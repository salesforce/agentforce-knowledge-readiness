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
 * LWC Controller for Duplicate_Candidate__c management.
 * Powers the knowledgeAuditQueue component.
 */
public with sharing class DuplicateCandidateController {

 // the status buckets the unified Duplicates queue can surface. Default
    // is the ACTIONABLE set; the two LWC toggles widen it.
 // ACTIONABLE = Pending PLUS Error: a failed merge is stamped Status='Error'
    // + Merge_Error__c and must stay on the queue (shown as "⚠ Failed" with its reason)
    // so the user can fix the cause and retry — it is not resolved/discarded.
    private static final Set<String> ACTIONABLE_STATUSES = new Set<String>{ 'Pending', 'Error' };
    private static final Set<String> RESOLVED_STATUSES = new Set<String>{ 'Resolved', 'Superseded' };
 // review — the headline Duplicates count-badge is Pending-ONLY. Error
    // (failed-merge) rows still SHOW in the queue (getCandidatesByStatus surfaces
    // the ACTIONABLE Pending+Error set as "⚠ Failed" rows), but they are not
    // counted in the badge — so the badge matches the queue's own countchange
    // (Pending) and does not flicker Pending+Error→Pending when the tab opens.
    private static final Set<String> BADGE_STATUSES = new Set<String>{ 'Pending' };

    // Publish/edit indirection so publishGoldenRecord can be stubbed in tests
    // (inserted Knowledge__kav rows cannot reach PublishStatus='Online', so the
    // real publish API throws). Mirrors Tier4ConsolidationAction's seam.
    @TestVisible
    private static KBKnowledgePublisher.IPublisher publisher = new KBKnowledgePublisher.RealPublisher();

    @AuraEnabled(cacheable=true)
    public static List<Duplicate_Candidate__c> getActiveCandidates(String runId) {
        // Count-badge / whole-run caller — Pending-only (not the Pending+Error
        // ACTIONABLE set) so the Action Center badge reflects the Pending count,
 // consistent with the queue's countchange and CLAUDE.md.
        return queryCandidates(runId, null, BADGE_STATUSES);
    }

    /**
 * status-aware variant powering the unified Duplicates queue. The
     * queue's two toggles (Show resolved / Show discarded) widen the default
     * Pending-only set. `includeResolved` adds Resolved + Superseded;
     * `includeDiscarded` adds the DISCARDED_STATUSES (Not a Duplicate / Rejected
     * / Suppressed). Pending is ALWAYS included — it is the queue's baseline.
     */
    @AuraEnabled(cacheable=true)
    public static List<Duplicate_Candidate__c> getCandidatesByStatus(
        String runId, String articleVersionId, Boolean includeResolved, Boolean includeDiscarded
    ) {
        Set<String> statuses = new Set<String>(ACTIONABLE_STATUSES);
        if (includeResolved == true) {
            statuses.addAll(RESOLVED_STATUSES);
        }
        if (includeDiscarded == true) {
            statuses.addAll(KBAssessmentModels.DISCARDED_STATUSES);
        }
        return queryCandidates(runId, articleVersionId, statuses);
    }

    /**
 * variant that additionally filters to candidates touching a specific
     * KnowledgeArticleVERSION id on either side of the pair. Used by the
     * "Resolve in Action Center" deep-link from the article record page's
     * Duplicates & Conflicts tab, so the queue lands on the exact pair(s) for
     * that article+run rather than the whole run's list.
     *
 * Field-naming trap: Knowledge_Article_1__c / _2__c hold the
     * VERSION id (despite the "Article" name); the article-level KnowledgeArticleId
     * is in Knowledge_Article_Id_1__c / _2__c. The record-page sidebar passes the
     * assessed VERSION id, so we match the version fields.
     *
     * articleVersionId may be blank → behaves like getActiveCandidates (no
     * article narrowing).
     */
    @AuraEnabled(cacheable=true)
    public static List<Duplicate_Candidate__c> getActiveCandidatesForArticle(String runId, String articleVersionId) {
        // Deep-link entry point (record-page "Resolve in Action Center"): the
        // ACTIONABLE set (Pending + Error) — a failed merge stays actionable/visible
 // for retry. The headline count-badge uses the Pending-only
 // getActiveCandidates path instead, so this method no longer
        // feeds the badge.
        return queryCandidates(runId, articleVersionId, ACTIONABLE_STATUSES);
    }

    /**
     * Shared query for the Duplicates queue. `statuses` is the set of
     * Status__c values to surface (always includes 'Pending' from callers).
     * Selects Merged_Article__c so the golden-record "View Draft" per-row
 * action can navigate without a re-query.
     */
    private static List<Duplicate_Candidate__c> queryCandidates(
        String runId, String articleVersionId, Set<String> statuses
    ) {
        Id runIdSafe = parseOptionalId(runId);
        if (String.isNotBlank(runId) && runIdSafe == null) {
            return new List<Duplicate_Candidate__c>();
        }
        // Includes Knowledge_Article_Id_1/2__c + Merged_Knowledge_Article_Id__c
 // so the lazy reconciler can decide staleness without a re-query.
        String query = 'SELECT Id, Name, Knowledge_Article_1__c, Knowledge_Article_2__c, ' +
                       'Knowledge_Article_Id_1__c, Knowledge_Article_Id_2__c, ' +
                       'Merged_Knowledge_Article_Id__c, ' +
                       'Article_1_Title__c, Article_2_Title__c, Confidence_Score__c, ' +
                       'Flag_Type__c, AI_Reasoning__c, Status__c, Source_Tier__c, ' +
                       'Score_Calculated_Date__c, Merged_Article__c, Merge_Error__c ' +
                       'FROM Duplicate_Candidate__c ' +
                       'WHERE Status__c IN :statuses';
        Map<String, Object> binds = new Map<String, Object>{ 'statuses' => statuses };
        if (runIdSafe != null) {
            query += ' AND Assessment_Run__c = :runIdSafe';
            binds.put('runIdSafe', runIdSafe);
        }
        if (String.isNotBlank(articleVersionId)) {
            query += ' AND (Knowledge_Article_1__c = :articleVersionId'
                   + ' OR Knowledge_Article_2__c = :articleVersionId)';
            binds.put('articleVersionId', articleVersionId);
        }
        query += ' ORDER BY Confidence_Score__c DESC LIMIT 200';
        return Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);
    }

    /**
 * Non-cacheable reconciliation hook. The cacheable list methods
     * cannot do DML, so the LWC calls this after a successful wire load to
     * close any rows whose underlying article was published outside our flow.
     * Returns the set of newly-closed candidate ids so the LWC can prune them
     * client-side without a refetch.
     */
    @AuraEnabled
    public static List<Id> reconcileActiveCandidates() {
        try {
            List<Duplicate_Candidate__c> rows = [
                SELECT Id, Status__c,
                       Knowledge_Article_1__c, Knowledge_Article_2__c,
                       Knowledge_Article_Id_1__c, Knowledge_Article_Id_2__c,
                       Merged_Knowledge_Article_Id__c, Merged_Article__c
                FROM Duplicate_Candidate__c
                WHERE Status__c = 'Pending'
                LIMIT 200
            ];
            Set<Id> closed = KBDuplicateCandidateReconciler.reconcileInboxRows(rows);
            return new List<Id>(closed);
        } catch (Exception e) {
            AuraHandledException ahe = new AuraHandledException(
                'Reconciliation failed: ' + e.getMessage());
            ahe.setMessage('Reconciliation failed: ' + e.getMessage());
            throw ahe;
        }
    }

    /**
     * Returns Pending duplicate candidates where the given Knowledge__kav id
     * appears on either side of the pair. Used by the record-page Health
     * panel's Duplicates tab so users see existing candidates before re-running
     * the conflict check. Capped at 10 — the panel renders at most 3 cards but
     * the extra headroom lets the LWC count "+N more" if needed.
     */
    @AuraEnabled(cacheable=true)
    public static List<Duplicate_Candidate__c> getOpenCandidatesForArticle(String articleVersionId) {
        if (String.isBlank(articleVersionId)) return new List<Duplicate_Candidate__c>();
        return [
            SELECT Id, Name, Knowledge_Article_1__c, Knowledge_Article_2__c,
                   Article_1_Title__c, Article_2_Title__c, Confidence_Score__c,
                   Flag_Type__c, AI_Reasoning__c, Status__c, Source_Tier__c,
                   Score_Calculated_Date__c
            FROM Duplicate_Candidate__c
            WHERE Status__c = 'Pending'
              AND (Knowledge_Article_1__c = :articleVersionId OR Knowledge_Article_2__c = :articleVersionId)
            WITH USER_MODE
            ORDER BY Score_Calculated_Date__c DESC NULLS LAST, Confidence_Score__c DESC
            LIMIT 10
        ];
    }

 // getResolvedCandidates was retired: the standalone "Resolved
    // Duplicates" tab (kbResolvedCandidates) it fed was folded into the unified
    // Duplicates queue, which now surfaces resolved rows via getCandidatesByStatus
    // with includeResolved=true. The golden-record "View Draft" affordance moved
    // to a per-row action there.

    /**
     * Returns Id.valueOf(runId) if it parses to a valid 15/18-char Salesforce
     * Id, null otherwise. Callers treat null + blank input as "no filter";
     * null + non-blank input as "garbage → return empty".
     */
    private static Id parseOptionalId(String raw) {
        if (String.isBlank(raw)) return null;
        try { return Id.valueOf(raw); } catch (Exception e) { return null; }
    }

    @AuraEnabled
    public static void updateStatus(Id candidateId, String newStatus) {
        Duplicate_Candidate__c dc = [
            SELECT Id, Status__c
            FROM Duplicate_Candidate__c
            WHERE Id = :candidateId
            LIMIT 1
        ];
        dc.Status__c = newStatus;
        // USER_MODE enforces FLS on Status__c. Status__c is a restricted picklist
        // (Pending / Resolved / Rejected / Suppressed) — invalid values throw at
        // DML time with a platform error, so no application-level whitelist is needed.
        Database.update(dc, AccessLevel.USER_MODE);
    }

 /** Soft-discard status written by the consolidated "not a duplicate" action. */
    @TestVisible
    private static final String STATUS_NOT_A_DUPLICATE = 'Not a Duplicate';

    /**
 * consolidated "mark as not a duplicate" action. Replaces the former
     * rejectCandidate + suppressCandidate split (both of which set a permanent
     * terminal status that behaved identically to the user). Sets the SOFT
     * status 'Not a Duplicate': the pair is preserved this run but IS
     * re-evaluated and can re-surface on the next assessment (see
     * Tier4PairEvaluator — soft statuses are overwritten on re-run). The reason
     * is optional and stored on Rejection_Reason__c (the existing audit field,
     * reused — no schema churn); a blank reason clears any stale prior value.
     *
     * Version-specificity is inherent: the pair is keyed by version composite
     * key, so a re-publish of either article yields a fresh candidate anyway.
     */
    @AuraEnabled
    public static void markNotADuplicate(Id candidateId, String reason) {
        Duplicate_Candidate__c dc = [
            SELECT Id, Status__c, Rejection_Reason__c
            FROM Duplicate_Candidate__c
            WHERE Id = :candidateId
            LIMIT 1
        ];
 // defense-in-depth precondition: only a Pending
        // candidate may be discarded. Without this, the unified queue's
        // read-only Compare (reachable from Resolved/Superseded rows once
        // "Show resolved" is on) could flip a completed merge to 'Not a
        // Duplicate', dropping it from the resolved view and orphaning its
        // Golden Record draft. The UI already hides the action on terminal
        // rows; this guards the endpoint directly.
        if (dc.Status__c != 'Pending') {
            throw new AuraHandledException(
                'Only a pending candidate can be marked as not a duplicate. '
                + 'This candidate is already ' + dc.Status__c + '.'
            );
        }
        dc.Status__c = STATUS_NOT_A_DUPLICATE;
        // Always overwrite the reason so this action's audit trail is accurate:
        // a blank reason clears any stale reason left by a prior action, rather
        // than leaving the old text to masquerade as this decision's rationale.
        dc.Rejection_Reason__c = String.isNotBlank(reason) ? reason : null;
        // USER_MODE enforces FLS on the written fields. Status__c is a restricted
        // picklist so an invalid value throws at DML time. The Action Center personas
        // (KB_Assessment_Admin / Setup_Admin) hold editable FLS on Status__c +
        // Rejection_Reason__c, so USER_MODE does not block the legitimate caller.
        update as user dc;
    }

    /**
     * Publishes a merged Golden Record draft from the Action Center and archives
     * the source ("loser") articles in the SAME transaction.
     *
     * Why this exists: an approved merge only DRAFTS the Golden Record — it never
     * publishes. Publishing it used to be native-only (the standard Knowledge
     * layout), where loser-archiving keyed off a Knowledge__kav after-update
     * trigger firing on that publish. But publishing generally does NOT fire Apex
     * triggers on Knowledge__kav (it changes publication status without an
     * incidental save — verified empirically), so the losers were left Online
     * after a native publish and the trigger was retired. Driving the publish
     * through here makes archiving deterministic: publish, then run the
     * reconciler directly — which flips the candidate to Resolved and archives
     * both source articles as losers. Idempotent: if the Golden Record is already
     * Online (e.g. published natively before this action existed), the publish is
     * skipped and the reconciler still archives any losers left behind.
     *
     * Publish + archive require Knowledge write/delete (KB_Knowledge_Author); a
     * denial is translated to actionable guidance rather than raw platform text.
     */
    @AuraEnabled
    public static void publishGoldenRecord(Id candidateId) {
        Duplicate_Candidate__c dc = [
            SELECT Id, Status__c, Merged_Article__c, Merged_Knowledge_Article_Id__c
            FROM Duplicate_Candidate__c
            WHERE Id = :candidateId
            LIMIT 1
        ];
        if (String.isBlank(dc.Merged_Article__c) || String.isBlank(dc.Merged_Knowledge_Article_Id__c)) {
            throw new AuraHandledException(
                'This candidate has no merged Golden Record to publish. Resolve it as a merge first.'
            );
        }

        // Resolve the merged draft's current publish status. If it is already
        // Online, treat as success (idempotent) and still run the reconciler so
        // any losers left behind by a prior native publish get archived now.
        Id mergedKavId;
        try { mergedKavId = Id.valueOf(dc.Merged_Article__c); }
        catch (Exception e) {
            throw new AuraHandledException('The Golden Record reference is invalid.');
        }
        List<Knowledge__kav> merged = [
            SELECT Id, KnowledgeArticleId, PublishStatus
            FROM Knowledge__kav
            WHERE Id = :mergedKavId
            WITH USER_MODE
            LIMIT 1
        ];
        if (merged.isEmpty()) {
            throw new AuraHandledException(
                'The Golden Record draft was deleted or is no longer accessible.'
            );
        }
        Knowledge__kav mergedKav = merged[0];

        try {
            if (KBPublishStatusHelper.isDraft(mergedKav.PublishStatus)) {
                publisher.publishArticle(mergedKav.KnowledgeArticleId, true);
            }
            // Run the same reconciler the retired trigger would have, keyed off
            // the now-Online Golden Record. Its primary effect here is
            // archiveMergedLosers — retiring the source articles merged into this
            // survivor. (The candidate itself is already 'Resolved' from merge
            // time, so the reconciler's Pending-scoped candidate close is a no-op
            // for it; the loser archiving is the work that was missing.)
            List<Id> failedArchiveIds = KBDuplicateCandidateReconciler.closeForPublishedArticles(
                new Set<Id>{ mergedKav.KnowledgeArticleId },
                new Set<Id>{ mergedKav.Id }
            );
            // The Golden Record is now published, but one or more source articles
            // could not be archived. Per-loser archiving is best-effort and never
            // rolls back the publish — but the caller must NOT be told "all
            // archived". Surface a partial-success error so the LWC shows the true
            // outcome rather than a false all-clear toast.
            //
            // The platform's archive failure is a single generic message covering
            // BOTH causes ("...valid for the current state of the article, and
            // that you have permission..."), so we can't tell them apart from the
            // string. Name both in the toast rather than blaming delete permission
            // alone — the most common cause here is a loser that still has an
            // unpublished draft (an in-progress Fix/edit), which blocks archiving
            // even when the user holds Knowledge delete.
            if (!failedArchiveIds.isEmpty()) {
                String friendly = 'Golden Record published, but '
                    + failedArchiveIds.size() + ' duplicate article(s) could not be '
                    + 'archived automatically — this can happen if an article still '
                    + 'has an unpublished draft (publish or discard it first), or if '
                    + 'you lack Knowledge delete permission. Archive them manually if '
                    + 'needed. The merge itself is complete.';
                AuraHandledException partial = new AuraHandledException(friendly);
                partial.setMessage(friendly);
                throw partial;
            }
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            String raw = e.getMessage();
            String friendly = KBAccessErrorClassifier.isAccessDenial(raw)
                ? 'You do not have permission to publish this article. Ask an admin '
                    + 'to assign the KB Knowledge Author permission set (Knowledge '
                    + 'create/edit/delete), then retry.'
                : 'Could not publish the Golden Record: ' + raw;
            AuraHandledException wrapped = new AuraHandledException(friendly);
            wrapped.setMessage(friendly); // survives Aura's client-side stripping
            throw wrapped;
        }
    }

    /**
 * @deprecated — superseded by markNotADuplicate. Retained as a thin
     * delegator so any external @AuraEnabled caller keeps working; the app's
     * own LWCs now call markNotADuplicate. Reason is forwarded.
     */
    @AuraEnabled
    public static void rejectCandidate(Id candidateId, String rejectionReason) {
        markNotADuplicate(candidateId, rejectionReason);
    }

    /**
 * @deprecated — superseded by markNotADuplicate. Retained as a thin
     * delegator (no reason on the suppress path historically).
     */
    @AuraEnabled
    public static void suppressCandidate(Id candidateId) {
        markNotADuplicate(candidateId, null);
    }

    @AuraEnabled
    public static void approveMerge(Id candidateId) {
        Tier4ConsolidationAction.consolidate(new List<Id>{ candidateId });
    }

    /**
 * keep-choice pair merge. keepChoice = 'create_new' (new Golden Record,
     * the default behaviour) or 'keep_survivor' (enrich survivorVersionId with
     * the other article as a new version + archive the loser on publish).
     */
    @AuraEnabled
    public static void approveMergeWithChoice(Id candidateId, String keepChoice, Id survivorVersionId) {
        if (Tier4ConsolidationAction.KEEP_SURVIVOR.equals(keepChoice) && survivorVersionId == null) {
            throw new AuraHandledException('Choose which article to keep before merging.');
        }
        Tier4ConsolidationAction.consolidate(new List<Id>{ candidateId }, keepChoice, survivorVersionId);
    }

    /**
     * Returns article details for side-by-side comparison.
     * Handles stale version IDs gracefully.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, ArticleDetail> getArticleComparison(
        String articleVersionIdA,
        String articleVersionIdB
    ) {
        Map<String, ArticleDetail> result = new Map<String, ArticleDetail>();

 // part 2 — degrade read (comparison sidebar). FLS-strip rather than
        // USER_MODE-throw: a reviewer lacking FLS on a field (e.g. Summary) should
        // still see the rest of the comparison card, not an error. buildArticleDetail
        // null-guards each field.
        List<Knowledge__kav> articles = (List<Knowledge__kav>) Security.stripInaccessible(
            AccessType.READABLE,
            [
                SELECT Id, KnowledgeArticleId, Title, Summary, ArticleNumber,
                       PublishStatus, VersionNumber, LastModifiedDate, LastModifiedBy.Name
                FROM Knowledge__kav
                WHERE Id IN (:articleVersionIdA, :articleVersionIdB)
            ]
        ).getRecords();

        Map<String, Knowledge__kav> articleById = new Map<String, Knowledge__kav>();
        for (Knowledge__kav art : articles) {
            articleById.put(art.Id, art);
        }

        result.put('articleA', buildArticleDetail(articleById.get(articleVersionIdA), articleVersionIdA));
        result.put('articleB', buildArticleDetail(articleById.get(articleVersionIdB), articleVersionIdB));

        return result;
    }

    private static ArticleDetail buildArticleDetail(Knowledge__kav article, String versionId) {
        ArticleDetail detail = new ArticleDetail();

        if (article != null) {
            detail.articleVersionId = article.Id;
            detail.knowledgeArticleId = article.KnowledgeArticleId;
            detail.title = article.Title;
            detail.summary = article.Summary;
            detail.articleNumber = article.ArticleNumber;
            detail.publishStatus = article.PublishStatus;
            detail.versionNumber = article.VersionNumber;
            detail.lastModifiedDate = article.LastModifiedDate;
            detail.lastModifiedBy = article.LastModifiedBy != null ? article.LastModifiedBy.Name : '';
        } else {
            detail.articleVersionId = versionId;
            detail.knowledgeArticleId = '';
            detail.title = 'Article not found (version may have changed)';
            detail.summary = 'The article version ID ' + versionId + ' is no longer available.';
            detail.articleNumber = '';
            detail.publishStatus = 'Unknown';
            detail.versionNumber = 0;
            detail.lastModifiedDate = null;
            detail.lastModifiedBy = '';
        }

        return detail;
    }

    /**
     * Returns a single ArticleDetail for the given version id. Used by the
     * hover popover in knowledgeAuditQueue — cheaper than getArticleComparison
     * when the UI only needs one side.
     */
    @AuraEnabled(cacheable=true)
    public static ArticleDetail getArticleDetail(String articleVersionId) {
        if (String.isBlank(articleVersionId)) {
            return buildArticleDetail(null, articleVersionId);
        }
        // FLS-strip rather than USER_MODE-throw, matching getArticleComparison: a
        // reviewer lacking FLS on a field (e.g. Summary) should still see the rest
        // of the detail, not an error. buildArticleDetail null-guards each field.
        List<Knowledge__kav> rows = (List<Knowledge__kav>) Security.stripInaccessible(
            AccessType.READABLE,
            [
                SELECT Id, KnowledgeArticleId, Title, Summary, ArticleNumber,
                       PublishStatus, VersionNumber, LastModifiedDate, LastModifiedBy.Name
                FROM Knowledge__kav
                WHERE Id = :articleVersionId
                LIMIT 1
            ]
        ).getRecords();
        return buildArticleDetail(rows.isEmpty() ? null : rows[0], articleVersionId);
    }

    /**
     * BFS over the pair graph starting from a seed candidate. Returns every
     * Pending candidate reachable within `depth` hops, excluding the seed
     * itself. Used by the cluster merge modal so the reviewer can tick
     * neighbors they also want to include in a cluster merge.
     *
     * Matches candidates by the master KnowledgeArticleId (not the version
     * id) — different pipeline runs capture different Knowledge__kav version
     * records for the same article, so only master-id matching finds the
     * real neighbors.
     *
     * Caps (all defensive): MAX_DEPTH=10, MAX_CANDIDATES=50, MAX_ARTICLES=20.
     */
    @AuraEnabled(cacheable=true)
    public static List<NeighborCandidate> getNeighborCandidates(Id seedCandidateId, Integer depth) {
        final Integer MAX_DEPTH = 10;
        final Integer MAX_CANDIDATES = 50;
        final Integer MAX_ARTICLES = 20;
        Integer safeDepth = (depth == null || depth < 1) ? 1 : Math.min(depth, MAX_DEPTH);

        List<Duplicate_Candidate__c> seedRows = [
            SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c
            FROM Duplicate_Candidate__c
            WHERE Id = :seedCandidateId
            LIMIT 1
        ];
        if (seedRows.isEmpty()) {
            return new List<NeighborCandidate>();
        }
        Duplicate_Candidate__c seed = seedRows[0];

        // Resolve every Knowledge__kav version id we encounter to its master
        // KnowledgeArticleId so we can match across pipeline runs.
        Map<Id, Id> versionToMaster = new Map<Id, Id>();
        Set<Id> seedVersionIds = new Set<Id>();
        if (seed.Knowledge_Article_1__c != null) seedVersionIds.add(Id.valueOf(seed.Knowledge_Article_1__c));
        if (seed.Knowledge_Article_2__c != null) seedVersionIds.add(Id.valueOf(seed.Knowledge_Article_2__c));
        for (Knowledge__kav kav : [
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :seedVersionIds
        ]) {
            versionToMaster.put(kav.Id, kav.KnowledgeArticleId);
        }

        Set<Id> knownMasterIds = new Set<Id>();
        for (Id v : seedVersionIds) {
            Id master = versionToMaster.get(v);
            if (master != null) knownMasterIds.add(master);
        }
        if (knownMasterIds.isEmpty()) {
            return new List<NeighborCandidate>();
        }

        Set<Id> visitedCandidateIds = new Set<Id>{ seed.Id };
        Map<Id, Integer> hopByCandidate = new Map<Id, Integer>();
        Map<Id, Duplicate_Candidate__c> foundByCandidate = new Map<Id, Duplicate_Candidate__c>();
        // Track all version ids ever encountered so the final article-number
        // lookup is bulkified.
        Set<Id> knownVersionIds = new Set<Id>(seedVersionIds);

        Set<Id> frontierMasters = new Set<Id>(knownMasterIds);
        for (Integer hop = 1; hop <= safeDepth; hop++) {
            if (frontierMasters.isEmpty() || foundByCandidate.size() >= MAX_CANDIDATES || knownMasterIds.size() >= MAX_ARTICLES) {
                break;
            }

            // Step 1 — every Knowledge__kav version record that belongs to
            // the master ids in the current frontier. This is what makes the
            // BFS work across pipeline runs.
            Set<Id> frontierVersionIds = new Set<Id>();
            for (Knowledge__kav kav : [
                SELECT Id, KnowledgeArticleId FROM Knowledge__kav
                WHERE KnowledgeArticleId IN :frontierMasters
            ]) {
                frontierVersionIds.add(kav.Id);
                versionToMaster.put(kav.Id, kav.KnowledgeArticleId);
            }
            if (frontierVersionIds.isEmpty()) {
                break;
            }

            // Step 2 — candidates touching any of those version ids.
            List<Duplicate_Candidate__c> hopRows = [
                SELECT Id, Name, Composite_Key__c, Confidence_Score__c,
                       Flag_Type__c, Source_Tier__c, AI_Reasoning__c,
                       Knowledge_Article_1__c, Knowledge_Article_2__c,
                       Article_1_Title__c, Article_2_Title__c
                FROM Duplicate_Candidate__c
                WHERE (Knowledge_Article_1__c IN :frontierVersionIds OR Knowledge_Article_2__c IN :frontierVersionIds)
                  AND Status__c = 'Pending'
                  AND Flag_Type__c != 'Contradiction'
                  AND Id NOT IN :visitedCandidateIds
                WITH USER_MODE
                ORDER BY Confidence_Score__c DESC
                LIMIT 200
            ];

            // Step 3 — resolve the NEW article versions we just saw to their masters
            // so we can (a) include them in the next frontier and (b) carry them into
            // the final article-number enrichment SOQL.
            Set<Id> newVersionsThisHop = new Set<Id>();
            for (Duplicate_Candidate__c dc : hopRows) {
                if (dc.Knowledge_Article_1__c != null) {
                    Id v = Id.valueOf(dc.Knowledge_Article_1__c);
                    if (!versionToMaster.containsKey(v)) newVersionsThisHop.add(v);
                }
                if (dc.Knowledge_Article_2__c != null) {
                    Id v = Id.valueOf(dc.Knowledge_Article_2__c);
                    if (!versionToMaster.containsKey(v)) newVersionsThisHop.add(v);
                }
            }
            if (!newVersionsThisHop.isEmpty()) {
                for (Knowledge__kav kav : [
                    SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :newVersionsThisHop
                ]) {
                    versionToMaster.put(kav.Id, kav.KnowledgeArticleId);
                }
            }

            Set<Id> nextFrontierMasters = new Set<Id>();
            for (Duplicate_Candidate__c dc : hopRows) {
                if (foundByCandidate.size() >= MAX_CANDIDATES) break;
                visitedCandidateIds.add(dc.Id);
                foundByCandidate.put(dc.Id, dc);
                hopByCandidate.put(dc.Id, hop);

                if (dc.Knowledge_Article_1__c != null) {
                    Id v = Id.valueOf(dc.Knowledge_Article_1__c);
                    knownVersionIds.add(v);
                    Id master = versionToMaster.get(v);
                    if (master != null && !knownMasterIds.contains(master) && knownMasterIds.size() < MAX_ARTICLES) {
                        knownMasterIds.add(master);
                        nextFrontierMasters.add(master);
                    }
                }
                if (dc.Knowledge_Article_2__c != null) {
                    Id v = Id.valueOf(dc.Knowledge_Article_2__c);
                    knownVersionIds.add(v);
                    Id master = versionToMaster.get(v);
                    if (master != null && !knownMasterIds.contains(master) && knownMasterIds.size() < MAX_ARTICLES) {
                        knownMasterIds.add(master);
                        nextFrontierMasters.add(master);
                    }
                }
            }
            frontierMasters = nextFrontierMasters;
        }

        // Enrich with ArticleNumber for every version id ever encountered.
        Map<Id, Knowledge__kav> articleMap = new Map<Id, Knowledge__kav>();
        if (!knownVersionIds.isEmpty()) {
            for (Knowledge__kav kav : [
                SELECT Id, ArticleNumber
                FROM Knowledge__kav
                WHERE Id IN :knownVersionIds
            ]) {
                articleMap.put(kav.Id, kav);
            }
        }

        List<NeighborCandidate> result = new List<NeighborCandidate>();
        for (Duplicate_Candidate__c dc : foundByCandidate.values()) {
            NeighborCandidate n = new NeighborCandidate();
            n.candidateId = dc.Id;
            n.candidateName = dc.Name;
            n.compositeKey = dc.Composite_Key__c;
            n.article1Id = dc.Knowledge_Article_1__c;
            n.article2Id = dc.Knowledge_Article_2__c;
            n.article1Title = dc.Article_1_Title__c;
            n.article2Title = dc.Article_2_Title__c;
            Knowledge__kav a1 = dc.Knowledge_Article_1__c == null ? null : articleMap.get(Id.valueOf(dc.Knowledge_Article_1__c));
            Knowledge__kav a2 = dc.Knowledge_Article_2__c == null ? null : articleMap.get(Id.valueOf(dc.Knowledge_Article_2__c));
            n.article1Number = a1 == null ? '' : a1.ArticleNumber;
            n.article2Number = a2 == null ? '' : a2.ArticleNumber;
            n.confidenceScore = dc.Confidence_Score__c;
            n.flagType = dc.Flag_Type__c;
            n.sourceTier = dc.Source_Tier__c;
            n.reasoning = dc.AI_Reasoning__c;
            n.hopDistance = hopByCandidate.get(dc.Id);
            result.add(n);
        }
        result.sort(new NeighborCandidateComparator());
        return result;
    }

    /**
     * Closes the implied cluster and enqueues a single-draft golden-record merge.
     * See Tier4ConsolidationAction.consolidateCluster for the closure logic.
     */
    @AuraEnabled
    public static void approveClusterMerge(List<Id> candidateIds) {
        if (candidateIds == null || candidateIds.isEmpty()) {
            throw new AuraHandledException('Select at least one candidate to merge.');
        }
        Tier4ConsolidationAction.consolidateCluster(candidateIds);
    }

    /**
 * keep-choice cluster merge. keepChoice = 'create_new' (single new
     * Golden Record) or 'keep_survivor' (enrich the chosen survivorVersionId
     * with the merged cluster content + archive the other members on publish).
     */
    @AuraEnabled
    public static void approveClusterMergeWithChoice(
        List<Id> candidateIds, String keepChoice, Id survivorVersionId
    ) {
        if (candidateIds == null || candidateIds.isEmpty()) {
            throw new AuraHandledException('Select at least one candidate to merge.');
        }
        if (Tier4ConsolidationAction.KEEP_SURVIVOR.equals(keepChoice) && survivorVersionId == null) {
            throw new AuraHandledException('Choose which article to keep before merging.');
        }
        Tier4ConsolidationAction.consolidateCluster(candidateIds, keepChoice, survivorVersionId);
    }

    /**
     * Deletes the Duplicate_Candidate__c record(s) for a pair so it re-evaluates
 * on the next pipeline run. `runId` scopes the delete to a single
     * assessment run — candidates are run-scoped (each run has its own row for the
     * same version pair), so an un-scoped delete would wipe OTHER runs' rows for
     * the pair (incl. their triaged Resolved/Error audit rows). Pass null for the
     * run-agnostic behaviour. Single method, not an overload — @AuraEnabled forbids
 * overloading. (Kept though retired the UI affordance — still Apex-reachable.)
     */
    @AuraEnabled
    public static void forceReEvaluate(String articleVersionIdA, String articleVersionIdB, String runId) {
        // Match on the article-version pointers, not Composite_Key__c: the key is
        // run-scoped (assessmentRunId + pair), so a run-agnostic key string would
        // no longer match. Matching on the pair (either ordering) deletes the
        // candidate so it re-evaluates on the next run.
        Id runIdSafe = parseOptionalId(runId);
        List<Duplicate_Candidate__c> cached;
        if (runIdSafe != null) {
            cached = [
                SELECT Id FROM Duplicate_Candidate__c
                WHERE Assessment_Run__c = :runIdSafe
                AND ((Knowledge_Article_1__c = :articleVersionIdA AND Knowledge_Article_2__c = :articleVersionIdB)
                  OR (Knowledge_Article_1__c = :articleVersionIdB AND Knowledge_Article_2__c = :articleVersionIdA))
            ];
        } else {
            cached = [
                SELECT Id FROM Duplicate_Candidate__c
                WHERE (Knowledge_Article_1__c = :articleVersionIdA AND Knowledge_Article_2__c = :articleVersionIdB)
                   OR (Knowledge_Article_1__c = :articleVersionIdB AND Knowledge_Article_2__c = :articleVersionIdA)
            ];
        }

        if (!cached.isEmpty()) {
            delete cached;
        }
    }

    /**
     * Resolves a Contradiction candidate. Three outcomes:
     *  - 'article_a_correct' / 'article_b_correct': marks the other article with a
     *    Conflict recommendation to review/correct it.
     *  - 'both_valid_different_scope': both are correct but need clearer scoping —
     *    creates a recommendation on BOTH articles.
     *
 * NOTE: the 'needs_sme' ("Needs SME review") outcome was RETIRED — it
     * only set Status='Resolved' with no recommendation/task/flag/routing, so it
     * behaved exactly like a dismiss (a no-op). It can be reintroduced once there
     * is a real routing target (a review queue, an assigned owner, or an
     * assignment rule). Until then the modal offers only the three actionable
     * outcomes above.
     */
    @AuraEnabled
    public static void resolveContradiction(Id candidateId, String correctArticleId, String resolution) {
 // reject the retired SME outcome explicitly rather than silently
        // no-op'ing (which is what made it indistinguishable from dismiss).
        if (resolution == 'needs_sme') {
            throw new AuraHandledException(
                'The "Needs SME review" outcome has been retired. Choose Article A correct, '
                + 'Article B correct, or Both valid (different scope).'
            );
        }

        try {
            Duplicate_Candidate__c dc = [
                SELECT Id, Status__c, Knowledge_Article_1__c, Knowledge_Article_2__c,
                       Article_1_Title__c, Article_2_Title__c, AI_Reasoning__c
                FROM Duplicate_Candidate__c
                WHERE Id = :candidateId
                LIMIT 1
            ];

            // Update a minimal-shape record, NOT the hydrated dc. USER_MODE validates
            // EDIT access on every populated field, and dc carries read-only display
            // fields (Article_*_Title__c, AI_Reasoning__c) that the Manager persona
            // holds read-only — updating dc itself throws "fields inaccessible". Only
            // Status__c + Rejection_Reason__c are writable here (mirrors
            // markNotADuplicate). dc stays in scope, read-only, for the strings below.
            update as user new Duplicate_Candidate__c(
                Id = dc.Id,
                Status__c = 'Resolved',
                Rejection_Reason__c = resolution
            );

            List<KB_Dimension_Analysis__c> rows = new List<KB_Dimension_Analysis__c>();

            if (resolution == 'both_valid_different_scope') {
                ConflictTarget targetA = findConflictTarget(dc.Knowledge_Article_1__c);
                ConflictTarget targetB = findConflictTarget(dc.Knowledge_Article_2__c);

                if (targetA != null) {
                    rows.add(buildConflictAnalysis(
                        targetA,
                        'This article overlaps in scope with "'
                            + dc.Article_2_Title__c + '" but provides different information. '
                            + 'Clarify the intended audience or use case to avoid confusion. '
                            + 'AI reasoning: ' + dc.AI_Reasoning__c
                    ));
                }
                if (targetB != null) {
                    rows.add(buildConflictAnalysis(
                        targetB,
                        'This article overlaps in scope with "'
                            + dc.Article_1_Title__c + '" but provides different information. '
                            + 'Clarify the intended audience or use case to avoid confusion. '
                            + 'AI reasoning: ' + dc.AI_Reasoning__c
                    ));
                }
            } else {
                // One article is correct, the other needs fixing
                String incorrectArticleId = correctArticleId == dc.Knowledge_Article_1__c
                    ? dc.Knowledge_Article_2__c
                    : dc.Knowledge_Article_1__c;
                String correctTitle = correctArticleId == dc.Knowledge_Article_1__c
                    ? dc.Article_1_Title__c
                    : dc.Article_2_Title__c;

                ConflictTarget target = findConflictTarget(incorrectArticleId);
                if (target != null) {
                    rows.add(buildConflictAnalysis(
                        target,
                        'This article contradicts "'
                            + correctTitle + '". Review and correct the conflicting information. '
                            + 'AI reasoning: ' + dc.AI_Reasoning__c
                    ));
                }
            }

            if (!rows.isEmpty()) {
                insert as user rows;
            }
        } catch (AuraHandledException ahe) {
            // Already-friendly (e.g. the needs_sme guard above) — preserve as-is.
            throw ahe;
        } catch (Exception e) {
            // A USER_MODE CRUD/FLS denial here surfaces raw platform text
            // ("fields ... inaccessible", "insufficient access", ...) which reads
            // like a bug in kbResolveContradictionModal's inline alert. Translate
            // it into actionable guidance naming the persona — mirrors
 // KBImprovementFixFacade.toFriendly / Tier4ConsolidationAction.
            String raw = e.getMessage();
            String friendly;
            if (KBAccessErrorClassifier.isAccessDenial(raw)) {
                friendly = 'You do not have permission to resolve this contradiction. '
                    + 'Ask an admin to assign the KB Assessment Manager permission set '
                    + '(edit access on Duplicate Candidate status and the Conflict '
                    + 'recommendation fields), then retry.';
            } else {
                friendly = 'Could not resolve the contradiction: ' + raw;
            }
            AuraHandledException wrapped = new AuraHandledException(friendly);
            wrapped.setMessage(friendly); // survives Aura's client-side stripping
            throw wrapped;
        }
    }

    private class ConflictTarget {
        Id assessmentId;
        Id dimensionResultId;
    }

    /**
     * Locate the latest article assessment for the given article version and
     * its Conflict dimension result row. Both Ids are required: the analysis
     * row is master-detail on KB_Dimension_Result__c. If a Conflict dimension
     * row doesn't exist on the latest assessment yet, returns null — caller
     * skips the recommendation rather than orphaning it.
     */
    private static ConflictTarget findConflictTarget(String articleVersionId) {
        Id assessmentId = findLatestAssessment(articleVersionId);
        if (assessmentId == null) return null;
        List<KB_Dimension_Result__c> results = [
            SELECT Id FROM KB_Dimension_Result__c
            WHERE Article_Assessment__c = :assessmentId
              AND Dimension__c = 'Conflict'
            LIMIT 1
        ];
        if (results.isEmpty()) return null;
        ConflictTarget target = new ConflictTarget();
        target.assessmentId = assessmentId;
        target.dimensionResultId = results[0].Id;
        return target;
    }

    private static KB_Dimension_Analysis__c buildConflictAnalysis(
        ConflictTarget target,
        String recommendation
    ) {
 // Impact-only severity: Priority__c / Effort__c are no longer
        // written on the pipeline (Conflict) path. Impact is annotated
        // asynchronously by KBSeverityAnnotationQueueable when present; these
        // human-resolution rows leave it null (the inbox shows no Impact badge).
        return new KB_Dimension_Analysis__c(
            Article_Assessment__c = target.assessmentId,
            Dimension_Result__c   = target.dimensionResultId,
            Type__c               = KBDimensionAnalysisService.TYPE_ISSUE,
            Dimension__c          = 'Conflict',
            Recommendation__c     = recommendation,
            Status__c             = 'Open'
        );
    }

    private static Id findLatestAssessment(String articleVersionId) {
        List<KB_Article_Assessment__c> assessments = [
            SELECT Id FROM KB_Article_Assessment__c
            WHERE Knowledge__c = :articleVersionId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return assessments.isEmpty() ? null : assessments[0].Id;
    }

    public class ArticleDetail {
        @AuraEnabled public String articleVersionId;
        @AuraEnabled public String knowledgeArticleId;
        @AuraEnabled public String title;
        @AuraEnabled public String summary;
        @AuraEnabled public String articleNumber;
        @AuraEnabled public String publishStatus;
        @AuraEnabled public Integer versionNumber;
        @AuraEnabled public Datetime lastModifiedDate;
        @AuraEnabled public String lastModifiedBy;
    }

    public class NeighborCandidate {
        @AuraEnabled public Id candidateId;
        @AuraEnabled public String candidateName;
        @AuraEnabled public String compositeKey;
        @AuraEnabled public Id article1Id;
        @AuraEnabled public Id article2Id;
        @AuraEnabled public String article1Title;
        @AuraEnabled public String article2Title;
        @AuraEnabled public String article1Number;
        @AuraEnabled public String article2Number;
        @AuraEnabled public Decimal confidenceScore;
        @AuraEnabled public String flagType;
        @AuraEnabled public String sourceTier;
        @AuraEnabled public String reasoning;
        @AuraEnabled public Integer hopDistance;
    }

    private class NeighborCandidateComparator implements Comparator<NeighborCandidate> {
        public Integer compare(NeighborCandidate a, NeighborCandidate b) {
            Integer hopA = a.hopDistance == null ? 9999 : a.hopDistance;
            Integer hopB = b.hopDistance == null ? 9999 : b.hopDistance;
            if (hopA != hopB) {
                return hopA < hopB ? -1 : 1;
            }
            Decimal scoreA = a.confidenceScore == null ? -1 : a.confidenceScore;
            Decimal scoreB = b.confidenceScore == null ? -1 : b.confidenceScore;
            if (scoreA == scoreB) return 0;
            return scoreA > scoreB ? -1 : 1;
        }
    }
}
