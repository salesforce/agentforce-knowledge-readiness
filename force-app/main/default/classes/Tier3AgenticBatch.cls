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
 * Tier 4 (parallel path, C). Evaluates a SHARD of finalist pairs as Batch Apex
 * so up to 5 shards run concurrently org-wide — the dedup "finals" stage was
 * previously a single self-chaining queueable processing pairs link-by-link.
 *
 * Why Batch over Queueable here:
 *   - The framework re-invokes execute() for the next scope automatically, so
 *     we don't need the queueable's budget-reservation/continuation machinery
 *     (this class doesn't pace against Limits.getCallouts() — the Einstein LLM
 *     call Tier3PairEvaluator makes isn't actually a tracked Apex callout,
 *     verified empirically; there is no 100-callout governor to stay under
 *     here).
 *   - Multiple distinct batch jobs run concurrently (Tier3DispatchQueueable
 *     launches one per shard), giving real parallelism the async-chain
 *     "1 enqueueJob per transaction" rule otherwise forbids.
 *
 * Typed Batchable over FinalistPair (Iterable<FinalistPair>) — no SObject
 * placeholder hack. Scope size is the per-chunk pair count (Tier3DispatchQueueable.
 * batchScopeSize), kept small so one chunk's wall-clock stays reasonable and
 * the progress heartbeat + cancellation check (both only fire between chunks)
 * aren't held up too long by one scope. Per-pair compute lives in
 * Tier3PairEvaluator (shared with the legacy queueable).
 *
 * Join barrier: KB_Assessment_Run__c.Tier4_Lanes_Outstanding__c is seeded by the
 * dispatcher with the shard count. Each shard's finish() decrements it under
 * FOR UPDATE; the shard that hits 0 is last-done and enqueues the callback.
 */
public with sharing class Tier3AgenticBatch implements Database.Batchable<Tier3AgenticQueueable.FinalistPair>, Database.AllowsCallouts, Database.Stateful {

    private List<Tier3AgenticQueueable.FinalistPair> shardPairs;
    private Id assessmentRunId;
    private Id pipelineRunId;
    // Total lanes launched for this run — lets each lane publish a run-level
    // "lanes done / total" progress event so the dedup 80→100% band advances
 // (follow-up: the parallel path previously published only a
    // countless keep-alive, so the bar froze at the 80% pipeline floor).
    private Integer totalLanes;

    // Stateful tallies for the finish() summary log.
    private Integer totalEvaluated = 0;
    private Integer totalFlagged = 0;
    private Integer totalErrored = 0;

    // Legacy 3-arg constructor (single-lane / tests): one lane of one.
    public Tier3AgenticBatch(
        List<Tier3AgenticQueueable.FinalistPair> shardPairs,
        Id assessmentRunId,
        Id pipelineRunId
    ) {
        this(shardPairs, assessmentRunId, pipelineRunId, 1);
    }

    public Tier3AgenticBatch(
        List<Tier3AgenticQueueable.FinalistPair> shardPairs,
        Id assessmentRunId,
        Id pipelineRunId,
        Integer totalLanes
    ) {
        this.shardPairs = shardPairs;
        this.assessmentRunId = assessmentRunId;
        this.pipelineRunId = pipelineRunId;
        this.totalLanes = (totalLanes != null && totalLanes > 0) ? totalLanes : 1;
    }

    public Iterable<Tier3AgenticQueueable.FinalistPair> start(Database.BatchableContext bc) {
        return shardPairs != null ? shardPairs : new List<Tier3AgenticQueueable.FinalistPair>();
    }

    public void execute(Database.BatchableContext bc, List<Tier3AgenticQueueable.FinalistPair> scope) {
 // Cancel gate.
        if (assessmentRunId != null && KBAssessmentService.isCancelled(assessmentRunId)) {
            return;
        }
        if (scope == null || scope.isEmpty()) return;

        Tier3PairEvaluator.Result r =
            Tier3PairEvaluator.evaluatePairs(scope, assessmentRunId, pipelineRunId);

        totalEvaluated += r.evaluatedPairs;
        totalFlagged += r.flaggedPairs;
        totalErrored += r.erroredPairs;

        if (!r.flaggedCandidates.isEmpty()) {
            // Candidates are master-detail to the assessment run (always non-null
            // on the pipeline path) and visibility is controlled-by-parent, so no
            // explicit sharing call is needed.
 // run-scoped reuse drops human-triaged rows, so upsert
            // ONLY the returned subset (not the full flaggedCandidates list).
            List<Duplicate_Candidate__c> toUpsert =
                Tier3PairEvaluator.attachExistingIdsForRunScopedUpsert(
                    r.flaggedCandidates, assessmentRunId);
            if (!toUpsert.isEmpty()) {
                upsert toUpsert;
            }
        }
        if (!r.evaluations.isEmpty()) {
            upsert r.evaluations Composite_Version_Key__c;
        }

        publishHeartbeat();
    }

    // Lanes completed so far this run, derived from the barrier at claim time
    // (totalLanes − outstanding). -1 = not yet computed / barrier read failed.
    private Integer lanesDoneSnapshot = -1;

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO,
            'Tier3AgenticBatch shard finished: evaluated=' + totalEvaluated
            + ', flagged=' + totalFlagged + ', errored=' + totalErrored
            + ', run=' + assessmentRunId);

        if (assessmentRunId == null) return;
        signalShardComplete();
        // Publish a COUNTED progress event so the dedup 80→100% band advances by
        // one lane. The LWC maps Current_Batch__c/Total_Batches__c → pairs
        // done/total in its Pipeline-Running branch and latches monotonically,
 // so out-of-order lane completion never regresses the bar.
        publishLaneProgress();
    }

    /**
     * Decrement the join barrier under FOR UPDATE. The shard that takes it to 0
     * is the last one done and hands off to the pipeline callback. A cancelled
     * run short-circuits without firing the callback.
     */
    private void signalShardComplete() {
        if (KBAssessmentService.isCancelled(assessmentRunId)) return;

        Boolean isLast = false;
        try {
            isLast = claimIfLastLane();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Tier3AgenticBatch.signalShardComplete failed: ' + e.getMessage());
            // Do NOT blind-finalize (that double-fires the callback, which
            // re-runs severity annotation at LLM cost). Re-attempt the claim in
            // a fresh transaction; finalize only if this lane wins the claim.
            try {
                isLast = claimIfLastLane();
            } catch (Exception e2) {
                System.debug(LoggingLevel.ERROR,
                    'Tier3AgenticBatch.signalShardComplete re-claim failed: ' + e2.getMessage());
                isLast = false;
            }
        }

        if (isLast) {
            Id cbId = System.enqueueJob(new KBAssessmentPipelineCallback(assessmentRunId));
            KBAssessmentService.recordAsyncJob(assessmentRunId, cbId);
        }
    }

    // Sentinel parked in the lane barrier once a lane has CLAIMED the callback,
    // so a concurrent/late lane (or a catch-arm recovery) that reads a negative
    // value knows the callback was already enqueued and bails.
    @TestVisible
    private static final Integer BARRIER_CLAIMED = -1;

    /**
     * Atomic decrement-and-claim of the Tier 4 lane barrier under FOR UPDATE.
     * Returns true only if this transaction drives the barrier to 0 and it had
     * not already been claimed — guaranteeing at-most-once callback dispatch.
     */
    private Boolean claimIfLastLane() {
        KB_Assessment_Run__c run = [
            SELECT Id, Tier4_Lanes_Outstanding__c
            FROM KB_Assessment_Run__c
            WHERE Id = :assessmentRunId
            FOR UPDATE
        ];
        Decimal outstanding = run.Tier4_Lanes_Outstanding__c != null
            ? run.Tier4_Lanes_Outstanding__c : 0;
        if (outstanding < 0) {
            // Already claimed — all lanes are effectively done for progress.
            lanesDoneSnapshot = totalLanes;
            return false;
        }
        outstanding = outstanding - 1;
        Boolean claim = (outstanding <= 0);
        // Lanes finished so far = launched total minus those still outstanding.
        // On claim the barrier is parked at the sentinel, so remaining is 0.
        lanesDoneSnapshot = claim ? totalLanes : (totalLanes - (Integer) outstanding);
        run.Tier4_Lanes_Outstanding__c = claim ? BARRIER_CLAIMED : outstanding;
        update run;
        return claim;
    }

    /**
     * Publish a counted dedup-progress event (lanes done / total lanes). The
     * runner LWC's Pipeline-Running branch reads Current_Batch__c as pairs-done
     * and Total_Batches__c as pairs-total, driving the 80→100% band; its
     * monotonic latch means an out-of-order or redelivered lane event can only
     * hold or advance the bar, never regress it.
     */
    private void publishLaneProgress() {
        if (assessmentRunId == null) return;
        Integer done = lanesDoneSnapshot >= 0 ? lanesDoneSnapshot : 0;
        Integer total = (totalLanes != null && totalLanes > 0) ? totalLanes : 1;
        if (done > total) done = total;
        try {
            EventBus.publish(new KB_Assessment_Progress__e(
                Assessment_Id__c = assessmentRunId,
                Status__c = 'Pipeline Running',
                Current_Batch__c = done,
                Total_Batches__c = total,
                Message__c = 'Checking for duplicates and conflicts…'
            ));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Tier3AgenticBatch.publishLaneProgress failed: ' + e.getMessage());
        }
    }

    /**
     * Coarse pipeline-phase heartbeat. Per-shard remaining counts are opaque to
     * other shards, so we publish a keep-alive keyed on the run; the LWC's
     * monotonic latch holds the bar at the 80% pipeline floor without regressing
     * across concurrent shards.
     */
    private void publishHeartbeat() {
        if (assessmentRunId == null) return;
        try {
            EventBus.publish(new KB_Assessment_Progress__e(
                Assessment_Id__c = assessmentRunId,
                Status__c = 'Pipeline Running',
                Message__c = 'Checking for duplicates and conflicts…'
            ));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Tier3AgenticBatch.publishHeartbeat failed: ' + e.getMessage());
        }
    }
}
