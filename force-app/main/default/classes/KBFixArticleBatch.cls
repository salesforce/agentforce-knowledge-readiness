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
 * Batch Apex wrapper around `KBImprovementFixService.dispatchArticleFixInternal`
 * for the bulk-fix path with > 500 requests.
 *
 * Per-request exceptions are caught inside the loop because
 * `dispatchArticleFixInternal` already marks recommendation rows as Error on
 * its own catch path — the catch keeps one bad request from poisoning the
 * rest of the scope. The cause is logged via `System.debug(LoggingLevel.ERROR, …)`
 * so failures surface in debug logs (the previous swallow lost every
 * breadcrumb).
 *
 * AR2: tracks errorCount across all `execute` invocations, publishes a
 * `KB_Assessment_Progress__e` event from `finish`, and closes out the
 * `KB_Pipeline_Run__c` row that `dispatchArticleFixesBulkInternal` opened.
 */
public with sharing class KBFixArticleBatch implements Database.Batchable<KBImprovementFixService.BulkFixRequest>,
                                                       Database.AllowsCallouts,
                                                       Database.Stateful {

    private final List<KBImprovementFixService.BulkFixRequest> requests;

    private Integer processedArticles = 0;
    private Integer errorCount        = 0;

    public KBFixArticleBatch(List<KBImprovementFixService.BulkFixRequest> requests) {
        this.requests = requests;
    }

    public Iterable<KBImprovementFixService.BulkFixRequest> start(Database.BatchableContext ctx) {
        return requests;
    }

    public void execute(Database.BatchableContext ctx,
                        List<KBImprovementFixService.BulkFixRequest> scope) {
        Id pipelineRunId = scope.isEmpty() ? null : scope[0].pipelineRunId;

        for (KBImprovementFixService.BulkFixRequest req : scope) {
            try {
                KBImprovementFixService.dispatchArticleFixInternal(
                    req.articleVersionId,
                    req.useCurrentOnline,
                    req.recIds,
                    req.issueDescriptions,
                    req.pipelineRunId
                );
            } catch (Exception e) {
                // Service.dispatchArticleFixInternal has already flipped recs to Error.
                // Log the cause so it's debuggable — silently swallowing here loses
                // every debug breadcrumb. Match the convention from
                // KBAssessmentDimensionQueueable.execute (Finding 5).
                System.debug(LoggingLevel.ERROR,
                    'AI Fix batch dispatch failed: ' + e.getMessage()
                    + '\n' + e.getStackTraceString());
                errorCount++;
            }
            processedArticles++;
        }

        // AR2: per-chunk progress event so the LWC sees mid-flight movement.
        KBImprovementFixService.publishFixProgress(
            pipelineRunId,
            processedArticles,
            requests.size(),
            errorCount,
            processedArticles < requests.size() ? 'In Progress' : (errorCount > 0 ? 'Partial' : 'Completed'),
            'Processed ' + processedArticles + ' of ' + requests.size() + ' articles'
        );
    }

    public void finish(Database.BatchableContext ctx) {
        Id pipelineRunId = requests.isEmpty() ? null : requests[0].pipelineRunId;

        KBImprovementFixService.publishFixProgress(
            pipelineRunId,
            processedArticles,
            requests.size(),
            errorCount,
            errorCount > 0 ? 'Partial' : 'Completed',
            'AI Fix batch complete (' + processedArticles + ' processed, ' + errorCount + ' errors)'
        );
        KBImprovementFixService.completeAIFixPipelineRun(pipelineRunId, errorCount);
    }
}
