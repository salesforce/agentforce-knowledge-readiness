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
 * Data model for the scoring pipeline.
 *
 * Dimension identity is NOT defined here. The registry is
 * KB_Scoring_Dimension__mdt, read via DimensionRegistry. Adding a new
 * dimension is a deploy of one CMDT record + one scorer class — no change
 * to this file.
 */
public with sharing class KBAssessmentModels {

    /**
 * /— Duplicate_Candidate__c statuses that represent a
     * user-discarded pair and must be EXCLUDED from every surface that counts
     * or lists "live" candidates (Action Center queue, Dimension Explorer
     * shelves/lists, the Duplication/Conflict scorers, and the pipeline bridge).
     * 'Not a Duplicate' is the consolidated soft-discard status; 'Rejected' /
     * 'Suppressed' are its retired predecessors, retained for legacy rows.
     * Single source of truth so these surfaces can't drift apart again — a
 * drift is the exact cross-surface inconsistency set out to remove.
     */
    public static final Set<String> DISCARDED_STATUSES = new Set<String>{
        'Not a Duplicate', 'Rejected', 'Suppressed'
    };

    public class FilterClause {
 // NEW: stable client-supplied id so the formula parser can
        // reference clauses positionally and the LWC can edit/remove rows
        // without re-indexing. Optional — generated client-side, server
        // doesn't validate the format.
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String field { get; set; }
 // NEW: DisplayType.name for round-tripping. Lets the LWC
        // re-render the right per-type input on edit without re-fetching the
        // describe map. Server-side it's a hint — the compiler still
        // verifies the field type from the canonical describe map.
        @AuraEnabled public String fieldType { get; set; }
        @AuraEnabled public String operator { get; set; }
        @AuraEnabled public String value { get; set; }
 // NEW: list-valued payload for `in`, `includes`, `excludes`
        // and `lastNDays` (single-element list of digits is fine, but
        // semantically distinct from a scalar `value`). Null for scalar ops.
        @AuraEnabled public List<String> values { get; set; }
    }

    public class AssessmentRunOptions {
        @AuraEnabled public List<String> assessmentTypes { get; set; }
        @AuraEnabled public List<String> executionModes { get; set; }
        @AuraEnabled public List<String> selectedDimensions { get; set; }
        @AuraEnabled public String requestedScope { get; set; }
        @AuraEnabled public List<FilterClause> filterClauses { get; set; }
        @AuraEnabled public String filterLogic { get; set; }
 // NEW: Salesforce-style boolean formula referencing clauses
        // 1..N positionally (e.g. `(1 OR 2) AND NOT 3`). When blank the
        // legacy filterLogic AND/OR path is used — full backwards compat.
        @AuraEnabled public String filterFormula { get; set; }
 // NEW: user-supplied name + description captured on the
        // "Assessment details" step of the new-assessment flow. runName is
        // mandatory in the UI; persisted to KB_Assessment_Run__c.Run_Name__c
        // and surfaced in the All Assessments list (auto-number Name fallback
        // when blank). description is optional.
        @AuraEnabled public String runName { get; set; }
        @AuraEnabled public String description { get; set; }

        public AssessmentRunOptions() {
            this.assessmentTypes = new List<String>{ 'Readiness' };
            this.executionModes = new List<String>{ 'DEDUPLICATION' };
            this.selectedDimensions = new List<String>(DimensionRegistry.getActiveDeveloperNames());
            this.requestedScope = 'Selected';
            this.filterClauses = new List<FilterClause>();
            this.filterLogic = 'AND';
            this.filterFormula = null;
            this.runName = null;
            this.description = null;
        }
    }

    public class ArticleWrapper {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public String articleNumber { get; set; }
        // Parent KnowledgeArticleId (kA0... prefix). Versions of the same
        // article share this id, so it's the right key for cross-version
        // operations (e.g. dedup pair filtering, denormalised audit fields).
        @AuraEnabled public String knowledgeArticleId { get; set; }
        @AuraEnabled public String summary { get; set; }
        @AuraEnabled public String content { get; set; }
        @AuraEnabled public String urlName { get; set; }
        @AuraEnabled public Datetime lastModifiedDate { get; set; }
        @AuraEnabled public String publishStatus { get; set; }
        @AuraEnabled public Integer dataCategories { get; set; }
        // Raw values of admin-selected content fields, keyed by API name.
        // Used by the article-selector LWC to render dynamic table columns
        // without re-fetching describe metadata in JS. Optional — may be
        // null on wrappers built outside the picker SOQL pipeline.
        @AuraEnabled public Map<String, String> contentFieldValues { get; set; }

        public ArticleWrapper() {}

        public ArticleWrapper(SObject article) {
            this.id = (String)article.get('Id');
            this.title = (String)article.get('Title');
            this.articleNumber = (String)article.get('ArticleNumber');
            this.knowledgeArticleId = (String)article.get('KnowledgeArticleId');
            this.summary = (String)article.get('Summary');
            this.urlName = (String)article.get('UrlName');
            this.lastModifiedDate = (Datetime)article.get('LastModifiedDate');
            this.publishStatus = (String)article.get('PublishStatus');
        }
    }

    /**
     * Per-issue severity carrier. Mirrors the issues list 1:1 by index so
     * the existing List<String> shape stays usable by older callers (LWC,
     * legacy tests) while LLM-driven impact/effort/priority can flow through
     * the parallel issueAnalyses list. impact / effort / priority are null
     * for deterministic-emitted issues until KBDimensionAnalysisService
 * annotates them via Annotate_Issue_Severity.
     */
    public class IssueAnalysis {
        @AuraEnabled public String text { get; set; }
        @AuraEnabled public String impact { get; set; }
        @AuraEnabled public String effort { get; set; }
        @AuraEnabled public String priority { get; set; }

        public IssueAnalysis() {}

        public IssueAnalysis(String text) {
            this.text = text;
        }

        public IssueAnalysis(String text, String impact, String effort, String priority) {
            this.text     = text;
            this.impact   = impact;
            this.effort   = effort;
            this.priority = priority;
        }
    }

    public class DimensionScore {
        @AuraEnabled public Decimal score { get; set; }
        @AuraEnabled public String reasoning { get; set; }
        @AuraEnabled public List<String> issues { get; set; }
        @AuraEnabled public List<IssueAnalysis> issueAnalyses { get; set; }
        @AuraEnabled public List<String> strengths { get; set; }
        @AuraEnabled public Boolean isUnassessable { get; set; }
        @AuraEnabled public String scorerMode { get; set; }
        @AuraEnabled public Long executionMs { get; set; }

        public DimensionScore() {
            this.score = 0;
            this.reasoning = '';
            this.issues = new List<String>();
            this.issueAnalyses = new List<IssueAnalysis>();
            this.strengths = new List<String>();
            this.isUnassessable = false;
            this.scorerMode = null;
            this.executionMs = null;
        }

        public DimensionScore(Decimal score, String reasoning) {
            this();
            this.score = score != null ? score : 0;
            this.reasoning = String.isNotBlank(reasoning) ? reasoning : '';
            parseReasoningText(this.reasoning);
        }

        /**
         * Append an issue with optional severity. Keeps issues and
         * issueAnalyses in lockstep so consumers can pick whichever shape
         * they need without index-drift surprises.
         */
        public void addIssue(String text) {
            addIssue(text, null, null, null);
        }

        public void addIssue(String text, String impact, String effort, String priority) {
            if (String.isBlank(text)) return;
            this.issues.add(text);
            this.issueAnalyses.add(new IssueAnalysis(text, impact, effort, priority));
        }

        private void parseReasoningText(String reasoningText) {
            if (String.isBlank(reasoningText)) return;

            Pattern strengthsPattern = Pattern.compile('(?i)Strengths?:\\s*([^.]*(?:\\.[^I]*)*)(?=\\.\\s*Issues?:|$)');
            Matcher strengthsMatcher = strengthsPattern.matcher(reasoningText);
            if (strengthsMatcher.find() && String.isNotBlank(strengthsMatcher.group(1))) {
                for (String item : strengthsMatcher.group(1).split(';')) {
                    String trimmed = item.trim().replaceAll('\\.+$', '');
                    if (String.isNotBlank(trimmed)) {
                        this.strengths.add(trimmed);
                    }
                }
            }

            Pattern issuesPattern = Pattern.compile('(?i)Issues?:\\s*(.+?)$');
            Matcher issuesMatcher = issuesPattern.matcher(reasoningText);
            if (issuesMatcher.find() && String.isNotBlank(issuesMatcher.group(1))) {
                for (String item : issuesMatcher.group(1).split(';')) {
                    String trimmed = item.trim().replaceAll('\\.+$', '');
                    if (String.isNotBlank(trimmed)) {
                        this.issues.add(trimmed);
                    }
                }
            }
        }
    }

    /**
     * Per-article assessment result. Dimension scores live in scoresByDim,
     * keyed by dimension DeveloperName from KB_Scoring_Dimension__mdt.
     * Use getScore(dim) / setScore(dim, score) to access them.
     */
    public class ArticleAssessmentResult {
        @AuraEnabled public String articleId { get; set; }
        @AuraEnabled public String articleTitle { get; set; }
        // Denormalized identifiers from Knowledge__kav so consumers (and the
        // KB_Article_Assessment__c record builder) don't need to re-query the
        // article. ArticleNumber is the human-facing 000001234 reference;
        // KnowledgeArticleId is the parent kA0... id (versions share it).
        @AuraEnabled public String articleNumber { get; set; }
        @AuraEnabled public String knowledgeArticleId { get; set; }
        @AuraEnabled public Decimal overallScore { get; set; }
        @AuraEnabled public String readinessStatus { get; set; }
        @AuraEnabled public String pipelineSkipReason { get; set; }
 // whether the assessed article is still reachable by the running
        // user. False when the article was deleted (Knowledge__c nulled by the
 // SetNull constraint,) OR the user lost access (moved to a data
        // category / FLS they don't have). The row still renders from the
        // snapshot fields (title/score), but the LWC greys it out and drops the
        // open-article + View Actions links, which would otherwise dead-end.
        // Defaults true so any path that doesn't set it keeps today's behaviour.
        @AuraEnabled public Boolean isReachable { get; set; }

        /**
         * Scores keyed by dimension DeveloperName (e.g. 'Completeness', 'Structure').
         */
        @AuraEnabled public Map<String, DimensionScore> scoresByDim { get; set; }

        @AuraEnabled public Boolean hasConflicts { get; set; }
        @AuraEnabled public String conflictDetails { get; set; }
        @AuraEnabled public List<String> conflictingArticleIds { get; set; }
        @AuraEnabled public List<RecommendationResult> recommendations { get; set; }

        public ArticleAssessmentResult() {
            this.scoresByDim = new Map<String, DimensionScore>();
            this.hasConflicts = false;
            this.isReachable = true; // default reachable; loader flips it off
            this.conflictingArticleIds = new List<String>();
            this.recommendations = new List<RecommendationResult>();
        }

        public DimensionScore getScore(String dim) {
            if (this.scoresByDim == null) return null;
            return this.scoresByDim.get(dim);
        }

        public void setScore(String dim, DimensionScore s) {
            if (this.scoresByDim == null) this.scoresByDim = new Map<String, DimensionScore>();
            if (String.isBlank(dim) || s == null) return;
            this.scoresByDim.put(dim, s);
        }

        /**
         * Weighted overall score across the selected dimensions.
         * Unscored (null) and unassessable dims are skipped so they don't
         * bias the average downward. Weights renormalised over the set of
         * dims that produced a numeric score.
         */
        public void calculateOverallScore(
            Set<String> selectedDimensions,
            Map<String, Decimal> effectiveWeights
        ) {
            Set<String> selected = (selectedDimensions == null || selectedDimensions.isEmpty())
                ? DimensionRegistry.getActiveDeveloperNames()
                : selectedDimensions;
            Map<String, Decimal> weights = effectiveWeights == null
                ? DimensionRegistry.getActiveWeights()
                : effectiveWeights;

            Decimal weightSum = 0;
            Decimal weightedTotal = 0;
            for (String dim : selected) {
                DimensionScore s = this.getScore(dim);
                if (s == null || s.isUnassessable == true || s.score == null) continue;
                Decimal w = weights.containsKey(dim) ? weights.get(dim) : 0;
                if (w == null || w == 0) continue;
                weightedTotal += s.score * w;
                weightSum += w;
            }

            this.overallScore = (weightSum == 0)
                ? 0
                : (weightedTotal / weightSum).setScale(2);

            if (this.overallScore >= 80) {
                this.readinessStatus = 'Ready';
            } else if (this.overallScore >= 50) {
                this.readinessStatus = 'Needs Work';
            } else {
                this.readinessStatus = 'Not Ready';
            }
        }
    }

    public class RecommendationResult {
        @AuraEnabled public String dimension { get; set; }
        @AuraEnabled public String recommendation { get; set; }
        // Severity model reduced to Impact only (High/Medium/Low). Effort,
        // Priority and the numeric impact-score field were dropped: the fix is
        // done by AI (no human effort to estimate) and the numeric impact score
        // was an Apex-computed weight, not an LLM signal. Impact mirrors the
        // score deduction the issue carries.
        @AuraEnabled public String impact { get; set; }
        @AuraEnabled public String articleTitle { get; set; }
        // Lifecycle status of the recommendation (Open / Queued / Resolved /
        // Error / Dismissed / Rejected). Surfaced so the results score card can
        // tell whether an article still has actionable (Open/Error) issues and
 // gate its "View Actions" deep-link accordingly. Populated only
        // when the caller's SELECT pulls Status__c.
        @AuraEnabled public String status { get; set; }

        public RecommendationResult() {}

        public RecommendationResult(KB_Dimension_Analysis__c row, String articleTitle) {
            this.dimension = row.Dimension__c;
            this.recommendation = row.Recommendation__c;
            this.impact = row.Impact__c;
            this.articleTitle = articleTitle;
            // Defensive read: not every caller's SELECT pulls Status__c. Reading
            // an unqueried field throws SObjectException, so only read it when
            // present (mirrors the ArticleAssessmentResult mapper's approach).
            if (row.getPopulatedFieldsAsMap().containsKey('Status__c')) {
                this.status = row.Status__c;
            }
        }
    }

    public class AssessmentRunResult {
        @AuraEnabled public String runId { get; set; }
 // auto-number Name (RUN-####) and the user-supplied name/
        // description from the "Assessment details" step. The UI shows
        // userRunName when present, falling back to runName (auto-number) —
        // the "golden thread" name surfaced on the preview/results view.
        @AuraEnabled public String runName { get; set; }
        @AuraEnabled public String userRunName { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal overallScore { get; set; }
        @AuraEnabled public Integer totalArticles { get; set; }
        @AuraEnabled public Integer readyCount { get; set; }
        @AuraEnabled public Integer needsWorkCount { get; set; }
        @AuraEnabled public Integer notReadyCount { get; set; }
        @AuraEnabled public List<ArticleAssessmentResult> articleResults { get; set; }
        @AuraEnabled public String status { get; set; }
 // run timestamps surfaced on the results "Run details" panel.
        // startedAt prefers Scan_Start_Time__c (re-stamped on a destructive
        // rerun) and falls back to createdDate; completedAt is the finish time.
        // The LWC computes duration from startedAt → completedAt.
        @AuraEnabled public Datetime createdDate { get; set; }
        @AuraEnabled public Datetime startedAt { get; set; }
        @AuraEnabled public Datetime completedAt { get; set; }
        // Populated on Failed runs by KBAssessmentPipelineCallback so the
 // runner LWC's safety-net poll can mirror the live event's
        // reason when the race caused the Failed event to be missed.
        @AuraEnabled public String statusMessage { get; set; }
        @AuraEnabled public String assessmentTypesCsv { get; set; }
        @AuraEnabled public String requestedScope { get; set; }
        @AuraEnabled public Integer selectedDimensionCount { get; set; }
        @AuraEnabled public String pipelineRunId { get; set; }
 // number of in-scope articles skipped on a rerun because their
        // parent has no current published version (archived / retired / merged).
        // The rerun proceeds for the rest; the LWC warns the user with this count.
        @AuraEnabled public Integer skippedNoPublishedVersionCount { get; set; }

        /**
         * Run-level aggregate dimension scores keyed by DeveloperName.
         * Populated by KBAssessmentPipelineCallback at finalization via a
         * GROUP BY on KB_Dimension_Result__c.
         */
        @AuraEnabled public Map<String, Decimal> dimensionScores { get; set; }

        @AuraEnabled public String maturityTier { get; set; }
        @AuraEnabled public String deploymentTier { get; set; }
        @AuraEnabled public Boolean usedLLM { get; set; }
 // server-side gate for the LWC Cancel button. Computed
        // from the running user's FLS on KB_Assessment_Run__c.Status__c —
        // identical to what `update as user` enforces at DML time. Read-only
        // users (Viewer permset) get false and the LWC hides the button
        // rather than rendering a click-then-error toast.
        @AuraEnabled public Boolean canCancel { get; set; }

        public AssessmentRunResult() {
            this.totalArticles = 0;
            this.readyCount = 0;
            this.needsWorkCount = 0;
            this.notReadyCount = 0;
            this.overallScore = 0;
            this.articleResults = new List<ArticleAssessmentResult>();
            this.dimensionScores = new Map<String, Decimal>();
            this.status = 'Pending';
            this.usedLLM = false;
        }

        public void calculateSummary() {
            if (this.articleResults.isEmpty()) {
                return;
            }

            this.totalArticles = this.articleResults.size();
            this.readyCount = 0;
            this.needsWorkCount = 0;
            this.notReadyCount = 0;

            Decimal totalScore = 0;
            for (ArticleAssessmentResult result : this.articleResults) {
                totalScore += (result.overallScore == null ? 0 : result.overallScore);
                if (result.readinessStatus == 'Ready') {
                    this.readyCount++;
                } else if (result.readinessStatus == 'Needs Work') {
                    this.needsWorkCount++;
                } else {
                    this.notReadyCount++;
                }
            }

            this.overallScore = (totalScore / this.totalArticles).setScale(2);
        }
    }

    public class OrgHealthData {
        @AuraEnabled public Integer totalPublishedArticles { get; set; }
        @AuraEnabled public Integer totalAssessedArticles { get; set; }
        @AuraEnabled public Decimal coveragePct { get; set; }
        @AuraEnabled public Boolean hasScanConfig { get; set; }
        @AuraEnabled public Boolean hasScoreWeights { get; set; }
        @AuraEnabled public Boolean hasCompletedRun { get; set; }
        @AuraEnabled public Integer pendingDuplicates { get; set; }
        @AuraEnabled public Integer pendingEnrichments { get; set; }
        @AuraEnabled public Datetime lastScanDate { get; set; }
        @AuraEnabled public String nextScheduledRun { get; set; }
        @AuraEnabled public List<RunSummary> runHistory { get; set; }
        @AuraEnabled public List<DimensionTrend> dimensionTrends { get; set; }

        public OrgHealthData() {
            this.totalPublishedArticles = 0;
            this.totalAssessedArticles = 0;
            this.coveragePct = 0;
            this.hasScanConfig = false;
            this.hasScoreWeights = false;
            this.hasCompletedRun = false;
            this.pendingDuplicates = 0;
            this.pendingEnrichments = 0;
            this.runHistory = new List<RunSummary>();
            this.dimensionTrends = new List<DimensionTrend>();
        }
    }

    public class RunSummary {
        @AuraEnabled public String runId { get; set; }
        @AuraEnabled public String runName { get; set; }
        @AuraEnabled public Decimal overallScore { get; set; }
        @AuraEnabled public Integer totalArticles { get; set; }
        @AuraEnabled public Datetime completedAt { get; set; }
        @AuraEnabled public Boolean usedLLM { get; set; }
        @AuraEnabled public String requestedScope { get; set; }
        @AuraEnabled public String selectedDimensionsJSON { get; set; }
        @AuraEnabled public String effectiveWeightsJSON { get; set; }
        @AuraEnabled public String filterDslJSON { get; set; }
        @AuraEnabled public String maturityTier { get; set; }
        @AuraEnabled public String deploymentTier { get; set; }
        @AuraEnabled public Boolean comparableToPrevious { get; set; }
        @AuraEnabled public String incompatibilityReason { get; set; }
    }

    public class DimensionTrend {
        @AuraEnabled public String dimension { get; set; }
        @AuraEnabled public Decimal averageScore { get; set; }
        @AuraEnabled public Decimal latestScore { get; set; }
        @AuraEnabled public Boolean isPersistentWeakSpot { get; set; }
        @AuraEnabled public Integer runsBelow50 { get; set; }
    }

    public class DashboardData {
        @AuraEnabled public AssessmentRunResult latestRun { get; set; }
        @AuraEnabled public List<RecommendationResult> quickWins { get; set; }
        @AuraEnabled public Decimal previousOverallScore { get; set; }
        @AuraEnabled public Integer previousTotalArticles { get; set; }
        @AuraEnabled public Integer totalPublishedArticles { get; set; }
        @AuraEnabled public Boolean hasScanConfig { get; set; }
        @AuraEnabled public Boolean hasScoreWeights { get; set; }
        @AuraEnabled public Boolean hasCompletedRun { get; set; }
        @AuraEnabled public Datetime lastScanDate { get; set; }

        public DashboardData() {
            this.quickWins = new List<RecommendationResult>();
            this.hasCompletedRun = false;
            this.hasScanConfig = false;
            this.hasScoreWeights = false;
            this.totalPublishedArticles = 0;
        }
    }

    public class ArticleFilterResult {
        @AuraEnabled public List<ArticleWrapper> articles { get; set; }
        @AuraEnabled public Integer totalCount { get; set; }
        @AuraEnabled public Boolean hasMore { get; set; }
        // True when a filterFormula was supplied but couldn't be applied, so the
 // legacy AND-of-all-clauses path produced these rows instead. The
        // LWC toasts "formula was invalid; showing AND of all clauses".
        @AuraEnabled public Boolean formulaFallbackApplied { get; set; }

        public ArticleFilterResult() {
            this.articles = new List<ArticleWrapper>();
            this.totalCount = 0;
            this.hasMore = false;
            this.formulaFallbackApplied = false;
        }
    }

    public class AssessmentProgress {
        @AuraEnabled public Integer total { get; set; }
        @AuraEnabled public Integer completed { get; set; }
        @AuraEnabled public Integer percentComplete { get; set; }
        @AuraEnabled public String currentArticle { get; set; }
        @AuraEnabled public String status { get; set; }

        public AssessmentProgress() {
            this.total = 0;
            this.completed = 0;
            this.percentComplete = 0;
            this.status = 'Pending';
        }
    }

    /**
     * One unit of scoring work dispatched to a KBAssessmentDimensionQueueable in
     * the ≤cap fan-out tier. A deterministic dimension is one task over all its
     * articles; an LLM dimension is split into several tasks (article-chunks) so
     * they run concurrently. `token` is an opaque sequential id used by the
     * run's completion gate (Dispatched/Completed_Dimensions__c hold tokens, not
     * dimension names, since a dimension may map to multiple tasks).
     */
    public class ScoringTask {
        public String token;
        public String dimensionName;
        public List<String> articleIds;

        public ScoringTask(String token, String dimensionName, List<String> articleIds) {
            this.token = token;
            this.dimensionName = dimensionName;
            this.articleIds = articleIds;
        }
    }

    /**
 * payload for prefilling the new-assessment modal when a user clones
     * an existing run. Carries the source run's editable "what to assess"
     * (name suggestion + description) and the article scope re-resolved to the
     * CURRENT published versions, so cloning always assesses live content. The
     * article ids are the only scope carried — the selector self-hydrates the
     * basket rows via getArticlesByIds, and the clone submits as a plain
     * 'Selected' run. droppedNoPublishedVersionCount surfaces membership churn
     * (parents whose only version was archived/retired/merged away) to the user.
     */
    public class RunSelectionForClone {
        @AuraEnabled public String suggestedRunName;
        @AuraEnabled public String description;
        // The article versions the clone will assess. CAPPED to a UI-sane size
        // (see KBAssessmentService.CLONE_ARTICLE_CAP) so a huge cloned scope
        // can't overload the selector datatable / preview list.
        @AuraEnabled public List<String> articleIds;
        // Parents dropped because they have no current published version
        // (archived / retired / merged) — drives the churn toast.
        @AuraEnabled public Integer droppedNoPublishedVersionCount;
        // The FULL resolved article count BEFORE the UI cap was applied. When
        // this exceeds articleIds.size() the LWC warns that the clone was
        // limited to the first N (so the cap is never a silent truncation).
        @AuraEnabled public Integer resolvedArticleCount;
    }
}
