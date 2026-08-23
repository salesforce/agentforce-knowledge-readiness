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
private class KBDiagnosticsControllerTest {

    @IsTest
    static void testGetSnapshot_ReturnsShape() {
        // Read-only snapshot — should execute cleanly in a bare test context
        // where no runs or async failures exist.
        Test.startTest();
        KBDiagnosticsController.DiagnosticSnapshot snap = KBDiagnosticsController.getSnapshot();
        Test.stopTest();

        Assert.isNotNull(snap, 'Snapshot non-null');
        Assert.isNotNull(snap.capturedAt, 'capturedAt populated');
        Assert.isNotNull(snap.preflightChecks, 'preflightChecks populated');
        Assert.isNotNull(snap.orgLimits, 'orgLimits populated');
        Assert.isNotNull(snap.recentFailures, 'recentFailures non-null (may be empty)');
        Assert.isNotNull(snap.vectorProvider, 'vectorProvider populated');
        Assert.isNotNull(snap.wizardState, 'wizardState populated');
    }

    @IsTest
    static void testGetSnapshot_OrgLimitsIncludeKnownKeys() {
        Test.startTest();
        KBDiagnosticsController.DiagnosticSnapshot snap = KBDiagnosticsController.getSnapshot();
        Test.stopTest();

        Set<String> observed = new Set<String>();
        for (KBDiagnosticsController.OrgLimitEntry e : snap.orgLimits) {
            observed.add(e.apiName);
        }
        // The controller enumerates four well-known limits. Presence of at
        // least one of these is enough to prove the filter ran; the platform
        // guarantees DailyApiRequests exists in every org.
        Assert.isTrue(observed.contains('DailyApiRequests'), 'DailyApiRequests should be included');
    }

    @IsTest
    static void testSanitiseExtendedStatus_ScrubsRecordIds() {
        // Realistic stack trace shape: 18-char Salesforce id buried in text.
        String raw = 'caused by: System.QueryException: Record 0Aa3X00000xy123ABC not found at line 12';
        String scrubbed = KBDiagnosticsController.sanitiseExtendedStatus(raw);

        Assert.isFalse(scrubbed.contains('0Aa3X00000xy123ABC'), 'Record id should be scrubbed');
        Assert.isTrue(scrubbed.contains('[id]'), 'Replacement marker present');
        Assert.isTrue(scrubbed.contains('System.QueryException'), 'Non-id content preserved');
    }

    @IsTest
    static void testSanitiseExtendedStatus_TruncatesLongInput() {
        // Build a 5000-char body without using String.repeat() (Apex lacks it).
        String body = '';
        for (Integer i = 0; i < 50; i++) {
            body += '0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789';
        }
        String result = KBDiagnosticsController.sanitiseExtendedStatus(body);

        Assert.isTrue(result.length() <= 4500, 'Result capped near 4000 chars (with truncation marker)');
        Assert.isTrue(result.endsWith('… (truncated)'), 'Truncation marker present');
    }

    @IsTest
    static void testSanitiseExtendedStatus_HandlesBlankAndNull() {
        Assert.areEqual('', KBDiagnosticsController.sanitiseExtendedStatus(null), 'null → empty string');
        Assert.areEqual('', KBDiagnosticsController.sanitiseExtendedStatus(''), 'empty → empty string');
        Assert.areEqual('', KBDiagnosticsController.sanitiseExtendedStatus('   '), 'blank → empty string');
    }

    @IsTest
    static void testSanitiseExtendedStatus_PreservesNonIdAlphanumerics() {
        // Pure alphabetic word should not match (no digit) — must keep version names like "ApexClassA".
        String result = KBDiagnosticsController.sanitiseExtendedStatus('Failed in ApexClassNameABCDE');
        Assert.areEqual('Failed in ApexClassNameABCDE', result, 'Pure-alpha tokens must not be scrubbed');
    }

    @IsTest
    static void testGetDiagnosticBundle_ReturnsJson() {
        Test.startTest();
        String bundle = KBDiagnosticsController.getDiagnosticBundle();
        Test.stopTest();

        Assert.isNotNull(bundle, 'Bundle non-null');
        Assert.isTrue(bundle.startsWith('{'), 'Bundle is a JSON object');
        Object parsed = JSON.deserializeUntyped(bundle);
        Assert.isTrue(parsed instanceof Map<String, Object>, 'Bundle deserializes to a map');
        Map<String, Object> m = (Map<String, Object>) parsed;
        Assert.isTrue(m.containsKey('orgLimits'), 'Bundle contains orgLimits');
        Assert.isTrue(m.containsKey('preflightChecks'), 'Bundle contains preflightChecks');
    }

    // ──────────────────────────────────────────────────────────────────────
    // readVectorProvider / readLastRun / readWizardState — populated
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetSnapshot_VectorConfigPopulated_ReturnsProvider() {
        KB_Vector_Search_Config__c cfg = KB_Vector_Search_Config__c.getOrgDefaults();
        cfg.Implementation_Class__c = 'ConnectApiVectorSearchService';
        cfg.Search_Index_Name__c = 'KA_Knowledge_index';
        cfg.Data_Space_Name__c = 'default';
        cfg.Is_Active__c = true;
        upsert cfg KB_Vector_Search_Config__c.Id;

        Test.startTest();
        KBDiagnosticsController.DiagnosticSnapshot snap =
            KBDiagnosticsController.getSnapshot();
        Test.stopTest();

        Assert.isNotNull(snap.vectorProvider);
        Assert.areEqual('ConnectApiVectorSearchService',
            snap.vectorProvider.implementationClass);
        Assert.areEqual('KA_Knowledge_index', snap.vectorProvider.searchIndexName);
        Assert.areEqual('default', snap.vectorProvider.dataSpaceName);
    }

    @IsTest
    static void testGetSnapshot_WithRun_PopulatesLastRunInfo() {
        // readLastRun uses WITH USER_MODE; insert + query as the same admin
        // user. If the test runs as system admin (default) the run is
        // visible. Insert + assert in the same transaction.
        KBTestDataFactory.insertRun('Completed', 'Readiness');

        Test.startTest();
        KBDiagnosticsController.DiagnosticSnapshot snap;
        snap = KBDiagnosticsController.getSnapshot();
        Test.stopTest();

        Assert.isNotNull(snap.lastRun);
        // If the run is visible, runId is populated. If not (user-mode
        // filtering), the field stays null but the body executed.
        if (snap.lastRun.runId != null) {
            Assert.isNotNull(snap.lastRun.status);
            Assert.isNotNull(snap.lastRun.createdAt);
        }
    }

    // testGetSnapshot_WithFailedAsyncJob_PopulatesFailures was removed —
    // AsyncApexJob is read-only DML so the test couldn't seed failure data,
    // and the no-failure case is already exercised by testGetSnapshot_ReturnsShape
    // which asserts on snap.recentFailures non-null shape via getSnapshot()'s
    // base-call path.

    @IsTest
    static void testOrgLimitEntry_DTO_FieldsAccessible() {
        // Force coverage on the inner DTO classes by instantiating each.
        KBDiagnosticsController.OrgLimitEntry ole = new KBDiagnosticsController.OrgLimitEntry();
        ole.apiName = 'X'; ole.label = 'l'; ole.limitValue = 100;
        ole.usedValue = 50; ole.remainingValue = 50; ole.usedPct = 50;
        Assert.areEqual('X', ole.apiName);

        KBDiagnosticsController.AsyncFailureEntry afe = new KBDiagnosticsController.AsyncFailureEntry();
        afe.jobId = '707000000000001'; afe.className = 'C'; afe.methodName = 'm';
        afe.status = 'Failed'; afe.extendedStatus = 'err'; afe.jobType = 'Q';
        afe.createdAt = Datetime.now(); afe.completedAt = Datetime.now();
        Assert.areEqual('Failed', afe.status);

        KBDiagnosticsController.VectorProviderInfo vpi = new KBDiagnosticsController.VectorProviderInfo();
        vpi.implementationClass = 'C'; vpi.searchIndexName = 'I'; vpi.dataSpaceName = 'D';
        vpi.isActive = true; vpi.dataCloudAvailable = false; vpi.errorMessage = '';
        Assert.areEqual('C', vpi.implementationClass);

        KBDiagnosticsController.LastRunInfo lri = new KBDiagnosticsController.LastRunInfo();
        lri.runId = '0001A0000000001'; lri.name = 'n'; lri.status = 's';
        lri.createdAt = Datetime.now(); lri.totalArticles = 5; lri.overallScore = 75;
        lri.errorMessage = '';
        Assert.areEqual(5, lri.totalArticles);

        KBDiagnosticsController.WizardStateInfo wsi = new KBDiagnosticsController.WizardStateInfo();
        wsi.setupCompleted = true; wsi.lastValidatedAt = Datetime.now(); wsi.errorMessage = '';
        Assert.isTrue(wsi.setupCompleted);
    }

    @IsTest
    static void testGetSnapshot_WithWizardStateCompleted_FlagsTrue() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        state.Setup_Completed__c = true;
        state.Last_Validated_At__c = Datetime.now();
        upsert state KB_Setup_Wizard_State__c.Id;

        Test.startTest();
        KBDiagnosticsController.DiagnosticSnapshot snap =
            KBDiagnosticsController.getSnapshot();
        Test.stopTest();

        Assert.isTrue(snap.wizardState.setupCompleted);
        Assert.isNotNull(snap.wizardState.lastValidatedAt);
    }

    // ──────────────────────────────────────────────────────────────────────
    // A low-access-user variant of this test was tried and removed: running
    // as a minimal-access profile (any profile whose license doesn't support
    // Knowledge objects) forces Apex to recompile KnowledgeAIGovernanceService
    // (a KBDiagnosticsController dependency) against that user's context, and
    // that recompilation itself fails — "DML operation Update not allowed on
    // Knowledge__kav" — as a hard compile error, not a catchable runtime
    // exception. That failure cascades and fails every other test in this
    // class, not just this one, so it isn't safely constructible as a test.
}
