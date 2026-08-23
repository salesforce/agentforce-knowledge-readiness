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
 * Coverage for KBSetupPreflightService. Surfaces 5 postflight checks on
 * Step 5 (Final Validation) of the wizard: dataCloudAvailable,
 * searchIndexConfigured, contentFieldsSelected, knowledgeArticlesExist,
 * bypassPermissionExists.
 *
 * Tests run runChecks() in several configuration scenarios so the
 * conditional branches (search-index configured, content fields selected,
 * setup completed flag) are all exercised.
 *
 * Calls the @TestVisible buildCheck overload directly to lock in
 * the severity-resolution rule (severity defaults to 'blocker' when
 * required=true, 'warning' otherwise — unless an explicit severity is
 * passed).
 */
@IsTest
private class KBSetupPreflightServiceTest {

    @IsTest
    static void testRunChecks_DefaultOrg_ReturnsExpectedSet() {
        Test.startTest();
        List<Map<String, Object>> checks = KBSetupPreflightService.runChecks();
        Test.stopTest();

        Assert.areEqual(5, checks.size(),
            'Five documented checks; the count is stable so this catches accidental drops');

        // Every entry has the documented shape.
        for (Map<String, Object> c : checks) {
            Assert.isTrue(c.containsKey('key'));
            Assert.isTrue(c.containsKey('label'));
            Assert.isTrue(c.containsKey('passed'));
            Assert.isTrue(c.containsKey('required'));
            Assert.isTrue(c.containsKey('details'));
            Assert.isTrue(c.containsKey('severity'));
        }

        // The known fixed-key set is rendered.
        Set<String> keys = new Set<String>();
        for (Map<String, Object> c : checks) keys.add((String) c.get('key'));
        Assert.isTrue(keys.contains('dataCloudAvailable'));
        Assert.isTrue(keys.contains('searchIndexConfigured'));
        Assert.isTrue(keys.contains('contentFieldsSelected'));
        Assert.isTrue(keys.contains('knowledgeArticlesExist'));
        Assert.isTrue(keys.contains('bypassPermissionExists'));
    }

    @IsTest
    static void testRunChecks_ContentFieldsConfigured_FlipsSelectedToTrue() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Content_Field_Mapping_JSON__c = 'Summary,Title';
        upsert cfg KB_Scan_Config__c.Id;

        Test.startTest();
        List<Map<String, Object>> checks = KBSetupPreflightService.runChecks();
        Test.stopTest();

        Boolean foundContentCheck = false;
        for (Map<String, Object> c : checks) {
            if ((String) c.get('key') == 'contentFieldsSelected') {
                foundContentCheck = true;
                Assert.isTrue((Boolean) c.get('passed'),
                    'Content fields configured → check passes');
                Assert.isTrue(((String) c.get('details')).contains('content field'));
            }
        }
        Assert.isTrue(foundContentCheck);
    }

    @IsTest
    static void testRunChecks_SearchIndexConfigured_PassesWhenSetupComplete() {
        KB_Vector_Search_Config__c vc = KB_Vector_Search_Config__c.getOrgDefaults();
        vc.Search_Index_Name__c = 'my_index';
        vc.Is_Active__c = true;
        upsert vc KB_Vector_Search_Config__c.Id;

        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        state.Setup_Completed__c = true;
        upsert state KB_Setup_Wizard_State__c.Id;

        Test.startTest();
        List<Map<String, Object>> checks = KBSetupPreflightService.runChecks();
        Test.stopTest();

        for (Map<String, Object> c : checks) {
            if ((String) c.get('key') == 'searchIndexConfigured') {
                Assert.isTrue((Boolean) c.get('passed'),
                    'Index name configured → check passes');
            }
        }
    }

    @IsTest
    static void testRunChecks_NoSearchIndex_SetupNotDone_PassesAsNotApplicable() {
        // Wizard state has Setup_Completed=false (default). With no index
        // configured the check still passes via the `!setupDone` short-circuit.
        Test.startTest();
        List<Map<String, Object>> checks = KBSetupPreflightService.runChecks();
        Test.stopTest();

        for (Map<String, Object> c : checks) {
            if ((String) c.get('key') == 'searchIndexConfigured') {
                Assert.isTrue((Boolean) c.get('passed'),
                    'Setup not yet complete → check is N/A and passes');
            }
        }
    }

    @IsTest
    static void testRunChecks_ContentFieldsBlankList_DoesNotPass() {
        // Trailing-comma / whitespace-only entry: split produces blanks
        // that count++ skips, so contentFieldCount stays 0 → check fails.
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Content_Field_Mapping_JSON__c = ' ,,';
        upsert cfg KB_Scan_Config__c.Id;

        Test.startTest();
        List<Map<String, Object>> checks = KBSetupPreflightService.runChecks();
        Test.stopTest();

        for (Map<String, Object> c : checks) {
            if ((String) c.get('key') == 'contentFieldsSelected') {
                Assert.isFalse((Boolean) c.get('passed'),
                    'All-blank entries → 0 valid fields → fails');
            }
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // buildCheck — direct unit test on the @TestVisible builder
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testBuildCheck_RequiredImpliesBlocker() {
        Map<String, Object> c = KBSetupPreflightService.buildCheck(
            'k1', 'label', false, true, 'details'
        );
        Assert.areEqual('blocker', (String) c.get('severity'),
            'required=true → severity defaults to blocker');
    }

    @IsTest
    static void testBuildCheck_NonRequiredImpliesWarning() {
        Map<String, Object> c = KBSetupPreflightService.buildCheck(
            'k1', 'label', true, false, 'details'
        );
        Assert.areEqual('warning', (String) c.get('severity'));
    }

    @IsTest
    static void testBuildCheck_ExplicitSeverityWins() {
        Map<String, Object> c = KBSetupPreflightService.buildCheck(
            'k1', 'label', false, true, 'details', 'info', 'step:2'
        );
        Assert.areEqual('info', (String) c.get('severity'),
            'Explicit severity overrides the required-derived default');
        Assert.areEqual('step:2', (String) c.get('actionKey'));
    }

    @IsTest
    static void testBuildCheck_HelptextResolved() {
        // Known key in HELPTEXT_BY_KEY → helptext populated from Custom Label.
        Map<String, Object> c = KBSetupPreflightService.buildCheck(
            'dataCloudAvailable', 'Data Cloud', true, false, 'details'
        );
        // Helptext is not null (sourced from System.Label.KB_Helptext_Preflight_DataCloud)
        Assert.isNotNull(c.get('helptext'));
    }

    @IsTest
    static void testBuildCheck_UnknownKey_HelptextIsNull() {
        Map<String, Object> c = KBSetupPreflightService.buildCheck(
            '__no_such_helptext__', 'X', false, false, 'd'
        );
        Assert.isNull(c.get('helptext'),
            'Unknown key returns null helptext (Map.get of missing key)');
    }
}
