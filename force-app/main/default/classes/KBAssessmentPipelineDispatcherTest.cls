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
@IsTest
private class KBAssessmentPipelineDispatcherTest {

    @IsTest
    static void testDispatchFinalization_NoRunFound() {
        // Non-existent run ID → should fall back to callback enqueue without throwing.
        // Build a syntactically valid 15-char Salesforce id (3-char keyPrefix + 12 padding).
        String prefix = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix();
        Id fakeRunId = Id.valueOf(prefix + '000000000000');
        Test.startTest();
        Boolean pipelineEnqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(fakeRunId);
        Test.stopTest();

        Assert.isFalse(pipelineEnqueued, 'Non-existent run falls back to callback (returns false)');
    }

    @IsTest
    static void testDispatchFinalization_NoPipelineRun_DirectCallback() {
        // Run with no Pipeline_Run__c → executionMode is null → shouldRunPipeline = false → direct callback
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 1,
            Pipeline_Run__c = null,
            Selected_Dimensions_JSON__c = '["Completeness","Structure"]'
        );
        insert run;

        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_Id__c = 'ka0FAKE000000001',
            Article_Title__c = 'Test'
        );

        Test.startTest();
        Boolean pipelineEnqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(run.Id);
        Test.stopTest();

        Assert.isFalse(pipelineEnqueued, 'No pipeline run → direct callback');
    }

    @IsTest
    static void testDispatchFinalization_NoArticleAssessments_FallsBackToCallback() {
        // Run exists but no KB_Article_Assessment__c rows → falls back
        KB_Pipeline_Run__c pipeline = new KB_Pipeline_Run__c(
            Execution_Modes__c = 'DEDUPLICATION',
            Status__c = 'Queued'
        );
        insert pipeline;

        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 0,
            Pipeline_Run__c = pipeline.Id,
            Selected_Dimensions_JSON__c = '["Duplication","Conflict"]'
        );
        insert run;

        Test.startTest();
        Boolean pipelineEnqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(run.Id);
        Test.stopTest();

        Assert.isFalse(pipelineEnqueued, 'No assessments → falls back to callback');
    }

    @IsTest
    static void testDispatchFinalization_WithDedupDims_EnqueuesPipeline() {
        KB_Pipeline_Run__c pipeline = new KB_Pipeline_Run__c(
            Execution_Modes__c = 'DEDUPLICATION',
            Status__c = 'Queued'
        );
        insert pipeline;

        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 1,
            Pipeline_Run__c = pipeline.Id,
            Selected_Dimensions_JSON__c = '["Completeness","Duplication","Conflict"]'
        );
        insert run;

        Knowledge__kav kav = new Knowledge__kav(
            Title = 'Dispatcher Test',
            UrlName = 'dispatcher-test-' + System.currentTimeMillis(),
            Language = 'en_US'
        );
        insert kav;

        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = kav.Id,
            Knowledge_Article_Id__c = kav.Id,
            Article_Title__c = 'Dispatcher Test'
        );

        // Inject a mock vector search returning no candidates — Tier2 will
        // then take the early-return path which is test-mode safe (production
        // would chain to KBAssessmentPipelineCallback, but that path is
        // guarded with Test.isRunningTest).
        VectorSearchFactory.setMock(new MockVectorSearchService());

        Test.startTest();
        Boolean pipelineEnqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(run.Id);
        Test.stopTest();

        Assert.isTrue(pipelineEnqueued, 'Dedup dims selected + pipeline run → enqueues Tier2');
        KB_Assessment_Run__c updated = [SELECT Status__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.areEqual('Pipeline Running', updated.Status__c, 'Status flipped to Pipeline Running');
    }

    @IsTest
    static void testDispatchFinalization_NoDedupDims_DirectCallback() {
        KB_Pipeline_Run__c pipeline = new KB_Pipeline_Run__c(
            Execution_Modes__c = 'DEDUPLICATION',
            Status__c = 'Queued'
        );
        insert pipeline;

        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 1,
            Pipeline_Run__c = pipeline.Id,
            Selected_Dimensions_JSON__c = '["Completeness","Structure","Clarity"]'
        );
        insert run;

        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_Id__c = 'ka0FAKE000000001',
            Article_Title__c = 'Test'
        );

        Test.startTest();
        Boolean pipelineEnqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(run.Id);
        Test.stopTest();

        Assert.isFalse(pipelineEnqueued, 'No pipeline-dependent dims → direct callback');
    }

    /**
     * Helper: build a fully-wired Run + Pipeline + Knowledge__kav + Assessment
     * with the given dimension scores. Returns the assessment record so tests
     * can assert against it. `scoreByDim` keys must be 'Completeness',
     * 'Structure', or 'Clarity'; null values are not inserted (simulates a
     * dimension that wasn't selected).
     */
    private static KB_Article_Assessment__c seedAssessment(Map<String, Decimal> scoreByDim, String selectedDimsJson) {
        KB_Pipeline_Run__c pipeline = new KB_Pipeline_Run__c(
            Execution_Modes__c = 'DEDUPLICATION',
            Status__c = 'Queued'
        );
        insert pipeline;

        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 1,
            Pipeline_Run__c = pipeline.Id,
            Selected_Dimensions_JSON__c = selectedDimsJson
        );
        insert run;

        Knowledge__kav kav = new Knowledge__kav(
            Title = 'Gate Test',
            UrlName = 'gate-test-' + System.currentTimeMillis() + '-' + Math.mod((Long) (Math.random() * 100000), 100000),
            Language = 'en_US'
        );
        insert kav;

        KB_Article_Assessment__c assessment = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = kav.Id,
            Knowledge_Article_Id__c = kav.Id,
            Article_Title__c = 'Gate Test'
        );
        insert assessment;

        List<KB_Dimension_Result__c> dims = new List<KB_Dimension_Result__c>();
        for (String dim : scoreByDim.keySet()) {
            Decimal score = scoreByDim.get(dim);
            if (score == null) continue;
            dims.add(new KB_Dimension_Result__c(
                Article_Assessment__c = assessment.Id,
                Dimension__c = dim,
                Score__c = score
            ));
        }
        if (!dims.isEmpty()) insert dims;

        return assessment;
    }

    @IsTest
    static void testQualityGateExcludesLowCompleteness() {
        // Default config: 60/60/60. Completeness=42 → article is gated.
        KB_Article_Assessment__c assessment = seedAssessment(
            new Map<String, Decimal>{
                'Completeness' => 42,
                'Structure'    => 80,
                'Clarity'      => 80
            },
            '["Completeness","Structure","Clarity","Duplication","Conflict"]'
        );

        VectorSearchFactory.setMock(new MockVectorSearchService());

        Test.startTest();
        Boolean enqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(assessment.Assessment_Run__c);
        Test.stopTest();

        Assert.isFalse(enqueued, 'All articles gated → falls back to callback (no Tier2)');
        KB_Article_Assessment__c reloaded = [
            SELECT Pipeline_Skip_Reason__c FROM KB_Article_Assessment__c WHERE Id = :assessment.Id
        ];
        Assert.areEqual(
            'Completeness 42 < threshold 60',
            reloaded.Pipeline_Skip_Reason__c,
            'Skip reason captures the failing dimension and threshold'
        );
    }

    @IsTest
    static void testQualityGatePassesEligibleArticle() {
        KB_Article_Assessment__c assessment = seedAssessment(
            new Map<String, Decimal>{
                'Completeness' => 80,
                'Structure'    => 75,
                'Clarity'      => 70
            },
            '["Completeness","Duplication","Conflict"]'
        );

        VectorSearchFactory.setMock(new MockVectorSearchService());

        Test.startTest();
        Boolean enqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(assessment.Assessment_Run__c);
        Test.stopTest();

        Assert.isTrue(enqueued, 'Eligible article enters Tier2');
        KB_Article_Assessment__c reloaded = [
            SELECT Pipeline_Skip_Reason__c FROM KB_Article_Assessment__c WHERE Id = :assessment.Id
        ];
        Assert.isNull(reloaded.Pipeline_Skip_Reason__c, 'No skip reason on a passing article');
    }

    @IsTest
    static void testQualityGateDisabledWhenAllZero() {
        // Inject CMDT mock with all three thresholds at 0 → gate disabled
        // even for an article that would otherwise fail every check.
        PipelineConfigService.setMockConfig(new KM_Pipeline_Config__mdt(
            Min_Completeness_Score__c = 0,
            Min_Structure_Score__c    = 0,
            Min_Clarity_Score__c      = 0,
            Tier2_TopK__c             = 20,
            Tier2_Similarity_Threshold__c = 0.75,
            Is_Active__c = true
        ));

        KB_Article_Assessment__c assessment = seedAssessment(
            new Map<String, Decimal>{
                'Completeness' => 10,
                'Structure'    => 10,
                'Clarity'      => 10
            },
            '["Completeness","Duplication","Conflict"]'
        );

        VectorSearchFactory.setMock(new MockVectorSearchService());

        Test.startTest();
        Boolean enqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(assessment.Assessment_Run__c);
        Test.stopTest();

        Assert.isTrue(enqueued, 'Gate disabled → low-quality article still enters Tier2');
        KB_Article_Assessment__c reloaded = [
            SELECT Pipeline_Skip_Reason__c FROM KB_Article_Assessment__c WHERE Id = :assessment.Id
        ];
        Assert.isNull(reloaded.Pipeline_Skip_Reason__c, 'No skip reason when gate disabled');
    }

    @IsTest
    static void testQualityGateBackwardsCompatMissingDimensions() {
        // Article only has Duplication scored — none of the gate dimensions present.
        // Backwards-compat rule: missing dimension passes the gate.
        KB_Article_Assessment__c assessment = seedAssessment(
            new Map<String, Decimal>{},
            '["Duplication"]'
        );
        // No KB_Dimension_Result__c rows for Completeness/Structure/Clarity.

        VectorSearchFactory.setMock(new MockVectorSearchService());

        Test.startTest();
        Boolean enqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(assessment.Assessment_Run__c);
        Test.stopTest();

        Assert.isTrue(enqueued, 'Duplication-only run: missing gate dims pass through');
        KB_Article_Assessment__c reloaded = [
            SELECT Pipeline_Skip_Reason__c FROM KB_Article_Assessment__c WHERE Id = :assessment.Id
        ];
        Assert.isNull(reloaded.Pipeline_Skip_Reason__c, 'No skip reason for missing-dims case');
    }

    @IsTest
    static void testDispatchFinalization_MalformedJSON_DefaultsFalse() {
        KB_Pipeline_Run__c pipeline = new KB_Pipeline_Run__c(
            Execution_Modes__c = 'DEDUPLICATION',
            Status__c = 'Queued'
        );
        insert pipeline;

        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 1,
            Pipeline_Run__c = pipeline.Id,
            Selected_Dimensions_JSON__c = 'NOT VALID JSON'
        );
        insert run;

        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_Id__c = 'ka0FAKE000000001',
            Article_Title__c = 'Test'
        );

        Test.startTest();
        Boolean pipelineEnqueued = KBAssessmentPipelineDispatcher.dispatchFinalization(run.Id);
        Test.stopTest();

        // After H5 fix: malformed JSON defaults to false (skip pipeline)
        Assert.isFalse(pipelineEnqueued, 'Malformed JSON → skip pipeline (safe default)');
    }
}
