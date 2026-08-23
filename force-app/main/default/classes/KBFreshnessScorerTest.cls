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
private class KBFreshnessScorerTest {

    @IsTest
    static void testDefaultConstructor() {
        Test.startTest();
        KBFreshnessScorer scorer = new KBFreshnessScorer();
        Test.stopTest();

        Assert.areEqual('Freshness', scorer.getDimensionName());
    }

    @IsTest
    static void testScoreFreshness_NullDate() {
        KBFreshnessScorer scorer = new KBFreshnessScorer();

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreFreshness(null);
        Test.stopTest();

        Assert.areEqual(50, result.score, 'Null date should return 50');
        Assert.isTrue(result.issues.size() > 0, 'Should have an issue about missing date');
        Assert.areEqual(KBScorerBase.MODE_DETERMINISTIC, result.scorerMode,
            'Freshness is always deterministic — never calls the LLM');
    }

    @IsTest
    static void testScoreFreshness_VeryFresh() {
        KBFreshnessScorer scorer = new KBFreshnessScorer();
        Datetime recent = Datetime.now().addDays(-5);

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreFreshness(recent);
        Test.stopTest();

        Assert.isTrue(result.score > 70, 'Very fresh article should score well');
        Assert.isTrue(result.strengths.size() > 0, 'Should have strengths');
        Boolean hasVeryFresh = false;
        for (String s : result.strengths) {
            if (s.contains('very fresh')) {
                hasVeryFresh = true;
                break;
            }
        }
        Assert.isTrue(hasVeryFresh, 'Should note very fresh');
        Assert.areEqual(KBScorerBase.MODE_DETERMINISTIC, result.scorerMode,
            'Freshness is always deterministic — never calls the LLM');
    }

    @IsTest
    static void testScoreFreshness_FewMonthsOld() {
        KBFreshnessScorer scorer = new KBFreshnessScorer();
        Datetime fewMonthsAgo = Datetime.now().addMonths(-4);

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreFreshness(fewMonthsAgo);
        Test.stopTest();

        Assert.isTrue(result.score > 50, 'Moderately fresh article should score decently');
        Assert.isTrue(result.strengths.size() > 0, 'Should have strengths');
    }

    @IsTest
    static void testScoreFreshness_WithinYear() {
        KBFreshnessScorer scorer = new KBFreshnessScorer();
        Datetime nineMonthsAgo = Datetime.now().addMonths(-9);

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreFreshness(nineMonthsAgo);
        Test.stopTest();

        Assert.isTrue(result.score > 50, 'Within-year article should score OK');
    }

    @IsTest
    static void testScoreFreshness_Stale() {
        KBFreshnessScorer scorer = new KBFreshnessScorer();
        Datetime eighteenMonthsAgo = Datetime.now().addMonths(-18);

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreFreshness(eighteenMonthsAgo);
        Test.stopTest();

        Boolean hasStaleIssue = false;
        for (String issue : result.issues) {
            if (issue.contains('stale') || issue.contains('reviewed')) {
                hasStaleIssue = true;
                break;
            }
        }
        Assert.isTrue(hasStaleIssue, 'Stale article should be flagged');
    }

    @IsTest
    static void testScoreFreshness_Critical() {
        KBFreshnessScorer scorer = new KBFreshnessScorer();
        Datetime threeYearsAgo = Datetime.now().addMonths(-36);

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreFreshness(threeYearsAgo);
        Test.stopTest();

        Assert.isTrue(result.score <= 50, 'Critically old article should score poorly');
        Boolean hasCritical = false;
        for (String issue : result.issues) {
            if (issue.contains('CRITICAL') || issue.contains('severely')) {
                hasCritical = true;
                break;
            }
        }
        Assert.isTrue(hasCritical, 'Critically old article should have critical issue');
    }

    @IsTest
    static void testScoreViaArticleWrapper() {
        KBFreshnessScorer scorer = new KBFreshnessScorer();
        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.title = 'Test Article';
        article.lastModifiedDate = Datetime.now().addMonths(-3);

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.score(article);
        Test.stopTest();

        Assert.isTrue(result.score > 0, 'Should produce a valid score');
    }

    @IsTest
    static void testScoreViaArticleWrapper_NullDate() {
        KBFreshnessScorer scorer = new KBFreshnessScorer();
        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.title = 'Test Article';
        article.lastModifiedDate = null;

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.score(article);
        Test.stopTest();

        Assert.areEqual(50, result.score, 'Null date via wrapper should return 50');
    }

    @IsTest
    static void testScoreFreshness_ExactThreshold() {
        KBFreshnessScorer scorer = new KBFreshnessScorer();
        // Default threshold is 12 months
        Datetime exactlyTwelveMonths = Datetime.now().addMonths(-12).addDays(-1);

        Test.startTest();
        KBAssessmentModels.DimensionScore result = scorer.scoreFreshness(exactlyTwelveMonths);
        Test.stopTest();

        Assert.isTrue(result.score >= 0 && result.score <= 100, 'Should produce valid score at threshold boundary');
    }
}
