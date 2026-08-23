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
private class KBClarityScorerTest {

    @IsTest
    static void testDefaultConstructor() {
        Test.startTest();
        KBClarityScorer scorer = new KBClarityScorer();
        Test.stopTest();

        Assert.areEqual('Clarity', scorer.getDimensionName());
    }

    @IsTest
    static void testGateFailNoContent() {
        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreClarity('', 'Some Title');
        Test.stopTest();

        Assert.areEqual(KBClarityScorer.GATE_FAIL_SCORE, result.score,
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
        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreClarity(null, null);
        Test.stopTest();

        Assert.areEqual(KBClarityScorer.GATE_FAIL_SCORE, result.score,
            'Null content hits the gate-fail floor');
    }

    @IsTest
    static void testGateFailSkipsLLM() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreClarity('', 'Title');
        Test.stopTest();

        Assert.areEqual(0, mock.clarityCallCount,
            'Gate failure should skip the LLM callout');
        Assert.areEqual(KBClarityScorer.GATE_FAIL_SCORE, result.score);
        Assert.areEqual(KBScorerBase.MODE_DETERMINISTIC, result.scorerMode,
            'A gate-fail that skips the LLM should be tagged Deterministic');
    }

    @IsTest
    static void testGatesPassLLMUnavailableFallsBackToBaseline() {
        // No mock injected → the real PromptTemplateService can't reach Einstein
        // in the test context, so the LLM call returns no usable result and
        // the scorer falls back to LLM_FAILURE_BASELINE via the catch arm.
        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreClarity(
            '<p>Reset your password by clicking the Forgot Password link.</p>',
            'How to reset your password'
        );
        Test.stopTest();

        Assert.areEqual(KBClarityScorer.LLM_FAILURE_BASELINE, result.score,
            'LLM unavailable should fall back to the baseline');
    }

    @IsTest
    static void testLLMScoreReplacesDeterministicWhenGatesPass() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 88;
        llm.success = true;
        llm.reasoning = 'Clear, customer-friendly language.';
        llm.issues = new List<String>{ 'Pronoun "it" in para 3 lacks recoverable referent under 512-token chunks' };
        llm.strengths = new List<String>{ 'Acronyms expanded on first use' };
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreClarity(
            '<p>Reset the password using Settings &gt; Security.</p>',
            'How to reset your password'
        );
        Test.stopTest();

        Assert.areEqual(1, mock.clarityCallCount, 'Should make exactly one LLM call');
        Assert.areEqual(88, result.score,
            'LLM score should become the dimension score directly when gates pass');
        Assert.areEqual(KBScorerBase.MODE_HYBRID, result.scorerMode,
            'A successful LLM score should be tagged Hybrid');
 // LLM-contributed feedback surfaces verbatim — no '[LLM] ' prefix.
        Assert.isTrue(
            result.issues.contains('Pronoun "it" in para 3 lacks recoverable referent under 512-token chunks'),
            'LLM-contributed feedback should be surfaced verbatim (no prefix)');
        for (String issue : result.issues) {
            Assert.isFalse(issue.startsWith('[LLM]'),
                'No issue should carry the retired [LLM] prefix');
        }
    }

    @IsTest
    static void testLLMScoreOfZeroIsPreserved() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 0;
        llm.success = true;
        llm.reasoning = 'Article is unintelligible.';
        llm.issues = new List<String>();
        llm.strengths = new List<String>();
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreClarity(
            'Some content', 'Title'
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

        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreClarity(
            '<p>Reset your password.</p>', 'Password reset'
        );
        Test.stopTest();

        Assert.areEqual(KBClarityScorer.LLM_FAILURE_BASELINE, result.score,
            'LLM failure should fall back to the baseline');
        Assert.areEqual(KBScorerBase.MODE_LLM_FALLBACK, result.scorerMode,
            'A catch-arm fallback should be tagged LLM_Fallback_Deterministic, not Hybrid');
    }

    /**
 * Title and Summary must reach the Clarity prompt as their OWN
     * dedicated inputs — never folded into the body Content.
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
        article.content = '<p>Click Settings. Select Security. Choose Reset Password.</p>';

        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        scorer.score(article);
        Test.stopTest();

        Assert.areEqual(1, mock.clarityCallCount, 'LLM called once');
        Assert.areEqual('How to Reset Your Password', mock.lastClarityTitle,
            'Title threaded to the prompt as its own input');
        Assert.areEqual('Steps to reset a forgotten password from the login screen.',
            mock.lastClaritySummary,
            'Summary threaded to the prompt as its own input');
    }

    @IsTest
    static void testScoreViaArticleWrapper() {
        KBClarityScorer scorer = new KBClarityScorer();
        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.title = 'How to Reset Password';
        article.content = '<p>Click Settings. Select Security. Choose Reset Password.</p>';

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.score(article);
        Test.stopTest();

        Assert.isTrue(result.score > 0, 'Should produce a valid score');
    }

    @IsTest
    static void testScoreViaArticleWrapper_NullArticle() {
        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.score(null);
        Test.stopTest();

        Assert.areEqual(KBClarityScorer.GATE_FAIL_SCORE, result.score,
            'Null article should hit gate-fail floor');
    }

    /**
     * Severity carry-through: when the LLM emits per-issue impact/effort/priority
     * via issueAnalyses, the scorer must thread those into result.issueAnalyses
     * so KBDimensionAnalysisService can stamp KB_Dimension_Analysis__c with
     * Impact__c / Effort__c / Priority__c. Pre-fix, the scorer iterated the
     * legacy issues string list only and dropped severity on the floor —
     * Improvements Inbox showed Clarity issues without badges.
     */
    @IsTest
    static void testLLMSeverityFlowsIntoIssueAnalyses() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 65;
        llm.success = true;
        llm.issues = new List<String>{
            'Title contains 4 unexpanded acronyms',
            'Pronoun "it" in section 3 has no recoverable referent'
        };
        llm.issueAnalyses = new List<KBAssessmentModels.IssueAnalysis>{
            new KBAssessmentModels.IssueAnalysis(
                'Title contains 4 unexpanded acronyms', 'High', 'Low', 'High'
            ),
            new KBAssessmentModels.IssueAnalysis(
                'Pronoun "it" in section 3 has no recoverable referent',
                'Medium', 'Quick Win', 'Medium'
            )
        };
        llm.strengths = new List<String>();
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreClarity(
            '<p>' + 'word '.repeat(200) + '</p>', 'Some Article'
        );
        Test.stopTest();

        Assert.areEqual(2, result.issues.size(), 'Both LLM issues surfaced');
        Assert.areEqual(2, result.issueAnalyses.size(),
            'issueAnalyses populated in lockstep with issues');

        Map<String, KBAssessmentModels.IssueAnalysis> byText =
            new Map<String, KBAssessmentModels.IssueAnalysis>();
        for (KBAssessmentModels.IssueAnalysis ia : result.issueAnalyses) {
            byText.put(ia.text, ia);
        }
 // issue text carried through verbatim (no '[LLM] ' prefix).
        KBAssessmentModels.IssueAnalysis a = byText.get('Title contains 4 unexpanded acronyms');
        Assert.isNotNull(a);
        Assert.areEqual('High', a.impact);

        KBAssessmentModels.IssueAnalysis b = byText.get('Pronoun "it" in section 3 has no recoverable referent');
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
        llm.issueAnalyses = null;
        llm.strengths = new List<String>();
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBClarityScorer scorer = new KBClarityScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreClarity(
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
