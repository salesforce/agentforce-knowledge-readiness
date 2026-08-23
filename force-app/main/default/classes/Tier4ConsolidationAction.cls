/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * Tier 4: Agentforce Consolidation Agent — "The Action Layer".
 *
 * Runs only on an explicit user-approved merge from the Action Center
 * (DuplicateCandidateController, Apex-to-Apex). There is no longer a
 * confidence-score band gate: the unattended-pipeline auto-merge path was
 * retired, so a user who approves a merge always gets the drafted Golden
 * Record regardless of the candidate's confidence score. The old
 * Auto_Merge_Threshold__c / Manual_Review_Threshold__c knobs were removed.
 *
 * Bulkified SOQL via pre-loop Map.
 * Language from source article.
 * URLName: candidate.Id.to15() + '-' + art1.URLName.
 *
 * TODO: the only live caller is DuplicateCandidateController
 * (Apex-to-Apex). The @InvocableMethod decorator + "Action" suffix imply an
 * Agentforce surface that doesn't exist. Consider renaming to
 * Tier4ConsolidationService and dropping the decorator in a future refactor.
 */
public inherited sharing class Tier4ConsolidationAction {

 // keep-choice. CREATE_NEW = today's behaviour (LLM-draft a brand-new
    // Golden Record). KEEP_SURVIVOR = enrich a chosen existing article with the
    // other(s) as a NEW VERSION of it, then archive the loser(s) on publish.
    public static final String KEEP_CREATE_NEW = 'create_new';
    public static final String KEEP_SURVIVOR = 'keep_survivor';

    /**
 * Mockable seams. editOnlineArticle/archive go through the publisher
     * indirection (real APIs throw in test context); the survivor draft field
     * write goes through KBKavDraftWriter (with sharing + USER_MODE — enforces
 * the running user's Knowledge CRUD/FLS/sharing,). Tests swap these.
     */
    @TestVisible
    private static KBKnowledgePublisher.IPublisher publisher = new KBKnowledgePublisher.RealPublisher();
    @TestVisible
    private static KBKavDraftWriter draftWriter = new KBKavDraftWriter();

    @InvocableMethod(label='Consolidate Duplicate Articles'
        description='Drafts a merged Golden Record from duplicate candidates with qualifying scores.')
    public static void consolidate(List<Id> duplicateCandidateIds) {
        System.enqueueJob(new ConsolidationQueueable(duplicateCandidateIds));
    }

    /**
 * keep-choice pair consolidation. keepChoice = CREATE_NEW (new Golden
     * Record) or KEEP_SURVIVOR (enrich survivorVersionId with the other article
     * as a new version, archive the loser on publish). survivorVersionId is the
     * Knowledge__kav version id the user chose to keep; ignored for CREATE_NEW.
     */
    public static void consolidate(List<Id> duplicateCandidateIds, String keepChoice, Id survivorVersionId) {
        System.enqueueJob(new ConsolidationQueueable(duplicateCandidateIds, keepChoice, survivorVersionId));
    }

    /**
     * Cluster-aware consolidation. Expands the implied connected component,
     * drafts one Golden Record per component, resolves every candidate whose
     * both endpoints land in the component (including pairs the user did not
     * tick but that are transitively implied). Called only from Apex/LWC
     * (DuplicateCandidateController.approveClusterMerge) — Apex only allows
     * one @InvocableMethod per class, so this stays a plain static.
     */
    public static void consolidateCluster(List<Id> duplicateCandidateIds) {
        System.enqueueJob(new ClusterConsolidationQueueable(duplicateCandidateIds));
    }

    /**
 * keep-choice cluster consolidation. KEEP_SURVIVOR enriches the chosen
     * survivorVersionId with the merged cluster content (new version) and
     * archives the other members on publish; CREATE_NEW is the original
     * single-Golden-Record path.
     */
    public static void consolidateCluster(List<Id> duplicateCandidateIds, String keepChoice, Id survivorVersionId) {
        System.enqueueJob(new ClusterConsolidationQueueable(duplicateCandidateIds, keepChoice, survivorVersionId));
    }

 // ── field-aware merge shared helpers ───────────────────────────────
    // Merge must operate on the SAME content fields the rest of the app uses
    // (setup step 2's KB_Scan_Config__c.Content_Field_Mapping_JSON__c via
    // KBAssessmentService.getContentFields), not just Title+Summary — matching
    // the AI Fix flow (KBImprovementFixService). Otherwise, on an org whose body
    // lives in FAQ_Answer__c / Solution__c, the merge would read a near-empty
    // body and write into the wrong field.

    /** The Knowledge__kav fields to read/merge: Title + mapped content fields. */
    private static List<String> mergeFields() {
        List<String> fields = new List<String>{ 'Title' };
        for (String f : KBAssessmentService.getContentFields('Knowledge__kav')) {
            if (f != 'Title') fields.add(f);
        }
        return fields;
    }

    /** Dynamic SELECT of the merge fields + identity columns for a KAV id set. */
    private static Map<Id, Knowledge__kav> queryArticles(Set<Id> versionIds, List<String> fields) {
        Set<String> sel = new Set<String>{ 'Id', 'KnowledgeArticleId', 'UrlName', 'Language' };
        sel.addAll(fields);
        String soql = 'SELECT ' + String.join(new List<String>(sel), ', ')
            + ' FROM Knowledge__kav WHERE Id IN :versionIds';
        Map<Id, Knowledge__kav> out = new Map<Id, Knowledge__kav>();
        // System mode (default) on purpose: the merge must read the full current
        // body of both articles (the admin-mapped content fields) to draft a
        // complete Golden Record — FLS on those fields is the customer's to
        // grant, not ours. Runs from a queueable in system context, so the read
        // isn't narrowed by a running user's Knowledge data-category visibility.
        // Deliberately asymmetric with the merge WRITE, which goes through
        // KBKavDraftWriter under USER_MODE so the running user is genuinely
        // required to hold Knowledge write access. A USER_MODE read here would
        // instead throw on a content field for a Knowledge-read-only persona and
        // abort the merge before the write's access check runs.
        for (Knowledge__kav kav : Database.query(soql)) {
            out.put(kav.Id, kav);
        }
        return out;
    }

    /**
 * Stamp a candidate as a failed merge: Status=Error + a user-friendly
     * Merge_Error__c reason, added to toUpdate so it persists, and recorded in the
     * error list for the async-job debug trail. This makes a failed merge VISIBLE
     * on the Duplicates queue (a "Failed" badge + reason) instead of leaving it a
     * silent Pending — the pair stays actionable so the user can fix the cause and
     * retry (mirrors the AI-Fix path's Error status on recommendations).
     */
    private static void markCandidateError(
        Duplicate_Candidate__c dc, String reason,
        List<String> mergeErrors, List<Duplicate_Candidate__c> toUpdate
    ) {
        dc.Status__c = 'Error';
        dc.Merge_Error__c = reason != null && reason.length() > 1024 ? reason.left(1024) : reason;
        toUpdate.add(dc);
        mergeErrors.add('Candidate ' + dc.Id + ': ' + reason);
    }

    /**
 * Cluster variant of markCandidateError: stamp EVERY candidate in the
     * cluster as Error + reason and persist (soft-fail), instead of throwing —
     * which would roll back the status write and leave the cluster a silent
     * Pending. Applied to the cluster merge's failure + staleness paths.
     */
    private static void markClusterError(
        Iterable<Duplicate_Candidate__c> candidates, String reason
    ) {
        List<Duplicate_Candidate__c> rows = new List<Duplicate_Candidate__c>();
        String trimmed = reason != null && reason.length() > 1024 ? reason.left(1024) : reason;
        for (Duplicate_Candidate__c dc : candidates) {
            rows.add(new Duplicate_Candidate__c(
                Id = dc.Id, Status__c = 'Error', Merge_Error__c = trimmed
            ));
        }
        if (!rows.isEmpty()) Database.update(rows, false);
    }

    /** Translate a raw merge exception into an actionable, non-jargon message. */
    @TestVisible
    private static String friendlyMergeError(Exception e) {
        String raw = e != null ? e.getMessage() : '';
        if (raw == null) raw = '';
        // applyTitle throws a complete, already-actionable sentence. Pass it
        // through verbatim — prefixing "Merge failed: " would double the message
 // on the queue's Failed row.
 // COUPLING NOTE: the passthrough is keyed on substrings of the
        // applyTitle message. The current message (both-causes reword) no longer
        // contains "missing field-level security (Edit)" — it says "lack
        // field-level security (Edit)" — so the FIRST clause below no longer
        // matches it; passthrough now survives ONLY on the "Knowledge__kav.Title"
        // clause. Keep that exact token in any future applyTitle reword, or this
        // falls through to the generic "Merge failed:" prefix (guarded by
        // Tier4ConsolidationActionTest.friendlyMergeError_TitleFlsMessage_*).
        if (raw.containsIgnoreCase('missing field-level security (Edit)')
            || raw.containsIgnoreCase('Knowledge__kav.Title')) {
            return raw;
        }
        if (raw.containsIgnoreCase('No such column')) {
            return 'Field-level security on Knowledge fields is missing — grant the '
                + 'running user Read and Edit on your Content Scope fields, then retry.';
        }
 // USER_MODE surfaces a CRUD/FLS denial (e.g. "DML operation
        // INSERT not allowed on Knowledge__kav") — a user without Knowledge
        // write (no KB_Knowledge_Author permset) hits this on the create-new
        // merge path.
        if (KBAccessErrorClassifier.isAccessDenial(raw)) {
            return 'You do not have the Knowledge permissions needed to create the '
                + 'merged draft. Ask an admin to assign the KB Knowledge Author '
                + 'permission set (Knowledge Create/Edit), plus Manage Articles + '
                + 'Publish Articles and the Knowledge User license, then retry.';
        }
        if (raw.containsIgnoreCase('No active template version')) {
            return 'The merge AI template is not active in this org — activate '
                + 'Consolidate_Knowledge_Articles in Prompt Builder, then retry.';
        }
        // Fallback: surface the raw cause, trimmed.
        return 'Merge failed: ' + raw;
    }

    /** Uppercase the first letter (staleness reason reads as a sentence). */
    private static String capitalize(String s) {
        if (String.isBlank(s)) return s;
        return s.substring(0, 1).toUpperCase() + s.substring(1);
    }

    /**
     * Staleness guard: has the article changed since the duplicate was detected?
     * Returns the reason string when the article carries any Knowledge__kav
     * version (Draft OR a newer Online) — other than the one the duplication
     * evaluated — that was created AFTER the candidate's Score_Calculated_Date__c.
     * Null when the article is unchanged and safe to merge.
     *
     * Why block rather than reuse the existing draft: that draft may hold someone
     * else's in-progress enrichment (e.g. an AI-Fix rewrite or a manual edit made
     * after the duplication ran) — merging into or over it would clobber their
     * work, and the duplication verdict was reached against the *evaluated*
 * version, not this newer content. Mirrors the staleness philosophy
     * (a newer published version supersedes a candidate); here it also covers a
     * newer DRAFT, which is the common case right after an AI-Fix on the article.
     */
    private static String stalenessReason(Id knowledgeArticleId, Datetime detectedAt) {
        if (knowledgeArticleId == null || detectedAt == null) return null;
        // A version created AFTER detection is, by definition, newer than the
        // content the duplication verdict was reached against. The evaluated
        // version itself can't match: Score_Calculated_Date__c is stamped in the
        // same transaction that read it, so its CreatedDate <= detectedAt. So a
        // pure timestamp test is sufficient (no need to exclude by version id) and
        // catches the common case — a Draft created by a later AI-Fix on the article.
        List<Knowledge__kav> newer = [
            SELECT Id, PublishStatus
            FROM Knowledge__kav
            WHERE KnowledgeArticleId = :knowledgeArticleId
              AND CreatedDate > :detectedAt
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (newer.isEmpty()) return null;
        return 'the article "' + knowledgeArticleId + '" has a newer '
            + (KBPublishStatusHelper.isDraft(newer[0].PublishStatus) ? 'draft' : 'version')
            + ' created after this duplicate was detected — re-run the assessment '
            + 'before merging so the merge reflects the current content';
    }

    /**
 * Merge two articles via the shared findings-aware consolidate prompt.
     * Builds one ArticleInput per article (its mapped content fields + the issues
     * to resolve + strengths to preserve, fetched from the latest assessment) and
     * makes a SINGLE LLM call that reconciles both into one article — instead of
     * the old per-field, findings-blind merge. The first article (the survivor /
     * primary) is listed first so its identity (e.g. title) anchors the result.
     * Returns field → merged value.
     */
    private static Map<String, String> mergeArticlePair(
        Knowledge__kav a, Knowledge__kav b, List<String> fields,
        String language, PromptTemplateService promptService
    ) {
        Map<String, List<String>> issuesByVer = findingsByVersion(
            new Set<Id>{ a.Id, b.Id }, fields, 'Issue');
        Map<String, List<String>> strengthsByVer = findingsByVersion(
            new Set<Id>{ a.Id, b.Id }, fields, 'Strength');

        List<PromptTemplateService.ArticleInput> inputs =
            new List<PromptTemplateService.ArticleInput>{
                buildArticleInput(a, fields, issuesByVer, strengthsByVer),
                buildArticleInput(b, fields, issuesByVer, strengthsByVer)
            };
        PromptTemplateService.FixArticleResult res =
            promptService.consolidateArticles(inputs, fieldLimits(fields), language);
        return res != null && res.rewrittenFields != null
            ? res.rewrittenFields : new Map<String, String>();
    }

    private static String strVal(Knowledge__kav kav, String field) {
        if (kav == null) return '';
        Object v = kav.get(field);
        return v == null ? '' : String.valueOf(v);
    }

    /** Build one ArticleInput (mapped fields + its issues/strengths) for the prompt. */
    private static PromptTemplateService.ArticleInput buildArticleInput(
        Knowledge__kav kav, List<String> fields,
        Map<String, List<String>> issuesByVer, Map<String, List<String>> strengthsByVer
    ) {
        PromptTemplateService.ArticleInput ai = new PromptTemplateService.ArticleInput();
        for (String f : fields) {
            String v = strVal(kav, f);
            if (String.isNotBlank(v)) ai.fields.put(f, v);
        }
        String vid = String.valueOf(kav.Id);
        if (issuesByVer.containsKey(vid)) ai.issues = issuesByVer.get(vid);
        if (strengthsByVer.containsKey(vid)) ai.strengths = strengthsByVer.get(vid);
        return ai;
    }

    /**
 * Latest issues/strengths text per article VERSION id, from
     * KB_Dimension_Analysis__c. Best-effort: an article with no findings (never
     * assessed, or no open issues) simply contributes none — the merge then
     * proceeds on its mapped content fields alone (never Title+Summary). Bulk
     * query (one SOQL for the whole cluster). `type` is 'Issue' or 'Strength'.
     */
    private static Map<String, List<String>> findingsByVersion(
        Set<Id> versionIds, List<String> fields, String findingType
    ) {
        Map<String, List<String>> out = new Map<String, List<String>>();
        if (versionIds == null || versionIds.isEmpty()) return out;
        try {
            // Analysis_Text__c is a LongText (not filterable in SOQL); skip blanks in Apex.
            for (KB_Dimension_Analysis__c a : [
                SELECT Article_Assessment__r.Knowledge__c, Dimension__c, Analysis_Text__c
                FROM KB_Dimension_Analysis__c
                WHERE Article_Assessment__r.Knowledge__c IN :versionIds
                  AND Type__c = :findingType
                ORDER BY Article_Assessment__r.CreatedDate DESC
                LIMIT 500
            ]) {
                if (String.isBlank(a.Analysis_Text__c)) continue;
                String vid = String.valueOf(a.Article_Assessment__r.Knowledge__c);
                if (!out.containsKey(vid)) out.put(vid, new List<String>());
                // Prefix the dimension so the model knows which aspect each note is about.
                String dim = String.isBlank(a.Dimension__c) ? '' : a.Dimension__c + ': ';
                out.get(vid).add(dim + a.Analysis_Text__c);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Tier 4: findingsByVersion failed (' + findingType + '): ' + e.getMessage());
        }
        return out;
    }

    /** Per-field character limits for the consolidate prompt (Title capped 255). */
    private static Map<String, Integer> fieldLimits(List<String> fields) {
        Map<String, Schema.SObjectField> kavFields = Schema.SObjectType.Knowledge__kav.fields.getMap();
        Map<String, Integer> limits = new Map<String, Integer>();
        for (String f : fields) {
            if (f == 'Title') { limits.put('Title', 255); continue; }
            Schema.SObjectField sof = kavFields.get(f.toLowerCase());
            if (sof != null) {
                Integer len = sof.getDescribe().getLength();
                limits.put(f, len > 0 ? len : 131072);
            }
        }
        return limits;
    }

    /** FLS-checked write of merged field values onto a draft (Title capped 255). */
    private static void applyMergedFields(Knowledge__kav draft, Map<String, String> merged) {
        Map<String, Schema.SObjectField> kavFields = Schema.SObjectType.Knowledge__kav.fields.getMap();
        for (String f : merged.keySet()) {
            String val = merged.get(f);
            if (val == null) continue;
            if (f == 'Title') {
                applyTitle(draft, val);
                continue;
            }
            Schema.SObjectField sof = kavFields.get(f.toLowerCase());
            if (sof == null) continue;
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            if (!dfr.isUpdateable()) continue;
            Integer maxLen = dfr.getLength() > 0 ? dfr.getLength() : 131072;
            draft.put(f, val.length() > maxLen ? val.left(maxLen) : val);
        }
    }

    /**
     * FLS-checked Title write (capped 255). Title is a standard required field
     * but FLS-gating it keeps the write consistent with applyMergedFields and
 * degrades safely if a persona lacks Title edit.
     */
    private static void applyTitle(Knowledge__kav draft, String val) {
        if (val == null) return;
        // Title is REQUIRED on the Golden Record draft. If Title isn't updateable
        // for the running user, silently skipping it (the old behaviour) produced
        // a baffling REQUIRED_FIELD_MISSING: [Title] on insert. Fail loud with the
 // actionable cause instead — the queueable's catch surfaces it.
        //
        // NOTE: Title.isUpdateable() is false for TWO distinct reasons and we
        // can't tell them apart here: (a) the user has no object write on
        // Knowledge__kav at all (no KB_Knowledge_Author permset — the common
        // case for an analysis-only user), or (b) the user has object write but
        // lacks field-level Edit on Title specifically. Naming only Title FLS
        // (the old message) misdirected an analysis-only user to grant Title FLS
        // when the real gap was the write permset — so name BOTH causes.
        if (!Knowledge__kav.Title.getDescribe().isUpdateable()) {
            throw new KnowledgeAIException(
                'Cannot set the merged article Title on Knowledge__kav.Title — the '
                + 'running user can\'t edit it. Two things can cause this: you may '
                + 'not have Knowledge write access (ask an admin to assign the '
                + 'KB Knowledge Author permission set — Knowledge Create/Edit — plus '
                + 'Manage Articles + Publish Articles and the Knowledge User license); '
                + 'or you have write access but lack field-level security (Edit) on '
                + 'your Content Scope fields (Setup Wizard, Step 2). Grant whichever '
                + 'applies, then retry the merge.');
        }
        draft.Title = val.length() > 255 ? val.left(255) : val;
    }

    public inherited sharing class ConsolidationQueueable implements Queueable, Database.AllowsCallouts {
        private List<Id> candidateIds;
        private String keepChoice;       // CREATE_NEW (default) | KEEP_SURVIVOR
        private Id survivorVersionId;    // the KAV version the user keeps

        public ConsolidationQueueable(List<Id> candidateIds) {
            this(candidateIds, KEEP_CREATE_NEW, null);
        }

        public ConsolidationQueueable(List<Id> candidateIds, String keepChoice, Id survivorVersionId) {
            this.candidateIds = candidateIds;
            this.keepChoice = String.isBlank(keepChoice) ? KEEP_CREATE_NEW : keepChoice;
            this.survivorVersionId = survivorVersionId;
        }

        public void execute(QueueableContext context) {
 // no confidence-score band gate here. This queueable only runs
            // when a user has *explicitly* approved a merge in the Action Center
            // (DuplicateCandidateController), so the merge must always proceed —
            // the old Auto_Merge/Manual_Review thresholds were vestigial from the
            // retired unattended-pipeline path and silently no-opped a user's
            // approved merge when confidence sat below the auto-merge threshold.
            List<Duplicate_Candidate__c> candidates = [
                SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c,
                       Knowledge_Article_Id_1__c, Knowledge_Article_Id_2__c,
                       Confidence_Score__c, Status__c, Source_Tier__c,
                       Score_Calculated_Date__c
                FROM Duplicate_Candidate__c
                WHERE Id IN :candidateIds
 // Pending OR Error: an Error row is a previously-failed merge
                // the user is RETRYING from the queue. Excluding it made the retry a
                // silent no-op. The success arm below flips it to Resolved and clears
                // Merge_Error__c, so a successful retry heals the row.
                AND Status__c IN ('Pending', 'Error')
            ];

            if (candidates.isEmpty()) {
                return;
            }

            // Bulkified: collect all article IDs, query once
            Set<Id> allArticleIds = new Set<Id>();
            for (Duplicate_Candidate__c dc : candidates) {
                allArticleIds.add(Id.valueOf(dc.Knowledge_Article_1__c));
                allArticleIds.add(Id.valueOf(dc.Knowledge_Article_2__c));
            }

            List<String> fields = mergeFields();
            Map<Id, Knowledge__kav> articleMap = queryArticles(allArticleIds, fields);

            PromptTemplateService promptService = PromptTemplateService.getInstance();
            List<Duplicate_Candidate__c> toUpdate = new List<Duplicate_Candidate__c>();
            List<Knowledge__kav> newDrafts = new List<Knowledge__kav>();
            Map<Id, Knowledge__kav> candidateToDraft = new Map<Id, Knowledge__kav>();
            // Per-candidate merge failures. Each failed candidate is stamped
 // Status=Error + Merge_Error__c so the Duplicates queue shows a
            // visible "Failed" badge + reason instead of a silent Pending — the user
            // can fix the cause (re-run for staleness, grant FLS/Manage) and retry.
            // Also collected for the all-failed re-throw so the async job still
            // records a systemic failure.
            List<String> mergeErrors = new List<String>();

            for (Duplicate_Candidate__c dc : candidates) {
                // Draft the merged Golden Record (user-approved — no score gate).
                Knowledge__kav art1 = articleMap.get(Id.valueOf(dc.Knowledge_Article_1__c));
                Knowledge__kav art2 = articleMap.get(Id.valueOf(dc.Knowledge_Article_2__c));

                if (art1 == null || art2 == null) {
                    markCandidateError(dc, 'One or both articles could not be found — they may have been deleted. Re-run the assessment.', mergeErrors, toUpdate);
                    continue;
                }

 // Staleness guard: refuse if EITHER article changed since the
                // duplicate was detected (a newer draft/version) — merging would act
                // on a stale verdict and could clobber in-progress enrichment. Both
                // articles matter: the survivor is drafted; the loser is archived.
                String stale = stalenessReason(art1.KnowledgeArticleId, dc.Score_Calculated_Date__c);
                if (stale == null) {
                    stale = stalenessReason(art2.KnowledgeArticleId, dc.Score_Calculated_Date__c);
                }
                if (stale != null) {
                    markCandidateError(dc, capitalize(stale) + '.', mergeErrors, toUpdate);
                    continue;
                }

                String language = art1.Language != null ? art1.Language : 'en_US';

 // KEEP_SURVIVOR: enrich the chosen article (survivor) with
                // the other (loser) as a NEW VERSION of the survivor; the loser
                // is archived when the survivor publishes (the publish hook derives
                // it from the candidate junction). No new Golden Record is created.
                if (KEEP_SURVIVOR.equals(keepChoice) && survivorVersionId != null
                    && (survivorVersionId == art1.Id || survivorVersionId == art2.Id)) {
                    Knowledge__kav survivor = (survivorVersionId == art1.Id) ? art1 : art2;
                    Knowledge__kav loser = (survivorVersionId == art1.Id) ? art2 : art1;
                    try {
                        enrichSurvivor(dc, survivor, loser, fields, language, promptService);
                        dc.Status__c = 'Resolved';
                        dc.Merge_Error__c = null; // clear any prior failure note
                        toUpdate.add(dc);
                    } catch (Exception e) {
                        markCandidateError(dc, friendlyMergeError(e), mergeErrors, toUpdate);
                        System.debug(LoggingLevel.ERROR,
                            'Tier 4: keep-survivor merge failed for candidate ' + dc.Id + ': ' + e.getMessage());
                    }
                    continue;
                }

                try {
 // Field-aware merge across the mapped content fields,
                    // not just Summary — matches the AI Fix flow.
                    Map<String, String> mergedFields =
                        mergeArticlePair(art1, art2, fields, language, promptService);

                    // URLName: candidate.Id.to15() + '-' + art1.URLName
                    String newUrlName = dc.Id.to15() + '-' + (art1.UrlName != null ? art1.UrlName : 'merged');
                    if (newUrlName.length() > 255) {
                        newUrlName = newUrlName.abbreviate(255);
                    }

                    Knowledge__kav draftArticle = new Knowledge__kav(
                        UrlName = newUrlName,
                        Language = language
                    );
                    applyMergedFields(draftArticle, mergedFields);
                    // Golden Record title is explicitly marked as a merge.
                    applyTitle(draftArticle, 'Merged: ' + (art1.Title == null ? '' : art1.Title));

                    newDrafts.add(draftArticle);
                    candidateToDraft.put(dc.Id, draftArticle);

                    dc.Status__c = 'Resolved';
                    dc.Merge_Error__c = null;
                    toUpdate.add(dc);

                } catch (Exception e) {
                    markCandidateError(dc, friendlyMergeError(e), mergeErrors, toUpdate);
                    System.debug(LoggingLevel.ERROR,
                        'Tier 4: Merge draft failed for candidate ' + dc.Id + ': ' + e.getMessage());
                }
            }

 // Insert drafts. Wrap the DML: a bare `insert` that throws
            // (e.g. the running user lacks Knowledge create / Manage Articles, a
            // required-field validation fires, or a URLName collision) would escape
            // uncaught and roll back the Database.update(toUpdate) below — erasing
            // the very Error/Resolved + Merge_Error__c stamps that are the
            // user-visible signal, leaving the pair silently Pending and the async
            // job just "failed". Instead, flip every optimistically-Resolved
            // candidate (all-or-none insert → on throw NO draft was created) to
            // Error + reason so the failure stays visible + retryable, matching the
            // cluster CREATE_NEW path which already wraps its insert.
            if (!newDrafts.isEmpty()) {
                try {
                    // USER_MODE enforces the running user's Knowledge__kav CRUD +
 // FLS: a user without Knowledge write access — i.e. no
                    // KB_Knowledge_Author permset — is blocked here rather than
                    // creating a Golden Record past the org's access model. The
                    // throw is caught below and stamped as a retryable Error.
                    Database.insert(newDrafts, AccessLevel.USER_MODE);

                    // Update Duplicate_Candidate__c with merged article IDs.
                    // KnowledgeArticleId is auto-populated by the platform on insert,
 // so we can read it back from the same object reference.
                    Set<Id> draftIdsForLookup = new Set<Id>();
                    for (Knowledge__kav d : newDrafts) {
                        if (d.Id != null) draftIdsForLookup.add(d.Id);
                    }
                    Map<Id, Knowledge__kav> draftLookup = new Map<Id, Knowledge__kav>([
                        SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :draftIdsForLookup
                    ]);
                    for (Duplicate_Candidate__c dc : toUpdate) {
                        Knowledge__kav draft = candidateToDraft.get(dc.Id);
                        if (draft != null && draft.Id != null) {
                            dc.Merged_Article__c = draft.Id;
                            dc.Merged_Article_Version__c = draft.Id; // native-related-list lookup (same version id as the Text field)
                            Knowledge__kav fresh = draftLookup.get(draft.Id);
                            if (fresh != null && fresh.KnowledgeArticleId != null) {
                                dc.Merged_Knowledge_Article_Id__c = String.valueOf(fresh.KnowledgeArticleId);
                            }
                        }
                    }
                } catch (Exception e) {
                    String reason = friendlyMergeError(e);
                    String trimmed = reason != null && reason.length() > 1024 ? reason.left(1024) : reason;
                    for (Duplicate_Candidate__c dc : toUpdate) {
                        // Only the drafted (optimistically-Resolved) candidates need
                        // flipping; rows already stamped Error keep their own reason.
                        if (candidateToDraft.containsKey(dc.Id)) {
                            dc.Status__c = 'Error';
                            dc.Merge_Error__c = trimmed;
                            dc.Merged_Article__c = null;
                            dc.Merged_Article_Version__c = null;
                            mergeErrors.add('Candidate ' + dc.Id + ' (draft insert): ' + reason);
                        }
                    }
                    System.debug(LoggingLevel.ERROR,
                        'Tier 4: Golden Record draft insert failed: ' + e.getMessage());
                }
            }

            // Persist statuses: successes (Resolved + draft links) AND failures
            // (Error + Merge_Error__c) ride in toUpdate together, so the Duplicates
            // queue reflects the real outcome per candidate. Soft-fail so one bad
 // row degrades to a logged warning rather than aborting the batch.
            //
            // NOTE: we deliberately do NOT re-throw on all-failed here — a thrown
            // exception would roll back this very update and erase the Error/
 // Merge_Error__c stamps that are now the user-visible signal. The
            // per-candidate Error status IS the durable record; a debug log covers
            // the async-job trail without sacrificing the status write.
            if (!toUpdate.isEmpty()) {
                Database.update(toUpdate, false);
            }
            System.debug(LoggingLevel.INFO, 'Tier 4: Created ' + newDrafts.size()
                + ' Golden Record draft(s); ' + mergeErrors.size() + ' candidate(s) errored'
                + (mergeErrors.isEmpty() ? '' : ': ' + String.join(mergeErrors, ' | ')));
        }

        /**
 * KEEP_SURVIVOR: produce a NEW DRAFT VERSION of the survivor whose
         * content fields are the per-field LLM merge of survivor + loser, and
         * point the candidate at the survivor draft + survivor master. The loser
         * is archived when the survivor draft goes Online — the publish hook
         * (KBDuplicateCandidateReconciler.archiveMergedLosers) derives it from the
         * candidate (the non-survivor article id), since the merge link cannot
         * live on the loser article (Knowledge__kav fields are Draft-only writable).
         * Survivor identity/UrlName is preserved (we version it, not replace it).
         * Field-aware (mapped content fields, not just Summary). Never auto-publishes.
         */
        private void enrichSurvivor(
            Duplicate_Candidate__c dc, Knowledge__kav survivor, Knowledge__kav loser,
            List<String> fields, String language, PromptTemplateService promptService
        ) {
            Map<String, String> mergedFields =
                mergeArticlePair(survivor, loser, fields, language, promptService);

            // Open an editable draft off the survivor's Online article.
            String draftId = publisher.editOnlineArticle(survivor.KnowledgeArticleId, false);
            if (String.isBlank(draftId)) {
                throw new KnowledgeAIException(
                    'editOnlineArticle returned no draft id for survivor ' + survivor.KnowledgeArticleId);
            }

            // Write the merged fields into the survivor draft. The writer runs
 // with sharing + USER_MODE, so the running user's Knowledge
            // CRUD/FLS/sharing are enforced — mirrors
            // KBImprovementFixService.persistDraft.
            Knowledge__kav draft = new Knowledge__kav(Id = (Id) draftId);
            applyMergedFields(draft, mergedFields);
            draftWriter.writeDraft(draft);

            // The merge link lives on the Duplicate_Candidate__c junction below,
            // NOT on the loser article. (Probe 2026-06-16: Knowledge__kav fields
            // are writable only on a Draft — an Online/Archived write fails with
            // FIELD_INTEGRITY_EXCEPTION, so the old loser Merged_Into__c stamp
            // silently no-opped.) KBDuplicateCandidateReconciler.archiveMergedLosers
            // derives the loser from the candidate (the non-survivor article id)
            // and archives it when the survivor publishes.

            // Candidate points at the survivor draft + master so the reconciler's
            // happy-path Resolved fires when that draft is published, and so the
            // loser can be derived (the article id that is NOT the survivor).
            dc.Merged_Article__c = draftId;
            dc.Merged_Article_Version__c = draftId; // native-related-list lookup
            dc.Merged_Knowledge_Article_Id__c = String.valueOf(survivor.KnowledgeArticleId);
        }
    }

    public inherited sharing class ClusterConsolidationQueueable implements Queueable, Database.AllowsCallouts {
        private List<Id> seedCandidateIds;
        private String keepChoice;       // CREATE_NEW (default) | KEEP_SURVIVOR
        private Id survivorVersionId;    // the cluster member to keep

        public ClusterConsolidationQueueable(List<Id> seedCandidateIds) {
            this(seedCandidateIds, KEEP_CREATE_NEW, null);
        }

        public ClusterConsolidationQueueable(List<Id> seedCandidateIds, String keepChoice, Id survivorVersionId) {
            this.seedCandidateIds = seedCandidateIds;
            this.keepChoice = String.isBlank(keepChoice) ? KEEP_CREATE_NEW : keepChoice;
            this.survivorVersionId = survivorVersionId;
        }

        public void execute(QueueableContext context) {
            if (seedCandidateIds == null || seedCandidateIds.isEmpty()) {
                return;
            }

            // 1. Load seed candidates and collect their article version ids.
 // Pending OR Error: the user may be retrying a cluster merge
            //    that previously failed (seeds stamped Error). Excluding Error made
            //    the retry a silent no-op.
            List<Duplicate_Candidate__c> seeds = [
                SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c, Source_Tier__c,
                       Score_Calculated_Date__c
                FROM Duplicate_Candidate__c
                WHERE Id IN :seedCandidateIds
                AND Status__c IN ('Pending', 'Error')
            ];
            if (seeds.isEmpty()) {
                return;
            }

            Set<Id> seedVersionIds = new Set<Id>();
            // Earliest detection date across the seeds — the conservative bound for
 // the cluster staleness guard: any cluster article changed after
            // the FIRST seed was detected is treated as newer-than-analysis.
            Datetime earliestDetectedAt = null;
            for (Duplicate_Candidate__c dc : seeds) {
                if (dc.Knowledge_Article_1__c != null) seedVersionIds.add(Id.valueOf(dc.Knowledge_Article_1__c));
                if (dc.Knowledge_Article_2__c != null) seedVersionIds.add(Id.valueOf(dc.Knowledge_Article_2__c));
                if (dc.Score_Calculated_Date__c != null
                    && (earliestDetectedAt == null || dc.Score_Calculated_Date__c < earliestDetectedAt)) {
                    earliestDetectedAt = dc.Score_Calculated_Date__c;
                }
            }
            if (seedVersionIds.size() < 2) {
                return;
            }

            // Resolve version ids → master KnowledgeArticleIds. We match on
            // master ids so different pipeline runs' version records for the
            // same article are treated as the same node in the cluster graph.
            Map<Id, Id> versionToMaster = new Map<Id, Id>();
            Set<Id> clusterMasterIds = new Set<Id>();
            for (Knowledge__kav kav : [
                SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :seedVersionIds
            ]) {
                versionToMaster.put(kav.Id, kav.KnowledgeArticleId);
                clusterMasterIds.add(kav.KnowledgeArticleId);
            }
            if (clusterMasterIds.size() < 2) {
                return;
            }

            // 2. Close the cluster on master ids. At each step, find every
            //    Knowledge__kav version whose master is in the cluster, then
            //    find every Pending candidate touching those versions, then
            //    fold the newly-seen articles' masters back into the cluster.
            //    Stop when a pass adds nothing new.
            Integer prevSize = 0;
            while (prevSize != clusterMasterIds.size()) {
                prevSize = clusterMasterIds.size();

                Set<Id> clusterVersionIds = new Set<Id>();
                for (Knowledge__kav kav : [
                    SELECT Id, KnowledgeArticleId FROM Knowledge__kav
                    WHERE KnowledgeArticleId IN :clusterMasterIds
                ]) {
                    clusterVersionIds.add(kav.Id);
                    versionToMaster.put(kav.Id, kav.KnowledgeArticleId);
                }
                if (clusterVersionIds.isEmpty()) break;

                List<Duplicate_Candidate__c> hop = [
                    SELECT Knowledge_Article_1__c, Knowledge_Article_2__c
                    FROM Duplicate_Candidate__c
                    WHERE (Knowledge_Article_1__c IN :clusterVersionIds OR Knowledge_Article_2__c IN :clusterVersionIds)
                    AND Status__c IN ('Pending', 'Error') // re-absorb errored neighbors on a cluster retry
                ];
                Set<Id> newVersionsSeen = new Set<Id>();
                for (Duplicate_Candidate__c dc : hop) {
                    if (dc.Knowledge_Article_1__c != null) {
                        Id v = Id.valueOf(dc.Knowledge_Article_1__c);
                        if (!versionToMaster.containsKey(v)) newVersionsSeen.add(v);
                    }
                    if (dc.Knowledge_Article_2__c != null) {
                        Id v = Id.valueOf(dc.Knowledge_Article_2__c);
                        if (!versionToMaster.containsKey(v)) newVersionsSeen.add(v);
                    }
                }
                if (!newVersionsSeen.isEmpty()) {
                    for (Knowledge__kav kav : [
                        SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :newVersionsSeen
                    ]) {
                        versionToMaster.put(kav.Id, kav.KnowledgeArticleId);
                        clusterMasterIds.add(kav.KnowledgeArticleId);
                    }
                }
            }

 // 2b. Staleness guard: if ANY article now in the cluster has a
            //     version created after the earliest seed detection, refuse the
            //     whole cluster merge — the same "don't merge on a stale verdict /
            //     don't clobber newer edits" rule as the pair path. Conservative by
            //     design (earliest seed date, whole-cluster block): a cluster merge
            //     touches many articles, so partial staleness makes the result
            //     untrustworthy. The user re-runs the assessment and re-merges.
            if (earliestDetectedAt != null) {
                for (Knowledge__kav v : [
                    SELECT KnowledgeArticleId, PublishStatus
                    FROM Knowledge__kav
                    WHERE KnowledgeArticleId IN :clusterMasterIds
                      AND CreatedDate > :earliestDetectedAt
                    LIMIT 1
                ]) {
 // Stamp the seed candidates Error + reason and stop
                    // NOT a throw (which would roll back and leave them Pending).
                    markClusterError(seeds,
                        'One of the articles in this cluster has a newer '
                        + (KBPublishStatusHelper.isDraft(v.PublishStatus) ? 'draft' : 'version')
                        + ' created after these duplicates were detected — re-run the '
                        + 'assessment before merging so the merge reflects current content.');
                    return;
                }
            }

            // 3. Collect every version id whose master is in the cluster —
            //    these are the versions the implied-candidate query will use.
 // Field-aware: pull the mapped content fields, not just
            //    Title+Summary, so cluster merges operate on the real body.
            List<String> fields = mergeFields();
            Set<String> clusterSel = new Set<String>{ 'Id', 'KnowledgeArticleId', 'UrlName', 'Language' };
            clusterSel.addAll(fields);
            Set<Id> clusterVersionIdsFinal = new Set<Id>();
            Map<Id, Knowledge__kav> articleMap = new Map<Id, Knowledge__kav>();
            String clusterSoql = 'SELECT ' + String.join(new List<String>(clusterSel), ', ')
                + ' FROM Knowledge__kav WHERE KnowledgeArticleId IN :clusterMasterIds';
            // System mode (default) on purpose, same rationale as queryArticles:
            // clusterSel pulls the admin-mapped content fields so the cluster
            // merge reads full bodies (customer-granted FLS), from a queueable in
            // system context, deliberately asymmetric with the USER_MODE merge
            // write (KBKavDraftWriter). USER_MODE here would throw on a content
            // field for a Knowledge-read-only persona and abort before the write.
            for (Knowledge__kav kav : Database.query(clusterSoql)) {
                clusterVersionIdsFinal.add(kav.Id);
                articleMap.put(kav.Id, kav);
            }

            // 4. Pick up EVERY Pending/Error candidate whose BOTH endpoints are in
            //    the cluster — these all get auto-resolved alongside the
 // user-ticked seeds. Error included so a cluster retry heals
            //    neighbors that failed on the prior attempt.
            List<Duplicate_Candidate__c> impliedCandidates = [
                SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c
                FROM Duplicate_Candidate__c
                WHERE Knowledge_Article_1__c IN :clusterVersionIdsFinal
                AND Knowledge_Article_2__c IN :clusterVersionIdsFinal
                AND Status__c IN ('Pending', 'Error')
            ];
            Map<Id, Duplicate_Candidate__c> toResolve = new Map<Id, Duplicate_Candidate__c>();
            for (Duplicate_Candidate__c dc : impliedCandidates) {
                toResolve.put(dc.Id, dc);
            }

            // Treat the final cluster as "one article per master". We pick the
            // newest version per master for the body so we merge the latest
            // content, not stale snapshots.
            Map<Id, Knowledge__kav> latestByMaster = new Map<Id, Knowledge__kav>();
            for (Knowledge__kav kav : articleMap.values()) {
                Knowledge__kav existing = latestByMaster.get(kav.KnowledgeArticleId);
                if (existing == null) {
                    latestByMaster.put(kav.KnowledgeArticleId, kav);
                }
            }
            // Rebuild articleMap keyed by version id but only containing one-per-master.
            articleMap = new Map<Id, Knowledge__kav>();
            Set<Id> clusterArticleIds = new Set<Id>();
            for (Knowledge__kav kav : latestByMaster.values()) {
                articleMap.put(kav.Id, kav);
                clusterArticleIds.add(kav.Id);
            }

 // 5. Field-aware cluster merge. Pick a primary (first member)
            //    for identity defaults, then for each mapped field fold that
            //    field's value across ALL members via draftMergedCluster.
            PromptTemplateService promptService = PromptTemplateService.getInstance();
            Knowledge__kav primary = null;
            for (Id artId : clusterArticleIds) {
                Knowledge__kav kav = articleMap.get(artId);
                if (kav == null) continue;
                if (primary == null) { primary = kav; break; }
            }
            if (primary == null) {
                return;
            }
            String language = primary.Language != null ? primary.Language : 'en_US';

 // KEEP_SURVIVOR (cluster): enrich the chosen survivor with the
            // whole cluster's content as a NEW VERSION of it, archive the other
            // members on publish (derived from each candidate junction), and point
            // every candidate at the survivor draft. No new Golden Record.
            if (KEEP_SURVIVOR.equals(keepChoice) && survivorVersionId != null
                && articleMap.containsKey(survivorVersionId)) {
                try {
                    enrichClusterSurvivor(
                        articleMap.get(survivorVersionId), articleMap, clusterArticleIds,
                        fields, language, promptService, toResolve.values()
                    );
                    if (!toResolve.isEmpty()) {
                        // Soft-fail: a single bad candidate row degrades to a
                        // logged warning rather than aborting the whole cluster
 // resolve.
                        Database.update(toResolve.values(), false);
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR,
                        'Tier 4 (cluster): keep-survivor merge failed for seeds '
                        + seedCandidateIds + ': ' + e.getMessage());
 // Stamp every cluster candidate Error + reason so the
                    // failure is visible on the Duplicates queue and the user can
                    // fix the cause + retry — NOT a re-throw (which would roll back
                    // the status write and leave the cluster silently Pending).
                    markClusterError(toResolve.values(), friendlyMergeError(e));
                }
                return;
            }

            // CREATE_NEW: a fresh Golden Record carrying the merged content fields.
            Knowledge__kav draft;
            try {
                // LLM merge inside the try — a prompt failure must leave the
                // cluster Pending (no draft, no resolve), not escape the queueable.
                Map<String, String> mergedFields =
                    mergeClusterFields(articleMap, clusterArticleIds, fields, language, promptService);

                Id seedForUrl = seedCandidateIds[0];
                String newUrlName = seedForUrl.to15() + '-' + (primary.UrlName != null ? primary.UrlName : 'merged-cluster');
                if (newUrlName.length() > 255) {
                    newUrlName = newUrlName.abbreviate(255);
                }

                draft = new Knowledge__kav(
                    UrlName = newUrlName,
                    Language = language
                );
                applyMergedFields(draft, mergedFields);
                applyTitle(draft, 'Merged: ' + (primary.Title == null ? '' : primary.Title));
 // USER_MODE enforces Knowledge__kav CRUD + FLS — a user
                // without KB_Knowledge_Author is blocked from creating the
                // cluster Golden Record; the throw is caught + stamped Error.
                Database.insert(draft, AccessLevel.USER_MODE);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Tier 4 (cluster): Merge draft failed for seeds ' + seedCandidateIds + ': ' + e.getMessage());
 // Stamp every cluster candidate Error + reason rather than
                // re-throwing (which would roll back the status write).
                markClusterError(toResolve.values(), friendlyMergeError(e));
                return;
            }

            // 6. Mark every candidate in the closure Resolved and point it at the draft.
 // Re-fetch the inserted draft to capture KnowledgeArticleId.
            String mergedArticleId = null;
            try {
                Knowledge__kav fresh = [
                    SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :draft.Id LIMIT 1
                ];
                mergedArticleId = (fresh != null && fresh.KnowledgeArticleId != null)
                    ? String.valueOf(fresh.KnowledgeArticleId) : null;
            } catch (Exception ignore) {
                // best-effort — reconciler still works through the lazy path
            }
            for (Duplicate_Candidate__c dc : toResolve.values()) {
                dc.Status__c = 'Resolved';
                dc.Merge_Error__c = null; // heal a prior failure note on a successful cluster retry
                dc.Merged_Article__c = draft.Id;
                dc.Merged_Article_Version__c = draft.Id; // native-related-list lookup
                if (mergedArticleId != null) {
                    dc.Merged_Knowledge_Article_Id__c = mergedArticleId;
                }
            }
            if (!toResolve.isEmpty()) {
                update toResolve.values();
                System.debug(LoggingLevel.INFO,
                    'Tier 4 (cluster): Merged ' + clusterArticleIds.size()
                    + ' articles into draft ' + draft.Id
                    + ', resolved ' + toResolve.size() + ' candidates.');
            }
        }

        /**
 * Findings-aware cluster merge. Builds one ArticleInput per cluster
         * member (its mapped content fields + issues to resolve + strengths to
         * preserve) and makes a SINGLE consolidate call that reconciles all members
         * into one article — instead of the old per-field pairwise fold. The
         * primary (first member) is listed first to anchor identity. An article
         * with no findings contributes none (content-only for that member).
         */
        private Map<String, String> mergeClusterFields(
            Map<Id, Knowledge__kav> articleMap, Set<Id> clusterArticleIds,
            List<String> fields, String language, PromptTemplateService promptService
        ) {
            Set<Id> verIds = new Set<Id>();
            for (Id artId : clusterArticleIds) {
                if (articleMap.containsKey(artId)) verIds.add(artId);
            }
            Map<String, List<String>> issuesByVer = findingsByVersion(verIds, fields, 'Issue');
            Map<String, List<String>> strengthsByVer = findingsByVersion(verIds, fields, 'Strength');

            List<PromptTemplateService.ArticleInput> inputs =
                new List<PromptTemplateService.ArticleInput>();
            for (Id artId : clusterArticleIds) {
                Knowledge__kav kav = articleMap.get(artId);
                if (kav == null) continue;
                inputs.add(buildArticleInput(kav, fields, issuesByVer, strengthsByVer));
            }
            if (inputs.isEmpty()) return new Map<String, String>();

            PromptTemplateService.FixArticleResult res =
                promptService.consolidateArticles(inputs, fieldLimits(fields), language);
            return res != null && res.rewrittenFields != null
                ? res.rewrittenFields : new Map<String, String>();
        }

        /**
 * KEEP_SURVIVOR (cluster). Enrich `survivor` with the whole
         * cluster's merged content (per mapped field) as a new draft version,
         * and point each candidate at the survivor draft. Every OTHER cluster
         * member is archived on survivor publish, derived from its candidate
         * junction (not a loser-article stamp — see enrichSurvivor for why).
         * Mirrors the pair enrichSurvivor; never auto-publishes.
         */
        private void enrichClusterSurvivor(
            Knowledge__kav survivor, Map<Id, Knowledge__kav> articleMap, Set<Id> clusterArticleIds,
            List<String> fields, String language, PromptTemplateService promptService,
            List<Duplicate_Candidate__c> candidates
        ) {
            Map<String, String> mergedFields =
                mergeClusterFields(articleMap, clusterArticleIds, fields, language, promptService);

            String draftId = publisher.editOnlineArticle(survivor.KnowledgeArticleId, false);
            if (String.isBlank(draftId)) {
                throw new KnowledgeAIException(
                    'editOnlineArticle returned no draft id for cluster survivor ' + survivor.KnowledgeArticleId);
            }

            Knowledge__kav draft = new Knowledge__kav(Id = (Id) draftId);
            applyMergedFields(draft, mergedFields);
            draftWriter.writeDraft(draft);

            // No loser-article stamp: the merge link lives on each
            // Duplicate_Candidate__c row (see enrichSurvivor / archiveMergedLosers
            // for the probe rationale). The cluster fans out into one resolved
            // candidate per pair, so every other cluster member is recoverable as
            // the non-survivor article id on its candidate when the survivor
            // publishes.

            String survivorMasterId = String.valueOf(survivor.KnowledgeArticleId);
            for (Duplicate_Candidate__c dc : candidates) {
                dc.Status__c = 'Resolved';
                dc.Merge_Error__c = null; // heal a prior failure note on a successful cluster retry
                dc.Merged_Article__c = draftId;
                dc.Merged_Article_Version__c = draftId; // native-related-list lookup
                dc.Merged_Knowledge_Article_Id__c = survivorMasterId;
            }
        }
    }
}
