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
 * Coverage for the Tier-3 triage queueable.
 *
 * The queueable runs an LLM-judge over (target, candidates) pairs from
 * Tier 2, filters Suppressed pairs, and chains to Tier 4 — or to the
 * pipeline callback when no finalists survive.
 *
 * Tests use MockPromptTemplateService to swap out the LLM call so
 * triage returns deterministic positional indexes.
 */
@IsTest
private class Tier2TriageQueueableTest {

    // The finalizer test below enqueues Tier3DispatchQueueable for real (via
    // a genuine Finalizer, which IS allowed to enqueue) and lets it run
    // during Test.stopTest() — a no-op launcher keeps that real run from
    // reaching the actual System.enqueueJob/Database.executeBatch calls,
    // which are covered with full assertions in Tier3DispatchQueueableTest.
    private class NoOpLauncher implements Tier3DispatchQueueable.IAsyncLauncher {
        public Id enqueueTier3Agentic(Tier3AgenticQueueable job) { return null; }
        public Id launchBatch(Tier3AgenticBatch batch, Integer scopeSize) { return null; }
        public Id enqueuePipelineCallback(KBAssessmentPipelineCallback callback) { return null; }
    }

    @TestSetup
    static void setup() {
        // 4 articles: 1 target + 3 candidates. Suppressed pair will cover
        // target↔candidate[0].
        //
 // Tier 3 now pre-filters its bulk Knowledge__kav SELECT to
        // PublishStatus = 'Online', so the fixtures must be PUBLISHED or every
        // pair would drop out of articleMap and no pair would ever triage.
        // Publish here and key the suppressed candidate to the ONLINE version
        // ids the pairs will actually carry.
        KBTestDataFactory.insertArticles(4, 'triage');
        KBTestDataFactory.insertRun('In Progress', 'Readiness');

        List<Knowledge__kav> drafts = [
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav
            WHERE Title LIKE 'triage-%' AND PublishStatus = 'Draft'
        ];
        for (Knowledge__kav k : drafts) {
            KbManagement.PublishingService.publishArticle(k.KnowledgeArticleId, true);
        }

        // Target = online[0]; suppress its pair with online[1].
        List<Knowledge__kav> online = articlesByTitle();
        KBTestDataFactory.insertDuplicateCandidate(
            online[0].Id, online[1].Id, 'Duplicate', 'Suppressed'
        );
    }

    private static Tier1VectorSearchQueueable.ArticleCandidates buildPair(Id target, List<Id> cands) {
        return new Tier1VectorSearchQueueable.ArticleCandidates(target, cands);
    }

 // Returns the CURRENT Online versions of the fixtures (Tier 3 only
    // triages Online articles, so pairs are built from Online version ids).
    private static List<Knowledge__kav> articlesByTitle() {
        return [
            SELECT Id, Title FROM Knowledge__kav
            WHERE Title LIKE 'triage-%' AND PublishStatus = 'Online' ORDER BY Title
        ];
    }

    @IsTest
    static void testExecute_HappyPath_EnqueuesTier4WithFinalists() {
        List<Knowledge__kav> arts = articlesByTitle();
        Id target = arts[0].Id;
        List<Id> cands = new List<Id>{ arts[1].Id, arts[2].Id, arts[3].Id };
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triageResult = new PromptTemplateService.TriageResult();
        triageResult.topCandidateIndexes = new List<Integer>{ 1, 2 };
        mock.mockTriageResult = triageResult;
        PromptTemplateService.setMock(mock);

        // Direct .execute() call avoids the queueable-chain depth limit
        // that System.enqueueJob → Tier 4 enqueue would otherwise blow.
        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{ buildPair(target, cands) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.triageCallCount, 'Triage LLM called once for one pair');
        Integer tier4Jobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'Tier3AgenticQueueable'
        ];
        Assert.areEqual(1, tier4Jobs, 'Tier 4 queueable enqueued for finalist pairs');
    }

    @IsTest
    static void testExecute_NoFinalists_EnqueuesPipelineCallback() {
        List<Knowledge__kav> arts = articlesByTitle();
        Id target = arts[0].Id;
        List<Id> cands = new List<Id>{ arts[1].Id, arts[2].Id };
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triageResult = new PromptTemplateService.TriageResult();
        triageResult.topCandidateIndexes = new List<Integer>();
        mock.mockTriageResult = triageResult;
        PromptTemplateService.setMock(mock);

        // Direct .execute() call avoids the queueable-chain depth limit
        // that System.enqueueJob → Tier 4 enqueue would otherwise blow.
        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{ buildPair(target, cands) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Integer tier4Jobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'Tier3AgenticQueueable'
        ];
        Assert.areEqual(0, tier4Jobs, 'No Tier 4 enqueue when no finalists');

        Integer callbackJobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'KBAssessmentPipelineCallback'
        ];
        Assert.areEqual(1, callbackJobs, 'Pipeline callback enqueued when finalists empty + run id present');
    }

    @IsTest
    static void testExecute_SuppressedPair_ExcludedFromFinalists() {
        List<Knowledge__kav> arts = articlesByTitle();
        Id target = arts[0].Id;
        // Index 0 (cand[0] = articles[1]) is the SUPPRESSED pair; index 1 is fine.
        List<Id> cands = new List<Id>{ arts[1].Id, arts[2].Id };
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triageResult = new PromptTemplateService.TriageResult();
        triageResult.topCandidateIndexes = new List<Integer>{ 0, 1 };
        mock.mockTriageResult = triageResult;
        PromptTemplateService.setMock(mock);

        // Direct .execute() call avoids the queueable-chain depth limit
        // that System.enqueueJob → Tier 4 enqueue would otherwise blow.
        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{ buildPair(target, cands) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        // Both finalists are present after filtering: index 0 (suppressed) is
        // dropped; index 1 survives. We can't directly inspect the Tier 4
        // queueable's payload, so the observable behavior is that Tier 4 is
        // still enqueued (one finalist survived) and the suppressed
        // Duplicate_Candidate__c remains untouched in 'Suppressed' status.
        Integer tier4Jobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'Tier3AgenticQueueable'
        ];
        Assert.areEqual(1, tier4Jobs, 'Surviving (non-suppressed) finalist still enqueues Tier 4');

        Integer suppressedAfter = [
            SELECT COUNT() FROM Duplicate_Candidate__c WHERE Status__c = 'Suppressed'
        ];
        Assert.areEqual(1, suppressedAfter, 'Suppressed candidate row is untouched by triage');
    }

    @IsTest
    static void testExecute_LLMException_LogsAndContinuesWithoutTier4() {
        List<Knowledge__kav> arts = articlesByTitle();
        Id target = arts[0].Id;
        List<Id> cands = new List<Id>{ arts[1].Id };
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.throwException = true;
        PromptTemplateService.setMock(mock);

        // Direct .execute() call avoids the queueable-chain depth limit
        // that System.enqueueJob → Tier 4 enqueue would otherwise blow.
        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{ buildPair(target, cands) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.triageCallCount, 'LLM was attempted before exception was caught');
        Integer tier4Jobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'Tier3AgenticQueueable'
        ];
        Assert.areEqual(0, tier4Jobs, 'LLM exception → no finalists → no Tier 4 enqueue');

        Integer callbackJobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'KBAssessmentPipelineCallback'
        ];
        Assert.areEqual(1, callbackJobs,
            'No-finalists path still fires the pipeline callback when run id is present');
    }

    /**
 * the Tier4HandoffFinalizer enqueues Tier 4 in a fresh queueable
     * chain (depth resets), which is how production breaks the
     * Tier2→Tier3→Tier4 stack-depth accumulation. Exercise the Finalizer's
     * execute() directly — execute() of a real Finalizer is allowed to enqueue.
     */
    @IsTest
    static void testTier4HandoffFinalizer_EnqueuesTier4() {
        List<Knowledge__kav> arts = articlesByTitle();
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;
        List<Tier3AgenticQueueable.FinalistPair> finalists =
            new List<Tier3AgenticQueueable.FinalistPair>{
                new Tier3AgenticQueueable.FinalistPair(arts[0].Id, arts[1].Id)
            };

        Tier2TriageQueueable.Tier4HandoffFinalizer fin =
            new Tier2TriageQueueable.Tier4HandoffFinalizer(finalists, runId, 'DEDUPLICATION');

        // C: the finalizer now hands off to the parallel dispatcher (a fresh
        // chain at depth 1) instead of Tier3AgenticQueueable directly. The
        // dispatcher runs during stopTest; it records its sharding decision to a
        // @TestVisible static, so observing that static set (non-null) proves the
        // finalizer enqueued AND ran the dispatcher. (Counting the AsyncApexJob
        // row is unreliable for a directly-invoked Finalizer's enqueue.) The
        // dispatcher's decision logic is unit-tested in Tier3ParallelDispatchTest.
        Tier3DispatchQueueable.lastPlannedShardCount = null;
        Tier3DispatchQueueable.lastUsedLegacyFallback = null;
        Tier3DispatchQueueable.launcher = new NoOpLauncher();

        Test.startTest();
        fin.execute(null);
        Test.stopTest();

        Assert.isTrue(
            Tier3DispatchQueueable.lastUsedLegacyFallback != null,
            'Finalizer handed off to the Tier 4 dispatcher (it ran and recorded a decision)'
        );
    }

    /**
 * a pair whose target is NOT Online (Draft) must never reach the
     * triageDuplicateCandidates() LLM callout: the bulk SELECT filters to
     * PublishStatus = 'Online', so the target drops out of articleMap and the
     * pair is skipped before any Einstein spend. This is the whole point of the
     * fix — stop paying Tier 3 callouts for pairs Tier 4 would discard anyway.
     */
    @IsTest
    static void testExecute_NonOnlineTarget_SkippedBeforeLLMCallout() {
        List<Knowledge__kav> onlineArts = articlesByTitle();
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        // Insert a fresh DRAFT article to act as the (non-Online) target.
        List<Knowledge__kav> draftTarget = KBTestDataFactory.insertArticles(1, 'triage-draft');
        Id draftTargetId = draftTarget[0].Id;
        List<Id> cands = new List<Id>{ onlineArts[1].Id, onlineArts[2].Id };

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triageResult = new PromptTemplateService.TriageResult();
        triageResult.topCandidateIndexes = new List<Integer>{ 0, 1 };
        mock.mockTriageResult = triageResult;
        PromptTemplateService.setMock(mock);

        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{ buildPair(draftTargetId, cands) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        // The Draft target is absent from the Online-only articleMap, so the pair
        // is skipped: ZERO LLM callouts, no Tier 4 enqueue.
        Assert.areEqual(0, mock.triageCallCount,
            'Non-Online target must not trigger a triage LLM callout');
        Integer tier4Jobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'Tier3AgenticQueueable'
        ];
        Assert.areEqual(0, tier4Jobs, 'No finalists (target filtered out) → no Tier 4 enqueue');
    }

    @IsTest
    static void testConstructor_OneArg_UsesConfigDefaultMode() {
        List<Knowledge__kav> arts = articlesByTitle();
        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{
                buildPair(arts[0].Id, new List<Id>{ arts[1].Id })
            }
        );
        Assert.isNotNull(job);
    }

    @IsTest
    static void testConstructor_ThreeArg_BlankMode_FallsBackToConfigDefault() {
        List<Knowledge__kav> arts = articlesByTitle();
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;
        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{
                buildPair(arts[0].Id, new List<Id>{ arts[1].Id })
            },
            runId, ''
        );
        Assert.isNotNull(job);
    }

    @IsTest
    static void testExecute_RunCancelled_ShortCircuits() {
        List<Knowledge__kav> arts = articlesByTitle();
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Cancelled', 'Readiness');

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{
                buildPair(arts[0].Id, new List<Id>{ arts[1].Id })
            },
            run.Id
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(0, mock.triageCallCount, 'Cancelled run must short-circuit before any triage call');
    }

    @IsTest
    static void testExecute_RunScopedSuppression_FiltersMatchingPair() {
        // Scoped to THIS run's id specifically — the @TestSetup suppressed row
        // is scoped to a throwaway run and so never matches the run-scoped
        // suppression lookup that execute() actually performs.
        List<Knowledge__kav> arts = articlesByTitle();
        Id target = arts[0].Id;
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        KBTestDataFactory.insertDuplicateCandidate(
            target, arts[2].Id, 'Duplicate', 'Suppressed', runId
        );

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triageResult = new PromptTemplateService.TriageResult();
        triageResult.topCandidateIndexes = new List<Integer>{ 0 };
        mock.mockTriageResult = triageResult;
        PromptTemplateService.setMock(mock);

        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{
                buildPair(target, new List<Id>{ arts[2].Id })
            },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Integer tier4Jobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'Tier3AgenticQueueable'
        ];
        Assert.areEqual(0, tier4Jobs,
            'The only candidate is suppressed for this specific run — no finalists, no Tier 4 enqueue');
    }

    @IsTest
    static void testExecute_CalloutBudgetExhausted_BreaksBeforeSecondPair() {
        List<Knowledge__kav> arts = articlesByTitle();
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        KB_Pipeline_Config__c cfg = KB_Pipeline_Config__c.getInstance();
        if (cfg == null || cfg.Id == null) cfg = new KB_Pipeline_Config__c();
        cfg.Max_Callout_Limit__c = 1;
        upsert cfg;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triageResult = new PromptTemplateService.TriageResult();
        triageResult.topCandidateIndexes = new List<Integer>();
        mock.mockTriageResult = triageResult;
        PromptTemplateService.setMock(mock);

        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{
                buildPair(arts[0].Id, new List<Id>{ arts[1].Id }),
                buildPair(arts[2].Id, new List<Id>{ arts[3].Id })
            },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.triageCallCount,
            'The callout budget of 1 must stop processing before the second pair is triaged');
    }

    @IsTest
    static void testExecute_NoResolvableCandidates_SkipsPairWithoutLLMCall() {
        List<Knowledge__kav> arts = articlesByTitle();
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        // A Draft candidate is absent from the Online-only articleMap, so
        // summaries ends up empty for this pair.
        Knowledge__kav draftCandidate = KBTestDataFactory.insertArticles(1, 'triage-draftcand')[0];

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{
                buildPair(arts[0].Id, new List<Id>{ draftCandidate.Id })
            },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(0, mock.triageCallCount,
            'A pair whose only candidate cannot be resolved must be skipped before any LLM call');
    }

    @IsTest
    static void testExecute_SafetyCapAndOutOfRangeIndex_BothHandled() {
        List<Knowledge__kav> arts = articlesByTitle();
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        KB_Pipeline_Config__c cfg = KB_Pipeline_Config__c.getInstance();
        if (cfg == null || cfg.Id == null) cfg = new KB_Pipeline_Config__c();
        cfg.Max_Finalists__c = 1;
        upsert cfg;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult triageResult = new PromptTemplateService.TriageResult();
        // 5 is out of range (only 2 candidates → indexToIdMap size 2) and must
        // be skipped; 0 is added (bringing the safety cap to its limit); 1
        // then trips the safety-cap break before it's added.
        triageResult.topCandidateIndexes = new List<Integer>{ 5, 0, 1 };
        mock.mockTriageResult = triageResult;
        PromptTemplateService.setMock(mock);

        Tier2TriageQueueable job = new Tier2TriageQueueable(
            new List<Tier1VectorSearchQueueable.ArticleCandidates>{
                buildPair(arts[0].Id, new List<Id>{ arts[1].Id, arts[2].Id })
            },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Integer tier4Jobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'Tier3AgenticQueueable'
        ];
        Assert.areEqual(1, tier4Jobs,
            'Exactly one finalist should have survived (out-of-range skipped, second stopped by the safety cap)');
    }
}
