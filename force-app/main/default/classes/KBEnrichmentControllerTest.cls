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
private class KBEnrichmentControllerTest {

    @TestSetup
    static void setup() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 2,
            Assessment_Types__c = 'Readiness'
        );
        insert run;

        List<Enrichment_Candidate__c> candidates = new List<Enrichment_Candidate__c>{
            new Enrichment_Candidate__c(
                Composite_Key__c = 'test_enrich_alpha_' + run.Id,
                Source_Article_Title__c = 'Article Alpha',
                Source_Article_Version_Id__c = 'ka0FAKE000000001',
                Status__c = 'Pending',
                Is_Closed__c = false,
                Confidence_Score__c = 85,
                Assessment_Run__c = run.Id
            ),
            new Enrichment_Candidate__c(
                Composite_Key__c = 'test_enrich_beta_' + run.Id,
                Source_Article_Title__c = 'Article Beta',
                Source_Article_Version_Id__c = 'ka0FAKE000000002',
                Status__c = 'Pending',
                Is_Closed__c = false,
                Confidence_Score__c = 72,
                Assessment_Run__c = run.Id
            )
        };
        insert candidates;
    }

    static List<Enrichment_Candidate__c> getCandidates() {
        return [SELECT Id, Status__c, Is_Closed__c, Source_Article_Title__c
                FROM Enrichment_Candidate__c ORDER BY Source_Article_Title__c];
    }

    @IsTest
    static void getEnrichmentInbox_ReturnsCandidates() {
        KBEnrichmentController.EnrichmentInboxData data = KBEnrichmentController.getEnrichmentInbox(100, null);
        Assert.areEqual(2, data.candidates.size(), 'Should return all 2 pending candidates');
        Assert.areEqual(2, data.pendingCount);
    }

    @IsTest
    static void getEnrichmentInbox_RunScoped_FiltersAndPopulatesRunName() {
        KB_Assessment_Run__c setupRun = [SELECT Id, Name FROM KB_Assessment_Run__c LIMIT 1];

 // A candidate under a DIFFERENT run — must be excluded when filtering on setupRun.
        KB_Assessment_Run__c otherRun = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 1, Assessment_Types__c = 'Readiness'
        );
        insert otherRun;
        insert new Enrichment_Candidate__c(
            Composite_Key__c = 'test_enrich_gamma_' + otherRun.Id,
            Source_Article_Title__c = 'Article Gamma',
            Source_Article_Version_Id__c = 'ka0FAKE000000003',
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 60,
            Assessment_Run__c = otherRun.Id
        );

        Test.startTest();
        KBEnrichmentController.EnrichmentInboxData scoped =
            KBEnrichmentController.getEnrichmentInbox(100, setupRun.Id);
        Test.stopTest();

        Assert.areEqual(2, scoped.candidates.size(),
            'Run filter returns only the 2 candidates from setupRun, not the gamma candidate');
        for (KBEnrichmentController.SplitProposalRow row : scoped.candidates) {
            Assert.areEqual(setupRun.Name, row.sourceRunName,
                'sourceRunName populated from the linked assessment run');
        }
    }

    @IsTest
    static void publishCandidatesBulk_PartialFailure_ReturnsPerItemResults() {
        List<Enrichment_Candidate__c> candidates = getCandidates();
        // Candidate Alpha has a fake Draft_Article_Version_Id__c (not a real article)
        // so publishing will fail. Candidate Beta has no draft at all — also fails.
        List<String> ids = new List<String>{
            String.valueOf(candidates[0].Id),
            String.valueOf(candidates[1].Id)
        };

        Test.startTest();
        List<KBEnrichmentController.ActionResult> results =
            KBEnrichmentController.publishCandidatesBulk(ids);
        Test.stopTest();

        Assert.areEqual(2, results.size(), 'Should return a result per candidate');
        // Both should fail. Messages must be human-readable, never the
        // generic "Script-thrown exception" wrapper that AuraHandledException
        // surfaces when re-caught from inside Apex.
        for (KBEnrichmentController.ActionResult r : results) {
            Assert.isFalse(r.success, 'Should fail: ' + r.message);
            Assert.isTrue(String.isNotBlank(r.message), 'Error message should be populated');
            Assert.areNotEqual('Script-thrown exception', r.message,
                'Per-item message must be the real validation/platform reason, not the generic wrapper');
            Assert.isTrue(String.isNotBlank(r.candidateId), 'Candidate ID should be populated');
        }

        // At least one of the two should hit the "no draft linked" validation.
        Boolean sawNoDraftMessage = false;
        for (KBEnrichmentController.ActionResult r : results) {
            if (r.message != null && r.message.containsIgnoreCase('no draft')) {
                sawNoDraftMessage = true;
                break;
            }
        }
        Assert.isTrue(sawNoDraftMessage,
            'Expected at least one candidate to surface the "no draft is linked" reason. Got: '
            + results[0].message + ' / ' + results[1].message);
    }

    @IsTest
    static void publishCandidatesBulk_NullInput_ReturnsEmpty() {
        List<KBEnrichmentController.ActionResult> results =
            KBEnrichmentController.publishCandidatesBulk(null);
        Assert.areEqual(0, results.size());
    }

    @IsTest
    static void rejectCandidate_Success_MarksClosedWithReason() {
        Enrichment_Candidate__c c = getCandidates()[0];

        Test.startTest();
        KBEnrichmentController.ActionResult result =
            KBEnrichmentController.rejectCandidate(String.valueOf(c.Id), 'Not relevant');
        Test.stopTest();

        Assert.isTrue(result.success);
        Enrichment_Candidate__c updated = [SELECT Status__c, Is_Closed__c, Rejection_Reason__c
                                           FROM Enrichment_Candidate__c WHERE Id = :c.Id];
        Assert.areEqual('Rejected', updated.Status__c);
        Assert.isTrue(updated.Is_Closed__c);
        Assert.areEqual('Not relevant', updated.Rejection_Reason__c);
    }

    @IsTest
    static void rejectCandidate_BlankReason_Throws() {
        Enrichment_Candidate__c c = getCandidates()[0];
        Boolean threw = false;
        try {
            KBEnrichmentController.rejectCandidate(String.valueOf(c.Id), '');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, 'Should require a rejection reason');
    }

    @IsTest
    static void rejectCandidatesBulk_PartialFailure_ReturnsPerItemResults() {
        List<Enrichment_Candidate__c> candidates = getCandidates();
        // Use a real id + a bogus id to trigger partial failure
        List<String> ids = new List<String>{
            String.valueOf(candidates[0].Id),
            'a0KFAKE000000099' // non-existent
        };

        Test.startTest();
        List<KBEnrichmentController.ActionResult> results =
            KBEnrichmentController.rejectCandidatesBulk(ids, 'Test reason');
        Test.stopTest();

        Assert.areEqual(2, results.size());
        Assert.isTrue(results[0].success, 'Valid candidate should succeed');
        Assert.isFalse(results[1].success, 'Invalid candidate should fail');
        Assert.isTrue(String.isNotBlank(results[1].message));
    }

    @IsTest
    static void publishCandidate_AlreadyClosed_ReturnsSuccessWithMessage() {
        Enrichment_Candidate__c c = getCandidates()[0];
        c.Is_Closed__c = true;
        c.Status__c = 'Published';
        update c;

        KBEnrichmentController.ActionResult result =
            KBEnrichmentController.publishCandidate(String.valueOf(c.Id));
        Assert.isTrue(result.success);
        Assert.isTrue(result.message.contains('Already processed'));
    }

    /**
 * KbManagement.PublishingService.publishArticle rejects a draft with
     * the AMBIGUOUS platform message "You can't perform this action. Be sure the
     * action is valid for the current state of the article, and that you have
     * permission to perform it." — which covers BOTH a permission/record-access
     * failure AND a stale-version failure. friendlyPublishErrorMessage must
     * translate it into a message that names BOTH causes (never the raw dump,
     * and never confidently asserting only one — verified on-org that the same
     * draft a non-owning user was refused published fine as admin, i.e. the
     * permission cause is real, not hypothetical).
     */
    @IsTest
    static void friendlyPublishError_AmbiguousRejection_NamesBothCauses() {
        String platformMsg = 'You can\'t perform this action. Be sure the action '
            + 'is valid for the current state of the article, and that you have '
            + 'permission to perform it.';
        String friendly = KBEnrichmentController.friendlyPublishErrorMessage(
            new EnrichmentControllerTestException(platformMsg));

        Assert.isFalse(friendly.containsIgnoreCase('perform this action'),
            'The raw opaque platform message must NOT reach the user; got: ' + friendly);
        Assert.isTrue(friendly.containsIgnoreCase('permission'),
            'Message names the PERMISSION cause; got: ' + friendly);
        Assert.isTrue(friendly.containsIgnoreCase('published or updated separately')
                || friendly.containsIgnoreCase('re-run'),
            'Message names the STALE-version cause too; got: ' + friendly);
        Assert.isTrue(friendly.containsIgnoreCase('retry'),
            'Message gives an actionable next step; got: ' + friendly);
    }

    /**
 * regression guard: the new version-state branch must not swallow the
     * pre-existing access / already-published translations (they're checked
     * first and remain intact).
     */
    @IsTest
    static void friendlyPublishError_PreExistingBranchesStillWin() {
        Assert.areEqual('You do not have permission to publish this article.',
            KBEnrichmentController.friendlyPublishErrorMessage(
                new EnrichmentControllerTestException('INSUFFICIENT_ACCESS_OR_READONLY: ...')),
            'INSUFFICIENT_ACCESS still maps to the permission message');
        Assert.areEqual('This article is already published.',
            KBEnrichmentController.friendlyPublishErrorMessage(
                new EnrichmentControllerTestException('The article is already published')),
            'already-published still maps to its own message');
    }

    // Local exception so the test can feed friendlyPublishErrorMessage a
    // controlled getMessage() without a live publish callout.
    private class EnrichmentControllerTestException extends Exception {}

    // ------------------------------------------------------------------ getImprovementsInbox

    @IsTest
    static void testGetImprovementsInbox_ReturnsGroupsForOpenLLMRecs() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'inbox');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        KB_Article_Assessment__c aa1 = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = kavs[0].Id,
            Knowledge_Article_Id__c = kavs[0].Id,
            Article_Title__c = kavs[0].Title,
            Overall_Score__c = 50,
            Readiness_Status__c = 'Needs Work'
        );
        KB_Article_Assessment__c aa2 = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = kavs[1].Id,
            Knowledge_Article_Id__c = kavs[1].Id,
            Article_Title__c = kavs[1].Title,
            Overall_Score__c = 40,
            Readiness_Status__c = 'Not Ready'
        );
        insert new List<KB_Article_Assessment__c>{ aa1, aa2 };

        List<KB_Dimension_Result__c> drs = new List<KB_Dimension_Result__c>{
            new KB_Dimension_Result__c(Article_Assessment__c = aa1.Id, Dimension__c = 'Completeness', Score__c = 30),
            new KB_Dimension_Result__c(Article_Assessment__c = aa2.Id, Dimension__c = 'Structure', Score__c = 50),
            new KB_Dimension_Result__c(Article_Assessment__c = aa1.Id, Dimension__c = 'Duplication', Score__c = 30)
        };
        insert drs;

        insert new List<KB_Dimension_Analysis__c>{
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa1.Id,
                Dimension_Result__c = drs[0].Id,
                Type__c = 'Issue',
                Dimension__c = 'Completeness',
                Recommendation__c = 'Add a summary section.',
                Status__c = 'Open'
            ),
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa2.Id,
                Dimension_Result__c = drs[1].Id,
                Type__c = 'Issue',
                Dimension__c = 'Structure',
                Recommendation__c = 'Use headers.',
                Status__c = 'Open'
            ),
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa1.Id,
                Dimension_Result__c = drs[2].Id,
                Type__c = 'Issue',
                Dimension__c = 'Duplication',
                Recommendation__c = 'Merge with duplicate.',
                Status__c = 'Open'
            )
        };

        Test.startTest();
        List<KBEnrichmentController.ImprovementArticleGroup> groups =
            KBEnrichmentController.getImprovementsInbox(null);
        Test.stopTest();

        // Duplication recs are excluded; LLM recs (Completeness, Structure) are included
        Integer totalRecs = 0;
        for (KBEnrichmentController.ImprovementArticleGroup g : groups) {
            totalRecs += g.recommendations.size();
        }
        Assert.areEqual(2, totalRecs, 'Only LLM dimension recs (Completeness + Structure) returned');
        Assert.areEqual(2, groups.size(), 'One group per article');
    }

    @IsTest
    static void testGetImprovementsInbox_EmptyState_ReturnsEmptyList() {
        Test.startTest();
        List<KBEnrichmentController.ImprovementArticleGroup> groups =
            KBEnrichmentController.getImprovementsInbox(null);
        Test.stopTest();

        Assert.areEqual(0, groups.size(), 'No open LLM recs → empty list');
    }

    // ------------------------------------------------------------------ getImprovementsForArticle

    @IsTest
    static void testGetImprovementsForArticle_ReturnsGroupForOpenLLMRecs() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'single');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = kavs[0].Id,
            Knowledge_Article_Id__c = kavs[0].Id,
            Article_Title__c = kavs[0].Title,
            Overall_Score__c = 40,
            Readiness_Status__c = 'Needs Work'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id,
            Dimension__c = 'Completeness',
            Score__c = 30
        );
        insert dr;
        insert new List<KB_Dimension_Analysis__c>{
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa.Id,
                Dimension_Result__c = dr.Id,
                Type__c = 'Issue',
                Dimension__c = 'Completeness',
                Recommendation__c = 'Add a summary section.',
                Status__c = 'Open'
            ),
            // Duplication recs ARE returned — the per-article variant
            // includes them so the record-page panel can group them as
            // "manual-only" (with a Resolve button instead of a Fix
            // checkbox). The bulk inbox excludes them; this method does not.
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa.Id,
                Dimension_Result__c = dr.Id,
                Type__c = 'Issue',
                Dimension__c = 'Duplication',
                Recommendation__c = 'Merge.',
                Status__c = 'Open'
            )
        };

        Test.startTest();
        KBEnrichmentController.ImprovementArticleGroup grp =
            KBEnrichmentController.getImprovementsForArticle(kavs[0].Id);
        Test.stopTest();

        Assert.isNotNull(grp);
        Assert.areEqual(2, grp.recommendations.size(),
            'Both Completeness and Duplication recs are surfaced on the record-page panel');
        Set<String> dims = new Set<String>();
        for (KBEnrichmentController.ImprovementRow r : grp.recommendations) {
            dims.add(r.dimension);
        }
        Assert.isTrue(dims.contains('Completeness'), 'Completeness rec returned');
        Assert.isTrue(dims.contains('Duplication'), 'Duplication rec returned (manual-only group)');
        Assert.areEqual(kavs[0].Id, grp.articleId);
    }

    @IsTest
    static void testGetImprovementsForArticle_NoRecs_ReturnsNull() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'empty');
        Test.startTest();
        KBEnrichmentController.ImprovementArticleGroup grp =
            KBEnrichmentController.getImprovementsForArticle(kavs[0].Id);
        Test.stopTest();
        Assert.isNull(grp);
    }

    @IsTest
    static void testGetImprovementsForArticle_BlankId_ReturnsNull() {
        Test.startTest();
        KBEnrichmentController.ImprovementArticleGroup grp =
            KBEnrichmentController.getImprovementsForArticle(null);
        Test.stopTest();
        Assert.isNull(grp);
    }

    // ------------------------------------------------------------------ updateRecommendationStatus

    @IsTest
    static void testUpdateRecommendationStatus_BulkStatusChange() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'updstatus');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_Id__c = kavs[0].Id,
            Article_Title__c = kavs[0].Title,
            Overall_Score__c = 50,
            Readiness_Status__c = 'Needs Work'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id,
            Dimension__c = 'Clarity',
            Score__c = 50
        );
        insert dr;
        KB_Dimension_Analysis__c rec = new KB_Dimension_Analysis__c(
            Article_Assessment__c = aa.Id,
            Dimension_Result__c = dr.Id,
            Type__c = 'Issue',
            Dimension__c = 'Clarity',
            Recommendation__c = 'Simplify language.',
            Status__c = 'Open'
        );
        insert rec;

        Test.startTest();
        KBEnrichmentController.updateRecommendationStatus(
            new List<Id>{ rec.Id }, 'Rejected'
        );
        Test.stopTest();

        KB_Dimension_Analysis__c reloaded = [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Rejected', reloaded.Status__c, 'Status updated to Rejected');
    }

    @IsTest
    static void testUpdateRecommendationStatus_EmptyList_DoesNotThrow() {
        Test.startTest();
        KBEnrichmentController.updateRecommendationStatus(new List<Id>(), 'Rejected');
        Test.stopTest();
        // no exception expected
    }

    /**
     * S1 regression — `Status__c` is a restricted picklist, so passing an
     * invalid value should throw at DML time. We trust the platform here
     * rather than a hand-rolled whitelist (the picklist is the source of truth).
     */
    @IsTest
    static void testUpdateRecommendationStatus_InvalidStatus_ThrowsDmlException() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'invstatus');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_Id__c = kavs[0].Id,
            Article_Title__c = kavs[0].Title,
            Overall_Score__c = 50,
            Readiness_Status__c = 'Needs Work'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id,
            Dimension__c = 'Clarity',
            Score__c = 50
        );
        insert dr;
        KB_Dimension_Analysis__c rec = new KB_Dimension_Analysis__c(
            Article_Assessment__c = aa.Id,
            Dimension_Result__c = dr.Id,
            Type__c = 'Issue',
            Dimension__c = 'Clarity',
            Recommendation__c = 'Simplify language.',
            Status__c = 'Open'
        );
        insert rec;

        Boolean threw = false;
        Test.startTest();
        try {
            KBEnrichmentController.updateRecommendationStatus(
                new List<Id>{ rec.Id }, 'BogusValueNotInPicklist'
            );
        } catch (DmlException e) {
            threw = true;
        } catch (Exception e) {
            // AuraHandledException is also acceptable if the platform wraps it.
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid restricted-picklist value must throw at DML time.');
        // Verify the record was NOT mutated.
        KB_Dimension_Analysis__c reloaded = [
            SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id
        ];
        Assert.areEqual('Open', reloaded.Status__c,
            'Invalid status DML must roll back; row should still be Open.');
    }

    // ------------------------------------------------------------------ getImprovementsInbox per-article paging (C5)

    /**
     * C5 — confirms per-article paging: a noisy article with hundreds of recs
     * cannot starve other articles from the inbox. Old behaviour (LIMIT 500
     * recs across articles) would have hidden the second article entirely.
     *
     * Setup: 2 articles. Article A gets 60 recs (well above the legacy 500
     * cap when scaled by article count). Article B gets a single rec. Both
     * must appear in the inbox after the restructure.
     */
    @IsTest
    static void testGetImprovementsInbox_NoisyArticleDoesNotStarveOthers() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'noisyinbox');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        KB_Article_Assessment__c aaNoisy = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = kavs[0].Id,
            Knowledge_Article_Id__c = kavs[0].Id,
            Article_Title__c = kavs[0].Title,
            Overall_Score__c = 30,
            Readiness_Status__c = 'Not Ready'
        );
        KB_Article_Assessment__c aaQuiet = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = kavs[1].Id,
            Knowledge_Article_Id__c = kavs[1].Id,
            Article_Title__c = kavs[1].Title,
            Overall_Score__c = 70,
            Readiness_Status__c = 'Needs Work'
        );
        insert new List<KB_Article_Assessment__c>{ aaNoisy, aaQuiet };

        KB_Dimension_Result__c drNoisy = new KB_Dimension_Result__c(
            Article_Assessment__c = aaNoisy.Id, Dimension__c = 'Completeness', Score__c = 30
        );
        KB_Dimension_Result__c drQuiet = new KB_Dimension_Result__c(
            Article_Assessment__c = aaQuiet.Id, Dimension__c = 'Structure', Score__c = 60
        );
        insert new List<KB_Dimension_Result__c>{ drNoisy, drQuiet };

        // Article A: 60 recs (each with a unique recommendation text so they
        // survive the per-article dedup pass and reflect a real noisy article).
        List<KB_Dimension_Analysis__c> analyses = new List<KB_Dimension_Analysis__c>();
        for (Integer i = 0; i < 60; i++) {
            analyses.add(new KB_Dimension_Analysis__c(
                Article_Assessment__c = aaNoisy.Id,
                Dimension_Result__c = drNoisy.Id,
                Type__c = 'Issue',
                Dimension__c = 'Completeness',
                Recommendation__c = 'Add detail #' + i,
                Status__c = 'Open'
            ));
        }
        // Article B: a single rec at the tail of any natural ordering.
        analyses.add(new KB_Dimension_Analysis__c(
            Article_Assessment__c = aaQuiet.Id,
            Dimension_Result__c = drQuiet.Id,
            Type__c = 'Issue',
            Dimension__c = 'Structure',
            Recommendation__c = 'Use proper headers.',
            Status__c = 'Open'
        ));
        insert analyses;

        Test.startTest();
        List<KBEnrichmentController.ImprovementArticleGroup> groups =
            KBEnrichmentController.getImprovementsInbox(null);
        Test.stopTest();

        Assert.areEqual(2, groups.size(),
            'Per-article paging should return both articles, even when one has '
            + 'hundreds more recs than the other (C5).');

        Set<String> returnedArticleIds = new Set<String>();
        for (KBEnrichmentController.ImprovementArticleGroup g : groups) {
            returnedArticleIds.add(g.articleId);
        }
        Assert.isTrue(returnedArticleIds.contains(kavs[1].Id),
            'The quiet article must surface — old LIMIT 500 behaviour would have hidden it.');
    }

 // pagination + real total

    /**
 * getImprovementsInboxPage returns one page of article groups plus
     * the REAL total article count (not the page cap), and OFFSET walks pages
     * without overlap. Setup: 5 articles each with one open issue; page size 2.
     */
    @IsTest
    static void testGetImprovementsInboxPage_PaginatesWithRealTotal() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(5, 'paginbox');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        List<KB_Article_Assessment__c> aas = new List<KB_Article_Assessment__c>();
        for (Integer i = 0; i < 5; i++) {
            aas.add(new KB_Article_Assessment__c(
                Assessment_Run__c = run.Id, Knowledge__c = kavs[i].Id,
                Knowledge_Article_Id__c = kavs[i].Id, Article_Title__c = kavs[i].Title,
                Overall_Score__c = 40, Readiness_Status__c = 'Not Ready'
            ));
        }
        insert aas;
        // KB_Dimension_Analysis__c.Dimension_Result__c is a required master-detail,
        // so seed one dimension result per assessment first.
        List<KB_Dimension_Result__c> drs = new List<KB_Dimension_Result__c>();
        for (Integer i = 0; i < 5; i++) {
            drs.add(new KB_Dimension_Result__c(
                Article_Assessment__c = aas[i].Id, Dimension__c = 'Completeness', Score__c = 40
            ));
        }
        insert drs;
        List<KB_Dimension_Analysis__c> analyses = new List<KB_Dimension_Analysis__c>();
        for (Integer i = 0; i < 5; i++) {
            analyses.add(new KB_Dimension_Analysis__c(
                Article_Assessment__c = aas[i].Id, Dimension_Result__c = drs[i].Id, Type__c = 'Issue',
                Dimension__c = 'Completeness', Recommendation__c = 'Fix #' + i, Status__c = 'Open'
            ));
        }
        insert analyses;

        Test.startTest();
        KBEnrichmentController.ImprovementInboxPage p0 =
            KBEnrichmentController.getImprovementsInboxPage(null, 2, 0, null);
        KBEnrichmentController.ImprovementInboxPage p1 =
            KBEnrichmentController.getImprovementsInboxPage(null, 2, 2, null);
        KBEnrichmentController.ImprovementInboxPage p2 =
            KBEnrichmentController.getImprovementsInboxPage(null, 2, 4, null);
        Test.stopTest();

        // Real total is 5 on every page, regardless of page size.
        Assert.areEqual(5, p0.totalArticles, 'Total is the real distinct-article count');
        Assert.areEqual(5, p2.totalArticles, 'Total stays the real count on the last page');
        // Pages carry the requested slice sizes: 2 + 2 + 1 = 5, no overlap.
        Assert.areEqual(2, p0.groups.size(), 'Page 0 → 2 articles');
        Assert.areEqual(2, p1.groups.size(), 'Page 1 → 2 articles');
        Assert.areEqual(1, p2.groups.size(), 'Page 2 → last article');
        Set<String> seen = new Set<String>();
        for (KBEnrichmentController.ImprovementInboxPage pg : new List<KBEnrichmentController.ImprovementInboxPage>{ p0, p1, p2 }) {
            for (KBEnrichmentController.ImprovementArticleGroup g : pg.groups) {
                Assert.isTrue(seen.add(g.articleId), 'No article repeats across pages (stable OFFSET order)');
            }
        }
        Assert.areEqual(5, seen.size(), 'All 5 distinct articles paged through exactly once');
    }

    /**
 * review (blocker 2) — the dimension filter is now SERVER-SIDE, so the
     * real total, the page and the fetched recs all scope to one dimension. This
     * is what makes "select all N matching" honest: it can't fetch (and dispatch)
     * cross-dimension recs. Setup: 3 articles, each with a Completeness AND a
     * Clarity open issue; filter to Clarity.
     */
    @IsTest
    static void testGetImprovementsInboxPage_DimensionFilterIsServerSide() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(3, 'dimbox');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        List<KB_Article_Assessment__c> aas = new List<KB_Article_Assessment__c>();
        for (Integer i = 0; i < 3; i++) {
            aas.add(new KB_Article_Assessment__c(
                Assessment_Run__c = run.Id, Knowledge__c = kavs[i].Id,
                Knowledge_Article_Id__c = kavs[i].Id, Article_Title__c = kavs[i].Title,
                Overall_Score__c = 40, Readiness_Status__c = 'Not Ready'
            ));
        }
        insert aas;
        List<KB_Dimension_Result__c> drs = new List<KB_Dimension_Result__c>();
        for (Integer i = 0; i < 3; i++) {
            drs.add(new KB_Dimension_Result__c(
                Article_Assessment__c = aas[i].Id, Dimension__c = 'Completeness', Score__c = 40
            ));
        }
        insert drs;
        List<KB_Dimension_Analysis__c> analyses = new List<KB_Dimension_Analysis__c>();
        for (Integer i = 0; i < 3; i++) {
            analyses.add(new KB_Dimension_Analysis__c(
                Article_Assessment__c = aas[i].Id, Dimension_Result__c = drs[i].Id, Type__c = 'Issue',
                Dimension__c = 'Completeness', Recommendation__c = 'Comp #' + i, Status__c = 'Open'
            ));
            analyses.add(new KB_Dimension_Analysis__c(
                Article_Assessment__c = aas[i].Id, Dimension_Result__c = drs[i].Id, Type__c = 'Issue',
                Dimension__c = 'Clarity', Recommendation__c = 'Clarity #' + i, Status__c = 'Open'
            ));
        }
        insert analyses;

        Test.startTest();
        KBEnrichmentController.ImprovementInboxPage all =
            KBEnrichmentController.getImprovementsInboxPage(null, 25, 0, null);
        KBEnrichmentController.ImprovementInboxPage clarity =
            KBEnrichmentController.getImprovementsInboxPage(null, 25, 0, 'Clarity');
        KBEnrichmentController.ImprovementInboxPage bogus =
            KBEnrichmentController.getImprovementsInboxPage(null, 25, 0, 'NotADimension');
        Test.stopTest();

        // Same 3 articles either way (each has issues in both dimensions), but
        // the Clarity page carries ONLY Clarity recs.
        Assert.areEqual(3, all.totalArticles, 'Unfiltered: 3 distinct articles');
        Assert.areEqual(3, clarity.totalArticles, 'Clarity filter: still 3 articles, but Clarity-scoped');
        Integer clarityRecs = 0;
        for (KBEnrichmentController.ImprovementArticleGroup g : clarity.groups) {
            for (KBEnrichmentController.ImprovementRow r : g.recommendations) {
                Assert.areEqual('Clarity', r.dimension, 'Filtered page returns only Clarity recs');
                clarityRecs++;
            }
        }
        Assert.areEqual(3, clarityRecs, 'One Clarity rec per article, no Completeness bleed-through');
        // Off-list dimension is ignored → behaves like "All dimensions".
        Assert.areEqual(3, bogus.totalArticles, 'Off-list dimension falls back to unfiltered');
    }

    /**
 * review (blocker 3) — countArticlesWithOpenIssues is the bulk-run
     * completion ledger: it counts distinct dispatched articles that still carry
     * an open/errored non-dedup issue, independent of any page/dimension. Prove
     * (a) an article with an open issue counts, (b) resolving it drops the count,
     * (c) dedup dimensions and unknown ids are excluded, (d) empty/null → 0.
     */
    @IsTest
    static void testCountArticlesWithOpenIssues_LedgerIsPageAndFilterAgnostic() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'ledger');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        List<KB_Article_Assessment__c> aas = new List<KB_Article_Assessment__c>();
        for (Integer i = 0; i < 2; i++) {
            aas.add(new KB_Article_Assessment__c(
                Assessment_Run__c = run.Id, Knowledge__c = kavs[i].Id,
                Knowledge_Article_Id__c = kavs[i].Id, Article_Title__c = kavs[i].Title,
                Overall_Score__c = 40, Readiness_Status__c = 'Not Ready'
            ));
        }
        insert aas;
        List<KB_Dimension_Result__c> drs = new List<KB_Dimension_Result__c>();
        for (Integer i = 0; i < 2; i++) {
            drs.add(new KB_Dimension_Result__c(
                Article_Assessment__c = aas[i].Id, Dimension__c = 'Completeness', Score__c = 40
            ));
        }
        insert drs;
        // Article 0: one OPEN Completeness issue. Article 1: only a Duplication
        // issue (dedup — excluded) so it must NOT count.
        KB_Dimension_Analysis__c openRec = new KB_Dimension_Analysis__c(
            Article_Assessment__c = aas[0].Id, Dimension_Result__c = drs[0].Id, Type__c = 'Issue',
            Dimension__c = 'Completeness', Recommendation__c = 'Fix it', Status__c = 'Open'
        );
        insert new List<KB_Dimension_Analysis__c>{
            openRec,
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aas[1].Id, Dimension_Result__c = drs[1].Id, Type__c = 'Issue',
                Dimension__c = 'Duplication', Recommendation__c = 'dup', Status__c = 'Open'
            )
        };

        List<Id> both = new List<Id>{ kavs[0].Id, kavs[1].Id };

        Test.startTest();
        Integer before = KBEnrichmentController.countArticlesWithOpenIssues(both);
        // Resolve the only non-dedup open issue.
        openRec.Status__c = 'Resolved';
        update openRec;
        Integer after = KBEnrichmentController.countArticlesWithOpenIssues(both);
        Integer emptyIn = KBEnrichmentController.countArticlesWithOpenIssues(new List<Id>());
        Integer nullIn = KBEnrichmentController.countArticlesWithOpenIssues(null);
        Test.stopTest();

        Assert.areEqual(1, before,
            'Only article 0 counts (article 1 has a dedup-only issue, excluded)');
        Assert.areEqual(0, after,
            'Resolving the open issue drops the ledger to 0 → run can complete');
        Assert.areEqual(0, emptyIn, 'Empty id list → 0');
        Assert.areEqual(0, nullIn, 'Null id list → 0');
    }

    // ------------------------------------------------------------------ Error rec inclusion (C6)

    /**
     * C6 — `getImprovementsInbox` now returns recs in `Open` OR `Error` status
     * so previously-failed fix attempts surface for retry. The LWC consumes
     * `row.status` to render a Failed badge.
     */
    @IsTest
    static void testGetImprovementsInbox_IncludesErroredRecs() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'erroredinbox');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = kavs[0].Id,
            Knowledge_Article_Id__c = kavs[0].Id,
            Article_Title__c = kavs[0].Title,
            Overall_Score__c = 40,
            Readiness_Status__c = 'Needs Work'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id, Dimension__c = 'Completeness', Score__c = 40
        );
        insert dr;
        insert new List<KB_Dimension_Analysis__c>{
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa.Id,
                Dimension_Result__c = dr.Id,
                Type__c = 'Issue',
                Dimension__c = 'Completeness',
                Recommendation__c = 'Open issue.',
                Status__c = 'Open'
            ),
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa.Id,
                Dimension_Result__c = dr.Id,
                Type__c = 'Issue',
                Dimension__c = 'Completeness',
                Recommendation__c = 'Errored issue.',
                Status__c = 'Error'
            ),
            // Resolved should still be excluded.
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa.Id,
                Dimension_Result__c = dr.Id,
                Type__c = 'Issue',
                Dimension__c = 'Completeness',
                Recommendation__c = 'Already resolved.',
                Status__c = 'Resolved'
            )
        };

        Test.startTest();
        List<KBEnrichmentController.ImprovementArticleGroup> groups =
            KBEnrichmentController.getImprovementsInbox(null);
        Test.stopTest();

        Assert.areEqual(1, groups.size(), 'One article group');
        Assert.areEqual(2, groups[0].recommendations.size(),
            'Open + Error recs surface; Resolved stays hidden.');

        Set<String> statuses = new Set<String>();
        for (KBEnrichmentController.ImprovementRow r : groups[0].recommendations) {
            statuses.add(r.status);
        }
        Assert.isTrue(statuses.contains('Open'), 'Open rec returned with status field set');
        Assert.isTrue(statuses.contains('Error'), 'Error rec returned with status field set');
    }

    // ------------------------------------------------------------------ requeueErroredRecommendations (C6)

    @IsTest
    static void testRequeueErroredRecommendations_FlipsErrorToOpen() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'requeue');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_Id__c = kavs[0].Id,
            Article_Title__c = kavs[0].Title,
            Overall_Score__c = 40,
            Readiness_Status__c = 'Needs Work'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id, Dimension__c = 'Completeness', Score__c = 40
        );
        insert dr;
        KB_Dimension_Analysis__c errored = new KB_Dimension_Analysis__c(
            Article_Assessment__c = aa.Id,
            Dimension_Result__c = dr.Id,
            Type__c = 'Issue',
            Dimension__c = 'Completeness',
            Recommendation__c = 'Errored.',
            Status__c = 'Error'
        );
        KB_Dimension_Analysis__c openOne = new KB_Dimension_Analysis__c(
            Article_Assessment__c = aa.Id,
            Dimension_Result__c = dr.Id,
            Type__c = 'Issue',
            Dimension__c = 'Completeness',
            Recommendation__c = 'Already open.',
            Status__c = 'Open'
        );
        insert new List<KB_Dimension_Analysis__c>{ errored, openOne };

        Test.startTest();
        KBEnrichmentController.requeueErroredRecommendations(
            new List<Id>{ errored.Id, openOne.Id }
        );
        Test.stopTest();

        Map<Id, KB_Dimension_Analysis__c> reloaded = new Map<Id, KB_Dimension_Analysis__c>([
            SELECT Id, Status__c FROM KB_Dimension_Analysis__c
            WHERE Id IN :new List<Id>{ errored.Id, openOne.Id }
        ]);
        Assert.areEqual('Open', reloaded.get(errored.Id).Status__c,
            'Error rec flips to Open');
        Assert.areEqual('Open', reloaded.get(openOne.Id).Status__c,
            'Already-Open rec is left alone (filter clause skipped it)');
    }

    @IsTest
    static void testRequeueErroredRecommendations_EmptyOrNull_NoOp() {
        Test.startTest();
        KBEnrichmentController.requeueErroredRecommendations(new List<Id>());
        KBEnrichmentController.requeueErroredRecommendations(null);
        Test.stopTest();
        // No exception expected.
    }

    // ------------------------------------------------------------------ closeEnrichmentCandidatesForDraft

    @IsTest
    static void testCloseEnrichmentCandidatesForDraft_ClosesMatchingCandidates() {
        Enrichment_Candidate__c c = getCandidates()[0];
        c.Draft_Article_Version_Id__c = 'ka0DRAFT00000001';
        update c;

        Test.startTest();
        KBEnrichmentController.closeEnrichmentCandidatesForDraft('ka0DRAFT00000001');
        Test.stopTest();

        Enrichment_Candidate__c reloaded = [
            SELECT Status__c, Is_Closed__c FROM Enrichment_Candidate__c WHERE Id = :c.Id
        ];
        Assert.areEqual('Published', reloaded.Status__c);
        Assert.isTrue(reloaded.Is_Closed__c);
    }

    @IsTest
    static void testCloseEnrichmentCandidatesForDraft_BlankId_NoOp() {
        Test.startTest();
        KBEnrichmentController.closeEnrichmentCandidatesForDraft('');
        KBEnrichmentController.closeEnrichmentCandidatesForDraft(null);
        Test.stopTest();
        // No exception expected.
    }

 // graceful publish + lazy reconcile ----------------

    /**
     * publishCandidate gracefully closes the EC when the linked draft is
 * already Online (manual publish from the Knowledge layout).
     */
    @IsTest
    static void publishCandidate_DraftAlreadyOnline_GracefulClose() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(1, 'pub-graceful');
        Knowledge__kav kav = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];

        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = kav.Id,
            Source_Article_Title__c = 'A',
            Draft_Article_Version_Id__c = String.valueOf(kav.Id),
            Knowledge_Article_Id__c = String.valueOf(kav.KnowledgeArticleId),
            Composite_Key__c = 'test-graceful-' + kav.Id,
            Status__c = 'Pending',
            Is_Closed__c = false,
            Confidence_Score__c = 90,
            Assessment_Run__c = run.Id
        );
        insert ec;

        // Publish so the linked KAV is Online; the controller graceful-close
        // path then closes the candidate on publishCandidate below.
        KbManagement.PublishingService.publishArticle(kav.KnowledgeArticleId, true);

        Test.startTest();
        KBEnrichmentController.ActionResult result = KBEnrichmentController.publishCandidate(String.valueOf(ec.Id));
        Test.stopTest();

        Assert.isTrue(result.success, 'Graceful path returns success even when draft was already Online');
        Enrichment_Candidate__c reloaded = [SELECT Status__c, Is_Closed__c FROM Enrichment_Candidate__c WHERE Id = :ec.Id];
        Assert.isTrue(reloaded.Is_Closed__c, 'EC should be closed after graceful publish');
    }

    /**
 * the Suggested Drafts list is filtered by the linked draft's
     * PublishStatus — a candidate whose draft is still a Draft is shown; one
     * whose draft has been published (or superseded) is hidden. This is the UI
     * filter that replaced the former reconcile-on-inbox-load DML hook.
     */
    @IsTest
    static void getEnrichmentInbox_HidesCandidateWhoseDraftIsPublished() {
        // Two articles: one stays a Draft (shown), one gets published (hidden).
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'inbox-filter');
        Knowledge__kav draftKav = [SELECT Id, PublishStatus FROM Knowledge__kav WHERE Id = :arts[0].Id];
        Knowledge__kav publishKav = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[1].Id];
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];

        Enrichment_Candidate__c stillDraft = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = draftKav.Id,
            Source_Article_Title__c = 'Still a draft',
            Draft_Article_Version_Id__c = String.valueOf(draftKav.Id),
            Composite_Key__c = 'inbox-filter-draft-' + draftKav.Id,
            Status__c = 'Pending',
            Is_Closed__c = false,
            Confidence_Score__c = 90,
            Assessment_Run__c = run.Id
        );
        Enrichment_Candidate__c willPublish = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = publishKav.Id,
            Source_Article_Title__c = 'Now published',
            Draft_Article_Version_Id__c = String.valueOf(publishKav.Id),
            Composite_Key__c = 'inbox-filter-pub-' + publishKav.Id,
            Status__c = 'Pending',
            Is_Closed__c = false,
            Confidence_Score__c = 80,
            Assessment_Run__c = run.Id
        );
        insert new List<Enrichment_Candidate__c>{ stillDraft, willPublish };

        // Publish the second article's draft → its linked KAV is now Online.
 // This test isolates the UI filter: the row stays Is_Closed__c=false
        // (no on-load mutation) but is hidden from the inbox by PublishStatus.
        KbManagement.PublishingService.publishArticle(publishKav.KnowledgeArticleId, true);

        Test.startTest();
        KBEnrichmentController.EnrichmentInboxData data =
            KBEnrichmentController.getEnrichmentInbox(200, null);
        Test.stopTest();

        Set<String> shownIds = new Set<String>();
        for (KBEnrichmentController.SplitProposalRow r : data.candidates) {
            shownIds.add(r.proposalId);
        }
        Assert.isTrue(shownIds.contains(String.valueOf(stillDraft.Id)),
            'A candidate whose draft is still a Draft stays in the list');
        Assert.isFalse(shownIds.contains(String.valueOf(willPublish.Id)),
            'A candidate whose draft was published is filtered out of the list');
    }

    /**
 * (review finding F602-1): the load-bearing "positive-evidence only"
     * safety invariant — a row is hidden ONLY on positive proof the linked
     * draft is no longer a Draft (resolved AND PublishStatus present AND not
     * Draft). When the draft can't be resolved (deleted/absent KAV, or an FLS
     * strip leaving no row in the map) or the id is blank, the row MUST stay
     * VISIBLE — never silently emptied. A future "simplification" to
     * `if (!isDraft(ps)) continue;` would break this and hide everything on any
     * FLS/sharing gap; this test locks it.
     */
    @IsTest
    static void getEnrichmentInbox_KeepsRowWhenDraftUnresolvedOrBlank() {
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];

        // (i) draft pointer at a valid-shape but NON-EXISTENT KAV id → the
        // display SELECT returns no row → not in draftsById → must stay shown.
        String kavPrefix = Knowledge__kav.SObjectType.getDescribe().getKeyPrefix();
        String ghostKav = kavPrefix + '000000000000001'; // valid shape, no such row
        Enrichment_Candidate__c unresolved = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = ghostKav,
            Source_Article_Title__c = 'Draft deleted out of band',
            Draft_Article_Version_Id__c = ghostKav,
            Composite_Key__c = 'inbox-filter-ghost-' + ghostKav,
            Status__c = 'Pending', Is_Closed__c = false,
            Confidence_Score__c = 70, Assessment_Run__c = run.Id
        );
        // (ii) blank DRAFT pointer → nothing to check → must stay shown.
        // (Source_Article_Version_Id__c is required on the object, so it's set;
        //  the invariant under test is specifically a blank Draft_Article_Version_Id__c.)
        Enrichment_Candidate__c noDraft = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = ghostKav,
            Source_Article_Title__c = 'No linked draft',
            Composite_Key__c = 'inbox-filter-nodraft-' + String.valueOf(Datetime.now().getTime()),
            Status__c = 'Pending', Is_Closed__c = false,
            Confidence_Score__c = 60, Assessment_Run__c = run.Id
        );
        insert new List<Enrichment_Candidate__c>{ unresolved, noDraft };

        Test.startTest();
        KBEnrichmentController.EnrichmentInboxData data =
            KBEnrichmentController.getEnrichmentInbox(200, null);
        Test.stopTest();

        Set<String> shownIds = new Set<String>();
        for (KBEnrichmentController.SplitProposalRow r : data.candidates) {
            shownIds.add(r.proposalId);
        }
        Assert.isTrue(shownIds.contains(String.valueOf(unresolved.Id)),
            'Unresolvable draft (deleted/absent/FLS-stripped) must stay VISIBLE — '
            + 'positive-evidence-only guard (F602-1)');
        Assert.isTrue(shownIds.contains(String.valueOf(noDraft.Id)),
            'Candidate with a blank draft pointer must stay VISIBLE (nothing to check)');
    }

    // ------------------------------------------------------------------ getEnrichmentInbox edge cases

    @IsTest
    static void getEnrichmentInbox_InvalidRunId_ReturnsEmpty() {
        Test.startTest();
        KBEnrichmentController.EnrichmentInboxData data =
            KBEnrichmentController.getEnrichmentInbox(100, 'not-a-real-id');
        Test.stopTest();

        Assert.areEqual(0, data.candidates.size(), 'Garbage runId must short-circuit to empty, not all-rows');
    }

    @IsTest
    static void getEnrichmentInbox_EmptyRun_ReturnsEmpty() {
        KB_Assessment_Run__c emptyRun = KBTestDataFactory.insertRun('Completed', 'Readiness');

        Test.startTest();
        KBEnrichmentController.EnrichmentInboxData data =
            KBEnrichmentController.getEnrichmentInbox(100, emptyRun.Id);
        Test.stopTest();

        Assert.areEqual(0, data.candidates.size(), 'A run with no candidates returns the empty sentinel');
        Assert.areEqual(0, data.pendingCount);
    }

    @IsTest
    static void getEnrichmentInbox_ApprovedAndRejectedCountsTracked() {
        List<Enrichment_Candidate__c> candidates = getCandidates();
        candidates[0].Status__c = 'Approved';
        candidates[1].Status__c = 'Rejected';
        update candidates;

        Test.startTest();
        KBEnrichmentController.EnrichmentInboxData data = KBEnrichmentController.getEnrichmentInbox(100, null);
        Test.stopTest();

        Assert.areEqual(1, data.approvedCount, 'Approved candidate counted');
        Assert.areEqual(1, data.rejectedCount, 'Rejected candidate counted');
        Assert.areEqual(0, data.pendingCount, 'No candidates left Pending');
    }

    // ------------------------------------------------------------------ publishCandidate error paths

    @IsTest
    static void publishCandidate_BlankId_ThrowsFriendlyMessage() {
        Boolean threw = false;
        try {
            KBEnrichmentController.publishCandidate('');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, 'Blank candidate id must throw');
    }

    @IsTest
    static void publishCandidate_NotFound_ThrowsFriendlyMessage() {
        Boolean threw = false;
        try {
            KBEnrichmentController.publishCandidate('a0KFAKE0000000ZZ');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, 'Non-existent candidate id must throw');
    }

    @IsTest
    static void publishCandidate_DraftDeletedBlankArticleId_Throws() {
        String kavPrefix = Knowledge__kav.SObjectType.getDescribe().getKeyPrefix();
        String ghostKav = kavPrefix + '000000000002';
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = ghostKav,
            Source_Article_Title__c = 'Ghost',
            Draft_Article_Version_Id__c = ghostKav,
            Composite_Key__c = 'ghost-blank-artid-' + ghostKav,
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 70,
            Assessment_Run__c = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id
        );
        insert ec;

        Boolean threw = false;
        Test.startTest();
        try {
            KBEnrichmentController.publishCandidate(String.valueOf(ec.Id));
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('deleted') || e.getMessage().contains('accessible'),
                'Message should explain the draft is gone: ' + e.getMessage());
        }
        Test.stopTest();
        Assert.isTrue(threw, 'A deleted draft with no article-id fallback must throw');
    }

    @IsTest
    static void publishCandidate_DraftDeletedInvalidArticleId_Throws() {
        String kavPrefix = Knowledge__kav.SObjectType.getDescribe().getKeyPrefix();
        String ghostKav = kavPrefix + '000000000003';
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = ghostKav,
            Source_Article_Title__c = 'Ghost invalid articleid',
            Draft_Article_Version_Id__c = ghostKav,
            Knowledge_Article_Id__c = 'not-a-valid-id',
            Composite_Key__c = 'ghost-badartid-' + ghostKav,
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 70,
            Assessment_Run__c = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id
        );
        insert ec;

        Boolean threw = false;
        Test.startTest();
        try {
            KBEnrichmentController.publishCandidate(String.valueOf(ec.Id));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw, 'A malformed Knowledge_Article_Id__c must fall through to the deleted-draft error');
    }

    @IsTest
    static void publishCandidate_DraftDeletedNoOnlineVersion_Throws() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(1, 'pub-no-online');
        Knowledge__kav kav = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        String kavPrefix = Knowledge__kav.SObjectType.getDescribe().getKeyPrefix();
        String ghostKav = kavPrefix + '000000000004';

        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = ghostKav,
            Source_Article_Title__c = 'Ghost, real article but never published',
            Draft_Article_Version_Id__c = ghostKav,
            Knowledge_Article_Id__c = String.valueOf(kav.KnowledgeArticleId),
            Composite_Key__c = 'ghost-noonline-' + ghostKav,
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 70,
            Assessment_Run__c = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id
        );
        insert ec;

        Boolean threw = false;
        Test.startTest();
        try {
            KBEnrichmentController.publishCandidate(String.valueOf(ec.Id));
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Article exists but has no Online version — graceful path finds nothing, must throw');
    }

    @IsTest
    static void publishCandidate_DraftDeletedButArticlePublishedElsewhere_GracefulClose() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(1, 'pub-elsewhere');
        Knowledge__kav kav = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        KbManagement.PublishingService.publishArticle(kav.KnowledgeArticleId, true);
        Knowledge__kav online = [
            SELECT Id FROM Knowledge__kav
            WHERE KnowledgeArticleId = :kav.KnowledgeArticleId AND PublishStatus = 'Online'
            AND IsLatestVersion = true LIMIT 1
        ];

        String kavPrefix = Knowledge__kav.SObjectType.getDescribe().getKeyPrefix();
        String ghostKav = kavPrefix + '000000000005';
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = ghostKav,
            Source_Article_Title__c = 'Ghost, published under a different version',
            Draft_Article_Version_Id__c = ghostKav,
            Knowledge_Article_Id__c = String.valueOf(kav.KnowledgeArticleId),
            Composite_Key__c = 'ghost-supersede-' + ghostKav,
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 70,
            Assessment_Run__c = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id
        );
        insert ec;

        Test.startTest();
        KBEnrichmentController.ActionResult result = KBEnrichmentController.publishCandidate(String.valueOf(ec.Id));
        Test.stopTest();

        Assert.isTrue(result.success, 'Graceful path succeeds when a different version is already Online');
        Assert.isTrue(result.message.contains('superseded'),
            'The online version differs from the ghost draft pointer — must report superseded, not already-published: '
            + result.message);
        Enrichment_Candidate__c reloaded = [SELECT Is_Closed__c FROM Enrichment_Candidate__c WHERE Id = :ec.Id];
        Assert.isTrue(reloaded.Is_Closed__c);
    }

    @IsTest
    static void publishCandidate_DraftStillDraft_PublishesAndClosesCandidate() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(1, 'pub-happy');
        Knowledge__kav kav = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = kav.Id,
            Source_Article_Title__c = 'Happy path',
            Draft_Article_Version_Id__c = String.valueOf(kav.Id),
            Knowledge_Article_Id__c = String.valueOf(kav.KnowledgeArticleId),
            Composite_Key__c = 'test-happy-' + kav.Id,
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 90,
            Assessment_Run__c = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id
        );
        insert ec;

        Test.startTest();
        KBEnrichmentController.ActionResult result = KBEnrichmentController.publishCandidate(String.valueOf(ec.Id));
        Test.stopTest();

        Assert.isTrue(result.success, 'Publishing a still-Draft article should succeed');
        Assert.areEqual('Draft published.', result.message);
        Enrichment_Candidate__c reloaded = [SELECT Status__c, Is_Closed__c FROM Enrichment_Candidate__c WHERE Id = :ec.Id];
        Assert.areEqual('Published', reloaded.Status__c);
        Assert.isTrue(reloaded.Is_Closed__c);
    }

    @IsTest
    static void publishCandidate_GenericPublishFailure_TranslatesFriendlyMessage() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(1, 'pub-mockfail');
        Knowledge__kav kav = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = kav.Id,
            Source_Article_Title__c = 'Mock publish failure',
            Draft_Article_Version_Id__c = String.valueOf(kav.Id),
            Knowledge_Article_Id__c = String.valueOf(kav.KnowledgeArticleId),
            Composite_Key__c = 'test-mockfail-' + kav.Id,
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 90,
            Assessment_Run__c = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id
        );
        insert ec;

        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        pub.throwOnPublish = true;
        KBEnrichmentController.publisher = pub;

        Boolean threw = false;
        Test.startTest();
        try {
            KBEnrichmentController.publishCandidate(String.valueOf(ec.Id));
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(String.isNotBlank(e.getMessage()), 'A generic publish failure must surface a friendly message');
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Mocked publish failure must be caught and translated');
    }

    @IsTest
    static void publishCandidatesBulk_GenericPublishFailure_ReturnsFriendlyPerItemMessage() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(1, 'bulk-mockfail');
        Knowledge__kav kav = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = kav.Id,
            Source_Article_Title__c = 'Bulk mock publish failure',
            Draft_Article_Version_Id__c = String.valueOf(kav.Id),
            Knowledge_Article_Id__c = String.valueOf(kav.KnowledgeArticleId),
            Composite_Key__c = 'test-bulkmockfail-' + kav.Id,
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 90,
            Assessment_Run__c = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id
        );
        insert ec;

        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        pub.throwOnPublish = true;
        KBEnrichmentController.publisher = pub;

        Test.startTest();
        List<KBEnrichmentController.ActionResult> results =
            KBEnrichmentController.publishCandidatesBulk(new List<String>{ String.valueOf(ec.Id) });
        Test.stopTest();

        Assert.areEqual(1, results.size());
        Assert.isFalse(results[0].success, 'Mocked publish failure must be reported as a per-item failure');
        Assert.isTrue(String.isNotBlank(results[0].message));
    }

    // ------------------------------------------------------------------ friendlyPublishErrorMessage branches

    @IsTest
    static void friendlyPublishError_BlankOrScriptThrown_ReturnsGenericMessage() {
        Assert.areEqual(
            'Could not publish draft. Verify the article still exists and is not already published.',
            KBEnrichmentController.friendlyPublishErrorMessage(new EnrichmentControllerTestException('Script-thrown exception'))
        );
        Assert.areEqual(
            'Could not publish draft. Verify the article still exists and is not already published.',
            KBEnrichmentController.friendlyPublishErrorMessage(new EnrichmentControllerTestException(''))
        );
    }

    @IsTest
    static void friendlyPublishError_InvalidId_MapsToFriendlyMessage() {
        Assert.areEqual('Draft article ID is invalid or no longer exists.',
            KBEnrichmentController.friendlyPublishErrorMessage(
                new EnrichmentControllerTestException('Invalid ID field for this object.')));
    }

    @IsTest
    static void friendlyPublishError_CantPerformAction_MatchesSecondClause() {
        String friendly = KBEnrichmentController.friendlyPublishErrorMessage(
            new EnrichmentControllerTestException('Sorry, you can\'t perform this action right now.'));
        Assert.isTrue(friendly.containsIgnoreCase('permission'), 'Second OR clause must still route to the ambiguous message: ' + friendly);
    }

    @IsTest
    static void friendlyPublishError_CannotPerformAction_MatchesThirdClause() {
        String friendly = KBEnrichmentController.friendlyPublishErrorMessage(
            new EnrichmentControllerTestException('Sorry, but you cannot perform this action right now.'));
        Assert.isTrue(friendly.containsIgnoreCase('permission'), 'Third OR clause must still route to the ambiguous message: ' + friendly);
    }

    // ------------------------------------------------------------------ rejectCandidate / rejectCandidatesBulk

    @IsTest
    static void rejectCandidate_BlankCandidateId_Throws() {
        Boolean threw = false;
        try {
            KBEnrichmentController.rejectCandidate('', 'reason');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, 'Blank candidate id should require validation before the reason check');
    }

    @IsTest
    static void rejectCandidatesBulk_NullInput_ReturnsEmpty() {
        List<KBEnrichmentController.ActionResult> results = KBEnrichmentController.rejectCandidatesBulk(null, 'reason');
        Assert.areEqual(0, results.size());
    }

    // ------------------------------------------------------------------ getImprovementsInboxPage edge cases

    @IsTest
    static void getImprovementsInboxPage_InvalidRunId_ReturnsEmptyPage() {
        Test.startTest();
        KBEnrichmentController.ImprovementInboxPage page =
            KBEnrichmentController.getImprovementsInboxPage('not-a-real-id', 25, 0, null);
        Test.stopTest();

        Assert.areEqual(0, page.totalArticles, 'Garbage runId must short-circuit to an empty page');
        Assert.areEqual(0, page.groups.size());
    }

    @IsTest
    static void getImprovementsInboxPage_RunScopedAndOffsetClampedToLastPage() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'runscopedpage');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        List<KB_Article_Assessment__c> aas = new List<KB_Article_Assessment__c>();
        for (Integer i = 0; i < 2; i++) {
            aas.add(new KB_Article_Assessment__c(
                Assessment_Run__c = run.Id, Knowledge__c = kavs[i].Id,
                Knowledge_Article_Id__c = kavs[i].Id, Article_Title__c = kavs[i].Title,
                Overall_Score__c = 40, Readiness_Status__c = 'Not Ready'
            ));
        }
        insert aas;
        List<KB_Dimension_Result__c> drs = new List<KB_Dimension_Result__c>();
        for (Integer i = 0; i < 2; i++) {
            drs.add(new KB_Dimension_Result__c(
                Article_Assessment__c = aas[i].Id, Dimension__c = 'Completeness', Score__c = 40
            ));
        }
        insert drs;
        List<KB_Dimension_Analysis__c> analyses = new List<KB_Dimension_Analysis__c>();
        for (Integer i = 0; i < 2; i++) {
            analyses.add(new KB_Dimension_Analysis__c(
                Article_Assessment__c = aas[i].Id, Dimension_Result__c = drs[i].Id, Type__c = 'Issue',
                Dimension__c = 'Completeness', Recommendation__c = 'Fix #' + i, Status__c = 'Open'
            ));
        }
        insert analyses;

        Test.startTest();
        // Run-scoped (exercises the runId-not-null branches on the count/page/rec
        // queries) with an offset far beyond INBOX_MAX_OFFSET (clamps to 2000,
        // which is also far beyond this run's 2 matching articles — the page
        // query legitimately returns zero rows despite totalArticles > 0).
        KBEnrichmentController.ImprovementInboxPage page =
            KBEnrichmentController.getImprovementsInboxPage(run.Id, 25, 999999, null);
        Test.stopTest();

        Assert.areEqual(2, page.totalArticles, 'Run-scoped total still reflects the real count');
        Assert.areEqual(0, page.groups.size(), 'Offset clamped beyond available rows returns an empty page');
    }

    @IsTest
    static void getImprovementsInboxPage_RunScoped_ReachesRecFetchWithResults() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'runscopedrecs');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id, Knowledge__c = kavs[0].Id,
            Knowledge_Article_Id__c = kavs[0].Id, Article_Title__c = kavs[0].Title,
            Overall_Score__c = 40, Readiness_Status__c = 'Not Ready'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id, Dimension__c = 'Completeness', Score__c = 40
        );
        insert dr;
        insert new KB_Dimension_Analysis__c(
            Article_Assessment__c = aa.Id, Dimension_Result__c = dr.Id, Type__c = 'Issue',
            Dimension__c = 'Completeness', Recommendation__c = 'Fix it', Status__c = 'Open'
        );

        Test.startTest();
        // Small offset within range so query1 finds the article and execution
        // proceeds into the run-scoped rec fetch (query2), not just the count/page queries.
        KBEnrichmentController.ImprovementInboxPage page =
            KBEnrichmentController.getImprovementsInboxPage(run.Id, 25, 0, null);
        Test.stopTest();

        Assert.areEqual(1, page.totalArticles);
        Assert.areEqual(1, page.groups.size());
        Assert.areEqual(1, page.groups[0].recommendations.size());
    }

    @IsTest
    static void getImprovementsInboxPage_StampsPendingDraftOnGroup() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'pendingstamp');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id, Knowledge__c = kavs[0].Id,
            Knowledge_Article_Id__c = kavs[0].Id, Article_Title__c = kavs[0].Title,
            Overall_Score__c = 40, Readiness_Status__c = 'Not Ready'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id, Dimension__c = 'Completeness', Score__c = 40
        );
        insert dr;
        insert new KB_Dimension_Analysis__c(
            Article_Assessment__c = aa.Id, Dimension_Result__c = dr.Id, Type__c = 'Issue',
            Dimension__c = 'Completeness', Recommendation__c = 'Fix it', Status__c = 'Open'
        );
        insert new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = kavs[0].Id,
            Source_Article_Title__c = kavs[0].Title,
            Draft_Article_Version_Id__c = 'ka0DRAFTPENDING01',
            Composite_Key__c = 'pending-stamp-' + kavs[0].Id,
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 80,
            Assessment_Run__c = run.Id
        );

        Test.startTest();
        KBEnrichmentController.ImprovementInboxPage page =
            KBEnrichmentController.getImprovementsInboxPage(null, 25, 0, null);
        Test.stopTest();

        Boolean found = false;
        for (KBEnrichmentController.ImprovementArticleGroup g : page.groups) {
            if (g.articleId == kavs[0].Id) {
                found = true;
                Assert.areEqual('ka0DRAFTPENDING01', g.pendingDraftId, 'Pending draft id stamped onto the group');
                Assert.isNotNull(g.pendingDraftUrl);
            }
        }
        Assert.isTrue(found, 'Expected the seeded article group in the page');
    }

    @IsTest
    static void getImprovementsForArticle_StampsPendingDraft() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'pendingstamp2');
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id, Knowledge__c = kavs[0].Id,
            Knowledge_Article_Id__c = String.valueOf(kavs[0].Id).left(15),
            Article_Title__c = kavs[0].Title, Overall_Score__c = 40, Readiness_Status__c = 'Not Ready'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id, Dimension__c = 'Completeness', Score__c = 40
        );
        insert dr;
        insert new KB_Dimension_Analysis__c(
            Article_Assessment__c = aa.Id, Dimension_Result__c = dr.Id, Type__c = 'Issue',
            Dimension__c = 'Completeness', Recommendation__c = 'Fix it', Status__c = 'Open'
        );
        insert new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = kavs[0].Id,
            Source_Article_Title__c = kavs[0].Title,
            Draft_Article_Version_Id__c = 'ka0DRAFTPENDING02',
            Composite_Key__c = 'pending-stamp2-' + kavs[0].Id,
            Status__c = 'Pending', Is_Closed__c = false, Confidence_Score__c = 80,
            Assessment_Run__c = run.Id
        );

        Test.startTest();
        KBEnrichmentController.ImprovementArticleGroup grp =
            KBEnrichmentController.getImprovementsForArticle(kavs[0].Id);
        Test.stopTest();

        Assert.isNotNull(grp);
        Assert.areEqual('ka0DRAFTPENDING02', grp.pendingDraftId, 'Pending draft id stamped on the single-article group');
        Assert.isNotNull(grp.pendingDraftUrl);
    }

}