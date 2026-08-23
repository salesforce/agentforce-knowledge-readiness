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
 * Coverage for KBAssessmentService.cancelAssessmentRun and the supporting
 * helpers (recordAsyncJob, isCancelled)..
 *
 * Each test exercises a real KB_Assessment_Run__c row so the FOR UPDATE
 * lock + audit-stamp DML actually fires. The abortJob loop is deliberately
 * fed a synthetic id that does not correspond to a live AsyncApexJob — the
 * service is required to swallow that and continue.
 */
@IsTest
private class KBAssessmentServiceCancelTest {

    private static KB_Assessment_Run__c freshRun(String status) {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = status,
            Total_Articles__c = 0,
            Used_LLM__c = false,
            Assessment_Types__c = 'Readiness'
        );
        insert run;
        return run;
    }

    private static KB_Assessment_Run__c reload(Id runId) {
        return [
            SELECT Id, Status__c, Status_Message__c, Cancellation_Requested_At__c,
                   Cancelled_By__c, Completed_At__c, Async_Job_Ids__c, Pipeline_Run__c
            FROM KB_Assessment_Run__c
            WHERE Id = :runId
        ];
    }

    @IsTest
    static void cancel_FlipsStatusAndStampsAuditFields() {
        KB_Assessment_Run__c run = freshRun('In Progress');

        Test.startTest();
        KBAssessmentService.cancelAssessmentRun(run.Id);
        Test.stopTest();

        KB_Assessment_Run__c after = reload(run.Id);
        Assert.areEqual('Cancelled', after.Status__c, 'Status flips to Cancelled');
        Assert.areEqual(UserInfo.getUserId(), after.Cancelled_By__c, 'Cancelled_By__c records the caller');
        Assert.isNotNull(after.Cancellation_Requested_At__c, 'Cancellation_Requested_At__c stamped');
        Assert.isNotNull(after.Completed_At__c, 'Completed_At__c stamped');
        Assert.isTrue(
            String.isNotBlank(after.Status_Message__c) && after.Status_Message__c.startsWith('Cancelled by '),
            'Status_Message__c carries cancel reason; saw: ' + after.Status_Message__c
        );
    }

    @IsTest
    static void cancel_IsIdempotentOnTerminalStates() {
        // Build one run per terminal status and insert them in bulk (no DML in
        // the loop). Status_Message__c is seeded on insert, so no follow-up update.
        List<String> terminals = new List<String>{ 'Completed', 'Failed', 'Cancelled' };
        List<KB_Assessment_Run__c> runs = new List<KB_Assessment_Run__c>();
        for (String terminal : terminals) {
            runs.add(new KB_Assessment_Run__c(
                Status__c = terminal,
                Total_Articles__c = 0,
                Used_LLM__c = false,
                Assessment_Types__c = 'Readiness',
                Status_Message__c = 'pre-existing reason'
            ));
        }
        insert runs;
        Map<String, Id> idsByTerminal = new Map<String, Id>();
        for (Integer i = 0; i < terminals.size(); i++) {
            idsByTerminal.put(terminals[i], runs[i].Id);
        }

        Test.startTest();
        for (Id runId : idsByTerminal.values()) {
            KBAssessmentService.cancelAssessmentRun(runId);
        }
        Test.stopTest();

        for (String terminal : idsByTerminal.keySet()) {
            KB_Assessment_Run__c after = reload(idsByTerminal.get(terminal));
            Assert.areEqual(terminal, after.Status__c,
                'cancelAssessmentRun is a no-op when status is already ' + terminal);
            Assert.areEqual('pre-existing reason', after.Status_Message__c,
                'Status_Message__c not overwritten on idempotent cancel');
        }
    }

    @IsTest
    static void cancel_NullRunId_Throws() {
        Test.startTest();
        try {
            KBAssessmentService.cancelAssessmentRun(null);
            Assert.fail('Null run id must throw');
        } catch (IllegalArgumentException expected) {
            Assert.isTrue(String.isNotBlank(expected.getMessage()), 'Error message present');
        }
        Test.stopTest();
    }

    @IsTest
    static void cancel_AbortJobLoop_SwallowsMissingJobIds() {
        KB_Assessment_Run__c run = freshRun('In Progress');
        // Synthetic AsyncApexJob ids — abortJob will throw "Invalid id" /
        // similar; the service is required to swallow each and continue.
        // Use a fake but well-formed Id by appending a non-existent suffix.
        run.Async_Job_Ids__c = '707000000000000AAA,707000000000000BBB';
        update run;

        Test.startTest();
        // Must not throw despite both ids being non-existent.
        KBAssessmentService.cancelAssessmentRun(run.Id);
        Test.stopTest();

        KB_Assessment_Run__c after = reload(run.Id);
        Assert.areEqual('Cancelled', after.Status__c,
            'Cancel completes even when every captured job id fails to abort');
    }

    @IsTest
    static void cancel_LinkedPipelineRun_FlippedToCancelled() {
        KB_Pipeline_Run__c pr = new KB_Pipeline_Run__c(
            Status__c = 'Running',
            Execution_Modes__c = 'Deduplication'
        );
        insert pr;
        KB_Assessment_Run__c run = freshRun('Pipeline Running');
        run.Pipeline_Run__c = pr.Id;
        update run;

        Test.startTest();
        KBAssessmentService.cancelAssessmentRun(run.Id);
        Test.stopTest();

        KB_Pipeline_Run__c afterPr = [SELECT Status__c FROM KB_Pipeline_Run__c WHERE Id = :pr.Id];
        Assert.areEqual('Cancelled', afterPr.Status__c,
            'Linked pipeline run is also flipped to Cancelled');
    }

    @IsTest
    static void isCancelled_TrueOnlyForCancelledStatus() {
        KB_Assessment_Run__c notCancelled = freshRun('In Progress');
        KB_Assessment_Run__c cancelled = freshRun('Cancelled');

        Assert.isFalse(KBAssessmentService.isCancelled(notCancelled.Id),
            'isCancelled false for In Progress');
        Assert.isTrue(KBAssessmentService.isCancelled(cancelled.Id),
            'isCancelled true for Cancelled');
        Assert.isFalse(KBAssessmentService.isCancelled(null),
            'isCancelled false for null id');
    }

    @IsTest
    static void recordAsyncJob_AppendsToAsyncJobIds() {
        KB_Assessment_Run__c run = freshRun('In Progress');
 // use literal AsyncApexJob-shaped ids (707 prefix). The
        // earlier test used UserInfo.getUserId() (005 prefix) which round-
        // tripped fine because the service doesn't validate the prefix —
        // but if a future change ever does add a prefix check, this test
        // catches it. The two ids are different so the dedup-by-text logic
        // can't collapse them.
        Id firstJob  = '707000000000000AAA';
        Id secondJob = '707000000000000BBB';

        Test.startTest();
        KBAssessmentService.recordAsyncJob(run.Id, firstJob);
        KBAssessmentService.recordAsyncJob(run.Id, secondJob);
        Test.stopTest();

        KB_Assessment_Run__c after = reload(run.Id);
        Assert.isNotNull(after.Async_Job_Ids__c, 'Async_Job_Ids__c populated');
        List<String> recorded = after.Async_Job_Ids__c.split(',');
        Assert.areEqual(2, recorded.size(), 'Both ids appended (comma-separated)');
        Assert.isTrue(after.Async_Job_Ids__c.contains(String.valueOf(firstJob)),
            'First job id present');
        Assert.isTrue(after.Async_Job_Ids__c.contains(String.valueOf(secondJob)),
            'Second job id present');
    }

    @IsTest
    static void recordAsyncJob_DropsOldestWhenOverFieldLength() {
 // truncation must drop whole entries off the front, not
        // slice through one. Pre-stuff the field above the cap, then call
        // recordAsyncJob once — the next write should drop oldest entries
        // until the result fits and every surviving entry is a whole 18-char id.
        KB_Assessment_Run__c run = freshRun('In Progress');
        Integer cap = Schema.SObjectType.KB_Assessment_Run__c
            .fields.Async_Job_Ids__c.getLength();

        // Build a CSV that already sits at the cap with whole 18-char strings.
        // The service reads the existing CSV as text (no Id parsing), so the
        // seeds don't need to satisfy the Id checksum. 19 chars per entry
        // (18 + comma); cap/19 = ~215 entries.
        List<String> seedIds = new List<String>();
        Integer seedCount = cap / 19;
        for (Integer i = 0; i < seedCount; i++) {
            String suffix = String.valueOf(i).leftPad(15, '0');
            seedIds.add(('707' + suffix).left(18));
        }
        run.Async_Job_Ids__c = String.join(seedIds, ',');
        update run;

        // The newly appended id MUST be a real well-formed Id (Apex's Id
        // type validates the 18-char checksum). UserInfo.getUserId() is the
        // cheapest source of one.
        Id newJobId = UserInfo.getUserId();

        Test.startTest();
        KBAssessmentService.recordAsyncJob(run.Id, newJobId);
        Test.stopTest();

        KB_Assessment_Run__c after = reload(run.Id);
        Assert.isTrue(after.Async_Job_Ids__c.length() <= cap,
            'Stored value must not exceed field length; saw ' + after.Async_Job_Ids__c.length());
        for (String entry : after.Async_Job_Ids__c.split(',')) {
            Assert.areEqual(18, entry.length(),
                'Every retained entry must be a whole 18-char id (no mid-id slice); saw "' + entry + '"');
        }
        // Newest id must survive — the drop-oldest loop trims off the front,
        // never the back.
        Assert.isTrue(after.Async_Job_Ids__c.endsWith(String.valueOf(newJobId)),
            'Newest id must be preserved; saw end="' + after.Async_Job_Ids__c.right(20) + '"');
    }

    // ──────────────────────────────────────────────────────────────────────
 // CRUD/FLS enforcement (feedback)
    //
    // KBAssessmentService.cancelAssessmentRun uses `update as user`, so a
    // Viewer (read-only on KB_Assessment_Run__c + the cancellation fields)
    // must bounce off DML rather than silently mutating the run. The Admin
    // path is exercised everywhere else but we lock it in explicitly here
    // to guard against a future change accidentally tightening too far.
    // ──────────────────────────────────────────────────────────────────────

    /**
     * Build a User on the KB Minimum Access profile (or Standard User
     * fallback) with the KB_Assessment_Viewer permset assigned. Inline
     * because KBTestDataFactory.createManagerUser hardcodes the wrong
     * permset for our purposes.
     */
    private static User createViewerUser(String aliasSuffix) {
        List<Profile> minimal = [
            SELECT Id FROM Profile WHERE Name = 'KB Minimum Access' LIMIT 1
        ];
        Id profileId = minimal.isEmpty()
            ? [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id
            : minimal[0].Id;

        User u = new User(
            FirstName = 'KB',
            LastName = 'Viewer_' + aliasSuffix,
            Email = 'kbviewer_' + aliasSuffix + '@kbtest.invalid',
            Username = 'kbviewer_' + aliasSuffix + '@kbtest.invalid',
            Alias = ('kbv' + aliasSuffix).left(8),
            ProfileId = profileId,
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles'
        );
        insert u;

        PermissionSet ps = [
            SELECT Id FROM PermissionSet WHERE Name = 'KB_Assessment_Viewer' LIMIT 1
        ];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
        return u;
    }

    @IsTest
    static void cancel_AsViewer_ThrowsInsufficientAccess() {
        // PermissionSetAssignment is a setup object; KB_Assessment_Run__c is
        // not. Mixing the two DML categories in the same transaction throws
        // MIXED_DML_OPERATION. Isolate the user/permset insert inside a
        // System.runAs block so the setup DML lands cleanly.
        User viewer;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            viewer = createViewerUser('cancel');
        }
        KB_Assessment_Run__c run = freshRun('In Progress');

        Boolean threw = false;
        Test.startTest();
        System.runAs(viewer) {
            try {
                KBAssessmentService.cancelAssessmentRun(run.Id);
            } catch (Exception e) {
                // Either DmlException (FIELD_INTEGRITY / INSUFFICIENT_ACCESS)
                // or a wrapping exception is acceptable — the contract is
                // "Viewer cannot cancel", not a specific exception type.
                threw = true;
            }
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Viewer cancel must throw, not silently succeed');
        KB_Assessment_Run__c after = reload(run.Id);
        Assert.areEqual('In Progress', after.Status__c,
            'Run status must be unchanged when Viewer cancel is denied');
        Assert.isNull(after.Cancelled_By__c,
            'Cancelled_By__c must remain null on denied cancel');
    }

    @IsTest
    static void cancel_AsAdmin_StillSucceeds() {
        // Sanity: the existing happy path must still work after the
        // `update as user` switch — Admin has edit, so DML succeeds.
        KB_Assessment_Run__c run = freshRun('In Progress');

        Test.startTest();
        // Default running user (the test orchestrator) is a System
        // Administrator-equivalent on the test runtime — has edit on
        // KB_Assessment_Run__c.* by default.
        KBAssessmentService.cancelAssessmentRun(run.Id);
        Test.stopTest();

        KB_Assessment_Run__c after = reload(run.Id);
        Assert.areEqual('Cancelled', after.Status__c,
            'Admin cancel still succeeds under update as user');
        Assert.areEqual(UserInfo.getUserId(), after.Cancelled_By__c);
    }

    // ──────────────────────────────────────────────────────────────────────
 // Linked-pipeline-run cascade resilience
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void cancel_LinkedPipelineRunDeletedMidFlight_DoesNotThrow() {
        // The cascade `update as user new KB_Pipeline_Run__c(Id = ...)` is
        // wrapped in try/catch so a deleted/missing pipeline run row can't
        // crash the cancel path. Reproduce by deleting the pipeline run
        // before calling cancel, then assert the assessment run still flips
        // to Cancelled and the call returns normally (no DmlException).
        KB_Pipeline_Run__c pr = new KB_Pipeline_Run__c(
            Status__c = 'Running',
            Execution_Modes__c = 'Deduplication'
        );
        insert pr;
        KB_Assessment_Run__c run = freshRun('Pipeline Running');
        run.Pipeline_Run__c = pr.Id;
        update run;

        // Delete the pipeline run row so the cascade UPDATE references a
        // non-existent record. The catch in cancelAssessmentRun should
        // swallow the resulting DmlException.
        delete pr;

        Test.startTest();
        KBAssessmentService.cancelAssessmentRun(run.Id);
        Test.stopTest();

        KB_Assessment_Run__c after = reload(run.Id);
        Assert.areEqual('Cancelled', after.Status__c,
            'Run still flips to Cancelled even when the linked pipeline run cascade fails');
    }

    // ──────────────────────────────────────────────────────────────────────
 // canCancel flag
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void mapRunToRunResult_AsAdmin_CanCancelTrue() {
        // The test runtime always runs as System Administrator unless we
        // System.runAs into another user, so isUpdateable() returns true
        // here. Locks the contract that AssessmentRunResult.canCancel
        // surfaces the FLS verdict — Admin sees the button.
        KB_Assessment_Run__c run = freshRun('In Progress');

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result =
            KBAssessmentController.checkRunStatus(String.valueOf(run.Id));
        Test.stopTest();

        Assert.isTrue(result.canCancel,
            'Admin (full FLS on Status__c) gets canCancel=true');
    }
}
