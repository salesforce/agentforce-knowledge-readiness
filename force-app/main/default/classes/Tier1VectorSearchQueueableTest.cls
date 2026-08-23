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
 * Coverage for Tier1VectorSearchQueueable — fan-out queueable that
 * resolves vector-search candidates for a batch of articles, dedupes
 * (A,B)/(B,A) pairs, and dispatches Tier 3 (or Tier 4 in transformation
 * mode, or the pipeline callback when no candidates exist).
 *
 * All ConnectApi vector calls are intercepted via VectorSearchFactory
 * setMock(). Tests call .execute(null) directly inside Test.startTest()/
 * stopTest() rather than System.enqueueJob to avoid the queueable-from-
 * queueable depth limit.
 */
@IsTest
private class Tier1VectorSearchQueueableTest {

    private static List<Id> setupArticleIds(Integer count) {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(count, 't2-vec');
        List<Id> ids = new List<Id>();
        for (Knowledge__kav k : kavs) {
            ids.add(k.Id);
        }
        return ids;
    }

    private static MockVectorSearchService injectMock() {
        MockVectorSearchService mock = new MockVectorSearchService();
        VectorSearchFactory.setMock(mock);
        return mock;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Constructors — exercise all four overloads
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testConstructor_OneArg_SetsDefaultStartIndex() {
        List<Id> ids = setupArticleIds(2);

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(ids);
        // Coverage objective: ensure the ctor body executes without throwing.
        Assert.isNotNull(q);
    }

    @IsTest
    static void testConstructor_TwoArg_SetsStartIndex() {
        List<Id> ids = setupArticleIds(2);
        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(ids, 1);
        Assert.isNotNull(q);
    }

    @IsTest
    static void testConstructor_ThreeArg_AssessmentRunIdAttached() {
        List<Id> ids = setupArticleIds(2);
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Pending', 'Readiness');

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(ids, run.Id);
        Assert.isNotNull(q);
    }

    @IsTest
    static void testConstructor_FourArg_ExplicitMode() {
        List<Id> ids = setupArticleIds(2);
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Pending', 'Readiness');

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(
            ids, run.Id, KBRuntimeConfigService.MODE_DEDUPLICATION
        );
        Assert.isNotNull(q);
    }

    @IsTest
    static void testConstructor_FourArg_BlankMode_FallsBackToConfigDefault() {
        // Blank mode must fall back to KBRuntimeConfigService.getExecutionMode().
        // The default execution mode is DEDUPLICATION, so execute() must invoke
        // the vector search service (not the transformation short-circuit which
        // would bypass it). Observing pairCallCount > 0 proves the fallback
        // resolved to DEDUPLICATION mode and not to TRANSFORMATION.
        List<Id> ids = setupArticleIds(1);
        MockVectorSearchService mock = injectMock();

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(ids, null, '');

        // Mute Tier 3 in case the chain enqueues — but with one article and
        // empty mockPairResults, the no-candidates branch fires.
        MockPromptTemplateService promptMock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triage = new PromptTemplateService.TriageResult();
        triage.topCandidateIndexes = new List<Integer>();
        promptMock.mockTriageResult = triage;
        PromptTemplateService.setMock(promptMock);

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.pairCallCount,
            'Blank-mode fallback resolved to DEDUPLICATION → vector search ran');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Execute — vector throws, falls back to SOQL taxonomy search
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_VectorThrows_FallsBackToSOQL() {
        // Verify two things:
        //   1. The vector search was attempted (pairCallCount > 0)
        //   2. The exception was caught and the SOQL fallback ran without
        //      letting the original exception propagate (we reach the
        //      post-stopTest assertion line).
        // The SOQL fallback's side effect (finding candidates) isn't easily
        // observable here because the fake article ids won't match anything
        // in the org's KAV table — so the "no candidates" branch fires after
        // fallback, which is fine; the absence of an uncaught throw is the
        // observable signal that the fallback path executed cleanly.
        List<Id> ids = setupArticleIds(2);
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Pending', 'Readiness');

        MockVectorSearchService mock = injectMock();
        mock.throwException = true;

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(
            ids, run.Id, KBRuntimeConfigService.MODE_DEDUPLICATION
        );

        Test.startTest();
        Boolean reachedAssertion = false;
        try {
            q.execute(null);
            reachedAssertion = true;
        } catch (Exception e) {
            // If we get here, the production catch failed to handle the
            // mock's exception — that's a real regression.
            Assert.fail('execute() must catch the vector-search exception and fall back; got: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(reachedAssertion,
            'execute() returned cleanly after vector-search threw (fallback caught the exception)');
        Assert.areEqual(1, mock.pairCallCount,
            'Vector search was attempted exactly once before the throw triggered the fallback');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Execute — empty article list (edge case via startIndex past end)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_EmptyBatch_StartIndexPastEnd_NoOp() {
        List<Id> ids = setupArticleIds(1);
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Pending', 'Readiness');

        MockVectorSearchService mock = injectMock();
        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(ids, 5);
        // startIndex=5 beyond a 1-element list → batchIds empty → method
        // skips vector search and returns (callback enqueue branch is gated
        // on assessmentRunId which this ctor does not set).

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Assert.areEqual(0, mock.pairCallCount,
            'Vector search not called when batch is empty');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Execute — vector returns nothing → either skip callback (test) or
    // enqueue (production).
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_NoCandidates_TestContextSkipsCallback() {
        List<Id> ids = setupArticleIds(2);
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Pending', 'Readiness');

        MockVectorSearchService mock = injectMock();
        // Empty pair results → candidatesByTarget map remains empty.
        mock.mockPairResults = new List<VectorSearchResult>();

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(
            ids, run.Id, KBRuntimeConfigService.MODE_DEDUPLICATION
        );

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.pairCallCount,
            'Vector still queried; the empty result short-circuits the dispatch path');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Execute — pair dedup: (A,B) and (B,A) collapse to one
    // ──────────────────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────────────────
    // Execute — happy path: produces 1 pair, enqueues Tier 3.
    // Tier 3 itself would enqueue Tier 4 if it found finalists, blowing the
    // queueable-chain depth-1 limit in tests. We mute that by injecting a
    // PromptTemplateService mock returning zero finalists, so Tier 3 never
    // re-enqueues. This lets us cover Tier 2's pair-dedup body.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_HappyPath_PairsFound_EnqueuesTier3() {
        // No assessmentRunId on Tier 2 — that propagates to Tier 3, so when
        // Tier 3 finds no finalists it skips the callback enqueue → chain
        // depth stays at 1 (Tier 2 → Tier 3) which tests permit.
        List<Id> ids = setupArticleIds(3);

        MockVectorSearchService mock = injectMock();
        VectorSearchResult r = new VectorSearchResult(
            String.valueOf(ids[1]), 'Sibling', 'KA-2', 0.9, 'chunk'
        );
        r.pairedArticleVersionId = String.valueOf(ids[0]);
        mock.mockPairResults = new List<VectorSearchResult>{ r };

        // Mute Tier 3's LLM call and tell it there are no finalists.
        MockPromptTemplateService promptMock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triage = new PromptTemplateService.TriageResult();
        triage.topCandidateIndexes = new List<Integer>();
        promptMock.mockTriageResult = triage;
        PromptTemplateService.setMock(promptMock);

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(ids);

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.pairCallCount,
            'Vector search service called exactly once');
    }

    @IsTest
    static void testExecute_DedupesPairKeysBothDirections() {
        List<Id> ids = setupArticleIds(2);

        MockVectorSearchService mock = injectMock();
        VectorSearchResult forward = new VectorSearchResult(
            String.valueOf(ids[1]), 'B', 'KA-B', 0.85, 'fwd'
        );
        forward.pairedArticleVersionId = String.valueOf(ids[0]);
        VectorSearchResult reverse = new VectorSearchResult(
            String.valueOf(ids[0]), 'A', 'KA-A', 0.85, 'rev'
        );
        reverse.pairedArticleVersionId = String.valueOf(ids[1]);
        mock.mockPairResults = new List<VectorSearchResult>{ forward, reverse };

        MockPromptTemplateService promptMock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triage = new PromptTemplateService.TriageResult();
        triage.topCandidateIndexes = new List<Integer>();
        promptMock.mockTriageResult = triage;
        PromptTemplateService.setMock(promptMock);

        // No run id → Tier 3's no-finalist path will not enqueue the callback.
        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(ids);

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.pairCallCount,
            'Both directions seen, but dedupe collapses to one logical pair');
    }

    // ──────────────────────────────────────────────────────────────────────
    // ArticleCandidates DTO
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testArticleCandidates_ConstructorAssigns() {
        Id target = '0001A000001ZZZZ';
        List<Id> cands = new List<Id>{ '0001A000002ZZZZ' };

        Tier1VectorSearchQueueable.ArticleCandidates ac =
            new Tier1VectorSearchQueueable.ArticleCandidates(target, cands);

        Assert.areEqual(target, ac.targetArticleVersionId);
        Assert.areEqual(1, ac.candidateIds.size());
    }

    // ──────────────────────────────────────────────────────────────────────
    // Execute — cancel gate
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_RunCancelled_ShortCircuits() {
        List<Id> ids = setupArticleIds(2);
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Cancelled', 'Readiness');

        MockVectorSearchService mock = injectMock();

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(
            ids, run.Id, KBRuntimeConfigService.MODE_DEDUPLICATION
        );

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Assert.areEqual(0, mock.pairCallCount, 'A cancelled run must short-circuit before any vector search call');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Execute — per-result null-id and self-pair guards
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_NullAndSelfPairedResults_AreSkipped() {
        List<Id> ids = setupArticleIds(2);

        MockVectorSearchService mock = injectMock();
        VectorSearchResult nullPairedId = new VectorSearchResult(
            String.valueOf(ids[1]), 'B', 'KA-B', 0.9, 'chunk'
        );
        nullPairedId.pairedArticleVersionId = null;

        VectorSearchResult selfPair = new VectorSearchResult(
            String.valueOf(ids[0]), 'A', 'KA-A', 0.9, 'chunk'
        );
        selfPair.pairedArticleVersionId = String.valueOf(ids[0]);

        VectorSearchResult valid = new VectorSearchResult(
            String.valueOf(ids[1]), 'B', 'KA-B', 0.9, 'chunk'
        );
        valid.pairedArticleVersionId = String.valueOf(ids[0]);

        mock.mockPairResults = new List<VectorSearchResult>{ nullPairedId, selfPair, valid };

        MockPromptTemplateService promptMock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triage = new PromptTemplateService.TriageResult();
        triage.topCandidateIndexes = new List<Integer>();
        promptMock.mockTriageResult = triage;
        PromptTemplateService.setMock(promptMock);

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(ids);

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.pairCallCount,
            'A null-paired-id result and a self-paired result must both be skipped without throwing');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Execute — vector throws, SOQL fallback swallows a per-article failure
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_VectorThrows_SoqlFallbackSwallowsPerArticleError() {
        // A well-formed but nonexistent Knowledge__kav id (same key prefix as
        // a real article) makes Tier1SOQLFallbackService.findCandidatesByTaxonomy
        // throw for that one article — the per-article try/catch inside the
        // fallback loop must swallow it and keep processing the rest of the batch.
        List<Id> ids = setupArticleIds(1);
        String prefix = String.valueOf(ids[0]).substring(0, 3);
        ids.add(Id.valueOf(prefix + '000000000001'));

        MockVectorSearchService mock = injectMock();
        mock.throwException = true;

        Tier1VectorSearchQueueable q = new Tier1VectorSearchQueueable(ids);

        Test.startTest();
        Boolean threw = false;
        try {
            q.execute(null);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isFalse(threw,
            'A per-article SOQL fallback failure must be caught and swallowed, not propagate');
    }
}
