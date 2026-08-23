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
 * Pure-builder tests for KBAssessmentRecordBuilder. No callouts, no async.
 * Most cases stay in-memory; only linkChildren needs a real Id from DML.
 */
@IsTest
private class KBAssessmentRecordBuilderTest {

    private static KBAssessmentModels.DimensionScore makeScore(Decimal value, String reasoning) {
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = value;
        s.reasoning = reasoning;
        s.scorerMode = 'Hybrid';
        s.executionMs = 42L;
        return s;
    }

    /**
     * articleId here is treated as a String by the result DTO and assigned
     * to KB_Article_Assessment__c.Knowledge__c (a Lookup) by the builder.
     * For pure in-memory tests we leave it null so the SObject build doesn't
     * try to coerce a fake string into an Id; tests that DML the record
     * pass a real Knowledge__kav.Id.
     */
    private static KBAssessmentModels.ArticleAssessmentResult makeResult(
        String articleVersionId, String title, Map<String, KBAssessmentModels.DimensionScore> scores
    ) {
        KBAssessmentModels.ArticleAssessmentResult r = new KBAssessmentModels.ArticleAssessmentResult();
        r.articleId = articleVersionId;
        r.articleTitle = title;
        r.overallScore = 75;
        r.readinessStatus = 'Ready';
        r.hasConflicts = false;
        r.scoresByDim = scores;
        return r;
    }

    @IsTest
    static void testBuild_NullResult_ReturnsEmptyParent() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);

        KBAssessmentRecordBuilder.ParentWithChildren bundle =
            KBAssessmentRecordBuilder.build(fakeRunId, null);

        Assert.isNotNull(bundle.parent, 'Parent placeholder is constructed even for null result');
        Assert.isNull(bundle.parent.Assessment_Run__c, 'Run lookup not set for null result');
        Assert.areEqual(0, bundle.children.size(), 'No children for null result');
    }

    @IsTest
    static void testBuild_HappyPath_SetsParentFieldsAndChildren() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        Map<String, KBAssessmentModels.DimensionScore> scores = new Map<String, KBAssessmentModels.DimensionScore>{
            'Completeness' => makeScore(80, 'Strengths: clear. Issues: short.'),
            'Structure' => makeScore(70, 'Strengths: organised.'),
            'Clarity' => makeScore(90, 'Strengths: simple.')
        };
        KBAssessmentModels.ArticleAssessmentResult r = makeResult(null, 'My Title', scores);
        r.overallScore = 80;
        r.readinessStatus = 'Ready';
        r.conflictDetails = 'no conflicts';

        KBAssessmentRecordBuilder.ParentWithChildren bundle =
            KBAssessmentRecordBuilder.build(fakeRunId, r);

        Assert.areEqual(fakeRunId, bundle.parent.Assessment_Run__c, 'Run lookup stamped on parent');
        Assert.areEqual('My Title', bundle.parent.Article_Title__c, 'Title preserved when ≤255 chars');
        Assert.areEqual(80, bundle.parent.Overall_Score__c, 'Overall score copied');
        Assert.areEqual('Ready', bundle.parent.Readiness_Status__c, 'Readiness status copied');
        Assert.areEqual(false, bundle.parent.Has_Conflicts__c, 'Has_Conflicts derived from null/false → false');
        Assert.areEqual('no conflicts', bundle.parent.Conflict_Details__c, 'Conflict details copied');
        Assert.areEqual(3, bundle.children.size(), 'One child per dimension entry');
    }

    /**
 * denormalised Article_Number__c and Knowledge_Article_Id__c
     * must be populated on the parent when the result carries them. Title was
     * already covered above; this guards against the regression where the
     * builder dropped articleNumber and knowledgeArticleId silently.
     */
    @IsTest
    static void testBuild_DenormalisedArticleFields_PopulatedFromResult() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        KBAssessmentModels.ArticleAssessmentResult r = makeResult(
            null, 'Some Title',
            new Map<String, KBAssessmentModels.DimensionScore>{
                'Completeness' => makeScore(80, 'present')
            }
        );
        r.articleNumber = '000001234';
        r.knowledgeArticleId = 'kA0fn000000Q2kuCAC';

        KBAssessmentRecordBuilder.ParentWithChildren bundle =
            KBAssessmentRecordBuilder.build(fakeRunId, r);

        Assert.areEqual('000001234', bundle.parent.Article_Number__c,
            'ArticleNumber must flow from result to parent record');
        Assert.areEqual('kA0fn000000Q2kuCAC', bundle.parent.Knowledge_Article_Id__c,
            'KnowledgeArticleId must flow from result to parent record');
    }

    @IsTest
    static void testBuild_TitleOver255_TruncatesTo255() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        String longTitle = 'a'.repeat(300);
        KBAssessmentModels.ArticleAssessmentResult r = makeResult(
            null, longTitle,
            new Map<String, KBAssessmentModels.DimensionScore>{
                'Completeness' => makeScore(50, 'short')
            }
        );

        KBAssessmentRecordBuilder.ParentWithChildren bundle =
            KBAssessmentRecordBuilder.build(fakeRunId, r);

        Assert.areEqual(255, bundle.parent.Article_Title__c.length(), 'Title clamped to 255 chars');
    }

    @IsTest
    static void testBuild_HasConflictsTrue_SetsParentField() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        KBAssessmentModels.ArticleAssessmentResult r = makeResult(
            null, 'with conflicts',
            new Map<String, KBAssessmentModels.DimensionScore>()
        );
        r.hasConflicts = true;

        KBAssessmentRecordBuilder.ParentWithChildren bundle =
            KBAssessmentRecordBuilder.build(fakeRunId, r);

        Assert.isTrue(bundle.parent.Has_Conflicts__c, 'Has_Conflicts mapped from result');
    }

    @IsTest
    static void testBuild_NullDimensionScore_SkipsChild() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        Map<String, KBAssessmentModels.DimensionScore> scores = new Map<String, KBAssessmentModels.DimensionScore>{
            'Completeness' => makeScore(80, 'present'),
            'Structure' => null
        };
        KBAssessmentModels.ArticleAssessmentResult r = makeResult(null, 'mixed', scores);

        KBAssessmentRecordBuilder.ParentWithChildren bundle =
            KBAssessmentRecordBuilder.build(fakeRunId, r);

        Assert.areEqual(1, bundle.children.size(), 'Null score entries do not produce a child row');
        Assert.areEqual('Completeness', bundle.children[0].Dimension__c, 'Surviving child has the present dimension');
    }

    @IsTest
    static void testBuildChild_NullScore_NullsAllNumericAndTextFields() {
        KB_Dimension_Result__c child = KBAssessmentRecordBuilder.buildChild('Clarity', null);

        Assert.areEqual('Clarity', child.Dimension__c, 'Dimension name still set');
        Assert.isNull(child.Score__c, 'Score nulled when DimensionScore is null');
        Assert.isNull(child.Reasoning__c, 'Reasoning nulled');
        Assert.areEqual(false, child.Is_Unassessable__c, 'Defaults to false when score absent');
        Assert.isNull(child.Scorer_Mode__c, 'Scorer mode nulled');
        Assert.isNull(child.Execution_Ms__c, 'Execution ms nulled');
    }

    @IsTest
    static void testBuildChild_TruncatesReasoningTo32k() {
        KBAssessmentModels.DimensionScore s = makeScore(60, 'b'.repeat(40000));

        KB_Dimension_Result__c child = KBAssessmentRecordBuilder.buildChild('Structure', s);

        Assert.areEqual(32000, child.Reasoning__c.length(), 'Reasoning clamped to 32000 chars');
    }

    @IsTest
    static void testBuildChild_TruncatesDimensionNameTo80() {
        String veryLong = 'd'.repeat(120);
        KBAssessmentModels.DimensionScore s = makeScore(65, 'short');

        KB_Dimension_Result__c child = KBAssessmentRecordBuilder.buildChild(veryLong, s);

        Assert.areEqual(80, child.Dimension__c.length(), 'Dimension name clamped to 80 chars');
    }

    @IsTest
    static void testBuildAll_NullList_ReturnsEmpty() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);

        List<KBAssessmentRecordBuilder.ParentWithChildren> bundles =
            KBAssessmentRecordBuilder.buildAll(fakeRunId, null);

        Assert.areEqual(0, bundles.size(), 'Null input → empty list');
    }

    @IsTest
    static void testBuildAll_HappyPath_PreservesOrder() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        List<KBAssessmentModels.ArticleAssessmentResult> results = new List<KBAssessmentModels.ArticleAssessmentResult>{
            makeResult(null, 'first', new Map<String, KBAssessmentModels.DimensionScore>{
                'Completeness' => makeScore(50, 'r1')
            }),
            makeResult(null, 'second', new Map<String, KBAssessmentModels.DimensionScore>{
                'Structure' => makeScore(60, 'r2')
            })
        };

        List<KBAssessmentRecordBuilder.ParentWithChildren> bundles =
            KBAssessmentRecordBuilder.buildAll(fakeRunId, results);

        Assert.areEqual(2, bundles.size(), 'Two bundles for two results');
        Assert.areEqual('first', bundles[0].parent.Article_Title__c, 'Order preserved (item 0)');
        Assert.areEqual('second', bundles[1].parent.Article_Title__c, 'Order preserved (item 1)');
    }

    @IsTest
    static void testLinkChildren_StampsParentIdAfterParentInsert() {
        // linkChildren needs a real parent Id, so we have to insert minimal
        // run + parent rows. Builder logic itself is unit-only, but this is
        // the only branch that requires DML to exercise.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        List<Knowledge__kav> articles = KBTestDataFactory.insertArticles(2, 'rb');

        List<KBAssessmentRecordBuilder.ParentWithChildren> bundles = new List<KBAssessmentRecordBuilder.ParentWithChildren>();
        for (Knowledge__kav kav : articles) {
            KBAssessmentModels.ArticleAssessmentResult r = makeResult(
                kav.Id, kav.Title,
                new Map<String, KBAssessmentModels.DimensionScore>{
                    'Completeness' => makeScore(80, 'ok')
                }
            );
            bundles.add(KBAssessmentRecordBuilder.build(run.Id, r));
        }

        // Builder doesn't stamp Knowledge_Article_Id__c — production
        // KBAssessmentService does that separately. Replicate here so the
        // required-field DML check passes.
        List<KB_Article_Assessment__c> parents = KBAssessmentRecordBuilder.parentsOf(bundles);
        for (Integer i = 0; i < parents.size(); i++) {
            parents[i].Knowledge_Article_Id__c = articles[i].Id;
        }
        insert parents;
        KBAssessmentRecordBuilder.linkChildren(bundles);

        for (KBAssessmentRecordBuilder.ParentWithChildren b : bundles) {
            Assert.isNotNull(b.parent.Id, 'Parent has Id after insert');
            for (KB_Dimension_Result__c c : b.children) {
                Assert.areEqual(b.parent.Id, c.Article_Assessment__c,
                    'Parent Id stamped on each child');
            }
        }
    }

    @IsTest
    static void testLinkChildren_NullList_DoesNotThrow() {
        // Branch coverage: null defensive path.
        KBAssessmentRecordBuilder.linkChildren(null);
    }

    @IsTest
    static void testFlattenChildren_PreservesOrderAcrossBundles() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        List<KBAssessmentRecordBuilder.ParentWithChildren> bundles = new List<KBAssessmentRecordBuilder.ParentWithChildren>{
            KBAssessmentRecordBuilder.build(fakeRunId, makeResult(null, 't1',
                new Map<String, KBAssessmentModels.DimensionScore>{ 'Completeness' => makeScore(80, 'r') })),
            KBAssessmentRecordBuilder.build(fakeRunId, makeResult(null, 't2',
                new Map<String, KBAssessmentModels.DimensionScore>{
                    'Structure' => makeScore(70, 'r'),
                    'Clarity' => makeScore(90, 'r')
                }))
        };

        List<KB_Dimension_Result__c> flat = KBAssessmentRecordBuilder.flattenChildren(bundles);

        Assert.areEqual(3, flat.size(), '1+2 children flattened to single list of 3');
    }

    @IsTest
    static void testFlattenChildren_NullList_ReturnsEmpty() {
        Assert.areEqual(0, KBAssessmentRecordBuilder.flattenChildren(null).size(),
            'Null list → empty flattening');
    }

    @IsTest
    static void testParentsOf_FiltersBundlesWithNullParent() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        KBAssessmentRecordBuilder.ParentWithChildren good = KBAssessmentRecordBuilder.build(
            fakeRunId,
            makeResult(null, 't1', new Map<String, KBAssessmentModels.DimensionScore>())
        );
        KBAssessmentRecordBuilder.ParentWithChildren empty = new KBAssessmentRecordBuilder.ParentWithChildren();
        empty.parent = null;

        List<KB_Article_Assessment__c> parents = KBAssessmentRecordBuilder.parentsOf(
            new List<KBAssessmentRecordBuilder.ParentWithChildren>{ good, empty }
        );

        Assert.areEqual(1, parents.size(), 'Bundles with null parent are filtered out');
    }

    @IsTest
    static void testParentsOf_NullList_ReturnsEmpty() {
        Assert.areEqual(0, KBAssessmentRecordBuilder.parentsOf(null).size(),
            'Null list → empty');
    }

    // ------------------------------------------------------------------ analyses

    @IsTest
    static void testBuild_StoresScoreByDimension() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        KBAssessmentModels.DimensionScore s = makeScore(80, 'Strengths: clear. Issues: short.');
        s.issues = new List<String>{ 'Article body is too short' };
        s.strengths = new List<String>{ 'Title is descriptive', 'Has a summary' };

        KBAssessmentRecordBuilder.ParentWithChildren bundle = KBAssessmentRecordBuilder.build(
            fakeRunId,
            makeResult(null, 'analysis', new Map<String, KBAssessmentModels.DimensionScore>{
                'Completeness' => s
            })
        );

        Assert.areEqual(1, bundle.scoreByDimension.size(), 'Score wrapper retained per dimension');
        KBAssessmentModels.DimensionScore stored = bundle.scoreByDimension.get('Completeness');
        Assert.isNotNull(stored, 'Score wrapper kept for later analysis emission');
        Assert.areEqual(s.score, stored.score, 'Score copied through');
        Assert.areEqual(1, stored.issues.size(), 'Issues preserved');
        Assert.areEqual(2, stored.strengths.size(), 'Strengths preserved');
    }

    @IsTest
    static void testBuildAnalyses_EmitsIssueAndStrengthRows() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        List<Knowledge__kav> articles = KBTestDataFactory.insertArticles(1, 'analyses');

        KBAssessmentModels.DimensionScore s = makeScore(45, 'Issues: thin body. Strengths: clear title.');
        s.issues = new List<String>{ 'Article body is too short', 'Missing summary' };
        s.strengths = new List<String>{ 'Title clearly describes the topic' };

        List<KBAssessmentRecordBuilder.ParentWithChildren> bundles =
            new List<KBAssessmentRecordBuilder.ParentWithChildren>{
                KBAssessmentRecordBuilder.build(run.Id, makeResult(
                    articles[0].Id, articles[0].Title,
                    new Map<String, KBAssessmentModels.DimensionScore>{ 'Completeness' => s }
                ))
            };

        List<KB_Article_Assessment__c> parents = KBAssessmentRecordBuilder.parentsOf(bundles);
        parents[0].Knowledge_Article_Id__c = articles[0].Id;
        insert parents;
        KBAssessmentRecordBuilder.linkChildren(bundles);
        insert KBAssessmentRecordBuilder.flattenChildren(bundles);

        List<KB_Dimension_Analysis__c> analyses = KBAssessmentRecordBuilder.buildAnalyses(bundles);
        Assert.areEqual(3, analyses.size(),
            'One row per issue plus one per strength');

        Integer issueCount = 0, strengthCount = 0;
        for (KB_Dimension_Analysis__c a : analyses) {
            if (a.Type__c == KBDimensionAnalysisService.TYPE_ISSUE) issueCount++;
            if (a.Type__c == KBDimensionAnalysisService.TYPE_STRENGTH) strengthCount++;
            Assert.isNotNull(a.Dimension_Result__c, 'Master-detail Id stamped from inserted child');
            Assert.areEqual(parents[0].Id, a.Article_Assessment__c,
                'Denormalized assessment Id stamped on analysis');
            Assert.areEqual('Completeness', a.Dimension__c, 'Dimension copied');
        }
        Assert.areEqual(2, issueCount, 'Two issues → two Issue rows');
        Assert.areEqual(1, strengthCount, 'One strength → one Strength row');
    }

    @IsTest
    static void testBuildAnalyses_NoScores_ReturnsEmpty() {
        Id fakeRunId = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        KBAssessmentRecordBuilder.ParentWithChildren empty = KBAssessmentRecordBuilder.build(
            fakeRunId, makeResult(null, 'empty', new Map<String, KBAssessmentModels.DimensionScore>())
        );

        List<KB_Dimension_Analysis__c> rows = KBAssessmentRecordBuilder.buildAnalyses(
            new List<KBAssessmentRecordBuilder.ParentWithChildren>{ empty }
        );

        Assert.areEqual(0, rows.size(), 'No score wrappers → no analyses');
    }

    @IsTest
    static void testBuildAnalyses_NullList_ReturnsEmpty() {
        Assert.areEqual(0, KBAssessmentRecordBuilder.buildAnalyses(null).size(),
            'Null list → empty');
    }
}