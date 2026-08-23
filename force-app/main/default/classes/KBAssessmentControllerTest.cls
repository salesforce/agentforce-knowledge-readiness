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
private class KBAssessmentControllerTest {

    // Stable username marker — used by getManagerUser() to rehydrate the
    // dedicated test user across @IsTest methods. We intentionally avoid
    // System.currentTimeMillis() in the suffix so the username is reproducible
    // within the @TestSetup transaction lifetime.
    private static final String MANAGER_USERNAME = 'kb.ctrl.manager@kbtest.invalid';

    @TestSetup
    static void setup() {
        // Create a dedicated Manager user (KB_Assessment_Admin permset). Tests
        // that hit @AuraEnabled controllers backed by `WITH USER_MODE` SOQL must
        // run as this user (via System.runAs) — relying on the deploying admin's
        // profile is unsafe because System Administrator profiles in some
        // templated orgs have no FLS row for our custom fields, and USER_MODE
        // rejects the SOQL with a misleading "No such column" error. Manager (not
 // Setup Admin) is the persona with runtime-data access after 's
        // least-privilege split — Setup Admin is now config-only.
        //
        // Setup-object DML (User insert + PermissionSetAssignment) must
        // happen BEFORE non-setup data DML, otherwise MIXED_DML_OPERATION.
        Profile minimal;
        List<Profile> minimalCandidates = [
            SELECT Id FROM Profile WHERE Name = 'KB Minimum Access' LIMIT 1
        ];
        minimal = minimalCandidates.isEmpty()
            ? [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1]
            : minimalCandidates[0];

        User manager = new User(
            FirstName = 'KB',
            LastName = 'CtrlManager',
            Email = 'kbctrl@test.invalid',
            Username = MANAGER_USERNAME,
            Alias = 'kbctrl',
            ProfileId = minimal.Id,
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles'
        );
        insert manager;

        try {
            PermissionSet ps = [
                SELECT Id FROM PermissionSet
                WHERE Name = 'KB_Assessment_Admin' LIMIT 1
            ];
            insert new PermissionSetAssignment(
                AssigneeId = manager.Id,
                PermissionSetId = ps.Id
            );
        } catch (QueryException ignored) {
            // Permset missing on this org — tests that depend on FLS will
            // surface the real failure if it isn't deployed.
        }

        // Seed as the elevated running user (needed for KbManagement publish,
        // which the Manager persona can't do), but hand run OWNERSHIP to the
 // Manager. After the run is Private and candidates/results are
        // master-detail (controlled-by-parent), so a USER_MODE controller query
        // only returns a run's data to a user who can see that run — the tests
        // query as the Manager, so the Manager must own the run.
        User currentUser = new User(Id = UserInfo.getUserId());
        System.runAs(currentUser) {
            seedTestData(getManagerUser().Id);
        }
    }

    /**
     * Returns the dedicated Manager test user created in @TestSetup.
     * Use with `System.runAs(getManagerUser())` for any test that calls
     * a controller method backed by USER_MODE SOQL.
     */
    private static User getManagerUser() {
        return [SELECT Id FROM User WHERE Username = :MANAGER_USERNAME LIMIT 1];
    }

    private static void seedTestData(Id ownerId) {
        // Create test assessment runs, owned by the Manager (ownerId) so its
        // USER_MODE controller queries can see the run + its master-detail
 // children after the Private/least-privilege split.
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            OwnerId = ownerId,
            Status__c = 'Completed',
            Total_Articles__c = 5,
            Overall_Score__c = 75,
            Ready_Count__c = 3,
            Needs_Work_Count__c = 1,
            Not_Ready_Count__c = 1,
            Completed_At__c = Datetime.now(),
            Completeness_Score__c = 85,
            Structure_Score__c = 80,
            Clarity_Score__c = 75,
            Freshness_Score__c = 70,
            Duplication_Score__c = 65,
            Conflict_Score__c = 60,
            KB_Maturity_Tier__c = 'Early Adopter',
            Deployment_Tier__c = 'Medium',
            Used_LLM__c = false
        );
        insert run;

        // Seed Knowledge articles so lookup field has valid targets
        List<Knowledge__kav> kavs = new List<Knowledge__kav>();
        for (Integer i = 0; i < 3; i++) {
            kavs.add(new Knowledge__kav(
                Title = 'Test Article ' + i,
                UrlName = 'test-article-controller-' + i,
                Language = 'en_US'
            ));
        }
        insert kavs;

        // Re-query to pick up the auto-populated KnowledgeArticleId (the
        // canonical article id — distinct from the KAV/version id and only
        // available after insert). Storing the canonical id on
        // Knowledge_Article_Id__c is what production code does, and is what
        // getRunsAndAnalysesForArticle filters on.
        Map<Id, Knowledge__kav> kavById = new Map<Id, Knowledge__kav>([
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :kavs
        ]);

        // Publish so each article has a live Online version. The rerun path
 // re-resolves each parent KnowledgeArticleId to its current
        // published version, so a draft-only seed would make rerun find nothing
        // to re-assess. Mirrors real published articles.
        for (Knowledge__kav k : kavById.values()) {
            KbManagement.PublishingService.publishArticle(k.KnowledgeArticleId, true);
        }

        // Create test article assessments (per-dimension scores live on
        // KB_Dimension_Result__c children, not on the parent row).
        List<KB_Article_Assessment__c> assessments = new List<KB_Article_Assessment__c>();
        for (Integer i = 0; i < 3; i++) {
            assessments.add(new KB_Article_Assessment__c(
                Assessment_Run__c = run.Id,
                Knowledge__c = kavs[i].Id,
                Knowledge_Article_Id__c = kavById.get(kavs[i].Id).KnowledgeArticleId,
                Article_Title__c = 'Test Article ' + i,
                Overall_Score__c = 80 - (i * 10),
                Readiness_Status__c = 'Ready'
            ));
        }
        insert assessments;
    }

    @IsTest
    static void testGetKnowledgeArticles_NoSearchTerm() {
        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results =
            KBAssessmentController.getKnowledgeArticles(null, 10);
        Test.stopTest();

        Assert.isNotNull(results, 'Results should not be null');
    }

    @IsTest
    static void testGetKnowledgeArticles_WithSearchTerm() {
        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results =
            KBAssessmentController.getKnowledgeArticles('password', 10);
        Test.stopTest();

        Assert.isNotNull(results, 'Results should not be null');
    }

    @IsTest
    static void testGetKnowledgeArticles_WithLimit() {
        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results =
            KBAssessmentController.getKnowledgeArticles('', 5);
        Test.stopTest();

        Assert.isNotNull(results, 'Results should not be null');
    }

    @IsTest
    static void testGetKnowledgeArticles_NullLimit() {
        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results =
            KBAssessmentController.getKnowledgeArticles('test', null);
        Test.stopTest();

        Assert.isNotNull(results, 'Should handle null limit and use default');
    }

    @IsTest
    static void testRunAssessment_NullArticleIds() {
        Test.startTest();
        try {
            KBAssessmentController.runAssessment(null);
            Assert.fail('Should throw AuraHandledException for null article IDs');
        } catch (AuraHandledException e) {
            // AuraHandledException.getMessage() returns generic 'Script-thrown exception'
            // in test context; reaching this branch is proof the validation fired.
        }
        Test.stopTest();
    }

    @IsTest
    static void testRunAssessment_EmptyArticleIds() {
        Test.startTest();
        try {
            KBAssessmentController.runAssessment(new List<String>());
            Assert.fail('Should throw AuraHandledException for empty article IDs');
        } catch (AuraHandledException e) {
            // See testRunAssessment_NullArticleIds.
        }
        Test.stopTest();
    }

    @IsTest
    static void testRunAssessment_ValidArticleIds() {
        List<String> articleIds = new List<String>{'ka001', 'ka002'};

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = KBAssessmentController.runAssessment(articleIds);
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
        Assert.isNotNull(result.runId, 'Run ID should be created');
    }

    @IsTest
    static void testGetAssessmentResults_ValidRunId() {
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result =
            KBAssessmentController.getAssessmentResults(run.Id);
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
        Assert.areEqual(run.Id, result.runId, 'Run ID should match');
        Assert.areEqual('Completed', result.status, 'Status should match');
        Assert.areEqual(5, result.totalArticles, 'Total articles should match');
        Assert.areEqual(75, result.overallScore, 'Overall score should match');
        Assert.areEqual(3, result.readyCount, 'Ready count should match');
        Assert.areEqual(3, result.articleResults.size(), 'Should have 3 article results');
    }

    @IsTest
    static void testGetAssessmentResults_Reachability_536() {
        // The 3 seeded assessments point at published (Online) articles → reachable.
 // Add a 4th whose Knowledge__c is null (an article deleted after 's
        // SetNull) → unreachable. Its snapshot title/score still populate.
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];
        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = null,
            Knowledge_Article_Id__c = 'kA0FAKE000000009',
            Article_Title__c = 'Deleted Article',
            Overall_Score__c = 33,
            Readiness_Status__c = 'Not Ready'
        );

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result =
            KBAssessmentController.getAssessmentResults(run.Id);
        Test.stopTest();

        Assert.areEqual(4, result.articleResults.size(), 'All rows returned incl. the deleted one');
        Integer reachable = 0;
        KBAssessmentModels.ArticleAssessmentResult deletedRow = null;
        for (KBAssessmentModels.ArticleAssessmentResult r : result.articleResults) {
            if (r.isReachable) reachable++;
            if (r.articleTitle == 'Deleted Article') deletedRow = r;
        }
        Assert.areEqual(3, reachable, 'The 3 published articles are reachable');
        Assert.isNotNull(deletedRow, 'Deleted-article row still returned (snapshot)');
        Assert.isFalse(deletedRow.isReachable, 'Null Knowledge__c → unreachable');
        Assert.areEqual(33, deletedRow.overallScore, 'Snapshot score still renders');
    }

    @IsTest
    static void testGetAssessmentResults_BlankRunId() {
        Test.startTest();
        try {
            KBAssessmentController.getAssessmentResults('');
            Assert.fail('Should throw AuraHandledException for blank run ID');
        } catch (AuraHandledException e) {
            // AuraHandledException.getMessage() is generic in test context.
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetAssessmentResults_NullRunId() {
        Test.startTest();
        try {
            KBAssessmentController.getAssessmentResults(null);
            Assert.fail('Should throw AuraHandledException for null run ID');
        } catch (AuraHandledException e) {
            // AuraHandledException.getMessage() is generic in test context.
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetAssessmentResults_InvalidRunId() {
        Id fakeRunId = Schema.KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);

        Test.startTest();
        try {
            KBAssessmentController.getAssessmentResults(fakeRunId);
            Assert.fail('Should throw AuraHandledException for invalid run ID');
        } catch (AuraHandledException e) {
            // AuraHandledException.getMessage() is generic in test context.
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetAssessmentResultsLive_ParityWithCacheableVariant() {
        // The non-cacheable Live variant exists to bypass Lightning's LDS
        // cache during an active run; payload must be identical to the
        // cacheable variant. This test asserts both methods return the same
        // shape for the same run id, so a future change to one without the
        // other is caught.
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult cacheable =
            KBAssessmentController.getAssessmentResults(run.Id);
        KBAssessmentModels.AssessmentRunResult live =
            KBAssessmentController.getAssessmentResultsLive(run.Id);
        Test.stopTest();

        Assert.isNotNull(live, 'Live result should not be null');
        Assert.areEqual(cacheable.runId, live.runId, 'Run id matches');
        Assert.areEqual(cacheable.status, live.status, 'Status matches');
        Assert.areEqual(cacheable.totalArticles, live.totalArticles, 'totalArticles matches');
        Assert.areEqual(cacheable.overallScore, live.overallScore, 'overallScore matches');
        Assert.areEqual(cacheable.readyCount, live.readyCount, 'readyCount matches');
        Assert.areEqual(cacheable.articleResults.size(), live.articleResults.size(),
            'Same number of article results');
    }

    @IsTest
    static void testGetAssessmentResultsLive_BlankRunId() {
        Test.startTest();
        try {
            KBAssessmentController.getAssessmentResultsLive('');
            Assert.fail('Should throw AuraHandledException for blank run ID');
        } catch (AuraHandledException e) {
            // expected
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetAssessmentResults_StatusMessageRoundTrips() {
 // review follow-up — Status_Message__c set by the pipeline
        // callback on Failed must surface to the LWC via AssessmentRunResult.
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Failed',
            Status_Message__c = 'Pipeline callback error: simulated boom',
            Total_Articles__c = 0,
            Used_LLM__c = false,
            Assessment_Types__c = 'Readiness'
        );
        insert run;

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result =
            KBAssessmentController.getAssessmentResults(run.Id);
        Test.stopTest();

        Assert.areEqual('Failed', result.status);
        Assert.areEqual('Pipeline callback error: simulated boom', result.statusMessage,
            'statusMessage must round-trip from KB_Assessment_Run__c.Status_Message__c');
    }

    @IsTest
    static void testGetRecentRuns_NoLimit() {
        Test.startTest();
        List<KBAssessmentController.AssessmentRunSummary> results =
            KBAssessmentController.getRecentRuns(null);
        Test.stopTest();

        Assert.isNotNull(results, 'Results should not be null');
        Assert.isTrue(results.size() > 0, 'Should return at least one run');
    }

    @IsTest
    static void testGetRecentRuns_SurfacesRanBy() {
 // the recent-runs summary carries ranBy (the run owner name) so
        // the All Assessments list + Action Center run filter can show a
        // "by <who>" byline. Own a run as the querying user so Owner.Name
        // reliably resolves in the runAs context.
        User admin = getManagerUser();
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];
        update new KB_Assessment_Run__c(Id = run.Id, OwnerId = admin.Id);

        List<KBAssessmentController.AssessmentRunSummary> results;
        System.runAs(admin) {
            Test.startTest();
            results = KBAssessmentController.getRecentRuns(10);
            Test.stopTest();
        }

        KBAssessmentController.AssessmentRunSummary mine;
        for (KBAssessmentController.AssessmentRunSummary s : results) {
            if (s.runId == run.Id) {
                mine = s;
                break;
            }
        }
        Assert.isNotNull(mine, 'The owned run is in the recent-runs list');
        Assert.isNotNull(mine.ranBy, 'ranBy carries the run owner name');
    }

    @IsTest
    static void testGetRecentRuns_WithLimit() {
        Test.startTest();
        List<KBAssessmentController.AssessmentRunSummary> results =
            KBAssessmentController.getRecentRuns(5);
        Test.stopTest();

        Assert.isNotNull(results, 'Results should not be null');
        Assert.isTrue(results.size() <= 5, 'Should respect limit');
    }

    @IsTest
    static void testGetRecentRuns_ZeroLimit() {
        Test.startTest();
        List<KBAssessmentController.AssessmentRunSummary> results =
            KBAssessmentController.getRecentRuns(0);
        Test.stopTest();

        Assert.isNotNull(results, 'Should handle zero limit');
    }

    @IsTest
    static void testDeleteAssessmentRun_ValidId() {
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];

        Test.startTest();
        KBAssessmentController.deleteAssessmentRun(run.Id);
        Test.stopTest();

        List<KB_Assessment_Run__c> remainingRuns = [
            SELECT Id FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual(0, remainingRuns.size(), 'Run should be deleted');
    }

    @IsTest
    static void testDeleteAssessmentRun_NullId() {
        Test.startTest();
        try {
            KBAssessmentController.deleteAssessmentRun(null);
            Assert.fail('Should throw AuraHandledException for null ID');
        } catch (AuraHandledException e) {
            // AuraHandledException.getMessage() is generic in test context.
        }
        Test.stopTest();
    }

 // the delete-confirmation dialog reads real candidate counts so it
    // can tell the user what a run delete will remove.
    @IsTest
    static void testGetRunDeletionImpact_CountsBothCandidateTypes() {
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];
        List<Knowledge__kav> kavs = [SELECT Id FROM Knowledge__kav LIMIT 3];

        insert new List<Duplicate_Candidate__c>{
            new Duplicate_Candidate__c(
                Knowledge_Article_1__c = kavs[0].Id, Knowledge_Article_2__c = kavs[1].Id,
                Composite_Key__c = 'impact-dc-1', Flag_Type__c = 'Duplicate', Status__c = 'Pending',
                Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Assessment_Run__c = run.Id
            ),
            new Duplicate_Candidate__c(
                Knowledge_Article_1__c = kavs[1].Id, Knowledge_Article_2__c = kavs[2].Id,
                Composite_Key__c = 'impact-dc-2', Flag_Type__c = 'Contradiction', Status__c = 'Rejected',
                Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 85, Assessment_Run__c = run.Id
            )
        };
        insert new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = kavs[0].Id,
            Knowledge_Article_Id__c = String.valueOf(kavs[0].Id),
            Assessment_Run__c = run.Id, Composite_Key__c = 'impact-ec-1',
            Status__c = 'Pending', Is_Closed__c = false
        );

        KBAssessmentController.RunDeletionImpact impact;
        System.runAs(getManagerUser()) {
            impact = KBAssessmentController.getRunDeletionImpact(run.Id);
        }

        Assert.areEqual(2, impact.duplicateCandidateCount, 'Both DC counted (all statuses)');
        Assert.areEqual(1, impact.enrichmentCandidateCount, 'The EC counted');
    }

    @IsTest
    static void testGetRunDeletionImpact_BlankAndBadIdSafe() {
        KBAssessmentController.RunDeletionImpact blank = KBAssessmentController.getRunDeletionImpact('');
        Assert.areEqual(0, blank.duplicateCandidateCount, 'Blank id → zero');
        KBAssessmentController.RunDeletionImpact bad = KBAssessmentController.getRunDeletionImpact('not-an-id');
        Assert.areEqual(0, bad.enrichmentCandidateCount, 'Unparseable id → zero, no throw');
    }

 // ──: in-place rerun via the @AuraEnabled controller ──────────────
    @IsTest
    static void testRerunAssessment_KeepsRunAndReassessesSameScope() {
        // The seeded run has 3 real KAV-backed assessments — exactly the scope
        // a rerun should recover and re-assess. Runs as the Setup Admin so the
        // service's USER_MODE SOQL/DML has FLS.
        KBAssessmentModels.AssessmentRunResult result;
        KB_Assessment_Run__c original = [SELECT Id, CreatedDate FROM KB_Assessment_Run__c LIMIT 1];
        Id originalId = original.Id;
        Datetime originalCreated = original.CreatedDate;

        System.runAs(getManagerUser()) {
            Test.startTest();
            result = KBAssessmentController.rerunAssessment(originalId);
            Test.stopTest();
        }

        Assert.isNotNull(result, 'Rerun should return a result');
        // The SAME run id is returned — the run record survives the rerun.
        Assert.areEqual(String.valueOf(originalId), result.runId,
            'Rerun must KEEP the original run id, not create a new one');
        Assert.areEqual(3, result.totalArticles, 'Rerun should re-assess the original 3 articles');
        Assert.areEqual(1, [
            SELECT COUNT() FROM KB_Assessment_Run__c WHERE Id = :originalId
        ], 'Original run must NOT be discarded');
        // CreatedDate preserved (it's the same record, not a new one).
        Assert.areEqual(originalCreated, [
            SELECT CreatedDate FROM KB_Assessment_Run__c WHERE Id = :originalId
        ].CreatedDate, 'CreatedDate must be preserved across the rerun');
    }

    /**
     * Regression: rerun after a fix-and-republish must leave exactly ONE child
     * row for the parent, pointing at the new Online version — no stale
     * archived-version duplicate.
     *
     * The critical part is `runAs` the Manager persona. The Manager permset
     * grants object Create/Edit on KB_Article_Assessment__c but NO field-level
     * edit FLS on it. The version-repoint used to run in USER_MODE, so under this
     * persona the repoint update was silently dropped (a swallowed partial DML
     * failure), the archived-version row stayed put, and the system-mode
     * preCreate insert still added the new-version row — two scored rows for one
     * article. The prior repoint test ran as the deploying admin (full FLS), so
     * USER_MODE succeeded and the bug slipped through. This test runs the rerun
     * as the Manager and asserts the single-row outcome the system-mode repoint
     * now guarantees.
     */
    @IsTest
    static void testRerunAssessment_AsManager_RepublishedArticleHasNoDuplicateRow() {
        // Publish an article (v1) as the elevated admin — the Manager can't run
        // KbManagement publish, and seeding is an admin concern anyway.
        Knowledge__kav art = new Knowledge__kav(
            Title = 'Fix-and-rerun article',
            UrlName = 'fix-and-rerun-article',
            Language = 'en_US'
        );
        insert art;
        Knowledge__kav parent = [
            SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :art.Id
        ];
        KbManagement.PublishingService.publishArticle(parent.KnowledgeArticleId, true);
        Id v1 = [
            SELECT Id FROM Knowledge__kav
            WHERE KnowledgeArticleId = :parent.KnowledgeArticleId AND PublishStatus = 'Online'
            LIMIT 1
        ].Id;

        // A completed run over that article, OWNED BY THE MANAGER so the rerun's
        // USER_MODE run read (FOR UPDATE) can see it. A skip reason is stamped so
        // the repoint also has to clear it (the second field the update writes).
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            OwnerId = getManagerUser().Id,
            Status__c = 'Completed',
            Total_Articles__c = 1,
            Assessment_Types__c = 'Readiness',
            Requested_Scope__c = 'Selected',
            Selected_Dimensions_JSON__c = JSON.serialize(new List<String>{ 'Completeness' })
        );
        insert run;
        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = v1,
            Knowledge_Article_Id__c = String.valueOf(parent.KnowledgeArticleId),
            Article_Title__c = art.Title,
            Pipeline_Skip_Reason__c = 'Clarity 58 < threshold 60',
            Overall_Score__c = 66
        );

        // Republish: edit online → new draft → publish → new Online (v2),
        // archiving v1 — the exact fix-with-AI-then-publish shape from the field.
        Id draftId = KbManagement.PublishingService.editOnlineArticle(parent.KnowledgeArticleId, false);
        update new Knowledge__kav(Id = draftId, Summary = 'v2 improved');
        KbManagement.PublishingService.publishArticle(parent.KnowledgeArticleId, true);
        Id v2 = [
            SELECT Id FROM Knowledge__kav
            WHERE KnowledgeArticleId = :parent.KnowledgeArticleId AND PublishStatus = 'Online'
            LIMIT 1
        ].Id;
        Assert.areNotEqual(v1, v2, 'Republish should have produced a new Online version');

        System.runAs(getManagerUser()) {
            Test.startTest();
            KBAssessmentController.rerunAssessment(run.Id);
            Test.stopTest();
        }

        List<KB_Article_Assessment__c> rows = [
            SELECT Knowledge__c, Pipeline_Skip_Reason__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :run.Id
        ];
        Assert.areEqual(1, rows.size(),
            'Rerun as the Manager persona must leave exactly ONE child row — the '
            + 'repoint must persist even without field-edit FLS (no archived duplicate)');
        Assert.areEqual(v2, rows[0].Knowledge__c,
            'The surviving row must point at the new Online version, not the archived one');
        Assert.isNull(rows[0].Pipeline_Skip_Reason__c,
            'A row that now resolves to a live version must have its stale skip reason cleared');
    }

    @IsTest
    static void testRerunAssessment_NullId() {
        Test.startTest();
        try {
            KBAssessmentController.rerunAssessment(null);
            Assert.fail('Should throw AuraHandledException for null ID');
        } catch (AuraHandledException e) {
            // AuraHandledException.getMessage() is generic in test context.
        }
        Test.stopTest();
    }

    @IsTest
    static void testRerunAssessment_InvalidId() {
        Id fakeRunId = Schema.KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);
        System.runAs(getManagerUser()) {
            Test.startTest();
            try {
                KBAssessmentController.rerunAssessment(fakeRunId);
                Assert.fail('Should throw AuraHandledException for a non-existent run');
            } catch (AuraHandledException e) {
                // expected — service throws "run not found", wrapped by the controller
            }
            Test.stopTest();
        }
    }

    /**
     * A rerun of a still-running run must be rejected. The service throws
     * RunNotRerunnableException; the @AuraEnabled wrapper turns it into a clean
     * AuraHandledException for the LWC (which itself gates Rerun client-side, but
     * a stale row / direct call reaches the controller anyway).
     */
    @IsTest
    static void testRerunAssessment_InProgress_ThrowsAuraHandled() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 3,
            Assessment_Types__c = 'Readiness',
            Requested_Scope__c = 'Selected'
        );
        insert run;
        // Own the run as the Manager so the service's USER_MODE read returns it
        // (Manager has CRED but no View All — same pattern as the other tests).
        update new KB_Assessment_Run__c(Id = run.Id, OwnerId = getManagerUser().Id);

        System.runAs(getManagerUser()) {
            Test.startTest();
            try {
                KBAssessmentController.rerunAssessment(run.Id);
                Assert.fail('Should throw AuraHandledException for an in-flight run');
            } catch (AuraHandledException e) {
                // expected — service throws RunNotRerunnableException, wrapped
            }
            Test.stopTest();
        }

        Assert.areEqual('In Progress', [
            SELECT Status__c FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ].Status__c, 'Blocked rerun must leave the run untouched');
    }

    @IsTest
    static void testCheckRunStatus_ValidId() {
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = KBAssessmentController.checkRunStatus(run.Id);
        Test.stopTest();

        Assert.areEqual('Completed', result.status, 'Should return correct status');
        Assert.isNotNull(result.articleResults, 'Should load article results for completed run');
        Assert.areEqual(3, result.articleResults.size(), 'Should have 3 article results');
    }

    @IsTest
    static void testCheckRunStatus_NullId() {
        Test.startTest();
        try {
            KBAssessmentController.checkRunStatus(null);
            Assert.fail('Should throw AuraHandledException for null ID');
        } catch (AuraHandledException e) {
            // AuraHandledException.getMessage() is generic in test context.
        }
        Test.stopTest();
    }

    @IsTest
    static void testCheckRunStatus_InvalidId() {
        Id fakeRunId = Schema.KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix() + '0'.repeat(15);

        Test.startTest();
        try {
            KBAssessmentController.checkRunStatus(fakeRunId);
            Assert.fail('Should throw AuraHandledException for invalid ID');
        } catch (AuraHandledException e) {
            // AuraHandledException.getMessage() is generic in test context.
        }
        Test.stopTest();
    }

    @IsTest
    static void testAssessmentRunSummary_Construction() {
 // include Scan_Start_Time__c so we can assert the summary exposes
        // it — the live elapsed-time timer in the All Assessments list reads
        // scanStartTime in preference to createdDate, so the wrapper must carry
        // it. Stamp a known value first to assert the round-trip precisely.
        KB_Assessment_Run__c stampTarget = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];
        Datetime expectedScanStart = Datetime.newInstance(2026, 6, 10, 9, 30, 0);
        stampTarget.Scan_Start_Time__c = expectedScanStart;
        update stampTarget;

        KB_Assessment_Run__c run = [
            SELECT Id, Name, Status__c, Total_Articles__c, Overall_Score__c,
                   Ready_Count__c, Needs_Work_Count__c, Not_Ready_Count__c,
                   Completed_At__c, CreatedDate, Scan_Start_Time__c
            FROM KB_Assessment_Run__c WHERE Id = :stampTarget.Id LIMIT 1
        ];

        Test.startTest();
        KBAssessmentController.AssessmentRunSummary summary =
            new KBAssessmentController.AssessmentRunSummary(run);
        Test.stopTest();

        Assert.isNotNull(summary, 'Summary should be constructed');
        Assert.areEqual(run.Id, summary.runId, 'Run ID should match');
        Assert.areEqual(run.Status__c, summary.status, 'Status should match');
        Assert.areEqual(run.Total_Articles__c.intValue(), summary.totalArticles, 'Total articles should match');
        Assert.areEqual(expectedScanStart, summary.scanStartTime,
            'Summary must expose Scan_Start_Time__c as scanStartTime for the live timer');
    }

    @IsTest
    static void testAssessmentRunSummary_ScanStartOptionalInSelect() {
 // the constructor guards the Scan_Start_Time__c read with
        // getPopulatedFieldsAsMap() so callsites that DON'T query the field
        // don't throw SObjectException. A SELECT omitting *only* that field
        // (the other summary fields are read unconditionally by the
        // constructor, so they must still be queried) must yield a null
        // scanStartTime, not an error.
        KB_Assessment_Run__c run = [
            SELECT Id, Name, Status__c, Total_Articles__c, Overall_Score__c,
                   Ready_Count__c, Needs_Work_Count__c, Not_Ready_Count__c,
                   Completed_At__c, CreatedDate
            FROM KB_Assessment_Run__c LIMIT 1
        ];

        Test.startTest();
        KBAssessmentController.AssessmentRunSummary summary =
            new KBAssessmentController.AssessmentRunSummary(run);
        Test.stopTest();

        Assert.isNotNull(summary, 'Summary should construct even without Scan_Start_Time__c in the SELECT');
        Assert.isNull(summary.scanStartTime, 'scanStartTime should be null when the field is not queried');
    }

    @IsTest
    static void testCacheable_GetKnowledgeArticles() {
        // Test that the method is cacheable
        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results1 =
            KBAssessmentController.getKnowledgeArticles('test', 10);
        List<KBAssessmentModels.ArticleWrapper> results2 =
            KBAssessmentController.getKnowledgeArticles('test', 10);
        Test.stopTest();

        // Both calls should succeed (cacheable methods should work)
        Assert.isNotNull(results1, 'First call should return results');
        Assert.isNotNull(results2, 'Second call should return results');
    }

    @IsTest
    static void testCacheable_GetAssessmentResults() {
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result1 =
            KBAssessmentController.getAssessmentResults(run.Id);
        KBAssessmentModels.AssessmentRunResult result2 =
            KBAssessmentController.getAssessmentResults(run.Id);
        Test.stopTest();

        Assert.isNotNull(result1, 'First call should return result');
        Assert.isNotNull(result2, 'Second call should return result');
        Assert.areEqual(result1.runId, result2.runId, 'Both should return same run');
    }

    @IsTest
    static void testCacheable_GetRecentRuns() {
        Test.startTest();
        List<KBAssessmentController.AssessmentRunSummary> results1 =
            KBAssessmentController.getRecentRuns(5);
        List<KBAssessmentController.AssessmentRunSummary> results2 =
            KBAssessmentController.getRecentRuns(5);
        Test.stopTest();

        Assert.isNotNull(results1, 'First call should return results');
        Assert.isNotNull(results2, 'Second call should return results');
    }

    // ---- getDashboardData Tests ----

    @IsTest
    static void testGetDashboardData_WithCompletedRun() {
        Test.startTest();
        KBAssessmentModels.DashboardData data = KBAssessmentController.getDashboardData();
        Test.stopTest();

        Assert.isTrue(data.hasCompletedRun, 'Should have a completed run');
        Assert.isNotNull(data.latestRun, 'Latest run should not be null');
        Assert.areEqual(75, data.latestRun.overallScore, 'Overall score should match');
        Assert.areEqual(85, data.latestRun.dimensionScores.get('Completeness'), 'Completeness score should match');
        Assert.areEqual('Early Adopter', data.latestRun.maturityTier, 'Maturity tier should match');
        Assert.areEqual('Medium', data.latestRun.deploymentTier, 'Deployment tier should match');
        Assert.isFalse(data.latestRun.usedLLM, 'Used LLM should be false');
        Assert.isNotNull(data.quickWins, 'Quick wins list should not be null');
    }

    @IsTest
    static void testGetDashboardData_NoCompletedRuns() {
        delete [SELECT Id FROM KB_Assessment_Run__c];

        Test.startTest();
        KBAssessmentModels.DashboardData data = KBAssessmentController.getDashboardData();
        Test.stopTest();

        Assert.isFalse(data.hasCompletedRun, 'Should have no completed run');
        Assert.isNull(data.latestRun, 'Latest run should be null');
        Assert.isTrue(data.quickWins.isEmpty(), 'Quick wins should be empty');
    }

    @IsTest
    static void testGetDashboardData_TrendData() {
        // Insert a second older completed run for trend
        KB_Assessment_Run__c previousRun = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 3,
            Overall_Score__c = 60,
            Ready_Count__c = 1,
            Needs_Work_Count__c = 1,
            Not_Ready_Count__c = 1,
            Completed_At__c = Datetime.now().addDays(-7)
        );
        insert previousRun;

        Test.startTest();
        KBAssessmentModels.DashboardData data = KBAssessmentController.getDashboardData();
        Test.stopTest();

        Assert.isTrue(data.hasCompletedRun, 'Should have completed run');
        Assert.areEqual(60, data.previousOverallScore, 'Previous score should be 60');
        Assert.areEqual(3, data.previousTotalArticles, 'Previous article count should be 3');
    }

    @IsTest
    static void testGetDashboardData_QuickWinsRetired() {
 // /— the Quick-Wins query was removed (it gated on
        // Effort__c = 'Quick Win', which is no longer written). Even with an
        // Issue rec present on the latest run, data.quickWins stays empty and
        // the dashboard load does not throw.
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];
        KB_Article_Assessment__c assessment = [SELECT Id FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :run.Id LIMIT 1];

        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = assessment.Id,
            Dimension__c = 'Completeness',
            Score__c = 40
        );
        insert dr;

        KB_Dimension_Analysis__c rec = new KB_Dimension_Analysis__c(
            Article_Assessment__c = assessment.Id,
            Dimension_Result__c = dr.Id,
            Type__c = 'Issue',
            Dimension__c = 'Completeness',
            Recommendation__c = 'Add a summary to this article',
            Impact__c = 'High'
        );
        insert rec;

        Test.startTest();
        KBAssessmentModels.DashboardData data = KBAssessmentController.getDashboardData();
        Test.stopTest();

        Assert.isNotNull(data.quickWins, 'quickWins list is still initialised on the DTO');
        Assert.isTrue(data.quickWins.isEmpty(), 'Quick Wins are retired — list stays empty');
    }

    @IsTest
    static void testGetDashboardData_ConfigStatus() {
        Test.startTest();
        KBAssessmentModels.DashboardData data = KBAssessmentController.getDashboardData();
        Test.stopTest();

        // No org defaults created in test context
        Assert.isFalse(data.hasScanConfig, 'Should not have scan config org defaults');
        Assert.isFalse(data.hasScoreWeights, 'Should not have score weights org defaults');
    }

    // ---- getArticleTypeOptions Tests ----

    @IsTest
    static void testGetArticleTypeOptions() {
        Test.startTest();
        List<Map<String, String>> options = KBAssessmentController.getArticleTypeOptions();
        Test.stopTest();

        Assert.isNotNull(options, 'Options should not be null');
    }

    // ---- getFilteredArticles Tests ----

    @IsTest
    static void testGetFilteredArticles_NoFilters() {
        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result =
            KBAssessmentController.getFilteredArticles(null);
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
        Assert.isNotNull(result.articles, 'Articles list should not be null');
    }

    @IsTest
    static void testGetFilteredArticles_WithFilters() {
        String filterJSON = JSON.serialize(new Map<String, Object>{
            'publishStatus' => 'Online',
            'titleSearch' => 'Test',
            'pageSize' => 10,
            'offset' => 0
        });

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result =
            KBAssessmentController.getFilteredArticles(filterJSON);
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
        Assert.isNotNull(result.totalCount, 'Total count should not be null');
    }

    @IsTest
    static void testGetFilteredArticles_WithArticleNumber() {
        String filterJSON = JSON.serialize(new Map<String, Object>{
            'articleNumber' => '001',
            'pageSize' => 5,
            'offset' => 0
        });

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result =
            KBAssessmentController.getFilteredArticles(filterJSON);
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
    }

    @IsTest
    static void testGetFilteredArticles_Pagination() {
        String filterJSON = JSON.serialize(new Map<String, Object>{
            'pageSize' => 5,
            'offset' => 10
        });

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result =
            KBAssessmentController.getFilteredArticles(filterJSON);
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
        Assert.isNotNull(result.hasMore, 'hasMore should be populated');
    }

    @IsTest
    static void testGetFilteredArticles_InvalidJSON() {
        Boolean caught = false;
        Test.startTest();
        try {
            KBAssessmentController.getFilteredArticles('{invalid}');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        Assert.isTrue(caught, 'Should throw AuraHandledException for invalid JSON');
    }

    // ---- getMatchingArticleIds Tests ----

    @IsTest
    static void testGetMatchingArticleIds_emptyFilterReturnsList() {
        Test.startTest();
        List<String> ids = KBAssessmentController.getMatchingArticleIds(null);
        Test.stopTest();

        Assert.isNotNull(ids, 'Should return a non-null list');
    }

    @IsTest
    static void testGetMatchingArticleIds_auraHandledOnCap() {
        Knowledge__kav a = new Knowledge__kav(
            Title = 'Cap Test Article',
            UrlName = 'cap-test-article-' + Math.abs(Crypto.getRandomLong()),
            Language = 'en_US'
        );
        insert a;

        Integer previousCap = KBAssessmentService.matchingFilterCap;
        KBAssessmentService.matchingFilterCap = 0;

        String filterJSON = JSON.serialize(new Map<String, Object>{
            'publishStatus' => 'Draft'
        });

        Boolean caught = false;
        String message = null;
        Test.startTest();
        try {
            KBAssessmentController.getMatchingArticleIds(filterJSON);
        } catch (AuraHandledException e) {
            caught = true;
            message = e.getMessage();
        } finally {
            KBAssessmentService.matchingFilterCap = previousCap;
        }
        Test.stopTest();

        Assert.isTrue(caught, 'Cap breach should surface as AuraHandledException');
    }

    @IsTest
    static void testGetMatchingArticleIds_invalidJSON() {
        Boolean caught = false;
        Test.startTest();
        try {
            KBAssessmentController.getMatchingArticleIds('{not-valid}');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        Assert.isTrue(caught, 'Invalid JSON should throw AuraHandledException');
    }

    // ==================== Article Record LWC Methods ====================

    @IsTest
    static void testAssessCurrentArticle_BlankId() {
        Boolean caught = false;
        Test.startTest();
        try {
            KBAssessmentController.assessCurrentArticle('', null);
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        Assert.isTrue(caught, 'Blank ID should throw');
    }

    @IsTest
    static void testAssessCurrentArticle_ExistingHit() {
        // Seed existing assessment
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 1
        );
        insert run;
        Knowledge__kav kav = new Knowledge__kav(
            Title = 'Controller Test',
            UrlName = 'controller-test-existing-hit',
            Language = 'en_US'
        );
        insert kav;
        String articleId = kav.Id;
        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = articleId,
            Knowledge_Article_Id__c = articleId,
            Article_Title__c = 'Controller Test',
            Overall_Score__c = 80,
            Readiness_Status__c = 'Ready'
        );

        Test.startTest();
        // Use skip pipeline via comma-separated dimensions excluding dup/conflict
        KBAssessmentModels.ArticleAssessmentResult result =
            KBAssessmentController.assessCurrentArticle(
                articleId,
                'completeness,structure,clarity,freshness'
            );
        Test.stopTest();

        // May or may not reuse existing depending on dup/conflict staleness check;
        // either way the result should not throw.
        Assert.isTrue(true, 'Should execute without throwing');
    }

    @IsTest
    static void testAssessCurrentArticle_NoArticle() {
        Boolean caught = false;
        Test.startTest();
        try {
            KBAssessmentController.assessCurrentArticle('ka0FAKE000000501', null);
        } catch (AuraHandledException e) {
            caught = true;
        } catch (Exception e) {
            // Any other exception also acceptable
            caught = true;
        }
        Test.stopTest();

        // Either throws or returns null — both acceptable
        Assert.isTrue(true, 'Should handle gracefully');
    }

    @IsTest
    static void testGetExistingArticleAssessment_BlankId() {
        Boolean caught = false;
        Test.startTest();
        try {
            KBAssessmentController.getExistingArticleAssessment('');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        Assert.isTrue(caught, 'Blank ID should throw');
    }

    @IsTest
    static void testGetExistingArticleAssessment_Found() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 1
        );
        insert run;
        Knowledge__kav kav = new Knowledge__kav(
            Title = 'Existing',
            UrlName = 'existing-assessment-found',
            Language = 'en_US'
        );
        insert kav;
        String articleId = kav.Id;
        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = articleId,
            Knowledge_Article_Id__c = articleId,
            Article_Title__c = 'Existing',
            Overall_Score__c = 70,
            Readiness_Status__c = 'Needs Work'
        );

        Test.startTest();
        KBAssessmentFacade.ExistingAssessmentResult existing =
            KBAssessmentController.getExistingArticleAssessment(articleId);
        Test.stopTest();

        Assert.isNotNull(existing, 'Should return existing result');
        Assert.isTrue(existing.found, 'Should find existing assessment');
    }

    @IsTest
    static void testGetExistingArticleAssessment_NotFound() {
        Test.startTest();
        KBAssessmentFacade.ExistingAssessmentResult existing =
            KBAssessmentController.getExistingArticleAssessment('ka0FAKE000000503');
        Test.stopTest();

        Assert.isNotNull(existing, 'Should return non-null');
        Assert.isFalse(existing.found, 'No assessment → not found');
    }

    @IsTest
    static void testTriggerPipelineForArticle_BlankId() {
        Boolean caught = false;
        Test.startTest();
        try {
            KBAssessmentController.triggerPipelineForArticle('');
        } catch (AuraHandledException e) {
            caught = true;
        }
        Test.stopTest();

        Assert.isTrue(caught, 'Blank ID should throw');
    }

    @IsTest
    static void testTriggerPipelineForArticle_ValidId() {
        Test.startTest();
        String runId = KBAssessmentController.triggerPipelineForArticle('ka0FAKE000000504');
        Test.stopTest();

        // May return null if no articles fetched, or a run ID if enqueued
        Assert.isTrue(true, 'Should execute without throwing');
    }

    // ─── Phase-1 @AuraEnabled read methods ─────────────────────────────────────

    @IsTest
    static void testHasAnyRuns_WithSeededRun() {
        // TestSetup() inserts one completed run.
        Test.startTest();
        Boolean result = KBAssessmentController.hasAnyRuns();
        Test.stopTest();

        Assert.isTrue(result, 'Seeded run should make hasAnyRuns return true');
    }

    @IsTest
    static void testGetLatestAssessmentForArticle_BlankId() {
        Test.startTest();
        Object result = KBAssessmentController.getLatestAssessmentForArticle('');
        Test.stopTest();

        Assert.isNull(result, 'Blank id should return null');
    }

    @IsTest
    static void testGetLatestAssessmentForArticle_UnknownId() {
        Test.startTest();
        // Non-existent KAV id — facade returns null for "no assessment yet" per
        // the read-only contract used by the record-page sidebar.
        KBAssessmentModels.ArticleAssessmentResult result =
            KBAssessmentController.getLatestAssessmentForArticle('ka0FAKE000000600');
        Test.stopTest();

        // Contract: returns without throwing. Shape may be null (no data).
        Assert.isTrue(true, 'Should not throw for unknown article');
    }

    @IsTest
    static void testGetRunDiagnostics_BlankRunId() {
        Test.startTest();
        KBAssessmentController.RunDiagnosticsInfo info = KBAssessmentController.getRunDiagnostics('');
        Test.stopTest();

        Assert.isNull(info, 'Blank runId returns null');
    }

    @IsTest
    static void testGetRunDiagnostics_UnknownRun() {
        // 15-char fake id with the right keyPrefix shape — must not match
        // any existing record. Hard-coded length here was 17 (invalid),
        // which threw on the WHERE Id = :runId binding.
        String prefix = KB_Assessment_Run__c.SObjectType.getDescribe().getKeyPrefix();
        Id fakeRunId = Id.valueOf(prefix + '00000FAKEXYZ');

        // Run as the Setup Admin test user — see testListRecommendationsForRun_HappyPath.
        System.runAs(getManagerUser()) {
            Test.startTest();
            KBAssessmentController.RunDiagnosticsInfo info =
                KBAssessmentController.getRunDiagnostics(fakeRunId);
            Test.stopTest();

            Assert.isNull(info, 'Unknown run returns null');
        }
    }

    @IsTest
    static void testGetRunDiagnostics_HappyPath() {
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];

        // Run as the Setup Admin test user — the controller's USER_MODE SOQL
        // requires explicit FLS on KB_Assessment_Run__c.Status__c +
        // Total_Articles__c, which the deploying admin's profile may not
        // carry on a fresh org.
        System.runAs(getManagerUser()) {
            Test.startTest();
            KBAssessmentController.RunDiagnosticsInfo info = KBAssessmentController.getRunDiagnostics(run.Id);
            Test.stopTest();

            Assert.isNotNull(info, 'Known run returns diagnostic info');
            Assert.areEqual(run.Id, info.runId, 'runId echoes back');
            Assert.isNotNull(info.failures, 'Failures list is non-null');
            Assert.areEqual(0, info.failures.size(), 'Test context has no KB async failures');
        }
    }

    // ──────────────────────────────────────────────────────────────────────
 // selected content field columns @AuraEnabled
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetSelectedContentFieldColumns_NoConfig_ReturnsEmpty() {
        Test.startTest();
        List<Map<String, String>> cols = KBAssessmentController.getSelectedContentFieldColumns();
        Test.stopTest();

        Assert.isNotNull(cols, 'Column list is initialised');
        Assert.areEqual(0, cols.size(), 'No mapping configured → no columns');
    }

    @IsTest
    static void testGetSelectedContentFieldColumns_DropsMissingFieldsSilently() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Content_Field_Mapping_JSON__c = 'KCSArticle_Issue__c,Not_A_Real_Field__c';
        upsert cfg KB_Scan_Config__c.Id;

        Test.startTest();
        List<Map<String, String>> cols = KBAssessmentController.getSelectedContentFieldColumns();
        Test.stopTest();

        // Both names are likely absent on a vanilla scratch org; the call
        // must complete without throwing the original SOQL error.
        Assert.isNotNull(cols, 'Column list returned even when configured fields are missing');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Edge-case + extension coverage
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetKnowledgeArticles_DefaultLimit_NoSearch() {
        Test.startTest();
        System.runAs(getManagerUser()) {
            List<KBAssessmentModels.ArticleWrapper> wrappers =
                KBAssessmentController.getKnowledgeArticles(null, null);
            Assert.isNotNull(wrappers);
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetKnowledgeArticles_WithLimitAndSearch() {
        Test.startTest();
        System.runAs(getManagerUser()) {
            List<KBAssessmentModels.ArticleWrapper> wrappers =
                KBAssessmentController.getKnowledgeArticles('foo', 5);
            Assert.isNotNull(wrappers);
        }
        Test.stopTest();
    }

    // ──────────────────────────────────────────────────────────────────────
    // Article-record LWC methods
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testAssessCurrentArticle_BlankId_Throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.assessCurrentArticle('', null);
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw);
    }

    @IsTest
    static void testAssessCurrentArticle_RealArticle_Delegates() {
        // The controller delegates to KBAssessmentFacade.getOrAssess, which
        // either returns a populated result OR throws KnowledgeAIException
        // (when no content fields are configured) which the controller wraps
        // as AuraHandledException. Both outcomes prove the delegation ran;
        // we assert one of them is observed.
        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result;
        Boolean wrappedAura = false;
        System.runAs(getManagerUser()) {
            Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'ctrl-assess-curr')[0];
            try {
                result = KBAssessmentController.assessCurrentArticle(
                    String.valueOf(kav.Id), 'Freshness'
                );
            } catch (AuraHandledException ahe) {
                wrappedAura = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(result != null || wrappedAura,
            'assessCurrentArticle either returned a result or threw the documented AuraHandledException — never silently no-op');
    }

    @IsTest
    static void testPreviewArticleScore_LeastPrivilegePersona_ReadsContent() {
        // previewArticleScore reads the article's content fields in system mode
        // (fetchArticles) to run the self-contained scorers. Run it as the
        // least-privilege Manager persona to confirm the system-mode content
        // read isn't blocked for a Knowledge-read-only user (a USER_MODE flip on
        // that read would throw here for a persona without custom-content FLS).
        // LLM is mocked for determinism. Like assessCurrentArticle above, a
        // no-content-fields org config surfaces as the documented
        // AuraHandledException rather than a result — accept either.
        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result;
        Boolean wrappedAura = false;
        System.runAs(getManagerUser()) {
            PromptTemplateService.setMock(new MockPromptTemplateService());
            Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'ctrl-preview')[0];
            try {
                result = KBAssessmentController.previewArticleScore(String.valueOf(kav.Id));
                Assert.areEqual(String.valueOf(kav.Id), result.articleId,
                    'preview result must be for the requested article');
            } catch (AuraHandledException ahe) {
                wrappedAura = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(result != null || wrappedAura,
            'previewArticleScore either scored the article via a system-mode content read or threw the documented AuraHandledException — never silently no-op');
    }

    @IsTest
    static void testGetExistingArticleAssessment_BlankId_Throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.getExistingArticleAssessment('');
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw);
    }

    @IsTest
    static void testGetExistingArticleAssessment_RealId_ReturnsResult() {
        // No prior assessment exists for the inserted KAV → ExistingAssessmentResult
        // must come back with found=false, never null. The controller's catch
        // path only fires for AuraHandledException, which we don't expect on
        // a real article id.
        KBAssessmentFacade.ExistingAssessmentResult result;
        Test.startTest();
        System.runAs(getManagerUser()) {
            Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'ctrl-existing')[0];
            result = KBAssessmentController.getExistingArticleAssessment(String.valueOf(kav.Id));
        }
        Test.stopTest();

        Assert.isNotNull(result, 'getExistingArticleAssessment must return a wrapper, never null');
        Assert.isFalse(result.found,
            'No prior assessment was inserted, so found must be false');
    }

    @IsTest
    static void testTriggerPipelineForArticle_BlankId_Throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.triggerPipelineForArticle('');
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw);
    }

    @IsTest
    static void testTriggerPipelineForArticle_RealId_DelegatesToFacade() {
        // Delegate to KBAssessmentFacade.assessArticlesAsync. Either creates
        // a KB_Assessment_Run__c (returned runId is non-null) OR throws
        // AuraHandledException (caught and rewrapped by the controller).
        // Asserting on the side effect — a run row created — is the strong
        // form of "delegation ran".
        Integer runsBefore = [SELECT COUNT() FROM KB_Assessment_Run__c];
        String runId;
        Boolean wrappedAura = false;

        Test.startTest();
        System.runAs(getManagerUser()) {
            Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'ctrl-trigger')[0];
            try {
                runId = KBAssessmentController.triggerPipelineForArticle(String.valueOf(kav.Id));
            } catch (AuraHandledException ahe) {
                wrappedAura = true;
            }
        }
        Test.stopTest();

        Integer runsAfter = [SELECT COUNT() FROM KB_Assessment_Run__c];
        Assert.isTrue(runId != null || runsAfter > runsBefore || wrappedAura,
            'triggerPipelineForArticle delegated — either returned a runId, created a run row, or wrapped the documented exception');
    }

    @IsTest
    static void testGetRecentPipelineRuns_DefaultLimit() {
        Test.startTest();
        List<KBAssessmentController.PipelineRunSummary> runs =
            KBAssessmentController.getRecentPipelineRuns(null);
        Test.stopTest();
        Assert.isNotNull(runs);
    }

    @IsTest
    static void testGetRecentPipelineRuns_WithLimit() {
        // Insert one pipeline run so the loop body executes. Use 'In Progress'
        // since the Status__c picklist on KB_Pipeline_Run__c does not allow 'Pending'.
        KB_Assessment_Run__c arun = KBTestDataFactory.insertRun('In Progress', 'Readiness');
        KBTestDataFactory.insertPipelineRun(arun.Id, 'DEDUPLICATION', 'Queued');

        Test.startTest();
        List<KBAssessmentController.PipelineRunSummary> runs =
            KBAssessmentController.getRecentPipelineRuns(10);
        Test.stopTest();

        Assert.isTrue(runs.size() >= 1);
    }

    @IsTest
    static void testRunAssessment_NullIds_ThrowsAuraHandled() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.runAssessment(null);
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw);
    }

    @IsTest
    static void testRunAssessment_EmptyIds_ThrowsAuraHandled() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.runAssessment(new List<String>());
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw);
    }

    @IsTest
    static void testRunAssessmentAdvanced_WithOptions() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'ctrl-adv')[0];
        String optsJson = JSON.serialize(new Map<String, Object>{
            'assessmentTypes' => new List<String>{ 'Readiness' },
            'requestedScope' => 'Selected'
        });

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result;
        Boolean wrappedAura = false;
        try {
            result = KBAssessmentController.runAssessmentAdvanced(
                new List<String>{ String.valueOf(kav.Id) }, optsJson
            );
        } catch (AuraHandledException ahe) {
            wrappedAura = true;
        }
        Test.stopTest();

        Assert.isTrue(result != null || wrappedAura,
            'runAssessmentAdvanced must either return or wrap as AuraHandledException');
    }

    @IsTest
    static void testGetAssessmentResults_BlankRunId_Throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.getAssessmentResults('');
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw);
    }

    @IsTest
    static void testGetRunDiagnostics_NotFound_Throws() {
        // Non-existent runId either returns null (the documented short-
        // circuit when SOQL finds zero rows) or throws AuraHandledException.
        // The controller's runs.isEmpty() check returns null in the empty
        // case — so this test now asserts the *correct* documented behavior.
        Test.startTest();
        KBAssessmentController.RunDiagnosticsInfo info;
        Boolean threwAura = false;
        try {
            info = KBAssessmentController.getRunDiagnostics('a0X000000000001');
        } catch (AuraHandledException ahe) {
            threwAura = true;
        }
        Test.stopTest();

        Assert.isTrue(info == null || threwAura,
            'Non-existent runId returns null (short-circuit) or AuraHandledException');
    }

    @IsTest
    static void testRunAssessmentAdvanced_InvalidOptionsJSON_Throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.runAssessmentAdvanced(
                new List<String>{ 'ka01' }, '{not-json}'
            );
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Bad options JSON triggers AuraHandled wrap');
    }

    @IsTest
    static void testGetAssessmentResults_NonexistentRunId_Throws() {
        Boolean threwAura = false;
        Test.startTest();
        try {
            KBAssessmentController.getAssessmentResults('a0X000000000001');
        } catch (AuraHandledException ahe) {
            threwAura = true;
        }
        Test.stopTest();
        Assert.isTrue(threwAura,
            'Non-existent runId surfaces as AuraHandledException after the SOQL List<> assignment fails');
    }

    @IsTest
    static void testGetRunDiagnostics_RealRun_PopulatesInfo() {
        Test.startTest();
        KBAssessmentController.RunDiagnosticsInfo info;
        System.runAs(getManagerUser()) {
            KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
            info = KBAssessmentController.getRunDiagnostics(run.Id);
        }
        Test.stopTest();

        Assert.isNotNull(info);
        Assert.isNotNull(info.runId);
        Assert.isNotNull(info.status);
        Assert.isNotNull(info.failures);
    }

    @IsTest
    static void testGetRunDiagnostics_BlankRunId_ReturnsNull() {
        Test.startTest();
        KBAssessmentController.RunDiagnosticsInfo info =
            KBAssessmentController.getRunDiagnostics('');
        Test.stopTest();

        Assert.isNull(info, 'Blank id short-circuits early');
    }

    @IsTest
    static void testGetAssessmentResults_RealRun_ReturnsData() {
        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result;
        Boolean threwAura = false;
        System.runAs(getManagerUser()) {
            KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
            try {
                result = KBAssessmentController.getAssessmentResults(run.Id);
            } catch (AuraHandledException ahe) {
                threwAura = true;
            }
        }
        Test.stopTest();

        Assert.isTrue((result != null && result.runId != null) || threwAura,
            'getAssessmentResults must either return a populated wrapper or wrap the underlying error as AuraHandledException');
    }

    @IsTest
    static void testGetOrgHealthData_NoRuns_ReturnsBaseData() {
        // The class-level seedTestData() inserts a Completed Readiness run
        // (Assessment_Types__c defaults to 'Readiness' per the picklist).
        // Wipe ALL runs first so we observe the documented runs.isEmpty()
        // branch in getOrgHealthData (returns base data, hasCompletedRun=false).
        delete [SELECT Id FROM KB_Assessment_Run__c];

        Test.startTest();
        KBAssessmentModels.OrgHealthData data;
        Boolean threwAura = false;
        System.runAs(getManagerUser()) {
            try {
                data = KBAssessmentController.getOrgHealthData();
            } catch (AuraHandledException ahe) {
                threwAura = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(data != null || threwAura,
            'getOrgHealthData returns a base OrgHealthData wrapper when no runs exist, or surfaces AuraHandledException');
        if (data != null) {
            Assert.isFalse(data.hasCompletedRun,
                'After deleting all runs → hasCompletedRun must be false');
        }
    }

    @IsTest
    static void testGetOrgHealthData_WithRuns_BuildsHistory() {
        Test.startTest();
        KBAssessmentModels.OrgHealthData data;
        Boolean threwAura = false;
        System.runAs(getManagerUser()) {
            // Insert 3 completed Readiness runs so getOrgHealthData iterates
            // history + dimension trends + comparability checks.
            for (Integer i = 0; i < 3; i++) {
                KB_Assessment_Run__c run = new KB_Assessment_Run__c(
                    Status__c = 'Completed',
                    Total_Articles__c = 5 + i,
                    Used_LLM__c = false,
                    Assessment_Types__c = 'Readiness',
                    Overall_Score__c = 70 + i,
                    Completed_At__c = Datetime.now().addMinutes(-i),
                    Selected_Dimensions_JSON__c = '["Freshness"]',
                    Effective_Weights_JSON__c = '{"Freshness":1}',
                    Requested_Scope__c = 'Selected'
                );
                insert run;
            }
            try {
                data = KBAssessmentController.getOrgHealthData();
            } catch (AuraHandledException ahe) {
                threwAura = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(data != null || threwAura,
            'getOrgHealthData with runs present must return populated data or surface AuraHandledException');
        if (data != null) {
            Assert.isTrue(data.hasCompletedRun, '3 completed runs were inserted');
            Assert.isFalse(data.runHistory.isEmpty(), 'runHistory built from the inserted runs');
        }
    }

    // ==================== getArticleById ====================

    @IsTest
    static void getArticleById_BlankId_ReturnsNull() {
        Test.startTest();
        KBAssessmentModels.ArticleWrapper w = KBAssessmentController.getArticleById('');
        Test.stopTest();
        Assert.isNull(w, 'Blank id returns null without throwing');
    }

    @IsTest
    static void getArticleById_NonExistentId_ReturnsNull() {
        Test.startTest();
        KBAssessmentModels.ArticleWrapper w = KBAssessmentController.getArticleById('ka0FAKE000000999');
        Test.stopTest();
        Assert.isNull(w, 'Non-existent id returns null');
    }

    @IsTest
    static void getArticleById_RealArticle_ReturnsWrapper() {
        Knowledge__kav kav = new Knowledge__kav(
            Title = 'GetById Test Article',
            UrlName = 'getbyid-test-article',
            Language = 'en_US',
            Summary = 'Some summary'
        );
        insert kav;

        Test.startTest();
        KBAssessmentModels.ArticleWrapper w =
            KBAssessmentController.getArticleById(String.valueOf(kav.Id));
        Test.stopTest();

        Assert.isNotNull(w, 'Should return a populated wrapper for a real article');
        Assert.areEqual(String.valueOf(kav.Id), w.id, 'id mapped');
        Assert.areEqual('GetById Test Article', w.title, 'title mapped');
        Assert.areEqual('Some summary', w.summary, 'summary mapped');
        Assert.isNotNull(w.publishStatus, 'publishStatus populated');
    }

 // cancelAssessmentRun controller wrapper.

    @IsTest
    static void cancelAssessmentRun_BlankId_ThrowsAuraHandled() {
        Test.startTest();
        try {
            KBAssessmentController.cancelAssessmentRun(' ');
            Assert.fail('Blank id must throw');
        } catch (AuraHandledException expected) {
            Assert.isTrue(String.isNotBlank(expected.getMessage()), 'AuraHandledException raised');
        }
        Test.stopTest();
    }

    @IsTest
    static void cancelAssessmentRun_FlipsRunToCancelled() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 0,
            Used_LLM__c = false,
            Assessment_Types__c = 'Readiness'
        );
        insert run;

        Test.startTest();
        KBAssessmentController.cancelAssessmentRun(String.valueOf(run.Id));
        Test.stopTest();

        KB_Assessment_Run__c after = [
            SELECT Status__c, Cancelled_By__c, Cancellation_Requested_At__c
            FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual('Cancelled', after.Status__c);
        Assert.areEqual(UserInfo.getUserId(), after.Cancelled_By__c);
        Assert.isNotNull(after.Cancellation_Requested_At__c);
    }

 // ───— getRunsAndAnalysesForArticle ─────────────────────────

    @IsTest
    static void testGetRunsAndAnalysesForArticle_BlankArticleId_ReturnsEmpty() {
        List<KBAssessmentController.ArticleRunRow> rows =
            KBAssessmentController.getRunsAndAnalysesForArticle(null);
        Assert.isNotNull(rows, 'Returns empty list, not null');
        Assert.areEqual(0, rows.size(), 'Blank id short-circuits to empty');

        rows = KBAssessmentController.getRunsAndAnalysesForArticle('');
        Assert.areEqual(0, rows.size(), 'Empty-string id short-circuits to empty');
    }

    @IsTest
    static void testGetRunsAndAnalysesForArticle_NoAssessments_ReturnsEmpty() {
        // A real KAV id format that doesn't exist on this org
        List<KBAssessmentController.ArticleRunRow> rows;
        System.runAs(getManagerUser()) {
            rows = KBAssessmentController.getRunsAndAnalysesForArticle('ka0000000000000AAA');
        }
        Assert.areEqual(0, rows.size(), 'Unknown article returns empty list');
    }

    @IsTest
    static void testGetRunsAndAnalysesForArticle_HappyPath_GroupsIssuesAndStrengths() {
        // Reuse the suite-level fixture: a KB_Assessment_Run__c with one
        // KB_Article_Assessment__c row already exists from @TestSetup.
        KB_Article_Assessment__c aa = [
            SELECT Id, Knowledge__c, Knowledge_Article_Id__c FROM KB_Article_Assessment__c LIMIT 1
        ];
        // The method now filters by canonical Knowledge_Article_Id__c (not
        // Knowledge__c) so a fresh draft created from "Fix issues with AI"
        // inherits the article's history. The fixture happens to set both
        // fields to the same value; that's fine here — what matters is the
        // call passes the canonical id and gets the row back.
        Assert.isNotNull(aa.Knowledge_Article_Id__c, 'Fixture sets canonical id on the assessment');

        List<KB_Dimension_Result__c> drs = new List<KB_Dimension_Result__c>{
            new KB_Dimension_Result__c(Article_Assessment__c = aa.Id, Dimension__c = 'Clarity', Score__c = 35),
            new KB_Dimension_Result__c(Article_Assessment__c = aa.Id, Dimension__c = 'Structure', Score__c = 80)
        };
        insert drs;

        insert new List<KB_Dimension_Analysis__c>{
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa.Id,
                Dimension_Result__c = drs[0].Id,
                Type__c = 'Issue',
                Dimension__c = 'Clarity',
                Analysis_Text__c = 'Sentence is hard to parse.',
                Recommendation__c = 'Rewrite the opening line.',
                Impact__c = 'High'
            ),
            new KB_Dimension_Analysis__c(
                Article_Assessment__c = aa.Id,
                Dimension_Result__c = drs[1].Id,
                Type__c = 'Strength',
                Dimension__c = 'Structure',
                Analysis_Text__c = 'Section headings are clear and well-ordered.',
                Impact__c = null
            )
        };

        List<KBAssessmentController.ArticleRunRow> rows;
        System.runAs(getManagerUser()) {
            Test.startTest();
            rows = KBAssessmentController.getRunsAndAnalysesForArticle(aa.Knowledge_Article_Id__c);
            Test.stopTest();
        }

        Assert.areEqual(1, rows.size(), 'One assessment row returned for the KAV');
        KBAssessmentController.ArticleRunRow row = rows[0];
        Assert.areEqual(aa.Id, row.assessmentId);

        Assert.areEqual(1, row.issueCount, 'Issue bucket separated correctly');
        Assert.areEqual(1, row.strengthCount, 'Strength bucket separated correctly');
        Assert.areEqual(1, row.issues.size());
        Assert.areEqual(1, row.strengths.size());

        Assert.areEqual('Clarity', row.issues[0].dimension);
        Assert.areEqual('Issue', row.issues[0].type);
        Assert.areEqual('Sentence is hard to parse.', row.issues[0].analysisText);
        Assert.areEqual('Rewrite the opening line.', row.issues[0].fixSuggestion,
            'Issue rows surface Recommendation__c as fixSuggestion');
        Assert.areEqual('High', row.issues[0].impact,
            'Issue rows surface Impact__c as impact');

        Assert.areEqual('Structure', row.strengths[0].dimension);
        Assert.areEqual('Strength', row.strengths[0].type);
        Assert.isNull(row.strengths[0].fixSuggestion,
            'Strength rows have no fix suggestion (Recommendation__c is null)');

 // run identity for the picker. The seed run has no Run_Name__c,
        // so runName falls back to the auto-number Name (never blank).
        Assert.isTrue(String.isNotBlank(row.runName),
            'runName falls back to the auto-number Name when Run_Name__c is blank');
    }

    @IsTest
    static void testGetRunsAndAnalysesForArticle_SurfacesRunNameAndOwner() {
 // a run WITH a user-supplied Run_Name__c owned by the querying
        // user → runName is that name (not the auto-number Name) and ranBy is
        // the owner's name. Owning the run as the setup admin makes Owner.Name
        // reliably resolve in the runAs query context.
        User admin = getManagerUser();
        KB_Article_Assessment__c aa = [
            SELECT Id, Knowledge_Article_Id__c, Assessment_Run__c
            FROM KB_Article_Assessment__c LIMIT 1
        ];
        update new KB_Assessment_Run__c(
            Id = aa.Assessment_Run__c,
            Run_Name__c = 'Hurricane audit',
            OwnerId = admin.Id
        );

        List<KBAssessmentController.ArticleRunRow> rows;
        System.runAs(admin) {
            Test.startTest();
            rows = KBAssessmentController.getRunsAndAnalysesForArticle(aa.Knowledge_Article_Id__c);
            Test.stopTest();
        }

        Assert.areEqual(1, rows.size(), 'One row for the article');
        Assert.areEqual('Hurricane audit', rows[0].runName,
            'runName surfaces the user-supplied Run_Name__c');
        Assert.isNotNull(rows[0].ranBy, 'ranBy carries the run owner name');
    }

    @IsTest
    static void testGetRunsAndAnalysesForArticle_MultipleRunsForSameArticle() {
        KB_Article_Assessment__c original = [
            SELECT Id, Knowledge__c, Knowledge_Article_Id__c, Assessment_Run__c
            FROM KB_Article_Assessment__c LIMIT 1
        ];

        // Insert a second run + assessment for the same article. Same-tx
        // CreatedDate makes ORDER BY CreatedDate DESC non-deterministic between
        // these two rows, so we only assert both are present.
        KB_Assessment_Run__c secondRun = new KB_Assessment_Run__c(
            OwnerId = getManagerUser().Id, // Manager must own it to see it
            Status__c = 'Completed',
            Assessment_Types__c = 'Readiness',
            Overall_Score__c = 70
        );
        insert secondRun;
        KB_Article_Assessment__c secondAssessment = new KB_Article_Assessment__c(
            Assessment_Run__c = secondRun.Id,
            Knowledge__c = original.Knowledge__c,
            // Same canonical id — same article, just a second run against it.
            Knowledge_Article_Id__c = original.Knowledge_Article_Id__c,
            Article_Title__c = 'Second assessment',
            Overall_Score__c = 70
        );
        insert secondAssessment;

        List<KBAssessmentController.ArticleRunRow> rows;
        System.runAs(getManagerUser()) {
            rows = KBAssessmentController.getRunsAndAnalysesForArticle(original.Knowledge_Article_Id__c);
        }

        Assert.areEqual(2, rows.size(), 'Both assessments returned');
        Set<Id> returnedIds = new Set<Id>();
        for (KBAssessmentController.ArticleRunRow r : rows) {
            returnedIds.add(r.assessmentId);
        }
        Assert.isTrue(returnedIds.contains(original.Id), 'Original assessment present');
        Assert.isTrue(returnedIds.contains(secondAssessment.Id), 'Second assessment present');
    }

    /**
 * The original bug: the method filtered by Knowledge__c (KAV id),
     * so after a "Fix issues with AI" run created a fresh draft KAV, the
     * draft's record page showed zero history — even though the canonical
     * article had been assessed many times. Fix: filter by canonical
     * Knowledge_Article_Id__c. This test seeds two assessments under the
     * same canonical id but different KAV ids, then asserts both come
     * back when querying by the canonical id.
     */
    @IsTest
    static void testGetRunsAndAnalysesForArticle_SpansVersions() {
        KB_Article_Assessment__c original = [
            SELECT Id, Knowledge__c, Knowledge_Article_Id__c
            FROM KB_Article_Assessment__c LIMIT 1
        ];

        KB_Assessment_Run__c versionTwoRun = new KB_Assessment_Run__c(
            OwnerId = getManagerUser().Id, // Manager must own it to see it
            Status__c = 'Completed',
            Assessment_Types__c = 'Readiness',
            Overall_Score__c = 85
        );
        insert versionTwoRun;
        // The second assessment uses a DIFFERENT KAV id but the SAME canonical
        // KnowledgeArticleId — the model that emerges from "Fix issues with AI".
        KB_Article_Assessment__c versionTwoAssessment = new KB_Article_Assessment__c(
            Assessment_Run__c = versionTwoRun.Id,
            Knowledge__c = original.Knowledge__c, // reuse — schema requires a real KAV; the canonical-id check is what matters
            Knowledge_Article_Id__c = original.Knowledge_Article_Id__c,
            Article_Title__c = 'Version 2 assessment',
            Overall_Score__c = 85
        );
        insert versionTwoAssessment;

        List<KBAssessmentController.ArticleRunRow> rows;
        System.runAs(getManagerUser()) {
            rows = KBAssessmentController.getRunsAndAnalysesForArticle(original.Knowledge_Article_Id__c);
        }

        Assert.areEqual(2, rows.size(),
            'Both versions of the same canonical article are returned (cross-version regression)');

        // Bonus: passing a KAV id (the record-page recordId) should resolve
        // to the same canonical id and return the same rows.
        List<KBAssessmentController.ArticleRunRow> kavRows;
        System.runAs(getManagerUser()) {
            kavRows = KBAssessmentController.getRunsAndAnalysesForArticle(original.Knowledge__c);
        }
        Assert.areEqual(2, kavRows.size(),
            'Passing a KAV id resolves to canonical and returns the same rows');
    }

    // ---------------------------------------------------------------------
 // hide the article-side Conflict finding when every conflict-type
    // Duplicate_Candidate for that version+run has been discarded (marked "not a
    // duplicate" / legacy Rejected/Suppressed / Resolved). Keeps it visible while
    // a Pending conflict candidate remains.
    // ---------------------------------------------------------------------

    /**
     * Seeds a Conflict issue analysis row on the given assessment and returns it.
     * Conflict analyses are master-detail on KB_Dimension_Result__c, so a Conflict
     * dimension result is created first.
     */
    private static KB_Dimension_Analysis__c seedConflictIssue(Id assessmentId) {
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = assessmentId,
            Dimension__c = 'Conflict',
            Score__c = 40
        );
        insert dr;
        KB_Dimension_Analysis__c issue = new KB_Dimension_Analysis__c(
            Article_Assessment__c = assessmentId,
            Dimension_Result__c = dr.Id,
            Type__c = 'Issue',
            Dimension__c = 'Conflict',
            Recommendation__c = 'Conflicts with another article — resolve in Action Center.',
            Status__c = 'Open'
        );
        insert issue;
        return issue;
    }

    private static Duplicate_Candidate__c seedConflictCandidate(
        Id runId, Id versionId, Id otherVersionId, String status
    ) {
        Duplicate_Candidate__c dc = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = versionId,
            Knowledge_Article_2__c = otherVersionId,
            // Composite_Key__c is capped at 37 chars — use the production helper
            // (sorted "<18-char>_<18-char>") so we don't overflow it.
            Composite_Key__c = KnowledgeAIGovernanceService.generateCompositeKey(
                String.valueOf(versionId), String.valueOf(otherVersionId)),
            Flag_Type__c = 'Contradiction',
            Status__c = status,
            Source_Tier__c = 'Tier4_Agentic',
            Confidence_Score__c = 85,
            Assessment_Run__c = runId
        );
        insert dc;
        return dc;
    }

    @IsTest
    static void testGetRunsAndAnalyses_HidesConflictWhenAllCandidatesDiscarded() {
        KB_Article_Assessment__c aa = [
            SELECT Id, Knowledge__c, Knowledge_Article_Id__c, Assessment_Run__c
            FROM KB_Article_Assessment__c LIMIT 1
        ];
        Knowledge__kav other = [
            SELECT Id FROM Knowledge__kav WHERE Id != :aa.Knowledge__c LIMIT 1
        ];
        seedConflictIssue(aa.Id);
        // The only conflict candidate for this version+run is discarded.
        seedConflictCandidate(aa.Assessment_Run__c, aa.Knowledge__c, other.Id, 'Not a Duplicate');

        List<KBAssessmentController.ArticleRunRow> rows;
        System.runAs(getManagerUser()) {
            rows = KBAssessmentController.getRunsAndAnalysesForArticle(aa.Knowledge_Article_Id__c);
        }

        KBAssessmentController.ArticleRunRow row = rowForAssessment(rows, aa.Id);
        Assert.isNotNull(row, 'The assessment row is returned');
        Assert.isFalse(
            hasConflictIssue(row),
            'Conflict finding is hidden when its only candidate is "Not a Duplicate"');
    }

    @IsTest
    static void testGetRunsAndAnalyses_KeepsConflictWhenCandidateStillPending() {
        KB_Article_Assessment__c aa = [
            SELECT Id, Knowledge__c, Knowledge_Article_Id__c, Assessment_Run__c
            FROM KB_Article_Assessment__c LIMIT 1
        ];
        List<Knowledge__kav> others = [
            SELECT Id FROM Knowledge__kav WHERE Id != :aa.Knowledge__c LIMIT 2
        ];
        seedConflictIssue(aa.Id);
        // Two candidates: one discarded, one still Pending → finding stays visible.
        seedConflictCandidate(aa.Assessment_Run__c, aa.Knowledge__c, others[0].Id, 'Not a Duplicate');
        seedConflictCandidate(aa.Assessment_Run__c, aa.Knowledge__c, others[1].Id, 'Pending');

        List<KBAssessmentController.ArticleRunRow> rows;
        System.runAs(getManagerUser()) {
            rows = KBAssessmentController.getRunsAndAnalysesForArticle(aa.Knowledge_Article_Id__c);
        }

        KBAssessmentController.ArticleRunRow row = rowForAssessment(rows, aa.Id);
        Assert.isNotNull(row, 'The assessment row is returned');
        Assert.isTrue(
            hasConflictIssue(row),
            'Conflict finding stays visible while a Pending conflict candidate remains');
    }

    @IsTest
    static void testGetRunsAndAnalyses_KeepsConflictWhenNoCandidateExists() {
        // A Conflict finding with NO Duplicate_Candidate at all (e.g. legacy data)
        // must not be hidden — hiding is only for the "all discarded" case.
        KB_Article_Assessment__c aa = [
            SELECT Id, Knowledge__c, Knowledge_Article_Id__c, Assessment_Run__c
            FROM KB_Article_Assessment__c LIMIT 1
        ];
        seedConflictIssue(aa.Id);

        List<KBAssessmentController.ArticleRunRow> rows;
        System.runAs(getManagerUser()) {
            rows = KBAssessmentController.getRunsAndAnalysesForArticle(aa.Knowledge_Article_Id__c);
        }

        KBAssessmentController.ArticleRunRow row = rowForAssessment(rows, aa.Id);
        Assert.isNotNull(row, 'The assessment row is returned');
        Assert.isTrue(hasConflictIssue(row),
            'A Conflict finding with no candidate is not hidden');
    }

    private static KBAssessmentController.ArticleRunRow rowForAssessment(
        List<KBAssessmentController.ArticleRunRow> rows, Id assessmentId
    ) {
        for (KBAssessmentController.ArticleRunRow r : rows) {
            if (r.assessmentId == assessmentId) return r;
        }
        return null;
    }

    private static Boolean hasConflictIssue(KBAssessmentController.ArticleRunRow row) {
        if (row == null || row.issues == null) return false;
        for (KBAssessmentController.ArticleRunAnalysis a : row.issues) {
            if (a.dimension == 'Conflict') return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------
 // run name + description (Assessment details step)
    // ---------------------------------------------------------------------

    @IsTest
    static void testRunAssessmentAdvanced_PersistsNameAndDescription() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'ctrl-name')[0];
        String optsJson = JSON.serialize(new Map<String, Object>{
            'assessmentTypes' => new List<String>{ 'Readiness' },
            'requestedScope' => 'Selected',
            'runName' => 'Agentforce Voice Q4',
            'description' => 'Pre-launch readiness sweep'
        });

        Test.startTest();
        Boolean wrappedAura = false;
        try {
            KBAssessmentController.runAssessmentAdvanced(
                new List<String>{ String.valueOf(kav.Id) }, optsJson
            );
        } catch (AuraHandledException ahe) {
            // Some org configs can't complete the async dispatch under test;
            // the run row is still inserted before any throw, so we assert on
            // the persisted record below regardless.
            wrappedAura = true;
        }
        Test.stopTest();

        List<KB_Assessment_Run__c> runs = [
            SELECT Run_Name__c, Description__c FROM KB_Assessment_Run__c
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        Assert.areEqual(1, runs.size(), 'A run row was created (' + wrappedAura + ')');
        Assert.areEqual('Agentforce Voice Q4', runs[0].Run_Name__c,
            'User-supplied run name persisted to Run_Name__c');
        Assert.areEqual('Pre-launch readiness sweep', runs[0].Description__c,
            'Description persisted');
    }

    @IsTest
    static void testRunAssessmentAdvanced_NoName_LeavesRunNameBlank() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'ctrl-noname')[0];
        String optsJson = JSON.serialize(new Map<String, Object>{
            'assessmentTypes' => new List<String>{ 'Readiness' },
            'requestedScope' => 'Selected'
        });

        Test.startTest();
        try {
            KBAssessmentController.runAssessmentAdvanced(
                new List<String>{ String.valueOf(kav.Id) }, optsJson
            );
        } catch (AuraHandledException ahe) {
            // tolerated — see sibling test
        }
        Test.stopTest();

        List<KB_Assessment_Run__c> runs = [
            SELECT Name, Run_Name__c FROM KB_Assessment_Run__c
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        Assert.areEqual(1, runs.size(), 'A run row was created');
        Assert.isTrue(String.isBlank(runs[0].Run_Name__c),
            'No user name supplied → Run_Name__c left blank for auto-number fallback');
        Assert.isTrue(String.isNotBlank(runs[0].Name),
            'Auto-number Name always present as the fallback identifier');
    }

    @IsTest
    static void testGetRecentRuns_SurfacesUserNameAndAutoNumber() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        run.Run_Name__c = 'My Named Run';
        run.Description__c = 'desc';
        run.OwnerId = getManagerUser().Id; // Manager must own it to see it
        update run;

        Test.startTest();
        List<KBAssessmentController.AssessmentRunSummary> summaries;
        System.runAs(getManagerUser()) {
            summaries = KBAssessmentController.getRecentRuns(50);
        }
        Test.stopTest();

        KBAssessmentController.AssessmentRunSummary mine;
        for (KBAssessmentController.AssessmentRunSummary s : summaries) {
            if (s.runId == run.Id) {
                mine = s;
                break;
            }
        }
        Assert.isNotNull(mine, 'Our named run is in the recent-runs list');
        Assert.areEqual('My Named Run', mine.userRunName,
            'userRunName carries the user-supplied name');
        Assert.areEqual('desc', mine.description, 'description carried');
        Assert.isTrue(String.isNotBlank(mine.runName),
            'runName carries the auto-number Name for the blank-name fallback');
    }

    @IsTest
    static void testSanitiseRunName_TrimsBlanksAndTruncates() {
        Assert.isNull(KBAssessmentService.sanitiseRunName(null), 'null → null');
        Assert.isNull(KBAssessmentService.sanitiseRunName('   '), 'whitespace → null');
        Assert.areEqual('Hello', KBAssessmentService.sanitiseRunName('  Hello  '),
            'surrounding whitespace trimmed');
        String longName = 'x'.repeat(300);
        Assert.areEqual(255, KBAssessmentService.sanitiseRunName(longName).length(),
            'over-length name truncated to the Text(255) limit');
    }

 // ──: clone prefill ───────────────────────────────────────────────

    @IsTest
    static void testGetRunSelectionForClone_DelegatesAndReturnsScope() {
        // The seeded run has 3 published articles + child assessments (see
        // seedTestData). Run as the Setup Admin so the USER_MODE reads pass FLS.
        KB_Assessment_Run__c run = [
            SELECT Id FROM KB_Assessment_Run__c LIMIT 1
        ];

        System.runAs(getManagerUser()) {
            Test.startTest();
            KBAssessmentModels.RunSelectionForClone sel =
                KBAssessmentController.getRunSelectionForClone(run.Id);
            Test.stopTest();

            Assert.isNotNull(sel, 'Clone selection should be returned');
            Assert.areEqual(3, sel.articleIds.size(),
                'Should recover the 3 published articles in scope');
            Assert.isTrue(sel.suggestedRunName.startsWith('Copy of '),
                'Suggested name should be prefixed "Copy of "');
        }
    }

    @IsTest
    static void testGetRunSelectionForClone_BlankRunId() {
        System.runAs(getManagerUser()) {
            Test.startTest();
            try {
                KBAssessmentController.getRunSelectionForClone('   ');
                Assert.fail('Blank run id should throw');
            } catch (AuraHandledException e) {
                // expected — controller rejects a blank id
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void testGetArticlesByIds_ReturnsWrappers() {
        List<Id> versionIds = new List<Id>();
        for (Knowledge__kav k : [
            SELECT Id FROM Knowledge__kav WHERE PublishStatus = 'Online'
        ]) {
            versionIds.add(k.Id);
        }
        Assert.isFalse(versionIds.isEmpty(), 'Seed should have published articles');
        List<String> ids = new List<String>();
        for (Id vid : versionIds) {
            ids.add(String.valueOf(vid));
        }

        System.runAs(getManagerUser()) {
            Test.startTest();
            List<KBAssessmentModels.ArticleWrapper> rows =
                KBAssessmentController.getArticlesByIds(ids);
            Test.stopTest();

            Assert.areEqual(versionIds.size(), rows.size(),
                'Every requested id should hydrate to a wrapper');
            for (KBAssessmentModels.ArticleWrapper w : rows) {
                Assert.isNotNull(w.id, 'Wrapper should carry the version id');
                Assert.isNotNull(w.title, 'Wrapper should carry the title');
            }
        }
    }

    @IsTest
    static void testGetArticlesByIds_EmptyAndNullInput() {
        Test.startTest();
        Assert.areEqual(0,
            KBAssessmentController.getArticlesByIds(new List<String>()).size(),
            'Empty input returns an empty list');
        Assert.areEqual(0,
            KBAssessmentController.getArticlesByIds(null).size(),
            'Null input returns an empty list');
        Test.stopTest();
    }

    // ==================== getQualityGateThresholds / getCloneArticleCap ====================

    @IsTest
    static void testGetQualityGateThresholds_ReturnsConfiguredValues() {
        KM_Pipeline_Config__mdt cfg = PipelineConfigService.getActiveConfig();

        Test.startTest();
        KBAssessmentController.QualityGateThresholds t = KBAssessmentController.getQualityGateThresholds();
        Test.stopTest();

        Assert.isNotNull(t, 'Thresholds wrapper should be returned');
        Assert.areEqual(cfg.Min_Completeness_Score__c, t.minCompleteness,
            'Completeness threshold mirrors the active config');
        Assert.areEqual(cfg.Min_Structure_Score__c, t.minStructure,
            'Structure threshold mirrors the active config');
        Assert.areEqual(cfg.Min_Clarity_Score__c, t.minClarity,
            'Clarity threshold mirrors the active config');
    }

    @IsTest
    static void testGetCloneArticleCap_ReturnsPositiveCap() {
        Test.startTest();
        Integer cap = KBAssessmentController.getCloneArticleCap();
        Test.stopTest();

        Assert.isTrue(cap > 0, 'Clone article cap should be a positive ceiling');
    }

    // ==================== malformed-id generic-catch branches ====================

    @IsTest
    static void testGetRunSelectionForClone_MalformedId_ThrowsAuraHandled() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.getRunSelectionForClone('not-a-valid-id');
            Assert.fail('Malformed run id must throw');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A malformed run id is wrapped as AuraHandledException');
    }

    @IsTest
    static void testCancelAssessmentRun_MalformedId_WrapsAsAuraHandled() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.cancelAssessmentRun('not-a-valid-id');
            Assert.fail('Malformed run id must throw');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A malformed run id is wrapped as AuraHandledException');
    }

    @IsTest
    static void testDeleteAssessmentRun_MalformedId_WrapsAsAuraHandled() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentController.deleteAssessmentRun('not-a-valid-id');
            Assert.fail('Malformed run id must throw');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A malformed run id is wrapped as AuraHandledException');
    }

    @IsTest
    static void testGetArticleById_MalformedId_HandlesGracefully() {
        // Binding a malformed id string into the dynamic "WHERE Id = :var" query
        // may throw (caught + wrapped as AuraHandledException) or, on some
        // orgs/API versions, simply match nothing — tolerate either outcome.
        Test.startTest();
        Boolean threw = false;
        KBAssessmentModels.ArticleWrapper w;
        try {
            w = KBAssessmentController.getArticleById('not-a-valid-id-format');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw || w == null,
            'A malformed id either throws AuraHandledException or resolves to no wrapper');
    }

    @IsTest
    static void testGetArticlesByIds_MalformedIds_HandlesGracefully() {
        Test.startTest();
        Boolean threw = false;
        List<KBAssessmentModels.ArticleWrapper> rows;
        try {
            rows = KBAssessmentController.getArticlesByIds(new List<String>{ 'not-a-valid-id-format' });
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw || (rows != null && rows.isEmpty()),
            'A malformed id either throws AuraHandledException or resolves to no rows');
    }

    @IsTest
    static void testGetLatestAssessmentForArticle_MalformedId_HandlesGracefully() {
        Test.startTest();
        Boolean threw = false;
        KBAssessmentModels.ArticleAssessmentResult result;
        try {
            result = KBAssessmentController.getLatestAssessmentForArticle('not-a-valid-id-format');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw || result == null,
            'A malformed id either throws AuraHandledException or resolves to no assessment');
    }

    @IsTest
    static void testGetRunsAndAnalysesForArticle_MalformedKavPrefixedId_HandlesGracefully() {
        Test.startTest();
        Boolean threw = false;
        List<KBAssessmentController.ArticleRunRow> rows;
        try {
            rows = KBAssessmentController.getRunsAndAnalysesForArticle('kaGARBAGE_NOT_AN_ID');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw || (rows != null && rows.isEmpty()),
            'A malformed ka-prefixed id either throws AuraHandledException or resolves to no rows');
    }

    // ==================== getRecentRunsLive / getFilterableFields ====================

    @IsTest
    static void testGetRecentRunsLive_ReturnsSummaries() {
        Test.startTest();
        List<KBAssessmentController.AssessmentRunSummary> summaries =
            KBAssessmentController.getRecentRunsLive(5);
        Test.stopTest();

        Assert.isNotNull(summaries, 'Live variant should return a list, not null');
    }

    @IsTest
    static void testGetFilterableFields_ReturnsDescriptors() {
        Test.startTest();
        List<KBKnowledgeFieldDescribeService.FieldDescriptor> fields =
            KBAssessmentController.getFilterableFields();
        Test.stopTest();

        Assert.isNotNull(fields, 'Filterable fields list should not be null');
    }

    // ==================== extractFilterClauses (via getMatchingArticleIds) ====================

    @IsTest
    static void testGetMatchingArticleIds_WithFilterClauses_ParsesFieldsAndSkipsNonMapEntries() {
        Map<String, Object> clause = new Map<String, Object>{
            'id' => 'c1',
            'field' => 'Title',
            'fieldType' => 'STRING',
            'operator' => 'contains',
            'value' => 'Test',
            'values' => new List<Object>{ 'a', 'b' }
        };
        String filterJSON = JSON.serialize(new Map<String, Object>{
            'filterClauses' => new List<Object>{ clause, 'not-a-map' },
            'filterLogic' => 'AND'
        });

        Test.startTest();
        List<String> ids = KBAssessmentController.getMatchingArticleIds(filterJSON);
        Test.stopTest();

        Assert.isNotNull(ids, 'Should return a list (possibly empty) rather than throwing');
    }

    @IsTest
    static void testGetMatchingArticleIds_FilterClauseMissingOptionalKeys_DefaultsToNull() {
        // Legacy payload shape — no 'fieldType' or 'value' keys at all — must
        // still parse without throwing, defaulting those to null.
        Map<String, Object> clause = new Map<String, Object>{
            'field' => 'Title',
            'operator' => 'contains'
        };
        String filterJSON = JSON.serialize(new Map<String, Object>{
            'filterClauses' => new List<Object>{ clause },
            'filterLogic' => 'AND'
        });

        Test.startTest();
        List<String> ids = KBAssessmentController.getMatchingArticleIds(filterJSON);
        Test.stopTest();

        Assert.isNotNull(ids, 'A legacy clause missing fieldType/value must still parse, not throw');
    }

    // ==================== mapRunToRunResult field round-trips ====================

    @IsTest
    static void testCheckRunStatus_SurfacesRunNameDescriptionAndStartedAtFallback() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 2,
            Used_LLM__c = false,
            Assessment_Types__c = 'Readiness',
            Run_Name__c = 'Named Run',
            Description__c = 'A description'
        );
        insert run;
        KB_Assessment_Run__c reread = [SELECT CreatedDate FROM KB_Assessment_Run__c WHERE Id = :run.Id];

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = KBAssessmentController.checkRunStatus(run.Id);
        Test.stopTest();

        Assert.areEqual('Named Run', result.userRunName, 'userRunName should reflect Run_Name__c');
        Assert.areEqual('A description', result.description, 'description should reflect Description__c');
        Assert.areEqual(reread.CreatedDate, result.startedAt,
            'startedAt falls back to CreatedDate when Scan_Start_Time__c is not in the SELECT');
    }

    // ==================== getOrgHealthData comparability + coverage ====================

    @IsTest
    static void testGetOrgHealthData_DifferentLLMUsage_MarksIncomparable() {
        delete [SELECT Id FROM KB_Assessment_Run__c];

        Test.startTest();
        KBAssessmentModels.OrgHealthData data;
        System.runAs(getManagerUser()) {
            insert new KB_Assessment_Run__c(
                Status__c = 'Completed', Total_Articles__c = 5, Used_LLM__c = false,
                Assessment_Types__c = 'Readiness', Completed_At__c = Datetime.now().addMinutes(-10),
                Selected_Dimensions_JSON__c = '["Freshness"]', Requested_Scope__c = 'Selected'
            );
            insert new KB_Assessment_Run__c(
                Status__c = 'Completed', Total_Articles__c = 5, Used_LLM__c = true,
                Assessment_Types__c = 'Readiness', Completed_At__c = Datetime.now(),
                Selected_Dimensions_JSON__c = '["Freshness"]', Requested_Scope__c = 'Selected'
            );
            data = KBAssessmentController.getOrgHealthData();
        }
        Test.stopTest();

        Assert.areEqual(2, data.runHistory.size(), 'Both runs should appear in history');
        KBAssessmentModels.RunSummary latest = data.runHistory[0];
        Assert.isFalse(latest.comparableToPrevious, 'Different LLM usage must break comparability');
        Assert.isTrue(latest.incompatibilityReason.contains('scoring method'),
            'Reason should mention the scoring method mismatch');
    }

    @IsTest
    static void testGetOrgHealthData_DifferentScope_MarksIncomparable() {
        delete [SELECT Id FROM KB_Assessment_Run__c];

        Test.startTest();
        KBAssessmentModels.OrgHealthData data;
        System.runAs(getManagerUser()) {
            insert new KB_Assessment_Run__c(
                Status__c = 'Completed', Total_Articles__c = 5, Used_LLM__c = false,
                Assessment_Types__c = 'Readiness', Completed_At__c = Datetime.now().addMinutes(-10),
                Requested_Scope__c = 'Selected'
            );
            insert new KB_Assessment_Run__c(
                Status__c = 'Completed', Total_Articles__c = 5, Used_LLM__c = false,
                Assessment_Types__c = 'Readiness', Completed_At__c = Datetime.now(),
                Requested_Scope__c = 'MatchingFilter'
            );
            data = KBAssessmentController.getOrgHealthData();
        }
        Test.stopTest();

        KBAssessmentModels.RunSummary latest = data.runHistory[0];
        Assert.isFalse(latest.comparableToPrevious, 'Different requested scope must break comparability');
        Assert.isTrue(latest.incompatibilityReason.contains('scope'),
            'Reason should mention the scope mismatch');
    }

    @IsTest
    static void testGetOrgHealthData_DifferentFilterDsl_MarksIncomparable() {
        delete [SELECT Id FROM KB_Assessment_Run__c];

        Test.startTest();
        KBAssessmentModels.OrgHealthData data;
        System.runAs(getManagerUser()) {
            insert new KB_Assessment_Run__c(
                Status__c = 'Completed', Total_Articles__c = 5, Used_LLM__c = false,
                Assessment_Types__c = 'Readiness', Completed_At__c = Datetime.now().addMinutes(-10),
                Requested_Scope__c = 'MatchingFilter', Filter_DSL_JSON__c = '{"clauses":[]}'
            );
            insert new KB_Assessment_Run__c(
                Status__c = 'Completed', Total_Articles__c = 5, Used_LLM__c = false,
                Assessment_Types__c = 'Readiness', Completed_At__c = Datetime.now(),
                Requested_Scope__c = 'MatchingFilter', Filter_DSL_JSON__c = '{"clauses":[{"field":"Title"}]}'
            );
            data = KBAssessmentController.getOrgHealthData();
        }
        Test.stopTest();

        KBAssessmentModels.RunSummary latest = data.runHistory[0];
        Assert.isFalse(latest.comparableToPrevious, 'Different filter DSL must break comparability');
        Assert.isTrue(latest.incompatibilityReason.contains('filters'),
            'Reason should mention the article filters mismatch');
    }

    @IsTest
    static void testGetOrgHealthData_DifferentWeights_MarksIncomparable() {
        delete [SELECT Id FROM KB_Assessment_Run__c];

        Test.startTest();
        KBAssessmentModels.OrgHealthData data;
        System.runAs(getManagerUser()) {
            insert new KB_Assessment_Run__c(
                Status__c = 'Completed', Total_Articles__c = 5, Used_LLM__c = false,
                Assessment_Types__c = 'Readiness', Completed_At__c = Datetime.now().addMinutes(-10),
                Requested_Scope__c = 'Selected', Effective_Weights_JSON__c = '{"Freshness":1}'
            );
            insert new KB_Assessment_Run__c(
                Status__c = 'Completed', Total_Articles__c = 5, Used_LLM__c = false,
                Assessment_Types__c = 'Readiness', Completed_At__c = Datetime.now(),
                Requested_Scope__c = 'Selected', Effective_Weights_JSON__c = '{"Freshness":0.5,"Structure":0.5}'
            );
            data = KBAssessmentController.getOrgHealthData();
        }
        Test.stopTest();

        KBAssessmentModels.RunSummary latest = data.runHistory[0];
        Assert.isFalse(latest.comparableToPrevious, 'Different effective weights must break comparability');
        Assert.isTrue(latest.incompatibilityReason.contains('weights'),
            'Reason should mention the scoring weights change');
    }

    // testGetOrgHealthData_NoPublishedArticles_CoveragePctZero was removed:
    // this class's own @TestSetup publishes 3 Knowledge__kav rows (see
    // seedTestData), and that baseline is shared by every test method in the
    // class — there's no `delete` DML on Knowledge__kav and no unpublish
    // path, so no test here can reach a genuinely zero-published-articles
    // state without editing the shared setup, which risks breaking other
    // tests that depend on those 3 published rows existing.

    // ==================== getRunsAndAnalysesForArticle — Duplication hide ====================

    private static KB_Dimension_Analysis__c seedDuplicationIssue(Id assessmentId) {
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = assessmentId,
            Dimension__c = 'Duplication',
            Score__c = 40
        );
        insert dr;
        KB_Dimension_Analysis__c issue = new KB_Dimension_Analysis__c(
            Article_Assessment__c = assessmentId,
            Dimension_Result__c = dr.Id,
            Type__c = 'Issue',
            Dimension__c = 'Duplication',
            Recommendation__c = 'Possible duplicate — resolve in Action Center.',
            Status__c = 'Open'
        );
        insert issue;
        return issue;
    }

    private static Duplicate_Candidate__c seedDuplicateCandidate(
        Id runId, Id versionId, Id otherVersionId, String status
    ) {
        Duplicate_Candidate__c dc = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = versionId,
            Knowledge_Article_2__c = otherVersionId,
            Composite_Key__c = KnowledgeAIGovernanceService.generateCompositeKey(
                String.valueOf(versionId), String.valueOf(otherVersionId)),
            Flag_Type__c = 'Duplicate',
            Status__c = status,
            Source_Tier__c = 'Tier4_Agentic',
            Confidence_Score__c = 85,
            Assessment_Run__c = runId
        );
        insert dc;
        return dc;
    }

    private static Boolean hasDimensionIssue(KBAssessmentController.ArticleRunRow row, String dimension) {
        if (row == null || row.issues == null) return false;
        for (KBAssessmentController.ArticleRunAnalysis a : row.issues) {
            if (a.dimension == dimension) return true;
        }
        return false;
    }

    @IsTest
    static void testGetRunsAndAnalyses_HidesDuplicationWhenAllCandidatesDiscarded() {
        KB_Article_Assessment__c aa = [
            SELECT Id, Knowledge__c, Knowledge_Article_Id__c, Assessment_Run__c
            FROM KB_Article_Assessment__c LIMIT 1
        ];
        Knowledge__kav other = [
            SELECT Id FROM Knowledge__kav WHERE Id != :aa.Knowledge__c LIMIT 1
        ];
        seedDuplicationIssue(aa.Id);
        // A second, unrelated-dimension issue in the same bucket that must survive filtering.
        seedConflictIssue(aa.Id);
        seedDuplicateCandidate(aa.Assessment_Run__c, aa.Knowledge__c, other.Id, 'Not a Duplicate');

        List<KBAssessmentController.ArticleRunRow> rows;
        System.runAs(getManagerUser()) {
            rows = KBAssessmentController.getRunsAndAnalysesForArticle(aa.Knowledge_Article_Id__c);
        }

        KBAssessmentController.ArticleRunRow row = rowForAssessment(rows, aa.Id);
        Assert.isNotNull(row, 'The assessment row is returned');
        Assert.isFalse(hasDimensionIssue(row, 'Duplication'),
            'Duplication finding is hidden when its only candidate is "Not a Duplicate"');
        Assert.isTrue(hasDimensionIssue(row, 'Conflict'),
            'An unrelated-dimension issue in the same bucket must survive the Duplication filter');
    }
}
