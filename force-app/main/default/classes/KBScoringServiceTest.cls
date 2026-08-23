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
private class KBScoringServiceTest {

    private static KBAssessmentModels.ArticleWrapper buildArticle(String title, String summary, String content) {
        KBAssessmentModels.ArticleWrapper w = new KBAssessmentModels.ArticleWrapper();
        w.id = 'ka0FAKE000000001';
        w.title = title;
        w.summary = summary;
        w.content = content;
        w.dataCategories = 2;
        w.lastModifiedDate = Datetime.now().addMonths(-3);
        return w;
    }

    // ==================== Construction ====================

    @IsTest
    static void testConstructor_Default() {
        Test.startTest();
        KBScoringService service = new KBScoringService();
        Test.stopTest();

        Assert.isNotNull(service, 'Default constructor should instantiate');
    }

    // ==================== scoreDimensions — full pass ====================

    @IsTest
    static void testScoreDimensions_AllDimensions_HappyPath() {
        KBScoringService service = new KBScoringService();
        String goodContent = '';
        for (Integer i = 0; i < 300; i++) { goodContent += 'word '; }
        KBAssessmentModels.ArticleWrapper article = buildArticle(
            'How to Reset Your Password in Salesforce',
            'This article explains the step-by-step process to reset your password.',
            goodContent
        );

        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result =
            service.scoreDimensions(article, null, null, null, null);
        Test.stopTest();

        Assert.isNotNull(result.getScore('Completeness'), 'Completeness populated');
        Assert.isNotNull(result.getScore('Structure'), 'Structure populated');
        Assert.isNotNull(result.getScore('Clarity'), 'Clarity populated');
        Assert.isNotNull(result.getScore('Freshness'), 'Freshness populated');
        Assert.isNotNull(result.getScore('Duplication'), 'Duplication populated (bridge returns default)');
        Assert.isNotNull(result.getScore('Conflict'), 'Conflict populated (bridge returns default)');
        Assert.areEqual(article.id, result.articleId, 'Article id mapped');
        Assert.areEqual(article.title, result.articleTitle, 'Article title mapped');
    }

    @IsTest
    static void testScoreDimensions_NullArticle_ReturnsEmptyResult() {
        KBScoringService service = new KBScoringService();

        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result =
            service.scoreDimensions(null, null, null, null, null);
        Test.stopTest();

        Assert.isNotNull(result, 'Result should be non-null');
        Assert.isNull(result.articleId, 'No article id when article is null');
    }

    @IsTest
    static void testScoreDimensions_EmptyContent_StructureAndClarityGetNoContentScore() {
        KBScoringService service = new KBScoringService();
        KBAssessmentModels.ArticleWrapper article = buildArticle('Good Title', 'Good Summary', '');

        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result =
            service.scoreDimensions(article, null, null, null, null);
        Test.stopTest();

        Assert.isTrue(result.getScore('Structure').isUnassessable, 'Structure marked unassessable without content');
        Assert.isTrue(result.getScore('Clarity').isUnassessable, 'Clarity marked unassessable without content');
        Assert.isTrue(result.getScore('Structure').reasoning.contains('no content'), 'Structure reasoning flags no content');
        Assert.isNotNull(result.getScore('Completeness'), 'Completeness still scored (title/summary drive it)');
    }

    @IsTest
    static void testScoreDimensions_SelectedDimensions_OnlyStructure() {
        KBScoringService service = new KBScoringService();
        String content = '';
        for (Integer i = 0; i < 200; i++) { content += 'word '; }
        KBAssessmentModels.ArticleWrapper article = buildArticle('Title', 'Summary', content);

        Set<String> selected = new Set<String>{ 'Structure' };

        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result =
            service.scoreDimensions(article, selected, null, null, null);
        Test.stopTest();

        Assert.isNotNull(result.getScore('Structure'), 'Structure should be populated');
        // Non-selected dims are absent from scoresByDim (null)
        Assert.isNull(result.getScore('Clarity'), 'Clarity should be absent (not selected)');
        Assert.isNull(result.getScore('Freshness'), 'Freshness should be absent (not selected)');
    }

    @IsTest
    static void testScoreDimensions_BulkPath_UsesPreloadedScores() {
        KBScoringService service = new KBScoringService();
        String content = '';
        for (Integer i = 0; i < 200; i++) { content += 'word '; }
        KBAssessmentModels.ArticleWrapper article = buildArticle('Title', 'Summary', content);

        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result =
            service.scoreDimensions(article, null, 45, 55, new List<Duplicate_Candidate__c>());
        Test.stopTest();

        Assert.areEqual(45, result.getScore('Duplication').score, 'Uses preloaded duplication score');
        Assert.areEqual(55, result.getScore('Conflict').score, 'Uses preloaded conflict score');
    }

    @IsTest
    static void testScoreDimensions_LLMUnavailable_ProducesValidScores() {
        // No mock injected → real PromptTemplateService can't reach Einstein in
        // the test context, so each LLM-backed scorer falls back via its catch
        // arm. The result should still produce a valid 0-100 score per dimension.
        KBScoringService service = new KBScoringService();

        String content = '';
        for (Integer i = 0; i < 200; i++) { content += 'word '; }
        KBAssessmentModels.ArticleWrapper article = buildArticle('Good Title', 'Good Summary', content);

        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result =
            service.scoreDimensions(article, null, null, null, null);
        Test.stopTest();

        Assert.isTrue(result.getScore('Structure').score >= 0 && result.getScore('Structure').score <= 100, 'Structure in range');
        Assert.isTrue(result.getScore('Clarity').score >= 0 && result.getScore('Clarity').score <= 100, 'Clarity in range');
        Assert.isTrue(result.getScore('Completeness').score >= 0 && result.getScore('Completeness').score <= 100, 'Completeness in range');
    }

    @IsTest
    static void testScoreDimensions_NullFields_DoNotThrow() {
        KBScoringService service = new KBScoringService();
        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.id = 'ka0FAKE000000001';
        // All other fields null

        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result =
            service.scoreDimensions(article, null, null, null, null);
        Test.stopTest();

        Assert.isNotNull(result, 'Should return a result without throwing');
        Assert.isNotNull(result.getScore('Completeness'), 'Completeness populated even with null fields');
    }
}
