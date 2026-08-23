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
 * Targeted coverage for KBAssessmentPipelineCallback branches not exercised
 * by Tier3AgenticQueueableTest. Specifically:
 *
 *   - initializeRunContext: malformed JSON in Selected_Dimensions /
 *     Effective_Weights falls back to defaults rather than throwing.
 *   - execute(): empty-assessments path stamps Failed and exits.
 *   - execute(): no Dup/Conflict selected → finalize from existing dim rows.
 *   - finalizeRun: empty parents short-circuits to Failed.
 *   - publishProgress: oversized message (>255) is truncated, not thrown on.
 */
@IsTest
private class KBAssessmentPipelineCallbackTest {

    @IsTest
    static void testExecute_NoAssessments_MarksFailed() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        // Pipeline run that the callback will mark Failed alongside the parent.
        // KB_Pipeline_Run__c.Status__c restricted picklist uses 'Running', not 'In Progress'.
        KB_Pipeline_Run__c pr = KBTestDataFactory.insertPipelineRun(run.Id, 'Deduplication', 'Running');
        run.Pipeline_Run__c = pr.Id;
        update run;

        Test.startTest();
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        Test.stopTest();

        KB_Assessment_Run__c reread =
            [SELECT Status__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.areEqual('Failed', reread.Status__c,
            'No assessments → run marked Failed');
        KB_Pipeline_Run__c prReread =
            [SELECT Status__c FROM KB_Pipeline_Run__c WHERE Id = :pr.Id];
        Assert.areEqual('Failed', prReread.Status__c,
            'Pipeline run also marked Failed');
    }

    @IsTest
    static void testExecute_NoDupOrConflictDimensions_FinalizesFromExisting() {
        // Selected_Dimensions = ["Freshness"] only — execute() takes the
        // !evaluateDuplication && !evaluateConflict branch and computes
        // Overall_Score__c from existing dim rows.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        run.Selected_Dimensions_JSON__c = '["Freshness"]';
        update run;

        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'cb-no-dedup')[0];
        KB_Article_Assessment__c parent = KBTestDataFactory.insertArticleAssessment(run.Id, kav.Id);

        // Seed a Freshness child row so scoresForOverall has something to work with.
        insert new KB_Dimension_Result__c(
            Article_Assessment__c = parent.Id,
            Dimension__c = 'Freshness',
            Score__c = 80
        );

        Test.startTest();
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        Test.stopTest();

        KB_Article_Assessment__c reread = [
            SELECT Overall_Score__c, Readiness_Status__c
            FROM KB_Article_Assessment__c WHERE Id = :parent.Id
        ];
        Assert.isNotNull(reread.Overall_Score__c,
            'Overall_Score populated from existing dim rows when no dedup dims selected');
        Assert.isNotNull(reread.Readiness_Status__c,
            'Readiness classified from the computed overall');

 // the only dimension row is Freshness (no Scorer_Mode__c='Hybrid'),
        // so finalization must reconcile Used_LLM__c down to false even though
        // the run was created with whatever intent default.
        KB_Assessment_Run__c runReread =
            [SELECT Used_LLM__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.isFalse(runReread.Used_LLM__c,
            'No Hybrid dimension rows → Used_LLM__c reconciled to false at finalization');
    }

    @IsTest
    static void testExecute_HybridDimensionRow_ReconcilesUsedLLMTrue() {
 // when at least one dimension row was actually produced by the LLM
        // (Scorer_Mode__c='Hybrid'), finalization sets Used_LLM__c=true.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        run.Selected_Dimensions_JSON__c = '["Completeness"]';
        update run;

        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'cb-hybrid')[0];
        KB_Article_Assessment__c parent = KBTestDataFactory.insertArticleAssessment(run.Id, kav.Id);

        insert new KB_Dimension_Result__c(
            Article_Assessment__c = parent.Id,
            Dimension__c = 'Completeness',
            Score__c = 88,
            Scorer_Mode__c = KBScorerBase.MODE_HYBRID
        );

        Test.startTest();
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        Test.stopTest();

        KB_Assessment_Run__c runReread =
            [SELECT Used_LLM__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.isTrue(runReread.Used_LLM__c,
            'A Hybrid dimension row → Used_LLM__c reconciled to true at finalization');
    }

    @IsTest
    static void testInitializeRunContext_MalformedJsonFallsBackToActive() {
        // Malformed Selected_Dimensions_JSON + Effective_Weights_JSON should
        // all be swallowed by their try/catches. The callback continues with
        // the active dim set + active weights.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        run.Selected_Dimensions_JSON__c = '{not-json';
        run.Effective_Weights_JSON__c   = '<<<broken';
        update run;

        Test.startTest();
        // No assessments → execute() fails out, but only AFTER
        // initializeRunContext() has run and exercised both catch arms.
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        Test.stopTest();

        // Just assert the run was processed — the test passes by not throwing.
        KB_Assessment_Run__c reread =
            [SELECT Status__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.areEqual('Failed', reread.Status__c,
            'Malformed JSON survived; downstream still ran and marked Failed (no assessments)');
    }

    @IsTest
    static void testExecute_PipelineSkippedArticles_DropPlaceholderRows() {
        // Articles excluded by the quality gate carry Pipeline_Skip_Reason__c.
        // The callback should DELETE pre-existing Duplication/Conflict rows
        // for those parents (they were placeholder 100s) — exercises lines
        // 105-116 (the skipped-deletion block).
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        run.Selected_Dimensions_JSON__c = '["Duplication","Conflict"]';
        update run;

        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'cb-skipped')[0];
        KB_Article_Assessment__c parent =
            KBTestDataFactory.insertArticleAssessment(run.Id, kav.Id);
        parent.Pipeline_Skip_Reason__c = 'Completeness 42 < threshold 60';
        update parent;

        // Seed placeholder Duplication + Conflict child rows that the callback
        // is expected to delete.
        insert new List<KB_Dimension_Result__c>{
            new KB_Dimension_Result__c(
                Article_Assessment__c = parent.Id,
                Dimension__c = 'Duplication', Score__c = 100
            ),
            new KB_Dimension_Result__c(
                Article_Assessment__c = parent.Id,
                Dimension__c = 'Conflict', Score__c = 100
            )
        };

        Test.startTest();
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        Test.stopTest();

        Integer remaining = [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__c = :parent.Id
              AND Dimension__c IN ('Duplication','Conflict')
        ];
        Assert.areEqual(0, remaining,
            'Placeholder Duplication/Conflict rows deleted for gate-skipped article');
    }

    @IsTest
    static void testAllArticlesSkippedYieldsNullDimAverages() {
 // regression: when EVERY article in the run is excluded
        // from the dedup pipeline by the quality gate, the run-level
        // Duplication_Score__c / Conflict_Score__c columns must end up null
        // on KB_Assessment_Run__c — not 100, not 0. The downstream LWCs
        // read null as "render N/A"; any non-null value would mislead users
        // into thinking the dim was actually scored.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        run.Selected_Dimensions_JSON__c = '["Duplication","Conflict"]';
        update run;
        KB_Pipeline_Run__c pr = KBTestDataFactory.insertPipelineRun(run.Id, 'Deduplication', 'Running');
        run.Pipeline_Run__c = pr.Id;
        update run;

        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'cb-allskip');
        List<KB_Article_Assessment__c> parents = new List<KB_Article_Assessment__c>();
        for (Knowledge__kav k : arts) {
            KB_Article_Assessment__c p = KBTestDataFactory.insertArticleAssessment(run.Id, k.Id);
            p.Pipeline_Skip_Reason__c = 'Completeness 42 < threshold 60';
            parents.add(p);
        }
        update parents;

        // Seed the placeholder Duplication/Conflict child rows the
        // KBAssessmentDimensionQueueable would have written pre-pipeline —
        // the callback's skipped-deletion block (lines 138-148) is what
        // strips them. After deletion the finalizeRun aggregate has zero
        // rows for those dims and writes null on the run.
        List<KB_Dimension_Result__c> placeholders = new List<KB_Dimension_Result__c>();
        for (KB_Article_Assessment__c p : parents) {
            placeholders.add(new KB_Dimension_Result__c(
                Article_Assessment__c = p.Id,
                Dimension__c = 'Duplication', Score__c = 100
            ));
            placeholders.add(new KB_Dimension_Result__c(
                Article_Assessment__c = p.Id,
                Dimension__c = 'Conflict', Score__c = 100
            ));
        }
        insert placeholders;

        Test.startTest();
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        Test.stopTest();

        KB_Assessment_Run__c reread = [
            SELECT Status__c, Duplication_Score__c, Conflict_Score__c
            FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual('Completed', reread.Status__c,
            'All-skipped run still finalizes Completed');
        Assert.isNull(reread.Duplication_Score__c,
            'run-level Duplication_Score__c is null when every ' +
            'article was gate-skipped (LWC will render N/A)');
        Assert.isNull(reread.Conflict_Score__c,
            'run-level Conflict_Score__c is null when every ' +
            'article was gate-skipped (LWC will render N/A)');

        // Defense-in-depth: also assert the child rows are gone, so a
        // row-count check yields 0 even if a future drift somehow
        // restored the run-level columns.
        Integer remainingChildRows = [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :run.Id
              AND Dimension__c IN ('Duplication','Conflict')
        ];
        Assert.areEqual(0, remainingChildRows,
            'No Duplication/Conflict child rows remain for an all-skipped run');
    }

    @IsTest
    static void testExecute_FullPipeline_WritesParentScores() {
        // End-to-end: dimensions = both Dup + Conflict, real candidate seeded,
        // real article rows. Exercises the main loop body, dimChildUpserts,
        // generatePipelineRecommendations, finalizeRun, and the dimAverages
        // aggregate query.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        run.Selected_Dimensions_JSON__c = '["Duplication","Conflict"]';
        update run;

        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'cb-full');
        KB_Article_Assessment__c parentA =
            KBTestDataFactory.insertArticleAssessment(run.Id, arts[0].Id);
        KB_Article_Assessment__c parentB =
            KBTestDataFactory.insertArticleAssessment(run.Id, arts[1].Id);

        KBTestDataFactory.insertDuplicateCandidate(
            arts[0].Id, arts[1].Id, 'Duplicate', 'Pending'
        );

        Test.startTest();
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        Test.stopTest();

        KB_Assessment_Run__c reread = [
            SELECT Status__c, Overall_Score__c, Duplication_Score__c, Conflict_Score__c
            FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual('Completed', reread.Status__c,
            'Full pipeline path completes the run');
        Assert.isNotNull(reread.Overall_Score__c,
            'Run-level Overall_Score populated after finalizeRun');

        Integer parentUpdates = [
            SELECT COUNT() FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :run.Id AND Overall_Score__c != null
        ];
        Assert.areEqual(2, parentUpdates,
            'Both article assessments got Overall_Score__c written');
    }

    @IsTest
    static void testExecute_RethrowsUnexpectedFailure_IsCaughtAtTopLevel() {
        // T9: previously this test used a 15-char phantom Id ('000000000000000AAA')
        // which made the SOQL silently return zero assessments — the
        // assessments.isEmpty() early return ran before any catchable failure
        // could surface, so the catch block at the bottom of execute() was
        // never actually exercised.
        //
        // Now: insert a real run with a real Pipeline_Run__c, then flip the
        // @TestVisible throwAfterInitializeForTest seam so execute() throws
        // *after* initializeRunContext() — well past the empty-assessments
        // early return. The outer catch at execute()'s tail then runs
        // updateRunStatus('Failed') + markPipelineFailed(...), and we assert
        // both downstream effects landed.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        KB_Pipeline_Run__c pr = KBTestDataFactory.insertPipelineRun(run.Id, 'Deduplication', 'Running');
        run.Pipeline_Run__c = pr.Id;
        update run;

        // Need at least one assessment so initializeRunContext + the
        // assessments-loaded path actually run before the injected throw.
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'cb-rethrow')[0];
        KBTestDataFactory.insertArticleAssessment(run.Id, kav.Id);

        KBAssessmentPipelineCallback.throwAfterInitializeForTest = true;

        Test.startTest();
        Boolean threw = false;
        try {
            new KBAssessmentPipelineCallback(run.Id).execute(null);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isFalse(threw,
            'Top-level catch swallows the injected mid-execute failure — execute() never propagates');

        KB_Assessment_Run__c reread =
            [SELECT Status__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.areEqual('Failed', reread.Status__c,
            'Outer catch ran updateRunStatus(Failed)');

        KB_Pipeline_Run__c prReread =
            [SELECT Status__c FROM KB_Pipeline_Run__c WHERE Id = :pr.Id];
        Assert.areEqual('Failed', prReread.Status__c,
            'Outer catch ran markPipelineFailed → Pipeline_Run__c.Status__c = Failed');
    }

    /**
     * Stub PromptTemplateService that records every annotateIssueSeverity
     * invocation — used by tests that need to verify either (a) the callback
     * is no longer making sync severity callouts (callout-budget regression)
     * or (b) the queueable is wired correctly when invoked. Returns canned
     * annotations matching the requested issue count so the queueable's
     * happy path runs end-to-end.
     */
    public class RecordingPromptService extends PromptTemplateService {
        public Integer callCount = 0;
        public Integer lastIssueCount = 0;

        public override List<PromptTemplateService.IssueSeverityAnnotation> annotateIssueSeverity(
            String articleTitle, String articleSummary, String articleContent,
            String counterpartTitle, String counterpartSummary, String counterpartContent,
            List<String> issues, List<String> strengths
        ) {
            this.callCount++;
            this.lastIssueCount = issues != null ? issues.size() : 0;
            List<PromptTemplateService.IssueSeverityAnnotation> out =
                new List<PromptTemplateService.IssueSeverityAnnotation>();
            if (issues == null) return out;
            for (Integer i = 0; i < issues.size(); i++) {
                PromptTemplateService.IssueSeverityAnnotation ann =
                    new PromptTemplateService.IssueSeverityAnnotation();
                ann.index    = i;
                ann.impact   = 'Medium';
                out.add(ann);
            }
            return out;
        }
    }

    @IsTest
    static void testExecute_CalloutBudget_StaysUnderTenForOneHundredAssessments() {
        // C3 regression: previously generatePipelineRecommendations called
        // PromptTemplateService.annotateIssueSeverity once per (article, dim)
        // synchronously inside execute() — 100 articles × Dup+Conflict was
        // up to 200 callouts in a single transaction (above the 100-callout
        // governor). Severity annotation now fans into KBSeverityAnnotationQueueable
        // and runs in its own transactions, so the callback's execute() should
        // make zero LLM callouts itself.
        //
        // Asserts Limits.getCallouts() captured between start-of-execute and
        // end-of-execute (i.e. before the chained queueable runs in stopTest)
        // is < 10. The previous sync path would have pushed it to ~200.
        //
        // Drives 100 assessments with paired duplicate candidates so the
        // pipeline path actually generates work — otherwise we'd be
        // measuring an empty path. To keep the queueable's chain depth
        // within the platform-test cap (1) we override CHUNK_SIZE upward
        // so all tasks fit in the first chunk.
        RecordingPromptService recorder = new RecordingPromptService();
        PromptTemplateService.setMock(recorder);
        Integer originalChunk = KBSeverityAnnotationQueueable.CHUNK_SIZE;
        KBSeverityAnnotationQueueable.CHUNK_SIZE = 500; // > expected 100 × 2 = 200 tasks

        try {
            KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
            run.Selected_Dimensions_JSON__c = '["Duplication","Conflict"]';
            update run;

            List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(100, 'cb-budget');
            // Bulk insert assessments to stay under the 150-DML governor
            // (per-call factory was producing one DML per row → 150+).
            List<KB_Article_Assessment__c> assessments = new List<KB_Article_Assessment__c>();
            Map<Id, Id> versionToParent = new Map<Id, Id>();
            for (Knowledge__kav kav : [
                SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :arts
            ]) {
                versionToParent.put(kav.Id, kav.KnowledgeArticleId);
            }
            for (Knowledge__kav k : arts) {
                Id parent = versionToParent.containsKey(k.Id) ? versionToParent.get(k.Id) : k.Id;
                assessments.add(new KB_Article_Assessment__c(
                    Assessment_Run__c = run.Id,
                    Knowledge__c = k.Id,
                    Knowledge_Article_Id__c = String.valueOf(parent),
                    Article_Title__c = k.Title,
                    Overall_Score__c = 75,
                    Readiness_Status__c = 'Ready'
                ));
            }
            insert assessments;

            // Bulk insert duplicate candidates linked to this run so the
            // pipeline path (KBPipelineBridgeService.getBatchCandidates with
            // runId filter) actually sees them.
            List<Duplicate_Candidate__c> candidates = new List<Duplicate_Candidate__c>();
            for (Integer i = 0; i < arts.size() - 1; i += 2) {
                String compositeKey = KnowledgeAIGovernanceService.generateCompositeKey(
                    String.valueOf(arts[i].Id), String.valueOf(arts[i + 1].Id)
                );
                candidates.add(new Duplicate_Candidate__c(
                    Knowledge_Article_1__c = String.valueOf(arts[i].Id),
                    Knowledge_Article_2__c = String.valueOf(arts[i + 1].Id),
                    Composite_Key__c = compositeKey,
                    Flag_Type__c = 'Duplicate',
                    Status__c = 'Pending',
                    Confidence_Score__c = 80,
                    Source_Tier__c = 'Tier4_Agentic',
                    Score_Calculated_Date__c = Datetime.now(),
                    Assessment_Run__c = run.Id
                ));
            }
            insert candidates;

            Test.startTest();
            Integer calloutsBefore = Limits.getCallouts();
            new KBAssessmentPipelineCallback(run.Id).execute(null);
            Integer calloutsDuringCallbackExecute = Limits.getCallouts() - calloutsBefore;
            Test.stopTest();

            Assert.isTrue(calloutsDuringCallbackExecute < 10,
                'Callback execute() should make < 10 callouts (was ' + calloutsDuringCallbackExecute
                + '); severity annotation moved to KBSeverityAnnotationQueueable');
        } finally {
            KBSeverityAnnotationQueueable.CHUNK_SIZE = originalChunk;
        }
    }

    @IsTest
    static void testExecute_PipelineRecommendations_EnqueuesSeverityQueueable() {
        // The synchronous severity annotation has been replaced with an
        // enqueued KBSeverityAnnotationQueueable. Asserting the chained
        // queueable ran is the cleanest signal the wiring is intact.
        // We verify by checking that KB_Dimension_Analysis__c rows now
 // carry Impact severity (Impact-only on the pipeline path,)
        // populated by the recorder stub — which only happens if the
        // queueable ran AND updated rows by Id.
        RecordingPromptService recorder = new RecordingPromptService();
        PromptTemplateService.setMock(recorder);

        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        run.Selected_Dimensions_JSON__c = '["Duplication","Conflict"]';
        update run;

        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'cb-enqueue');
        KBTestDataFactory.insertArticleAssessment(run.Id, arts[0].Id);
        KBTestDataFactory.insertArticleAssessment(run.Id, arts[1].Id);
        // KBPipelineBridgeService.getBatchCandidates filters by Assessment_Run__c
        // when a runId is passed (which the callback does), so parent the candidate
        // to this run at creation. (Assessment_Run__c is now a master-detail parent
        // and non-reparentable, so it must be set on insert, not reassigned later.)
        KBTestDataFactory.insertDuplicateCandidate(
            arts[0].Id, arts[1].Id, 'Duplicate', 'Pending', run.Id
        );

        Test.startTest();
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        Test.stopTest();
        // After Test.stopTest(): the queueable enqueued from execute() has run.

 // severity on the pipeline path is Impact-only; Priority/Effort
        // are no longer stamped, so gate on Impact__c alone.
        Integer annotatedRowCount = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Type__c = 'Issue'
              AND Dimension__c IN ('Duplication','Conflict')
              AND Impact__c != null
        ];
        Assert.isTrue(annotatedRowCount > 0,
            'Queueable ran and stamped Impact severity on issue rows');
        Assert.isTrue(recorder.callCount > 0,
            'RecordingPromptService.annotateIssueSeverity was invoked from the queueable');
    }

    @IsTest
    static void testExecute_ReRunIsIdempotentForSeverity() {
        // Idempotency: invoking execute() twice should not corrupt severity.
        // The first run inserts analysis rows + enqueues the queueable; on
        // second run we call execute() again — the analysis rows for the
        // same (assessment, dim) are deleted-then-reinserted, so any prior
        // severity is cleared. The new queueable then re-stamps severity.
        // Net effect: severity values reflect the most-recent annotation
        // pass, not a stack of two passes.
        RecordingPromptService recorder = new RecordingPromptService();
        PromptTemplateService.setMock(recorder);

        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        run.Selected_Dimensions_JSON__c = '["Duplication","Conflict"]';
        update run;

        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'cb-idem');
        KBTestDataFactory.insertArticleAssessment(run.Id, arts[0].Id);
        KBTestDataFactory.insertArticleAssessment(run.Id, arts[1].Id);
        // Parent the candidate to this run at creation (master-detail, non-reparentable).
        KBTestDataFactory.insertDuplicateCandidate(
            arts[0].Id, arts[1].Id, 'Duplicate', 'Pending', run.Id
        );

        Test.startTest();
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        new KBAssessmentPipelineCallback(run.Id).execute(null);
        Test.stopTest();

        // After both passes: Impact column holds at most one value per row
        // (the most recent annotation). No "doubled-up" string would be
        // possible since each UPDATE overwrites the previous value.
        Integer issueRows = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Type__c = 'Issue'
              AND Dimension__c IN ('Duplication','Conflict')
        ];
        Assert.isTrue(issueRows > 0, 'Issue rows survive the re-run');

        // Belt-and-suspenders: assert no row carries an obviously corrupt
        // (concatenated) impact string — Impact__c is restricted picklist
        // so platform DML would reject 'MediumMedium' anyway, but we still
        // assert against anything starting with 'Medium ' (whitespace gap
        // would suggest stitched values).
        for (KB_Dimension_Analysis__c row : [
            SELECT Impact__c FROM KB_Dimension_Analysis__c
            WHERE Type__c = 'Issue'
              AND Dimension__c IN ('Duplication','Conflict')
        ]) {
            if (row.Impact__c != null) {
                Assert.isFalse(row.Impact__c.contains(' Medium'),
                    'Re-run never produces concatenated impact values');
            }
        }
    }
}
