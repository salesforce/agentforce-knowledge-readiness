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
 * Unified Assessment Facade
 *
 * Central orchestrator for all assessment operations across surfaces.
 * Handles: freshness validation, dimension selection, sync/async routing,
 * result persistence.
 *
 * Consumers: KBAssessmentController (@AuraEnabled), Invocable Actions
 * (Agentforce), future REST resource.
 *
 * Does NOT replace KBAssessmentService or KBScoringService — delegates to them.
 */
public with sharing class KBAssessmentFacade {

    private static final Integer DEFAULT_MAX_SYNC_ARTICLES = 10;

    // ==================== Options ====================

    /**
     * Configuration for an assessment request.
     * All fields optional — sensible defaults applied.
     */
    public class AssessmentOptions {
        public List<String> dimensions;
        public List<String> assessmentTypes;
        public Integer maxSyncArticles;
        public Boolean skipPipelineDimensions;
        public Boolean persistResults;
        public List<KBAssessmentModels.FilterClause> filterClauses;
        public String filterLogic;

        public AssessmentOptions() {
            this.dimensions = null; // null = all
            this.assessmentTypes = new List<String>{ 'Readiness' };
            this.maxSyncArticles = null; // read from config
            this.skipPipelineDimensions = false;
            this.persistResults = true;
            this.filterClauses = new List<KBAssessmentModels.FilterClause>();
            this.filterLogic = 'AND';
        }
    }

    /**
     * Result wrapper exposing staleness metadata alongside an existing
     * assessment (or null if none fresh).
     */
    public class ExistingAssessmentResult {
        @AuraEnabled public KBAssessmentModels.ArticleAssessmentResult assessment { get; set; }
        @AuraEnabled public Boolean found { get; set; }
        @AuraEnabled public Boolean articleModifiedSince { get; set; }
        @AuraEnabled public Datetime assessedDate { get; set; }
        @AuraEnabled public Boolean dupConflictStale { get; set; }

        public ExistingAssessmentResult() {
            this.found = false;
            this.articleModifiedSince = false;
            this.dupConflictStale = false;
        }
    }

    // ==================== Existing / Retrieval ====================

    /**
     * Retrieve the most recent fresh assessment for a single article.
     *
     * Freshness rule: an existing assessment is considered fresh if the
     * article has NOT been modified since the assessment was created.
     *
     * @param articleId Knowledge article version ID
     * @return ArticleAssessmentResult if a fresh existing assessment exists, null otherwise
     */
    public static KBAssessmentModels.ArticleAssessmentResult getExistingAssessment(String articleId) {
        ExistingAssessmentResult existing = getExistingAssessmentDetailed(articleId);
        return existing.found && !existing.articleModifiedSince ? existing.assessment : null;
    }

    /**
     * Retrieve existing assessment with full staleness metadata.
     * Use when the caller needs to know WHY the existing assessment is stale (modified vs missing).
     */
    public static ExistingAssessmentResult getExistingAssessmentDetailed(String articleId) {
        ExistingAssessmentResult result = new ExistingAssessmentResult();
        if (String.isBlank(articleId)) {
            return result;
        }

        List<KB_Article_Assessment__c> assessments = [
            SELECT Id, Knowledge__c, Article_Title__c, Article_Number__c, Knowledge_Article_Id__c, Overall_Score__c,
                   Readiness_Status__c, CreatedDate,
                   Has_Conflicts__c, Conflict_Details__c,
                   (SELECT Dimension__c, Score__c, Reasoning__c,
                           Is_Unassessable__c, Scorer_Mode__c, Execution_Ms__c
                    FROM Dimension_Results__r)
            FROM KB_Article_Assessment__c
            WHERE Knowledge__c = :articleId
              AND Overall_Score__c != null
              AND Assessment_Run__r.Assessment_Types__c INCLUDES ('Readiness')
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (assessments.isEmpty()) {
            return result;
        }

        KB_Article_Assessment__c existingRec = assessments[0];
        result.found = true;
        result.assessedDate = existingRec.CreatedDate;
        result.assessment = mapAssessmentToResult(existingRec);

        // Check if article has been modified since the assessment
        Datetime articleLastModified = getArticleLastModified(articleId);
        if (articleLastModified != null && articleLastModified > existingRec.CreatedDate) {
            result.articleModifiedSince = true;
        }

        // Flag duplication/conflict staleness: new Duplicate_Candidate__c records
        // may have been created by OTHER articles' pipeline runs since this assessment
        result.dupConflictStale = hasNewerDuplicateCandidates(articleId, existingRec.CreatedDate);

        return result;
    }

    /**
     * Existing-first assessment: return existing result if fresh, otherwise
     * run a fresh assessment synchronously.
     *
     * Primary method for the agent path and article record LWC.
     *
     * @param articleId Knowledge article version ID
     * @param options Assessment configuration
     * @return ArticleAssessmentResult from existing or freshly computed
     */
    public static KBAssessmentModels.ArticleAssessmentResult getOrAssess(
        String articleId, AssessmentOptions options
    ) {
        if (String.isBlank(articleId)) {
            return null;
        }
        AssessmentOptions safeOptions = options != null ? options : new AssessmentOptions();

        ExistingAssessmentResult existing = getExistingAssessmentDetailed(articleId);

        // Fresh existing: article unmodified and dup/conflict not stale (unless caller doesn't care)
        Boolean existingUsable = existing.found
            && !existing.articleModifiedSince
            && (safeOptions.skipPipelineDimensions || !existing.dupConflictStale);

        if (existingUsable) {
            return existing.assessment;
        }

        // No fresh existing: run fresh sync assessment
        KBAssessmentModels.AssessmentRunResult runResult = assessArticlesSync(
            new List<String>{ articleId }, safeOptions
        );
        if (runResult != null && runResult.articleResults != null && !runResult.articleResults.isEmpty()) {
            return runResult.articleResults[0];
        }
        return null;
    }

    // ==================== Sync Assessment ====================

    /**
     * Assess one or more articles synchronously. Solo dimensions
     * (Completeness, Structure, Clarity, Freshness) are scored inline.
     * Duplication/Conflict use existing Duplicate_Candidate__c data when
     * available; otherwise default to 100 (no known issues).
     *
     * Should only be called for small batches (≤ options.maxSyncArticles).
     * Use assess() router to auto-select sync vs async.
     *
     * @param articleIds List of article version IDs
     * @param options Assessment configuration
     * @return AssessmentRunResult with inline article results
     */
    public static KBAssessmentModels.AssessmentRunResult assessArticlesSync(
        List<String> articleIds, AssessmentOptions options
    ) {
        KBAssessmentModels.AssessmentRunResult result = new KBAssessmentModels.AssessmentRunResult();

        if (articleIds == null || articleIds.isEmpty()) {
            result.status = 'Failed';
            return result;
        }
        AssessmentOptions safeOptions = options != null ? options : new AssessmentOptions();

        // Resolve selected dimensions and weights
        Set<String> selectedDimensions = resolveSelectedDimensions(safeOptions);
        Map<String, Decimal> effectiveWeights = renormaliseWeights(selectedDimensions);

        // Fetch articles (deduped by service)
        KBAssessmentService service = new KBAssessmentService();
        List<KBAssessmentModels.ArticleWrapper> articles = service.fetchArticles(articleIds);

        if (articles.isEmpty()) {
            result.status = 'Failed';
            return result;
        }

        // Pre-load pipeline data in bulk for dup/conflict
        Map<String, Decimal> dupScores = new Map<String, Decimal>();
        Map<String, Decimal> conflictScores = new Map<String, Decimal>();
        Map<String, List<Duplicate_Candidate__c>> candidatesByArticle = new Map<String, List<Duplicate_Candidate__c>>();

        Boolean skipPipeline = safeOptions.skipPipelineDimensions != null && safeOptions.skipPipelineDimensions;
        Boolean needsDup = selectedDimensions.contains('Duplication') && !skipPipeline;
        Boolean needsConflict = selectedDimensions.contains('Conflict') && !skipPipeline;

        if (needsDup) {
            dupScores = KBPipelineBridgeService.getBatchDuplicationScores(articleIds);
        }
        if (needsConflict) {
            conflictScores = KBPipelineBridgeService.getBatchConflictScores(articleIds);
        }
        if (needsDup || needsConflict) {
            candidatesByArticle = KBPipelineBridgeService.getBatchCandidates(articleIds);
        }

        // Score each article for requested dimensions
        KBScoringService scoringService = new KBScoringService();

        for (KBAssessmentModels.ArticleWrapper article : articles) {
            KBAssessmentModels.ArticleAssessmentResult articleResult =
                scoringService.scoreDimensions(
                    article,
                    selectedDimensions,
                    dupScores.containsKey(article.id) ? dupScores.get(article.id) : null,
                    conflictScores.containsKey(article.id) ? conflictScores.get(article.id) : null,
                    candidatesByArticle.containsKey(article.id) ? candidatesByArticle.get(article.id) : null
                );
            articleResult.calculateOverallScore(selectedDimensions, effectiveWeights);
            result.articleResults.add(articleResult);
        }

        // Persist results if requested
        Boolean persist = safeOptions.persistResults == null ? true : safeOptions.persistResults;
        if (persist) {
            persistSyncResults(result, selectedDimensions, effectiveWeights, safeOptions);
        }

        result.calculateSummary();
        result.status = 'Completed';
        // Ground truth from the in-memory scores: did any dimension actually
        // run the LLM (Scorer_Mode__c = 'Hybrid')? A deterministic-only or
 // all-fallback run reads false. See.
        result.usedLLM = anyHybridScore(result.articleResults);
        result.selectedDimensionCount = selectedDimensions.size();
        return result;
    }

    /**
     * True if any dimension score in the run was produced by the LLM
     * (Scorer_Mode__c = 'Hybrid'). Used to set the honest Used_LLM__c value on
     * the synchronous path, where scores are computed in-memory before persist.
     */
    private static Boolean anyHybridScore(List<KBAssessmentModels.ArticleAssessmentResult> articleResults) {
        if (articleResults == null) return false;
        for (KBAssessmentModels.ArticleAssessmentResult ar : articleResults) {
            if (ar == null || ar.scoresByDim == null) continue;
            for (KBAssessmentModels.DimensionScore s : ar.scoresByDim.values()) {
                if (s != null && s.scorerMode == KBScorerBase.MODE_HYBRID) return true;
            }
        }
        return false;
    }

    // ==================== Async Assessment ====================

    /**
     * Assess articles asynchronously via the existing bulk pipeline.
     * Creates a KB_Assessment_Run__c and dispatches the tiered worker
     * (queueable fan-out for 11–50, Batch Apex above).
     *
     * @param articleIds Article version IDs
     * @param options Assessment configuration
     * @return AssessmentRunResult with runId and status='Processing'
     */
    public static KBAssessmentModels.AssessmentRunResult assessArticlesAsync(
        List<String> articleIds, AssessmentOptions options
    ) {
        AssessmentOptions safeOptions = options != null ? options : new AssessmentOptions();
        KBAssessmentService service = new KBAssessmentService();
        return service.runAssessment(articleIds, toRunOptions(safeOptions));
    }

    // ==================== Smart Router ====================

    /**
     * Automatically choose sync or async based on article count.
     *
     * @param articleIds Article version IDs
     * @param options Assessment configuration
     * @return AssessmentRunResult — complete (sync) or with runId (async)
     */
    public static KBAssessmentModels.AssessmentRunResult assess(
        List<String> articleIds, AssessmentOptions options
    ) {
        AssessmentOptions safeOptions = options != null ? options : new AssessmentOptions();

        if (articleIds == null || articleIds.isEmpty()) {
            KBAssessmentModels.AssessmentRunResult empty = new KBAssessmentModels.AssessmentRunResult();
            empty.status = 'Failed';
            return empty;
        }

        Integer threshold = resolveMaxSyncArticles(safeOptions);
        if (articleIds.size() <= threshold) {
            return assessArticlesSync(articleIds, safeOptions);
        }
        return assessArticlesAsync(articleIds, safeOptions);
    }

    // ==================== Knowledge Querying ====================

    /**
     * Find articles similar to a given article using existing
     * Duplicate_Candidate__c data from prior pipeline runs.
     *
     * @param articleId Source article version ID
     * @param limitCount Max similar articles to return
     * @return List of SimilarArticle with confidence + flag type
     */
    public static List<SimilarArticle> findSimilarArticles(String articleId, Integer limitCount) {
        List<SimilarArticle> similar = new List<SimilarArticle>();
        if (String.isBlank(articleId)) {
            return similar;
        }
        Integer safeLimit = (limitCount != null && limitCount > 0) ? limitCount : 5;

        List<Duplicate_Candidate__c> candidates = [
            SELECT Knowledge_Article_1__c, Knowledge_Article_2__c,
                   Article_1_Title__c, Article_2_Title__c,
                   Confidence_Score__c, Flag_Type__c, Source_Tier__c, Status__c
            FROM Duplicate_Candidate__c
            WHERE (Knowledge_Article_1__c = :articleId OR Knowledge_Article_2__c = :articleId)
            AND Status__c NOT IN ('Rejected', 'Suppressed')
            ORDER BY Confidence_Score__c DESC
            LIMIT :safeLimit
        ];

        for (Duplicate_Candidate__c dc : candidates) {
            SimilarArticle s = new SimilarArticle();
            Boolean articleIsFirst = dc.Knowledge_Article_1__c == articleId;
            s.articleId = articleIsFirst ? dc.Knowledge_Article_2__c : dc.Knowledge_Article_1__c;
            s.title = articleIsFirst ? dc.Article_2_Title__c : dc.Article_1_Title__c;
            s.confidenceScore = dc.Confidence_Score__c;
            s.flagType = dc.Flag_Type__c;
            s.sourceTier = dc.Source_Tier__c;
            similar.add(s);
        }
        return similar;
    }

    public class SimilarArticle {
        @AuraEnabled public String articleId { get; set; }
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public Decimal confidenceScore { get; set; }
        @AuraEnabled public String flagType { get; set; }
        @AuraEnabled public String sourceTier { get; set; }

        public SimilarArticle() {}
    }

    // ==================== Private Helpers ====================

    /**
     * Resolve the effective dimension set from options.
     * Null/empty → all 6 dimensions. skipPipelineDimensions → removes Dup+Conflict.
     */
    private static Set<String> resolveSelectedDimensions(AssessmentOptions options) {
        Set<String> active = DimensionRegistry.getActiveDeveloperNames();
        Set<String> dims = new Set<String>();
        if (options.dimensions == null || options.dimensions.isEmpty()) {
            dims.addAll(active);
        } else {
            for (String d : options.dimensions) {
                if (String.isBlank(d)) continue;
                String trimmed = d.trim();
                if (active.contains(trimmed)) dims.add(trimmed);
            }
            if (dims.isEmpty()) dims.addAll(active);
        }

        if (options.skipPipelineDimensions != null && options.skipPipelineDimensions) {
            for (String dim : new Set<String>(dims)) {
                DimensionRegistry.DimensionDefinition def = DimensionRegistry.get(dim);
                if (def != null && def.requiresPipelineData) dims.remove(dim);
            }
        }
        return dims;
    }

    /**
     * Renormalise weights over selected dimensions so they sum to 1.0.
     * Reads admin-editable weights via DimensionRegistry.
     */
    private static Map<String, Decimal> renormaliseWeights(Set<String> selected) {
        return DimensionRegistry.renormalise(selected);
    }

    /**
     * Translate facade AssessmentOptions → model AssessmentRunOptions
     * for delegation to KBAssessmentService.runAssessment().
     */
    private static KBAssessmentModels.AssessmentRunOptions toRunOptions(AssessmentOptions opts) {
        KBAssessmentModels.AssessmentRunOptions runOpts = new KBAssessmentModels.AssessmentRunOptions();
        if (opts.dimensions != null && !opts.dimensions.isEmpty()) {
            runOpts.selectedDimensions = opts.dimensions;
        }
        if (opts.assessmentTypes != null && !opts.assessmentTypes.isEmpty()) {
            runOpts.assessmentTypes = opts.assessmentTypes;
        }
        if (opts.filterClauses != null) {
            runOpts.filterClauses = opts.filterClauses;
        }
        if (String.isNotBlank(opts.filterLogic)) {
            runOpts.filterLogic = opts.filterLogic;
        }
        return runOpts;
    }

    /**
     * Resolve the sync-tier threshold: caller override → KB_Scan_Config__c →
     * compiled default. Anything <= this count runs synchronously in-request.
     * Above this, the service's tiered dispatch picks queueable fan-out
     * (11–50 LLM / 11–200 non-LLM) or Batch Apex (larger).
     */
    private static Integer resolveMaxSyncArticles(AssessmentOptions opts) {
        if (opts.maxSyncArticles != null && opts.maxSyncArticles > 0) {
            return opts.maxSyncArticles;
        }
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getInstance();
        if (cfg != null && cfg.Sync_Threshold__c != null && cfg.Sync_Threshold__c > 0) {
            return cfg.Sync_Threshold__c.intValue();
        }
        return DEFAULT_MAX_SYNC_ARTICLES;
    }

    /**
     * Query the Knowledge article's LastModifiedDate by ID.
     * Returns null if the article can't be found.
     */
    private static Datetime getArticleLastModified(String articleId) {
        String objectName = KBAssessmentService.getKnowledgeObjectApiNameStatic();
        if (String.isBlank(objectName)) return null;

        try {
            String soql = 'SELECT LastModifiedDate FROM ' + objectName
                + ' WHERE Id = :articleId LIMIT 1';
            // USER_MODE: id-keyed read of a standard system field only, so it
            // enforces the running user's access without an FLS risk.
            List<SObject> rows = Database.query(soql, AccessLevel.USER_MODE);
            if (rows.isEmpty()) return null;
            return (Datetime) rows[0].get('LastModifiedDate');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Cannot fetch article LastModifiedDate: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Check whether new Duplicate_Candidate__c records exist for this article
     * since the given cutoff (existing assessment date).
     */
    private static Boolean hasNewerDuplicateCandidates(String articleId, Datetime cutoff) {
        if (cutoff == null) return false;
        Integer count = [
            SELECT COUNT()
            FROM Duplicate_Candidate__c
            WHERE (Knowledge_Article_1__c = :articleId OR Knowledge_Article_2__c = :articleId)
            AND CreatedDate > :cutoff
            LIMIT 1
        ];
        return count > 0;
    }

    /**
     * Map a KB_Article_Assessment__c record (with Dimension_Results__r subquery)
     * to ArticleAssessmentResult. Child rows become entries in scoresByDim.
     */
    private static KBAssessmentModels.ArticleAssessmentResult mapAssessmentToResult(KB_Article_Assessment__c rec) {
        KBAssessmentModels.ArticleAssessmentResult r = new KBAssessmentModels.ArticleAssessmentResult();
        r.articleId = rec.Knowledge__c;
        r.articleTitle = rec.Article_Title__c;
        r.articleNumber = rec.Article_Number__c;
        r.knowledgeArticleId = rec.Knowledge_Article_Id__c;
        r.overallScore = rec.Overall_Score__c;
        r.readinessStatus = rec.Readiness_Status__c;
        r.hasConflicts = rec.Has_Conflicts__c;
        r.conflictDetails = rec.Conflict_Details__c;

        if (rec.Dimension_Results__r != null) {
            for (KB_Dimension_Result__c dr : rec.Dimension_Results__r) {
                KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore(
                    dr.Score__c, dr.Reasoning__c
                );
                s.isUnassessable = dr.Is_Unassessable__c == true;
                s.scorerMode = dr.Scorer_Mode__c;
                s.executionMs = dr.Execution_Ms__c == null ? null : dr.Execution_Ms__c.longValue();
                r.setScore(dr.Dimension__c, s);
            }
        }
        return r;
    }

    /**
     * Persist synchronous run results: create KB_Assessment_Run__c + child
     * KB_Article_Assessment__c records. Sets status to 'Completed' so the
     * record shows up in history views.
     */
    private static void persistSyncResults(
        KBAssessmentModels.AssessmentRunResult runResult,
        Set<String> selectedDimensions,
        Map<String, Decimal> effectiveWeights,
        AssessmentOptions options
    ) {
        Savepoint sp = Database.setSavepoint();
        try {
            KB_Assessment_Run__c run = new KB_Assessment_Run__c(
                Status__c = 'Completed',
                Total_Articles__c = runResult.articleResults.size(),
                // Mirror the ground-truth value computed on the result DTO
 // (true iff a dimension actually ran the LLM). See.
                Used_LLM__c = runResult.usedLLM == true,
                Completed_At__c = Datetime.now(),
                Assessment_Types__c = joinAssessmentTypes(options.assessmentTypes),
                Selected_Dimensions_JSON__c = JSON.serialize(new List<String>(selectedDimensions)),
                Requested_Scope__c = 'Selected'
            );
            insert run;
            runResult.runId = run.Id;

            List<KBAssessmentRecordBuilder.ParentWithChildren> bundles =
                KBAssessmentRecordBuilder.buildAll(run.Id, runResult.articleResults);
            List<KB_Article_Assessment__c> parents = KBAssessmentRecordBuilder.parentsOf(bundles);
            if (!parents.isEmpty()) {
                stampKnowledgeArticleIds(parents);
                insert parents;
                KBAssessmentRecordBuilder.linkChildren(bundles);
                List<KB_Dimension_Result__c> children = KBAssessmentRecordBuilder.flattenChildren(bundles);
                if (!children.isEmpty()) {
                    insert children;
                    List<KB_Dimension_Analysis__c> analyses = KBAssessmentRecordBuilder.buildAnalyses(bundles);
                    if (!analyses.isEmpty()) {
                        insert analyses;
                    }
                }
                finalizeSyncRun(run.Id, runResult);
            }
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR,
                'Failed to persist sync assessment (rolled back): ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            throw new AuraHandledException(
                'Assessment scored successfully but failed to save results: ' + e.getMessage()
                + '. Please try again.');
        }
    }

    /**
     * Populate aggregate fields on the run record for sync-tier runs. The
     * async tiers get this for free via KBAssessmentPipelineCallback; sync
     * doesn't go through that path so we mirror the aggregation here.
     */
    private static void finalizeSyncRun(Id runId, KBAssessmentModels.AssessmentRunResult runResult) {
        if (runResult.articleResults == null || runResult.articleResults.isEmpty()) return;

        Integer total = runResult.articleResults.size();
        Integer readyCount = 0, needsWorkCount = 0, notReadyCount = 0;
        Decimal totalScore = 0;
        for (KBAssessmentModels.ArticleAssessmentResult a : runResult.articleResults) {
            totalScore += a.overallScore == null ? 0 : a.overallScore;
            if (a.readinessStatus == 'Ready') readyCount++;
            else if (a.readinessStatus == 'Needs Work') needsWorkCount++;
            else notReadyCount++;
        }

        Map<String, Decimal> dimAverages = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT Dimension__c dim, AVG(Score__c) avgScore
            FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :runId
              AND Is_Unassessable__c = false
              AND Score__c != null
            GROUP BY Dimension__c
        ]) {
            Object avg = ar.get('avgScore');
            if (avg != null) dimAverages.put((String) ar.get('dim'), ((Decimal) avg).setScale(0));
        }

        update new KB_Assessment_Run__c(
            Id = runId,
            Overall_Score__c      = (totalScore / total).setScale(2),
            Ready_Count__c        = readyCount,
            Needs_Work_Count__c   = needsWorkCount,
            Not_Ready_Count__c    = notReadyCount,
            Completeness_Score__c = dimAverages.get('Completeness'),
            Structure_Score__c    = dimAverages.get('Structure'),
            Clarity_Score__c      = dimAverages.get('Clarity'),
            Freshness_Score__c    = dimAverages.get('Freshness'),
            Duplication_Score__c  = dimAverages.get('Duplication'),
            Conflict_Score__c     = dimAverages.get('Conflict')
        );

        // Also put the aggregate overall score back on the in-memory result.
        runResult.overallScore = (totalScore / total).setScale(2);
        runResult.readyCount = readyCount;
        runResult.needsWorkCount = needsWorkCount;
        runResult.notReadyCount = notReadyCount;
        runResult.totalArticles = total;
    }

    private static String joinAssessmentTypes(List<String> types) {
        if (types == null || types.isEmpty()) return 'Readiness';
        return String.join(types, ';');
    }

    // Knowledge_Article_Id__c is required on KB_Article_Assessment__c but the
    // record builder only has KAV Ids. Resolve KnowledgeArticleId in bulk
    // before insert. Mirrors the async path in KBAssessmentService.
    private static void stampKnowledgeArticleIds(List<KB_Article_Assessment__c> parents) {
        Set<Id> kavIds = new Set<Id>();
        for (KB_Article_Assessment__c p : parents) {
            if (p.Knowledge__c != null && p.Knowledge_Article_Id__c == null) {
                kavIds.add(p.Knowledge__c);
            }
        }
        if (kavIds.isEmpty()) return;

        Map<Id, String> kaIdByKav = new Map<Id, String>();
        // USER_MODE: id-keyed read of system fields only (Id/KnowledgeArticleId),
        // so it respects the running user's access with no content-field FLS risk.
        for (SObject row : Database.query(
            'SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :kavIds',
            AccessLevel.USER_MODE
        )) {
            kaIdByKav.put((Id) row.get('Id'), (String) row.get('KnowledgeArticleId'));
        }
        for (KB_Article_Assessment__c p : parents) {
            if (p.Knowledge_Article_Id__c == null && kaIdByKav.containsKey(p.Knowledge__c)) {
                p.Knowledge_Article_Id__c = kaIdByKav.get(p.Knowledge__c);
            }
        }
    }
}