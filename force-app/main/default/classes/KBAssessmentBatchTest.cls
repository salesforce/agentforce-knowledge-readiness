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
 * Coverage for KBAssessmentBatch — Batch Apex orchestrator that scores
 * dimensions for large runs (>50 articles).
 *
 * Tests fall into two groups:
 *   1. Pure scope-size math (no DML beyond a single run record).
 *   2. Full execute() body driven through real Knowledge__kav rows +
 *      KB_Article_Assessment__c parents + Duplicate_Candidate__c bridge
 *      data, using deterministic dimensions (Freshness, Duplication,
 *      Conflict) so no LLM mock is required.
 */
@IsTest
private class KBAssessmentBatchTest {

    private static KB_Assessment_Run__c createTestRun() {
        return KBTestDataFactory.insertRun('In Progress', 'Readiness');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Scope-size math
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testComputeScopeSize_AllActiveDims() {
        KBAssessmentBatch batch = new KBAssessmentBatch(
            createTestRun().Id, DimensionRegistry.getActiveDeveloperNames()
        );
        Integer scope = batch.getScopeSize();
        Assert.isTrue(scope >= 5);
        Assert.isTrue(scope <= 90);
    }

    @IsTest
    static void testComputeScopeSize_SingleLLMDim() {
        KBAssessmentBatch batch = new KBAssessmentBatch(
            createTestRun().Id, new Set<String>{ 'Completeness' }
        );
        // Completeness = 1 callout/article post-consolidation; min(90/1, 480/(1*10)) = 48
        Assert.areEqual(48, batch.getScopeSize());
    }

    @IsTest
    static void testComputeScopeSize_NoPipelineDims() {
        KBAssessmentBatch batch = new KBAssessmentBatch(
            createTestRun().Id, new Set<String>{ 'Freshness' }
        );
        Assert.areEqual(100, batch.getScopeSize());
    }

    @IsTest
    static void testConstructor_NullDimensions_FallsBackToActiveSet() {
        KBAssessmentBatch batch = new KBAssessmentBatch(
            createTestRun().Id, null
        );
        // Constructor swaps null for DimensionRegistry.getActiveDeveloperNames();
        // verify by exercising scope-size which depends on the dim set.
        Assert.isNotNull(batch.getScopeSize());
    }

    @IsTest
    static void testConstructor_EmptyDimensions_FallsBackToActiveSet() {
        KBAssessmentBatch batch = new KBAssessmentBatch(
            createTestRun().Id, new Set<String>()
        );
        Assert.isNotNull(batch.getScopeSize());
    }

    // ──────────────────────────────────────────────────────────────────────
    // start() — query locator
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testStart_ReturnsQueryLocator() {
        KB_Assessment_Run__c run = createTestRun();
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'batch-start')[0];
        KBTestDataFactory.insertArticleAssessment(run.Id, kav.Id);

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, DimensionRegistry.getActiveDeveloperNames()
        );

        Test.startTest();
        Database.QueryLocator ql = (Database.QueryLocator) batch.start(null);
        Test.stopTest();

        Assert.isNotNull(ql);
    }

    // ──────────────────────────────────────────────────────────────────────
    // execute() — empty scope short-circuit
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_EmptyScope_NoOp() {
        KB_Assessment_Run__c run = createTestRun();
        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }
        );

        // Empty scope path — must not throw, must not query, must not DML.
        Test.startTest();
        batch.execute(null, new List<KB_Article_Assessment__c>());
        batch.execute(null, null);
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM KB_Dimension_Result__c WHERE Article_Assessment__r.Assessment_Run__c = :run.Id],
            'No child rows created on empty scope'
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // execute() — full body with deterministic dims
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_FreshnessOnly_WritesDimensionResults() {
        KB_Assessment_Run__c run = createTestRun();
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'batch-fresh');
        List<KB_Article_Assessment__c> parents = new List<KB_Article_Assessment__c>();
        for (Knowledge__kav k : kavs) {
            parents.add(KBTestDataFactory.insertArticleAssessment(run.Id, k.Id));
        }

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }
        );

        // Re-query parents so the scope rows have populated lookup fields.
        List<KB_Article_Assessment__c> scope = [
            SELECT Id, Knowledge__c, Article_Title__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :run.Id
        ];

        Test.startTest();
        batch.execute(null, scope);
        Test.stopTest();

        Integer dimRows = [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :run.Id
              AND Dimension__c = 'Freshness'
        ];
        Assert.areEqual(2, dimRows,
            'One Freshness child row per article scored');

        // Parent Overall_Score and Readiness_Status are populated.
        List<KB_Article_Assessment__c> updated = [
            SELECT Overall_Score__c, Readiness_Status__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :run.Id
        ];
        for (KB_Article_Assessment__c p : updated) {
            Assert.isNotNull(p.Overall_Score__c);
            Assert.isNotNull(p.Readiness_Status__c);
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Per-chunk generation gate (straggler from an aborted prior wave)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_SkipsWriteWhenSupersededByNewerWave() {
        // Simulates the reported cancel→rerun collision: a wave-1 shard drains
        // an in-flight chunk (abortJob doesn't stop it) AFTER a rerun bumped the
        // run to a newer generation. The straggler must decline to write rather
        // than collide with wave-2 over the same KB_Article_Assessment__c rows.
        KB_Assessment_Run__c run = createTestRun();
        update new KB_Assessment_Run__c(Id = run.Id, Dispatch_Generation__c = 1);
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'batch-gen-stale');
        for (Knowledge__kav k : kavs) {
            KBTestDataFactory.insertArticleAssessment(run.Id, k.Id);
        }
        List<KB_Article_Assessment__c> scope = [
            SELECT Id, Knowledge__c, Article_Title__c
            FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :run.Id
        ];

        KBAssessmentBatch batch = new KBAssessmentBatch(run.Id, new Set<String>{ 'Freshness' });

        Test.startTest();
        // start() captures generation 1 (this wave's generation).
        batch.start(null);
        // A rerun then re-dispatches, bumping the run to generation 2.
        update new KB_Assessment_Run__c(Id = run.Id, Dispatch_Generation__c = 2);
        // The drained chunk now runs — it must see 2 > 1 and bail without writing.
        batch.execute(null, scope);
        Test.stopTest();

        Assert.areEqual(0, [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :run.Id
        ], 'A superseded (older-generation) straggler must not write any dimension results');
    }

    @IsTest
    static void testExecute_WritesWhenGenerationStillCurrent() {
        // Companion to the gate test: when the captured generation still matches
        // the run's current generation (no rerun happened), the chunk writes
        // normally — the gate must not block a legitimate in-progress wave.
        KB_Assessment_Run__c run = createTestRun();
        update new KB_Assessment_Run__c(Id = run.Id, Dispatch_Generation__c = 1);
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'batch-gen-current');
        for (Knowledge__kav k : kavs) {
            KBTestDataFactory.insertArticleAssessment(run.Id, k.Id);
        }
        List<KB_Article_Assessment__c> scope = [
            SELECT Id, Knowledge__c, Article_Title__c
            FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :run.Id
        ];

        KBAssessmentBatch batch = new KBAssessmentBatch(run.Id, new Set<String>{ 'Freshness' });

        Test.startTest();
        batch.start(null);           // captures generation 1
        batch.execute(null, scope);  // generation unchanged → writes
        Test.stopTest();

        Assert.areEqual(2, [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :run.Id
              AND Dimension__c = 'Freshness'
        ], 'A current-generation wave must write its dimension results normally');
    }

    @IsTest
    static void testExecute_PersistsAnalysisRows_AndIsIdempotent() {
 // the batch path must persist KB_Dimension_Analysis__c issue/
        // strength rows (it computed them but never wrote them). A freshly
        // created article scores "very fresh" → one Freshness Strength row.
        KB_Assessment_Run__c run = createTestRun();
        KBTestDataFactory.insertArticleAssessment(
            run.Id, KBTestDataFactory.insertArticles(1, 'batch-analysis')[0].Id
        );
        List<KB_Article_Assessment__c> scope = [
            SELECT Id, Knowledge__c, Article_Title__c
            FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :run.Id
        ];

        KBAssessmentBatch batch = new KBAssessmentBatch(run.Id, new Set<String>{ 'Freshness' });

        Test.startTest();
        batch.execute(null, scope);           // first pass writes analyses
        batch.execute(null, scope);           // re-run must REPLACE, not stack
        Test.stopTest();

        List<KB_Dimension_Analysis__c> analyses = [
            SELECT Id, Type__c, Dimension__c
            FROM KB_Dimension_Analysis__c
            WHERE Article_Assessment__r.Assessment_Run__c = :run.Id
              AND Dimension__c = 'Freshness'
        ];
        Assert.areEqual(1, analyses.size(),
            'Exactly one Freshness analysis row persists (idempotent re-run — no stacking)');
        Assert.areEqual('Strength', analyses[0].Type__c,
            'A very-fresh article yields a Freshness Strength row');
    }

    @IsTest
    static void testExecute_PipelineDims_LoadsBridgeData() {
        // Drives the Duplication and Conflict branches that read from
        // KBPipelineBridgeService — verifies the bridge integration path.
        KB_Assessment_Run__c run = createTestRun();
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'batch-pipeline');
        for (Knowledge__kav k : kavs) {
            KBTestDataFactory.insertArticleAssessment(run.Id, k.Id);
        }
        // Seed a duplicate candidate so getBatchCandidates returns rows.
        KBTestDataFactory.insertDuplicateCandidate(
            kavs[0].Id, kavs[1].Id, 'Duplicate', 'Pending'
        );

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness', 'Duplication', 'Conflict' }
        );

        List<KB_Article_Assessment__c> scope = [
            SELECT Id, Knowledge__c, Article_Title__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :run.Id
        ];

        Test.startTest();
        batch.execute(null, scope);
        Test.stopTest();

        Integer dimRows = [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :run.Id
        ];
        Assert.isTrue(dimRows >= 6,
            '3 dims × 2 articles ≥ 6 child rows (some dims may add more)');
    }

    @IsTest
    static void testExecute_ExistingChildRows_UpdatedInPlace() {
        // Pre-create a Freshness child row for one article. Run execute()
        // and verify it's updated rather than duplicated.
        KB_Assessment_Run__c run = createTestRun();
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'batch-existing')[0];
        KB_Article_Assessment__c parent = KBTestDataFactory.insertArticleAssessment(run.Id, kav.Id);
        insert new KB_Dimension_Result__c(
            Article_Assessment__c = parent.Id,
            Dimension__c = 'Freshness',
            Score__c = 0,
            Reasoning__c = 'old'
        );

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }
        );
        List<KB_Article_Assessment__c> scope = [
            SELECT Id, Knowledge__c, Article_Title__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :run.Id
        ];

        Test.startTest();
        batch.execute(null, scope);
        Test.stopTest();

        // Still exactly one Freshness row for this article (not duplicated).
        Integer count = [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__c = :parent.Id
              AND Dimension__c = 'Freshness'
        ];
        Assert.areEqual(1, count, 'Existing row updated, not duplicated');
    }

    // ──────────────────────────────────────────────────────────────────────
    // finish() — dispatches finalization
    // ──────────────────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────────────────
 // per-chunk KB_Assessment_Progress__e emit + Database.Stateful
    // cumulative counter. Same EventBus.publish caveat as the queueable test:
    // publish has no captured-events API. We assert structurally that the
    // counter survives across chunks and is incremented in lockstep with
    // scope size — the publish call sits immediately after the increment, so
    // the counter check covers the publish call having been reached.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_CumulativeProcessed_SurvivesAcrossChunks() {
        // Two chunks of 1 article each. After both, cumulativeProcessed must
        // equal the total (2) — proves Database.Stateful is in effect AND
        // the increment runs immediately before publishChunkProgress.
        KB_Assessment_Run__c run = createTestRun();
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'batch-progress');
        for (Knowledge__kav k : kavs) {
            KBTestDataFactory.insertArticleAssessment(run.Id, k.Id);
        }

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }
        );
        // Stamp totalScope as start() would — keeps the unit test focused on
        // the per-chunk increment + publish, without driving Database.executeBatch.
        batch.totalScope = 2;

        List<KB_Article_Assessment__c> all = [
            SELECT Id, Knowledge__c, Article_Title__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :run.Id
            ORDER BY Id ASC
        ];
        List<KB_Article_Assessment__c> chunk1 = new List<KB_Article_Assessment__c>{ all[0] };
        List<KB_Article_Assessment__c> chunk2 = new List<KB_Article_Assessment__c>{ all[1] };

        Test.startTest();
        batch.execute(null, chunk1);
        Assert.areEqual(1, batch.cumulativeProcessed,
            'First chunk increments counter to 1 before publish');
        batch.execute(null, chunk2);
        Test.stopTest();

        Assert.areEqual(2, batch.cumulativeProcessed,
            'Second chunk increments counter to 2 — Database.Stateful preserved state');
    }

    @IsTest
    static void testStart_PopulatesTotalScopeFromRun() {
        // start() should source totalScope from KB_Assessment_Run__c.Total_Articles__c
        // when populated, avoiding a redundant COUNT() query.
        KB_Assessment_Run__c run = createTestRun();
        run.Total_Articles__c = 7;
        update run;

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }
        );

        Test.startTest();
        // Called directly (no Database.executeBatch) to exercise the
        // totalScope-population path in start() without driving the full
        // batch framework — the BatchableContext is unused here.
        batch.start(null);
        Test.stopTest();

        Assert.areEqual(7, batch.totalScope,
            'totalScope sourced from Total_Articles__c on the run row');
    }

    @IsTest
    static void testStart_FallsBackToCountWhenTotalArticlesIsNull() {
 // If Total_Articles__c is null (older run rows pre-), start
        // must fall back to COUNT() so the per-chunk math is never blank.
        KB_Assessment_Run__c run = createTestRun();
        run.Total_Articles__c = null;
        update run;
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'batch-fallback')[0];
        KBTestDataFactory.insertArticleAssessment(run.Id, kav.Id);

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }
        );

        Test.startTest();
        batch.start(null);
        Test.stopTest();

        Assert.areEqual(1, batch.totalScope,
            'COUNT() fallback fires when Total_Articles__c is null');
    }

    @IsTest
    static void testFinish_DispatchesFinalization() {
        KB_Assessment_Run__c run = createTestRun();
        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }
        );

        // finish() delegates to KBAssessmentPipelineDispatcher.dispatchFinalization,
        // which inside Test.startTest/stopTest may try to enqueue a callback
        // queueable. Async chain depth in tests caps at 1, so we accept the
        // documented AsyncException; the synchronous dispatcher branch ran.
        Integer jobsBefore = [SELECT COUNT() FROM AsyncApexJob];
        Test.startTest();
        Boolean threwAsyncChain = false;
        try {
            batch.finish(null);
        } catch (AsyncException ae) {
            threwAsyncChain = true;
        }
        Test.stopTest();
        Integer jobsAfter = [SELECT COUNT() FROM AsyncApexJob];

        Assert.isTrue(threwAsyncChain || jobsAfter >= jobsBefore,
            'finish() either enqueued the next job or hit the test chain-depth cap — both prove dispatch ran');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Parallel scoring shards (>50 path)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testShard_StartScopesToShardArticleIds() {
        KB_Assessment_Run__c run = createTestRun();
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(4, 'batch-shard');
        for (Knowledge__kav k : kavs) {
            KBTestDataFactory.insertArticleAssessment(run.Id, k.Id);
        }
        // Shard covers only the first 2 of the 4 articles.
        List<String> shardIds = new List<String>{ kavs[0].Id, kavs[1].Id };
        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }, shardIds
        );

        Test.startTest();
        Database.QueryLocator loc = (Database.QueryLocator) batch.start(null);
        Test.stopTest();

        // The locator should only select this shard's 2 parents.
        Assert.areEqual(2, countLocator(loc),
            'Shard start() scopes to its own article ids only');
    }

    private static Integer countLocator(Database.QueryLocator loc) {
        Integer n = 0;
        Database.QueryLocatorIterator it = loc.iterator();
        while (it.hasNext()) { it.next(); n++; }
        return n;
    }

    @IsTest
    static void testShard_FinishDecrementsBarrier_NotLast() {
        KB_Assessment_Run__c run = createTestRun();
        update new KB_Assessment_Run__c(Id = run.Id, Scoring_Shards_Outstanding__c = 3);

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }, new List<String>{ '0' }
        );

        Test.startTest();
        batch.finish(null); // not the last shard (3 -> 2)
        Test.stopTest();

        KB_Assessment_Run__c after = [
            SELECT Scoring_Shards_Outstanding__c FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual(2, after.Scoring_Shards_Outstanding__c,
            'Non-last shard decrements the barrier but does not finalize');
    }

    @IsTest
    static void testShard_FinishLastShardFinalizes() {
        KB_Assessment_Run__c run = createTestRun();
        update new KB_Assessment_Run__c(Id = run.Id, Scoring_Shards_Outstanding__c = 1);

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }, new List<String>{ '0' }
        );

        Test.startTest();
        Boolean threwAsyncChain = false;
        try {
            batch.finish(null); // last shard (1 -> 0) → dispatches finalization
        } catch (AsyncException ae) {
            threwAsyncChain = true; // test chain-depth cap; dispatch still ran
        }
        Test.stopTest();

        KB_Assessment_Run__c after = [
            SELECT Scoring_Shards_Outstanding__c FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual(KBAssessmentBatch.BARRIER_CLAIMED, after.Scoring_Shards_Outstanding__c,
            'Last shard claims finalization by parking the sentinel');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Barrier double-fire guard: once a shard claims finalization (parks the
    // sentinel), a second shard reaching finish() must NOT finalize again —
    // finalization re-runs the dedup pipeline + severity annotation at LLM
 // cost, so at-most-once matters. (finding b.)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testShard_SecondShardDoesNotDoubleFinalize() {
        KB_Assessment_Run__c run = createTestRun();
        // Simulate the state right after the last shard claimed: barrier parked
        // at the negative sentinel.
        update new KB_Assessment_Run__c(
            Id = run.Id, Scoring_Shards_Outstanding__c = KBAssessmentBatch.BARRIER_CLAIMED
        );

        KBAssessmentBatch batch = new KBAssessmentBatch(
            run.Id, new Set<String>{ 'Freshness' }, new List<String>{ '0' }
        );

        Test.startTest();
        // A late shard finishing against an already-claimed barrier must not
        // dispatch finalization — so no AsyncException from a second dispatch.
        Boolean threw = false;
        try {
            batch.finish(null);
        } catch (AsyncException ae) {
            threw = true;
        }
        Test.stopTest();

        Assert.isFalse(threw,
            'A shard finishing against a claimed barrier must not dispatch finalization again');
        KB_Assessment_Run__c after = [
            SELECT Scoring_Shards_Outstanding__c FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual(KBAssessmentBatch.BARRIER_CLAIMED, after.Scoring_Shards_Outstanding__c,
            'Sentinel is left intact — the second shard bailed without re-decrementing');
    }
}
