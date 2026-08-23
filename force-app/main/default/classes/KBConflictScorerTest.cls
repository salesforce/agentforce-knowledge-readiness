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
 * Coverage for KBConflictScorer — pipeline-data-driven scorer that reads
 * Duplicate_Candidate__c rows via KBPipelineBridgeService and emits a
 * DimensionScore.
 *
 * The bulk path (`scoreConflictBulk`) accepts pre-loaded data so we cover
 * every branch in `buildConflictScore` (Contradiction counting; 'Overlap' retired,
 * conflict counts 0/1/3/>3, Rejected/Suppressed filtering, missing
 * Confidence_Score) without DML.
 *
 * The non-bulk path covers KBPipelineBridgeService integration via real
 * Duplicate_Candidate__c rows from KBTestDataFactory.
 */
@IsTest
private class KBConflictScorerTest {

    private static KBAssessmentModels.ArticleWrapper buildArticle(String id) {
        KBAssessmentModels.ArticleWrapper w = new KBAssessmentModels.ArticleWrapper();
        w.id = id;
        w.title = 'Test';
        w.content = '';
        return w;
    }

    private static Duplicate_Candidate__c buildCandidate(
        String articleId, String otherArticleId, String otherTitle,
        String flagType, String status, Decimal confidence, String tier
    ) {
        return new Duplicate_Candidate__c(
            Knowledge_Article_1__c = articleId,
            Knowledge_Article_2__c = otherArticleId,
            Article_2_Title__c = otherTitle,
            Flag_Type__c = flagType,
            Status__c = status,
            Confidence_Score__c = confidence,
            Source_Tier__c = tier
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // Existing core sanity tests
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testNullArticleId() {
        KBConflictScorer scorer = new KBConflictScorer();
        KBAssessmentModels.DimensionScore result = scorer.score(buildArticle(null));

        Assert.isNotNull(result);
    }

    @IsTest
    static void testNoConflicts() {
        KBConflictScorer scorer = new KBConflictScorer();
        KBAssessmentModels.DimensionScore result = scorer.score(buildArticle('ka0FAKE000000001'));

        Assert.areEqual(100, result.score, 'No candidates score 100');
        Assert.isFalse(result.strengths.isEmpty(), 'Strength noted for no conflicts');
        Assert.isTrue(result.issues.isEmpty(), 'No issues');
        Assert.areEqual(KBScorerBase.MODE_PIPELINE, result.scorerMode,
            'Conflict is sourced from pipeline data — tagged Pipeline_Default');
    }

    @IsTest
    static void testGetDimensionName() {
        Assert.areEqual('Conflict', new KBConflictScorer().getDimensionName());
    }

    @IsTest
    static void testDefaultConstructor() {
        KBConflictScorer scorer = new KBConflictScorer();
        Assert.isNotNull(scorer);
        Assert.areEqual('Conflict', scorer.getDimensionName());
    }

    @IsTest
    static void testBulkApi_EmptyCandidates() {
        KBConflictScorer scorer = new KBConflictScorer();
        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk('ka0FAKE000000003', 100, new List<Duplicate_Candidate__c>());

        Assert.areEqual(100, result.score);
        Assert.isFalse(result.strengths.isEmpty(), 'Empty candidates → strength added');
    }

    @IsTest
    static void testBulkApi_NullCandidates_SafeDefault() {
        KBConflictScorer scorer = new KBConflictScorer();
        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk('ka0FAKE000000099', 90, null);

        Assert.areEqual(90, result.score);
        Assert.isFalse(result.strengths.isEmpty(),
            'Null candidates treated as empty list — no NPE');
    }

    @IsTest
    static void testReasoningBuilt() {
        KBConflictScorer scorer = new KBConflictScorer();
        KBAssessmentModels.DimensionScore result = scorer.score(buildArticle('ka0FAKE000000002'));

        Assert.isTrue(String.isNotBlank(result.reasoning));
    }

    // ──────────────────────────────────────────────────────────────────────
    // Bulk path — flag-type and status filtering
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testBulkApi_ContradictionFlag_BuildsContradictsLabel() {
        KBConflictScorer scorer = new KBConflictScorer();
        String targetId = 'ka01TARGET00000A';
        List<Duplicate_Candidate__c> candidates = new List<Duplicate_Candidate__c>{
            buildCandidate(targetId, 'ka01OTHER0000001', 'Other Title',
                'Contradiction', 'Pending', 92.5, 'Tier4_Agentic')
        };

        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk(targetId, 60, candidates);

        Assert.areEqual(60, result.score);
        Assert.areEqual(1, result.issues.size());
        Assert.isTrue(result.issues[0].contains('Contradicts'),
            'Contradiction flag → "Contradicts" label');
        Assert.isTrue(result.issues[0].contains('Other Title'));
        Assert.isTrue(result.issues[0].contains('92%'),
            'setScale(0) truncates 92.5 to 92');
    }

 // 'Overlap' was retired as a Flag_Type. The Conflict dimension now
    // counts ONLY Contradiction candidates; a legacy Overlap row (should it still
    // exist) is ignored, not surfaced as a conflict.
    @IsTest
    static void testBulkApi_LegacyOverlapFlag_NotCounted() {
        KBConflictScorer scorer = new KBConflictScorer();
        String targetId = 'ka01TARGET00000B';
        List<Duplicate_Candidate__c> candidates = new List<Duplicate_Candidate__c>{
            buildCandidate(targetId, 'ka01OTHER0000002', 'Overlap Title',
                'Overlap', 'Pending', 75, 'Tier3_Triage')
        };

        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk(targetId, 70, candidates);

        Assert.isTrue(result.issues.isEmpty(),
            'Legacy Overlap flag is not counted as a conflict');
        Assert.isFalse(result.strengths.isEmpty(),
            'No contradictions → no-conflict strength');
    }

    @IsTest
    static void testBulkApi_DuplicateFlag_NotConflict_Filtered() {
        KBConflictScorer scorer = new KBConflictScorer();
        String targetId = 'ka01TARGET00000C';
        List<Duplicate_Candidate__c> candidates = new List<Duplicate_Candidate__c>{
            buildCandidate(targetId, 'ka01OTHER0000003', 'Dup Title',
                'Duplicate', 'Pending', 80, 'Tier4_Agentic')
        };

        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk(targetId, 100, candidates);

        Assert.isTrue(result.issues.isEmpty(),
            'Pure Duplicate flag is not a conflict — filtered');
        Assert.isFalse(result.strengths.isEmpty(),
            'Falls through to no-conflicts strength');
    }

    @IsTest
    static void testBulkApi_RejectedAndSuppressed_AreFiltered() {
        KBConflictScorer scorer = new KBConflictScorer();
        String targetId = 'ka01TARGET00000D';
        List<Duplicate_Candidate__c> candidates = new List<Duplicate_Candidate__c>{
            buildCandidate(targetId, 'ka01OTHER0000004', 'Rejected Title',
                'Contradiction', 'Rejected', 90, 'Tier3_Triage'),
            buildCandidate(targetId, 'ka01OTHER0000005', 'Suppressed Title',
                'Contradiction', 'Suppressed', 85, 'Tier4_Agentic')
        };

        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk(targetId, 100, candidates);

        Assert.isTrue(result.issues.isEmpty(),
            'Rejected and Suppressed candidates dropped');
        Assert.isFalse(result.strengths.isEmpty(),
            'Empty effective list → no-conflict strength');
    }

    @IsTest
    static void testBulkApi_ThreeConflicts_AllListed_NoSummaryLine() {
        KBConflictScorer scorer = new KBConflictScorer();
        String targetId = 'ka01TARGET00000E';
        List<Duplicate_Candidate__c> candidates = new List<Duplicate_Candidate__c>{
            buildCandidate(targetId, 'ka01OTHER0000006', 'A', 'Contradiction', 'Pending', 70, 'Tier4_Agentic'),
            buildCandidate(targetId, 'ka01OTHER0000007', 'B', 'Contradiction', 'Pending', 80, 'Tier4_Agentic'),
            buildCandidate(targetId, 'ka01OTHER0000008', 'C', 'Contradiction', 'Pending', 90, 'Tier3_Triage')
        };

        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk(targetId, 50, candidates);

        Assert.areEqual(3, result.issues.size(),
            'Up to 3 conflicts are listed individually');
    }

    @IsTest
    static void testBulkApi_FourConflicts_AddsSummaryLine() {
        // Locks in the >3 boundary: KBConflictScorer.buildConflictScore lists
        // the first 3 conflicts individually then collapses the rest into a
        // single summary line. If buildConflictScore raises this threshold,
        // this test must be updated alongside the scorer change.
        KBConflictScorer scorer = new KBConflictScorer();
        String targetId = 'ka01TARGET00000F';
        List<Duplicate_Candidate__c> candidates = new List<Duplicate_Candidate__c>{
            buildCandidate(targetId, 'ka01OTHER0000009', 'A', 'Contradiction', 'Pending', 70, 'Tier4_Agentic'),
            buildCandidate(targetId, 'ka01OTHER000000A', 'B', 'Contradiction', 'Pending', 75, 'Tier4_Agentic'),
            buildCandidate(targetId, 'ka01OTHER000000B', 'C', 'Contradiction', 'Pending', 80, 'Tier3_Triage'),
            buildCandidate(targetId, 'ka01OTHER000000C', 'D', 'Contradiction', 'Pending', 85, 'Tier3_Triage'),
            buildCandidate(targetId, 'ka01OTHER000000D', 'E', 'Contradiction', 'Pending', 90, 'Tier4_Agentic')
        };

        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk(targetId, 30, candidates);

        // First 3 listed individually + 1 summary line = 4 issues total.
        // Tied to the hardcoded conflictCount > 3 branch in buildConflictScore.
        Assert.areEqual(4, result.issues.size(),
            'Conflicts >3 collapse extras into a summary line (boundary at 3)');
        Assert.isTrue(result.issues[3].contains('5 conflict candidates'),
            'Summary line carries the total count of all 5 candidates');
    }

    @IsTest
    static void testBulkApi_TitleResolution_OtherDirection() {
        // When dc.Knowledge_Article_1__c == articleId, the OTHER article's
        // title is in Article_2_Title__c. When dc.Knowledge_Article_1__c
        // != articleId, the OTHER title is in Article_1_Title__c. Test
        // both directions.
        KBConflictScorer scorer = new KBConflictScorer();
        String targetId = 'ka01TARGET00000G';

        // Direction 1: target is article_1 → expect Article_2_Title
        Duplicate_Candidate__c dc1 = buildCandidate(
            targetId, 'ka01OTHER000000E', 'Title2',
            'Contradiction', 'Pending', 80, 'Tier4_Agentic'
        );

        // Direction 2: target is article_2 → expect Article_1_Title
        Duplicate_Candidate__c dc2 = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = 'ka01OTHER000000F',
            Knowledge_Article_2__c = targetId,
            Article_1_Title__c = 'Title1',
            Article_2_Title__c = 'Should not appear',
            Flag_Type__c = 'Contradiction',
            Status__c = 'Pending',
            Confidence_Score__c = 75,
            Source_Tier__c = 'Tier3_Triage'
        );

        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk(targetId, 60, new List<Duplicate_Candidate__c>{ dc1, dc2 });

        Assert.areEqual(2, result.issues.size());
        String allIssues = String.join(result.issues, '|');
        Assert.isTrue(allIssues.contains('Title1'), 'Reverse-direction title resolved');
        Assert.isTrue(allIssues.contains('Title2'), 'Forward-direction title resolved');
    }

    @IsTest
    static void testBulkApi_NullConfidence_RendersAsZero() {
        KBConflictScorer scorer = new KBConflictScorer();
        String targetId = 'ka01TARGET00000H';
        Duplicate_Candidate__c dc = buildCandidate(
            targetId, 'ka01OTHER0000010', 'NoConf',
            'Contradiction', 'Pending', null, 'Tier4_Agentic'
        );

        KBAssessmentModels.DimensionScore result =
            scorer.scoreConflictBulk(targetId, 40, new List<Duplicate_Candidate__c>{ dc });

        Assert.areEqual(1, result.issues.size());
        Assert.isTrue(result.issues[0].contains('0%'),
            'Null confidence rendered as 0%');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Non-bulk path — verifies KBPipelineBridgeService integration with
    // real DML rows (factory-created)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testNonBulk_LiveBridgeQuery_HappyPath() {
        // Insert two articles + one Duplicate_Candidate__c so the
        // KBPipelineBridgeService SOQL returns real data.
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'conflict-bulk');
        KBTestDataFactory.insertDuplicateCandidate(
            kavs[0].Id, kavs[1].Id, 'Contradiction', 'Pending'
        );

        Test.startTest();
        KBConflictScorer scorer = new KBConflictScorer();
        KBAssessmentModels.DimensionScore result =
            scorer.score(buildArticle(String.valueOf(kavs[0].Id)));
        Test.stopTest();

        Assert.isNotNull(result);
        Assert.isTrue(String.isNotBlank(result.reasoning));
    }
}
