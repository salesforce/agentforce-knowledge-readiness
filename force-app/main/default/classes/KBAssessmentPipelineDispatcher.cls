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
 * Centralised handoff from scoring → dedup pipeline → finalization callback.
 *
 * When scoring completes on a run with executionMode = DEDUPLICATION and
 * Duplication / Conflict in the selected dimensions, we enqueue the dedup
 * pipeline (entry: Tier1VectorSearchQueueable). The pipeline chains through
 * Tier2 → Tier3 → Tier4 and enqueues KBAssessmentPipelineCallback at the
 * end. Otherwise — direct callback.
 *
 * Called from both tier 2 (KBAssessmentDimensionQueueable.markCompleted)
 * and tier 3 (KBAssessmentBatch.finish).
 */
public with sharing class KBAssessmentPipelineDispatcher {

    /**
     * Decide whether to run the dedup pipeline and enqueue the next job.
     * Returns true if pipeline tier 2 was enqueued; false if the callback
     * was enqueued directly.
     */
    public static Boolean dispatchFinalization(Id runId) {
        KB_Assessment_Run__c run;
        try {
            run = [
                SELECT Id, Pipeline_Run__c, Selected_Dimensions_JSON__c,
                       CreatedDate, Scan_Start_Time__c
                FROM KB_Assessment_Run__c
                WHERE Id = :runId
                LIMIT 1
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'KBAssessmentPipelineDispatcher: could not load run ' + runId + ': ' + e.getMessage());
            // Fall back to callback so we don't leave the run in limbo
            Id cbId = System.enqueueJob(new KBAssessmentPipelineCallback(runId));
            KBAssessmentService.recordAsyncJob(runId, cbId);
            return false;
        }

        // Wall-clock scoring time from when the scan actually started. Scan_Start_Time__c
        // is stamped at dispatch (new run: createRunRecord; rerun: resetRunForRerun), so
 // this measures scoring, not idle time since CreatedDate — critical for
        // reruns, which keep the original run's (older) CreatedDate. Falls back to
        // CreatedDate for historical runs created before the field was populated.
        Datetime scoringStart = run.Scan_Start_Time__c != null ? run.Scan_Start_Time__c : run.CreatedDate;
        Long scoringDurationMs = Datetime.now().getTime() - scoringStart.getTime();

        String executionMode = resolveExecutionMode(run.Pipeline_Run__c);
        Boolean wantsDedup = shouldRunPipeline(run, executionMode);
        if (!wantsDedup) {
            try {
                update new KB_Assessment_Run__c(
                    Id = runId,
                    Scoring_Duration_Ms__c = scoringDurationMs
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'KBAssessmentPipelineDispatcher: failed to update scoring duration for run '
                    + runId + ': ' + e.getMessage());
            }
            Id cbId = System.enqueueJob(new KBAssessmentPipelineCallback(runId));
            KBAssessmentService.recordAsyncJob(runId, cbId);
            return false;
        }

 // Quality gate: exclude articles whose Completeness/Structure/Clarity
        // scores fall below the configured thresholds. Skipped articles get a human-readable
        // reason stamped on their assessment row; eligible articles flow into Tier 2.
        // Backwards compat: an article missing one of the three gate dimensions (e.g. a
        // Duplication-only run) passes the gate — otherwise we'd accidentally exclude
        // every article on Duplication-only runs.
        KM_Pipeline_Config__mdt cfg = PipelineConfigService.getActiveConfig();
        Decimal minComp   = cfg.Min_Completeness_Score__c == null ? 60 : cfg.Min_Completeness_Score__c;
        Decimal minStruct = cfg.Min_Structure_Score__c    == null ? 60 : cfg.Min_Structure_Score__c;
        Decimal minClar   = cfg.Min_Clarity_Score__c      == null ? 60 : cfg.Min_Clarity_Score__c;
        Boolean gateOn    = (minComp > 0 || minStruct > 0 || minClar > 0);

        List<KB_Article_Assessment__c> assessments = [
            SELECT Id, Knowledge__c,
                   (SELECT Dimension__c, Score__c
                      FROM Dimension_Results__r
                     WHERE Dimension__c IN ('Completeness', 'Structure', 'Clarity'))
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :runId AND Knowledge__c != null
        ];

        List<Id> versionIds = new List<Id>();
        List<KB_Article_Assessment__c> toUpdate = new List<KB_Article_Assessment__c>();

        for (KB_Article_Assessment__c a : assessments) {
            Decimal cScore, sScore, lScore;
            for (KB_Dimension_Result__c dr : a.Dimension_Results__r) {
                if (dr.Dimension__c == 'Completeness') cScore = dr.Score__c;
                else if (dr.Dimension__c == 'Structure') sScore = dr.Score__c;
                else if (dr.Dimension__c == 'Clarity')   lScore = dr.Score__c;
            }

            String skipReason = null;
            if (gateOn) {
                if (cScore != null && minComp > 0 && cScore < minComp) {
                    skipReason = 'Completeness ' + cScore.intValue() + ' < threshold ' + minComp.intValue();
                } else if (sScore != null && minStruct > 0 && sScore < minStruct) {
                    skipReason = 'Structure ' + sScore.intValue() + ' < threshold ' + minStruct.intValue();
                } else if (lScore != null && minClar > 0 && lScore < minClar) {
                    skipReason = 'Clarity ' + lScore.intValue() + ' < threshold ' + minClar.intValue();
                }
            }

            if (skipReason != null) {
                toUpdate.add(new KB_Article_Assessment__c(
                    Id = a.Id,
                    Pipeline_Skip_Reason__c = skipReason
                ));
            } else {
                try { versionIds.add(Id.valueOf(a.Knowledge__c)); } catch (Exception e) {}
            }
        }

        if (!toUpdate.isEmpty()) {
            try {
                update toUpdate;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'KBAssessmentPipelineDispatcher: failed to write skip reasons for run '
                    + runId + ': ' + e.getMessage());
            }
        }

        if (versionIds.isEmpty()) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentPipelineDispatcher: no article ids for run ' + runId + ', falling back to callback');
            Id cbId = System.enqueueJob(new KBAssessmentPipelineCallback(runId));
            KBAssessmentService.recordAsyncJob(runId, cbId);
            return false;
        }

        // Flip the run status so the dashboard shows "Pipeline Running"
        try {
            update new KB_Assessment_Run__c(
                Id = runId,
                Status__c = 'Pipeline Running',
                Scoring_Duration_Ms__c = scoringDurationMs
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentPipelineDispatcher: failed to update run status to Pipeline Running for '
                + runId + ': ' + e.getMessage());
        }

        System.debug(LoggingLevel.INFO,
            'KBAssessmentPipelineDispatcher: enqueueing Tier2 for run ' + runId +
            ' with ' + versionIds.size() + ' articles, mode=' + executionMode);
        Id t2Id = System.enqueueJob(new Tier1VectorSearchQueueable(
            versionIds, runId, executionMode
        ));
        KBAssessmentService.recordAsyncJob(runId, t2Id);
        return true;
    }

    /**
     * Resolve the execution mode via the linked KB_Pipeline_Run__c. The
     * mode lives on the pipeline run record, not the assessment run.
     * Returns null when no pipeline run was created (i.e. caller did not
     * request Deduplication).
     */
    private static String resolveExecutionMode(Id pipelineRunId) {
        if (pipelineRunId == null) return null;
        try {
            KB_Pipeline_Run__c pr = [
                SELECT Execution_Modes__c FROM KB_Pipeline_Run__c
                WHERE Id = :pipelineRunId LIMIT 1
            ];
            return pr.Execution_Modes__c;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * True when the run wants the dedup pipeline AND at least one of
     * Duplication / Conflict is selected.
     */
    private static Boolean shouldRunPipeline(KB_Assessment_Run__c run, String executionMode) {
        if (run == null) return false;
        if (String.isBlank(executionMode)) return false;

        // Deduplication mode needs the pipeline only when at least one
        // pipeline-dependent dimension (Duplication / Conflict) is selected.
        if (!executionMode.contains(KBRuntimeConfigService.MODE_DEDUPLICATION)) {
            return false;
        }
        if (String.isBlank(run.Selected_Dimensions_JSON__c)) return true; // default all dims
        try {
            List<Object> dims = (List<Object>) JSON.deserializeUntyped(run.Selected_Dimensions_JSON__c);
            for (Object d : dims) {
                String s = String.valueOf(d);
                DimensionRegistry.DimensionDefinition def = DimensionRegistry.get(s);
                if (def != null && def.requiresPipelineData) return true;
            }
            return false;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentPipelineDispatcher: failed to parse Selected_Dimensions_JSON__c for run '
                + run.Id + ': ' + e.getMessage() + '. Defaulting to skip pipeline.');
            return false;
        }
    }
}
