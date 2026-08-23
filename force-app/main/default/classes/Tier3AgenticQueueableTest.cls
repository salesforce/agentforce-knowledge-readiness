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
 * Coverage for Tier-4 agentic queueable: extract facts → compare → flag/clear
 * pairs into Duplicate_Candidate__c, recording each evaluation in
 * Knowledge_Pair_Evaluation__c.
 *
 * We exercise execute() directly with a null QueueableContext to avoid
 * the queueable-chain depth limit; the production code never reads the
 * context object.
 */
@IsTest
private class Tier3AgenticQueueableTest {

    @TestSetup
    static void setup() {
        // 6 Knowledge__kav rows: 3 target/finalist pairs.
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(6, 'tier4');
        // Give them non-blank bodies so buildArticleBody returns content.
        for (Knowledge__kav k : arts) {
            k.Summary = 'This is a useful article about a topic. '
                + 'It has multiple sentences and paragraphs to chunk.\n\n'
                + 'Second paragraph with extra content for chunk testing.';
        }
        update arts;

        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 6,
            Used_LLM__c = true,
            Assessment_Types__c = 'Readiness'
        );
        insert run;

        KB_Pipeline_Run__c pr = KBTestDataFactory.insertPipelineRun(run.Id, 'DEDUPLICATION', 'Running');
        run.Pipeline_Run__c = pr.Id;
        update run;
    }

    // Seeds a "this pair was already evaluated" cache row for the published
    // (Online) version ids of articles a/b — keyed the way Tier 4 keys it. The
    // pair-eval row must use the SAME version ids the test pairs on, so this is
    // built per-test (after getOnlineArticles() publishes), not in @TestSetup.
    private static void seedCachedEvaluation(Id a, Id b) {
        KB_Pipeline_Run__c pr = [SELECT Id FROM KB_Pipeline_Run__c LIMIT 1];
        insert new Knowledge_Pair_Evaluation__c(
 // KPE key is pipeline-run-scoped; seed the same scoped key the
            // evaluator now looks up, or the cache-skip path wouldn't be exercised.
            Composite_Version_Key__c =
                KnowledgeAIGovernanceService.generatePipelineEvaluationKey(a, b, pr.Id),
            Evaluation_Status__c = 'Clear',
            Evaluated_Date__c = Datetime.now(),
            Pipeline_Run__c = pr.Id,
            Evaluation_Domain__c = KnowledgeAIGovernanceService.EVALUATION_DOMAIN_PIPELINE
        );
    }

    // Publishes the 6 fixtures and returns their CURRENT Online versions.
 // NAME NOTE: this has a DML side effect (it publishes)—: Tier 4 only
    // compares published articles, so the eval-path tests need Online pairs.
    // Publishing happens here (test-method context) rather than @TestSetup,
    // because KbManagement.PublishingService is not permitted during @TestSetup.
    // Idempotent: once published, the rows are already Online and re-querying
    // just returns them.
    private static List<Knowledge__kav> getOnlineArticles() {
        List<Knowledge__kav> drafts = [
            SELECT KnowledgeArticleId FROM Knowledge__kav
            WHERE Title LIKE 'tier4-%' AND PublishStatus = 'Draft'
        ];
        if (!drafts.isEmpty()) {
            for (Knowledge__kav k : drafts) {
                KbManagement.PublishingService.publishArticle(k.KnowledgeArticleId, true);
            }
        }
        return [
            SELECT Id, Title, Summary, KnowledgeArticleId
            FROM Knowledge__kav
            WHERE Title LIKE 'tier4-%' AND PublishStatus = 'Online'
            ORDER BY Title
        ];
    }

    private static Id getRunId() {
        return [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;
    }

    private static Tier3AgenticQueueable.FinalistPair pair(Id a, Id b) {
        return new Tier3AgenticQueueable.FinalistPair(a, b);
    }

    @IsTest
    static void testExecute_EmptyPairs_EnqueuesCallback() {
        Id runId = getRunId();
        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>(), runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        // Empty input + assessmentRunId set → System.schedule fires the
        // callback trampoline; trampoline runs (during stopTest) and aborts
        // its own cron, then enqueues KBAssessmentPipelineCallback. We
        // observe the resulting AsyncApexJob row.
        Integer queued = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable' AND ApexClass.Name = 'KBAssessmentPipelineCallback'
        ];
        Assert.areEqual(1, queued, 'Empty pairs path schedules the callback trampoline');
    }

    @IsTest
    static void testExecute_SelfPair_Skipped() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        // Self-pair only → executor should skip and emit no DML.
        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(arts[0].Id, arts[0].Id) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(0, mock.factEvalCallCount, 'Self-pair never reaches the LLM');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Duplicate_Candidate__c],
            'Self-pair produces no Duplicate_Candidate__c');
    }

 // a pair where either side is NOT currently published (Draft, here)
    // must be skipped before the LLM and must never write a Duplicate_Candidate__c,
    // even when the LLM would have flagged it. The gate is status-only
    // (!isOnline → skip) and never inspects KnowledgeArticleId, so this single
    // Draft case covers the whole class the bug came from: a superseded prior
    // version (Archived) or a draft-in-progress of the same article — any
    // non-Online side fails the gate identically and is never flagged as a
    // duplicate of the current published version.
    @IsTest
    static void testExecute_NonPublishedPair_Skipped() {
        List<Knowledge__kav> arts = getOnlineArticles(); // all Online
        Id runId = getRunId();

        // A fresh Draft article. Use a prefix that does NOT match 'tier4-%' so
        // a later getOnlineArticles() call could never sweep it up and publish it.
        Knowledge__kav draft = KBTestDataFactory.insertArticles(1, 'draftonly')[0];
        draft.Summary = 'Draft body with enough sentences to chunk. '
            + 'Second sentence to ensure a non-blank body.';
        update draft;

        // Mock an LLM result that WOULD flag — proving the skip is the gate,
        // not a low-confidence/clear evaluation.
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult flagged = new PromptTemplateService.FactEvaluationResult();
        flagged.isDuplicate = true;
        flagged.confidenceScore = 95;
        flagged.reasoning = 'Would flag if it ever reached the LLM.';
        flagged.anomalyType = 'Duplicate';
        mock.mockFactEvalResult = flagged;
        mock.mockExtractedFacts = '- Fact A\n- Fact B';
        PromptTemplateService.setMock(mock);

        // Pair an Online article with the Draft → gate must skip the pair.
        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(arts[2].Id, draft.Id) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(0, mock.factEvalCallCount,
            'Non-published pair never reaches the LLM (skipped by the publish-status gate)');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Duplicate_Candidate__c],
            'Non-published pair produces no Duplicate_Candidate__c');
    }

    @IsTest
    static void testExecute_FlaggedPair_UpsertsDuplicateCandidate() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult flagged = new PromptTemplateService.FactEvaluationResult();
        flagged.isDuplicate = true;
        flagged.confidenceScore = 85;
        flagged.reasoning = 'Both articles describe the same procedure.';
        flagged.anomalyType = 'Duplicate';
        mock.mockFactEvalResult = flagged;
        mock.mockExtractedFacts = '- Fact A\n- Fact B';
        PromptTemplateService.setMock(mock);

        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(arts[2].Id, arts[3].Id) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.factEvalCallCount, 'Root agent compared facts once');
        List<Duplicate_Candidate__c> dcs = [
            SELECT Id, Confidence_Score__c, Flag_Type__c, Status__c
            FROM Duplicate_Candidate__c
            WHERE Source_Tier__c = 'Tier4_Agentic'
        ];
        Assert.areEqual(1, dcs.size(), 'Flagged pair upserts a Duplicate_Candidate__c');
        Assert.areEqual(85, dcs[0].Confidence_Score__c, 'Confidence score stamped');
        Assert.areEqual('Duplicate', dcs[0].Flag_Type__c, 'Flag type from LLM');
        Assert.areEqual('Pending', dcs[0].Status__c, 'New row defaults to Pending');
    }

 // review (finding #1) — a re-detected pair must NOT flip a human-triaged
    // (Rejected/Resolved) candidate back to Pending. attachExistingIdsForRunScopedUpsert
    // only reuses Pending rows, so the triaged row survives and a fresh Pending
    // row is created for the new detection.
    @IsTest
    static void testExecute_ReDetectedPair_DoesNotOverwriteTriagedCandidate() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        // A human-Rejected candidate already exists for this exact pair (same
        // composite key Tier 4 will compute for arts[2]/arts[3]).
        String compositeKey = KnowledgeAIGovernanceService.generateCompositeKey(arts[2].Id, arts[3].Id);
        Duplicate_Candidate__c rejected = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = arts[2].Id, Knowledge_Article_2__c = arts[3].Id,
            Composite_Key__c = compositeKey, Flag_Type__c = 'Duplicate', Status__c = 'Rejected',
            Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Assessment_Run__c = runId
        );
        insert rejected;

        // LLM would flag the pair again.
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult flagged = new PromptTemplateService.FactEvaluationResult();
        flagged.isDuplicate = true;
        flagged.confidenceScore = 90;
        flagged.anomalyType = 'Duplicate';
        mock.mockFactEvalResult = flagged;
        mock.mockExtractedFacts = '- Fact A';
        PromptTemplateService.setMock(mock);

        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(arts[2].Id, arts[3].Id) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        // The Rejected row is untouched (still Rejected).
        Assert.areEqual('Rejected',
            [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :rejected.Id].Status__c,
            'Re-detection must not flip a human-Rejected candidate back to Pending');
    }

    @IsTest
    static void testExecute_BelowThreshold_StoresEvaluationOnly() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult clear = new PromptTemplateService.FactEvaluationResult();
        clear.isDuplicate = true;
        clear.confidenceScore = 30; // below default 50% threshold
        clear.reasoning = 'Some similarity but not duplicates.';
        clear.anomalyType = 'Duplicate';
        mock.mockFactEvalResult = clear;
        PromptTemplateService.setMock(mock);

        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(arts[2].Id, arts[3].Id) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.factEvalCallCount, 'LLM was consulted');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Duplicate_Candidate__c WHERE Source_Tier__c = 'Tier4_Agentic'],
            'Below-threshold pair NOT promoted to Duplicate_Candidate__c');
        Assert.isTrue(
            [SELECT COUNT() FROM Knowledge_Pair_Evaluation__c WHERE Evaluation_Status__c = 'Clear'] >= 1,
            'Pair-evaluation row recorded as Clear');
    }

    @IsTest
    static void testExecute_CachedEvaluationKey_SkippedAgainstDB() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();
        // Pre-record this exact (published) pair as already evaluated.
        seedCachedEvaluation(arts[0].Id, arts[1].Id);

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(arts[0].Id, arts[1].Id) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(0, mock.factEvalCallCount,
            'Pair already in Knowledge_Pair_Evaluation__c → skipped without LLM');
    }

    @IsTest
    static void testExecute_AlreadyProcessedKey_SkippedOnce() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult clear = new PromptTemplateService.FactEvaluationResult();
        clear.isDuplicate = false;
        clear.confidenceScore = 40;
        mock.mockFactEvalResult = clear;
        PromptTemplateService.setMock(mock);

        // Same pair twice (in either order). The second hit composite-key
        // dedupe and skips re-evaluation.
        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{
                pair(arts[2].Id, arts[3].Id),
                pair(arts[3].Id, arts[2].Id)
            },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(1, mock.factEvalCallCount,
            'Composite-key dedup processes (A,B) and (B,A) as a single pair');
    }

    @IsTest
    static void testExecute_LLMException_IncrementsErroredAndContinues() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.throwException = true;
        PromptTemplateService.setMock(mock);

        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{ pair(arts[2].Id, arts[3].Id) },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Duplicate_Candidate__c WHERE Source_Tier__c = 'Tier4_Agentic'],
            'LLM exception → no Duplicate_Candidate__c row produced');
    }

    // ──────────────────────────────────────────────────────────────────────
 // callout budget is a per-transaction PACE, not a coverage limit.
    // When more pairs remain than one transaction's budget allows, the
    // unprocessed pairs are deferred to a self-chained continuation rather than
    // silently dropped (which used to make the run look complete when it wasn't).
    // ──────────────────────────────────────────────────────────────────────

    private static void setCalloutBudget(Integer budget) {
 // Manual_Review_Threshold__c is the CS populated-row sentinel, so
        // set it too or PipelineConfigService falls through to CMDT/defaults.
        KB_Pipeline_Config__c cs = KB_Pipeline_Config__c.getOrgDefaults();
        cs.Manual_Review_Threshold__c = 50;
        cs.Max_SubAgent_Callouts__c = budget;
        upsert cs KB_Pipeline_Config__c.Id;
        PipelineConfigService.clearCache();
    }

    @IsTest
    static void testExecute_BudgetReached_ChainsContinuationForRemainingPairs() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        // Budget = 3: the first pair's full worst-case cost (chunk(t)=1 +
        // chunk(f)=1 + compare=1) is reserved up front and fits exactly. The
        // second pair (cost 3) needs more than the remaining 0 budget, so it is
        // deferred BEFORE any of its facts are extracted.
        setCalloutBudget(3);

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult clear = new PromptTemplateService.FactEvaluationResult();
        clear.isDuplicate = false;
        clear.confidenceScore = 40;
        mock.mockFactEvalResult = clear;
        PromptTemplateService.setMock(mock);

        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{
                pair(arts[2].Id, arts[3].Id),
                pair(arts[4].Id, arts[5].Id)
            },
            runId
        );

        Test.startTest();
        job.execute(null);

 // assert the HEAD-LINK state BEFORE Test.stopTest. job.execute
        // ran synchronously above and enqueued a continuation for the deferred
        // pair; that continuation runs at stopTest() and shares these mock
        // counters. Asserting after stopTest observes head + continuation (2
        // pairs), which masks the reserve-before-start contract this test exists
        // to prove. The budget/chunk math is correct — the assertions were just
        // reading the counters one link too late.

        // Exactly one pair compared this link; the second was deferred.
        Assert.areEqual(1, mock.factEvalCallCount, 'Budget allows one pair per transaction');
        // No wasted extraction: only the completed pair's two articles were
        // extracted. The deferred pair was NOT touched (reserve-before-start
        // means no mid-pair abandonment → no double LLM cost on continuation).
        Assert.areEqual(2, mock.extractFactsCallCount,
            'Only the completed pair extracted facts; deferred pair untouched');
        // A continuation Tier4 queueable was enqueued for the remaining pair —
        // NOT the pipeline callback (the run is not finished yet).
        Assert.areEqual(1,
            [SELECT COUNT() FROM AsyncApexJob
             WHERE JobType = 'Queueable' AND ApexClass.Name = 'Tier3AgenticQueueable'],
            'Budget reached → continuation queueable enqueued for the deferred pair');
        Assert.areEqual(0,
            [SELECT COUNT() FROM AsyncApexJob
             WHERE JobType = 'Queueable' AND ApexClass.Name = 'KBAssessmentPipelineCallback'],
            'Pipeline does NOT finalize while pairs remain');

        Test.stopTest();

        // After the continuation flushes: the deferred pair WAS evaluated — the
 // budget path defers, it never silently drops. Total comparisons
        // across the chain is 2 (head 1 + continuation 1).
        Assert.areEqual(2, mock.factEvalCallCount,
            'Continuation evaluated the deferred pair — no pair is silently dropped');
    }

    @IsTest
    static void testExecute_BudgetTooLowForAnyPair_AbortsChainAndStampsError() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        // Budget = 1: the first pair's reserved cost (3) exceeds the budget, so
        // it's deferred before any work and zero pairs are evaluated. Chaining
        // would loop forever — the guard must abort and stamp an actionable
        // error on the run instead.
        setCalloutBudget(1);

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Tier3AgenticQueueable job = new Tier3AgenticQueueable(
            new List<Tier3AgenticQueueable.FinalistPair>{
                pair(arts[2].Id, arts[3].Id),
                pair(arts[4].Id, arts[5].Id)
            },
            runId
        );

        Test.startTest();
        job.execute(null);
        Test.stopTest();

        // No continuation Tier4 job — the chain was aborted.
        Assert.areEqual(0,
            [SELECT COUNT() FROM AsyncApexJob
             WHERE JobType = 'Queueable' AND ApexClass.Name = 'Tier3AgenticQueueable'],
            'Zero-progress budget must NOT chain (would loop forever)');
        // The run carries an actionable error message.
        KB_Assessment_Run__c run = [SELECT Status_Message__c FROM KB_Assessment_Run__c WHERE Id = :runId];
        Assert.isTrue(
            run.Status_Message__c != null && run.Status_Message__c.contains('Max Sub-Agent Callouts'),
            'Run stamped with an actionable budget-too-low message, not a silent skip');
    }

    // ──────────────────────────────────────────────────────────────────────
 // Pipeline callback — analysis fan-out (PR1)
    //
    // The callback is normally enqueued by Tier 4 / the trampoline, but we
    // exercise it directly to verify Duplication analysis rows are emitted
    // alongside KB_Dimension_Result__c when pipeline data lands.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testPipelineCallback_EmitsDuplicationAnalysisRows() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        KB_Assessment_Run__c run = [
            SELECT Id, Selected_Dimensions_JSON__c
            FROM KB_Assessment_Run__c WHERE Id = :runId
        ];
        run.Selected_Dimensions_JSON__c = '["Duplication"]';
        update run;

        KB_Article_Assessment__c parent =
            KBTestDataFactory.insertArticleAssessment(runId, arts[0].Id);

        // Seed a Duplication dimension row so the callback's UPDATE branch fires
        // (mirrors the post-fan-out steady state) and so we can detect that
        // the analysis emission key (Article_Assessment__c) is preserved.
        insert new KB_Dimension_Result__c(
            Article_Assessment__c = parent.Id,
            Dimension__c = 'Duplication',
            Score__c = 100
        );

        // Pipeline candidate that drops Duplication well below 100 → triggers
        // an Issue analysis row emission from KBDimensionAnalysisService.
        KBTestDataFactory.insertDuplicateCandidate(
            arts[0].Id, arts[1].Id, 'Duplicate', 'Pending'
        );

        Test.startTest();
        new KBAssessmentPipelineCallback(runId).execute(null);
        Test.stopTest();

        List<KB_Dimension_Analysis__c> analyses = [
            SELECT Id, Dimension__c, Type__c, Status__c, Dimension_Result__c
            FROM KB_Dimension_Analysis__c
            WHERE Dimension_Result__r.Article_Assessment__c = :parent.Id
              AND Dimension__c = 'Duplication'
        ];
        Assert.isFalse(analyses.isEmpty(),
            'Pipeline callback emits Duplication analysis rows when candidates exist');
        for (KB_Dimension_Analysis__c a : analyses) {
            Assert.areEqual('Duplication', a.Dimension__c, 'Dimension stamped');
            Assert.areEqual('Open', a.Status__c, 'Defaults to Open');
            Assert.isNotNull(a.Dimension_Result__c, 'Master-detail link populated');
        }
    }

    @IsTest
    static void testPipelineCallback_RerunReplacesDuplicationAnalysisRows() {
        List<Knowledge__kav> arts = getOnlineArticles();
        Id runId = getRunId();

        KB_Assessment_Run__c run = [
            SELECT Id, Selected_Dimensions_JSON__c
            FROM KB_Assessment_Run__c WHERE Id = :runId
        ];
        run.Selected_Dimensions_JSON__c = '["Duplication"]';
        update run;

        KB_Article_Assessment__c parent =
            KBTestDataFactory.insertArticleAssessment(runId, arts[0].Id);
        insert new KB_Dimension_Result__c(
            Article_Assessment__c = parent.Id,
            Dimension__c = 'Duplication',
            Score__c = 100
        );
        KBTestDataFactory.insertDuplicateCandidate(
            arts[0].Id, arts[1].Id, 'Duplicate', 'Pending'
        );

        Test.startTest();
        new KBAssessmentPipelineCallback(runId).execute(null);
        Integer firstPass = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Dimension_Result__r.Article_Assessment__c = :parent.Id
              AND Dimension__c = 'Duplication'
        ];

        // Reset run to In Progress so the second execute() doesn't short-circuit.
        run = [SELECT Id, Status__c FROM KB_Assessment_Run__c WHERE Id = :runId];
        run.Status__c = 'In Progress';
        update run;

        new KBAssessmentPipelineCallback(runId).execute(null);
        Test.stopTest();

        Integer secondPass = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Dimension_Result__r.Article_Assessment__c = :parent.Id
              AND Dimension__c = 'Duplication'
        ];
        Assert.isTrue(firstPass > 0, 'First pass produced analysis rows');
        Assert.areEqual(firstPass, secondPass,
            'Re-run replaces, does not duplicate, Duplication analysis rows');
    }

}
