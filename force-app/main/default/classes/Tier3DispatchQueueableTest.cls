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
 * Coverage for Tier3DispatchQueueable — the parallel Tier 4 dispatcher.
 *
 * The actual platform async calls (System.enqueueJob / Database.executeBatch)
 * are routed through the injectable IAsyncLauncher seam, so these tests
 * substitute a RecordingLauncher instead of trying to run the real calls —
 * the platform forbids launching a batch/queueable fan-out from inside a
 * currently-running queueable or finalizer in test context regardless of how
 * the seam is exercised, so a mock sidesteps that restriction entirely rather
 * than working around it.
 */
@IsTest
private class Tier3DispatchQueueableTest {

    private class RecordingLauncher implements Tier3DispatchQueueable.IAsyncLauncher {
        Integer enqueueCalls = 0;
        Integer batchCalls = 0;
        Integer callbackCalls = 0;
        Boolean enqueueThrows = false;
        Set<Integer> batchCallsThatThrow = new Set<Integer>();

        public Id enqueueTier3Agentic(Tier3AgenticQueueable job) {
            enqueueCalls++;
            if (enqueueThrows) throw new TestException('Simulated enqueue failure');
            return Id.valueOf('707000000000001');
        }
        public Id launchBatch(Tier3AgenticBatch batch, Integer scopeSize) {
            Integer thisCall = batchCalls;
            batchCalls++;
            if (batchCallsThatThrow.contains(thisCall)) {
                throw new TestException('Simulated executeBatch failure for shard ' + thisCall);
            }
            return Id.valueOf('707000000000002');
        }
        public Id enqueuePipelineCallback(KBAssessmentPipelineCallback callback) {
            callbackCalls++;
            return Id.valueOf('707000000000003');
        }
    }

    private class TestException extends Exception {}

    private static List<Tier3AgenticQueueable.FinalistPair> buildPairs(Integer count, Id sampleArticleId) {
        List<Tier3AgenticQueueable.FinalistPair> pairs = new List<Tier3AgenticQueueable.FinalistPair>();
        for (Integer i = 0; i < count; i++) {
            pairs.add(new Tier3AgenticQueueable.FinalistPair(sampleArticleId, sampleArticleId));
        }
        return pairs;
    }

    @IsTest
    static void testExecute_RunCancelled_ShortCircuits() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Cancelled', 'Readiness');
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'tier4-dispatch-cancel')[0];

        Tier3DispatchQueueable.lastPlannedShardCount = null;
        Tier3DispatchQueueable.lastUsedLegacyFallback = null;

        Tier3DispatchQueueable job = new Tier3DispatchQueueable(
            buildPairs(6, art.Id), run.Id, 'DEDUPLICATION'
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.isNull(Tier3DispatchQueueable.lastUsedLegacyFallback,
            'A cancelled run must return before any sharding decision is recorded');
    }

    @IsTest
    static void testExecute_TooFewPairs_UsesLegacyFallback() {
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'tier4-dispatch-legacy')[0];

        Tier3DispatchQueueable.lastPlannedShardCount = null;
        Tier3DispatchQueueable.lastUsedLegacyFallback = null;
        RecordingLauncher launcher = new RecordingLauncher();
        Tier3DispatchQueueable.launcher = launcher;

        Tier3DispatchQueueable job = new Tier3DispatchQueueable(
            buildPairs(Tier3DispatchQueueable.minPairsToShard - 1, art.Id), null, 'DEDUPLICATION'
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.isTrue(Tier3DispatchQueueable.lastUsedLegacyFallback,
            'Below the sharding threshold, the legacy single-lane fallback must be chosen');
        Assert.areEqual(0, Tier3DispatchQueueable.lastPlannedShardCount,
            'Legacy fallback records a zero planned shard count');
        Assert.areEqual(1, launcher.enqueueCalls,
            'The legacy path launches exactly one Tier3AgenticQueueable via the launcher');
    }

    @IsTest
    static void testExecute_LegacyFallback_RecordsAsyncJobOnRun() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'tier4-dispatch-legacy-record')[0];

        Tier3DispatchQueueable.lastPlannedShardCount = null;
        Tier3DispatchQueueable.lastUsedLegacyFallback = null;
        Tier3DispatchQueueable.launcher = new RecordingLauncher();

        Tier3DispatchQueueable job = new Tier3DispatchQueueable(
            buildPairs(Tier3DispatchQueueable.minPairsToShard - 1, art.Id), run.Id, 'DEDUPLICATION'
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        KB_Assessment_Run__c reloaded = [SELECT Async_Job_Ids__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.isTrue(String.isNotBlank(reloaded.Async_Job_Ids__c),
            'The launcher-returned job id must be recorded on the run');
    }

    @IsTest
    static void testExecute_EnoughPairs_SeedsBarrierAndHandlesUnresolvableRun() {
        // A well-formed but nonexistent KB_Assessment_Run__c id (same key
        // prefix as a real run) forces both resolvePipelineRunId()'s SOQL
        // and the barrier-seed update to fail — exercising their catch
        // blocks — while still reaching the sharding decision itself.
        KB_Assessment_Run__c realRun = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        String prefix = String.valueOf(realRun.Id).substring(0, 3);
        Id bogusRunId = Id.valueOf(prefix + '000000000001');
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'tier4-dispatch-shard')[0];

        Tier3DispatchQueueable.lastPlannedShardCount = null;
        Tier3DispatchQueueable.lastUsedLegacyFallback = null;
        Tier3DispatchQueueable.launcher = new RecordingLauncher();

        Tier3DispatchQueueable job = new Tier3DispatchQueueable(
            buildPairs(Tier3DispatchQueueable.minPairsToShard, art.Id), bogusRunId, 'DEDUPLICATION'
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.isFalse(Tier3DispatchQueueable.lastUsedLegacyFallback,
            'At/above the sharding threshold, the parallel dispatch path must be chosen');
        Assert.isNotNull(Tier3DispatchQueueable.lastPlannedShardCount,
            'A shard count must be recorded once the sharding path is taken');
    }

    @IsTest
    static void testExecute_ShardingPath_AllShardsLaunch_NoCallbackEnqueued() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'tier4-dispatch-allok')[0];

        Tier3DispatchQueueable.lastPlannedShardCount = null;
        Tier3DispatchQueueable.lastUsedLegacyFallback = null;
        RecordingLauncher launcher = new RecordingLauncher();
        Tier3DispatchQueueable.launcher = launcher;

        Tier3DispatchQueueable job = new Tier3DispatchQueueable(
            buildPairs(8, art.Id), run.Id, 'DEDUPLICATION'
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(5, launcher.batchCalls, 'MAX_SHARDS=5 batches launched for 8 pairs');
        Assert.areEqual(0, launcher.callbackCalls, 'All shards launched — no fallback finalize needed');

        KB_Assessment_Run__c reloaded = [
            SELECT Tier4_Lanes_Outstanding__c, Async_Job_Ids__c FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual(5, reloaded.Tier4_Lanes_Outstanding__c, 'Barrier stays at the full shard count');
        Assert.isTrue(String.isNotBlank(reloaded.Async_Job_Ids__c),
            'Each launched batch id is recorded on the run');
    }

    @IsTest
    static void testExecute_ShardingPath_AllShardsFail_EnqueuesPipelineCallback() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'tier4-dispatch-allfail')[0];

        Tier3DispatchQueueable.lastPlannedShardCount = null;
        Tier3DispatchQueueable.lastUsedLegacyFallback = null;
        RecordingLauncher launcher = new RecordingLauncher();
        launcher.batchCallsThatThrow = new Set<Integer>{ 0, 1, 2, 3, 4 };
        Tier3DispatchQueueable.launcher = launcher;

        Tier3DispatchQueueable job = new Tier3DispatchQueueable(
            buildPairs(8, art.Id), run.Id, 'DEDUPLICATION'
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(1, launcher.callbackCalls,
            'Every shard failing to launch must fall back to enqueueing the pipeline callback');
    }

    @IsTest
    static void testExecute_ShardingPath_PartialShardFailure_CorrectsBarrier() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'tier4-dispatch-partial')[0];

        Tier3DispatchQueueable.lastPlannedShardCount = null;
        Tier3DispatchQueueable.lastUsedLegacyFallback = null;
        RecordingLauncher launcher = new RecordingLauncher();
        launcher.batchCallsThatThrow = new Set<Integer>{ 0 };
        Tier3DispatchQueueable.launcher = launcher;

        Tier3DispatchQueueable job = new Tier3DispatchQueueable(
            buildPairs(8, art.Id), run.Id, 'DEDUPLICATION'
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(0, launcher.callbackCalls,
            'At least one shard launched — no total-failure fallback');

        KB_Assessment_Run__c reloaded = [SELECT Tier4_Lanes_Outstanding__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.areEqual(4, reloaded.Tier4_Lanes_Outstanding__c,
            'Barrier corrected down to the count that actually launched (5 - 1 failure)');
    }

    @IsTest
    static void testRealAsyncLauncher_EnqueueTier3Agentic_DelegatesToPlatformApi() {
        // Direct coverage of the production launcher's delegate calls. No
        // Test.stopTest() here on purpose — enqueueing is enough to prove the
        // delegation; letting the job actually run would exercise
        // Tier3AgenticQueueable/Tier3AgenticBatch/KBAssessmentPipelineCallback
        // end-to-end with minimal fixture data, which is already covered
        // properly (with real setup) by their own test classes.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'tier4-real-launcher-a')[0];
        Tier3DispatchQueueable.RealAsyncLauncher real = new Tier3DispatchQueueable.RealAsyncLauncher();

        Test.startTest();
        Id qid = real.enqueueTier3Agentic(new Tier3AgenticQueueable(
            buildPairs(1, art.Id), run.Id, 'DEDUPLICATION'
        ));

        Assert.isNotNull(qid, 'RealAsyncLauncher.enqueueTier3Agentic delegates to System.enqueueJob');
    }

    @IsTest
    static void testRealAsyncLauncher_LaunchBatch_DelegatesToPlatformApi() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'tier4-real-launcher-b')[0];
        Tier3DispatchQueueable.RealAsyncLauncher real = new Tier3DispatchQueueable.RealAsyncLauncher();

        Test.startTest();
        Id batchId = real.launchBatch(
            new Tier3AgenticBatch(buildPairs(1, art.Id), run.Id, null, 1), 4
        );

        Assert.isNotNull(batchId, 'RealAsyncLauncher.launchBatch delegates to Database.executeBatch');
    }

    @IsTest
    static void testRealAsyncLauncher_EnqueuePipelineCallback_DelegatesToPlatformApi() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        Tier3DispatchQueueable.RealAsyncLauncher real = new Tier3DispatchQueueable.RealAsyncLauncher();

        Test.startTest();
        Id cbId = real.enqueuePipelineCallback(new KBAssessmentPipelineCallback(run.Id));

        Assert.isNotNull(cbId, 'RealAsyncLauncher.enqueuePipelineCallback delegates to System.enqueueJob');
    }
}
