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
 * Severity-annotation fan-out queueable.
 *
 * Extracted from KBAssessmentPipelineCallback to keep the callback's per-execute
 * callout count under the platform limit. Previously the callback called
 * PromptTemplateService.annotateIssueSeverity once per (article, dimension)
 * synchronously inside its execute() loop — with Duplication + Conflict on a
 * 50-article run that's up to 100 callouts in a single transaction (the
 * 100-callout governor ceiling). For fully-loaded 50-article runs we'd be
 * one rate-limited template-fetch from blowing the limit.
 *
 * The callback now inserts KB_Dimension_Analysis__c rows with the Impact__c
 * severity field left null, packages the annotation work into AnnotationTask
 * payloads keyed back to the inserted analysis row Ids, and enqueues this
 * queueable. The queueable processes tasks in chunks (CHUNK_SIZE work units =
 * annotation calls), self-chains for any remainder, and post-hoc UPDATEs the
 * analysis rows by Id once the LLM responds.
 *
 * Severity is Impact-only on this path: Effort/Priority were retired
 * the Duplication/Conflict findings carry a single Impact badge.
 *
 * Idempotency: the callback's task-build phase skips analysis rows that already
 * have Impact__c populated. Re-enqueuing this job for the same task list
 * overwrites Impact__c with a freshly-LLM'd value rather than stacking
 * duplicates — the underlying SObject UPDATE on a fixed Id is inherently
 * idempotent, so a duplicate job is benign.
 *
 * Marker interface Database.AllowsCallouts mirrors KBAssessmentPipelineCallback
 * (LLM template invocation requires a callout-allowing async context).
 */
public with sharing class KBSeverityAnnotationQueueable implements Queueable, Database.AllowsCallouts {

    /**
     * Conservative chunk size — each task is one annotateIssueSeverity callout.
     * Salesforce caps 100 callouts/transaction; we leave headroom (~20%) for
     * any incidental ConnectApi work + the SOQL the queueable performs at chunk
     * end. Keeping chunks small also keeps CPU + memory bounded per execute.
     */
    @TestVisible
    private static Integer CHUNK_SIZE = 80;

    private final List<AnnotationTask> tasks;
    private final Integer startIndex;

    public KBSeverityAnnotationQueueable(List<AnnotationTask> tasks) {
        this(tasks, 0);
    }

    public KBSeverityAnnotationQueueable(List<AnnotationTask> tasks, Integer startIndex) {
        this.tasks = tasks != null ? tasks : new List<AnnotationTask>();
        this.startIndex = startIndex != null && startIndex > 0 ? startIndex : 0;
    }

    public void execute(QueueableContext ctx) {
        if (this.tasks == null || this.tasks.isEmpty() || this.startIndex >= this.tasks.size()) {
            return;
        }

        Integer endIdx = Math.min(this.startIndex + CHUNK_SIZE, this.tasks.size());
        PromptTemplateService pts = PromptTemplateService.getInstance();

        // Collect every analysis row we plan to update across this chunk.
        // Keyed by Id so any duplicate references (e.g., the same row appearing
        // in multiple tasks because the LLM returned multiple annotations for
        // the same issue index across re-runs) collapse to a single UPDATE.
        Map<Id, KB_Dimension_Analysis__c> updatesById = new Map<Id, KB_Dimension_Analysis__c>();

        for (Integer i = this.startIndex; i < endIdx; i++) {
            AnnotationTask task = this.tasks.get(i);
            if (task == null || task.analysisRowIds == null || task.analysisRowIds.isEmpty()) continue;
            if (task.issueTexts == null || task.issueTexts.isEmpty()) continue;

            try {
                List<PromptTemplateService.IssueSeverityAnnotation> annotations =
                    pts.annotateIssueSeverity(
                        task.selfTitle,
                        task.selfSummary,
                        task.selfBody,
                        task.counterpartTitle,
                        task.counterpartSummary,
                        task.counterpartBody,
                        task.issueTexts,
                        task.strengths
                    );
                if (annotations == null) continue;

                for (PromptTemplateService.IssueSeverityAnnotation ann : annotations) {
                    if (ann == null || ann.index == null) continue;
                    if (ann.index < 0 || ann.index >= task.analysisRowIds.size()) continue;
                    Id rowId = task.analysisRowIds.get(ann.index);
                    if (rowId == null) continue;

                    KB_Dimension_Analysis__c row = updatesById.containsKey(rowId)
                        ? updatesById.get(rowId)
                        : new KB_Dimension_Analysis__c(Id = rowId);
 // Impact-only severity. Effort/Priority are no longer
                    // written on the pipeline (Duplication/Conflict) path — the
                    // Improvements Inbox renders a single Impact badge.
                    row.Impact__c = ann.impact;
                    updatesById.put(rowId, row);
                }
            } catch (Exception e) {
                // Non-fatal: leave severity null for this task so the LWC
                // renders the analysis without severity hints rather than
                // failing the whole chunk. Mirrors the original sync behaviour.
                System.debug(LoggingLevel.WARN,
                    'KBSeverityAnnotationQueueable: annotate failed for task '
                    + task.dimension + '/' + task.articleId + ' (non-fatal): '
                    + e.getMessage());
            }
        }

        if (!updatesById.isEmpty()) {
            // Best-effort partial DML: a single bad row shouldn't drop the
            // whole batch on the floor. Future chunks still run via self-chain.
            Database.update(updatesById.values(), false);
        }

        // Self-chain for the next slice. Mirrors the KBFixArticleQueueable
        // pattern. Avoids re-engineering this as a Batch — task counts are
        // bounded by article count × dimension count, which our governor-
        // friendly Batch path already guards higher in the stack.
        //
        // In test context Salesforce caps queueable chain depth at 1, so we
        // only chain once when running under Test (the chained job runs
        // inside Test.stopTest()). Tests that need to verify the full chain
        // either keep task count <= CHUNK_SIZE (fits in one execute) or
        // override CHUNK_SIZE upward.
        if (endIdx < this.tasks.size()) {
            System.enqueueJob(new KBSeverityAnnotationQueueable(this.tasks, endIdx));
        }
    }

    /**
     * One unit of severity-annotation work. Each task corresponds to a single
     * (article, dimension) tuple from KBAssessmentPipelineCallback. The
     * analysisRowIds list is index-aligned with issueTexts: the i-th issue
     * text corresponds to the i-th KB_Dimension_Analysis__c row id, so the
     * LLM annotation at index i lands on row analysisRowIds[i].
     *
     * Field names use the same shape as PromptTemplateService.annotateIssueSeverity
     * to make the call-site below straightforward to read.
     */
    public class AnnotationTask {
        public Id articleId;
        public String dimension; // 'Duplication' or 'Conflict'
        public String selfTitle;
        public String selfSummary;
        public String selfBody;
        public String counterpartTitle;
        public String counterpartSummary;
        public String counterpartBody;
        public List<String> issueTexts;
        public List<String> strengths;
        public List<Id> analysisRowIds;

        public AnnotationTask() {
            this.issueTexts = new List<String>();
            this.strengths = new List<String>();
            this.analysisRowIds = new List<Id>();
        }
    }
}
