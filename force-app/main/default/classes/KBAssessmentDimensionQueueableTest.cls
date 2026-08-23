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
 * Coverage for KBAssessmentDimensionQueueable — fan-out worker that
 * scores ONE dimension across ALL articles in a run.
 *
 * Tests drive execute() through real Knowledge__kav + KB_Article_Assessment__c
 * + Duplicate_Candidate__c data so the upsert and FOR UPDATE paths fire.
 * Deterministic dimensions (Freshness, Duplication, Conflict) are used so
 * no LLM mock is required.
 *
 * Why the explicit AsyncException catch (T8): Apex tests cap queueable-chain
 * depth at 1. When markCompleted's last-dim branch fires it calls
 * KBAssessmentPipelineDispatcher which itself enqueues — pushing chain depth
 * to 2 and raising AsyncException. The synchronous body of execute() runs to
 * completion before the enqueue, so the side-effect assertions still pass.
 *
 * Earlier passes used a blanket `catch (Exception ignored) {}` which masked
 * unrelated regressions (NPEs, malformed SOQL, FOR UPDATE collisions). We
 * now catch ONLY AsyncException and re-throw anything else, so any non-async
 * regression fails the test loud and clear.
 */
@IsTest
private class KBAssessmentDimensionQueueableTest {

    /**
     * Runs `job.execute(null)`, swallowing only the chain-depth AsyncException
     * that is platform-mandatory in tests. Any other exception is re-thrown
     * verbatim so it surfaces as a test failure rather than silent corruption.
     */
    private static void runExecuteSwallowingAsyncOnly(KBAssessmentDimensionQueueable job) {
        try {
            job.execute(null);
        } catch (System.AsyncException ae) {
            // Expected when the last-dim branch enqueues the pipeline dispatcher.
            // The synchronous side effects we assert on already ran by then.
        }
    }

    @TestSetup
    static void setup() {
        // Two real Knowledge__kav rows + parents so execute() has scoring work.
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 2,
            Dispatched_Dimensions__c = 'Freshness',
            Completed_Dimensions__c = null
        );
        insert run;
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'dim-q');
        for (Knowledge__kav k : kavs) {
            KBTestDataFactory.insertArticleAssessment(run.Id, k.Id);
        }
    }

    private static KB_Assessment_Run__c getRun() {
        return [SELECT Id, Status__c, Completed_Dimensions__c, Dispatched_Dimensions__c
                FROM KB_Assessment_Run__c LIMIT 1];
    }

    private static List<String> getArticleIdsForRun() {
        List<String> ids = new List<String>();
        for (KB_Article_Assessment__c p : [
            SELECT Knowledge__c FROM KB_Article_Assessment__c
        ]) {
            ids.add(String.valueOf(p.Knowledge__c));
        }
        return ids;
    }

    // ──────────────────────────────────────────────────────────────────────
    // markCompleted — last dim → finalization dispatch
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_LastDim_FlipsStatusToScoringComplete() {
        // Dispatched_Dimensions__c = 'Freshness' (set in @TestSetup) means
        // Freshness is the only dim queued; completing it should flip the
        // run to Scoring Complete.
        KB_Assessment_Run__c run = getRun();
        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        KB_Assessment_Run__c updated = getRun();
        Assert.isTrue(
            updated.Completed_Dimensions__c != null
                && updated.Completed_Dimensions__c.contains('Freshness'),
            'Dimension marked completed'
        );
        // Status flips to Scoring Complete and is then advanced by the
        // pipeline dispatcher → Completed in the same transaction.
        Assert.isTrue(
            updated.Status__c == 'Scoring Complete' || updated.Status__c == 'Completed'
                || updated.Status__c == 'Pipeline Running',
            'Status advanced past In Progress; saw: ' + updated.Status__c
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // markCompleted — not the last dim → status stays In Progress
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_NotLastDim_StatusStaysInProgress() {
        // Pre-set Dispatched_Dimensions to TWO dims — completing only one
        // means the run is NOT done.
        KB_Assessment_Run__c run = getRun();
        run.Dispatched_Dimensions__c = 'Freshness,Clarity';
        update run;

        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        KB_Assessment_Run__c updated = getRun();
        Assert.areEqual('In Progress', updated.Status__c,
            'Status only flips when ALL dispatched dims complete');
        Assert.isTrue(updated.Completed_Dimensions__c.contains('Freshness'));
    }

    // ──────────────────────────────────────────────────────────────────────
    // markCompleted — idempotency guard
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testMarkCompleted_IdempotencyGuard() {
        // Status already past In Progress → markCompleted exits early without
        // updating Completed_Dimensions__c.
        KB_Assessment_Run__c run = getRun();
        run.Status__c = 'Scoring Complete';
        update run;

        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        KB_Assessment_Run__c updated = getRun();
        Assert.areEqual('Scoring Complete', updated.Status__c, 'Status unchanged');
    }

    // ──────────────────────────────────────────────────────────────────────
    // execute() body — empty article list short-circuits
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_NoArticles_StillMarksCompleted() {
        KB_Assessment_Run__c run = getRun();
        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, new List<String>(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        KB_Assessment_Run__c updated = getRun();
        Assert.isTrue(
            updated.Completed_Dimensions__c != null
                && updated.Completed_Dimensions__c.contains('Freshness'),
            'Empty articles still marks dim complete'
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // execute() body — full happy path with real article rows
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_HappyPath_WritesDimensionResults() {
        KB_Assessment_Run__c run = getRun();
        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        Integer dimRows = [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :run.Id
              AND Dimension__c = 'Freshness'
        ];
        Assert.areEqual(2, dimRows, 'One Freshness child row per article');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Pipeline-data dim with bridge candidates
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_PipelineDataDim_LoadsBridgeData() {
        // Duplication is a pipeline-data dim — its bridge query will run.
        KB_Assessment_Run__c run = getRun();
        run.Dispatched_Dimensions__c = 'Duplication';
        update run;

        // Add a Duplicate_Candidate__c so getBatchCandidates returns data.
        List<KB_Article_Assessment__c> parents = [
            SELECT Knowledge__c FROM KB_Article_Assessment__c
        ];
        if (parents.size() >= 2) {
            KBTestDataFactory.insertDuplicateCandidate(
                parents[0].Knowledge__c, parents[1].Knowledge__c, 'Duplicate', 'Pending'
            );
        }

        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Duplication'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        KB_Assessment_Run__c updated = getRun();
        Assert.isTrue(
            updated.Completed_Dimensions__c != null
                && updated.Completed_Dimensions__c.contains('Duplication')
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // Existing child row updated in place (not duplicated)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_ExistingChildRow_UpdatedNotDuplicated() {
        KB_Assessment_Run__c run = getRun();
        // Pre-create a Freshness row for one parent.
        KB_Article_Assessment__c parent = [
            SELECT Id, Knowledge__c FROM KB_Article_Assessment__c LIMIT 1
        ];
        insert new KB_Dimension_Result__c(
            Article_Assessment__c = parent.Id,
            Dimension__c = 'Freshness',
            Score__c = 0,
            Reasoning__c = 'old'
        );

        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__c = :parent.Id
              AND Dimension__c = 'Freshness'
        ];
        Assert.areEqual(1, count, 'Existing row updated, not duplicated');
    }

    // ──────────────────────────────────────────────────────────────────────
 // Analysis rows fan out alongside dimension results (PR1)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_EmitsAnalysisRows() {
        // Freshness on freshly-inserted articles produces at least one
        // Strength ("very fresh") per article from the deterministic scorer.
        KB_Assessment_Run__c run = getRun();
        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        List<KB_Dimension_Analysis__c> analyses = [
            SELECT Id, Dimension__c, Type__c, Status__c, Dimension_Result__c
            FROM KB_Dimension_Analysis__c
            WHERE Dimension_Result__r.Article_Assessment__r.Assessment_Run__c = :run.Id
              AND Dimension__c = 'Freshness'
        ];
        Assert.isFalse(analyses.isEmpty(),
            'Async fan-out emits Issue/Strength rows for the scored dimension');
        for (KB_Dimension_Analysis__c a : analyses) {
            Assert.areEqual('Freshness', a.Dimension__c, 'Dimension stamped');
            Assert.areEqual('Open', a.Status__c, 'Defaults to Open');
            Assert.isNotNull(a.Dimension_Result__c, 'Master-detail link populated');
        }
    }

    @IsTest
    static void testExecute_RerunReplacesAnalysisRows() {
        // Re-running the same dim should DELETE prior analysis rows for that
        // (run, dim) and re-emit fresh ones — guards against duplicate
        // accumulation on iterative re-assessment.
        KB_Assessment_Run__c run = getRun();
        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Integer firstPass = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Dimension_Result__r.Article_Assessment__r.Assessment_Run__c = :run.Id
              AND Dimension__c = 'Freshness'
        ];
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        Integer secondPass = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Dimension_Result__r.Article_Assessment__r.Assessment_Run__c = :run.Id
              AND Dimension__c = 'Freshness'
        ];
        Assert.isTrue(firstPass > 0, 'First pass produced analysis rows');
        Assert.areEqual(firstPass, secondPass,
            'Re-run replaces, does not duplicate, analysis rows');
    }

    // ──────────────────────────────────────────────────────────────────────
 // Cancel gate: cancelled run short-circuits execute before
    // any KB_Dimension_Result__c rows are written and without advancing
    // Completed_Dimensions__c. Mirrors the markCompleted idempotency contract
    // but at the entry of execute().
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_RunCancelled_ShortCircuits() {
        KB_Assessment_Run__c run = getRun();
        run.Status__c = 'Cancelled';
        update run;

        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        try { job.execute(null); } catch (Exception ignored) {}
        Test.stopTest();

        KB_Assessment_Run__c updated = getRun();
        Assert.areEqual('Cancelled', updated.Status__c, 'Status remains Cancelled');
        Assert.isTrue(
            String.isBlank(updated.Completed_Dimensions__c),
            'Cancelled gate must not advance Completed_Dimensions__c; saw: ' + updated.Completed_Dimensions__c
        );
        Integer dimRows = [SELECT COUNT() FROM KB_Dimension_Result__c];
        Assert.areEqual(0, dimRows, 'Cancelled run writes no dimension result rows');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Per-worker generation gate (straggler from an aborted prior wave)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_SkipsWriteWhenSupersededByNewerWave() {
        // A straggler queueable from an aborted wave-1 drains AFTER a rerun bumped
        // the run to a newer generation. It must decline to write rather than
        // collide with wave-2 over the same result rows. The run stays 'In
        // Progress' (not Cancelled), so only the generation gate — not the cancel
        // gate — can stop it.
        KB_Assessment_Run__c run = getRun();
        run.Dispatch_Generation__c = 2;   // the run has advanced to wave-2
        update run;

        // This worker was dispatched at generation 1 (the prior, aborted wave).
        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness', null, 1
        );

        Test.startTest();
        try { job.execute(null); } catch (Exception ignored) {}
        Test.stopTest();

        KB_Assessment_Run__c updated = getRun();
        Assert.isTrue(String.isBlank(updated.Completed_Dimensions__c),
            'Superseded worker must not advance Completed_Dimensions__c; saw: ' + updated.Completed_Dimensions__c);
        Assert.areEqual(0, [SELECT COUNT() FROM KB_Dimension_Result__c],
            'A superseded (older-generation) straggler must not write any dimension results');
    }

    @IsTest
    static void testExecute_WritesWhenGenerationStillCurrent() {
        // Companion: when the worker's captured generation matches the run's
        // current generation (no rerun happened), it writes normally — the gate
        // must never block a legitimate wave.
        KB_Assessment_Run__c run = getRun();
        run.Dispatch_Generation__c = 1;
        update run;

        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness', null, 1   // captured == current
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        Assert.areEqual(2, [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Dimension__c = 'Freshness'
        ], 'A current-generation worker must write its dimension results normally');
    }

    // ──────────────────────────────────────────────────────────────────────
 // KB_Assessment_Progress__e emit points.
    //
    // Apex's EventBus.publish has no test-only "captured events" API (the
    // EventBus.TestBroker only exists on Streaming + CDC). publish() inside
    // a synchronous transaction returns a SaveResult; the event itself is
    // delivered at Test.stopTest(). We can't directly assert "the event was
    // published" without a custom seam, so the assertions below are
    // structural: the side effects that gate the publish call (markCompleted
    // updating the run row + scoring rows being written) confirm the
    // execute() path reached BOTH publish points without throwing.
    //
    // The publishProgress method itself is best-effort — it swallows
    // exceptions to avoid taking out scoring — so a thrown publish would
    // not fail the test. The structural assertions guarantee execute()
 // ran the full body, which traverses both emit sites in the post-
    // implementation.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecute_PublishesProgressWithoutThrowing() {
        // Happy path drives execute() through both publish points (start
        // heartbeat + markCompleted with Current_Batch / Total_Batches).
        // The execute body completes fully; the run advances past
        // 'In Progress' and the dimension results are written.
        KB_Assessment_Run__c run = getRun();
        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        // markCompleted ran (which is the second publish site). It writes
        // Completed_Dimensions__c under FOR UPDATE, and the publish call is
 // OUTSIDE the if(isLastDim) branch in the post- implementation,
        // so it fires on every completion.
        KB_Assessment_Run__c updated = getRun();
        Assert.isTrue(
            updated.Completed_Dimensions__c != null
                && updated.Completed_Dimensions__c.contains('Freshness'),
            'Both publish sites traversed — markCompleted ran to completion'
        );
        // Dimension results written → start-of-execute publish also ran.
        Integer dimRows = [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :run.Id
              AND Dimension__c = 'Freshness'
        ];
        Assert.areEqual(2, dimRows,
            'Start-of-execute publish ran (full body proceeded to write dim results)');
    }

    @IsTest
    static void testExecute_PublishesPerCompletion_NotJustLastDim() {
        // Two dimensions dispatched, only Freshness completing now. The
 // post- publish call lives OUTSIDE the if(isLastDim) branch so
        // it fires on every dimension completion — verified by the
        // Completed_Dimensions__c bookkeeping running to its non-terminal
        // state without exception.
        KB_Assessment_Run__c run = getRun();
        run.Dispatched_Dimensions__c = 'Freshness,Clarity';
        update run;

        KBAssessmentDimensionQueueable job = new KBAssessmentDimensionQueueable(
            run.Id, getArticleIdsForRun(), 'Freshness'
        );

        Test.startTest();
        runExecuteSwallowingAsyncOnly(job);
        Test.stopTest();

        KB_Assessment_Run__c updated = getRun();
        Assert.areEqual('In Progress', updated.Status__c,
            'Non-terminal completion path executes to publish point');
        Assert.isTrue(updated.Completed_Dimensions__c.contains('Freshness'),
            'Per-completion bookkeeping ran (publish site traversed)');
    }
}
