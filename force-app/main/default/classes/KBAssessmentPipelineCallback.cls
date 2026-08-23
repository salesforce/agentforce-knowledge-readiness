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
 * Pipeline Callback — Phase 2 of assessment.
 * Enqueued after the dedup pipeline has written Duplicate_Candidate__c rows.
 * Re-scores Duplication + Conflict dimensions, updates the corresponding
 * KB_Dimension_Result__c rows (not parent columns), recomputes per-article
 * overall scores, aggregates run-level per-dim averages, and finalizes the
 * KB_Assessment_Run__c.
 *
 * All per-dimension data lives on KB_Dimension_Result__c (child of
 * KB_Article_Assessment__c). Run-level aggregates are denormalised back onto
 * KB_Assessment_Run__c so the dashboard can read one row.
 */
public with sharing class KBAssessmentPipelineCallback implements Queueable, Database.AllowsCallouts {

    private Id runId;
    private Set<String> selectedDimensions;
    private Map<String, Decimal> effectiveWeights;
    private Id pipelineRunId;

    /**
     * Test-only injection: when true, execute() throws right after
     * initializeRunContext() so the outer try/catch path can be exercised
     * with a real run + assessments in scope (i.e. without relying on the
     * SOQL-empty path that would short-circuit before reaching the catch).
     * The previous "phantom Id" test (T9) didn't actually exercise the catch
     * — the empty-assessments early-return swallowed the no-op before any
     * catchable failure could surface.
     */
    @TestVisible
    private static Boolean throwAfterInitializeForTest = false;

    public KBAssessmentPipelineCallback(Id runId) {
        this.runId = runId;
    }

    public void execute(QueueableContext context) {
 // Cancel gate. Short-circuit BEFORE the 'In Progress' PE
        // so a cancelled run doesn't reanimate the runner's UI back into a
        // running state. Publish a 'Cancelled' PE so any subscribed LWC flips
        // immediately without waiting for the next safety-net poll.
        //
        // Note: KBAssessmentService.cancelAssessmentRun also publishes a
        // 'Cancelled' PE. The duplication is intentional — whichever fires
        // first wins; the LWC's _terminalReached guard de-dupes on the client.
        if (KBAssessmentService.isCancelled(this.runId)) {
            try {
                publishProgress('Cancelled', 'Run cancelled by user.');
            } catch (Exception ignore) { /* PE publish best-effort */ }
            return;
        }

        try {
            System.debug(LoggingLevel.INFO, 'Pipeline callback: start execute for run ' + this.runId);
            publishProgress('In Progress', 'Finalising results…');
            initializeRunContext();
            if (Test.isRunningTest() && throwAfterInitializeForTest) {
                // Reset the flag immediately so subsequent assertions/cleanup
                // (e.g. updateRunStatus inside the catch) do not re-trigger.
                throwAfterInitializeForTest = false;
                throw new KBAssessmentPipelineCallbackTestException('Injected mid-execute failure for outer-catch coverage');
            }

            // Load parent assessments and their current dimension result rows
            List<KB_Article_Assessment__c> assessments = [
                SELECT Id, Knowledge__c, Article_Title__c,
                       Overall_Score__c, Readiness_Status__c, Has_Conflicts__c,
                       Pipeline_Skip_Reason__c,
                       (SELECT Id, Dimension__c, Score__c, Reasoning__c,
                               Is_Unassessable__c, Scorer_Mode__c
                        FROM Dimension_Results__r)
                FROM KB_Article_Assessment__c
                WHERE Assessment_Run__c = :this.runId
            ];

            if (assessments.isEmpty()) {
                publishProgress('Failed', 'No assessments found for pipeline callback');
                updateRunStatus('Failed');
                markPipelineFailed('No assessments found for callback');
                return;
            }

            Boolean evaluateDuplication = this.selectedDimensions.contains('Duplication');
            Boolean evaluateConflict = this.selectedDimensions.contains('Conflict');

            if (!evaluateDuplication && !evaluateConflict) {
                publishProgress('In Progress', 'Finalising results…');
                // Compute and write overall scores from existing dimension results.
                // Without this the Overall_Score__c stays null when Dup/Conflict are skipped.
                List<KB_Article_Assessment__c> noDedupeUpdates = new List<KB_Article_Assessment__c>();
                for (KB_Article_Assessment__c a : assessments) {
                    Map<String, KB_Dimension_Result__c> byDim = new Map<String, KB_Dimension_Result__c>();
                    if (a.Dimension_Results__r != null) {
                        for (KB_Dimension_Result__c d : a.Dimension_Results__r) {
                            byDim.put(d.Dimension__c, d);
                        }
                    }
                    Map<String, Decimal> scoresMap = scoresForOverall(byDim, null, null);
                    Decimal overallScore = computeOverall(scoresMap);
                    noDedupeUpdates.add(new KB_Article_Assessment__c(
                        Id = a.Id,
                        Overall_Score__c = overallScore,
                        Readiness_Status__c = classifyReadiness(overallScore)
                    ));
                }
                if (!noDedupeUpdates.isEmpty()) update noDedupeUpdates;
                finalizeRun();
                completePipelineRun(assessments.size());
                return;
            }

            publishProgress('In Progress', 'Checking for duplicates and conflicts…');

            List<String> articleIds = new List<String>();
            for (KB_Article_Assessment__c a : assessments) {
                articleIds.add(a.Knowledge__c);
            }

            Map<String, Decimal> dupScores = KBPipelineBridgeService.getBatchDuplicationScores(articleIds, this.runId);
            Map<String, Decimal> conflictScores = KBPipelineBridgeService.getBatchConflictScores(articleIds, this.runId);
            Map<String, List<Duplicate_Candidate__c>> allCandidates =
                KBPipelineBridgeService.getBatchCandidates(articleIds, this.runId);

            KBDuplicationScorer dupScorer = new KBDuplicationScorer();
            KBConflictScorer conflictScorer = new KBConflictScorer();

            // Drop placeholder Duplication/Conflict rows for gate-excluded
            // articles — KBAssessmentDimensionQueueable writes them pre-pipeline
            // (score=100 with no candidates). Skipped articles never reach
            // Tier 2, so those rows are noise; absence = N/A in the LWC.
            // Master-detail to KB_Dimension_Result__c, so analysis children
            // cascade-delete with the parent rows.
            Set<Id> skippedAssessmentIds = new Set<Id>();
            for (KB_Article_Assessment__c a : assessments) {
                if (String.isNotBlank(a.Pipeline_Skip_Reason__c)) skippedAssessmentIds.add(a.Id);
            }
            if (!skippedAssessmentIds.isEmpty()) {
                List<String> skippedDims = new List<String>();
                if (evaluateDuplication) skippedDims.add('Duplication');
                if (evaluateConflict) skippedDims.add('Conflict');
                if (!skippedDims.isEmpty()) {
                    delete [
                        SELECT Id FROM KB_Dimension_Result__c
                        WHERE Article_Assessment__c IN :skippedAssessmentIds
                          AND Dimension__c IN :skippedDims
                    ];
                }
            }

            List<KB_Dimension_Result__c> dimChildUpserts = new List<KB_Dimension_Result__c>();
            List<KB_Article_Assessment__c> parentUpdates = new List<KB_Article_Assessment__c>();

            for (KB_Article_Assessment__c a : assessments) {
                String artId = a.Knowledge__c;

                // Index existing dimension rows by name for this article
                Map<String, KB_Dimension_Result__c> byDim = new Map<String, KB_Dimension_Result__c>();
                if (a.Dimension_Results__r != null) {
                    for (KB_Dimension_Result__c d : a.Dimension_Results__r) {
                        byDim.put(d.Dimension__c, d);
                    }
                }

                // Articles excluded by the quality gate never reached Tier 2,
                // so we have no pipeline signal to score Duplication/Conflict.
                // Skip writing dimension result rows entirely — absence of a
                // row means "not assessed" (LWC renders N/A from the missing
                // key in scoresByDim). The reason already lives on the parent's
                // Pipeline_Skip_Reason__c so we don't duplicate it per dim.
                Boolean pipelineSkipped = String.isNotBlank(a.Pipeline_Skip_Reason__c);

                // Per-article default of 100 = "passed the quality gate, no
                // duplicate/conflict candidates surfaced for this article" =
                // perfect score on this dimension. This default is only
                // consumed when `pipelineSkipped` is false (the bulk-fetch
                // misses an article id when there are zero pipeline rows for
                // it). For gate-skipped articles we short-circuit below and
                // never write a row — absence of the row is what makes the
 // dim render as N/A in the LWC. See.
                Decimal dupPipelineScore = dupScores.containsKey(artId) ? dupScores.get(artId) : 100;
                Decimal confPipelineScore = conflictScores.containsKey(artId) ? conflictScores.get(artId) : 100;
                List<Duplicate_Candidate__c> candidates = allCandidates.containsKey(artId)
                    ? allCandidates.get(artId) : new List<Duplicate_Candidate__c>();

                KBAssessmentModels.DimensionScore dupResult = (evaluateDuplication && !pipelineSkipped)
                    ? dupScorer.scoreDuplicationBulk(artId, dupPipelineScore, candidates)
                    : null;
                KBAssessmentModels.DimensionScore confResult = (evaluateConflict && !pipelineSkipped)
                    ? conflictScorer.scoreConflictBulk(artId, confPipelineScore, candidates)
                    : null;

                if (dupResult != null) {
                    dimChildUpserts.add(buildChildUpsert(a.Id, 'Duplication', dupResult, byDim));
                }
                if (confResult != null) {
                    dimChildUpserts.add(buildChildUpsert(a.Id, 'Conflict', confResult, byDim));
                }

                // Recompute overall from the ENTIRE scoresByDim (after dup/conflict update)
                Map<String, Decimal> scoresForOverall = scoresForOverall(byDim, dupResult, confResult);
                Decimal overallScore = computeOverall(scoresForOverall);
                String readinessStatus = classifyReadiness(overallScore);

                parentUpdates.add(new KB_Article_Assessment__c(
                    Id = a.Id,
                    Overall_Score__c = overallScore,
                    Readiness_Status__c = readinessStatus,
                    Has_Conflicts__c = confResult != null
                        ? (confResult.score != null && confResult.score < 80)
                        : a.Has_Conflicts__c
                ));
            }

            if (!dimChildUpserts.isEmpty()) upsert dimChildUpserts;
            if (!parentUpdates.isEmpty()) update parentUpdates;

            generatePipelineRecommendations(assessments, dupScores, conflictScores, allCandidates,
                dupScorer, conflictScorer, evaluateDuplication, evaluateConflict);

            finalizeRun();
            completePipelineRun(assessments.size());

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'KBAssessmentPipelineCallback failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            String reason = 'Pipeline callback error: ' + e.getMessage();
            publishProgress('Failed', reason);
            // Persist the same reason so the runner LWC's safety-net poll
 // can show the actual cause for users who hit the
            // race window where the live Failed event was missed.
            updateRunStatus('Failed', reason);
            markPipelineFailed(e.getMessage());
        }
    }

    /**
     * Build an insert-or-update KB_Dimension_Result__c row. If an existing
     * child row for this dim exists on the parent, update it (preserving Id);
     * otherwise create a new child with the master-detail set.
     */
    private KB_Dimension_Result__c buildChildUpsert(
        Id parentId,
        String dimName,
        KBAssessmentModels.DimensionScore score,
        Map<String, KB_Dimension_Result__c> byDim
    ) {
        KB_Dimension_Result__c existing = byDim.get(dimName);
        KB_Dimension_Result__c row;
        if (existing != null) {
            row = new KB_Dimension_Result__c(Id = existing.Id);
        } else {
            row = new KB_Dimension_Result__c(
                Article_Assessment__c = parentId,
                Dimension__c = dimName
            );
        }
        row.Score__c = score.score;
        row.Reasoning__c = truncate(score.reasoning, 32000);
        row.Is_Unassessable__c = score.isUnassessable == true;
        row.Scorer_Mode__c = score.scorerMode;
        return row;
    }

    /**
     * Merge existing child scores with the newly-computed dup/conflict scores
     * into a single flat map for overall-score recomputation.
     */
    private Map<String, Decimal> scoresForOverall(
        Map<String, KB_Dimension_Result__c> byDim,
        KBAssessmentModels.DimensionScore dupNew,
        KBAssessmentModels.DimensionScore confNew
    ) {
        Map<String, Decimal> out = new Map<String, Decimal>();
        for (String k : byDim.keySet()) {
            KB_Dimension_Result__c row = byDim.get(k);
            if (row.Is_Unassessable__c == true) continue;
            if (row.Score__c != null) out.put(k, row.Score__c);
        }
        if (dupNew != null && dupNew.isUnassessable != true && dupNew.score != null) {
            out.put('Duplication', dupNew.score);
        }
        if (confNew != null && confNew.isUnassessable != true && confNew.score != null) {
            out.put('Conflict', confNew.score);
        }
        return out;
    }

    /**
     * Weighted sum of per-dim scores, renormalised over the dims actually
     * present in the map. Empty map → 0.
     */
    private Decimal computeOverall(Map<String, Decimal> scores) {
        if (scores == null || scores.isEmpty()) return 0;
        Decimal weightedTotal = 0;
        Decimal weightSum = 0;
        for (String dim : scores.keySet()) {
            if (!this.selectedDimensions.contains(dim)) continue;
            Decimal w = getWeight(dim);
            if (w == null || w == 0) continue;
            weightedTotal += scores.get(dim) * w;
            weightSum += w;
        }
        return weightSum == 0 ? 0 : (weightedTotal / weightSum).setScale(2);
    }

    private String classifyReadiness(Decimal overallScore) {
        if (overallScore == null) return 'Not Ready';
        if (overallScore >= 80) return 'Ready';
        if (overallScore >= 50) return 'Needs Work';
        return 'Not Ready';
    }

    private void initializeRunContext() {
        KB_Assessment_Run__c run = [
            SELECT Selected_Dimensions_JSON__c, Effective_Weights_JSON__c,
                   Pipeline_Run__c
            FROM KB_Assessment_Run__c
            WHERE Id = :this.runId
            LIMIT 1
        ];

        Set<String> active = DimensionRegistry.getActiveDeveloperNames();
        this.selectedDimensions = new Set<String>();
        if (String.isNotBlank(run.Selected_Dimensions_JSON__c)) {
            try {
                for (Object item : (List<Object>) JSON.deserializeUntyped(run.Selected_Dimensions_JSON__c)) {
                    String dim = String.valueOf(item);
                    if (active.contains(dim)) this.selectedDimensions.add(dim);
                }
            } catch (Exception e) {
                this.selectedDimensions.clear();
            }
        }
        if (this.selectedDimensions.isEmpty()) this.selectedDimensions.addAll(active);

        this.effectiveWeights = new Map<String, Decimal>();
        if (String.isNotBlank(run.Effective_Weights_JSON__c)) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(run.Effective_Weights_JSON__c);
                for (String key : parsed.keySet()) {
                    this.effectiveWeights.put(key, Decimal.valueOf(String.valueOf(parsed.get(key))));
                }
            } catch (Exception e) {
                this.effectiveWeights.clear();
            }
        }
        if (this.effectiveWeights.isEmpty()) {
            this.effectiveWeights.putAll(DimensionRegistry.getActiveWeights());
        }

        this.pipelineRunId = run.Pipeline_Run__c;
    }

    private void completePipelineRun(Integer processedCount) {
        if (this.pipelineRunId == null) return;

        Integer evalCount = [
            SELECT COUNT() FROM Knowledge_Pair_Evaluation__c
            WHERE Pipeline_Run__c = :this.pipelineRunId
        ];

        update new KB_Pipeline_Run__c(
            Id = this.pipelineRunId,
            Status__c = 'Completed',
            Completed_At__c = Datetime.now(),
            Processed_Count__c = processedCount,
            Pair_Evaluations_Created__c = evalCount
        );
    }

    private void markPipelineFailed(String message) {
        if (this.pipelineRunId == null) return;
        update new KB_Pipeline_Run__c(
            Id = this.pipelineRunId,
            Status__c = 'Failed',
            Completed_At__c = Datetime.now(),
            Error_Count__c = 1
        );
    }

    private Decimal getWeight(String key) {
        if (this.effectiveWeights != null && this.effectiveWeights.containsKey(key) && this.effectiveWeights.get(key) != null) {
            return this.effectiveWeights.get(key);
        }
        return DimensionRegistry.getWeight(key);
    }

    private void generatePipelineRecommendations(
        List<KB_Article_Assessment__c> assessments,
        Map<String, Decimal> dupScores, Map<String, Decimal> conflictScores,
        Map<String, List<Duplicate_Candidate__c>> allCandidates,
        KBDuplicationScorer dupScorer, KBConflictScorer conflictScorer,
        Boolean evaluateDuplication, Boolean evaluateConflict
    ) {
        if (!evaluateDuplication && !evaluateConflict) return;
        Set<Id> assessmentIds = new Set<Id>();
        for (KB_Article_Assessment__c a : assessments) {
            if (a.Id != null) assessmentIds.add(a.Id);
        }

        // Index dimension result rows so we can stamp KB_Dimension_Analysis__c
        // master-detail Ids for the Duplication/Conflict dims that just got
        // their final scores from the pipeline.
        Map<Id, Map<String, Id>> dimResultIdByAssessmentDim =
            new Map<Id, Map<String, Id>>();
        if (!assessmentIds.isEmpty()) {
            for (KB_Dimension_Result__c d : [
                SELECT Id, Article_Assessment__c, Dimension__c
                FROM KB_Dimension_Result__c
                WHERE Article_Assessment__c IN :assessmentIds
                  AND Dimension__c IN ('Duplication', 'Conflict')
            ]) {
                if (!dimResultIdByAssessmentDim.containsKey(d.Article_Assessment__c)) {
                    dimResultIdByAssessmentDim.put(d.Article_Assessment__c, new Map<String, Id>());
                }
                dimResultIdByAssessmentDim.get(d.Article_Assessment__c).put(d.Dimension__c, d.Id);
            }

            // Replace any previous analysis rows for these (assessment, dim).
            // Master-detail to KB_Dimension_Result__c, so deleting by parent
            // assessment + dim handles both new and re-runs.
            Set<Id> resultIdsToReset = new Set<Id>();
            for (Map<String, Id> byDim : dimResultIdByAssessmentDim.values()) {
                resultIdsToReset.addAll(byDim.values());
            }
            if (!resultIdsToReset.isEmpty()) {
                delete [
                    SELECT Id FROM KB_Dimension_Analysis__c
                    WHERE Dimension_Result__c IN :resultIdsToReset
                ];
            }
        }

        // Bulk-load article text for Annotate_Issue_Severity calls (now async).
        // For each article with pipeline-derived dup/conflict issues we need
        // its own (Title/Summary/body) plus a representative counterpart's
        // (highest-confidence candidate's) — fetched in one SOQL keyed off
        // candidates so we don't re-query per row inside the loop. The
        // resolved text feeds into the AnnotationTask payloads handed off to
        // KBSeverityAnnotationQueueable below.
        Map<Id, Knowledge__kav> articleTextById = bulkFetchArticleText(assessments, allCandidates);
        List<String> contentFields = getContentFieldsCached();

        // Per-task scratchpad: each entry pairs the inserted analysis row
        // *positions* (not Ids — those don't exist yet pre-insert) with the
        // metadata the queueable will need post-insert. After we run `insert`
        // below we walk this pad and copy the assigned Ids over to the tasks.
        List<KB_Dimension_Analysis__c> analyses = new List<KB_Dimension_Analysis__c>();
        List<TaskAssemblyPlan> taskPlans = new List<TaskAssemblyPlan>();

        for (KB_Article_Assessment__c a : assessments) {
            // Excluded-from-dedup articles have unassessable Dup/Conflict —
            // skip analysis-row generation so we don't seed the LWC with
            // false-positive strengths.
            if (String.isNotBlank(a.Pipeline_Skip_Reason__c)) continue;

            String artId = a.Knowledge__c;
            Decimal dupPipelineScore = dupScores.containsKey(artId) ? dupScores.get(artId) : 100;
            Decimal confPipelineScore = conflictScores.containsKey(artId) ? conflictScores.get(artId) : 100;
            List<Duplicate_Candidate__c> candidates = allCandidates.containsKey(artId)
                ? allCandidates.get(artId) : new List<Duplicate_Candidate__c>();
            Map<String, Id> dimIdsForAssessment = dimResultIdByAssessmentDim.containsKey(a.Id)
                ? dimResultIdByAssessmentDim.get(a.Id) : new Map<String, Id>();

            if (evaluateDuplication) {
                KBAssessmentModels.DimensionScore dupResult =
                    dupScorer.scoreDuplicationBulk(artId, dupPipelineScore, candidates);
                Id dupResultId = dimIdsForAssessment.get('Duplication');
                if (dupResultId != null) {
                    appendAnalysesAndTaskPlan(
                        analyses, taskPlans, a.Id, artId, 'Duplication',
                        new Set<String>{ 'Duplicate' },
                        dupResult, dupResultId, candidates, articleTextById, contentFields
                    );
                }
            }
            if (evaluateConflict) {
                KBAssessmentModels.DimensionScore confResult =
                    conflictScorer.scoreConflictBulk(artId, confPipelineScore, candidates);
                Id confResultId = dimIdsForAssessment.get('Conflict');
                if (confResultId != null) {
                    appendAnalysesAndTaskPlan(
                        analyses, taskPlans, a.Id, artId, 'Conflict',
                        new Set<String>{ 'Contradiction' }, // 'Overlap' retired
                        confResult, confResultId, candidates, articleTextById, contentFields
                    );
                }
            }
        }

        if (!analyses.isEmpty()) insert analyses;

        // Severity annotation moves async. Build queueable tasks now that
        // analysis rows have Ids. Each plan's analysisRowPositions index back
        // into the master `analyses` list — Apex preserves list order through
        // insert, so analyses[pos].Id is the freshly-assigned Id for that row.
        List<KBSeverityAnnotationQueueable.AnnotationTask> tasks =
            new List<KBSeverityAnnotationQueueable.AnnotationTask>();
        for (TaskAssemblyPlan plan : taskPlans) {
            if (plan == null || plan.analysisRowPositions == null || plan.analysisRowPositions.isEmpty()) {
                continue;
            }
            KBSeverityAnnotationQueueable.AnnotationTask task =
                new KBSeverityAnnotationQueueable.AnnotationTask();
            task.articleId          = plan.articleId;
            task.dimension          = plan.dimension;
            task.selfTitle          = plan.selfTitle;
            task.selfSummary        = plan.selfSummary;
            task.selfBody           = plan.selfBody;
            task.counterpartTitle   = plan.counterpartTitle;
            task.counterpartSummary = plan.counterpartSummary;
            task.counterpartBody    = plan.counterpartBody;
            task.issueTexts         = plan.issueTexts;
            task.strengths          = plan.strengths;
            for (Integer pos : plan.analysisRowPositions) {
                if (pos >= 0 && pos < analyses.size()) {
                    task.analysisRowIds.add(analyses[pos].Id);
                }
            }
            // Idempotency guard: the only thing the queueable writes are the
            // three severity fields. If somehow a re-run brings up rows
            // already populated (manual seed, prior queueable success), the
            // queueable's UPDATE on the same Ids is a no-op for matching
            // values. Tasks with no row Ids are dropped here so we never
            // enqueue a no-op chunk.
            if (!task.analysisRowIds.isEmpty()) tasks.add(task);
        }
        if (!tasks.isEmpty()) {
            // Skip the enqueue when there are no annotatable issues at all —
            // saves a queueable slot for runs with only strength rows.
            System.enqueueJob(new KBSeverityAnnotationQueueable(tasks));
        }
    }

    /**
     * Build the analysis rows for a (article, dimension) pair AND the matching
     * task plan in lockstep so positions stay aligned. Captures the issue rows'
     * positions in the master `analyses` list — those positions resolve to Ids
     * once the caller `insert`s the list.
     *
     * Mirrors the per-issue dedupe/truncate KBDimensionAnalysisService applies
     * so the queueable's issueTexts list lines up index-by-index with the
     * actual KB_Dimension_Analysis__c rows we'll be updating.
     */
    private void appendAnalysesAndTaskPlan(
        List<KB_Dimension_Analysis__c> analyses,
        List<TaskAssemblyPlan> taskPlans,
        Id articleAssessmentId,
        String articleId,
        String dimensionName,
        Set<String> matchingFlagTypes,
        KBAssessmentModels.DimensionScore result,
        Id dimensionResultId,
        List<Duplicate_Candidate__c> candidates,
        Map<Id, Knowledge__kav> articleTextById,
        List<String> contentFields
    ) {
        List<KB_Dimension_Analysis__c> rowsForDim = KBDimensionAnalysisService.buildForDimension(
            dimensionResultId, articleAssessmentId, dimensionName, result
        );
        if (rowsForDim == null || rowsForDim.isEmpty()) return;

        // Filter to issue rows in the same order KBDimensionAnalysisService
        // emits them — that order matches the deduped/truncated issue texts
        // we feed into the LLM payload.
        List<Integer> issuePositions = new List<Integer>();
        List<String> issueTexts = new List<String>();
        for (KB_Dimension_Analysis__c row : rowsForDim) {
            Integer indexInMaster = analyses.size();
            analyses.add(row);
            if (KBDimensionAnalysisService.TYPE_ISSUE.equalsIgnoreCase(row.Type__c)) {
                issuePositions.add(indexInMaster);
                issueTexts.add(row.Analysis_Text__c);
            }
        }

        if (issuePositions.isEmpty()) return; // strength-only — no LLM work

        TaskAssemblyPlan plan = new TaskAssemblyPlan();
        plan.articleId = (Id) articleId;
        plan.dimension = dimensionName;
        plan.analysisRowPositions = issuePositions;
        plan.issueTexts = issueTexts;
        plan.strengths = result != null && result.strengths != null
            ? new List<String>(result.strengths)
            : new List<String>();

        Knowledge__kav self = articleTextById.get((Id) articleId);
        plan.selfTitle   = self != null ? self.Title : '';
        plan.selfSummary = self != null ? self.Summary : '';
        plan.selfBody    = self != null
            ? KBAssessmentService.buildArticleContent(self, contentFields)
            : '';

        Duplicate_Candidate__c topCandidate = pickTopCounterpart(articleId, candidates, matchingFlagTypes);
        Id counterpartId = null;
        if (topCandidate != null) {
            counterpartId = topCandidate.Knowledge_Article_1__c == articleId
                ? topCandidate.Knowledge_Article_2__c
                : topCandidate.Knowledge_Article_1__c;
        }
        Knowledge__kav counterpart = counterpartId != null ? articleTextById.get(counterpartId) : null;
        plan.counterpartTitle   = counterpart != null ? counterpart.Title : '';
        plan.counterpartSummary = counterpart != null ? counterpart.Summary : '';
        plan.counterpartBody    = counterpart != null
            ? KBAssessmentService.buildArticleContent(counterpart, contentFields)
            : '';

        taskPlans.add(plan);
    }

    /**
     * Pre-insert scratchpad: holds everything the AnnotationTask needs except
     * the row Ids (which don't exist yet) — those are filled in after the
     * batch insert by the calling method.
     */
    private class TaskAssemblyPlan {
        Id articleId;
        String dimension;
        String selfTitle;
        String selfSummary;
        String selfBody;
        String counterpartTitle;
        String counterpartSummary;
        String counterpartBody;
        List<String> issueTexts;
        List<String> strengths;
        List<Integer> analysisRowPositions;
    }

    /**
     * One-shot SOQL across the article + counterpart Ids needed by
     * Annotate_Issue_Severity. Returns the article rows keyed by Id; the
     * caller composes the body via KBAssessmentService.buildArticleContent()
     * using the same admin-configured content fields the scorers used. We
     * have to send the same fields the LLM flagged in scoring — otherwise
     * the rewriter on the next pass can't fix what was wrong, and the next
     * assessment will surface the same issue.
     */
    private Map<Id, Knowledge__kav> bulkFetchArticleText(
        List<KB_Article_Assessment__c> assessments,
        Map<String, List<Duplicate_Candidate__c>> allCandidates
    ) {
        Set<Id> ids = new Set<Id>();
        for (KB_Article_Assessment__c a : assessments) {
            if (a.Knowledge__c != null) ids.add((Id) a.Knowledge__c);
            List<Duplicate_Candidate__c> cands = allCandidates.get(a.Knowledge__c);
            if (cands == null) continue;
            for (Duplicate_Candidate__c dc : cands) {
                if (dc.Knowledge_Article_1__c != null) ids.add(dc.Knowledge_Article_1__c);
                if (dc.Knowledge_Article_2__c != null) ids.add(dc.Knowledge_Article_2__c);
            }
        }
        if (ids.isEmpty()) return new Map<Id, Knowledge__kav>();

        Set<String> fieldNames = new Set<String>{ 'Id', 'Title', 'Summary' };
        for (String f : KBAssessmentService.getContentFields('Knowledge__kav')) {
            if (String.isNotBlank(f)) fieldNames.add(f);
        }
        String selectClause = String.join(new List<String>(fieldNames), ', ');
        String soql = 'SELECT ' + selectClause + ' FROM Knowledge__kav WHERE Id IN :ids';
        // System mode (default) on purpose: selectClause pulls the admin-mapped
        // Knowledge content fields (FLS is the customer's to grant, not ours) so
        // the severity-annotation LLM sees the same body the scorer did. This
        // runs async off a whole-KB run; USER_MODE would throw on the content
        // fields for a Knowledge-read-only persona. (System mode relaxes FLS/CRUD
        // only, not Knowledge data-category record visibility — but this runs in
        // an async system context off the run's own scope, so it reads the run's
        // articles regardless of any one user's category access.)
        return new Map<Id, Knowledge__kav>((List<Knowledge__kav>) Database.query(soql));
    }

    /**
     * Cached list of admin-configured content fields, resolved once per
     * callback execution so we don't re-describe Knowledge__kav for every
     * dimension annotation.
     */
    private List<String> contentFieldsCache;

    private List<String> getContentFieldsCached() {
        if (this.contentFieldsCache == null) {
            this.contentFieldsCache = KBAssessmentService.getContentFields('Knowledge__kav');
        }
        return this.contentFieldsCache;
    }

    // Severity annotation lives in KBSeverityAnnotationQueueable now — the
    // sync path was issuing up to 100 callouts per execute() (50 articles ×
    // Dup+Conflict), which is the platform's per-transaction ceiling. The
    // queueable processes ~80 (article, dimension) tasks per chunk and
    // self-chains for any overflow. The callback inserts KB_Dimension_Analysis__c
    // rows with severity left null and the queueable backfills Impact__c /
    // Effort__c / Priority__c by Id once the LLM responds.

    private Duplicate_Candidate__c pickTopCounterpart(
        String articleId,
        List<Duplicate_Candidate__c> candidates,
        Set<String> matchingFlagTypes
    ) {
        if (candidates == null || candidates.isEmpty()) return null;
        Duplicate_Candidate__c best = null;
        Decimal bestScore = -1;
        for (Duplicate_Candidate__c dc : candidates) {
            if (!matchingFlagTypes.contains(dc.Flag_Type__c)) continue;
 // Skip user-discarded candidates. 'Not a Duplicate' is the
            // consolidated soft-discard status; 'Rejected'/'Suppressed' are its
            // retired predecessors, kept here for legacy rows not yet reset to Pending.
            if (dc.Status__c == 'Not a Duplicate'
                || dc.Status__c == 'Rejected'
                || dc.Status__c == 'Suppressed') continue;
            Decimal s = dc.Confidence_Score__c != null ? dc.Confidence_Score__c : 0;
            if (s > bestScore) {
                best = dc;
                bestScore = s;
            }
        }
        return best;
    }

    /**
     * Aggregate dimension scores from child rows and write run-level averages.
     */
    private void finalizeRun() {
        List<KB_Article_Assessment__c> parentStats = [
            SELECT Id, Overall_Score__c, Readiness_Status__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :this.runId
        ];

        if (parentStats.isEmpty()) {
            updateRunStatus('Failed');
            return;
        }

        Integer total = parentStats.size();
        Integer readyCount = 0, needsWorkCount = 0, notReadyCount = 0;
        Decimal totalScore = 0;
        for (KB_Article_Assessment__c a : parentStats) {
            totalScore += a.Overall_Score__c != null ? a.Overall_Score__c : 0;
            if (a.Readiness_Status__c == 'Ready') readyCount++;
            else if (a.Readiness_Status__c == 'Needs Work') needsWorkCount++;
            else notReadyCount++;
        }

        // Reconcile Used_LLM__c against what actually happened. The run was
        // stamped with intent at creation (any LLM-backed dimension selected);
        // here we set it to the ground truth — true iff at least one score was
        // produced by the LLM (Scorer_Mode__c = 'Hybrid'). A run whose LLM dims
        // all gate-skipped or fell back to the baseline reads as deterministic.
 // See.
        Boolean usedLLM = [
            SELECT COUNT()
            FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :this.runId
              AND Scorer_Mode__c = :KBScorerBase.MODE_HYBRID
        ] > 0;

        // Per-dim averages via aggregate on child rows
        Map<String, Decimal> dimAverages = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT Dimension__c dim, AVG(Score__c) avgScore
            FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :this.runId
              AND Is_Unassessable__c = false
              AND Score__c != null
            GROUP BY Dimension__c
        ]) {
            String dim = (String) ar.get('dim');
            Object avg = ar.get('avgScore');
            if (avg != null) {
                dimAverages.put(dim, ((Decimal) avg).setScale(0));
            }
        }

        // Compute wall-clock durations. Scoring duration was stamped by the
        // dispatcher; pipeline duration = total - scoring (null when no
        // dedup pipeline ran). Total is measured from Scan_Start_Time__c (the
        // moment scoring was dispatched) so it stays consistent with the
 // dispatcher's Scoring_Duration_Ms__c basis — critical for reruns,
        // which keep the original run's (older) CreatedDate. Falls back to
        // CreatedDate for historical runs created before the field was populated.
        Datetime completedAt = Datetime.now();
        Long totalMs = null;
        Long pipelineMs = null;
        try {
            KB_Assessment_Run__c runMeta = [
                SELECT CreatedDate, Scan_Start_Time__c, Scoring_Duration_Ms__c
                FROM KB_Assessment_Run__c WHERE Id = :this.runId LIMIT 1
            ];
            Datetime scanStart = runMeta.Scan_Start_Time__c != null
                ? runMeta.Scan_Start_Time__c : runMeta.CreatedDate;
            totalMs = completedAt.getTime() - scanStart.getTime();
            if (runMeta.Scoring_Duration_Ms__c != null) {
                pipelineMs = totalMs - runMeta.Scoring_Duration_Ms__c.longValue();
                if (pipelineMs < 0) pipelineMs = null;
            }
        } catch (Exception e) { /* non-fatal timing */ }

        update new KB_Assessment_Run__c(
            Id = this.runId,
            Status__c = 'Completed',
            Completed_At__c = completedAt,
            Used_LLM__c           = usedLLM,
            Overall_Score__c      = (totalScore / total).setScale(2),
            Ready_Count__c        = readyCount,
            Needs_Work_Count__c   = needsWorkCount,
            Not_Ready_Count__c    = notReadyCount,
            Completeness_Score__c = dimAverages.get('Completeness'),
            Structure_Score__c    = dimAverages.get('Structure'),
            Clarity_Score__c      = dimAverages.get('Clarity'),
            Freshness_Score__c    = dimAverages.get('Freshness'),
            Duplication_Score__c  = dimAverages.get('Duplication'),
            Conflict_Score__c     = dimAverages.get('Conflict'),
            Total_Duration_Ms__c  = totalMs,
            Pipeline_Duration_Ms__c = pipelineMs
        );

        publishProgress('Completed', 'Assessment complete! Scored ' + total + ' articles with pipeline analysis.');
    }

    private void updateRunStatus(String status) {
        updateRunStatus(status, null);
    }

    /**
     * Persist run status, and optionally a status message. Reused by the
 * Failed-transition path to write the same reason that's
     * published on the Platform Event channel into Status_Message__c, so the
     * runner LWC's safety-net poll can recover the detail when the live
     * Failed event was lost to the subscribe race.
     */
    @TestVisible
    private void updateRunStatus(String status, String message) {
        try {
            KB_Assessment_Run__c row = new KB_Assessment_Run__c(
                Id = this.runId,
                Status__c = status
            );
            if (String.isNotBlank(message)) {
                row.Status_Message__c = truncate(message, 1024);
            }
            update row;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to update run status: ' + e.getMessage());
        }
    }

    private void publishProgress(String status, String message) {
        try {
            KB_Assessment_Progress__e evt = new KB_Assessment_Progress__e(
                Assessment_Id__c = this.runId,
                Status__c = status,
                Message__c = message != null && message.length() > 255 ? message.substring(0, 255) : message
            );
            EventBus.publish(evt);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Failed to publish progress event: ' + e.getMessage());
        }
    }

    private static String truncate(String text, Integer maxLength) {
        if (text == null) return null;
        if (text.length() <= maxLength) return text;
        return text.substring(0, maxLength);
    }

    /**
     * Test-only exception thrown via the throwAfterInitializeForTest seam.
     * Distinct type so accidental real-world failures (e.g., unexpected
     * deserialization issues) don't masquerade as the injected case in the
     * test runner.
     */
    public class KBAssessmentPipelineCallbackTestException extends Exception {}
}