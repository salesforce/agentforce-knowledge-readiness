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
private class KBCompletenessScorerTest {

    @IsTest
    static void testDefaultConstructor() {
        Test.startTest();
        KBCompletenessScorer scorer = new KBCompletenessScorer();
        Test.stopTest();

        Assert.areEqual('Completeness', scorer.getDimensionName());
    }

    @IsTest
    static void testGatesPassDeterministicOnly() {
        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'How to Reset Your Password',
            'This is a complete summary explaining the steps.',
            'content '.repeat(300),
            true, false, 2
        );
        Test.stopTest();

        // Gates pass + LLM disabled → counting model on deterministic signals.
        Assert.isTrue(result.score > KBCompletenessScorer.GATE_FAIL_SCORE,
            'Article passing all gates should score above the gate-fail floor');
        Assert.isTrue(result.strengths.size() > 0, 'Should have strengths');
    }

    @IsTest
    static void testGateFailMissingTitle() {
        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            '', 'A reasonable summary', 'content '.repeat(100),
            true, false, 1
        );
        Test.stopTest();

        Assert.areEqual(KBCompletenessScorer.GATE_FAIL_SCORE, result.score,
            'Missing title is a hard gate fail and bottoms out the score');
        Boolean hasBlocking = false;
        for (String issue : result.issues) {
            if (issue.contains('BLOCKING') && issue.contains('title')) { hasBlocking = true; break; }
        }
        Assert.isTrue(hasBlocking, 'Missing title should produce a BLOCKING issue');
    }

    @IsTest
    static void testGateFailMissingSummary() {
        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'Reasonable Article Title', '', 'content '.repeat(100),
            false, false, 1
        );
        Test.stopTest();

        Assert.areEqual(KBCompletenessScorer.GATE_FAIL_SCORE, result.score,
            'Missing summary is a hard gate fail');
    }

    @IsTest
    static void testGateFailMissingBody() {
        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'Reasonable Article Title', 'Summary text here that is long enough', '',
            true, false, 1
        );
        Test.stopTest();

        Assert.areEqual(KBCompletenessScorer.GATE_FAIL_SCORE, result.score,
            'Missing body is a hard gate fail');
    }

    @IsTest
    static void testGateFailNullValues() {
        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            null, null, null, null, null, null
        );
        Test.stopTest();

        Assert.areEqual(KBCompletenessScorer.GATE_FAIL_SCORE, result.score,
            'All-null inputs hit gate-fail floor');
    }

    @IsTest
    static void testGateFailTitleTooFewWords() {
        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'Quick Help',
            'A reasonable summary of the article.',
            'content '.repeat(100),
            true, false, 1
        );
        Test.stopTest();

        Assert.areEqual(KBCompletenessScorer.GATE_FAIL_SCORE, result.score,
            'Two-word title fails the word-count gate');
    }

    @IsTest
    static void testTitleLengthThresholdIsApplied() {
        // Min_Title_Length__c is admin-configurable directly on the
        // KB_Scan_Config__c custom setting; the scorer must read it and gate-fail
        // titles shorter than the configured value.
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Min_Title_Length__c = 50;
        upsert cfg;

        KBCompletenessScorer scorer = new KBCompletenessScorer();

        // 30-char, 6-word title — passes word-count gate, fails the 50-char threshold.
        String shortTitle = 'How to Reset Your Password Now'; // 30 chars, 6 words
        Assert.isTrue(shortTitle.length() < 50, 'Test fixture must be shorter than configured threshold');

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            shortTitle,
            'A reasonable summary of the article.',
            'content '.repeat(100),
            true, false, 1
        );
        Test.stopTest();

        Assert.areEqual(KBCompletenessScorer.GATE_FAIL_SCORE, result.score,
            'Title shorter than configured Min_Title_Length__c must hit gate-fail floor');

        Boolean hasShortTitleIssue = false;
        for (String issue : result.issues) {
            if (issue.contains('too short') && issue.contains('50')) {
                hasShortTitleIssue = true;
                break;
            }
        }
        Assert.isTrue(hasShortTitleIssue,
            'Issue text must cite the configured threshold so users know which knob to turn');
    }

    @IsTest
    static void testTitleLengthThresholdRespectedWhenLowered() {
        // Inverse: with a low threshold, a short-but-multi-word title should
        // pass the title gate (so the test isolates the threshold rule from
        // the word-count rule).
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Min_Title_Length__c = 5;
        upsert cfg;

        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'How to Reset Password', // 21 chars, 4 words — passes both gates with threshold=5
            'A reasonable summary of the article.',
            'content '.repeat(100),
            true, false, 1
        );
        Test.stopTest();

        Assert.isTrue(result.score > KBCompletenessScorer.GATE_FAIL_SCORE,
            'Title above configured threshold should not bottom out the score');
    }

    @IsTest
    static void testLinkHeavyContentFlagged() {
        KBCompletenessScorer scorer = new KBCompletenessScorer();
        // Build content where >30% of word count is link text.
        String linkHeavy = '<p>See here: <a href="x">' + 'click here '.repeat(40) + '</a></p>'
            + '<p>Some surrounding text not in links.</p>';

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'Article on Refund Process',
            'Summary describing the refund process briefly.',
            linkHeavy,
            true, false, 1
        );
        Test.stopTest();

        Boolean hasLinkIssue = false;
        for (String issue : result.issues) {
            if (issue.contains('link-heavy')) { hasLinkIssue = true; break; }
        }
        Assert.isTrue(hasLinkIssue, 'Link-heavy content should be flagged');
    }

    @IsTest
    static void testSummaryEqualsTitleFlagged() {
        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'Refund Policy Overview',
            'Refund Policy Overview',
            'content '.repeat(100),
            true, false, 1
        );
        Test.stopTest();

        Boolean hasSummaryIssue = false;
        for (String issue : result.issues) {
            if (issue.contains('identical to title')) { hasSummaryIssue = true; break; }
        }
        Assert.isTrue(hasSummaryIssue, 'Summary equal to title should be flagged');
    }

    @IsTest
    static void testUsesDataCategoriesOffMakesMissingCategoriesInformational() {
        // Default config: Uses_Data_Categories__c = false.
        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'Reasonable Article Title',
            'A reasonable summary of the article.',
            'content '.repeat(100),
            true, false, 0
        );
        Test.stopTest();

        Boolean hasCategoryIssue = false;
        for (String issue : result.issues) {
            if (issue.toLowerCase().contains('data categor')) { hasCategoryIssue = true; break; }
        }
        Assert.isFalse(hasCategoryIssue,
            'When the org does not use data categories, missing categories should not be a scored issue');
    }

    @IsTest
    static void testUsesDataCategoriesOnPenalisesMissingCategories() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Uses_Data_Categories__c = true;
        upsert cfg;

        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'Reasonable Article Title',
            'A reasonable summary of the article.',
            'content '.repeat(100),
            true, false, 0
        );
        Test.stopTest();

        Boolean hasCategoryIssue = false;
        for (String issue : result.issues) {
            if (issue.toLowerCase().contains('data categor')) { hasCategoryIssue = true; break; }
        }
        Assert.isTrue(hasCategoryIssue,
            'When the org uses data categories, missing categories should be a scored issue');
    }

    @IsTest
    static void testLLMScoreReplacesDeterministicWhenGatesPass() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 88;
        llm.success = true;
        llm.reasoning = 'Strong substantive content.';
        llm.issues = new List<String>{ 'Refund_Policy__c: hedges on edge cases' };
        llm.strengths = new List<String>{ 'Resolution__c: concrete steps and codes' };
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'How to Reset Your Password',
            'A complete summary describing the reset flow.',
            'content '.repeat(100),
            true, false, 1
        );
        Test.stopTest();

        Assert.areEqual(1, mock.completenessCallCount,
            'Should make exactly one LLM call (consolidated template)');
        Assert.areEqual(88, result.score,
            'LLM score should become the dimension score directly when gates pass');
        Assert.areEqual(KBScorerBase.MODE_HYBRID, result.scorerMode,
            'A successful LLM score should be tagged Hybrid');
 // LLM-contributed feedback surfaces verbatim — no '[LLM] ' prefix.
        Assert.isTrue(result.issues.contains('Refund_Policy__c: hedges on edge cases'),
            'LLM-contributed feedback should be surfaced verbatim (no prefix)');
        for (String issue : result.issues) {
            Assert.isFalse(issue.startsWith('[LLM]'),
                'No issue should carry the retired [LLM] prefix');
        }
    }

    @IsTest
    static void testLLMScoreOfZeroIsPreserved() {
        // Contract: a legitimate LLM score of 0 (worst possible article) must not be
        // mistaken for "the LLM didn't run" and overridden by the counting model.
        // Pre-fix, the post-LLM check was `score == null || score == 0` which
        // collided with the DimensionScore default of 0; now it's `score == null` only.
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.LLMEvaluationResult llm = new PromptTemplateService.LLMEvaluationResult();
        llm.score = 0;
        llm.success = true;
        llm.reasoning = 'Article has no substantive content of any kind.';
        llm.issues = new List<String>{ 'Resolution: pure redirect, no content' };
        llm.strengths = new List<String>();
        mock.mockLLMResult = llm;
        PromptTemplateService.setMock(mock);

        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'How to Reset Your Password',
            'A complete summary describing the reset flow.',
            'content '.repeat(100),
            true, false, 1
        );
        Test.stopTest();

        Assert.areEqual(0, result.score,
            'A legitimate LLM score of 0 must be preserved, not overridden by the counting model');
    }

    @IsTest
    static void testGateFailSkipsLLM() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        // No title — gate fails, LLM should be skipped to avoid wasting a callout.
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            '', 'A summary', 'content '.repeat(50),
            true, false, 1
        );
        Test.stopTest();

        Assert.areEqual(0, mock.completenessCallCount,
            'Gate failure should skip the LLM callout');
        Assert.areEqual(KBCompletenessScorer.GATE_FAIL_SCORE, result.score,
            'Gate failure should produce the fixed gate-fail score');
        Assert.areEqual(KBScorerBase.MODE_DETERMINISTIC, result.scorerMode,
            'A gate-fail that skips the LLM should be tagged Deterministic');
    }

    @IsTest
    static void testLLMFailureFallsBackToCounting() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.throwException = true;
        PromptTemplateService.setMock(mock);

        KBCompletenessScorer scorer = new KBCompletenessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreCompleteness(
            'How to Reset Your Password',
            'A complete summary describing the reset flow.',
            'content '.repeat(100),
            true, false, 1
        );
        Test.stopTest();

        // LLM threw — should fall back to deterministic counting on the gate signals.
        Assert.isTrue(result.score > KBCompletenessScorer.GATE_FAIL_SCORE,
            'LLM failure should fall back to counting model, not the gate-fail floor');
        Assert.isTrue(result.score <= 100, 'Score must remain in valid range');
        Assert.areEqual(KBScorerBase.MODE_LLM_FALLBACK, result.scorerMode,
            'A catch-arm fallback should be tagged LLM_Fallback_Deterministic, not Hybrid');
    }

    @IsTest
    static void testScoreViaArticleWrapper() {
        KBCompletenessScorer scorer = new KBCompletenessScorer();
        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.title = 'How to Reset Password';
        article.summary = 'Steps to reset your password effectively.';
        article.content = '<p>' + 'content '.repeat(200) + '</p>';
        article.dataCategories = 1;

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.score(article);
        Test.stopTest();

        Assert.isTrue(result.score > 0, 'Should produce a valid score');
        Assert.isTrue(result.score > KBCompletenessScorer.GATE_FAIL_SCORE,
            'Wrapper happy path should not bottom out');
    }
}
