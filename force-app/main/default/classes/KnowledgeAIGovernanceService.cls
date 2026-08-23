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
 * Central orchestrator for Knowledge AI governance.
 * Serves as the LWC controller for the knowledgeConsistencyChecker component.
 * Handles draft verification, publish-with-audit, and force re-evaluation.
 */
public with sharing class KnowledgeAIGovernanceService {

    public static final String EVALUATION_DOMAIN_PIPELINE = 'Pipeline';
    public static final String EVALUATION_DOMAIN_GOVERNANCE = 'Governance';

    // OrgLimits the KB pipeline cares about. Shared with KBDiagnosticsController
    // so the Diagnostics tab and the Cost Preview modal surface the same four
    // rows. Labels are Custom-Label-sourced for i18n.
    public class TrackedOrgLimit {
        public String apiName;
        public String label;
        public TrackedOrgLimit(String apiName, String label) {
            this.apiName = apiName;
            this.label = label;
        }
    }

    public static List<TrackedOrgLimit> getTrackedOrgLimits() {
        return new List<TrackedOrgLimit>{
            new TrackedOrgLimit('DailyAsyncApexExecutions', System.Label.KB_OrgLimit_DailyAsyncApex),
            new TrackedOrgLimit('DailyApiRequests', System.Label.KB_OrgLimit_DailyApiRequests),
            new TrackedOrgLimit('HourlyPublishedPlatformEvents', System.Label.KB_OrgLimit_HourlyPlatformEvents),
            new TrackedOrgLimit('HourlyODataCallout', System.Label.KB_OrgLimit_HourlyODataCallout)
        };
    }

    /**
     * Verifies a draft article against published articles for conflicts.
     * No caching for drafts since draft text changes constantly prior to publish.
     *
     * @param articleVersionId The KnowledgeArticleVersion Id of the draft
     * @return DraftEvaluationResult with conflict details
     */
    /**
     * Returns the PublishStatus of the article. Used by the LWC to determine
     * draft vs published behavior, since PublishStatus may not be available
     * via the UI API getRecord wire.
     */
    @AuraEnabled(cacheable=true)
    public static String getArticleStatus(Id articleVersionId) {
        List<Knowledge__kav> articles = [
            SELECT PublishStatus FROM Knowledge__kav
            WHERE Id = :articleVersionId LIMIT 1
        ];
        return articles.isEmpty() ? null : articles[0].PublishStatus;
    }

    @AuraEnabled
    public static PromptTemplateService.DraftEvaluationResult verifyDraft(Id articleVersionId) {
        Knowledge__kav article = queryArticle(articleVersionId);

        String articleText = buildArticleText(article);
        if (String.isBlank(articleText)) {
            PromptTemplateService.DraftEvaluationResult clean = new PromptTemplateService.DraftEvaluationResult();
            clean.hasConflict = false;
            return clean;
        }

        VectorSearchFactory.ActiveVectorConfig config = VectorSearchFactory.getActiveConfig();
        IVectorSearchService searchService = VectorSearchFactory.getInstance();

        // Same fallback pattern as Tier1VectorSearchQueueable: if Data Cloud is
        // unreachable, the search index is missing, or the configured impl
        // throws for any reason, drop down to SOQL keyword matching so the
        // sidebar always returns a usable result instead of an ugly toast.
        List<VectorSearchResult> rawResults;
        try {
            rawResults = searchService.searchSimilarArticles(
                articleText,
                Integer.valueOf(config.maxResults),
                config.similarityThreshold
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'verifyDraft: vector search failed, falling back to SOQL: ' + e.getMessage());
            rawResults = new Tier1SOQLFallbackService().searchSimilarArticles(
                articleText,
                Integer.valueOf(config.maxResults),
                config.similarityThreshold
            );
        }

        // Exclude the current article and any other version of the same article
        String currentVersionId15 = String.valueOf(articleVersionId).left(15);
        String currentKnowledgeArticleId = article.KnowledgeArticleId;

        // Bulk-fetch mirror records to check KnowledgeArticleId for all results
        Set<String> resultVersionIds = new Set<String>();
        for (VectorSearchResult r : rawResults) {
            if (r.articleVersionId != null) {
                resultVersionIds.add(r.articleVersionId);
            }
        }

        // Map result version IDs to their stable KnowledgeArticleIds via Knowledge__kav
        Set<String> sameArticleVersionIds = new Set<String>();
        sameArticleVersionIds.add(String.valueOf(articleVersionId));
        if (String.isNotBlank(currentKnowledgeArticleId) && !resultVersionIds.isEmpty()) {
            for (Knowledge__kav kav : [
                SELECT Id, KnowledgeArticleId
                FROM Knowledge__kav
                WHERE Id IN :resultVersionIds
                AND KnowledgeArticleId = :currentKnowledgeArticleId
            ]) {
                sameArticleVersionIds.add(kav.Id);
            }
        }

        List<VectorSearchResult> similarArticles = new List<VectorSearchResult>();
        for (VectorSearchResult r : rawResults) {
            if (r.articleVersionId == null) {
                continue;
            }
            if (r.articleVersionId.left(15) == currentVersionId15) {
                continue;
            }
            if (sameArticleVersionIds.contains(r.articleVersionId)) {
                continue;
            }
            similarArticles.add(r);
        }

        if (similarArticles.isEmpty()) {
            PromptTemplateService.DraftEvaluationResult clean = new PromptTemplateService.DraftEvaluationResult();
            clean.hasConflict = false;
            return clean;
        }

        return PromptTemplateService.getInstance().evaluateDraft(articleText, similarArticles);
    }

    /**
     * Publishes an article with optional bypass audit logging.
     * If bypassReasonJson is provided, the user is bypassing AI warnings.
     *
     * @param knowledgeArticleId The KnowledgeArticleId (stable, not version-specific)
     * @param articleVersionId The current version Id for logging purposes
     * @param bypassReasonJson JSON string with bypass reason, or null if no bypass
     */
    @AuraEnabled
    public static void publishArticleWithAudit(
        Id knowledgeArticleId,
        Id articleVersionId,
        String bypassReasonJson
    ) {
        // Server-side enforcement of the bypass gate. A non-blank bypassReasonJson
        // means the caller is publishing PAST consistency warnings — that action
        // requires the `Bypass_AI_Knowledge_Check` custom permission. The LWC
        // already hides the "Publish Anyway" button for users without it, but the
        // permission was UI-only: nothing stopped a direct Apex call. Gate it here
        // so the rule holds regardless of caller. Seeing duplicates (verifyDraft)
        // and normal conflict-free publishes (null reason) are unaffected.
        if (String.isNotBlank(bypassReasonJson)) {
            if (!FeatureManagement.checkPermission('Bypass_AI_Knowledge_Check')) {
                throw new AuraHandledException(
                    'You don\'t have permission to publish past consistency warnings. '
                    + 'Resolve the duplicates, or ask a Knowledge Manager to override.'
                );
            }
            logBypassAudit(articleVersionId, bypassReasonJson);
        }

        Id resolvedArticleId = knowledgeArticleId;
        if (resolvedArticleId == null && articleVersionId != null) {
            List<Knowledge__kav> versions = [
                SELECT KnowledgeArticleId
                FROM Knowledge__kav
                WHERE Id = :articleVersionId
                LIMIT 1
            ];
            if (!versions.isEmpty()) {
                resolvedArticleId = versions[0].KnowledgeArticleId;
            }
        }

        if (resolvedArticleId == null) {
            throw new AuraHandledException(
                'Failed to publish article: knowledgeArticleId could not be resolved from articleVersionId ' +
                articleVersionId
            );
        }

        try {
            KbManagement.PublishingService.publishArticle(resolvedArticleId, true);
            KBEnrichmentController.closeEnrichmentCandidatesForDraft(String.valueOf(articleVersionId));
        } catch (AuraHandledException e) {
            // Pass through bypass-validation messages verbatim — wrapping
            // them in 'Failed to publish article:' would mask the real cause.
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(
                'Failed to publish article: ' + e.getMessage()
            );
        }

        // No mirror sync needed. Source of truth is Knowledge__kav.
    }

    /**
     * Creates a new draft version of a published article for editing.
     * Used when the consistency checker finds issues on a published article
     * and the manager wants to create a draft to fix them.
     *
     * @param knowledgeArticleId The stable KnowledgeArticleId
     * @return The new draft version Id
     */
    @AuraEnabled
    public static Id createDraftVersion(Id knowledgeArticleId) {
        // Check if a draft version already exists
        List<Knowledge__kav> existingDrafts = [
            SELECT Id FROM Knowledge__kav
            WHERE KnowledgeArticleId = :knowledgeArticleId
            AND PublishStatus = 'Draft'
            LIMIT 1
        ];

        if (!existingDrafts.isEmpty()) {
            // Draft already exists — return its ID so the LWC can navigate to it
            return existingDrafts[0].Id;
        }

        try {
            String draftId = KbManagement.PublishingService.editOnlineArticle(
                knowledgeArticleId, false
            );
            return Id.valueOf(draftId);
        } catch (Exception e) {
            AuraHandledException ahe = new AuraHandledException(
                'Failed to create draft version: ' + e.getMessage()
            );
            ahe.setMessage('Failed to create draft version: ' + e.getMessage());
            throw ahe;
        }
    }

    /**
     * Deletes the cache record for a pair of articles, forcing re-evaluation
     * on the next batch run.
     *
     * @param articleVersionIdA First article version Id
     * @param articleVersionIdB Second article version Id
     */
    @AuraEnabled
    public static void forceReEvaluate(String articleVersionIdA, String articleVersionIdB) {
        String compositeKey = generateCompositeKey(articleVersionIdA, articleVersionIdB);

        List<Knowledge_Pair_Evaluation__c> cached = [
            SELECT Id
            FROM Knowledge_Pair_Evaluation__c
            WHERE Composite_Version_Key__c = :compositeKey
            AND (Evaluation_Domain__c = :EVALUATION_DOMAIN_GOVERNANCE OR Evaluation_Domain__c = null)
            LIMIT 1
        ];

        if (!cached.isEmpty()) {
            delete cached;
        }
    }

    /**
     * Generates a deterministic composite key from two article version IDs.
     * Sorts alphabetically so the order of arguments doesn't matter.
     *
     * This run-agnostic form is the cache key for Knowledge_Pair_Evaluation__c
     * (Composite_Version_Key__c) — the LLM cache is intentionally keyed on the
     * article pair alone so a pair evaluated once isn't re-judged. Candidate
     * rows must NOT use this form; see the run-scoped overload below.
     */
    public static String generateCompositeKey(String versionIdA, String versionIdB) {
        List<String> ids = new List<String>{ versionIdA, versionIdB };
        ids.sort();
        return ids[0] + '_' + ids[1];
    }

    /**
     * Run-scoped composite key for Duplicate_Candidate__c.Composite_Key__c.
     * Prefixing the assessment run id makes each run's candidate rows unique on
     * the pair — two users (or two runs) assessing the same articles no longer
     * collide on the globally-unique key. The run id is the STABLE
     * KB_Assessment_Run__c id (not the per-rerun pipeline run), so within a
     * rerun the key is identical and the existing row is reused in place; across
     * different runs the keys differ and each run owns its own row. Falls back to
     * the run-agnostic form when no run id is available (defensive / legacy).
     */
    public static String generateCompositeKey(String versionIdA, String versionIdB, Id assessmentRunId) {
        String pairKey = generateCompositeKey(versionIdA, versionIdB);
        return assessmentRunId == null ? pairKey : assessmentRunId + '_' + pairKey;
    }

    /**
     * Run-scoped cache key for Knowledge_Pair_Evaluation__c.Composite_Version_Key__c.
     * That field is GLOBALLY unique; prefixing the PIPELINE run id gives each
     * pipeline run its own eval row for a given article pair, so two runs (two
     * users, or a rerun) over the same pair don't collide on the unique key. This
 * is the KPE twin of the Duplicate_Candidate__c run-scoping — the
     * original fix scoped only the candidate key and left this one globally unique,
     * so a second run's KPE upsert threw DUPLICATE_VALUE and rolled back the whole
     * pair-evaluation transaction (candidates included).
     *
     * The scope is the PIPELINE run id (not the stable assessment run id) because
     * (a) the cache read filters by Pipeline_Run__c, and (b) a rerun keeps the
     * assessment run id but creates a fresh pipeline run — assessment-run scoping
     * would collide on rerun against the prior run's surviving rows. Falls back to
     * the run-agnostic form when no pipeline run id is available (defensive).
     */
    public static String generatePipelineEvaluationKey(String versionIdA, String versionIdB, Id pipelineRunId) {
        String pairKey = generateCompositeKey(versionIdA, versionIdB);
        return pipelineRunId == null ? pairKey : pipelineRunId + '_' + pairKey;
    }

    private static Knowledge__kav queryArticle(Id articleVersionId) {
 // part 2 — FLS-hardened as a DEGRADE read. verifyDraft is a read-only
        // sidebar that must keep working even when the running user lacks FLS on a
        // selected field (e.g. AI_Bypass_Audit_Log__c). WITH USER_MODE would
        // all-or-nothing THROW and break the sidebar, so we instead run the query
        // and Security.stripInaccessible(READABLE) the rows — inaccessible fields
        // are dropped from the result, accessible ones survive. Downstream readers
        // (buildArticleText, logBypassAudit) null-guard each field, so a stripped
        // field reads as blank rather than erroring. `with sharing` still enforces
        // record-level visibility.
        List<Knowledge__kav> articles = [
            SELECT Id, KnowledgeArticleId, Title, Summary, PublishStatus,
                   IsLatestVersion, AI_Bypass_Audit_Log__c
            FROM Knowledge__kav
            WHERE Id = :articleVersionId
            LIMIT 1
        ];

        if (articles.isEmpty()) {
            throw new AuraHandledException('Article not found: ' + articleVersionId);
        }

        // Drop any fields the running user can't read; keeps the sidebar alive
        // under partial FLS instead of throwing.
        articles = Security.stripInaccessible(AccessType.READABLE, articles).getRecords();

        return articles[0];
    }

    private static String buildArticleText(Knowledge__kav article) {
        String text = '';
        if (String.isNotBlank(article.Title)) {
            text += article.Title + '\n';
        }
        if (String.isNotBlank(article.Summary)) {
            text += article.Summary;
        }
        return text.trim();
    }

    private static void logBypassAudit(Id articleVersionId, String bypassReasonJson) {
        Knowledge__kav article = [
            SELECT Id, AI_Bypass_Audit_Log__c
            FROM Knowledge__kav
            WHERE Id = :articleVersionId
            LIMIT 1
        ];

        List<Object> logEntries;
        if (String.isNotBlank(article.AI_Bypass_Audit_Log__c)) {
            logEntries = (List<Object>) JSON.deserializeUntyped(article.AI_Bypass_Audit_Log__c);
        } else {
            logEntries = new List<Object>();
        }

        Map<String, Object> newEntry = new Map<String, Object>{
            'timestamp' => Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'userId' => UserInfo.getUserId(),
            'userName' => UserInfo.getName(),
            'reason' => bypassReasonJson
        };

        logEntries.add(newEntry);

        // Truncate oldest entries if log exceeds field length
        String serialized = JSON.serialize(logEntries);
        while (serialized.length() > 32768 && logEntries.size() > 1) {
            logEntries.remove(0);
            serialized = JSON.serialize(logEntries);
        }

        article.AI_Bypass_Audit_Log__c = serialized;
        update article;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Cost & Consumption Preview (1.0.C)
    // ──────────────────────────────────────────────────────────────────────

    /**
     * Heuristic: per-dimension Queueable + finalization bookkeeping. Kept as
     * a constant multiplier rather than a config field because the value
     * comes from the pipeline architecture, not admin judgement. If the
     * dispatcher ever changes its chain shape, bump this number in one place.
     */
    private static final Integer ASYNC_JOBS_PER_DIMENSION_PER_BATCH = 2;

    /**
     * Heuristic: one progress Platform Event per batch. The scorer fires a
     * single progress PE per batch boundary, plus one final Completed event.
     */
    private static final Integer PLATFORM_EVENTS_PER_BATCH = 1;

    /**
     * Default batch size used when `KB_Scan_Config__c.Queueable_Batch_Size__c`
     * is not set. Matches the field's deploy-time default.
     */
    private static final Integer DEFAULT_BATCH_SIZE = 50;

    /**
     * Estimates consumption impact of a proposed run. Read-only — no DML,
     * no caching. Used by the Cost Preview modal to give users a blast-
     * radius view before they submit.
     *
     * @param articleCount How many articles this run will process.
     * @param selectedDimensions DeveloperNames of dimensions that will be scored.
     *                           null / empty → treat as all active dimensions.
     * @return DTO with the computed deltas, current org-limit snapshot, and
     *         a "warn" flag the UI can use to trigger typed confirmation.
     */
    @AuraEnabled
    public static RunCostEstimate estimateRunCost(
        Integer articleCount,
        List<String> selectedDimensions
    ) {
        try {
            Integer count = articleCount == null || articleCount < 0 ? 0 : articleCount;

            // Resolve dimensions: fall back to active set when caller passed nothing.
            // Keeps the preview useful even before the user deselects anything.
            Set<String> activeNames = DimensionRegistry.getActiveDeveloperNames();
            Set<String> requested = new Set<String>();
            if (selectedDimensions != null && !selectedDimensions.isEmpty()) {
                for (String s : selectedDimensions) {
                    if (String.isBlank(s)) continue;
                    // Accept both DeveloperName case and lowercase variants the LWC sends.
                    // Match against activeNames case-insensitively by normalizing.
                    requested.add(normalizeDimensionName(s, activeNames));
                }
            } else {
                requested.addAll(activeNames);
            }

            // Sum per-dimension callouts × articles, skipping dimensions that
            // don't require LLM (Freshness/Duplication/Conflict are deterministic).
            Integer calloutsPerArticle = 0;
            for (String name : requested) {
                DimensionRegistry.DimensionDefinition d = DimensionRegistry.get(name);
                if (d == null || !d.isActive) continue;
                if (!d.requiresLLM) continue;
                calloutsPerArticle += (d.calloutsPerArticle == null ? 0 : d.calloutsPerArticle);
            }

            Integer batchSize = resolveBatchSize();
            Integer batches = count <= 0 ? 0 : (Integer) Math.ceil((Double) count / (Double) batchSize);
            // Requested dimension count is what drives async chain length, not just llm ones.
            Integer activeRequested = 0;
            for (String name : requested) {
                DimensionRegistry.DimensionDefinition d = DimensionRegistry.get(name);
                if (d != null && d.isActive) activeRequested++;
            }

            RunCostEstimate est = new RunCostEstimate();
            est.articleCount = count;
            est.selectedDimensionCount = activeRequested;
            est.batchSize = batchSize;
            est.batchCount = batches;
            est.einsteinCalls = count * calloutsPerArticle;
            est.asyncJobExecutions = batches * activeRequested * ASYNC_JOBS_PER_DIMENSION_PER_BATCH;
            est.platformEvents = batches * PLATFORM_EVENTS_PER_BATCH;
            est.soqlRowsRead = count; // one article read per record; conservative floor.

            est.orgLimits = readOrgLimits(est);
            est.warn = shouldWarn(count, est.orgLimits);

            return est;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to estimate run consumption: ' + e.getMessage());
        }
    }

    private static String normalizeDimensionName(String input, Set<String> activeNames) {
        // LWC sends lowercase ('completeness'); CMDT DeveloperName is
        // capitalized ('Completeness'). Try exact first, then case-insensitive.
        if (activeNames.contains(input)) return input;
        String lc = input.toLowerCase();
        for (String n : activeNames) {
            if (n.toLowerCase() == lc) return n;
        }
        return input;
    }

    private static Integer resolveBatchSize() {
        try {
            KB_Scan_Config__c cfg = KB_Scan_Config__c.getInstance();
            if (cfg != null && cfg.Queueable_Batch_Size__c != null && cfg.Queueable_Batch_Size__c > 0) {
                return (Integer) cfg.Queueable_Batch_Size__c;
            }
        } catch (Exception e) {
            // Custom Setting unreachable — fall through.
        }
        return DEFAULT_BATCH_SIZE;
    }

    private static List<OrgLimitProjection> readOrgLimits(RunCostEstimate est) {
        List<OrgLimitProjection> out = new List<OrgLimitProjection>();
        Map<String, System.OrgLimit> all = OrgLimits.getMap();
        // Per-metric projected additions keyed by api name — keeps the
        // mapping in one place rather than scattered across the add calls.
        Map<String, Integer> projectedAdds = new Map<String, Integer>{
            'DailyAsyncApexExecutions' => est.asyncJobExecutions,
            'DailyApiRequests' => est.einsteinCalls,
            'HourlyPublishedPlatformEvents' => est.platformEvents,
            'HourlyODataCallout' => 0
        };
        for (TrackedOrgLimit t : getTrackedOrgLimits()) {
            Integer addVal = projectedAdds.containsKey(t.apiName) ? projectedAdds.get(t.apiName) : 0;
            out.add(projectLimit(all, t.apiName, t.label, addVal));
        }
        return out;
    }

    private static OrgLimitProjection projectLimit(
        Map<String, System.OrgLimit> all,
        String apiName,
        String label,
        Integer projectedAdd
    ) {
        OrgLimitProjection p = new OrgLimitProjection();
        p.apiName = apiName;
        p.label = label;
        p.projectedAdd = projectedAdd == null ? 0 : projectedAdd;
        System.OrgLimit ol = all.get(apiName);
        if (ol == null) {
            p.limitValue = 0;
            p.usedValue = 0;
            p.remainingValue = 0;
            p.projectedUsedPct = 0;
            return p;
        }
        p.limitValue = ol.getLimit();
        p.usedValue = ol.getValue();
        p.remainingValue = p.limitValue - p.usedValue;
        Integer projectedUsed = p.usedValue + p.projectedAdd;
        p.projectedUsedPct = p.limitValue > 0
            ? (Integer) Math.min(100, Math.round(((Double) projectedUsed * 100) / (Double) p.limitValue))
            : 0;
        return p;
    }

    /**
     * Warn thresholds — trigger typed confirmation when:
     *  - article count ≥ 500, OR
     *  - any quota projection lands above 80% of daily cap.
     * Kept as a server-side decision so every surface (including the planned
     * Agentforce action) gets the same guardrail.
     */
    private static Boolean shouldWarn(Integer articleCount, List<OrgLimitProjection> projections) {
        if (articleCount != null && articleCount >= 500) return true;
        for (OrgLimitProjection p : projections) {
            if (p.projectedUsedPct >= 80) return true;
        }
        return false;
    }

    // ─── DTOs ─────────────────────────────────────────────────────────────

    public class RunCostEstimate {
        @AuraEnabled public Integer articleCount { get; set; }
        @AuraEnabled public Integer selectedDimensionCount { get; set; }
        @AuraEnabled public Integer batchSize { get; set; }
        @AuraEnabled public Integer batchCount { get; set; }
        @AuraEnabled public Integer einsteinCalls { get; set; }
        @AuraEnabled public Integer asyncJobExecutions { get; set; }
        @AuraEnabled public Integer platformEvents { get; set; }
        @AuraEnabled public Integer soqlRowsRead { get; set; }
        @AuraEnabled public List<OrgLimitProjection> orgLimits { get; set; }
        @AuraEnabled public Boolean warn { get; set; }
    }

    public class OrgLimitProjection {
        @AuraEnabled public String apiName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Integer limitValue { get; set; }
        @AuraEnabled public Integer usedValue { get; set; }
        @AuraEnabled public Integer remainingValue { get; set; }
        @AuraEnabled public Integer projectedAdd { get; set; }
        @AuraEnabled public Integer projectedUsedPct { get; set; }
    }
}