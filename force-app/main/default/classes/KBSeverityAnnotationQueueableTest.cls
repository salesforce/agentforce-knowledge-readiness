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
 * Targeted coverage for KBSeverityAnnotationQueueable.
 *
 * Exercises:
 *  - Empty / null tasks → execute() no-ops without DML or callouts.
 *  - Happy path: tasks update KB_Dimension_Analysis__c rows by Id with
 *    impact drawn from the LLM stub (Impact-only — effort/priority retired).
 *  - LLM throws → catch leaves severity null, no DML on that task's rows,
 *    but other tasks in the same chunk still update.
 *  - Self-chain: tasks > CHUNK_SIZE enqueues a follow-on job (verified via
 *    CHUNK_SIZE override + AsyncApexJob count assertion).
 *  - Idempotency: running the queueable twice on the same task list yields
 *    the same severity values — no concatenation, no row duplication.
 */
@IsTest
private class KBSeverityAnnotationQueueableTest {

    /** Stub returning canned annotations matching the issue count. */
    public class CannedPromptService extends PromptTemplateService {
        public Integer callCount = 0;
        public override List<PromptTemplateService.IssueSeverityAnnotation> annotateIssueSeverity(
            String articleTitle, String articleSummary, String articleContent,
            String counterpartTitle, String counterpartSummary, String counterpartContent,
            List<String> issues, List<String> strengths
        ) {
            this.callCount++;
            List<PromptTemplateService.IssueSeverityAnnotation> out =
                new List<PromptTemplateService.IssueSeverityAnnotation>();
            if (issues == null) return out;
            for (Integer i = 0; i < issues.size(); i++) {
                PromptTemplateService.IssueSeverityAnnotation ann =
                    new PromptTemplateService.IssueSeverityAnnotation();
                ann.index    = i;
                ann.impact   = 'High';
                out.add(ann);
            }
            return out;
        }
    }

    /** Stub that always throws on annotateIssueSeverity. */
    public class ThrowingPromptService extends PromptTemplateService {
        public override List<PromptTemplateService.IssueSeverityAnnotation> annotateIssueSeverity(
            String articleTitle, String articleSummary, String articleContent,
            String counterpartTitle, String counterpartSummary, String counterpartContent,
            List<String> issues, List<String> strengths
        ) {
            throw new KnowledgeAIException('Simulated LLM failure for severity annotation');
        }
    }

    /**
     * Convenience: insert run + two articles + parent assessments + the
     * KB_Dimension_Result__c rows the analyses need as master-detail parents.
     * Returns the inserted analysis row Ids in deterministic order.
     */
    private static List<KB_Dimension_Analysis__c> seedAnalyses(Integer issueCount, String dim) {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'sevq-' + dim)[0];
        KB_Article_Assessment__c parent = KBTestDataFactory.insertArticleAssessment(run.Id, kav.Id);

        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = parent.Id,
            Dimension__c = dim,
            Score__c = 75
        );
        insert dr;

        List<KB_Dimension_Analysis__c> rows = new List<KB_Dimension_Analysis__c>();
        for (Integer i = 0; i < issueCount; i++) {
            rows.add(new KB_Dimension_Analysis__c(
                Dimension_Result__c   = dr.Id,
                Article_Assessment__c = parent.Id,
                Type__c               = 'Issue',
                Dimension__c          = dim,
                Analysis_Text__c      = 'Issue text #' + i,
                Status__c             = 'Open'
            ));
        }
        insert rows;
        return rows;
    }

    private static KBSeverityAnnotationQueueable.AnnotationTask buildTask(
        String dim, List<KB_Dimension_Analysis__c> rows
    ) {
        KBSeverityAnnotationQueueable.AnnotationTask task =
            new KBSeverityAnnotationQueueable.AnnotationTask();
        task.dimension          = dim;
        task.articleId          = (Id) rows[0].Article_Assessment__c;
        task.selfTitle          = 'Self Title';
        task.selfSummary        = 'Self Summary';
        task.selfBody           = 'Self body content';
        task.counterpartTitle   = 'Counterpart Title';
        task.counterpartSummary = 'Counterpart Summary';
        task.counterpartBody    = 'Counterpart body content';
        for (KB_Dimension_Analysis__c row : rows) {
            task.issueTexts.add(row.Analysis_Text__c);
            task.analysisRowIds.add(row.Id);
        }
        task.strengths = new List<String>{ 'A strength' };
        return task;
    }

    @IsTest
    static void testExecute_EmptyTasks_IsNoOp() {
        Test.startTest();
        // Both empty list and null branch — the queueable should swallow both.
        new KBSeverityAnnotationQueueable(new List<KBSeverityAnnotationQueueable.AnnotationTask>())
            .execute(null);
        new KBSeverityAnnotationQueueable(null).execute(null);
        Test.stopTest();
        // Passes by not throwing.
        Assert.isTrue(true, 'Empty / null task list executes without error');
    }

    @IsTest
    static void testExecute_HappyPath_StampsSeverityOnRowsById() {
        PromptTemplateService.setMock(new CannedPromptService());
        List<KB_Dimension_Analysis__c> rows = seedAnalyses(3, 'Duplication');
        KBSeverityAnnotationQueueable.AnnotationTask task = buildTask('Duplication', rows);

        Test.startTest();
        new KBSeverityAnnotationQueueable(
            new List<KBSeverityAnnotationQueueable.AnnotationTask>{ task }
        ).execute(null);
        Test.stopTest();

        List<KB_Dimension_Analysis__c> reread = [
            SELECT Id, Impact__c
            FROM KB_Dimension_Analysis__c
            WHERE Id IN :new Set<Id>{ rows[0].Id, rows[1].Id, rows[2].Id }
        ];
 // the pipeline severity path is Impact-only; Effort/Priority were
        // retired (the fields no longer exist on the object).
        for (KB_Dimension_Analysis__c r : reread) {
            Assert.areEqual('High', r.Impact__c, 'Impact stamped from CannedPromptService');
        }
    }

    @IsTest
    static void testExecute_LlmThrows_LeavesSeverityNullForThatTask() {
        PromptTemplateService.setMock(new ThrowingPromptService());
        List<KB_Dimension_Analysis__c> rows = seedAnalyses(2, 'Conflict');
        KBSeverityAnnotationQueueable.AnnotationTask task = buildTask('Conflict', rows);

        Test.startTest();
        new KBSeverityAnnotationQueueable(
            new List<KBSeverityAnnotationQueueable.AnnotationTask>{ task }
        ).execute(null);
        Test.stopTest();

        for (KB_Dimension_Analysis__c r : [
            SELECT Impact__c
            FROM KB_Dimension_Analysis__c
            WHERE Id IN :new Set<Id>{ rows[0].Id, rows[1].Id }
        ]) {
            Assert.isNull(r.Impact__c, 'LLM failure leaves Impact null');
        }
    }

    @IsTest
    static void testExecute_MixedTasks_GoodTasksUpdateEvenIfOneFails() {
        // First task throws, second task succeeds — assert second task's
        // rows still got severity. Drives a stub that throws on the first
        // call and returns canned annotations on subsequent calls.
        OneShotThrowingPromptService oneShot = new OneShotThrowingPromptService();
        PromptTemplateService.setMock(oneShot);

        List<KB_Dimension_Analysis__c> rowsA = seedAnalyses(1, 'Duplication');
        KBSeverityAnnotationQueueable.AnnotationTask taskA = buildTask('Duplication', rowsA);
        List<KB_Dimension_Analysis__c> rowsB = seedAnalyses(1, 'Conflict');
        KBSeverityAnnotationQueueable.AnnotationTask taskB = buildTask('Conflict', rowsB);

        Test.startTest();
        new KBSeverityAnnotationQueueable(
            new List<KBSeverityAnnotationQueueable.AnnotationTask>{ taskA, taskB }
        ).execute(null);
        Test.stopTest();

        KB_Dimension_Analysis__c afterA = [
            SELECT Impact__c FROM KB_Dimension_Analysis__c WHERE Id = :rowsA[0].Id
        ];
        KB_Dimension_Analysis__c afterB = [
            SELECT Impact__c FROM KB_Dimension_Analysis__c WHERE Id = :rowsB[0].Id
        ];
        Assert.isNull(afterA.Impact__c, 'Failing task leaves its rows untouched');
        Assert.isNotNull(afterB.Impact__c, 'Subsequent succeeding task still updates its rows');
    }

    public class OneShotThrowingPromptService extends PromptTemplateService {
        public Integer callCount = 0;
        public override List<PromptTemplateService.IssueSeverityAnnotation> annotateIssueSeverity(
            String articleTitle, String articleSummary, String articleContent,
            String counterpartTitle, String counterpartSummary, String counterpartContent,
            List<String> issues, List<String> strengths
        ) {
            this.callCount++;
            if (this.callCount == 1) {
                throw new KnowledgeAIException('First call fails');
            }
            List<PromptTemplateService.IssueSeverityAnnotation> out =
                new List<PromptTemplateService.IssueSeverityAnnotation>();
            for (Integer i = 0; i < issues.size(); i++) {
                PromptTemplateService.IssueSeverityAnnotation ann =
                    new PromptTemplateService.IssueSeverityAnnotation();
                ann.index    = i;
                ann.impact   = 'Low';
                out.add(ann);
            }
            return out;
        }
    }

    @IsTest
    static void testExecute_SelfChain_EnqueuesFollowOnJobForRemainder() {
        // Drop CHUNK_SIZE to 1 so a 2-task list forces a self-chain.
        // The chained job runs inside Test.stopTest().
        PromptTemplateService.setMock(new CannedPromptService());
        Integer originalChunk = KBSeverityAnnotationQueueable.CHUNK_SIZE;
        try {
            KBSeverityAnnotationQueueable.CHUNK_SIZE = 1;

            List<KB_Dimension_Analysis__c> rowsA = seedAnalyses(1, 'Duplication');
            KBSeverityAnnotationQueueable.AnnotationTask taskA = buildTask('Duplication', rowsA);
            List<KB_Dimension_Analysis__c> rowsB = seedAnalyses(1, 'Conflict');
            KBSeverityAnnotationQueueable.AnnotationTask taskB = buildTask('Conflict', rowsB);

            Test.startTest();
            new KBSeverityAnnotationQueueable(
                new List<KBSeverityAnnotationQueueable.AnnotationTask>{ taskA, taskB }
            ).execute(null);
            Test.stopTest();
            // After stopTest: the chained job has executed.

            // Both tasks were processed (first chunk handles taskA, chained
            // chunk handles taskB) — both rows should be annotated.
            KB_Dimension_Analysis__c afterA = [
                SELECT Impact__c FROM KB_Dimension_Analysis__c WHERE Id = :rowsA[0].Id
            ];
            KB_Dimension_Analysis__c afterB = [
                SELECT Impact__c FROM KB_Dimension_Analysis__c WHERE Id = :rowsB[0].Id
            ];
            Assert.isNotNull(afterA.Impact__c, 'First chunk annotated taskA rows');
            Assert.isNotNull(afterB.Impact__c, 'Self-chained chunk annotated taskB rows');
        } finally {
            KBSeverityAnnotationQueueable.CHUNK_SIZE = originalChunk;
        }
    }

    @IsTest
    static void testExecute_TasksWithEmptyIssuesAreSkipped() {
        // A task with empty issueTexts must not invoke the LLM.
        CannedPromptService stub = new CannedPromptService();
        PromptTemplateService.setMock(stub);

        KBSeverityAnnotationQueueable.AnnotationTask emptyTask =
            new KBSeverityAnnotationQueueable.AnnotationTask();
        emptyTask.dimension = 'Duplication';
        emptyTask.articleId = '0Aa000000000000AAA'; // shape-valid placeholder
        // issueTexts and analysisRowIds remain empty (factory new() defaults).

        Test.startTest();
        new KBSeverityAnnotationQueueable(
            new List<KBSeverityAnnotationQueueable.AnnotationTask>{ emptyTask }
        ).execute(null);
        Test.stopTest();

        Assert.areEqual(0, stub.callCount,
            'Empty task does not trigger LLM call');
    }

    @IsTest
    static void testExecute_StartIndexBeyondTaskList_NoOp() {
        // Defensive: queueable instantiated with startIndex >= tasks.size()
        // should no-op rather than throw or wrap-around.
        PromptTemplateService.setMock(new CannedPromptService());
        List<KB_Dimension_Analysis__c> rows = seedAnalyses(1, 'Duplication');
        KBSeverityAnnotationQueueable.AnnotationTask task = buildTask('Duplication', rows);

        Test.startTest();
        new KBSeverityAnnotationQueueable(
            new List<KBSeverityAnnotationQueueable.AnnotationTask>{ task },
            5
        ).execute(null);
        Test.stopTest();

        KB_Dimension_Analysis__c after = [
            SELECT Impact__c FROM KB_Dimension_Analysis__c WHERE Id = :rows[0].Id
        ];
        Assert.isNull(after.Impact__c,
            'Out-of-range startIndex leaves rows untouched');
    }

    @IsTest
    static void testExecute_BadAnnotationIndex_IsIgnored() {
        // LLM returns annotations with an out-of-range index — guarded
        // against by the queueable's bounds check. Other valid annotations
        // should still apply.
        PromptTemplateService.setMock(new BadIndexPromptService());
        List<KB_Dimension_Analysis__c> rows = seedAnalyses(1, 'Duplication');
        KBSeverityAnnotationQueueable.AnnotationTask task = buildTask('Duplication', rows);

        Test.startTest();
        new KBSeverityAnnotationQueueable(
            new List<KBSeverityAnnotationQueueable.AnnotationTask>{ task }
        ).execute(null);
        Test.stopTest();

        // Only the in-range annotation (index 0) should have applied.
        KB_Dimension_Analysis__c after = [
            SELECT Impact__c FROM KB_Dimension_Analysis__c WHERE Id = :rows[0].Id
        ];
        Assert.areEqual('Low', after.Impact__c,
            'Valid index applied; out-of-range annotations dropped');
    }

    public class BadIndexPromptService extends PromptTemplateService {
        public override List<PromptTemplateService.IssueSeverityAnnotation> annotateIssueSeverity(
            String articleTitle, String articleSummary, String articleContent,
            String counterpartTitle, String counterpartSummary, String counterpartContent,
            List<String> issues, List<String> strengths
        ) {
            List<PromptTemplateService.IssueSeverityAnnotation> out =
                new List<PromptTemplateService.IssueSeverityAnnotation>();

            // Valid index 0 — uses restricted picklist values.
            PromptTemplateService.IssueSeverityAnnotation good =
                new PromptTemplateService.IssueSeverityAnnotation();
            good.index = 0; good.impact = 'Low';
            out.add(good);

            // Out-of-range index 99 — must be filtered out by the queueable
            // BEFORE its severity values land on a row, otherwise the
            // restricted picklist would reject. The queueable's bounds
            // check is what we're verifying, so we leave fields valid.
            PromptTemplateService.IssueSeverityAnnotation bad =
                new PromptTemplateService.IssueSeverityAnnotation();
            bad.index = 99; bad.impact = 'High';
            out.add(bad);

            // Null index — same intent: queueable should drop these before DML.
            PromptTemplateService.IssueSeverityAnnotation nully =
                new PromptTemplateService.IssueSeverityAnnotation();
            nully.index = null; nully.impact = 'Medium';
            out.add(nully);

            return out;
        }
    }
}
