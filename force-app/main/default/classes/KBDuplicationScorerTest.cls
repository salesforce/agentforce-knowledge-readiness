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
 * Test class for KBDuplicationScorer.
 * Validates duplication scoring using pipeline bridge (Duplicate_Candidate__c).
 */
@IsTest
private class KBDuplicationScorerTest {

    private static KBAssessmentModels.ArticleWrapper buildArticle(String id) {
        KBAssessmentModels.ArticleWrapper w = new KBAssessmentModels.ArticleWrapper();
        w.id = id;
        w.title = 'Test';
        w.content = '';
        return w;
    }

    @IsTest
    static void testNullArticleId() {
        KBDuplicationScorer scorer = new KBDuplicationScorer();
        KBAssessmentModels.DimensionScore result = scorer.score(buildArticle(null));

        System.assertNotEquals(null, result, 'Result should not be null');
    }

    @IsTest
    static void testNoCandiates() {
        KBDuplicationScorer scorer = new KBDuplicationScorer();
        KBAssessmentModels.DimensionScore result = scorer.score(buildArticle('ka0FAKE000000001'));

        System.assertEquals(100, result.score, 'No candidates should score 100');
        System.assert(!result.strengths.isEmpty(), 'Should have strength for no duplicates');
        System.assert(result.issues.isEmpty(), 'Should have no issues');
    }

    @IsTest
    static void testGetDimensionName() {
        KBDuplicationScorer scorer = new KBDuplicationScorer();
        System.assertEquals('Duplication', scorer.getDimensionName());
    }

    @IsTest
    static void testDefaultConstructor() {
        KBDuplicationScorer scorer = new KBDuplicationScorer();
        System.assertNotEquals(null, scorer);
        System.assertEquals('Duplication', scorer.getDimensionName());
    }

    @IsTest
    static void testBulkApi_EmptyCandidates() {
        KBDuplicationScorer scorer = new KBDuplicationScorer();
        KBAssessmentModels.DimensionScore result =
            scorer.scoreDuplicationBulk('ka0FAKE000000003', 100, new List<Duplicate_Candidate__c>());
        System.assertEquals(100, result.score, 'Empty candidates score 100');
        System.assert(!result.strengths.isEmpty(), 'Should note no duplicates');
        Assert.areEqual(KBScorerBase.MODE_PIPELINE, result.scorerMode,
            'Duplication is sourced from pipeline data — tagged Pipeline_Default');
    }

    @IsTest
    static void testReasoningBuilt() {
        KBDuplicationScorer scorer = new KBDuplicationScorer();
        KBAssessmentModels.DimensionScore result = scorer.score(buildArticle('ka0FAKE000000002'));

        System.assert(String.isNotBlank(result.reasoning), 'Reasoning should be populated');
    }
}
