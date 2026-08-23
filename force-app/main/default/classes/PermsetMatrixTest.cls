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
private class PermsetMatrixTest {

    @TestSetup
    static void setup() {
        // Use the deliberately-blank-slate KB Minimum Access profile so that
        // the only object-level permissions the test users have come from
        // the permset under test. Falling back to Standard User leaks profile
        // permissions into the matrix and causes false positives on Viewer.
        List<Profile> minimal = [SELECT Id FROM Profile WHERE Name = 'KB Minimum Access' LIMIT 1];
        Profile stdProfile = minimal.isEmpty()
            ? [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1]
            : minimal[0];
        String ts = String.valueOf(System.currentTimeMillis());

        List<User> users = new List<User>{
            new User(FirstName='KB', LastName='SetupAdmin', Email='s@t.com', Username='kb.setup.pmt'+ts+'@test.invalid',
                     Alias='kbs'+ts.right(4), ProfileId=stdProfile.Id, EmailEncodingKey='UTF-8',
                     LanguageLocaleKey='en_US', LocaleSidKey='en_US', TimeZoneSidKey='America/Los_Angeles'),
            new User(FirstName='KB', LastName='Manager', Email='a@t.com', Username='kb.manager.pmt'+ts+'@test.invalid',
                     Alias='kbm'+ts.right(4), ProfileId=stdProfile.Id, EmailEncodingKey='UTF-8',
                     LanguageLocaleKey='en_US', LocaleSidKey='en_US', TimeZoneSidKey='America/Los_Angeles'),
            new User(FirstName='KB', LastName='Viewer', Email='v@t.com', Username='kb.viewer.pmt'+ts+'@test.invalid',
                     Alias='kbv'+ts.right(4), ProfileId=stdProfile.Id, EmailEncodingKey='UTF-8',
                     LanguageLocaleKey='en_US', LocaleSidKey='en_US', TimeZoneSidKey='America/Los_Angeles')
        };
        insert users;

        PermissionSet psSetup = [SELECT Id FROM PermissionSet WHERE Name='KB_Assessment_Setup_Admin' LIMIT 1];
        PermissionSet psManager = [SELECT Id FROM PermissionSet WHERE Name='KB_Assessment_Admin' LIMIT 1];
        PermissionSet psViewer = [SELECT Id FROM PermissionSet WHERE Name='KB_Assessment_Viewer' LIMIT 1];

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId=users[0].Id, PermissionSetId=psSetup.Id),
            new PermissionSetAssignment(AssigneeId=users[1].Id, PermissionSetId=psManager.Id),
            new PermissionSetAssignment(AssigneeId=users[2].Id, PermissionSetId=psViewer.Id)
        };
    }

    static User getUser(String lastName) {
        return [SELECT Id FROM User WHERE LastName = :lastName AND Username LIKE 'kb.%pmt%@test.invalid' LIMIT 1];
    }

 // ─── Setup Admin: config-only, NO runtime data access ──────────────

    @IsTest static void setupAdmin_CannotAccessRuns() {
 // least-privilege: Setup Admin is scoped to the setup screen + config
        // custom settings only. It must NOT have create/read on runtime data.
        System.runAs(getUser('SetupAdmin')) {
            Assert.isFalse(
                Schema.SObjectType.KB_Assessment_Run__c.isCreateable(),
                'Setup Admin must not create runs (config-only role)');
            Assert.isFalse(
                Schema.SObjectType.KB_Assessment_Run__c.isAccessible(),
                'Setup Admin must not read runs (config-only role)');
        }
    }

    @IsTest static void setupAdmin_CannotAccessCandidates() {
        System.runAs(getUser('SetupAdmin')) {
            Assert.isFalse(
                Schema.SObjectType.Duplicate_Candidate__c.isAccessible(),
                'Setup Admin must not read duplicate candidates (config-only role)');
        }
    }

    // ─── Manager (ex-Admin): full CRED on runtime data, no View All / Modify All ─

    @IsTest static void manager_CanCreateRun() {
        System.runAs(getUser('Manager')) {
            KB_Assessment_Run__c r = new KB_Assessment_Run__c(Status__c='In Progress', Total_Articles__c=0);
            insert r;
            Assert.isNotNull(r.Id);
        }
    }

    @IsTest static void manager_CanDeleteOwnRun() {
 // Manager now holds Delete on runs (was denied pre-). The runner
        // owns and can clean up their own runs (rerun/clone/delete).
        System.runAs(getUser('Manager')) {
            KB_Assessment_Run__c r = new KB_Assessment_Run__c(Status__c='Completed', Total_Articles__c=0);
            insert r;
            delete r;
            Assert.areEqual(0, [SELECT COUNT() FROM KB_Assessment_Run__c WHERE Id=:r.Id],
                'Manager should be able to delete its own run');
        }
    }

    @IsTest static void manager_CanEditDuplicateStatus() {
 // Candidates are master-detail to the run: the Manager owns the run
        // it creates, so it can insert + re-status the candidate under it.
        System.runAs(getUser('Manager')) {
            KB_Assessment_Run__c run = new KB_Assessment_Run__c(Status__c='Completed', Total_Articles__c=1);
            insert run;
            Duplicate_Candidate__c dc = new Duplicate_Candidate__c(
                Assessment_Run__c=run.Id,
                Knowledge_Article_1__c='ka0FAKE000000001', Knowledge_Article_2__c='ka0FAKE000000002',
                Composite_Key__c='pmt_test_key', Confidence_Score__c=90, Flag_Type__c='Duplicate', Status__c='Pending'
            );
            insert dc;
            dc.Status__c = 'Rejected';
            update dc;
            Assert.areEqual('Rejected', [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id=:dc.Id].Status__c);
        }
    }

    @IsTest static void manager_CanResolveContradiction() {
 // regression gate: resolveContradiction does USER_MODE DML
        // (`update as user` on Duplicate_Candidate__c + `insert as user` on
        // KB_Dimension_Analysis__c). It previously failed for EVERY Manager because
        // the update carried read-only display fields and the analysis insert wrote
        // read-only Recommendation__c. This test runs the flow AS a Manager so the
        // FLS is actually enforced — it fails pre-fix, passes after the narrowed
        // update + the permset FLS grant. Setup uses plain DML (skips FLS even under
        // runAs); only the controller's `as user` DML is the thing under test.
        //
        // Knowledge is seeded in system context — Manager holds Knowledge read-only
 // (post-) and lacks the write license, so it can't insert KAV rows.
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'pmt-contra');

        System.runAs(getUser('Manager')) {
            KB_Assessment_Run__c run = new KB_Assessment_Run__c(
                Status__c='Completed', Total_Articles__c=2);
            insert run;

            Duplicate_Candidate__c dc = new Duplicate_Candidate__c(
                Assessment_Run__c=run.Id,
                Knowledge_Article_1__c=arts[0].Id, Knowledge_Article_2__c=arts[1].Id,
                Composite_Key__c='pmt_contra_key', Confidence_Score__c=88,
                Flag_Type__c='Contradiction', Status__c='Pending',
                AI_Reasoning__c='Conflicting steps stated'
            );
            insert dc;

            // Assessments + Conflict dimension results so findConflictTarget resolves
            // (the recommendation row is master-detail on the Conflict result).
            KB_Article_Assessment__c aa1 = new KB_Article_Assessment__c(
                Assessment_Run__c=run.Id, Knowledge__c=arts[0].Id,
                Knowledge_Article_Id__c=String.valueOf(arts[0].Id),
                Article_Title__c='A', Overall_Score__c=70, Readiness_Status__c='Ready');
            KB_Article_Assessment__c aa2 = new KB_Article_Assessment__c(
                Assessment_Run__c=run.Id, Knowledge__c=arts[1].Id,
                Knowledge_Article_Id__c=String.valueOf(arts[1].Id),
                Article_Title__c='B', Overall_Score__c=70, Readiness_Status__c='Ready');
            insert new List<KB_Article_Assessment__c>{ aa1, aa2 };
            insert new List<KB_Dimension_Result__c>{
                new KB_Dimension_Result__c(Article_Assessment__c=aa1.Id, Dimension__c='Conflict', Score__c=80),
                new KB_Dimension_Result__c(Article_Assessment__c=aa2.Id, Dimension__c='Conflict', Score__c=80)
            };

            Test.startTest();
            // Article A correct → a Conflict recommendation is written on B (the incorrect one).
            DuplicateCandidateController.resolveContradiction(dc.Id, arts[0].Id, 'article_a_correct');
            Test.stopTest();

            Assert.areEqual('Resolved',
                [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id=:dc.Id].Status__c,
                'Manager must resolve the contradiction (narrowed USER_MODE update must pass)');
            List<KB_Dimension_Analysis__c> recs = [
                SELECT Id, Recommendation__c FROM KB_Dimension_Analysis__c
                WHERE Type__c='Issue' AND Dimension__c='Conflict'];
            Assert.areEqual(1, recs.size(),
                'One conflict recommendation created (USER_MODE insert must pass under Manager FLS)');
            Assert.isTrue(String.isNotBlank(recs[0].Recommendation__c),
                'Recommendation text must be written (Recommendation__c FLS-edit granted)');
        }
    }

    // ─── Viewer: read-only, oversight (keeps View All) ────────────────────────

    @IsTest static void viewer_CanReadRunAndScores() {
        // Seed as the test's system context (no runAs) — Setup Admin no longer has
        // run access, and Viewer keeps View All so it sees any run.
        KB_Assessment_Run__c r = new KB_Assessment_Run__c(
            Status__c='Completed', Total_Articles__c=1, Overall_Score__c=72);
        insert r;
        System.runAs(getUser('Viewer')) {
            KB_Assessment_Run__c fetched = [SELECT Status__c, Overall_Score__c FROM KB_Assessment_Run__c WHERE Id=:r.Id];
            Assert.areEqual(72, fetched.Overall_Score__c);
        }
    }

    @IsTest static void viewer_CannotCreateRun() {
        // Check FLS/CRUD via Schema rather than DML so the assertion is
        // deterministic regardless of the underlying profile/license
        // implicit grants. The KB_Assessment_Viewer permset must NOT grant
        // create on KB_Assessment_Run__c — anything else is misconfiguration.
        System.runAs(getUser('Viewer')) {
            Assert.isFalse(
                Schema.SObjectType.KB_Assessment_Run__c.isCreateable(),
                'Viewer permset must not grant create on KB_Assessment_Run__c'
            );
        }
    }

    @IsTest static void viewer_CannotAccessCandidates() {
        // Viewer has no object access to the candidate objects at all.
        System.runAs(getUser('Viewer')) {
            Assert.isFalse(
                Schema.SObjectType.Duplicate_Candidate__c.isAccessible(),
                'Viewer must have no access to duplicate candidates');
        }
    }
}
