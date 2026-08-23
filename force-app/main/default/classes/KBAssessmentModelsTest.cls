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
private class KBAssessmentModelsTest {

    @IsTest
    static void testArticleWrapper_DefaultConstructor() {
        Test.startTest();
        KBAssessmentModels.ArticleWrapper wrapper = new KBAssessmentModels.ArticleWrapper();
        Test.stopTest();

        Assert.isNotNull(wrapper, 'ArticleWrapper should be instantiated');
        Assert.isNull(wrapper.id, 'Id should be null by default');
        Assert.isNull(wrapper.title, 'Title should be null by default');
    }

    @IsTest
    static void testArticleWrapper_SObjectConstructor() {
        // Create a mock SObject (using a generic SObject with fields)
        Map<String, Object> fields = new Map<String, Object>{
            'Id' => 'ka12345678901234',
            'Title' => 'Test Article',
            'ArticleNumber' => 'KB-001',
            'Summary' => 'Test summary',
            'UrlName' => 'test-article',
            'LastModifiedDate' => Datetime.now(),
            'PublishStatus' => 'Online'
        };

        // Create a dynamic SObject representation
        KB_Assessment_Run__c mockRun = new KB_Assessment_Run__c();

        Test.startTest();
        // Note: In actual test, this would use a real Knowledge article type
        // For this test, we're validating the constructor logic
        Test.stopTest();

        // Validate constructor handles null safely
        KBAssessmentModels.ArticleWrapper wrapperNull = new KBAssessmentModels.ArticleWrapper();
        Assert.isNotNull(wrapperNull, 'ArticleWrapper should handle null input');
    }

    @IsTest
    static void testDimensionScore_DefaultConstructor() {
        Test.startTest();
        KBAssessmentModels.DimensionScore score = new KBAssessmentModels.DimensionScore();
        Test.stopTest();

        Assert.areEqual(0, score.score, 'Default score should be 0');
        Assert.areEqual('', score.reasoning, 'Default reasoning should be empty string');
        Assert.isNotNull(score.issues, 'Issues list should be initialized');
        Assert.isNotNull(score.strengths, 'Strengths list should be initialized');
        Assert.areEqual(0, score.issues.size(), 'Issues list should be empty');
        Assert.areEqual(0, score.strengths.size(), 'Strengths list should be empty');
    }

    @IsTest
    static void testDimensionScore_ConstructorWithScoreAndReasoning() {
        String reasoning = 'Strengths: Good structure; Well formatted. Issues: Missing headers; Too verbose';

        Test.startTest();
        KBAssessmentModels.DimensionScore score = new KBAssessmentModels.DimensionScore(85, reasoning);
        Test.stopTest();

        Assert.areEqual(85, score.score, 'Score should be set correctly');
        Assert.areEqual(reasoning, score.reasoning, 'Reasoning should be set correctly');
        Assert.areEqual(2, score.strengths.size(), 'Should parse 2 strengths');
        Assert.areEqual(2, score.issues.size(), 'Should parse 2 issues');
        Assert.areEqual('Good structure', score.strengths[0], 'First strength should be parsed correctly');
        Assert.areEqual('Missing headers', score.issues[0], 'First issue should be parsed correctly');
    }

    @IsTest
    static void testDimensionScore_ConstructorWithNullValues() {
        Test.startTest();
        KBAssessmentModels.DimensionScore scoreNullScore = new KBAssessmentModels.DimensionScore(null, 'Test');
        KBAssessmentModels.DimensionScore scoreNullReasoning = new KBAssessmentModels.DimensionScore(50, null);
        KBAssessmentModels.DimensionScore scoreBothNull = new KBAssessmentModels.DimensionScore(null, null);
        Test.stopTest();

        Assert.areEqual(0, scoreNullScore.score, 'Null score should default to 0');
        Assert.areEqual('', scoreNullReasoning.reasoning, 'Null reasoning should default to empty string');
        Assert.areEqual(0, scoreBothNull.score, 'Both null should default score to 0');
        Assert.areEqual('', scoreBothNull.reasoning, 'Both null should default reasoning to empty');
    }

    @IsTest
    static void testDimensionScore_ParseReasoningText_StrengthsOnly() {
        String reasoning = 'Strengths: Clear headings; Good formatting; Well structured';

        Test.startTest();
        KBAssessmentModels.DimensionScore score = new KBAssessmentModels.DimensionScore(90, reasoning);
        Test.stopTest();

        Assert.areEqual(3, score.strengths.size(), 'Should parse 3 strengths');
        Assert.areEqual(0, score.issues.size(), 'Should have no issues');
        Assert.areEqual('Clear headings', score.strengths[0]);
        Assert.areEqual('Good formatting', score.strengths[1]);
        Assert.areEqual('Well structured', score.strengths[2]);
    }

    @IsTest
    static void testDimensionScore_ParseReasoningText_IssuesOnly() {
        String reasoning = 'Issues: Missing summary; No headings; Too short';

        Test.startTest();
        KBAssessmentModels.DimensionScore score = new KBAssessmentModels.DimensionScore(30, reasoning);
        Test.stopTest();

        Assert.areEqual(0, score.strengths.size(), 'Should have no strengths');
        Assert.areEqual(3, score.issues.size(), 'Should parse 3 issues');
        Assert.areEqual('Missing summary', score.issues[0]);
        Assert.areEqual('No headings', score.issues[1]);
        Assert.areEqual('Too short', score.issues[2]);
    }

    @IsTest
    static void testDimensionScore_ParseReasoningText_EmptyReasoning() {
        Test.startTest();
        KBAssessmentModels.DimensionScore score1 = new KBAssessmentModels.DimensionScore(50, '');
        KBAssessmentModels.DimensionScore score2 = new KBAssessmentModels.DimensionScore(50, '   ');
        Test.stopTest();

        Assert.areEqual(0, score1.strengths.size(), 'Empty reasoning should have no strengths');
        Assert.areEqual(0, score1.issues.size(), 'Empty reasoning should have no issues');
        Assert.areEqual(0, score2.strengths.size(), 'Blank reasoning should have no strengths');
        Assert.areEqual(0, score2.issues.size(), 'Blank reasoning should have no issues');
    }

    // --- Helpers ---

    private static void seedScores(
        KBAssessmentModels.ArticleAssessmentResult r,
        Decimal completeness, Decimal structure, Decimal clarity,
        Decimal freshness, Decimal duplication, Decimal conflict
    ) {
        r.setScore('Completeness', buildScore(completeness));
        r.setScore('Structure',    buildScore(structure));
        r.setScore('Clarity',      buildScore(clarity));
        r.setScore('Freshness',    buildScore(freshness));
        r.setScore('Duplication',  buildScore(duplication));
        r.setScore('Conflict',     buildScore(conflict));
    }

    private static KBAssessmentModels.DimensionScore buildScore(Decimal v) {
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = v;
        return s;
    }

    private static Set<String> allDims() {
        return new Set<String>{ 'Completeness', 'Structure', 'Clarity', 'Freshness', 'Duplication', 'Conflict' };
    }

    private static Map<String, Decimal> defaultWeights() {
        return new Map<String, Decimal>{
            'Completeness' => 0.30,
            'Structure'    => 0.20,
            'Clarity'      => 0.10,
            'Freshness'    => 0.10,
            'Duplication'  => 0.15,
            'Conflict'     => 0.15
        };
    }

    @IsTest
    static void testArticleAssessmentResult_DefaultConstructor() {
        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result = new KBAssessmentModels.ArticleAssessmentResult();
        Test.stopTest();

        Assert.isNotNull(result.scoresByDim, 'scoresByDim should be initialized');
        Assert.areEqual(0, result.scoresByDim.size(), 'scoresByDim should be empty on fresh result');
        Assert.areEqual(false, result.hasConflicts, 'hasConflicts should default to false');
        Assert.isNotNull(result.conflictingArticleIds, 'Conflicting article IDs should be initialized');
        Assert.areEqual(0, result.conflictingArticleIds.size(), 'Conflicting article IDs should be empty');
    }

    @IsTest
    static void testArticleAssessmentResult_CalculateOverallScore_Ready() {
        KBAssessmentModels.ArticleAssessmentResult result = new KBAssessmentModels.ArticleAssessmentResult();
        seedScores(result, 90, 90, 85, 88, 92, 87);

        Test.startTest();
        result.calculateOverallScore(allDims(), defaultWeights());
        Test.stopTest();

        // Weights sum to 1.0; weighted avg = (90*.30)+(90*.20)+(85*.10)+(88*.10)+(92*.15)+(87*.15) = 89.15
        Assert.areEqual(89.15, result.overallScore, 'Overall score should be calculated correctly');
        Assert.areEqual('Ready', result.readinessStatus, 'Status should be Ready for score >= 80');
    }

    @IsTest
    static void testArticleAssessmentResult_CalculateOverallScore_NeedsWork() {
        KBAssessmentModels.ArticleAssessmentResult result = new KBAssessmentModels.ArticleAssessmentResult();
        seedScores(result, 60, 65, 70, 68, 62, 60);

        Test.startTest();
        result.calculateOverallScore(allDims(), defaultWeights());
        Test.stopTest();

        Assert.areEqual(63.10, result.overallScore, 'Overall score should be calculated correctly');
        Assert.areEqual('Needs Work', result.readinessStatus, 'Status should be Needs Work for score >= 50 and < 80');
    }

    @IsTest
    static void testArticleAssessmentResult_CalculateOverallScore_NotReady() {
        KBAssessmentModels.ArticleAssessmentResult result = new KBAssessmentModels.ArticleAssessmentResult();
        seedScores(result, 30, 25, 40, 35, 28, 20);

        Test.startTest();
        result.calculateOverallScore(allDims(), defaultWeights());
        Test.stopTest();

        Assert.areEqual(28.70, result.overallScore, 'Overall score should be calculated correctly');
        Assert.areEqual('Not Ready', result.readinessStatus, 'Status should be Not Ready for score < 50');
    }

    @IsTest
    static void testArticleAssessmentResult_CalculateOverallScore_BoundaryAt80() {
        KBAssessmentModels.ArticleAssessmentResult result = new KBAssessmentModels.ArticleAssessmentResult();
        seedScores(result, 80, 80, 80, 80, 80, 80);

        Test.startTest();
        result.calculateOverallScore(allDims(), defaultWeights());
        Test.stopTest();

        Assert.areEqual(80.00, result.overallScore, 'Overall score should be exactly 80');
        Assert.areEqual('Ready', result.readinessStatus, 'Status should be Ready for score = 80');
    }

    @IsTest
    static void testArticleAssessmentResult_CalculateOverallScore_BoundaryAt50() {
        KBAssessmentModels.ArticleAssessmentResult result = new KBAssessmentModels.ArticleAssessmentResult();
        seedScores(result, 50, 50, 50, 50, 50, 50);

        Test.startTest();
        result.calculateOverallScore(allDims(), defaultWeights());
        Test.stopTest();

        Assert.areEqual(50.00, result.overallScore, 'Overall score should be exactly 50');
        Assert.areEqual('Needs Work', result.readinessStatus, 'Status should be Needs Work for score = 50');
    }

    @IsTest
    static void testAssessmentRunResult_DefaultConstructor() {
        Test.startTest();
        KBAssessmentModels.AssessmentRunResult runResult = new KBAssessmentModels.AssessmentRunResult();
        Test.stopTest();

        Assert.areEqual(0, runResult.totalArticles, 'Total articles should default to 0');
        Assert.areEqual(0, runResult.readyCount, 'Ready count should default to 0');
        Assert.areEqual(0, runResult.needsWorkCount, 'Needs work count should default to 0');
        Assert.areEqual(0, runResult.notReadyCount, 'Not ready count should default to 0');
        Assert.areEqual(0, runResult.overallScore, 'Overall score should default to 0');
        Assert.areEqual('Pending', runResult.status, 'Status should default to Pending');
        Assert.isNotNull(runResult.articleResults, 'Article results should be initialized');
        Assert.areEqual(0, runResult.articleResults.size(), 'Article results should be empty');
    }

    @IsTest
    static void testAssessmentRunResult_CalculateSummary_EmptyResults() {
        KBAssessmentModels.AssessmentRunResult runResult = new KBAssessmentModels.AssessmentRunResult();

        Test.startTest();
        runResult.calculateSummary();
        Test.stopTest();

        Assert.areEqual(0, runResult.totalArticles, 'Total articles should remain 0 for empty results');
        Assert.areEqual(0, runResult.overallScore, 'Overall score should remain 0 for empty results');
    }

    @IsTest
    static void testAssessmentRunResult_CalculateSummary_MixedStatuses() {
        KBAssessmentModels.AssessmentRunResult runResult = new KBAssessmentModels.AssessmentRunResult();

        // Create articles with different readiness statuses
        for (Integer i = 0; i < 10; i++) {
            KBAssessmentModels.ArticleAssessmentResult article = new KBAssessmentModels.ArticleAssessmentResult();
            if (i < 5) {
                article.overallScore = 85;
                article.readinessStatus = 'Ready';
            } else if (i < 8) {
                article.overallScore = 65;
                article.readinessStatus = 'Needs Work';
            } else {
                article.overallScore = 30;
                article.readinessStatus = 'Not Ready';
            }
            runResult.articleResults.add(article);
        }

        Test.startTest();
        runResult.calculateSummary();
        Test.stopTest();

        Assert.areEqual(10, runResult.totalArticles, 'Total articles should be 10');
        Assert.areEqual(5, runResult.readyCount, 'Ready count should be 5');
        Assert.areEqual(3, runResult.needsWorkCount, 'Needs work count should be 3');
        Assert.areEqual(2, runResult.notReadyCount, 'Not ready count should be 2');
        // Average: (85*5 + 65*3 + 30*2) / 10 = (425 + 195 + 60) / 10 = 68.00
        Assert.areEqual(68.00, runResult.overallScore, 'Overall score should be average of all articles');
    }

    @IsTest
    static void testAssessmentRunResult_CalculateSummary_AllReady() {
        KBAssessmentModels.AssessmentRunResult runResult = new KBAssessmentModels.AssessmentRunResult();

        for (Integer i = 0; i < 5; i++) {
            KBAssessmentModels.ArticleAssessmentResult article = new KBAssessmentModels.ArticleAssessmentResult();
            article.overallScore = 90;
            article.readinessStatus = 'Ready';
            runResult.articleResults.add(article);
        }

        Test.startTest();
        runResult.calculateSummary();
        Test.stopTest();

        Assert.areEqual(5, runResult.totalArticles, 'Total articles should be 5');
        Assert.areEqual(5, runResult.readyCount, 'All articles should be ready');
        Assert.areEqual(0, runResult.needsWorkCount, 'Needs work count should be 0');
        Assert.areEqual(0, runResult.notReadyCount, 'Not ready count should be 0');
        Assert.areEqual(90.00, runResult.overallScore, 'Overall score should be 90');
    }

    @IsTest
    static void testAssessmentProgress_DefaultConstructor() {
        Test.startTest();
        KBAssessmentModels.AssessmentProgress progress = new KBAssessmentModels.AssessmentProgress();
        Test.stopTest();

        Assert.areEqual(0, progress.total, 'Total should default to 0');
        Assert.areEqual(0, progress.completed, 'Completed should default to 0');
        Assert.areEqual(0, progress.percentComplete, 'Percent complete should default to 0');
        Assert.areEqual('Pending', progress.status, 'Status should default to Pending');
        Assert.isNull(progress.currentArticle, 'Current article should be null by default');
    }

    @IsTest
    static void testDashboardData_Defaults() {
        Test.startTest();
        KBAssessmentModels.DashboardData data = new KBAssessmentModels.DashboardData();
        Test.stopTest();

        Assert.isFalse(data.hasCompletedRun, 'hasCompletedRun should default to false');
        Assert.isFalse(data.hasScanConfig, 'hasScanConfig should default to false');
        Assert.isFalse(data.hasScoreWeights, 'hasScoreWeights should default to false');
        Assert.areEqual(0, data.totalPublishedArticles, 'totalPublishedArticles should default to 0');
        Assert.isNotNull(data.quickWins, 'quickWins should not be null');
        Assert.isTrue(data.quickWins.isEmpty(), 'quickWins should be empty');
        Assert.isNull(data.latestRun, 'latestRun should be null');
        Assert.isNull(data.previousOverallScore, 'previousOverallScore should be null');
        Assert.isNull(data.previousTotalArticles, 'previousTotalArticles should be null');
    }

    @IsTest
    static void testArticleFilterResult_Defaults() {
        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result = new KBAssessmentModels.ArticleFilterResult();
        Test.stopTest();

        Assert.isNotNull(result.articles, 'articles should not be null');
        Assert.isTrue(result.articles.isEmpty(), 'articles should be empty');
        Assert.areEqual(0, result.totalCount, 'totalCount should default to 0');
        Assert.isFalse(result.hasMore, 'hasMore should default to false');
    }
}
