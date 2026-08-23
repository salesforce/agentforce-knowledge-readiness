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
private class KBScorerBaseTest {

    // enhanceWithLLM is protected — expose it via a same-hierarchy subclass
    // so the default no-op implementation is directly testable.
    private class TestableScorer extends KBScorerBase {
        public KBAssessmentModels.DimensionScore callEnhanceWithLLM(
            KBAssessmentModels.DimensionScore deterministicResult,
            KBAssessmentModels.ArticleWrapper article
        ) {
            return enhanceWithLLM(deterministicResult, article);
        }
    }

    @IsTest
    static void testEnhanceWithLLM_DefaultNoOp_ReturnsDeterministicResultUnchanged() {
        TestableScorer scorer = new TestableScorer();
        KBAssessmentModels.DimensionScore det = new KBAssessmentModels.DimensionScore();
        det.score = 55;

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.callEnhanceWithLLM(det, new KBAssessmentModels.ArticleWrapper());
        Test.stopTest();

        Assert.areEqual(det, result, 'Default enhanceWithLLM is a no-op — returns the same instance');
    }

    @IsTest
    static void testMergeLlmResult_IssueAnalyses_MergesAndSkipsBlankAndDuplicate() {
        KBScorerBase scorer = new KBScorerBase();
        KBAssessmentModels.DimensionScore det = new KBAssessmentModels.DimensionScore();
        det.score = 70;
        det.issues.add('already there');

        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.success = true;
        llm.issueAnalyses.add(new KBAssessmentModels.IssueAnalysis(null, 'High', null, null));
        llm.issueAnalyses.add(new KBAssessmentModels.IssueAnalysis('already there', 'High', null, null));
        llm.issueAnalyses.add(new KBAssessmentModels.IssueAnalysis('new issue', 'Medium', null, null));

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.mergeLlmResult(det, llm);
        Test.stopTest();

        Assert.areEqual(2, result.issues.size(),
            'Null-text and duplicate issueAnalyses entries are skipped; only the new one is added');
        Assert.isTrue(result.issues.contains('new issue'), 'New issueAnalyses entry merged in');
    }

    @IsTest
    static void testDefaultConstructor() {
        Test.startTest();
        KBScorerBase scorer = new KBScorerBase();
        Test.stopTest();

        Assert.isNotNull(scorer, 'Base scorer should instantiate');
        Assert.areEqual('Base', scorer.getDimensionName(), 'Default dimension name should be Base');
    }

    @IsTest
    static void testScoreReturnsEmptyDefault() {
        KBScorerBase scorer = new KBScorerBase();
        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.score(article);
        Test.stopTest();

        Assert.areEqual(0, result.score, 'Default score should be 0');
        Assert.isTrue(result.issues.isEmpty(), 'Default should have no issues');
        Assert.isTrue(result.strengths.isEmpty(), 'Default should have no strengths');
    }

    // ==================== calculateScoreFromFeedback ====================

    @IsTest
    static void testCalculateScore_NoFeedback() {
        KBScorerBase scorer = new KBScorerBase();

        Test.startTest();
        Decimal score = scorer.calculateScoreFromFeedback(0, 0);
        Test.stopTest();

        Assert.areEqual(75, score, 'No feedback should return 75');
    }

    @IsTest
    static void testCalculateScore_OnlyStrengths() {
        KBScorerBase scorer = new KBScorerBase();

        Test.startTest();
        Decimal score = scorer.calculateScoreFromFeedback(3, 0);
        Test.stopTest();

        Assert.areEqual(88, score, '3 strengths: 70 + 18 = 88');
    }

    @IsTest
    static void testCalculateScore_MaxStrengths() {
        KBScorerBase scorer = new KBScorerBase();

        Test.startTest();
        Decimal score = scorer.calculateScoreFromFeedback(10, 0);
        Test.stopTest();

        Assert.areEqual(100, score, 'Max strengths should cap at 100');
    }

    @IsTest
    static void testCalculateScore_OnlyIssues() {
        KBScorerBase scorer = new KBScorerBase();

        Test.startTest();
        Decimal score = scorer.calculateScoreFromFeedback(0, 3);
        Test.stopTest();

        Assert.areEqual(40, score, '3 issues: 70 - 30 = 40');
    }

    @IsTest
    static void testCalculateScore_MaxIssues() {
        KBScorerBase scorer = new KBScorerBase();

        Test.startTest();
        Decimal score = scorer.calculateScoreFromFeedback(0, 10);
        Test.stopTest();

        Assert.areEqual(30, score, 'Max issues: 70 - 40 = 30');
    }

    @IsTest
    static void testCalculateScore_MixedFeedback() {
        KBScorerBase scorer = new KBScorerBase();

        Test.startTest();
        Decimal score = scorer.calculateScoreFromFeedback(4, 1);
        Test.stopTest();

        Assert.areEqual(84, score, '4 strengths 1 issue: 70 + 24 - 10 = 84');
    }

    @IsTest
    static void testCalculateScore_FloorAt20() {
        KBScorerBase scorer = new KBScorerBase();

        Test.startTest();
        Decimal score = scorer.calculateScoreFromFeedback(0, 5);
        Test.stopTest();

        Assert.isTrue(score >= 20, 'Score should not go below 20');
    }

    // ==================== buildReasoning ====================

    @IsTest
    static void testBuildReasoning_NoFeedback() {
        KBScorerBase scorer = new KBScorerBase();
        KBAssessmentModels.DimensionScore dimScore = new KBAssessmentModels.DimensionScore();

        Test.startTest();
        String reasoning = scorer.buildReasoning(dimScore, 'Structure');
        Test.stopTest();

        Assert.areEqual('Structure meets basic requirements.', reasoning);
    }

    @IsTest
    static void testBuildReasoning_WithStrengths() {
        KBScorerBase scorer = new KBScorerBase();
        KBAssessmentModels.DimensionScore dimScore = new KBAssessmentModels.DimensionScore();
        dimScore.strengths.add('Good length');
        dimScore.strengths.add('Clear headings');

        Test.startTest();
        String reasoning = scorer.buildReasoning(dimScore, 'Structure');
        Test.stopTest();

        Assert.isTrue(reasoning.contains('Strengths:'), 'Should contain Strengths label');
        Assert.isTrue(reasoning.contains('Good length'), 'Should contain first strength');
        Assert.isTrue(reasoning.contains('Clear headings'), 'Should contain second strength');
    }

    @IsTest
    static void testBuildReasoning_WithIssues() {
        KBScorerBase scorer = new KBScorerBase();
        KBAssessmentModels.DimensionScore dimScore = new KBAssessmentModels.DimensionScore();
        dimScore.issues.add('Too short');

        Test.startTest();
        String reasoning = scorer.buildReasoning(dimScore, 'Clarity');
        Test.stopTest();

        Assert.isTrue(reasoning.contains('Issues:'), 'Should contain Issues label');
        Assert.isTrue(reasoning.contains('Too short'), 'Should contain issue text');
    }

    @IsTest
    static void testBuildReasoning_Mixed() {
        KBScorerBase scorer = new KBScorerBase();
        KBAssessmentModels.DimensionScore dimScore = new KBAssessmentModels.DimensionScore();
        dimScore.strengths.add('Good content');
        dimScore.issues.add('Missing headings');

        Test.startTest();
        String reasoning = scorer.buildReasoning(dimScore, 'Structure');
        Test.stopTest();

        Assert.isTrue(reasoning.contains('Strengths:'), 'Should have strengths section');
        Assert.isTrue(reasoning.contains('Issues:'), 'Should have issues section');
    }

    // ==================== getMonthsSince ====================

    @IsTest
    static void testGetMonthsSince_Null() {
        KBScorerBase scorer = new KBScorerBase();

        Test.startTest();
        Integer months = scorer.getMonthsSince(null);
        Test.stopTest();

        Assert.areEqual(0, months, 'Null datetime should return 0 months');
    }

    @IsTest
    static void testGetMonthsSince_Recent() {
        KBScorerBase scorer = new KBScorerBase();
        Datetime recent = Datetime.now().addDays(-15);

        Test.startTest();
        Integer months = scorer.getMonthsSince(recent);
        Test.stopTest();

        Assert.areEqual(0, months, '15 days ago should be 0 months');
    }

    @IsTest
    static void testGetMonthsSince_SixMonthsAgo() {
        KBScorerBase scorer = new KBScorerBase();
        Datetime sixMonthsAgo = Datetime.now().addMonths(-6);

        Test.startTest();
        Integer months = scorer.getMonthsSince(sixMonthsAgo);
        Test.stopTest();

        Assert.isTrue(months >= 5 && months <= 7, 'Should be approximately 6 months: ' + months);
    }

    // ==================== mergeLlmResult ====================

    @IsTest
    static void testMergeLlmResult_NullResult_NoOp() {
        KBScorerBase scorer = new KBScorerBase();
        KBAssessmentModels.DimensionScore det = new KBAssessmentModels.DimensionScore();
        det.score = 80;
        det.strengths.add('keep me');

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.mergeLlmResult(det, null);
        Test.stopTest();

        Assert.areEqual(80, result.score, 'Score unchanged when llmResult is null');
        Assert.areEqual(1, result.strengths.size(), 'Strengths unchanged');
    }

    @IsTest
    static void testMergeLlmResult_FailedLlm_NoOp() {
        KBScorerBase scorer = new KBScorerBase();
        KBAssessmentModels.DimensionScore det = new KBAssessmentModels.DimensionScore();
        det.score = 70;
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.success = false;
        llm.issues.add('should be ignored');

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.mergeLlmResult(det, llm);
        Test.stopTest();

        Assert.areEqual(70, result.score, 'Score unchanged when llmResult failed');
        Assert.isTrue(result.issues.isEmpty(), 'Failed LLM issues not merged');
    }

    @IsTest
    static void testMergeLlmResult_SuccessMergesAndRecalculates() {
        KBScorerBase scorer = new KBScorerBase();
        KBAssessmentModels.DimensionScore det = new KBAssessmentModels.DimensionScore();
        det.score = 70;
        det.strengths.add('deterministic strength');
        det.issues.add('deterministic issue');

        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.success = true;
        llm.strengths.add('llm strength');
        llm.issues.add('llm issue');

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.mergeLlmResult(det, llm);
        Test.stopTest();

        Assert.areEqual(2, result.strengths.size(), 'Should have deterministic + LLM strength');
        Assert.areEqual(2, result.issues.size(), 'Should have deterministic + LLM issue');
 // LLM-contributed items are surfaced verbatim — no '[LLM] ' prefix.
        Assert.areEqual('llm strength', result.strengths.get(1),
            'LLM-contributed strength surfaced verbatim (no prefix)');
        Assert.areEqual('llm issue', result.issues.get(1),
            'LLM-contributed issue surfaced verbatim (no prefix)');
    }
}
