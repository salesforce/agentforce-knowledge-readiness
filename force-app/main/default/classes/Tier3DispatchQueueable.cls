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
 * Tier 4 parallel dispatcher (C). Runs in its own fresh async transaction
 * (enqueued by Tier 3's handoff finalizer) so it is allowed to launch MULTIPLE
 * batch jobs — the "1 enqueueJob per async transaction" rule applies to
 * System.enqueueJob, not Database.executeBatch, which has its own 5-concurrent +
 * 100-queued flex-queue limit (verified empirically).
 *
 * Splits the finalist pairs into up to MAX_SHARDS shards and launches one
 * Tier3AgenticBatch per shard. Up to 5 run concurrently → ~5x the throughput of
 * the legacy single-lane Tier3AgenticQueueable chain. Seeds the join barrier
 * (Tier4_Lanes_Outstanding__c = shard count) BEFORE launching so no shard's
 * finish() can race to 0 against an unset barrier.
 *
 * Falls back to the legacy single-queueable path when there are too few pairs to
 * be worth sharding (overhead of 5 batch jobs isn't justified).
 */
public with sharing class Tier3DispatchQueueable implements Queueable {

    // Platform cap on concurrently-running batch jobs.
    private static final Integer MAX_SHARDS = 5;
    // Below this many pairs, just run the legacy single-lane queueable.
    @TestVisible
    private static Integer minPairsToShard = 6;
    // Pairs per batch chunk. Kept small so one chunk's wall-clock (each pair's
    // fact-extraction LLM calls run serially) stays reasonable and a lane's
    // progress heartbeat + cancellation check (both only fire between chunks,
    // not between pairs within a chunk) aren't held up too long by one scope.
    @TestVisible
    private static Integer batchScopeSize = 4;

    // Bookkeeping so tests can assert the sharding decision independently of
    // whether the launch itself ran.
    @TestVisible
    private static Integer lastPlannedShardCount = null;
    @TestVisible
    private static Boolean lastUsedLegacyFallback = null;

    /**
     * Test seam for the three actual async-launch calls. In test context the
     * platform forbids launching the batch/queueable fan-out from inside a
     * currently-running queueable or finalizer ("Maximum stack depth") — this
     * indirection lets tests substitute a recording stub that never touches
     * the real platform APIs, so the launch DECISIONS (which shard, how many,
     * what happens on partial/total failure) are verifiable without hitting
     * that restriction. Production always uses RealAsyncLauncher.
     */
    public interface IAsyncLauncher {
        Id enqueueTier3Agentic(Tier3AgenticQueueable job);
        Id launchBatch(Tier3AgenticBatch batch, Integer scopeSize);
        Id enqueuePipelineCallback(KBAssessmentPipelineCallback callback);
    }

    @TestVisible
    private class RealAsyncLauncher implements IAsyncLauncher {
        public Id enqueueTier3Agentic(Tier3AgenticQueueable job) {
            return System.enqueueJob(job);
        }
        public Id launchBatch(Tier3AgenticBatch batch, Integer scopeSize) {
            return Database.executeBatch(batch, scopeSize);
        }
        public Id enqueuePipelineCallback(KBAssessmentPipelineCallback callback) {
            return System.enqueueJob(callback);
        }
    }

    @TestVisible
    private static IAsyncLauncher launcher = new RealAsyncLauncher();

    private List<Tier3AgenticQueueable.FinalistPair> finalistPairs;
    private Id assessmentRunId;
    private String executionMode;

    public Tier3DispatchQueueable(
        List<Tier3AgenticQueueable.FinalistPair> finalistPairs,
        Id assessmentRunId,
        String executionMode
    ) {
        this.finalistPairs = finalistPairs;
        this.assessmentRunId = assessmentRunId;
        this.executionMode = executionMode;
    }

    public void execute(QueueableContext ctx) {
        if (assessmentRunId != null && KBAssessmentService.isCancelled(assessmentRunId)) {
            return;
        }

        List<Tier3AgenticQueueable.FinalistPair> pairs = finalistPairs != null
            ? finalistPairs : new List<Tier3AgenticQueueable.FinalistPair>();

        // Too few pairs to bother sharding — legacy single-lane path.
        if (pairs.size() < minPairsToShard) {
            lastUsedLegacyFallback = true;
            lastPlannedShardCount = 0;
            Id qid = launcher.enqueueTier3Agentic(new Tier3AgenticQueueable(
                pairs, assessmentRunId, executionMode));
            if (assessmentRunId != null) {
                KBAssessmentService.recordAsyncJob(assessmentRunId, qid);
            }
            return;
        }
        lastUsedLegacyFallback = false;

        Id pipelineRunId = resolvePipelineRunId();

        // Partition into round-robin shards so each gets a similar pair count.
        Integer shardCount = Math.min(MAX_SHARDS, pairs.size());
        List<List<Tier3AgenticQueueable.FinalistPair>> shards =
            new List<List<Tier3AgenticQueueable.FinalistPair>>();
        for (Integer i = 0; i < shardCount; i++) {
            shards.add(new List<Tier3AgenticQueueable.FinalistPair>());
        }
        for (Integer i = 0; i < pairs.size(); i++) {
            shards[Math.mod(i, shardCount)].add(pairs[i]);
        }

        lastPlannedShardCount = shardCount;

        // Seed the join barrier BEFORE launching any shard.
        if (assessmentRunId != null) {
            try {
                update new KB_Assessment_Run__c(
                    Id = assessmentRunId,
                    Tier4_Lanes_Outstanding__c = shardCount
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Tier3DispatchQueueable: failed to seed join barrier: ' + e.getMessage());
            }
        }

        Integer launched = 0;
        for (List<Tier3AgenticQueueable.FinalistPair> shard : shards) {
            try {
                Id batchId = launcher.launchBatch(
                    new Tier3AgenticBatch(shard, assessmentRunId, pipelineRunId, shardCount),
                    batchScopeSize
                );
                if (assessmentRunId != null && batchId != null) {
                    KBAssessmentService.recordAsyncJob(assessmentRunId, batchId);
                }
                launched++;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Tier3DispatchQueueable: executeBatch failed for a shard: ' + e.getMessage());
            }
        }

        System.debug(LoggingLevel.INFO,
            'Tier3DispatchQueueable: launched ' + launched + '/' + shardCount
            + ' shards for ' + pairs.size() + ' pairs, run ' + assessmentRunId);

        // If we failed to launch ANY shard, don't leave the run hung — finalize.
        if (launched == 0 && assessmentRunId != null) {
            Id cbId = launcher.enqueuePipelineCallback(new KBAssessmentPipelineCallback(assessmentRunId));
            KBAssessmentService.recordAsyncJob(assessmentRunId, cbId);
        } else if (launched < shardCount && assessmentRunId != null) {
            // Some shards failed to launch — correct the barrier so the shards
            // that DID launch can still drive it to 0 and finalize.
            try {
                KB_Assessment_Run__c run = [
                    SELECT Id, Tier4_Lanes_Outstanding__c FROM KB_Assessment_Run__c
                    WHERE Id = :assessmentRunId FOR UPDATE
                ];
                run.Tier4_Lanes_Outstanding__c = launched;
                update run;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Tier3DispatchQueueable: barrier correction failed: ' + e.getMessage());
            }
        }
    }

    private Id resolvePipelineRunId() {
        if (assessmentRunId == null) return null;
        try {
            return [
                SELECT Pipeline_Run__c FROM KB_Assessment_Run__c
                WHERE Id = :assessmentRunId LIMIT 1
            ].Pipeline_Run__c;
        } catch (Exception e) {
            return null;
        }
    }
}
