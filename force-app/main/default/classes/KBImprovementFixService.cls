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
 * Orchestration for AI-powered article fixes driven by KB_Dimension_Analysis__c issues.
 *
 * Layer: Service (between facade and scorers/data — see CLAUDE.md "5-layer service stack").
 * Callers:
 *   - `KBImprovementFixFacade` (LWC + AuraEnabled entry point — canonical caller)
 *   - `KBFixArticleQueueable` / `KBFixArticleBatch` (async wrappers for bulk dispatch)
 *
 * Flow per request:
 *   1. Lock the recommendations under FOR UPDATE and assert they are still 'Open'.
 *      If zero rows return, the dispatch was already in flight — bail out without
 *      calling the LLM (prevents double-billing on rapid double-clicks; finding C1).
 *   2. Resolve content fields via `KBAssessmentService.getContentFields` (single
 *      source of truth; finding AR3).
 *   3. Resolve effective version when `useCurrentOnline=true` so stale stored
 *      version Ids don't break the fetch or persist.
 *   4. Fetch the article + selected fields, build LLM payload, call `Fix_Article_Issues`.
 *   5. Persist Draft via `KBKavDraftWriter` (`with sharing` + USER_MODE — enforces
 * the running user's Knowledge CRUD/FLS/sharing,; see that class).
 *   6. Upsert `Enrichment_Candidate__c` (master-detail to the assessment run, so
 *      visibility is controlled-by-parent — no explicit sharing needed).
 *   7. Mark the recs Resolved (or Error on failure).
 *
 * This class is internal-only — there is no `@AuraEnabled` surface. All
 * external entry (LWC, future Agentforce action) routes through
 * `KBImprovementFixFacade`. The async wrappers (`KBFixArticleQueueable`,
 * `KBFixArticleBatch`) are private orchestration plumbing invoked from
 * `dispatchArticleFixesBulkInternal` only.
 */
public with sharing class KBImprovementFixService {

    /**
     * Per-article fix request used by both single-shot and bulk dispatch.
     *
     * `pipelineRunId` is optional — when present, the queueable/batch wrappers
     * publish `KB_Assessment_Progress__e` events tagged with this id so the LWC
     * can subscribe via `lightning/empApi` (finding AR2).
     */
    public class BulkFixRequest {
        @AuraEnabled public String       articleVersionId  { get; set; }
        @AuraEnabled public Boolean      useCurrentOnline  { get; set; }
        @AuraEnabled public List<Id>     recIds            { get; set; }
        @AuraEnabled public List<String> issueDescriptions { get; set; }
        @AuraEnabled public Id           pipelineRunId     { get; set; }
    }

    /**
     * Result returned by the bulk dispatch path. Exposes the Pipeline Run Id so
     * the LWC can subscribe to `KB_Assessment_Progress__e` for it (finding AR2).
     */
    public class BulkDispatchResult {
        @AuraEnabled public Id pipelineRunId { get; set; }
    }

    /**
     * Test seam: when set to true, `dispatchArticleFixesBulkInternal` skips
     * the actual `Database.executeBatch` call and only stamps the pipeline
     * run row. Salesforce test context limits batch iterables to chunk size,
     * so a 501-request iterable at chunk size 10 raises "No more than one
     * executeBatch can be called". The branch-coverage test for the Batch
     * path uses this seam to verify the dispatcher CHOICE without actually
     * running the batch — production behaviour is exercised by
     * `KBFixArticleAsyncTest.testBatch_HappyPath_*`.
     */
    @TestVisible
    private static Boolean suppressBatchEnqueueForTest = false;

    // ──────────────────────────────────────────────────────────────────────────
    // Orchestration entry — single-article (called by facade and async wrappers)
    // ──────────────────────────────────────────────────────────────────────────

    public static void dispatchArticleFixInternal(
        String       articleVersionId,
        Boolean      useCurrentOnline,
        List<Id>     recIds,
        List<String> issueDescriptions
    ) {
        dispatchArticleFixInternal(articleVersionId, useCurrentOnline, recIds, issueDescriptions, null);
    }

    /**
     * Overload that accepts a Pipeline Run Id. The async wrappers use this
     * variant to thread observability through the run.
     */
    public static void dispatchArticleFixInternal(
        String       articleVersionId,
        Boolean      useCurrentOnline,
        List<Id>     recIds,
        List<String> issueDescriptions,
        Id           pipelineRunId
    ) {
        if (String.isBlank(articleVersionId) || recIds == null || recIds.isEmpty()
                || issueDescriptions == null || issueDescriptions.isEmpty()) {
            throw new AuraHandledException('articleVersionId, recIds, and issueDescriptions are required.');
        }

        // C1: lock the recommendation rows and only proceed for those still 'Open'.
        // If a parallel dispatch already flipped them to Queued/Resolved/Error, the
        // SELECT-FOR-UPDATE returns zero rows and we bail out before any LLM call.
        List<Id> lockedRecIds = lockOpenRecsForUpdate(recIds);
        if (lockedRecIds.isEmpty()) {
            return;
        }

        // 1. Mark locked analyses as Queued (single SOQL+DML, holds the lock until commit).
        List<KB_Dimension_Analysis__c> toQueue = new List<KB_Dimension_Analysis__c>();
        for (Id recId : lockedRecIds) {
            toQueue.add(new KB_Dimension_Analysis__c(Id = recId, Status__c = 'Queued'));
        }
        update toQueue;

        try {
            // 2. Resolve content fields (AR3 — single source of truth).
            List<String> contentFields = KBAssessmentService.getContentFields('Knowledge__kav');

            // 3. Resolve effective version: when "published" path, always resolve the
            //    current Online version from the article's KnowledgeArticleId so that
            //    stale/archived stored version Ids don't break the fetch or persist.
            String effectiveVersionId = articleVersionId;
            if (useCurrentOnline == true) {
                List<Knowledge__kav> sourceRow = Database.queryWithBinds(
                    'SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :vid',
                    new Map<String, Object>{ 'vid' => articleVersionId },
                    AccessLevel.USER_MODE
                );
                if (!sourceRow.isEmpty()) {
                    String kaId = sourceRow[0].KnowledgeArticleId;
                    List<Knowledge__kav> online = Database.queryWithBinds(
                        'SELECT Id FROM Knowledge__kav '
                        + 'WHERE KnowledgeArticleId = :kaId AND PublishStatus = \'Online\' LIMIT 1',
                        new Map<String, Object>{ 'kaId' => kaId },
                        AccessLevel.USER_MODE
                    );
                    if (!online.isEmpty()) effectiveVersionId = online[0].Id;
                }
            }

            // 4. Fetch article with those fields
            Knowledge__kav article = fetchArticle(effectiveVersionId, contentFields);

 // archived (or otherwise non-writable) articles cannot be
            // fixed — the platform rejects an update on a non-Draft KAV with
            // FIELD_INTEGRITY_EXCEPTION ("Only draft articles can be updated").
            // Guard here so the user gets a clear, actionable message instead
            // of a raw platform error, and the bulk path is covered too.
            if (!KBPublishStatusHelper.isFixable(article.PublishStatus)) {
                throw new AuraHandledException(
                    'Cannot fix an archived article — unarchive it (or publish a new version) first.'
                );
            }

            // Build field-keyed maps for the LLM
            Map<String, String>  articleFields = buildArticleFields(article, contentFields);
            Map<String, Integer> fieldLimits   = buildFieldLimits(contentFields);
            String issuesList    = buildIssuesList(issueDescriptions);
            String strengthsList = buildStrengthsList(lockedRecIds);
            String language      = String.isNotBlank(article.Language) ? article.Language : 'en';

            // 5. Call Fix_Article_Issues prompt — LLM rewrites all fields in one pass.
            //    Strengths from the same article assessment are passed alongside issues so
            //    the LLM preserves dimensions that already passed assessment.
            PromptTemplateService pts = PromptTemplateService.getInstance();
            PromptTemplateService.FixArticleResult fixResult =
                pts.fixArticleIssues(articleFields, fieldLimits, issuesList, strengthsList, language);

            if (fixResult.rewrittenFields == null || fixResult.rewrittenFields.isEmpty()) {
                throw new KnowledgeAIException('LLM returned no rewritten fields.');
            }

            // 6. Persist as a Draft version and create an Enrichment Candidate for review.
            //    Pass effectiveVersionId as the source reference so the candidate correctly
            //    points to the version that was actually read (not the original stored Id).
            //    C8: subsumed by C1 — the recs are locked under FOR UPDATE for the duration
            //    of this transaction, so two callers can't both race past `findExistingDraft`
            //    and both call editOnlineArticle. Whichever caller wins the lock proceeds;
            //    the other returns early at the top of this method.
            Id draftVersionId = persistDraft(article, fixResult.rewrittenFields);
 // resolve the assessment run that produced the recs being
            // fixed, so the candidate is traceable back to its run (enables
 // filter-by-run in the Suggested Drafts inbox + cascade cleanup).
            Id assessmentRunId = resolveAssessmentRun(lockedRecIds);
            createEnrichmentCandidate(article, effectiveVersionId, draftVersionId, fixResult.changesSummary, issueDescriptions, assessmentRunId);

            // 7. Mark recommendations Resolved
            markRecsStatus(lockedRecIds, 'Resolved');

        } catch (Exception e) {
            markRecsStatus(lockedRecIds, 'Error');
            // Re-throw the original. The facade wraps for the LWC surface
            // (with setMessage so Aura doesn't strip it). The queueable/batch
            // wrappers catch the original cause and log it for debug visibility.
            // (Finding 5 — AHE wrap moved from service to facade.)
            throw e;
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Bulk dispatch — fan out to Queueable (≤ 50) or Batch (> 50)
    // ──────────────────────────────────────────────────────────────────────────
 // the Queueable path self-chains in chunks of CHUNK (10) and the
    // platform caps chained enqueues at 5, so it can only ever process 5×10 = 50
    // articles before silently dropping the tail. Route anything above 50 to
    // KBFixArticleBatch (Batch Apex — no chain-depth limit). The threshold was
    // 500, which meant a 51–500-article "Fix Selected" hit the 50 ceiling and
    // silently lost articles. Now that the paginated inbox lets a user select
    // more than 50, this ceiling is reachable, so the fix matters.
    private static final Integer QUEUEABLE_MAX_REQUESTS = 50;

    public static BulkDispatchResult dispatchArticleFixesBulkInternal(List<BulkFixRequest> requests) {
        BulkDispatchResult result = new BulkDispatchResult();
        if (requests == null || requests.isEmpty()) {
            return result;
        }

        // AR2: create a KB_Pipeline_Run__c row tagged with Execution_Modes__c
        // = 'AI Fix' so the dispatched chunks can publish KB_Assessment_Progress__e
        // events and the LWC can subscribe via lightning/empApi. 'AI Fix' coexists
        // with the 'DEDUPLICATION' value on the multiselect picklist; existing
        // consumers use `.contains('DEDUPLICATION')` so adding the value is
        // non-breaking.
        Id pipelineRunId = createAIFixPipelineRun(requests.size());
        for (BulkFixRequest req : requests) {
            req.pipelineRunId = pipelineRunId;
        }
        result.pipelineRunId = pipelineRunId;

        if (requests.size() <= QUEUEABLE_MAX_REQUESTS) {
            System.enqueueJob(new KBFixArticleQueueable(requests, 0));
        } else if (!suppressBatchEnqueueForTest) {
            Database.executeBatch(new KBFixArticleBatch(requests), 10);
        }
        return result;
    }

    /**
     * Publishes a single `KB_Assessment_Progress__e` event for the bulk run.
     * Called from the queueable and batch wrappers on completion of each chunk
     * and on terminal completion.
     *
     * Errors are swallowed — the platform-event publish is observability,
     * not a load-bearing path. If it fails, the LWC falls back to polling.
     */
    public static void publishFixProgress(
        Id pipelineRunId,
        Integer processedArticles,
        Integer totalArticles,
        Integer errorCount,
        String status,
        String message
    ) {
        if (pipelineRunId == null) return;
        try {
            KB_Assessment_Progress__e evt = new KB_Assessment_Progress__e(
                Assessment_Id__c = pipelineRunId,
                Status__c = status,
                Articles_Processed__c = processedArticles,
                Total_Articles__c = totalArticles,
                Message__c = message != null && message.length() > 255 ? message.substring(0, 255) : message
            );
            EventBus.publish(evt);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Failed to publish AI Fix progress event: ' + e.getMessage());
        }
    }

    /**
     * Marks the AI Fix pipeline run as Completed and stamps Completed_At__c
     * + Error_Count__c. Called from the queueable's terminal chunk and from
     * the batch's `finish`. No-op when pipelineRunId is null (single-shot path).
     */
    public static void completeAIFixPipelineRun(Id pipelineRunId, Integer errorCount) {
        if (pipelineRunId == null) return;
        try {
            update new KB_Pipeline_Run__c(
                Id              = pipelineRunId,
                Status__c       = errorCount != null && errorCount > 0 ? 'Partial' : 'Completed',
                Error_Count__c  = errorCount,
                Completed_At__c = System.now()
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Failed to complete AI Fix pipeline run: ' + e.getMessage());
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * C1 implementation. Selects the recs FOR UPDATE filtered by Status__c='Open'
     * so any concurrent transaction that already moved them past Open is shut out.
     * Returns the still-Open ids; empty list signals "another caller already
     * dispatched these — do not call the LLM".
     */
    private static List<Id> lockOpenRecsForUpdate(List<Id> recIds) {
        List<KB_Dimension_Analysis__c> locked = [
            SELECT Id
            FROM KB_Dimension_Analysis__c
            WHERE Id IN :recIds
              AND Status__c = 'Open'
            FOR UPDATE
        ];
        List<Id> ids = new List<Id>();
        for (KB_Dimension_Analysis__c r : locked) {
            ids.add(r.Id);
        }
        return ids;
    }

    private static Id createAIFixPipelineRun(Integer articleCount) {
        try {
            KB_Pipeline_Run__c run = new KB_Pipeline_Run__c(
                Execution_Modes__c      = 'AI Fix',
                Status__c               = 'Queued',
                Started_At__c           = System.now(),
                Total_Input_Articles__c = articleCount,
                Triggered_By__c         = UserInfo.getUserId(),
                Scope_Type__c           = 'Selected'
            );
            insert run;
            return run.Id;
        } catch (Exception e) {
            // Observability is best-effort — never fail the dispatch because we
            // couldn't insert a pipeline run row.
            System.debug(LoggingLevel.WARN, 'Failed to create AI Fix pipeline run: ' + e.getMessage());
            return null;
        }
    }

    private static Knowledge__kav fetchArticle(String articleId, List<String> contentFields) {
        // Build SELECT with base fields + content fields (deduped)
        Set<String> baseFields = new Set<String>{
            'Id', 'Title', 'Language', 'KnowledgeArticleId', 'VersionNumber', 'PublishStatus'
        };
        List<String> selectFields = new List<String>(baseFields);
        for (String cf : contentFields) {
            if (!baseFields.contains(cf)) {
                selectFields.add(cf);
            }
        }
        String soql = 'SELECT ' + String.join(selectFields, ', ')
            + ' FROM Knowledge__kav WHERE Id = :articleId LIMIT 1';

        List<Knowledge__kav> articles = Database.queryWithBinds(
            soql,
            new Map<String, Object>{ 'articleId' => articleId },
            AccessLevel.USER_MODE
        );
        if (articles.isEmpty()) {
            throw new KnowledgeAIException('Article not found: ' + articleId);
        }
        return articles[0];
    }

    private static Map<String, String> buildArticleFields(Knowledge__kav article, List<String> contentFields) {
        Map<String, String> m = new Map<String, String>();
        m.put('Title', article.Title ?? '');
        for (String field : contentFields) {
            Object val = article.get(field);
            if (val != null) m.put(field, String.valueOf(val));
        }
        return m;
    }

    private static Map<String, Integer> buildFieldLimits(List<String> contentFields) {
        Map<String, Schema.SObjectField> kavFields = Schema.SObjectType.Knowledge__kav.fields.getMap();
        Map<String, Integer> limits = new Map<String, Integer>();
        limits.put('Title', 255);
        for (String field : contentFields) {
            Schema.SObjectField sof = kavFields.get(field.toLowerCase());
            if (sof != null) {
                Integer len = sof.getDescribe().getLength();
                limits.put(field, len > 0 ? len : 131072);
            }
        }
        return limits;
    }

    private static String buildIssuesList(List<String> issues) {
        List<String> numbered = new List<String>();
        for (Integer i = 0; i < issues.size(); i++) {
            numbered.add((i + 1) + '. ' + issues[i]);
        }
        return String.join(numbered, '\n');
    }

    /**
     * Collect strengths from the same article assessments as the selected issue
     * recommendations. Strengths are KB_Dimension_Analysis__c rows with
     * Type__c = 'Strength' — they describe qualities the article already has,
     * so the LLM should preserve them when rewriting fields to fix the listed
     * issues.
     *
     * CV4: collapsed from two SOQL queries against KB_Dimension_Analysis__c
     * (which Apex does not allow as a same-object semi-join) into a single
     * SELECT against KB_Article_Assessment__c with a child subquery for the
     * strengths. The outer is on a different object, so the semi-join is legal.
     */
    private static String buildStrengthsList(List<Id> recIds) {
        List<KB_Article_Assessment__c> parents = [
            SELECT Id, (
                SELECT Dimension__c, Analysis_Text__c
                FROM Dimension_Analyses__r
                WHERE Type__c = 'Strength'
                ORDER BY Dimension__c, CreatedDate
            )
            FROM KB_Article_Assessment__c
            WHERE Id IN (
                SELECT Article_Assessment__c
                FROM KB_Dimension_Analysis__c
                WHERE Id IN :recIds
            )
            WITH USER_MODE
        ];

        List<String> numbered = new List<String>();
        for (KB_Article_Assessment__c parent : parents) {
            for (KB_Dimension_Analysis__c s : parent.Dimension_Analyses__r) {
                // Long-text fields can't be filtered in SOQL — skip blanks here.
                if (String.isBlank(s.Analysis_Text__c)) continue;
                String prefix = String.isNotBlank(s.Dimension__c) ? '[' + s.Dimension__c + '] ' : '';
                numbered.add((numbered.size() + 1) + '. ' + prefix + s.Analysis_Text__c);
            }
        }
        return String.join(numbered, '\n');
    }

    private static Id findExistingDraft(Id knowledgeArticleId, Id excludeVersionId) {
        List<Knowledge__kav> drafts = Database.queryWithBinds(
            'SELECT Id FROM Knowledge__kav '
            + 'WHERE KnowledgeArticleId = :knowledgeArticleId '
            + 'AND PublishStatus = \'Draft\' '
            + 'AND Id != :excludeVersionId '
            + 'LIMIT 1',
            new Map<String, Object>{
                'knowledgeArticleId' => knowledgeArticleId,
                'excludeVersionId'   => excludeVersionId
            },
            AccessLevel.USER_MODE
        );
        return drafts.isEmpty() ? null : drafts[0].Id;
    }

    private static Id persistDraft(
        Knowledge__kav source,
        Map<String, String> rewrittenFields
    ) {
        Map<String, Schema.SObjectField> kavFields =
            Schema.SObjectType.Knowledge__kav.fields.getMap();

        // Resolve a writable draft version Id:
        // - If a Draft version already exists for this article, use it.
        // - Else if the article is Online, create a new draft via the publishing API.
        // - Else (already Draft) use the source version directly.
        Id draftVersionId = findExistingDraft(source.KnowledgeArticleId, source.Id);
        if (draftVersionId == null) {
            if (KBPublishStatusHelper.isOnline(source.PublishStatus)) {
                draftVersionId = KbManagement.PublishingService.editOnlineArticle(
                    source.KnowledgeArticleId, false
                );
            } else if (KBPublishStatusHelper.isDraft(source.PublishStatus)) {
                draftVersionId = source.Id;
            } else {
                // Defence-in-depth: dispatchArticleFixInternal already guards
                // with isFixable, but persistDraft is reachable from other call
                // sites — never write into an archived/unknown-status version
 // (the platform would throw FIELD_INTEGRITY_EXCEPTION)..
                throw new KnowledgeAIException(
                    'Cannot persist a draft for article in PublishStatus \''
                    + source.PublishStatus + '\' — only Online or Draft versions are writable.'
                );
            }
        }

        Knowledge__kav draft = new Knowledge__kav(Id = draftVersionId);
        // Count CONTENT fields written (everything except Title). Title is
        // gated through the same isUpdateable() FLS check as content fields —
        // NOT special-cased — for two reasons:
 // (a) under the USER_MODE write, assigning an un-editable Title
        //      would throw the whole update, defeating per-field graceful
        //      degradation; and
        //  (b) Title is a standard field the LLM almost always returns and the
        //      user commonly has FLS on, so if it counted toward the guard a
        //      user with Title FLS but NO content-field FLS would slip past the
        //      guard — Title updated, body never rewritten, rec marked Resolved
 // (the exact silent success targets). The recommendations are
        //      body/content issues, so "did the fix actually happen?" is
        //      measured by content fields, not Title.
        Integer contentFieldsWritten = 0;
        for (String fieldName : rewrittenFields.keySet()) {
            String val = rewrittenFields.get(fieldName);
            if (val == null) continue;
            Schema.SObjectField sof = kavFields.get(fieldName.toLowerCase());
            if (sof == null) continue;
            Schema.DescribeFieldResult dfr = sof.getDescribe();
            // Pre-filter fields the user can't edit so one missing-FLS content
            // field degrades gracefully (others still write) rather than the
            // whole USER_MODE update throwing. The writer's USER_MODE DML is the
 // actual CRUD/FLS enforcement now — this is belt-and-braces.
            if (!dfr.isUpdateable()) continue;
            Integer maxLen = dfr.getLength() > 0 ? dfr.getLength() : 131072;
            draft.put(fieldName, val.length() > maxLen ? val.left(maxLen) : val);
            if (fieldName != 'Title') contentFieldsWritten++;
        }

 // the isUpdateable skip above is graceful degradation — one
        // missing-FLS content field shouldn't fail the whole rewrite. But if
        // NO content field survived the filter, the article body was never
        // rewritten (at most Title changed). Writing that draft is a successful
        // DML, so the caller would mark the recommendation Resolved with the
        // issue unaddressed — a silent success. Fail loudly instead so the rec
        // is stamped Error (retryable) with an actionable FLS message. This is
        // the narrow object-write-yes / all-content-FLS-no case, distinct from
 // the object-CRUD block where USER_MODE DML throws outright.
        if (contentFieldsWritten == 0) {
            throw new KnowledgeAIException(
                'You can edit the article but not its content fields — the AI '
                + 'rewrite was not saved. Grant the running user Field-Level '
                + 'Security (Edit) on the fields configured in your Content Scope '
                + '(Setup Wizard, Step 2), then retry.'
            );
        }

        new KBKavDraftWriter().writeDraft(draft);
        return draftVersionId;
    }

    /**
 * resolve the single assessment run behind the recs being fixed.
     * A rec (KB_Dimension_Analysis__c) → Article_Assessment__c →
     * KB_Article_Assessment__c.Assessment_Run__c. The Improvements Inbox only
     * ever surfaces recs from the latest assessment per article, so a given
     * fix dispatch is single-run by construction; if recs somehow span more
     * than one run we take the most recent (max by run CreatedDate). Returns
     * null when it can't be resolved (leaves the lookup blank — non-fatal).
     */
    private static Id resolveAssessmentRun(List<Id> recIds) {
        if (recIds == null || recIds.isEmpty()) return null;
        Id latestRunId = null;
        Datetime latestCreated = null;
        Set<Id> distinctRunIds = new Set<Id>();
        for (KB_Dimension_Analysis__c rec : [
            SELECT Article_Assessment__r.Assessment_Run__c,
                   Article_Assessment__r.Assessment_Run__r.CreatedDate
            FROM KB_Dimension_Analysis__c
            WHERE Id IN :recIds
              AND Article_Assessment__r.Assessment_Run__c != null
            WITH USER_MODE
        ]) {
            Id runId = rec.Article_Assessment__r.Assessment_Run__c;
            distinctRunIds.add(runId);
            Datetime created = rec.Article_Assessment__r.Assessment_Run__r.CreatedDate;
            if (latestCreated == null || (created != null && created > latestCreated)) {
                latestCreated = created;
                latestRunId = runId;
            }
        }
        // Single-run by construction (see doc above). A >1 case shouldn't happen;
        // leave a breadcrumb if it ever does so the max-CreatedDate tiebreak is
        // traceable rather than silent.
        if (distinctRunIds.size() > 1) {
            System.debug(LoggingLevel.WARN,
                'resolveAssessmentRun: recs span ' + distinctRunIds.size()
                + ' runs ' + distinctRunIds + '; using latest ' + latestRunId);
        }
        return latestRunId;
    }

    private static void createEnrichmentCandidate(
        Knowledge__kav source,
        String sourceVersionId,
        Id draftVersionId,
        String changesSummary,
        List<String> issueDescriptions,
        Id assessmentRunId
    ) {
        // Enrichment_Candidate__c is master-detail to the assessment run, so the
        // run is required. AI-Fix recs always originate from an assessment
        // (KB_Dimension_Analysis__c under an Article_Assessment__c that points at
        // a run), so a null here means the recs couldn't be resolved to a run —
        // fail loudly (the caller marks the recs Error and surfaces it) rather
        // than writing a parentless child.
        if (assessmentRunId == null) {
            throw new KnowledgeAIException(
                'Cannot create the AI Fix draft record: the recommendations being '
                + 'fixed are not linked to an assessment run. Re-run the assessment '
                + 'for this article and try Fix with AI again.');
        }
        String issuesSummary = String.join(issueDescriptions, '; ');
        // Run-scoped key: prefixing the assessment run id means a second run's AI
        // fix of the same article creates its own candidate instead of colliding
        // on the unique key (and overwriting the first user's draft candidate).
        String compositeKey = 'ai-fix-' + assessmentRunId + '-' + source.KnowledgeArticleId;
        Enrichment_Candidate__c candidate = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = sourceVersionId,
            Source_Article_Title__c      = source.Title,
            Draft_Article_Version_Id__c  = String.valueOf(draftVersionId),
            Knowledge_Article_Id__c      = String.valueOf(source.KnowledgeArticleId), // article-level id for reconciler
            Assessment_Run__c            = assessmentRunId, // run that triggered the fix
            Composite_Key__c             = compositeKey,
            Status__c                    = 'Pending',
            Is_Closed__c                 = false,
            Confidence_Score__c          = 90,
            Reason__c                    = 'AI Fix: ' + (issuesSummary.length() > 255 ? issuesSummary.left(255) : issuesSummary),
            Recommended_Action__c        = 'Review and publish AI-generated fix draft'
        );
        upsert candidate Composite_Key__c;
        // Enrichment_Candidate__c is master-detail to the assessment run:
        // visibility is controlled-by-parent, so no explicit sharing call is
        // needed — whoever can see the run sees its candidates.
    }

    private static void markRecsStatus(List<Id> recIds, String status) {
        List<KB_Dimension_Analysis__c> toUpdate = new List<KB_Dimension_Analysis__c>();
        for (Id recId : recIds) {
            toUpdate.add(new KB_Dimension_Analysis__c(Id = recId, Status__c = status));
        }
        update toUpdate;
    }
}
