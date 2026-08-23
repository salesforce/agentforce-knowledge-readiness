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
 * Async wrapper around `KBImprovementFixService.dispatchArticleFixInternal`
 * for the bulk-fix path with ≤ 500 requests. Self-chains in `CHUNK`-size
 * windows so the per-execute callout/CPU budget stays bounded.
 *
 * Per-request exceptions are caught inside the loop because
 * `dispatchArticleFixInternal` already marks recommendation rows as Error on
 * its own catch path — the catch keeps one bad request from poisoning the
 * rest of the chunk. The cause is logged via `System.debug(LoggingLevel.ERROR, …)`
 * so failures surface in debug logs (the previous swallow lost every
 * breadcrumb).
 *
 * AR2: when `requests[i].pipelineRunId` is non-null (set at dispatch time
 * by `KBImprovementFixService.dispatchArticleFixesBulkInternal`), we publish
 * a `KB_Assessment_Progress__e` event after each chunk and a final
 * Completed/Partial event on the terminal chunk.
 */
public with sharing class KBFixArticleQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer CHUNK = 10;

    /**
     * Test seam: when set to true, the chain-enqueue at the end of `execute`
     * is suppressed so unit tests can verify the branch was hit without
     * tripping Salesforce's "Maximum stack depth" guard inside
     * `Test.startTest()..stopTest()`. The counter records how many times
     * the chain branch was reached.
     */
    @TestVisible
    private static Boolean suppressChainForTest = false;
    @TestVisible
    private static Integer chainAttemptCount = 0;

    private final List<KBImprovementFixService.BulkFixRequest> requests;
    private final Integer startIndex;
    private final Integer cumulativeErrors;

    public KBFixArticleQueueable(
        List<KBImprovementFixService.BulkFixRequest> requests,
        Integer startIndex
    ) {
        this(requests, startIndex, 0);
    }

    public KBFixArticleQueueable(
        List<KBImprovementFixService.BulkFixRequest> requests,
        Integer startIndex,
        Integer cumulativeErrors
    ) {
        this.requests         = requests;
        this.startIndex       = startIndex;
        this.cumulativeErrors = cumulativeErrors == null ? 0 : cumulativeErrors;
    }

    public void execute(QueueableContext ctx) {
        Integer endIdx = Math.min(startIndex + CHUNK, requests.size());
        Integer chunkErrors = 0;
        Id pipelineRunId = requests.isEmpty() ? null : requests[0].pipelineRunId;

        for (Integer i = startIndex; i < endIdx; i++) {
            KBImprovementFixService.BulkFixRequest req = requests[i];
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
                // Log the cause so it's debuggable — Aura would have stripped this if
                // we hit the facade path, and silently swallowing here loses every
                // debug breadcrumb. Match the convention from
                // KBAssessmentDimensionQueueable.execute (Finding 5).
                System.debug(LoggingLevel.ERROR,
                    'AI Fix dispatch failed: ' + e.getMessage()
                    + '\n' + e.getStackTraceString());
                chunkErrors++;
            }
        }

        Integer runningErrors = cumulativeErrors + chunkErrors;

        // AR2: per-chunk progress event so the LWC can update its progress bar
        // mid-flight rather than waiting for the terminal chunk.
        KBImprovementFixService.publishFixProgress(
            pipelineRunId,
            endIdx,
            requests.size(),
            runningErrors,
            endIdx < requests.size() ? 'In Progress' : (runningErrors > 0 ? 'Partial' : 'Completed'),
            'Processed ' + endIdx + ' of ' + requests.size() + ' articles'
        );

        if (endIdx < requests.size()) {
            chainAttemptCount++;
            if (!suppressChainForTest) {
                System.enqueueJob(new KBFixArticleQueueable(requests, endIdx, runningErrors));
            }
        } else {
            // Terminal chunk — close out the pipeline run row.
            KBImprovementFixService.completeAIFixPipelineRun(pipelineRunId, runningErrors);
        }
    }
}
