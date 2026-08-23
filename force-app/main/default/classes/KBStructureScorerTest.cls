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
private class KBStructureScorerTest {

    @IsTest
    static void testDefaultConstructor() {
        Test.startTest();
        KBStructureScorer scorer = new KBStructureScorer();
        Test.stopTest();

        Assert.areEqual('Structure', scorer.getDimensionName());
    }

    @IsTest
    static void testGateFailNoContent() {
        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreStructure('', 'Some Title');
        Test.stopTest();

        Assert.areEqual(KBStructureScorer.GATE_FAIL_SCORE, result.score,
            'Empty content is a hard gate fail');
        Boolean hasBlocking = false;
        for (String issue : result.issues) {
            if (issue.contains('BLOCKING') && issue.toLowerCase().contains('content')) {
                hasBlocking = true; break;
            }
        }
        Assert.isTrue(hasBlocking, 'Missing content should produce a BLOCKING issue');
    }

    @IsTest
    static void testGateFailNullContent() {
        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreStructure(null, null);
        Test.stopTest();

        Assert.areEqual(KBStructureScorer.GATE_FAIL_SCORE, result.score,
            'Null content hits the gate-fail floor');
    }

    @IsTest
    static void testGateFailSkipsLLM() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreStructure('', 'Title');
        Test.stopTest();

        Assert.areEqual(0, mock.structureCallCount,
            'Gate failure should skip the LLM callout');
        Assert.areEqual(KBStructureScorer.GATE_FAIL_SCORE, result.score,
            'Gate failure should produce the fixed gate-fail score');
        Assert.areEqual(KBScorerBase.MODE_DETERMINISTIC, result.scorerMode,
            'A gate-fail that skips the LLM should be tagged Deterministic');
    }

    @IsTest
    static void testGatesPassLLMUnavailableFallsBackToBaseline() {
        // Gate passes (content present), no mock injected → the real
        // PromptTemplateService can't reach Einstein in the test context, so
        // the catch arm fires and the fallback is the LLM_FAILURE_SCORE
        // baseline. The deterministic checks have all been dropped per the
        // structure review, so there is no counted score to fall back to.
        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreStructure(
            '<p>' + 'word '.repeat(200) + '</p>',
            'How to Reset Your Password'
        );
        Test.stopTest();

        Assert.areEqual(KBStructureScorer.LLM_FAILURE_SCORE, result.score,
            'Gates pass with no LLM should bottom out at the baseline, not the gate-fail floor');
    }

    @IsTest
    static void testLLMScoreReplacesDeterministicWhenGatesPass() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 88;
        llm.success = true;
        llm.reasoning = 'Cleanly chunked, single topic.';
        llm.issues = new List<String>{ 'Resolution__c: minor cross-reference to "see above"' };
        llm.strengths = new List<String>{ 'Resolution__c: each section is self-contained' };
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreStructure(
            '<h2>Section 1</h2><p>' + 'word '.repeat(200) + '</p>',
            'How to Reset Your Password'
        );
        Test.stopTest();

        Assert.areEqual(1, mock.structureCallCount, 'Should make exactly one LLM call');
        Assert.areEqual(88, result.score,
            'LLM score should become the dimension score directly when gates pass');
        Assert.areEqual(KBScorerBase.MODE_HYBRID, result.scorerMode,
            'A successful LLM score should be tagged Hybrid');
 // LLM-contributed feedback surfaces verbatim — no '[LLM] ' prefix.
        Assert.isTrue(
            result.issues.contains('Resolution__c: minor cross-reference to "see above"'),
            'LLM-contributed feedback should be surfaced verbatim (no prefix)');
        for (String issue : result.issues) {
            Assert.isFalse(issue.startsWith('[LLM]'),
                'No issue should carry the retired [LLM] prefix');
        }
    }

    @IsTest
    static void testLLMScoreOfZeroIsPreserved() {
        // Mirrors the Completeness contract: a legitimate LLM score of 0
        // (worst-possible structure) must not be mistaken for "the LLM didn't
        // run" and overridden by the fallback baseline.
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 0;
        llm.success = true;
        llm.reasoning = 'Article is one giant paragraph with no internal structure.';
        llm.issues = new List<String>{ 'Solution__c: cannot chunk cleanly' };
        llm.strengths = new List<String>();
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreStructure(
            '<p>' + 'word '.repeat(200) + '</p>',
            'How to Reset Your Password'
        );
        Test.stopTest();

        Assert.areEqual(0, result.score,
            'A legitimate LLM score of 0 must be preserved, not overridden by the baseline');
    }

    @IsTest
    static void testLLMFailureFallsBackToBaseline() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.throwException = true;
        PromptTemplateService.setMock(mock);

        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreStructure(
            '<p>' + 'word '.repeat(200) + '</p>',
            'How to Reset Your Password'
        );
        Test.stopTest();

        Assert.areEqual(KBStructureScorer.LLM_FAILURE_SCORE, result.score,
            'LLM failure should fall back to the baseline, not the gate-fail floor');
        Assert.areEqual(KBScorerBase.MODE_LLM_FALLBACK, result.scorerMode,
            'A catch-arm fallback should be tagged LLM_Fallback_Deterministic, not Hybrid');
    }

    /**
 * Title and Summary must reach the Structure prompt as their OWN
     * dedicated inputs — never folded into the body Content — so a strong
     * title/summary still informs the structure judgement when the body is thin.
     */
    @IsTest
    static void testTitleAndSummaryPassedAsIndependentInputs() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 80;
        llm.success = true;
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.title = 'How to Reset Your Password';
        article.summary = 'Steps to reset a forgotten password from the login screen.';
        article.content = '<h3>Resolution__c</h3><p>' + 'word '.repeat(200) + '</p>';

        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        scorer.score(article);
        Test.stopTest();

        Assert.areEqual(1, mock.structureCallCount, 'LLM called once');
        Assert.areEqual('How to Reset Your Password', mock.lastStructureTitle,
            'Title threaded to the prompt as its own input');
        Assert.areEqual('Steps to reset a forgotten password from the login screen.',
            mock.lastStructureSummary,
            'Summary threaded to the prompt as its own input');
    }

    @IsTest
    static void testScoreViaArticleWrapper() {
        KBStructureScorer scorer = new KBStructureScorer();
        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.title = 'How to Reset Password';
        article.content = '<p>' + 'content '.repeat(200) + '</p>';

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.score(article);
        Test.stopTest();

        Assert.isTrue(result.score > 0, 'Should produce a valid score');
    }

    @IsTest
    static void testScoreViaArticleWrapper_NullArticle() {
        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.score(null);
        Test.stopTest();

        Assert.areEqual(KBStructureScorer.GATE_FAIL_SCORE, result.score,
            'Null article should hit gate-fail floor');
    }

    /**
     * Severity carry-through: when the LLM emits per-issue impact/effort/priority
     * via issueAnalyses, the scorer must thread those into result.issueAnalyses
     * so KBDimensionAnalysisService can stamp KB_Dimension_Analysis__c with
     * Impact__c / Effort__c / Priority__c. Pre-fix, the scorer iterated the
     * legacy issues string list only and dropped severity on the floor —
     * Improvements Inbox showed Structure issues without badges.
     */
    @IsTest
    static void testLLMSeverityFlowsIntoIssueAnalyses() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 65;
        llm.success = true;
        llm.issues = new List<String>{
            'Resolution__c: long paragraph with no internal structure',
            'Details__c: cross-reference "see above" loses meaning when split'
        };
        llm.issueAnalyses = new List<KBAssessmentModels.IssueAnalysis>{
            new KBAssessmentModels.IssueAnalysis(
                'Resolution__c: long paragraph with no internal structure',
                'High', 'Medium', 'High'
            ),
            new KBAssessmentModels.IssueAnalysis(
                'Details__c: cross-reference "see above" loses meaning when split',
                'Medium', 'Quick Win', 'Medium'
            )
        };
        llm.strengths = new List<String>();
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreStructure(
            '<p>' + 'word '.repeat(200) + '</p>', 'Some Article'
        );
        Test.stopTest();

        Assert.areEqual(2, result.issues.size(), 'Both LLM issues surfaced');
        Assert.areEqual(2, result.issueAnalyses.size(),
            'issueAnalyses populated in lockstep with issues');

        // Find each entry by text and assert severity made it through
        Map<String, KBAssessmentModels.IssueAnalysis> byText =
            new Map<String, KBAssessmentModels.IssueAnalysis>();
        for (KBAssessmentModels.IssueAnalysis ia : result.issueAnalyses) {
            byText.put(ia.text, ia);
        }
 // issue text carried through verbatim (no '[LLM] ' prefix).
        KBAssessmentModels.IssueAnalysis a = byText.get('Resolution__c: long paragraph with no internal structure');
        Assert.isNotNull(a, 'First issue carried through verbatim (no prefix)');
        Assert.areEqual('High', a.impact, 'Impact threaded from LLM');

        KBAssessmentModels.IssueAnalysis b = byText.get('Details__c: cross-reference "see above" loses meaning when split');
        Assert.isNotNull(b);
        Assert.areEqual('Medium', b.impact);
    }

    /**
     * Backward-compat: when the LLM doesn't emit issueAnalyses (older response
     * shape, defensive), the scorer must still surface the plain-string issues
     * via the legacy path, with null severity.
     */
    @IsTest
    static void testLLMNoIssueAnalyses_FallsBackToPlainIssues() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 70;
        llm.success = true;
        llm.issues = new List<String>{ 'Plain string issue' };
        llm.issueAnalyses = null;  // legacy shape — no severity
        llm.strengths = new List<String>();
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBStructureScorer scorer = new KBStructureScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreStructure(
            '<p>' + 'word '.repeat(200) + '</p>', 'Some Article'
        );
        Test.stopTest();

        Assert.areEqual(1, result.issues.size(), 'Plain-string issue surfaced via fallback path');
        Assert.areEqual(1, result.issueAnalyses.size(),
            'issueAnalyses kept in lockstep — addIssue() always appends both');
        Assert.isNull(result.issueAnalyses[0].impact,
            'Severity null when LLM did not emit it (legacy shape)');
    }
}
