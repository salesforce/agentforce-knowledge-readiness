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
 * Trampoline tests — verify the schedulable enqueues the callback queueable
 * when given a valid run id, and stays a no-op when given null.
 *
 * Test framing: System.schedule + Test.startTest/stopTest is the only way
 * to genuinely exercise SchedulableContext.getTriggerId() and the abortJob
 * call. Calling execute() directly with a stub context would short-circuit
 * the cron lifecycle.
 */
@IsTest
private class KBPipelineCallbackSchedulableTest {

    private static final String FUTURE_CRON = '0 0 0 1 1 ? 2099';

    @TestSetup
    static void setup() {
        KBTestDataFactory.insertRun('Completed', 'Readiness');
    }

    @IsTest
    static void testExecute_ValidRunId_EnqueuesCallback() {
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;

        Test.startTest();
        System.schedule(
            'KbCallbackTrampolineTest_Valid',
            FUTURE_CRON,
            new KBAssessmentPipelineCallbackSchedulable(runId)
        );
        Test.stopTest();

        Integer enqueuedCount = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            AND ApexClass.Name = 'KBAssessmentPipelineCallback'
        ];
        Assert.areEqual(1, enqueuedCount,
            'Trampoline enqueued KBAssessmentPipelineCallback exactly once');
    }

    @IsTest
    static void testExecute_NullRunId_DoesNotEnqueue() {
        Test.startTest();
        System.schedule(
            'KbCallbackTrampolineTest_Null',
            FUTURE_CRON,
            new KBAssessmentPipelineCallbackSchedulable(null)
        );
        Test.stopTest();

        Integer enqueuedCount = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            AND ApexClass.Name = 'KBAssessmentPipelineCallback'
        ];
        Assert.areEqual(0, enqueuedCount,
            'Null run id leaves the callback queueable un-enqueued');
    }

 // (review follow-up) — KBAssessmentPipelineCallback.updateRunStatus
    // now persists an optional Status_Message__c so the runner LWC's safety-net
    // poll can mirror the live Failed event's reason. Lock down the contract.

    @IsTest
    static void testUpdateRunStatus_Failed_PersistsStatusMessage() {
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;
        KBAssessmentPipelineCallback callback = new KBAssessmentPipelineCallback(runId);

        Test.startTest();
        callback.updateRunStatus('Failed', 'Pipeline callback error: simulated boom');
        Test.stopTest();

        KB_Assessment_Run__c persisted = [
            SELECT Status__c, Status_Message__c
            FROM KB_Assessment_Run__c
            WHERE Id = :runId
        ];
        Assert.areEqual('Failed', persisted.Status__c, 'Status flipped to Failed');
        Assert.areEqual('Pipeline callback error: simulated boom', persisted.Status_Message__c,
            'Status message round-tripped through updateRunStatus');
    }

    @IsTest
    static void testUpdateRunStatus_BlankMessage_LeavesStatusMessageNull() {
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;
        KBAssessmentPipelineCallback callback = new KBAssessmentPipelineCallback(runId);

        Test.startTest();
        // Blank/null message: status flips but Status_Message__c isn't written.
        // Successful runs (Completed) take this path so they don't carry a stale
        // failure reason from a re-used run record.
        callback.updateRunStatus('Completed', null);
        Test.stopTest();

        KB_Assessment_Run__c persisted = [
            SELECT Status__c, Status_Message__c
            FROM KB_Assessment_Run__c
            WHERE Id = :runId
        ];
        Assert.areEqual('Completed', persisted.Status__c);
        Assert.isNull(persisted.Status_Message__c,
            'Blank message must leave Status_Message__c null');
    }

    @IsTest
    static void testUpdateRunStatus_LongMessage_TruncatedTo1024() {
        Id runId = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1].Id;
        KBAssessmentPipelineCallback callback = new KBAssessmentPipelineCallback(runId);
        // Build a message over the 1024-char field length.
        String huge = 'X'.repeat(2000);

        Test.startTest();
        callback.updateRunStatus('Failed', huge);
        Test.stopTest();

        KB_Assessment_Run__c persisted = [
            SELECT Status_Message__c FROM KB_Assessment_Run__c WHERE Id = :runId
        ];
        Assert.areEqual(1024, persisted.Status_Message__c.length(),
            'Message truncated to field length');
    }
}
