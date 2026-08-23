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
 * Shared @IsTest data builders for the KB package test suite.
 *
 * Centralises the small handful of record shapes that 5+ test classes were
 * about to duplicate inline (Knowledge__kav drafts, KB_Assessment_Run__c,
 * KB_Pipeline_Run__c, Duplicate_Candidate__c, Enrichment_Candidate__c, etc).
 * Pure DML — no behavioural logic — so it doesn't need its own *Test class.
 *
 * Mirrors the existing inline patterns in KBAssessmentControllerTest and
 * Tier4ConsolidationActionTest. Add a builder here only when ≥2 test classes
 * would otherwise duplicate the same shape.
 */
@IsTest
public class KBTestDataFactory {

    /**
     * Creates a User on the KB Minimum Access profile (falling back to
     * Standard User) and assigns the KB_Assessment_Admin (Manager) permset.
     *
     * Use with `System.runAs(...)` from any test that exercises @AuraEnabled
     * controller methods backed by `WITH USER_MODE` SOQL — the deploying
     * admin's profile may not carry FLS for KB custom fields, which causes
     * USER_MODE to return the misleading "No such column" error. Manager (not
 * Setup Admin) is the data-capable persona after the least-privilege
     * split — Setup Admin is config-only.
     *
     * The aliasSuffix keeps usernames unique across simultaneous test runs
     * within the same @TestSetup transaction.
     */
    public static User createManagerUser(String aliasSuffix) {
        return createUserWithPermset(aliasSuffix, 'KB_Assessment_Admin');
    }

    /**
     * Creates a User on the KB Minimum Access profile (falling back to
     * Standard User) and assigns the named permission set. The permset name is
     * the only thing that varies between the app's runtime personas, so this is
     * the single builder behind createManagerUser and any Viewer / Setup Admin
     * test user.
     *
     * Use with `System.runAs(...)` from a test that exercises USER_MODE SOQL:
     * the deploying admin's profile may not carry FLS for KB custom fields,
     * which makes USER_MODE return the misleading "No such column" error, so the
     * running user must be a real least-privilege persona rather than the admin.
     *
     * If the permset isn't deployed on the org, the user is still created but
     * unassigned — a dependent test then surfaces the real access failure.
     */
    public static User createUserWithPermset(String aliasSuffix, String permsetName) {
        Profile target;
        List<Profile> minimal = [
            SELECT Id FROM Profile WHERE Name = 'KB Minimum Access' LIMIT 1
        ];
        target = minimal.isEmpty()
            ? [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1]
            : minimal[0];

        User u = new User(
            FirstName = 'KB',
            LastName = 'TestUser_' + aliasSuffix,
            Email = 'kbtest_' + aliasSuffix + '@kbtest.invalid',
            Username = 'kbtest_' + aliasSuffix + '@kbtest.invalid',
            Alias = ('kbt' + aliasSuffix).left(8),
            ProfileId = target.Id,
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles'
        );
        insert u;

        try {
            PermissionSet ps = [
                SELECT Id FROM PermissionSet WHERE Name = :permsetName LIMIT 1
            ];
            insert new PermissionSetAssignment(
                AssigneeId = u.Id,
                PermissionSetId = ps.Id
            );
        } catch (QueryException ignored) {
            // Permset missing on the org — caller will surface the real
            // failure if FLS still blocks them.
        }
        return u;
    }

    public static KB_Assessment_Run__c insertRun(String status, String assessmentTypes) {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = status,
            Total_Articles__c = 5,
            Used_LLM__c = false,
            Assessment_Types__c = assessmentTypes
        );
        insert run;
        return run;
    }

    public static KB_Pipeline_Run__c insertPipelineRun(Id assessmentRunId, String mode, String status) {
        KB_Pipeline_Run__c pr = new KB_Pipeline_Run__c(
            Assessment_Run__c = assessmentRunId,
            Execution_Modes__c = mode,
            Status__c = status,
            Started_At__c = Datetime.now(),
            Total_Input_Articles__c = 0
        );
        insert pr;
        return pr;
    }

    /**
     * Inserts `count` minimally-valid Draft Knowledge__kav rows. Titles are
     * `<urlNamePrefix>-title-<i>` so tests can identify rows by index.
     */
    public static List<Knowledge__kav> insertArticles(Integer count, String urlNamePrefix) {
        List<Knowledge__kav> kavs = new List<Knowledge__kav>();
        for (Integer i = 0; i < count; i++) {
            kavs.add(new Knowledge__kav(
                Title = urlNamePrefix + '-title-' + i,
                UrlName = urlNamePrefix + '-' + i + '-' + System.currentTimeMillis(),
                Language = 'en_US',
                Summary = 'Summary for ' + urlNamePrefix + ' #' + i
            ));
        }
        insert kavs;
        return kavs;
    }

    public static Duplicate_Candidate__c insertDuplicateCandidate(
        Id articleA, Id articleB, String flagType, String status
    ) {
 // Duplicate_Candidate__c is master-detail to the run, so a parent
        // is required. Callers that don't care about the run get a throwaway one.
        return insertDuplicateCandidate(articleA, articleB, flagType, status, null);
    }

    public static Duplicate_Candidate__c insertDuplicateCandidate(
        Id articleA, Id articleB, String flagType, String status, Id assessmentRunId
    ) {
        Id runId = assessmentRunId != null
            ? assessmentRunId
            : insertRun('Completed', 'Readiness').Id;
        Duplicate_Candidate__c dc = new Duplicate_Candidate__c(
            Assessment_Run__c = runId,
            Knowledge_Article_1__c = String.valueOf(articleA),
            Knowledge_Article_2__c = String.valueOf(articleB),
            Composite_Key__c = KnowledgeAIGovernanceService.generateCompositeKey(articleA, articleB, runId),
            Flag_Type__c = flagType,
            Status__c = status,
            Confidence_Score__c = 80,
            Source_Tier__c = 'Tier4_Agentic',
            Score_Calculated_Date__c = Datetime.now()
        );
        insert dc;
        return dc;
    }

    public static Enrichment_Candidate__c insertEnrichmentCandidate(
        Id assessmentRunId, Id sourceArticleVersionId, String status, Boolean isClosed
    ) {
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Assessment_Run__c = assessmentRunId,
            Source_Article_Version_Id__c = String.valueOf(sourceArticleVersionId),
            Source_Article_Title__c = 'Source #' + sourceArticleVersionId,
            Composite_Key__c = String.valueOf(sourceArticleVersionId) + '-' + System.currentTimeMillis(),
            Status__c = status,
            Is_Closed__c = isClosed,
            Recommended_Action__c = 'Replace'
        );
        insert ec;
        return ec;
    }

    public static KB_Article_Assessment__c insertArticleAssessment(Id runId, Id articleVersionId) {
        // Knowledge_Article_Id__c is required and stores the parent
        // KnowledgeArticleId (master record), NOT the version Id. We look it
        // up via SOQL when articleVersionId is a real Knowledge__kav row.
        //
        // WARNING: when callers pass a placeholder/fake Id that doesn't
        // correspond to a real Knowledge__kav row, the SOQL throws
        // QueryException and we fall back to using the version Id itself.
        // The resulting row is malformed in that field, so any test that
        // *reads* Knowledge_Article_Id__c after calling the factory with a
        // fake id will see junk. Existing tests don't read the field; new
        // tests should pass a real version id from KBTestDataFactory.insertArticles.
        Id resolvedArticleIdField = articleVersionId;
        try {
            Knowledge__kav kav = [
                SELECT KnowledgeArticleId FROM Knowledge__kav
                WHERE Id = :articleVersionId LIMIT 1
            ];
            if (kav != null && kav.KnowledgeArticleId != null) {
                resolvedArticleIdField = kav.KnowledgeArticleId;
            }
        } catch (QueryException qe) {
            // Fake/placeholder version Id — fall through with the legacy
            // version-id-as-parent shape. See WARNING above.
        }

        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = runId,
            Knowledge__c = articleVersionId,
            Knowledge_Article_Id__c = String.valueOf(resolvedArticleIdField),
            Article_Title__c = 'Test Article',
            Overall_Score__c = 75,
            Readiness_Status__c = 'Ready'
        );
        insert aa;
        return aa;
    }
}
