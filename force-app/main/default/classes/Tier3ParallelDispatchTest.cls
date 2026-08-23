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
 * Coverage for the parallel Tier 4 path (C): Tier3DispatchQueueable's sharding
 * decision + barrier seeding, Tier3AgenticBatch's evaluate/persist/join-barrier,
 * and the shared Tier3PairEvaluator.
 *
 * The dispatch tests below inject a no-op IAsyncLauncher stub before calling
 * execute() directly — the real System.enqueueJob/Database.executeBatch calls
 * are exercised (with full assertions on launch counts, callback fallback, and
 * barrier correction) in Tier3DispatchQueueableTest instead; these tests only
 * care about the sharding decision + barrier seeding + persisted candidates
 * from the batch executed directly.
 */
@IsTest
private class Tier3ParallelDispatchTest {

    private class NoOpLauncher implements Tier3DispatchQueueable.IAsyncLauncher {
        public Id enqueueTier3Agentic(Tier3AgenticQueueable job) { return null; }
        public Id launchBatch(Tier3AgenticBatch batch, Integer scopeSize) { return null; }
        public Id enqueuePipelineCallback(KBAssessmentPipelineCallback callback) { return null; }
    }

    @TestSetup
    static void setup() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(12, 'tier4p');
        for (Knowledge__kav k : arts) {
            k.Summary = 'A useful article with enough content to chunk.\n\n'
                + 'A second paragraph so semanticChunk yields multiple chunks.';
        }
        update arts;

        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 12,
            Used_LLM__c = true,
            Assessment_Types__c = 'Readiness'
        );
        insert run;
        KB_Pipeline_Run__c pr = KBTestDataFactory.insertPipelineRun(run.Id, 'DEDUPLICATION', 'Running');
        run.Pipeline_Run__c = pr.Id;
        update run;
    }

    private static List<Knowledge__kav> arts() {
        return [SELECT Id, Title, Summary FROM Knowledge__kav WHERE Title LIKE 'tier4p-%' ORDER BY Title];
    }

 // Tier 4 only compares CURRENT Online articles, so any test that
    // expects a pair to be evaluated/flagged must publish the fixtures first.
    // Publishing can't run in @TestSetup (KbManagement.PublishingService is
    // disallowed there), so it happens here in test-method context.
    // Idempotent: already-Online rows are simply re-queried.
    private static List<Knowledge__kav> onlineArts() {
        List<Knowledge__kav> drafts = [
            SELECT KnowledgeArticleId FROM Knowledge__kav
            WHERE Title LIKE 'tier4p-%' AND PublishStatus = 'Draft'
        ];
        if (!drafts.isEmpty()) {
            for (Knowledge__kav k : drafts) {
                KbManagement.PublishingService.publishArticle(k.KnowledgeArticleId, true);
            }
        }
        return [
            SELECT Id, Title, Summary FROM Knowledge__kav
            WHERE Title LIKE 'tier4p-%' AND PublishStatus = 'Online' ORDER BY Title
        ];
    }
    private static Id runId() {
        return [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;
    }
    private static Tier3AgenticQueueable.FinalistPair pair(Id a, Id b) {
        return new Tier3AgenticQueueable.FinalistPair(a, b);
    }

    // Build N distinct finalist pairs from the 12 seeded articles.
    private static List<Tier3AgenticQueueable.FinalistPair> pairs(Integer n) {
        List<Knowledge__kav> a = arts();
        List<Tier3AgenticQueueable.FinalistPair> out = new List<Tier3AgenticQueueable.FinalistPair>();
        for (Integer i = 0; i < n; i++) {
            out.add(pair(a[Math.mod(i, 6)].Id, a[6 + Math.mod(i, 6)].Id));
        }
        return out;
    }

    @IsTest
    static void testDispatch_ManyPairs_PlansShardsAndSeedsBarrier() {
        // 8 pairs ≥ minPairsToShard(6) → shards. shardCount = min(5, 8) = 5.
        Tier3DispatchQueueable.launcher = new NoOpLauncher();
        Tier3DispatchQueueable d = new Tier3DispatchQueueable(pairs(8), runId(), 'DEDUPLICATION');

        Test.startTest();
        d.execute(null);
        Test.stopTest();

        Assert.areEqual(false, Tier3DispatchQueueable.lastUsedLegacyFallback,
            'Enough pairs → not the legacy fallback');
        Assert.areEqual(5, Tier3DispatchQueueable.lastPlannedShardCount,
            'Capped at MAX_SHARDS = 5');

        KB_Assessment_Run__c run = [
            SELECT Tier4_Lanes_Outstanding__c FROM KB_Assessment_Run__c WHERE Id = :runId()
        ];
        Assert.areEqual(5, run.Tier4_Lanes_Outstanding__c,
            'Join barrier seeded with the shard count before launch');
    }

    @IsTest
    static void testDispatch_FewPairs_UsesLegacyFallback() {
        // 3 pairs < minPairsToShard(6) → legacy single-lane path.
        Tier3DispatchQueueable.launcher = new NoOpLauncher();
        Tier3DispatchQueueable d = new Tier3DispatchQueueable(pairs(3), runId(), 'DEDUPLICATION');

        Test.startTest();
        d.execute(null);
        Test.stopTest();

        Assert.areEqual(true, Tier3DispatchQueueable.lastUsedLegacyFallback,
            'Too few pairs → legacy fallback');
        Assert.areEqual(0, Tier3DispatchQueueable.lastPlannedShardCount,
            'No shards planned on the fallback path');
    }

    @IsTest
    static void testDispatch_ShardCountTracksPairCountBelowMax() {
        // Exactly minPairsToShard with fewer than MAX_SHARDS distinct pairs:
        // 6 pairs → shardCount = min(5, 6) = 5.
        Tier3DispatchQueueable.launcher = new NoOpLauncher();
        Tier3DispatchQueueable d = new Tier3DispatchQueueable(pairs(6), runId(), 'DEDUPLICATION');
        Test.startTest();
        d.execute(null);
        Test.stopTest();
        Assert.areEqual(5, Tier3DispatchQueueable.lastPlannedShardCount, 'min(5,6)=5');
    }

    @IsTest
    static void testBatch_FlaggedPair_PersistsAndDecrementsBarrier() {
        List<Knowledge__kav> a = onlineArts(); // must be Online to be evaluated
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;

        // Seed barrier as if one shard was launched.
        update new KB_Assessment_Run__c(Id = rid, Tier4_Lanes_Outstanding__c = 1);

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult flagged = new PromptTemplateService.FactEvaluationResult();
        flagged.isDuplicate = true;
        flagged.confidenceScore = 90;
        flagged.reasoning = 'Same procedure described twice.';
        flagged.anomalyType = 'Duplicate';
        mock.mockFactEvalResult = flagged;
        mock.mockExtractedFacts = '- Fact A\n- Fact B';
        PromptTemplateService.setMock(mock);

        Tier3AgenticBatch b = new Tier3AgenticBatch(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(a[0].Id, a[6].Id) },
            rid, prId
        );

        Test.startTest();
        Database.executeBatch(b, 4);
        Test.stopTest();

        List<Duplicate_Candidate__c> dcs = [
            SELECT Id, Confidence_Score__c, Source_Tier__c, Status__c
            FROM Duplicate_Candidate__c WHERE Source_Tier__c = 'Tier4_Agentic'
        ];
        Assert.areEqual(1, dcs.size(), 'Flagged pair persisted by the batch');
        Assert.areEqual(90, dcs[0].Confidence_Score__c, 'Confidence stamped');

        KB_Assessment_Run__c run = [
            SELECT Tier4_Lanes_Outstanding__c FROM KB_Assessment_Run__c WHERE Id = :rid
        ];
        Assert.areEqual(Tier3AgenticBatch.BARRIER_CLAIMED, run.Tier4_Lanes_Outstanding__c,
            'Last lane finish() claims finalization by parking the sentinel');

        Integer cb = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'KBAssessmentPipelineCallback'
        ];
        Assert.areEqual(1, cb, 'Barrier hitting 0 enqueues the pipeline callback');
    }

 // finding b: once a lane claims finalization (sentinel
    // parked), a second lane finishing must NOT enqueue the callback again —
    // the callback re-runs severity annotation at LLM cost, so at-most-once.
    @IsTest
    static void testBatch_SecondLaneDoesNotDoubleFireCallback() {
        List<Knowledge__kav> a = onlineArts();
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;

        // Barrier already at the claimed sentinel — a late lane arrives.
        update new KB_Assessment_Run__c(
            Id = rid, Tier4_Lanes_Outstanding__c = Tier3AgenticBatch.BARRIER_CLAIMED
        );

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Tier3AgenticBatch b = new Tier3AgenticBatch(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(a[0].Id, a[6].Id) },
            rid, prId
        );

        Test.startTest();
        Database.executeBatch(b, 4);
        Test.stopTest();

        Integer cb = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'KBAssessmentPipelineCallback'
        ];
        Assert.areEqual(0, cb,
            'A lane finishing against a claimed barrier must not re-enqueue the callback');
        KB_Assessment_Run__c run = [
            SELECT Tier4_Lanes_Outstanding__c FROM KB_Assessment_Run__c WHERE Id = :rid
        ];
        Assert.areEqual(Tier3AgenticBatch.BARRIER_CLAIMED, run.Tier4_Lanes_Outstanding__c,
            'Sentinel left intact — the late lane bailed without re-decrementing');
    }

    @IsTest
    static void testEvaluator_SelfAndBlankPairsSkipped() {
        List<Knowledge__kav> a = arts();
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Test.startTest();
        Tier3PairEvaluator.Result r = Tier3PairEvaluator.evaluatePairs(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(a[0].Id, a[0].Id) },
            rid, prId
        );
        Test.stopTest();

        Assert.areEqual(0, r.evaluatedPairs, 'Self-pair never evaluated');
        Assert.areEqual(1, r.skippedPairs, 'Self-pair counted as skipped');
        Assert.areEqual(0, mock.factEvalCallCount, 'No LLM call for a self-pair');
    }

    @IsTest
    static void testBatch_CancelledRun_SkipsWork() {
        List<Knowledge__kav> a = arts();
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;
        update new KB_Assessment_Run__c(Id = rid, Status__c = 'Cancelled');

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Tier3AgenticBatch b = new Tier3AgenticBatch(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(a[0].Id, a[6].Id) },
            rid, prId
        );

        Test.startTest();
        Database.executeBatch(b, 4);
        Test.stopTest();

        Assert.areEqual(0, mock.factEvalCallCount, 'Cancelled run → batch does no LLM work');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Duplicate_Candidate__c WHERE Source_Tier__c = 'Tier4_Agentic'],
            'Cancelled run persists nothing');
    }

 // the parallel evaluator must apply the SAME published-only gate as
    // the legacy queueable: a pair with a non-Online (here Draft) side is
    // skipped before the LLM and never flagged, even if the LLM would flag it.
    @IsTest
    static void testEvaluator_NonPublishedPairSkipped() {
        List<Knowledge__kav> a = onlineArts(); // publishes the tier4p fixtures
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;

        // A fresh Draft that a later onlineArts() could never sweep up (prefix
        // does not match 'tier4p-%').
        Knowledge__kav draft = KBTestDataFactory.insertArticles(1, 'draftonlyp')[0];
        draft.Summary = 'Draft body with enough content to chunk. Second sentence.';
        update draft;

        // Mock a result that WOULD flag — proving the skip is the publish gate.
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult flagged = new PromptTemplateService.FactEvaluationResult();
        flagged.isDuplicate = true;
        flagged.confidenceScore = 95;
        flagged.anomalyType = 'Duplicate';
        mock.mockFactEvalResult = flagged;
        mock.mockExtractedFacts = '- Fact A';
        PromptTemplateService.setMock(mock);

        Test.startTest();
        Tier3PairEvaluator.Result r = Tier3PairEvaluator.evaluatePairs(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(a[0].Id, draft.Id) },
            rid, prId
        );
        Test.stopTest();

        Assert.areEqual(0, r.evaluatedPairs, 'Non-published pair never evaluated');
        Assert.areEqual(0, mock.factEvalCallCount, 'Publish gate skips before the LLM');
        Assert.areEqual(0, r.flaggedCandidates.size(), 'Non-published pair produces no candidate');
    }

 // 'Overlap' was retired; there is no longer an Overlap-specific
    // confidence floor. A ruling that a stale prompt still labels 'Overlap' must
    // (a) clear the single configured minConfidence like any anomaly and (b) be
    // persisted as 'Duplicate' (a valid Flag_Type value), not the retired one.
    @IsTest
    static void testEvaluator_LegacyOverlapCoercedToDuplicate() {
        List<Knowledge__kav> a = onlineArts();
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult overlap = new PromptTemplateService.FactEvaluationResult();
        overlap.isDuplicate = true;
        overlap.confidenceScore = 90; // clears the configured floor
        overlap.anomalyType = 'Overlap';
        mock.mockFactEvalResult = overlap;
        mock.mockExtractedFacts = '- Fact A';
        PromptTemplateService.setMock(mock);

        Test.startTest();
        Tier3PairEvaluator.Result r = Tier3PairEvaluator.evaluatePairs(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(a[0].Id, a[6].Id) },
            rid, prId
        );
        Test.stopTest();

        Assert.areEqual(1, r.flaggedCandidates.size(), 'Anomaly is flagged (no Overlap floor)');
        Assert.areEqual('Duplicate', r.flaggedCandidates[0].Flag_Type__c,
            'Retired "Overlap" ruling is coerced to Duplicate, not written verbatim');
    }

 // Contradiction takes precedence over Duplicate. A ruling that marks
    // the pair as a duplicate AND names a contradiction must persist as
    // Contradiction so it routes to human resolution, never to auto-merge.
    @IsTest
    static void testEvaluator_ContradictionWinsOverDuplicate() {
        List<Knowledge__kav> a = onlineArts();
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult both = new PromptTemplateService.FactEvaluationResult();
        both.isDuplicate = true;            // near-duplicate…
        both.anomalyType = 'Contradiction'; // …but also contradictory
        both.confidenceScore = 95;
        mock.mockFactEvalResult = both;
        mock.mockExtractedFacts = '- Fact A';
        PromptTemplateService.setMock(mock);

        Test.startTest();
        Tier3PairEvaluator.Result r = Tier3PairEvaluator.evaluatePairs(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(a[0].Id, a[6].Id) },
            rid, prId
        );
        Test.stopTest();

        Assert.areEqual(1, r.flaggedCandidates.size(), 'The both-signals pair is flagged');
        Assert.areEqual('Contradiction', r.flaggedCandidates[0].Flag_Type__c,
            'Contradiction takes precedence over Duplicate — routes to human review, not merge');
    }

 // budgeted (legacy queueable) path, ample budget. Covers the
    // reserve-before-start block that only runs when maxCallouts is non-null.
    //
    // The regression this pins is a duplicated semanticChunk() — pure CPU, no LLM
    // call — so it is INVISIBLE to extractFactsCallCount (extraction, and thus the
    // fact-extract LLM call, ran exactly once per body on both the buggy and fixed
    // code, guarded by factsCache). The only signal that separates them is how
    // many times semanticChunk itself runs: pre-fix = 4 (2 bodies × {reserve,
    // extract}), post-fix = 2 (each body chunked once, reused). We assert on the
    // @TestVisible semanticChunkCallCount counter, which fails against pre-fix code.
    @IsTest
    static void testEvaluator_BudgetedAmpleBudget_ChunksEachBodyOnce() {
        List<Knowledge__kav> a = onlineArts();
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult flagged = new PromptTemplateService.FactEvaluationResult();
        flagged.isDuplicate = true;
        flagged.confidenceScore = 95;
        flagged.anomalyType = 'Duplicate';
        mock.mockFactEvalResult = flagged;
        mock.mockExtractedFacts = '- Fact A';
        PromptTemplateService.setMock(mock);

        Tier3PairEvaluator.semanticChunkCallCount = 0;

        Test.startTest();
        Tier3PairEvaluator.Result r = Tier3PairEvaluator.evaluatePairs(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(a[0].Id, a[6].Id) },
            rid, prId, 100 // budgeted, but far more than this one pair needs
        );
        Test.stopTest();

        Assert.areEqual(false, r.budgetHit, 'Ample budget → not hit');
        Assert.areEqual(0, r.remainingPairs.size(), 'Nothing deferred');
        Assert.areEqual(1, r.evaluatedPairs, 'The pair is evaluated');
        Assert.areEqual(1, r.flaggedCandidates.size(), 'And flagged');
 // The core assertion: 2 bodies chunked once each. Pre-fix this was 4
        // (reserve chunked, then extraction re-chunked the identical body).
        Assert.areEqual(2, Tier3PairEvaluator.semanticChunkCallCount,
            'Each body is chunked exactly once — the reserve step and extraction '
            + 'share the cached chunk list, not a second semanticChunk');
    }

    // A long article body must be chunked in full — no fixed chunk-count cap
    // silently drops the tail. Knowledge__kav.Summary is capped at 1000 chars,
    // too short to naturally force many chunks at the default 500-char chunk
    // size, so this pins Max_Chunk_Size__c down instead: 8 short paragraphs
    // (each comfortably longer than the pinned size) each force their own
    // chunk — comfortably past the retired default cap of 5, so this fails
    // against a reverted cap rather than sitting right at its boundary (the
    // leading Title paragraph the body-builder prepends also consumes a
    // "slot" under the old cap-enforcing code, which a lower paragraph count
    // could mask). Only the LAST paragraph carries a unique marker; asserting
    // the marker reached extractArticleFacts proves the tail of a long
    // article is analyzed, not truncated.
    @IsTest
    static void testEvaluator_LongArticleBody_TailReachesExtraction() {
        List<Knowledge__kav> a = onlineArts();
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;

        KB_Pipeline_Config__c cs = KB_Pipeline_Config__c.getOrgDefaults();
        cs.Max_Chunk_Size__c = 40;
        upsert cs KB_Pipeline_Config__c.Id;

        Integer sectionCount = 8;
        String tailMarker = 'UNIQUE_TAIL_MARKER_XYZ';
        List<String> paragraphs = new List<String>();
        for (Integer i = 0; i < sectionCount; i++) {
            String para = 'Section ' + i + ' is well past the pinned forty-char chunk size.';
            if (i == sectionCount - 1) {
                para += ' ' + tailMarker;
            }
            paragraphs.add(para);
        }

        // An Online KAV can't be edited by plain DML (Knowledge write goes
        // through KbManagement.PublishingService) — set the long body while
        // still Draft, then publish it.
        Knowledge__kav longDraft = KBTestDataFactory.insertArticles(1, 'tier4pLong')[0];
        longDraft.Summary = String.join(paragraphs, '\n\n');
        update longDraft;
        Id longArticleId = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :longDraft.Id].KnowledgeArticleId;
        KbManagement.PublishingService.publishArticle(longArticleId, true);
        Knowledge__kav longArticle = [
            SELECT Id, Title, Summary FROM Knowledge__kav
            WHERE KnowledgeArticleId = :longArticleId AND PublishStatus = 'Online'
        ];

        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.mockExtractedFacts = '- Fact A';
        PromptTemplateService.setMock(mock);

        Test.startTest();
        Tier3PairEvaluator.Result r = Tier3PairEvaluator.evaluatePairs(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(longArticle.Id, a[6].Id) },
            rid, prId
        );
        Test.stopTest();

        Assert.areEqual(1, r.evaluatedPairs, 'The pair is evaluated');

        Boolean tailReachedExtraction = false;
        for (String chunkText : mock.extractedChunkTexts) {
            if (chunkText.contains(tailMarker)) {
                tailReachedExtraction = true;
                break;
            }
        }
        Assert.isTrue(tailReachedExtraction,
            'The last paragraph of a long article must reach extractArticleFacts — '
            + 'a fixed chunk-count cap used to silently drop it');
        Assert.isTrue(mock.extractedChunkTexts.size() > 2,
            'The long body alone should split into several chunks, not collapse to one');
    }

 // budgeted path, budget too small for the pair's worst-case cost.
    // Reserve-before-start must defer the pair WITHOUT extracting anything, so no
    // LLM callout is spent on a pair the continuation has to re-extract.
    @IsTest
    static void testEvaluator_BudgetedTooSmall_DefersWithoutExtracting() {
        List<Knowledge__kav> a = onlineArts();
        Id rid = runId();
        Id prId = [SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :rid].Pipeline_Run__c;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.mockExtractedFacts = '- Fact A';
        PromptTemplateService.setMock(mock);

        Test.startTest();
        // The pair costs 3 callouts (1 + 1 + 1); a budget of 1 can't cover it.
        Tier3PairEvaluator.Result r = Tier3PairEvaluator.evaluatePairs(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(a[0].Id, a[6].Id) },
            rid, prId, 1
        );
        Test.stopTest();

        Assert.areEqual(true, r.budgetHit, 'Budget too small → hit');
        Assert.areEqual(1, r.remainingPairs.size(), 'The un-startable pair is deferred');
        Assert.areEqual(0, r.evaluatedPairs, 'Nothing evaluated');
        Assert.areEqual(0, mock.extractFactsCallCount,
            'Reserve-before-start extracted nothing for the deferred pair');
    }

    // Direct unit coverage of the precedence/coercion helper.
    @IsTest
    static void testResolveFlagType_PrecedenceAndCoercion() {
        PromptTemplateService.FactEvaluationResult dup = new PromptTemplateService.FactEvaluationResult();
        dup.isDuplicate = true; dup.anomalyType = 'Duplicate';
        Assert.areEqual('Duplicate', Tier3PairEvaluator.resolveFlagType(dup));

        PromptTemplateService.FactEvaluationResult con = new PromptTemplateService.FactEvaluationResult();
        con.isDuplicate = true; con.anomalyType = 'Contradiction';
        Assert.areEqual('Contradiction', Tier3PairEvaluator.resolveFlagType(con),
            'Contradiction wins even when isDuplicate=true');

        PromptTemplateService.FactEvaluationResult ovl = new PromptTemplateService.FactEvaluationResult();
        ovl.isDuplicate = false; ovl.anomalyType = 'Overlap';
        Assert.areEqual('Duplicate', Tier3PairEvaluator.resolveFlagType(ovl),
            'Retired Overlap coerces to Duplicate');
    }

 // a re-detected pair must not resurface a human-triaged
    // (Rejected/Resolved/Suppressed) candidate. attachExistingIdsForRunScopedUpsert
    // drops the triaged row from the returned upsert set.
    @IsTest
    static void testUpsertHelper_ProtectsTriagedCandidate() {
        List<Knowledge__kav> a = onlineArts();
        Id rid = runId();
        String key = KnowledgeAIGovernanceService.generateCompositeKey(a[0].Id, a[6].Id);

        // A human-Rejected candidate already exists for this pair.
        insert new Duplicate_Candidate__c(
            Knowledge_Article_1__c = a[0].Id, Knowledge_Article_2__c = a[6].Id,
            Composite_Key__c = key, Flag_Type__c = 'Duplicate', Status__c = 'Rejected',
            Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Assessment_Run__c = rid
        );

        // A freshly-detected (Pending) row for the SAME pair.
        List<Duplicate_Candidate__c> fresh = new List<Duplicate_Candidate__c>{
            new Duplicate_Candidate__c(
                Knowledge_Article_1__c = a[0].Id, Knowledge_Article_2__c = a[6].Id,
                Composite_Key__c = key, Flag_Type__c = 'Duplicate', Status__c = 'Pending',
                Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 90, Assessment_Run__c = rid
            )
        };

        Test.startTest();
        List<Duplicate_Candidate__c> toUpsert =
            Tier3PairEvaluator.attachExistingIdsForRunScopedUpsert(fresh, rid);
        Test.stopTest();

        Assert.areEqual(0, toUpsert.size(),
            'A human-Rejected pair is dropped from the upsert (decision stands)');
        Assert.areEqual('Rejected',
            [SELECT Status__c FROM Duplicate_Candidate__c WHERE Composite_Key__c = :key].Status__c,
            'The triaged row is untouched');
    }

 // a SOFT 'Not a Duplicate' discard is this-run-only: on re-detection
    // the pair must resurface. attachExistingIdsForRunScopedUpsert reuses the row
    // in place (Id stamped) so the fresh Pending result overwrites the soft status.
    @IsTest
    static void testUpsertHelper_SoftNotADuplicateResurfaces() {
        List<Knowledge__kav> a = onlineArts();
        Id rid = runId();
        String key = KnowledgeAIGovernanceService.generateCompositeKey(a[0].Id, a[6].Id);

        Duplicate_Candidate__c existing = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = a[0].Id, Knowledge_Article_2__c = a[6].Id,
            Composite_Key__c = key, Flag_Type__c = 'Duplicate', Status__c = 'Not a Duplicate',
            Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Assessment_Run__c = rid
        );
        insert existing;

        List<Duplicate_Candidate__c> fresh = new List<Duplicate_Candidate__c>{
            new Duplicate_Candidate__c(
                Knowledge_Article_1__c = a[0].Id, Knowledge_Article_2__c = a[6].Id,
                Composite_Key__c = key, Flag_Type__c = 'Duplicate', Status__c = 'Pending',
                Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 90, Assessment_Run__c = rid
            )
        };

        Test.startTest();
        List<Duplicate_Candidate__c> toUpsert =
            Tier3PairEvaluator.attachExistingIdsForRunScopedUpsert(fresh, rid);
        Test.stopTest();

        Assert.areEqual(1, toUpsert.size(),
            'A soft "Not a Duplicate" pair is re-included so it resurfaces');
        Assert.areEqual(existing.Id, toUpsert[0].Id,
            'The existing row is reused in place (Id stamped), not duplicated');
        Assert.areEqual('Pending', toUpsert[0].Status__c,
            'Reused row carries the fresh Pending status → resurfaces on the queue');
    }
}
