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
public with sharing class KBAssessmentController {

    @AuraEnabled
    public static KBAssessmentModels.ArticleWrapper getArticleById(String articleVersionId) {
        if (String.isBlank(articleVersionId)) return null;
        try {
            // Whitelist the KAV object name — defense in depth against future
            // changes to getKnowledgeObjectApiNameStatic that could accept input.
            String kavName = KBAssessmentService.getKnowledgeObjectApiNameStatic();
            if (kavName != 'Knowledge__kav') {
                return null;
            }
            // WITH SECURITY_ENFORCED applies field-level security to the dynamic SOQL,
            // matching the rest of the codebase's posture.
            String query = 'SELECT Id, Title, ArticleNumber, Summary, UrlName, LastModifiedDate, PublishStatus'
                + ' FROM ' + kavName
                + ' WHERE Id = :articleVersionId WITH SECURITY_ENFORCED LIMIT 1';
            List<SObject> rows = Database.query(query);
            if (rows.isEmpty()) return null;
            SObject row = rows[0];
            KBAssessmentModels.ArticleWrapper w = new KBAssessmentModels.ArticleWrapper();
            w.id = String.valueOf(row.get('Id'));
            w.title = (String) row.get('Title');
            w.articleNumber = (String) row.get('ArticleNumber');
            w.summary = (String) row.get('Summary');
            w.urlName = (String) row.get('UrlName');
            w.lastModifiedDate = (Datetime) row.get('LastModifiedDate');
            w.publishStatus = (String) row.get('PublishStatus');
            return w;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching article: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<KBAssessmentModels.ArticleWrapper> getKnowledgeArticles(
        String searchTerm,
        Integer limitSize
    ) {
        try {
            KBAssessmentService service = new KBAssessmentService();
            Integer queryLimit = (limitSize != null && limitSize > 0) ? limitSize : 50;
            return service.searchArticles(searchTerm, queryLimit);
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching articles: ' + e.getMessage());
        }
    }

    /**
 * (b) — the quality-gate thresholds the dedup pipeline uses. The
     * run-preview screen surfaces these so users understand that Duplication &
     * Conflict only run for articles whose Completeness / Structure / Clarity
     * clear the configured minimums (default 60, admin-set in Setup). Read-only.
     */
    @AuraEnabled(cacheable=true)
    public static QualityGateThresholds getQualityGateThresholds() {
        try {
            KM_Pipeline_Config__mdt cfg = PipelineConfigService.getActiveConfig();
            QualityGateThresholds t = new QualityGateThresholds();
            t.minCompleteness = cfg.Min_Completeness_Score__c;
            t.minStructure = cfg.Min_Structure_Score__c;
            t.minClarity = cfg.Min_Clarity_Score__c;
            return t;
        } catch (Exception e) {
            throw new AuraHandledException('Error reading quality-gate thresholds: ' + e.getMessage());
        }
    }

    public class QualityGateThresholds {
        @AuraEnabled public Decimal minCompleteness;
        @AuraEnabled public Decimal minStructure;
        @AuraEnabled public Decimal minClarity;
    }

    @AuraEnabled(cacheable=true)
    public static List<PipelineRunSummary> getRecentPipelineRuns(Integer limitSize) {
        try {
            Integer queryLimit = (limitSize != null && limitSize > 0) ? limitSize : 20;
            List<KB_Pipeline_Run__c> runs = [
                SELECT Id, Name, Status__c, Execution_Modes__c, Scope_Type__c,
                       Total_Input_Articles__c, Processed_Count__c, Error_Count__c,
                       Pair_Evaluations_Created__c,
                       Started_At__c, Completed_At__c,
                       Assessment_Run__c
                FROM KB_Pipeline_Run__c
                ORDER BY CreatedDate DESC
                LIMIT :queryLimit
            ];

            List<PipelineRunSummary> summaries = new List<PipelineRunSummary>();
            for (KB_Pipeline_Run__c run : runs) {
                summaries.add(new PipelineRunSummary(run));
            }
            return summaries;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching pipeline runs: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static KBAssessmentModels.AssessmentRunResult runAssessment(List<String> articleIds) {
        return runAssessmentWithOptions(articleIds, null);
    }

    @AuraEnabled
    public static KBAssessmentModels.AssessmentRunResult runAssessmentAdvanced(
        List<String> articleIds,
        String optionsJSON
    ) {
        return runAssessmentWithOptions(articleIds, optionsJSON);
    }

    /**
 * In-place rerun. KEEPS the named run record (same Id, Name,
     * CreatedDate) and re-assesses the *same article set* it was originally run
     * against. The old scores + recommendations stay VISIBLE while the new
     * assessment runs; the service swaps results in on completion (Option B —
     * replace-on-success, failure-safe). Reuses the standard dispatch path
     * (queueable ≤50 / Batch >50) via the service. Returns the run's result
     * (runId is unchanged from the input) so the caller can refresh the list.
     */
    @AuraEnabled
    public static KBAssessmentModels.AssessmentRunResult rerunAssessment(String runId) {
        try {
            if (String.isBlank(runId)) {
                throw new AuraHandledException('Run ID is required.');
            }
            KBAssessmentService service = new KBAssessmentService();
            return service.rerunAssessment(Id.valueOf(runId));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error rerunning assessment: ' + e.getMessage());
        }
    }

    /**
 * the max articles a run (and therefore a clone) can hold: the
     * app-wide scope ceiling (matchingFilterCap, 10k). The All Assessments list
     * reads this to disable the Clone button — with an explanatory tooltip — for
     * a run whose article count exceeds it, rather than opening a modal that
     * would trim the scope. Cacheable: the cap is effectively constant per org.
     */
    @AuraEnabled(cacheable=true)
    public static Integer getCloneArticleCap() {
        return KBAssessmentService.getCloneArticleCapStatic();
    }

    /**
 * Clone prefill. Returns the source run's name suggestion +
     * description and its article scope re-resolved to CURRENT published
     * versions, so the LWC can open the new-assessment modal prepopulated. A
     * clone creates a brand-new run (the source is untouched), preserving
     * history. Not cacheable — re-resolves live versions each call.
     */
    @AuraEnabled
    public static KBAssessmentModels.RunSelectionForClone getRunSelectionForClone(String runId) {
        try {
            if (String.isBlank(runId)) {
                throw new AuraHandledException('Run ID is required.');
            }
            return new KBAssessmentService().getRunSelectionForClone(Id.valueOf(runId));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error loading run selection for clone: ' + e.getMessage());
        }
    }

    /**
 * Batch sibling of getArticleById: hydrate basket rows for a set of
     * KAV version ids (the clone flow seeds the article selector with a whole
     * run's worth of articles). Mirrors getArticleById's lightweight projection
     * + WITH SECURITY_ENFORCED posture — deliberately NOT the heavier
     * KBAssessmentService.fetchArticles (which requires configured content
     * fields and builds full scoring content the picker doesn't need).
     */
    @AuraEnabled
    public static List<KBAssessmentModels.ArticleWrapper> getArticlesByIds(List<String> articleVersionIds) {
        List<KBAssessmentModels.ArticleWrapper> wrappers = new List<KBAssessmentModels.ArticleWrapper>();
        if (articleVersionIds == null || articleVersionIds.isEmpty()) {
            return wrappers;
        }
        try {
            // Whitelist the KAV object name — defense in depth, same as getArticleById.
            String kavName = KBAssessmentService.getKnowledgeObjectApiNameStatic();
            if (kavName != 'Knowledge__kav') {
                return wrappers;
            }
            String query = 'SELECT Id, Title, ArticleNumber, Summary, UrlName, LastModifiedDate, PublishStatus'
                + ' FROM ' + kavName
                + ' WHERE Id IN :articleVersionIds WITH SECURITY_ENFORCED';
            for (SObject row : Database.query(query)) {
                KBAssessmentModels.ArticleWrapper w = new KBAssessmentModels.ArticleWrapper();
                w.id = String.valueOf(row.get('Id'));
                w.title = (String) row.get('Title');
                w.articleNumber = (String) row.get('ArticleNumber');
                w.summary = (String) row.get('Summary');
                w.urlName = (String) row.get('UrlName');
                w.lastModifiedDate = (Datetime) row.get('LastModifiedDate');
                w.publishStatus = (String) row.get('PublishStatus');
                wrappers.add(w);
            }
            return wrappers;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching articles: ' + e.getMessage());
        }
    }

    private static KBAssessmentModels.AssessmentRunResult runAssessmentWithOptions(
        List<String> articleIds,
        String optionsJSON
    ) {
        try {
            if (articleIds == null || articleIds.isEmpty()) {
                throw new AuraHandledException('Please select at least one article to assess.');
            }

            KBAssessmentService service = new KBAssessmentService();
            KBAssessmentModels.AssessmentRunOptions options = String.isNotBlank(optionsJSON)
                ? (KBAssessmentModels.AssessmentRunOptions) JSON.deserialize(optionsJSON, KBAssessmentModels.AssessmentRunOptions.class)
                : new KBAssessmentModels.AssessmentRunOptions();
            return service.runAssessment(articleIds, options);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error running assessment: ' + e.getMessage());
        }
    }

    /**
     * Cacheable variant — used by the historical results pages (run history,
     * post-completion review). Lightning's wire cache is fine here because the
     * UI re-renders on navigation, not on platform-event ticks.
     *
     * Do NOT use during an active run — see getAssessmentResultsLive.
     */
    @AuraEnabled(cacheable=true)
    public static KBAssessmentModels.AssessmentRunResult getAssessmentResults(String runId) {
        return loadAssessmentResults(runId);
    }

    /**
     * Non-cacheable variant — used by the live runner LWC's safety-net poll
     * and post-Completed event reload. Cacheable=true bites here: the first
     * mid-run poll caches an all-null/zero payload (status=Pending, scores
     * not yet rolled up), and the post-Completed reload then hits that
     * cached blob, painting an all-zero "Assessment Results" section.
     * This entry point bypasses the LDS cache so the UI sees the persisted
     * row written in the same DML as Status='Completed'.
     */
    @AuraEnabled
    public static KBAssessmentModels.AssessmentRunResult getAssessmentResultsLive(String runId) {
        return loadAssessmentResults(runId);
    }

    private static KBAssessmentModels.AssessmentRunResult loadAssessmentResults(String runId) {
        try {
            if (String.isBlank(runId)) {
                throw new AuraHandledException('Run ID is required.');
            }

            KB_Assessment_Run__c run = [
                SELECT Id, Name, Run_Name__c, Description__c, Status__c, Status_Message__c, Total_Articles__c, Overall_Score__c,
                       Ready_Count__c, Needs_Work_Count__c, Not_Ready_Count__c,
                       Completed_At__c, Scan_Start_Time__c, CreatedDate,
                       Completeness_Score__c, Structure_Score__c, Clarity_Score__c,
                       Freshness_Score__c, Duplication_Score__c, Conflict_Score__c,
                       KB_Maturity_Tier__c, Deployment_Tier__c, Used_LLM__c,
                       Assessment_Types__c, Requested_Scope__c, Selected_Dimensions_JSON__c,
                       Pipeline_Run__c
                FROM KB_Assessment_Run__c
                WHERE Id = :runId
                LIMIT 1
            ];

            KBAssessmentModels.AssessmentRunResult result = mapRunToRunResult(run);

            List<KB_Article_Assessment__c> assessments = [
                SELECT Id, Knowledge__c, Article_Title__c, Article_Number__c, Knowledge_Article_Id__c, Overall_Score__c,
                       Readiness_Status__c, Pipeline_Skip_Reason__c,
                       Has_Conflicts__c, Conflict_Details__c,
                       (SELECT Dimension__c, Score__c, Reasoning__c,
                               Is_Unassessable__c, Scorer_Mode__c
                        FROM Dimension_Results__r),
                       (SELECT Dimension__c, Recommendation__c, Impact__c, Status__c
                        FROM Dimension_Analyses__r
                        WHERE Type__c = 'Issue'
                        ORDER BY Dimension__c)
                FROM KB_Article_Assessment__c
                WHERE Assessment_Run__c = :runId
                ORDER BY Overall_Score__c DESC
            ];

            result.articleResults = new List<KBAssessmentModels.ArticleAssessmentResult>();

 // determine which assessed article versions the running user
            // can still reach. A row is unreachable when the article was deleted
 // (Knowledge__c nulled by the SetNull constraint,) or the user
            // lost access (moved to a data category / FLS they lack). One
            // USER_MODE query over the version ids in this run: an id that comes
            // back is reachable; a null or absent id is not. The card then greys
            // the row and drops the open-article + View Actions links that would
            // otherwise dead-end, while title/score still render from the snapshot.
            Set<Id> reachableVersionIds = getReachableArticleVersionIds(assessments);

            for (KB_Article_Assessment__c assessment : assessments) {
                result.articleResults.add(
                    mapAssessmentToResult(assessment, reachableVersionIds)
                );
            }

            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching results: ' + e.getMessage());
        }
    }

    /**
 * the set of assessed article VERSION ids the running user can still
     * reach. Runs a single USER_MODE query over the non-null Knowledge__c ids in
     * the result set: an id that returns is reachable; a deleted (already null)
     * or access-lost (data-category / FLS) id does not come back. USER_MODE is
     * deliberate — it enforces the running user's row + FLS access so a lost-
     * access article reads as unreachable, matching what the open-article link
     * would hit. Returns an empty set when there are no non-null ids.
     */
    private static Set<Id> getReachableArticleVersionIds(
        List<KB_Article_Assessment__c> assessments
    ) {
        Set<Id> versionIds = new Set<Id>();
        for (KB_Article_Assessment__c a : assessments) {
            if (a.Knowledge__c != null) {
                versionIds.add(a.Knowledge__c);
            }
        }
        Set<Id> reachable = new Set<Id>();
        if (versionIds.isEmpty()) {
            return reachable;
        }
        for (Knowledge__kav kav : [
            SELECT Id FROM Knowledge__kav WHERE Id IN :versionIds WITH USER_MODE
        ]) {
            reachable.add(kav.Id);
        }
        return reachable;
    }

    /**
     * Returns a lightweight run diagnostics bundle for the run-detail error
     * panel (1.0.I). Read-only — pulls the run's own status + any KB-prefixed
     * AsyncApexJob failures that occurred in the run's time window. Handy for
     * users staring at a red run badge with no "what went wrong" hint.
     */
    @AuraEnabled(cacheable=true)
    public static RunDiagnosticsInfo getRunDiagnostics(String runId) {
        if (String.isBlank(runId)) return null;
        try {
            List<KB_Assessment_Run__c> runs = [
                SELECT Id, Name, Status__c, Total_Articles__c, CreatedDate, LastModifiedDate
                FROM KB_Assessment_Run__c
                WHERE Id = :runId
                WITH USER_MODE
                LIMIT 1
            ];
            if (runs.isEmpty()) return null;
            KB_Assessment_Run__c run = runs[0];

            RunDiagnosticsInfo info = new RunDiagnosticsInfo();
            info.runId = run.Id;
            info.status = run.Status__c;
            info.totalArticles = run.Total_Articles__c != null ? (Integer) run.Total_Articles__c : 0;
            info.createdAt = run.CreatedDate;
            info.lastModifiedAt = run.LastModifiedDate;

            // Time-bounded query: from run start to now (or last modified + 5 min,
            // whichever is later). Prevents the query from scanning the whole org.
            Datetime windowEnd = run.LastModifiedDate != null
                ? run.LastModifiedDate.addMinutes(5)
                : System.now();
            info.failures = new List<RunFailureRow>();
            // AsyncApexJob is platform-internal; USER_MODE still applies standard
            // access gates, so a user without AsyncApexJob visibility won't see
            // failures here (acceptable — they can't triage what they can't see).
            for (AsyncApexJob j : [
                SELECT Id, ApexClass.Name, Status, ExtendedStatus, CreatedDate, JobType, MethodName
                FROM AsyncApexJob
                WHERE Status IN ('Failed', 'Aborted')
                  AND ApexClass.Name LIKE 'KB%'
                  AND CreatedDate >= :run.CreatedDate
                  AND CreatedDate <= :windowEnd
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 20
            ]) {
                RunFailureRow row = new RunFailureRow();
                row.jobId = j.Id;
                row.className = j.ApexClass != null ? j.ApexClass.Name : '(unknown)';
                row.methodName = j.MethodName;
                row.status = j.Status;
                row.extendedStatus = KBDiagnosticsController.sanitiseExtendedStatus(j.ExtendedStatus);
                row.jobType = j.JobType;
                row.createdAt = j.CreatedDate;
                info.failures.add(row);
            }
            return info;
        } catch (Exception e) {
            throw new AuraHandledException('Could not load run diagnostics: ' + e.getMessage());
        }
    }

    public class RunDiagnosticsInfo {
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Integer totalArticles { get; set; }
        @AuraEnabled public Datetime createdAt { get; set; }
        @AuraEnabled public Datetime lastModifiedAt { get; set; }
        @AuraEnabled public List<RunFailureRow> failures { get; set; }
    }

    public class RunFailureRow {
        @AuraEnabled public Id jobId { get; set; }
        @AuraEnabled public String className { get; set; }
        @AuraEnabled public String methodName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String extendedStatus { get; set; }
        @AuraEnabled public String jobType { get; set; }
        @AuraEnabled public Datetime createdAt { get; set; }
    }

    // ==================== Article record page — runs + analyses ====================
    // Renders the History tab in the Article Health panel (knowledgeConsistencyChecker)
    // on the Knowledge record page.
    // Reads KB_Dimension_Analysis__c (Type__c = Issue | Strength) — the model
    // that replaced the legacy KB_Recommendation__c. Naming here uses the
    // domain term "Analysis" (parent), with "issue / strength" as the
    // discriminator, NOT "recommendation". Recommendation__c is retained on
    // the SObject as the actionable-fix text for Issue rows only.
    //
    // Schema chain (no new lookup):
    //   Knowledge__kav --(Knowledge__c)→ KB_Article_Assessment__c
    //                              └---(Article_Assessment__c)→ KB_Dimension_Analysis__c
    //
    // The standard related list on Knowledge__kav already exposes the
    // KB_Article_Assessments__r child. Analyses (KB_Dimension_Analysis__c)
    // are 2 hops from Knowledge__kav with no direct lookup. A direct lookup
    // would let admins surface a flat related list on the Knowledge layout,
    // but per scoping it's intentionally not added here — this LWC serves
    // the same view via 2-hop SOQL. If a layout admin later needs the
    // direct hop, add `Knowledge__c` lookup on KB_Dimension_Analysis__c +
    // wire it in KBDimensionAnalysisService at insert time (denormalized).

    public class ArticleRunAnalysis {
        @AuraEnabled public Id id { get; set; }
        @AuraEnabled public String dimension { get; set; }
        @AuraEnabled public String type { get; set; }            // 'Issue' or 'Strength'
        @AuraEnabled public String analysisText { get; set; }    // KB_Dimension_Analysis__c.Analysis_Text__c
        @AuraEnabled public String fixSuggestion { get; set; }   // KB_Dimension_Analysis__c.Recommendation__c — null for Strength rows
        @AuraEnabled public String impact { get; set; }          // KB_Dimension_Analysis__c.Impact__c — null for Strength rows
        @AuraEnabled public String status { get; set; }
    }

    public class ArticleRunRow {
        @AuraEnabled public Id assessmentId { get; set; }
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public Datetime runDate { get; set; }
        @AuraEnabled public String runStatus { get; set; }
 // run identity for the run picker: the assessment's display name
        // (user-supplied Run_Name__c, else auto-number Name) and who ran it
        // (the run owner). Lets the picker read "Hurricane audit · Jul 6 · <run owner>"
        // instead of a bare score.
        @AuraEnabled public String runName { get; set; }
        @AuraEnabled public String ranBy { get; set; }
        @AuraEnabled public Decimal overallScore { get; set; }
        @AuraEnabled public String readinessStatus { get; set; }
        @AuraEnabled public String pipelineSkipReason { get; set; }
        @AuraEnabled public Integer issueCount { get; set; }
        @AuraEnabled public Integer strengthCount { get; set; }
        // Version stamp for cross-version history. assessedVersionId is the
        // KAV id this row's assessment ran against; versionNumber is its
        // VersionNumber on Knowledge__kav. Lets the LWC tag rows like "v2"
        // and filter "this version only" vs "all versions".
        @AuraEnabled public Id assessedVersionId { get; set; }
        @AuraEnabled public Decimal versionNumber { get; set; }
        @AuraEnabled public List<ArticleRunAnalysis> issues { get; set; }
        @AuraEnabled public List<ArticleRunAnalysis> strengths { get; set; }

        public ArticleRunRow() {
            this.issues = new List<ArticleRunAnalysis>();
            this.strengths = new List<ArticleRunAnalysis>();
            this.issueCount = 0;
            this.strengthCount = 0;
        }
    }

    /**
     * Returns the assessments for a given Knowledge article (CANONICAL id —
     * KnowledgeArticleId, not KAV/version id) with their issues + strengths
     * inlined. Used by the knowledgeConsistencyChecker sidebar component on
     * the Knowledge record page (Strengths tab + run selector).
     *
     * Filtering by canonical id (not Knowledge__c, the KAV FK) is intentional:
     * after a "Fix issues with AI" run creates a fresh draft, that draft has
     * a new KAV id but the same KnowledgeArticleId. Users want to see the
     * trajectory of scores across versions, not just this version's runs.
     * Each row stamps the assessedVersionId + versionNumber so the LWC can
     * label and optionally filter by version.
     *
     * Caps at 25 most-recent assessments and 50 issues + 25 strengths per
     * assessment to keep payload size sane on long-lived articles.
     * Cacheable — Lightning's record-id-keyed cache makes the wire
     * idempotent across re-renders.
     *
     * @param articleId  Either a KAV (version) id or the canonical
     *                   KnowledgeArticleId. KAV ids are resolved to their
     *                   canonical id before the assessment query runs.
     *
     * Breaking change: the param was renamed from `knowledgeArticleVersionId`
     * to `articleId` (now accepts either id type). The repo is unmanaged with
     * no namespace; no external Apex consumers should depend on the parameter
     * name. The knowledgeConsistencyChecker LWC is the only known caller and
     * has been updated. If a downstream caller breaks at compile, replace
     * `knowledgeArticleVersionId:` with `articleId:` in the call site.
     */
    @AuraEnabled(cacheable=true)
    public static List<ArticleRunRow> getRunsAndAnalysesForArticle(String articleId) {
        if (String.isBlank(articleId)) return new List<ArticleRunRow>();
        try {
            // Resolve a KAV id → canonical KnowledgeArticleId so the LWC can
            // pass recordId without a separate getRecord round-trip (the
            // getRecord wire on Knowledge__kav.KnowledgeArticleId can stall
            // silently when FLS is incomplete — this Apex hop is reliable).
            // KAV ids start with `ka` (lowercase prefix); canonical ids
            // start with `kA`. The keyPrefix check is case-sensitive.
            String canonicalId = articleId;
            if (articleId.startsWith('ka')) {
                List<Knowledge__kav> kavs = [
                    SELECT KnowledgeArticleId
                    FROM Knowledge__kav
                    WHERE Id = :articleId
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (kavs.isEmpty()) return new List<ArticleRunRow>();
                canonicalId = kavs[0].KnowledgeArticleId;
            }

            // WITH SYSTEM_MODE here on purpose (explicit, not accidental). CLAUDE.md
            // documents that the shipped permsets do not grant FLS on
            // Knowledge__kav fields (customer's responsibility), so a USER_MODE /
            // WITH SECURITY_ENFORCED query would throw on Knowledge__r.VersionNumber
            // for any assigned user. The class is `with sharing` so record-level
            // visibility is still enforced via the running user's sharing rules;
            // SYSTEM_MODE only relaxes field/entity-level enforcement, which is the
            // documented, intended behaviour here (SAST: explicit system-mode).
            // Per-parent nested subquery (single round-trip). Each assessment
            // gets its own slice of analyses, so an older assessment with a
            // huge analysis count can no longer fill a shared window and starve
 // newer runs of rows. The subquery LIMIT is per parent; we
            // pull 75 (the 50-issue + 25-strength display caps combined) ordered
            // by impact so the highest-impact rows survive, then split by type
            // in Apex below.
            List<KB_Article_Assessment__c> assessments = [
                SELECT Id, Knowledge__c, Overall_Score__c, Readiness_Status__c, Pipeline_Skip_Reason__c,
                       Knowledge__r.VersionNumber,
                       Assessment_Run__c,
                       Assessment_Run__r.Status__c,
                       Assessment_Run__r.Run_Name__c,
                       Assessment_Run__r.Name,
                       Assessment_Run__r.Owner.Name,
                       Assessment_Run__r.Scan_Start_Time__c,
                       Assessment_Run__r.Completed_At__c,
                       Assessment_Run__r.CreatedDate,
                       // Trade-off acknowledged: we pull a single combined
                       // LIMIT 75 window ordered by impact, then split
                       // Issue/Strength in Apex (50/25 caps). A theoretically
                       // cleaner split into two type-partitioned subqueries is NOT
                       // possible here — SOQL forbids following the same child
                       // relationship twice ("Cannot follow the same aggregate
                       // relationship twice: Dimension_Analyses__r"). Edge case:
                       // if an article has 25+ very-high-impact strengths AND 50+
                       // issues, strengths could crowd the window and under-fill
                       // the issue cap. In practice issues vastly outnumber and
                       // out-rank strengths on low-scoring articles (the ones this
                       // sidebar surfaces), so the combined window is acceptable.
                       // Impact__c is a restricted picklist (High/Medium/Low);
                       // SOQL orders it by the declared value order, so ASC keeps
                       // the highest-impact rows at the front of the window.
                       (
                           SELECT Id, Dimension__c, Type__c,
                                  Analysis_Text__c, Recommendation__c,
                                  Impact__c, Status__c
                           FROM Dimension_Analyses__r
                           ORDER BY Impact__c ASC NULLS LAST, Dimension__c ASC
                           LIMIT 75
                       )
                FROM KB_Article_Assessment__c
                WHERE Knowledge_Article_Id__c = :canonicalId
                WITH SYSTEM_MODE
                ORDER BY CreatedDate DESC
                LIMIT 25
            ];
            if (assessments.isEmpty()) return new List<ArticleRunRow>();

            // Per-assessment buckets for issues + strengths.
            Map<Id, List<ArticleRunAnalysis>> issuesByAssessment = new Map<Id, List<ArticleRunAnalysis>>();
            Map<Id, List<ArticleRunAnalysis>> strengthsByAssessment = new Map<Id, List<ArticleRunAnalysis>>();

            for (KB_Article_Assessment__c assessment : assessments) {
                if (assessment.Dimension_Analyses__r == null) continue;
                for (KB_Dimension_Analysis__c rec : assessment.Dimension_Analyses__r) {
                    ArticleRunAnalysis a = new ArticleRunAnalysis();
                    a.id = rec.Id;
                    a.dimension = rec.Dimension__c;
                    a.type = rec.Type__c;
                    a.analysisText = rec.Analysis_Text__c;
                    a.fixSuggestion = rec.Recommendation__c;
                    a.impact = rec.Impact__c;
                    a.status = rec.Status__c;

                    Map<Id, List<ArticleRunAnalysis>> target = (a.type == 'Strength')
                        ? strengthsByAssessment
                        : issuesByAssessment;
                    Integer cap = (a.type == 'Strength') ? 25 : 50;
                    List<ArticleRunAnalysis> bucket = target.get(assessment.Id);
                    if (bucket == null) {
                        bucket = new List<ArticleRunAnalysis>();
                        target.put(assessment.Id, bucket);
                    }
                    if (bucket.size() < cap) {
                        bucket.add(a);
                    }
                }
            }

 // a Conflict finding shown on the article record links to the
            // Action Centre queue, which only surfaces Pending candidates. When
            // the underlying pair has been marked "not a duplicate" (or the
            // legacy Rejected/Suppressed), the queue no longer lists it, so the
            // article-side finding becomes a dead-end ("shown but missing from
            // Action Centre"). Compute, per assessed version + run, whether every
            // conflict-type candidate is discarded; if so we drop the Conflict
            // issues from that row so both surfaces agree. Soft/this-run-only: a
            // re-run re-evaluates the pair (Tier3PairEvaluator), so it re-surfaces
            // on both surfaces together next time.
            Set<String> hideConflictForVersionRun = conflictHiddenKeys(assessments);
 // same dead-end fix for the (higher-volume) Duplication dimension.
            Set<String> hideDuplicationForVersionRun = duplicationHiddenKeys(assessments);

            List<ArticleRunRow> rows = new List<ArticleRunRow>();
            for (KB_Article_Assessment__c a : assessments) {
                ArticleRunRow row = new ArticleRunRow();
                row.assessmentId = a.Id;
                row.assessedVersionId = a.Knowledge__c;
                row.versionNumber = a.Knowledge__r != null ? a.Knowledge__r.VersionNumber : null;
                row.runId = a.Assessment_Run__c;
                row.runStatus = a.Assessment_Run__r != null ? a.Assessment_Run__r.Status__c : null;
 // surface run identity in the picker (name + who ran it),
                // not just a raw score. Prefer the user-supplied Run_Name__c;
                // fall back to the auto-number Name. ranBy is the run owner
                // (runs are owned by the user who ran them — see CLAUDE.md).
                if (a.Assessment_Run__r != null) {
                    row.runName = String.isNotBlank(a.Assessment_Run__r.Run_Name__c)
                        ? a.Assessment_Run__r.Run_Name__c
                        : a.Assessment_Run__r.Name;
                    row.ranBy = a.Assessment_Run__r.Owner != null
                        ? a.Assessment_Run__r.Owner.Name
                        : null;
                }
                Datetime started = a.Assessment_Run__r != null ? a.Assessment_Run__r.Scan_Start_Time__c : null;
                Datetime completed = a.Assessment_Run__r != null ? a.Assessment_Run__r.Completed_At__c : null;
                Datetime runCreated = a.Assessment_Run__r != null ? a.Assessment_Run__r.CreatedDate : null;
                // Pick the most useful date: completed > started > created.
                row.runDate = completed != null ? completed : (started != null ? started : runCreated);
                row.overallScore = a.Overall_Score__c;
                row.readinessStatus = a.Readiness_Status__c;
                row.pipelineSkipReason = a.Pipeline_Skip_Reason__c;

                String versionRunKey = conflictKey(a.Knowledge__c, a.Assessment_Run__c);
                Boolean hideConflicts = hideConflictForVersionRun.contains(versionRunKey);
                Boolean hideDuplication = hideDuplicationForVersionRun.contains(versionRunKey);

                List<ArticleRunAnalysis> issueBucket = issuesByAssessment.get(a.Id);
                if (issueBucket != null) {
                    if (hideConflicts || hideDuplication) {
                        List<ArticleRunAnalysis> filtered = new List<ArticleRunAnalysis>();
                        for (ArticleRunAnalysis ia : issueBucket) {
                            if (hideConflicts && ia.dimension == 'Conflict') continue;
                            if (hideDuplication && ia.dimension == 'Duplication') continue;
                            filtered.add(ia);
                        }
                        issueBucket = filtered;
                    }
                    row.issues = issueBucket;
                    row.issueCount = issueBucket.size();
                }
                List<ArticleRunAnalysis> strengthBucket = strengthsByAssessment.get(a.Id);
                if (strengthBucket != null) {
                    row.strengths = strengthBucket;
                    row.strengthCount = strengthBucket.size();
                }
                rows.add(row);
            }
            return rows;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to load runs and analyses: ' + e.getMessage());
        }
    }

    /**
 * Build the set of "<assessedVersionId>|<runId>" keys for which the
     * article-side Conflict finding should be HIDDEN because every conflict-type
     * Duplicate_Candidate for that version+run is discarded/absent from the
     * queue. A version with at least one still-Pending conflict candidate keeps
     * its Conflict finding visible.
     *
 * Join note (field-naming trap — see): a candidate stores the
     * KnowledgeArticleVERSION id in Knowledge_Article_1__c / Knowledge_Article_2__c
     * (despite the "Article" name); the article-level KnowledgeArticleId lives in
     * Knowledge_Article_Id_1__c / _2__c. We match the assessed VERSION
     * (KB_Article_Assessment__c.Knowledge__c) against the version fields so the
     * hide is version-specific — consistent with the version-keyed discard.
     */
    private static Set<String> conflictHiddenKeys(List<KB_Article_Assessment__c> assessments) {
        // The Conflict dimension is driven by {'Contradiction','Overlap'} (see
        // KBConflictScorer / KBAssessmentPipelineCallback). 'Overlap' stays a
 // hardcoded literal so this is still valid after retires the value.
        return hiddenKeysForFlagTypes(assessments, new Set<String>{ 'Contradiction', 'Overlap' });
    }

    /**
 * Duplication analog of conflictHiddenKeys. A Duplicate candidate
     * marked discarded ('Not a Duplicate' etc.) must hide the article-side
     * Duplication finding too, or the record page keeps a "Resolve in Action
     * Centre" button that lands on an empty queue. Duplicate is the most common
 * flag type, so this is the higher-volume half of the dead-end fixes.
     */
    private static Set<String> duplicationHiddenKeys(List<KB_Article_Assessment__c> assessments) {
        return hiddenKeysForFlagTypes(assessments, new Set<String>{ 'Duplicate' });
    }

    /**
 * shared engine for the per-(assessedVersion|run) "hide the
     * article-side finding" computation. Returns the keys for which EVERY
     * candidate of the given flag types is discarded/absent (none still
     * Pending), so the finding links to a queue that would show nothing.
     * Soft/this-run-only: a re-run re-evaluates the pair (Tier3PairEvaluator),
     * so it re-surfaces on both surfaces together next time.
     *
 * Join note (field-naming trap — see): a candidate stores the
     * KnowledgeArticleVERSION id in Knowledge_Article_1__c / Knowledge_Article_2__c
     * (despite the "Article" name); the article-level KnowledgeArticleId lives in
     * Knowledge_Article_Id_1__c / _2__c. We match the assessed VERSION
     * (KB_Article_Assessment__c.Knowledge__c) against the version fields so the
     * hide is version-specific — consistent with the version-keyed discard.
     */
    private static Set<String> hiddenKeysForFlagTypes(
        List<KB_Article_Assessment__c> assessments,
        Set<String> flagTypes
    ) {
        Set<String> result = new Set<String>();

        // Collect the (version, run) pairs in scope.
        Set<Id> versionIds = new Set<Id>();
        Set<Id> runIds = new Set<Id>();
        for (KB_Article_Assessment__c a : assessments) {
            if (a.Knowledge__c != null && a.Assessment_Run__c != null) {
                versionIds.add(a.Knowledge__c);
                runIds.add(a.Assessment_Run__c);
            }
        }
        if (versionIds.isEmpty()) return result;

        // Version id is 18 chars; the candidate side fields are Text, so bind the
        // string form.
        Set<String> versionIdStrs = new Set<String>();
        for (Id v : versionIds) versionIdStrs.add(String.valueOf(v));

        // Per (version|run): does any matching candidate remain Pending?
        Map<String, Boolean> anyPendingByKey = new Map<String, Boolean>();
        Map<String, Boolean> anyCandidateByKey = new Map<String, Boolean>();

        for (Duplicate_Candidate__c dc : [
            SELECT Status__c, Assessment_Run__c,
                   Knowledge_Article_1__c, Knowledge_Article_2__c
            FROM Duplicate_Candidate__c
            WHERE Flag_Type__c IN :flagTypes
              AND Assessment_Run__c IN :runIds
              AND (Knowledge_Article_1__c IN :versionIdStrs
                   OR Knowledge_Article_2__c IN :versionIdStrs)
            WITH SYSTEM_MODE
        ]) {
            // A candidate can name two in-scope versions; attribute it to whichever
            // side(s) are in scope so each version's row decides independently.
            for (String side : new List<String>{ dc.Knowledge_Article_1__c, dc.Knowledge_Article_2__c }) {
                if (!versionIdStrs.contains(side)) continue;
                String key = conflictKey(side, dc.Assessment_Run__c);
                anyCandidateByKey.put(key, true);
                if (dc.Status__c == 'Pending') {
                    anyPendingByKey.put(key, true);
                }
            }
        }

        // Hide only where at least one matching candidate existed AND none remain Pending.
        for (String key : anyCandidateByKey.keySet()) {
            if (anyPendingByKey.get(key) != true) {
                result.add(key);
            }
        }
        return result;
    }

    private static String conflictKey(Id versionId, Id runId) {
        return String.valueOf(versionId) + '|' + String.valueOf(runId);
    }

    private static String conflictKey(String versionId, Id runId) {
        return versionId + '|' + String.valueOf(runId);
    }

    /**
     * Returns the most recent assessment for a Knowledge article version
     * (KnowledgeArticleVersion id). Used by the record-page sidebar
     * (kbConsistencyChecker → Readiness tab). Read-only, no pipeline work.
     *
     * Returns null when no assessment exists yet so the LWC can render a
     * "no assessment" empty state with a deep link.
     *
     * @param articleVersionId Knowledge article version id (KAV), not the canonical KnowledgeArticleId
     */
    @AuraEnabled(cacheable=true)
    public static KBAssessmentModels.ArticleAssessmentResult getLatestAssessmentForArticle(String articleVersionId) {
        if (String.isBlank(articleVersionId)) return null;
        try {
            return KBAssessmentFacade.getExistingAssessment(articleVersionId);
        } catch (Exception e) {
            throw new AuraHandledException('Could not load latest assessment: ' + e.getMessage());
        }
    }

    /**
     * Lightweight existence check for completed assessment runs. Used by LWCs
     * to decide whether to show a first-run coach banner or a zero-state
     * CTA. Cacheable so it's a single read per session unless invalidated.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean hasAnyRuns() {
        try {
            return [SELECT COUNT() FROM KB_Assessment_Run__c WITH USER_MODE LIMIT 1] > 0;
        } catch (Exception e) {
            return false;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<AssessmentRunSummary> getRecentRuns(Integer limitSize) {
        return loadRecentRuns(limitSize);
    }

    /**
     * Non-cacheable variant of getRecentRuns. Mirrors the split applied to
 * getAssessmentResults / getAssessmentResultsLive in — the LDS
     * cache for the cacheable variant can serve a stale snapshot from
     * mid-run (status = 'Pipeline Running' or 'Scoring Complete') even
     * after the run has flipped to 'Completed' on the server. Callers that
     * need a fresh read after a run terminates use this Live variant; the
     * cacheable variant remains for navigation-time list rendering where
     * the cache is the right behaviour.
     */
    @AuraEnabled
    public static List<AssessmentRunSummary> getRecentRunsLive(Integer limitSize) {
        return loadRecentRuns(limitSize);
    }

    private static List<AssessmentRunSummary> loadRecentRuns(Integer limitSize) {
        try {
            Integer queryLimit = (limitSize != null && limitSize > 0) ? limitSize : 10;
            KBAssessmentService service = new KBAssessmentService();
            List<KB_Assessment_Run__c> runs = service.getRecentAssessmentRuns(queryLimit);

            List<AssessmentRunSummary> summaries = new List<AssessmentRunSummary>();
            for (KB_Assessment_Run__c run : runs) {
                summaries.add(new AssessmentRunSummary(run));
            }

            return summaries;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching recent runs: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void deleteAssessmentRun(String runId) {
        try {
            if (String.isBlank(runId)) {
                throw new AuraHandledException('Run ID is required.');
            }

            KBAssessmentService service = new KBAssessmentService();
            service.deleteAssessmentRun(Id.valueOf(runId));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error deleting run: ' + e.getMessage());
        }
    }

    /**
 * counts of the candidate records that a run delete will remove, so
     * the delete-confirmation dialog can tell the user exactly what they lose
     * ("x enrichment candidates, y duplicate candidates"). Counts ALL statuses,
     * matching deleteAssessmentRun's delete-everything behaviour. Cacheable —
     * the LWC reads it just before showing the confirm.
     */
    @AuraEnabled(cacheable=true)
    public static RunDeletionImpact getRunDeletionImpact(String runId) {
        RunDeletionImpact impact = new RunDeletionImpact();
        if (String.isBlank(runId)) {
            return impact;
        }
        Id runIdSafe;
        try {
            runIdSafe = Id.valueOf(runId);
        } catch (Exception e) {
            return impact;
        }
        impact.enrichmentCandidateCount = [
            SELECT COUNT() FROM Enrichment_Candidate__c
            WHERE Assessment_Run__c = :runIdSafe WITH USER_MODE
        ];
        impact.duplicateCandidateCount = [
            SELECT COUNT() FROM Duplicate_Candidate__c
            WHERE Assessment_Run__c = :runIdSafe WITH USER_MODE
        ];
        return impact;
    }

 /** what a run delete will remove, for the confirmation dialog. */
    public class RunDeletionImpact {
        @AuraEnabled public Integer enrichmentCandidateCount = 0;
        @AuraEnabled public Integer duplicateCandidateCount = 0;
    }

    /**
 * Cancel an in-flight assessment run. Idempotent on terminal
     * states. The actual abort + audit-stamp logic lives in
     * KBAssessmentService.cancelAssessmentRun. CRUD/FLS is enforced at the
     * service-layer DML via `update as user`, so a Viewer (read-only on the
     * run object + cancellation fields) hits an InsufficientAccess error
     * that we surface here as a clean AuraHandledException.
     */
    @AuraEnabled
    public static void cancelAssessmentRun(String runId) {
        try {
            if (String.isBlank(runId)) {
                throw new AuraHandledException('Run ID is required.');
            }
            KBAssessmentService.cancelAssessmentRun(Id.valueOf(runId));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error cancelling run: ' + e.getMessage());
        }
    }

    /**
     * Check the status of an assessment run (for polling async LLM jobs)
     * Not cacheable so we always get fresh data
     */
    @AuraEnabled
    public static KBAssessmentModels.AssessmentRunResult checkRunStatus(String runId) {
        try {
            if (String.isBlank(runId)) {
                throw new AuraHandledException('Run ID is required.');
            }

            KB_Assessment_Run__c run = [
                SELECT Id, Name, Run_Name__c, Description__c, Status__c, Status_Message__c, Total_Articles__c, Overall_Score__c,
                       Ready_Count__c, Needs_Work_Count__c, Not_Ready_Count__c,
                       Completed_At__c, CreatedDate,
                       Completeness_Score__c, Structure_Score__c, Clarity_Score__c,
                       Freshness_Score__c, Duplication_Score__c, Conflict_Score__c,
                       KB_Maturity_Tier__c, Deployment_Tier__c, Used_LLM__c,
                       Assessment_Types__c, Requested_Scope__c, Selected_Dimensions_JSON__c,
                       Pipeline_Run__c
                FROM KB_Assessment_Run__c
                WHERE Id = :runId
                WITH USER_MODE
                LIMIT 1
            ];

            KBAssessmentModels.AssessmentRunResult result = mapRunToRunResult(run);

            // Only load article results if run is completed
            if (run.Status__c == 'Completed') {
                List<KB_Article_Assessment__c> assessments = [
                    SELECT Id, Knowledge__c, Article_Title__c, Article_Number__c, Knowledge_Article_Id__c, Overall_Score__c,
                           Readiness_Status__c, Pipeline_Skip_Reason__c,
                           Has_Conflicts__c, Conflict_Details__c,
                           (SELECT Dimension__c, Score__c, Reasoning__c,
                                   Is_Unassessable__c, Scorer_Mode__c
                            FROM Dimension_Results__r),
                           (SELECT Dimension__c, Recommendation__c, Impact__c, Status__c
                            FROM Dimension_Analyses__r
                            WHERE Type__c = 'Issue'
                            ORDER BY Dimension__c)
                    FROM KB_Article_Assessment__c
                    WHERE Assessment_Run__c = :runId
                    // WITH SYSTEM_MODE (not USER_MODE): this completed-run subquery
                    // selects Knowledge_Article_Id__c + Pipeline_Skip_Reason__c, which
                    // no shipped permset grants to KB_Assessment_Viewer. The live
                    // run-progress poll (kbAssessmentRunProgress) hits this for a
                    // Viewer the moment a run completes — USER_MODE would throw and
                    // break the panel. Mirrors the sibling loadAssessmentResults,
                    // which serves the same fields in system mode by design.
                    WITH SYSTEM_MODE
                    ORDER BY Overall_Score__c DESC
                ];

                result.articleResults = new List<KBAssessmentModels.ArticleAssessmentResult>();
                for (KB_Article_Assessment__c assessment : assessments) {
                    result.articleResults.add(mapAssessmentToResult(assessment));
                }
            }

            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error checking run status: ' + e.getMessage());
        }
    }

    private static final String RUN_FIELDS = 'Id, Name, Status__c, Total_Articles__c, Overall_Score__c, ' +
        'Ready_Count__c, Needs_Work_Count__c, Not_Ready_Count__c, ' +
        'Completed_At__c, CreatedDate, ' +
        'Completeness_Score__c, Structure_Score__c, Clarity_Score__c, ' +
        'Freshness_Score__c, Duplication_Score__c, Conflict_Score__c, ' +
        'KB_Maturity_Tier__c, Deployment_Tier__c, Used_LLM__c, ' +
        'Assessment_Types__c, Requested_Scope__c, Selected_Dimensions_JSON__c, Pipeline_Run__c';

    @AuraEnabled(cacheable=true)
    public static KBAssessmentModels.OrgHealthData getOrgHealthData() {
        try {
            KBAssessmentModels.OrgHealthData data = new KBAssessmentModels.OrgHealthData();

            // Config status
            KB_Scan_Config__c scanConfig = KB_Scan_Config__c.getOrgDefaults();
            KB_Score_Weight__c scoreWeights = KB_Score_Weight__c.getOrgDefaults();
            data.hasScanConfig = scanConfig != null && scanConfig.Id != null;
            data.hasScoreWeights = scoreWeights != null && scoreWeights.Id != null;

            // Org-wide article count
            data.totalPublishedArticles = KBAssessmentService.getPublishedArticleCount();

            // Pending actions backlog
            data.pendingDuplicates = [
                SELECT COUNT() FROM Duplicate_Candidate__c WHERE Status__c = 'Active'
            ];
            data.pendingEnrichments = [
                SELECT COUNT() FROM Enrichment_Candidate__c WHERE Status__c = 'Pending'
            ];

            // All completed readiness runs (last 20) for trend + comparability
            List<KB_Assessment_Run__c> runs = [
                SELECT Id, Name, Status__c, Overall_Score__c, Total_Articles__c,
                       Completed_At__c, Used_LLM__c, Requested_Scope__c,
                       Selected_Dimensions_JSON__c, Effective_Weights_JSON__c,
                       Filter_DSL_JSON__c, KB_Maturity_Tier__c, Deployment_Tier__c,
                       Completeness_Score__c, Structure_Score__c, Clarity_Score__c,
                       Freshness_Score__c, Duplication_Score__c, Conflict_Score__c
                FROM KB_Assessment_Run__c
                WHERE Status__c = 'Completed'
                AND Assessment_Types__c INCLUDES ('Readiness')
                WITH USER_MODE
                ORDER BY Completed_At__c DESC
                LIMIT 20
            ];

            if (runs.isEmpty()) {
                return data;
            }

            data.hasCompletedRun = true;
            data.lastScanDate = runs[0].Completed_At__c;

            // Distinct assessed article count (approximate via sum of run article counts deduplicated)
            Set<Integer> articleCounts = new Set<Integer>();
            Integer maxArticlesEver = 0;
            for (KB_Assessment_Run__c r : runs) {
                Integer cnt = r.Total_Articles__c != null ? r.Total_Articles__c.intValue() : 0;
                if (cnt > maxArticlesEver) maxArticlesEver = cnt;
            }
            data.totalAssessedArticles = maxArticlesEver;
            data.coveragePct = data.totalPublishedArticles > 0
                ? ((Decimal)maxArticlesEver / data.totalPublishedArticles * 100).setScale(1)
                : 0;

            // Build run history with comparability
            for (Integer i = 0; i < runs.size(); i++) {
                KB_Assessment_Run__c r = runs[i];
                KBAssessmentModels.RunSummary summary = new KBAssessmentModels.RunSummary();
                summary.runId = r.Id;
                summary.runName = r.Name;
                summary.overallScore = r.Overall_Score__c;
                summary.totalArticles = r.Total_Articles__c != null ? r.Total_Articles__c.intValue() : 0;
                summary.completedAt = r.Completed_At__c;
                summary.usedLLM = r.Used_LLM__c;
                summary.requestedScope = r.Requested_Scope__c;
                summary.selectedDimensionsJSON = r.Selected_Dimensions_JSON__c;
                summary.effectiveWeightsJSON = r.Effective_Weights_JSON__c;
                summary.filterDslJSON = r.Filter_DSL_JSON__c;
                summary.maturityTier = r.KB_Maturity_Tier__c;
                summary.deploymentTier = r.Deployment_Tier__c;

                // Comparability check against next-older run
                if (i < runs.size() - 1) {
                    KB_Assessment_Run__c prev = runs[i + 1];
                    String reason = getIncompatibilityReason(r, prev);
                    summary.comparableToPrevious = String.isBlank(reason);
                    summary.incompatibilityReason = reason;
                } else {
                    summary.comparableToPrevious = true;
                    summary.incompatibilityReason = null;
                }
                data.runHistory.add(summary);
            }

            // Dimension trends across comparable runs
            data.dimensionTrends = buildDimensionTrends(runs);


            return data;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching org health data: ' + e.getMessage());
        }
    }

    private static String getIncompatibilityReason(KB_Assessment_Run__c current, KB_Assessment_Run__c previous) {
        if (current.Used_LLM__c != previous.Used_LLM__c) {
            return 'Different scoring method (LLM vs deterministic)';
        }
        String curDims = current.Selected_Dimensions_JSON__c;
        String prevDims = previous.Selected_Dimensions_JSON__c;
        if (curDims != prevDims) {
            return 'Different dimensions scored';
        }
        String curScope = current.Requested_Scope__c;
        String prevScope = previous.Requested_Scope__c;
        if (curScope != prevScope) {
            return 'Different scope (' + curScope + ' vs ' + prevScope + ')';
        }
        // Filter comparison applies to every scope that carries a filter DSL.
        // Persisted scope values: 'Selected' (explicit ids, no filter),
        // 'MatchingFilter' (batch runner "select all matching"), 'Filtered'
        // and 'All' (scheduled run plans). Any non-'Selected' scope may have
        // a filter JSON whose drift breaks comparability.
        if (curScope != 'Selected') {
            String curFilter = current.Filter_DSL_JSON__c;
            String prevFilter = previous.Filter_DSL_JSON__c;
            if (curFilter != prevFilter) {
                return 'Different article filters';
            }
        }
        if (current.Effective_Weights_JSON__c != previous.Effective_Weights_JSON__c) {
            return 'Scoring weights changed';
        }
        return null;
    }

    private static List<KBAssessmentModels.DimensionTrend> buildDimensionTrends(List<KB_Assessment_Run__c> runs) {
        Map<String, List<Decimal>> scoresByDim = new Map<String, List<Decimal>>{
            'Completeness' => new List<Decimal>(),
            'Structure'    => new List<Decimal>(),
            'Clarity'      => new List<Decimal>(),
            'Freshness'    => new List<Decimal>(),
            'Duplication'  => new List<Decimal>(),
            'Conflict'     => new List<Decimal>()
        };
        for (KB_Assessment_Run__c r : runs) {
            if (r.Completeness_Score__c != null) scoresByDim.get('Completeness').add(r.Completeness_Score__c);
            if (r.Structure_Score__c != null)    scoresByDim.get('Structure').add(r.Structure_Score__c);
            if (r.Clarity_Score__c != null)      scoresByDim.get('Clarity').add(r.Clarity_Score__c);
            if (r.Freshness_Score__c != null)    scoresByDim.get('Freshness').add(r.Freshness_Score__c);
            if (r.Duplication_Score__c != null)  scoresByDim.get('Duplication').add(r.Duplication_Score__c);
            if (r.Conflict_Score__c != null)     scoresByDim.get('Conflict').add(r.Conflict_Score__c);
        }
        List<KBAssessmentModels.DimensionTrend> trends = new List<KBAssessmentModels.DimensionTrend>();
        for (String dim : scoresByDim.keySet()) {
            List<Decimal> scores = scoresByDim.get(dim);
            if (scores.isEmpty()) continue;
            KBAssessmentModels.DimensionTrend trend = new KBAssessmentModels.DimensionTrend();
            trend.dimension = dim;
            trend.latestScore = scores[0];
            Decimal total = 0;
            Integer runsBelow = 0;
            for (Decimal s : scores) {
                total += s;
                if (s < 50) runsBelow++;
            }
            trend.averageScore = (total / scores.size()).setScale(1);
            trend.runsBelow50 = runsBelow;
            trend.isPersistentWeakSpot = scores.size() >= 2 && runsBelow >= (scores.size() / 2);
            trends.add(trend);
        }
        return trends;
    }

    @AuraEnabled(cacheable=true)
    public static KBAssessmentModels.DashboardData getDashboardData() {
        try {
            KBAssessmentModels.DashboardData data = new KBAssessmentModels.DashboardData();

            // Config status
            KB_Scan_Config__c scanConfig = KB_Scan_Config__c.getOrgDefaults();
            KB_Score_Weight__c scoreWeights = KB_Score_Weight__c.getOrgDefaults();
            data.hasScanConfig = scanConfig != null && scanConfig.Id != null;
            data.hasScoreWeights = scoreWeights != null && scoreWeights.Id != null;

            // Total published articles
            data.totalPublishedArticles = KBAssessmentService.getPublishedArticleCount();

            // Most recent completed run
            List<KB_Assessment_Run__c> completedRuns = [
                SELECT Id, Name, Status__c, Status_Message__c, Total_Articles__c, Overall_Score__c,
                       Ready_Count__c, Needs_Work_Count__c, Not_Ready_Count__c,
                       Completed_At__c, CreatedDate,
                       Completeness_Score__c, Structure_Score__c, Clarity_Score__c,
                       Freshness_Score__c, Duplication_Score__c, Conflict_Score__c,
                       KB_Maturity_Tier__c, Deployment_Tier__c, Used_LLM__c,
                       Assessment_Types__c, Requested_Scope__c, Pipeline_Run__c,
                       Selected_Dimensions_JSON__c
                FROM KB_Assessment_Run__c
                WHERE Status__c = 'Completed'
                AND Assessment_Types__c INCLUDES ('Readiness')
                WITH USER_MODE
                ORDER BY Completed_At__c DESC
                LIMIT 2
            ];

            if (completedRuns.isEmpty()) {
                return data;
            }

            data.hasCompletedRun = true;
            KB_Assessment_Run__c latestRun = completedRuns[0];
            data.latestRun = mapRunToRunResult(latestRun);
            data.lastScanDate = latestRun.Completed_At__c;

 // Quick Wins were dropped: the query gated on
            // Effort__c = 'Quick Win', which is never written now that the
            // severity model is Impact-only — it always returned empty and has
            // no production LWC caller. data.quickWins stays initialised to an
            // empty list on the DTO so existing consumers don't NPE.

            // Previous run for trend comparison
            if (completedRuns.size() > 1) {
                KB_Assessment_Run__c previousRun = completedRuns[1];
                data.previousOverallScore = previousRun.Overall_Score__c;
                data.previousTotalArticles = previousRun.Total_Articles__c != null
                    ? previousRun.Total_Articles__c.intValue() : 0;
            }

            return data;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching dashboard data: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getArticleTypeOptions() {
        try {
            return KBAssessmentService.getAllKnowledgeObjectApiNames();
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching article types: ' + e.getMessage());
        }
    }

    /**
     * Descriptors (apiName + label) for the admin-selected content fields.
     * Drives the dynamic columns appended to the article-selector table.
     * Cached because the underlying `Content_Field_Mapping_JSON__c` only
     * changes when the Setup Wizard is re-run.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getSelectedContentFieldColumns() {
        try {
            return KBAssessmentService.getSelectedContentFieldDescriptors();
        } catch (Exception e) {
            throw new AuraHandledException('Error loading content field columns: ' + e.getMessage());
        }
    }

    /**
     * Filterable Knowledge fields (apiName / label / type / picklistValues).
 * Drives the dynamic field combobox in the advanced-filter UI.
     * cacheable so the LWC's @wire only round-trips once per session — the
     * describe map is invariant for the lifetime of the running user's
     * Knowledge schema.
     */
    @AuraEnabled(cacheable=true)
    public static List<KBKnowledgeFieldDescribeService.FieldDescriptor> getFilterableFields() {
        try {
            return KBKnowledgeFieldDescribeService.getFilterableFields();
        } catch (Exception e) {
            throw new AuraHandledException('Error loading filterable fields: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static KBAssessmentModels.ArticleFilterResult getFilteredArticles(String filterJSON) {
        try {
            KBAssessmentService service = new KBAssessmentService();
            Map<String, Object> filters = parseFilterJson(filterJSON);
            Integer pageSize = filters.containsKey('pageSize')
                ? Integer.valueOf(filters.get('pageSize')) : 25;
            Integer offset = filters.containsKey('offset')
                ? Integer.valueOf(filters.get('offset')) : 0;

            return service.searchArticlesFiltered(
                (String) filters.get('publishStatus'),
                (String) filters.get('titleSearch'),
                (String) filters.get('articleNumber'),
                (String) filters.get('articleType'),
                pageSize,
                offset,
                extractFilterClauses(filters),
                (String) filters.get('filterLogic'),
                (String) filters.get('filterFormula')
            );
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching filtered articles: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static List<String> getMatchingArticleIds(String filterJSON) {
        try {
            KBAssessmentService service = new KBAssessmentService();
            Map<String, Object> filters = parseFilterJson(filterJSON);
            return service.resolveMatchingArticleIds(
                (String) filters.get('publishStatus'),
                (String) filters.get('titleSearch'),
                (String) filters.get('articleNumber'),
                (String) filters.get('articleType'),
                extractFilterClauses(filters),
                (String) filters.get('filterLogic'),
                (String) filters.get('filterFormula')
            );
        } catch (KBAssessmentService.MatchingFilterLimitException e) {
            throw new AuraHandledException(e.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Error resolving matching articles: ' + e.getMessage());
        }
    }

    private static Map<String, Object> parseFilterJson(String filterJSON) {
        return String.isNotBlank(filterJSON)
            ? (Map<String, Object>) JSON.deserializeUntyped(filterJSON)
            : new Map<String, Object>();
    }

    private static List<KBAssessmentModels.FilterClause> extractFilterClauses(Map<String, Object> filters) {
        List<KBAssessmentModels.FilterClause> filterClauses = new List<KBAssessmentModels.FilterClause>();
        if (!filters.containsKey('filterClauses') || !(filters.get('filterClauses') instanceof List<Object>)) {
            return filterClauses;
        }
        for (Object rawClause : (List<Object>) filters.get('filterClauses')) {
            if (!(rawClause instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> m = (Map<String, Object>) rawClause;
            KBAssessmentModels.FilterClause fc = new KBAssessmentModels.FilterClause();
            // id and fieldType are optional — the client supplies them for
            // formula references and per-type input rendering, but legacy
            // payloads predate these fields and must keep parsing.
            fc.id = m.containsKey('id') && m.get('id') != null ? String.valueOf(m.get('id')) : null;
            fc.field = m.containsKey('field') ? String.valueOf(m.get('field')) : null;
            fc.fieldType = m.containsKey('fieldType') && m.get('fieldType') != null
                ? String.valueOf(m.get('fieldType'))
                : null;
            fc.operator = m.containsKey('operator') ? String.valueOf(m.get('operator')) : null;
            fc.value = m.containsKey('value') && m.get('value') != null
                ? String.valueOf(m.get('value'))
                : null;
            if (m.containsKey('values') && m.get('values') instanceof List<Object>) {
                fc.values = new List<String>();
                for (Object v : (List<Object>) m.get('values')) {
                    if (v != null) fc.values.add(String.valueOf(v));
                }
            }
            filterClauses.add(fc);
        }
        return filterClauses;
    }

    private static KBAssessmentModels.AssessmentRunResult mapRunToRunResult(KB_Assessment_Run__c run) {
        KBAssessmentModels.AssessmentRunResult result = new KBAssessmentModels.AssessmentRunResult();
        result.runId = run.Id;
        result.status = run.Status__c;
 // golden-thread name. Name (auto-number) is always selected;
        // Run_Name__c / Description__c are pulled by callers that show them
        // (defensive read so dashboard/health paths that omit them don't throw).
        result.runName = run.Name;
        Map<String, Object> populated = run.getPopulatedFieldsAsMap();
        if (populated.containsKey('Run_Name__c')) {
            result.userRunName = run.Run_Name__c;
        }
        if (populated.containsKey('Description__c')) {
            result.description = run.Description__c;
        }
        // Defensive read: not every caller's SELECT pulls Status_Message__c
 // (it was added in 's review follow-up; older callsites that
        // don't show the message in the UI omit it). getPopulatedFieldsAsMap
        // returns only fields that were actually selected, so this stays null
        // rather than throwing SObjectException on the dashboard / health paths.
        if (run.getPopulatedFieldsAsMap().containsKey('Status_Message__c')) {
            result.statusMessage = run.Status_Message__c;
        }
 // run timestamps for the results "Run details" panel. Defensive
        // reads: Completed_At__c / Scan_Start_Time__c are null (hence absent from
        // getPopulatedFieldsAsMap) on in-progress runs; CreatedDate is always
        // present. startedAt prefers the scan-start (re-stamped on a destructive
        // rerun) and falls back to createdDate.
        if (populated.containsKey('CreatedDate')) {
            result.createdDate = run.CreatedDate;
        }
        if (populated.containsKey('Completed_At__c')) {
            result.completedAt = run.Completed_At__c;
        }
        if (populated.containsKey('Scan_Start_Time__c')) {
            result.startedAt = run.Scan_Start_Time__c;
        } else if (populated.containsKey('CreatedDate')) {
            result.startedAt = run.CreatedDate;
        }
        result.totalArticles = run.Total_Articles__c != null ? run.Total_Articles__c.intValue() : 0;
        result.overallScore = run.Overall_Score__c != null ? run.Overall_Score__c : 0;
        result.readyCount = run.Ready_Count__c != null ? run.Ready_Count__c.intValue() : 0;
        result.needsWorkCount = run.Needs_Work_Count__c != null ? run.Needs_Work_Count__c.intValue() : 0;
        result.notReadyCount = run.Not_Ready_Count__c != null ? run.Not_Ready_Count__c.intValue() : 0;
        // Run-level per-dim aggregate scores live on the same-named columns on
        // KB_Assessment_Run__c (populated at finalization). Map them into the
        // dimensionScores map keyed by DeveloperName so consumers don't depend
        // on the physical column layout.
        if (run.Completeness_Score__c != null) result.dimensionScores.put('Completeness', run.Completeness_Score__c);
        if (run.Structure_Score__c    != null) result.dimensionScores.put('Structure',    run.Structure_Score__c);
        if (run.Clarity_Score__c      != null) result.dimensionScores.put('Clarity',      run.Clarity_Score__c);
        if (run.Freshness_Score__c    != null) result.dimensionScores.put('Freshness',    run.Freshness_Score__c);
        if (run.Duplication_Score__c  != null) result.dimensionScores.put('Duplication',  run.Duplication_Score__c);
        if (run.Conflict_Score__c     != null) result.dimensionScores.put('Conflict',     run.Conflict_Score__c);
        result.maturityTier = run.KB_Maturity_Tier__c;
        result.deploymentTier = run.Deployment_Tier__c;
        result.usedLLM = run.Used_LLM__c;
 // gate the LWC Cancel button on the same FLS check the
        // service-layer DML enforces (`update as user` on Status__c). Viewer
        // users return false here and the LWC hides the button entirely.
        result.canCancel = Schema.SObjectType.KB_Assessment_Run__c
            .fields.Status__c.isUpdateable();
        result.assessmentTypesCsv = run.Assessment_Types__c;
        result.requestedScope = run.Requested_Scope__c;
        result.pipelineRunId = run.Pipeline_Run__c != null ? String.valueOf(run.Pipeline_Run__c) : null;
        Integer selectedCount = 0;
        if (String.isNotBlank(run.Selected_Dimensions_JSON__c)) {
            try {
                selectedCount = ((List<Object>) JSON.deserializeUntyped(run.Selected_Dimensions_JSON__c)).size();
            } catch (Exception e) {
                selectedCount = 0;
            }
        }
        result.selectedDimensionCount = selectedCount;
        return result;
    }

    private static KBAssessmentModels.ArticleAssessmentResult mapAssessmentToResult(
        KB_Article_Assessment__c assessment
    ) {
        // Overload for callers that don't compute reachability — treats the
        // article as reachable (null set → no downgrade). loadAssessmentResults
 // passes a real set so greys unreachable rows.
        return mapAssessmentToResult(assessment, null);
    }

    private static KBAssessmentModels.ArticleAssessmentResult mapAssessmentToResult(
        KB_Article_Assessment__c assessment,
        Set<Id> reachableVersionIds
    ) {
        KBAssessmentModels.ArticleAssessmentResult result = new KBAssessmentModels.ArticleAssessmentResult();

        Map<String, Object> populated = assessment.getPopulatedFieldsAsMap();
        result.articleId = assessment.Knowledge__c;
        result.articleTitle = assessment.Article_Title__c;
        result.articleNumber = assessment.Article_Number__c;
        result.knowledgeArticleId = assessment.Knowledge_Article_Id__c;
        result.overallScore = assessment.Overall_Score__c;
        result.readinessStatus = assessment.Readiness_Status__c;
 // reachable only when we were given a reachable-set AND this
        // article's version id is in it. A null set means the caller didn't
        // compute reachability, so leave the DTO default (true) untouched.
        if (reachableVersionIds != null) {
            result.isReachable =
                assessment.Knowledge__c != null
                && reachableVersionIds.contains(assessment.Knowledge__c);
        }
        // Defensive read: not every caller's SELECT pulls Pipeline_Skip_Reason__c.
        // Skipping when not selected keeps the mapper robust without forcing a
        // SELECT change in every caller.
        if (populated.containsKey('Pipeline_Skip_Reason__c')) {
            result.pipelineSkipReason = assessment.Pipeline_Skip_Reason__c;
        }
        result.hasConflicts = assessment.Has_Conflicts__c;
        result.conflictDetails = assessment.Conflict_Details__c;

        if (assessment.Dimension_Results__r != null) {
            for (KB_Dimension_Result__c dr : assessment.Dimension_Results__r) {
                KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore(
                    dr.Score__c, dr.Reasoning__c
                );
                s.isUnassessable = dr.Is_Unassessable__c == true;
                s.scorerMode = dr.Scorer_Mode__c;
                result.setScore(dr.Dimension__c, s);
            }
        }

        result.recommendations = new List<KBAssessmentModels.RecommendationResult>();
        if (assessment.Dimension_Analyses__r != null) {
            for (KB_Dimension_Analysis__c rec : assessment.Dimension_Analyses__r) {
                result.recommendations.add(
                    new KBAssessmentModels.RecommendationResult(rec, assessment.Article_Title__c)
                );
            }
        }

        return result;
    }

    // ==================== Article Record LWC methods ====================

    /**
     * Single-article assessment, existing-first.
     * For use by the Knowledge article record page LWC.
     *
     * @param articleId Knowledge article version ID (from the record page)
     * @param dimensionsCsv Optional comma-separated dimension names to assess.
     *                      Null/blank = all dimensions.
     * @return ArticleAssessmentResult from existing if fresh, or freshly scored
     */
    @AuraEnabled
    public static KBAssessmentModels.ArticleAssessmentResult assessCurrentArticle(
        String articleId, String dimensionsCsv
    ) {
        try {
            if (String.isBlank(articleId)) {
                throw new AuraHandledException('Article ID is required.');
            }
            KBAssessmentFacade.AssessmentOptions options = new KBAssessmentFacade.AssessmentOptions();
            if (String.isNotBlank(dimensionsCsv)) {
                options.dimensions = parseDimensions(dimensionsCsv);
            }
            return KBAssessmentFacade.getOrAssess(articleId, options);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error assessing article: ' + e.getMessage());
        }
    }

    /**
 * On-demand scoring PREVIEW for a single article/version.
     *
     * Scores the four self-contained dimensions (Completeness, Structure,
     * Clarity, Freshness) against the article's CURRENT content and returns the
     * result inline — WITHOUT creating a KB_Assessment_Run__c or persisting any
     * row. Duplication/Conflict are excluded by design: they read pipeline data
     * (Duplicate_Candidate__c), which only exists after a real run, so they have
     * no meaning for a single unpublished/edited article.
     *
     * Use case: open any Knowledge__kav version (including an AI-Fix-generated
     * Draft) and see "how would this score if I published and assessed it?"
     * before committing. Always recomputes fresh (no existing-first cache) so the
     * preview reflects unsaved-since-last-run edits.
     *
     * Runs the LLM scorers live (≈4 callouts) — the LWC gates this behind an
     * explicit "Preview results" button, not page load, so a record view never
     * silently consumes Einstein credits.
     *
     * @param articleId Knowledge article version ID (from the record page)
     * @return ArticleAssessmentResult scored in-memory; nothing persisted
     */
    @AuraEnabled
    public static KBAssessmentModels.ArticleAssessmentResult previewArticleScore(String articleId) {
        try {
            if (String.isBlank(articleId)) {
                throw new AuraHandledException('Article ID is required.');
            }
            // Let the dimension registry own the set: skipPipelineDimensions
            // makes resolveSelectedDimensions return exactly the active
            // non-pipeline dimensions (Completeness/Structure/Clarity/Freshness
            // today). Don't hardcode the list here — a future 7th self-contained
 // dimension is then picked up automatically (review note,).
            KBAssessmentFacade.AssessmentOptions options = new KBAssessmentFacade.AssessmentOptions();
            options.skipPipelineDimensions = true; // no Dup/Conflict — pipeline-only
            options.persistResults = false;        // pure preview — no run, no DML

            KBAssessmentModels.AssessmentRunResult run = KBAssessmentFacade.assessArticlesSync(
                new List<String>{ articleId }, options
            );
            if (run == null || run.articleResults == null || run.articleResults.isEmpty()) {
                throw new AuraHandledException('Could not score this article.');
            }
            return run.articleResults[0];
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error previewing score: ' + e.getMessage());
        }
    }

    /**
     * Get the existing assessment for the current article.
     * For the article record LWC to show existing results on page load.
     *
     * @param articleId Knowledge article version ID
     * @return ExistingAssessmentResult with the existing assessment and staleness metadata
     */
    @AuraEnabled(cacheable=true)
    public static KBAssessmentFacade.ExistingAssessmentResult getExistingArticleAssessment(String articleId) {
        try {
            if (String.isBlank(articleId)) {
                throw new AuraHandledException('Article ID is required.');
            }
            return KBAssessmentFacade.getExistingAssessmentDetailed(articleId);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error fetching existing assessment: ' + e.getMessage());
        }
    }

    /**
     * Trigger the dedup pipeline for a single article.
     * Used when the article record LWC wants fresh Duplication/Conflict scoring.
     *
     * @param articleId Knowledge article version ID
     * @return Run ID for platform event subscription
     */
    @AuraEnabled
    public static String triggerPipelineForArticle(String articleId) {
        try {
            if (String.isBlank(articleId)) {
                throw new AuraHandledException('Article ID is required.');
            }
            KBAssessmentFacade.AssessmentOptions options = new KBAssessmentFacade.AssessmentOptions();
            options.dimensions = new List<String>{ 'Duplication', 'Conflict' };
            KBAssessmentModels.AssessmentRunResult result = KBAssessmentFacade.assessArticlesAsync(
                new List<String>{ articleId }, options
            );
            return result != null ? result.runId : null;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Error triggering pipeline: ' + e.getMessage());
        }
    }

    private static List<String> parseDimensions(String csv) {
        List<String> result = new List<String>();
        if (String.isBlank(csv)) return result;
        for (String dim : csv.split(',')) {
            String trimmed = dim.trim();
            if (String.isNotBlank(trimmed)) {
                result.add(trimmed.toLowerCase());
            }
        }
        return result;
    }

    public class AssessmentRunSummary {
        @AuraEnabled public String runId { get; set; }
 // auto-number Name (RUN-####). The All Assessments list falls
        // back to this when the user-supplied runName is blank.
        @AuraEnabled public String runName { get; set; }
 // user-supplied name + description from the "Assessment details"
        // step. userRunName may be null/blank for historical or unnamed runs;
        // the LWC resolves display = userRunName || runName (auto-number).
        @AuraEnabled public String userRunName { get; set; }
        @AuraEnabled public String description { get; set; }
 // who ran the assessment (the run owner), so the All Assessments
        // list can show a "by <name>" byline that matches the record-page run
        // picker. Optional in the SELECT — read defensively.
        @AuraEnabled public String ranBy { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Integer totalArticles { get; set; }
        @AuraEnabled public Decimal overallScore { get; set; }
        @AuraEnabled public Integer readyCount { get; set; }
        @AuraEnabled public Integer needsWorkCount { get; set; }
        @AuraEnabled public Integer notReadyCount { get; set; }
        @AuraEnabled public Datetime completedAt { get; set; }
        @AuraEnabled public Datetime createdDate { get; set; }
 // when scoring actually started for this run. Re-stamped fresh on
        // a destructive rerun (KBAssessmentService.resetRunForRerun), so the
        // All Assessments list's live elapsed-time timer counts from the rerun
 // start, not the original CreatedDate. May be null for pre- runs or
        // runs created before the scan-start stamp — the LWC falls back to
        // createdDate in that case.
        @AuraEnabled public Datetime scanStartTime { get; set; }
        // Total wall-clock for the run (scoring + pipeline), stamped on
        // completion by KBAssessmentPipelineCallback. Null while in flight or
        // for failed/cancelled runs. The LWC renders it as a human-readable
        // "took 2h 13m" on completed rows.
        @AuraEnabled public Long totalDurationMs { get; set; }

        public AssessmentRunSummary(KB_Assessment_Run__c run) {
            this.runId = run.Id;
            this.runName = run.Name;
 // Run_Name__c / Description__c are optional in the SELECT
            // defensive read so callsites that don't query them (e.g. the
            // summary-construction unit test) don't throw SObjectException.
            Map<String, Object> populated = run.getPopulatedFieldsAsMap();
            if (populated.containsKey('Run_Name__c')) {
                this.userRunName = run.Run_Name__c;
            }
            if (populated.containsKey('Description__c')) {
                this.description = run.Description__c;
            }
 // Owner.Name is optional in the SELECT; guard via the
            // populated-fields map (accessing OwnerId when unqueried throws
            // SObjectException) so callsites that don't query it don't break.
            if (populated.containsKey('OwnerId') && run.Owner != null) {
                this.ranBy = run.Owner.Name;
            }
 // Scan_Start_Time__c is optional in the SELECT — defensive
            // read so callsites that don't query it don't throw SObjectException.
            if (populated.containsKey('Scan_Start_Time__c')) {
                this.scanStartTime = run.Scan_Start_Time__c;
            }
            if (populated.containsKey('Total_Duration_Ms__c')) {
                this.totalDurationMs = run.Total_Duration_Ms__c != null
                    ? run.Total_Duration_Ms__c.longValue()
                    : null;
            }
            this.status = run.Status__c;
            this.totalArticles = run.Total_Articles__c != null ? run.Total_Articles__c.intValue() : 0;
            this.overallScore = run.Overall_Score__c;
            this.readyCount = run.Ready_Count__c != null ? run.Ready_Count__c.intValue() : 0;
            this.needsWorkCount = run.Needs_Work_Count__c != null ? run.Needs_Work_Count__c.intValue() : 0;
            this.notReadyCount = run.Not_Ready_Count__c != null ? run.Not_Ready_Count__c.intValue() : 0;
            this.completedAt = run.Completed_At__c;
            this.createdDate = run.CreatedDate;
        }
    }

    public class PipelineRunSummary {
        @AuraEnabled public String runId { get; set; }
        @AuraEnabled public String runName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String executionModes { get; set; }
        @AuraEnabled public String scopeType { get; set; }
        @AuraEnabled public Integer totalInputArticles { get; set; }
        @AuraEnabled public Integer processedCount { get; set; }
        @AuraEnabled public Integer errorCount { get; set; }
        @AuraEnabled public Integer pairEvaluationsCreated { get; set; }
        @AuraEnabled public Datetime startedAt { get; set; }
        @AuraEnabled public Datetime completedAt { get; set; }
        @AuraEnabled public String assessmentRunId { get; set; }

        public PipelineRunSummary(KB_Pipeline_Run__c run) {
            this.runId = run.Id;
            this.runName = run.Name;
            this.status = run.Status__c;
            this.executionModes = run.Execution_Modes__c;
            this.scopeType = run.Scope_Type__c;
            this.totalInputArticles = run.Total_Input_Articles__c != null ? run.Total_Input_Articles__c.intValue() : 0;
            this.processedCount = run.Processed_Count__c != null ? run.Processed_Count__c.intValue() : 0;
            this.errorCount = run.Error_Count__c != null ? run.Error_Count__c.intValue() : 0;
            this.pairEvaluationsCreated = run.Pair_Evaluations_Created__c != null ? run.Pair_Evaluations_Created__c.intValue() : 0;
            this.startedAt = run.Started_At__c;
            this.completedAt = run.Completed_At__c;
            this.assessmentRunId = run.Assessment_Run__c != null ? String.valueOf(run.Assessment_Run__c) : null;
        }
    }
}