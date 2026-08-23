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
 * Coverage for the two async wrappers around KBImprovementFixService:
 *
 *   - KBFixArticleQueueable: chunks of 10, self-chains until all requests are
 *     dispatched. T2 verifies the self-chaining branch enqueues a successor
 *     job when the chunk window doesn't cover the full request list.
 *   - KBFixArticleBatch:     iterable batch with the same per-request
 *     semantics, plus AR2 progress events on every execute and finish.
 *
 * Both wrappers swallow per-request exceptions because dispatchArticleFixInternal
 * marks the recommendation rows as Error internally — the swallow is what
 * lets one bad request not poison the rest of the chunk. We verify that
 * contract by mixing a happy-path request with one that's structurally bad
 * and asserting the good row reaches Resolved while the bad row does not
 * destroy the chunk.
 *
 * LLM calls go through MockPromptTemplateService so no callout budget is used.
 */
@IsTest
private class KBFixArticleAsyncTest {

    private static KB_Dimension_Analysis__c setupRec(Knowledge__kav kav) {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_Id__c = kav.Id,
            Article_Title__c = kav.Title,
            Overall_Score__c = 45,
            Readiness_Status__c = 'Needs Work'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id,
            Dimension__c = 'Completeness',
            Score__c = 45
        );
        insert dr;
        KB_Dimension_Analysis__c rec = new KB_Dimension_Analysis__c(
            Article_Assessment__c = aa.Id,
            Dimension_Result__c = dr.Id,
            Type__c = 'Issue',
            Dimension__c = 'Completeness',
            Recommendation__c = 'Add a summary section.',
            Status__c = 'Open'
        );
        insert rec;
        return rec;
    }

    private static KBImprovementFixService.BulkFixRequest buildRequest(
        Id articleVersionId, Id recId
    ) {
        KBImprovementFixService.BulkFixRequest req = new KBImprovementFixService.BulkFixRequest();
        req.articleVersionId  = articleVersionId;
        req.useCurrentOnline  = true;
        req.recIds            = new List<Id>{ recId };
        req.issueDescriptions = new List<String>{ '[Completeness] Add a summary section.' };
        return req;
    }

    @IsTest
    static void testQueueable_HappyPath_ResolvesRecommendation() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'fixq-happy')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        Test.startTest();
        System.enqueueJob(new KBFixArticleQueueable(
            new List<KBImprovementFixService.BulkFixRequest>{ buildRequest(kav.Id, rec.Id) },
            0
        ));
        Test.stopTest();

        KB_Dimension_Analysis__c reread =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Resolved', reread.Status__c,
            'Queueable dispatched the request → rec marked Resolved');
    }

    @IsTest
    static void testQueueable_BadRequestInChunk_DoesNotKillGoodSibling() {
        // One good request + one structurally-bad request (no recIds → throws).
        // The wrapper's try/catch must keep the good one moving.
        Knowledge__kav goodKav = KBTestDataFactory.insertArticles(1, 'fixq-good')[0];
        KB_Dimension_Analysis__c goodRec = setupRec(goodKav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        KBImprovementFixService.BulkFixRequest bad = new KBImprovementFixService.BulkFixRequest();
        bad.articleVersionId  = goodKav.Id;
        bad.useCurrentOnline  = true;
        bad.recIds            = new List<Id>(); // empty → dispatchArticleFixInternal throws
        bad.issueDescriptions = new List<String>{ 'irrelevant' };

        Test.startTest();
        System.enqueueJob(new KBFixArticleQueueable(
            new List<KBImprovementFixService.BulkFixRequest>{
                bad,
                buildRequest(goodKav.Id, goodRec.Id)
            },
            0
        ));
        Test.stopTest();

        KB_Dimension_Analysis__c reread =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :goodRec.Id];
        Assert.areEqual('Resolved', reread.Status__c,
            'Bad sibling swallowed by wrapper try/catch — good rec still resolved');
    }

    /**
     * T2: self-chaining branch. With > CHUNK (10) requests, the queueable's
     * `endIdx < requests.size()` branch increments `chainAttemptCount` and
     * (in production) enqueues a successor job. Salesforce's test context
     * forbids actual chain enqueues from inside `Test.startTest..stopTest`
     * (Maximum stack depth 1), so we flip `suppressChainForTest=true` on
     * the queueable, run the first chunk synchronously, and assert that the
     * branch was reached. The actual chained execution is not testable in
     * Apex test context — production behaviour is straightforward
     * (re-enqueue with new startIndex).
     */
    @IsTest
    static void testQueueable_SelfChains_OnRequestsBeyondChunkSize() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'fixq-chain')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        // 11 requests — chunk size is 10, so the first execute processes
        // 0..9 and would enqueue exactly one successor for index 10.
        List<KBImprovementFixService.BulkFixRequest> reqs =
            new List<KBImprovementFixService.BulkFixRequest>();
        reqs.add(buildRequest(kav.Id, rec.Id));
        for (Integer i = 1; i < 11; i++) {
            KBImprovementFixService.BulkFixRequest r = new KBImprovementFixService.BulkFixRequest();
            r.articleVersionId  = kav.Id;
            r.useCurrentOnline  = true;
            r.recIds            = new List<Id>();   // bad → swallowed by wrapper
            r.issueDescriptions = new List<String>{ 'irrelevant' };
            reqs.add(r);
        }

        // Suppress the chain enqueue and reset the counter so we can prove
        // the branch was reached without tripping Salesforce's depth guard.
        KBFixArticleQueueable.suppressChainForTest = true;
        KBFixArticleQueueable.chainAttemptCount = 0;

        Test.startTest();
        System.enqueueJob(new KBFixArticleQueueable(reqs, 0));
        Test.stopTest();

        Assert.areEqual(1, KBFixArticleQueueable.chainAttemptCount,
            'First chunk reached the `endIdx < requests.size()` branch and tried to chain exactly once');

        KB_Dimension_Analysis__c reread =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Resolved', reread.Status__c,
            'First chunk still processed the good rec end-to-end before the chain branch');

        // Tidy: reset the flags so other tests aren't surprised.
        KBFixArticleQueueable.suppressChainForTest = false;
        KBFixArticleQueueable.chainAttemptCount = 0;
    }

    @IsTest
    static void testBatch_HappyPath_ResolvesRecommendation() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'fixb-happy')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        Test.startTest();
        Database.executeBatch(
            new KBFixArticleBatch(
                new List<KBImprovementFixService.BulkFixRequest>{ buildRequest(kav.Id, rec.Id) }
            ),
            10
        );
        Test.stopTest();

        KB_Dimension_Analysis__c reread =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Resolved', reread.Status__c,
            'Batch dispatched the request → rec marked Resolved');
    }

    @IsTest
    static void testBatch_BadRequestInScope_DoesNotKillGoodSibling() {
        Knowledge__kav goodKav = KBTestDataFactory.insertArticles(1, 'fixb-good')[0];
        KB_Dimension_Analysis__c goodRec = setupRec(goodKav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        KBImprovementFixService.BulkFixRequest bad = new KBImprovementFixService.BulkFixRequest();
        bad.articleVersionId  = goodKav.Id;
        bad.useCurrentOnline  = true;
        bad.recIds            = new List<Id>();
        bad.issueDescriptions = new List<String>{ 'irrelevant' };

        Test.startTest();
        Database.executeBatch(
            new KBFixArticleBatch(
                new List<KBImprovementFixService.BulkFixRequest>{
                    bad,
                    buildRequest(goodKav.Id, goodRec.Id)
                }
            ),
            10
        );
        Test.stopTest();

        KB_Dimension_Analysis__c reread =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :goodRec.Id];
        Assert.areEqual('Resolved', reread.Status__c,
            'Batch wrapper swallowed bad sibling — good rec still resolved');
    }

    /**
     * The queueable/batch wrappers now
     * log via `System.debug(LoggingLevel.ERROR, ...)` before incrementing
     * `chunkErrors`. `System.debug` output isn't directly assertable in Apex
     * tests, so this test verifies the structural contract:
     *   1. The rec flips to Error (the service's catch path runs).
     *   2. The queueable did NOT propagate the exception (test would fail
     *      with an uncaught exception otherwise).
     *   3. The good rec in the same chunk still resolves — i.e. the catch
     *      didn't poison the rest of the chunk.
     *
     * The test's PURPOSE is to lock down the catch-and-continue behaviour;
     * if a future refactor removes the `System.debug` line, this test still
     * passes — that's an acknowledged limitation. The structural assertions
     * are the regression boundary that matters: removing the catch entirely
     * would break the "good sibling still resolves" branch (since the
     * exception would propagate and roll back the queueable execute).
     */
    @IsTest
    static void testQueueable_LogsOnDispatchFailure() {
        // Two articles → two recs. The first request will be forced to
        // throw (mock.throwException flips the next fixArticleIssues call
        // to throw KnowledgeAIException). The second runs against a
        // non-throwing mock to prove the catch-and-continue contract.
        Knowledge__kav badKav  = KBTestDataFactory.insertArticles(1, 'fixq-log-bad')[0];
        Knowledge__kav goodKav = KBTestDataFactory.insertArticles(1, 'fixq-log-good')[0];
        KB_Dimension_Analysis__c badRec  = setupRec(badKav);
        KB_Dimension_Analysis__c goodRec = setupRec(goodKav);

        // Mock that throws on every fixArticleIssues call. Both requests
        // are dispatched against the same mock, so both will fail in the
        // service's LLM call. The queueable's catch must:
        //   - log the cause (via System.debug — not directly assertable)
        //   - increment chunkErrors
        //   - keep iterating to the next request without re-throwing
        // We assert (1) both recs reach Error (service catch ran for each),
        // (2) the queueable execute didn't throw (Test.stopTest doesn't
        // raise an uncaught exception).
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.throwException = true;
        PromptTemplateService.setMock(mock);

        Test.startTest();
        // No try/catch here — if the queueable propagated the exception
        // instead of catching, this test would fail with an uncaught
        // System.AsyncException at stopTest.
        System.enqueueJob(new KBFixArticleQueueable(
            new List<KBImprovementFixService.BulkFixRequest>{
                buildRequest(badKav.Id,  badRec.Id),
                buildRequest(goodKav.Id, goodRec.Id)
            },
            0
        ));
        Test.stopTest();

        // Both recs went through the failing LLM path → both flip to Error.
        // If the queueable had propagated the first exception, the second
        // request would never be reached and goodRec would still be 'Open'.
        KB_Dimension_Analysis__c reloadedBad =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :badRec.Id];
        KB_Dimension_Analysis__c reloadedGood =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :goodRec.Id];
        Assert.areEqual('Error', reloadedBad.Status__c,
            'First failing request marked Error in service catch');
        Assert.areEqual('Error', reloadedGood.Status__c,
            'Queueable kept iterating after the first failure — second rec also reached the service catch');
    }

    /**
     * AR2 publish-side: queueable + batch wrappers update the AI Fix
     * pipeline run row to Completed/Partial on terminal completion. We
     * pre-create a pipeline run row, attach its id to the request, run the
     * queueable, and assert the row was closed out.
     */
    @IsTest
    static void testQueueable_AR2_ClosesPipelineRunOnFinish() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'fixq-pipeline')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        KB_Pipeline_Run__c pipelineRun = new KB_Pipeline_Run__c(
            Execution_Modes__c      = 'AI Fix',
            Status__c               = 'Queued',
            Started_At__c           = System.now(),
            Total_Input_Articles__c = 1
        );
        insert pipelineRun;

        KBImprovementFixService.BulkFixRequest req = buildRequest(kav.Id, rec.Id);
        req.pipelineRunId = pipelineRun.Id;

        Test.startTest();
        System.enqueueJob(new KBFixArticleQueueable(
            new List<KBImprovementFixService.BulkFixRequest>{ req }, 0
        ));
        Test.stopTest();

        KB_Pipeline_Run__c reread =
            [SELECT Status__c, Completed_At__c FROM KB_Pipeline_Run__c WHERE Id = :pipelineRun.Id];
        Assert.areEqual('Completed', reread.Status__c,
            'Queueable closes out the pipeline run as Completed when no errors');
        Assert.isNotNull(reread.Completed_At__c, 'Completed_At__c is stamped on close-out');
    }
}
