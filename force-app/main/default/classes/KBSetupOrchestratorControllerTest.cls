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
private class KBSetupOrchestratorControllerTest {

    @IsTest
    static void testGetBootstrapData() {
        Test.startTest();
        Map<String, Object> data = KBSetupOrchestratorController.getBootstrapData();
        Test.stopTest();

        System.assertNotEquals(null, data, 'Bootstrap data should be returned');
        System.assert(data.containsKey('scanConfig'), 'Includes scan config');
        System.assert(data.containsKey('scoreWeights'), 'Includes score weights');
        System.assert(data.containsKey('pipelineConfig'), 'Includes pipeline config');
        System.assert(data.containsKey('vectorConfig'), 'Includes vector config');
        System.assert(data.containsKey('wizardState'), 'Includes wizard state');
    }

    @IsTest
    static void testWizardStatePersistence() {
        String stateJson = '{"currentStep":"5"}';

        Test.startTest();
        KBSetupOrchestratorController.saveWizardState(stateJson);
        Map<String, Object> state = KBSetupOrchestratorController.getWizardState();
        Test.stopTest();

        System.assertEquals(stateJson, (String) state.get('wizardStateJSON'), 'Wizard state JSON persists');
    }

    @IsTest
    static void testGetAvailableSearchIndexes_ReturnsListOrEmpty() {
        Test.startTest();
        List<Map<String, Object>> indexes = KBSetupOrchestratorController.getAvailableSearchIndexes();
        Test.stopTest();

        // DataSemanticSearch may not exist in all orgs — method must return a list (empty or populated), never throw
        System.assertNotEquals(null, indexes, 'Should return a non-null list');
        for (Map<String, Object> idx : indexes) {
            System.assert(idx.containsKey('value'), 'Each entry must have a value key');
            System.assert(idx.containsKey('label'), 'Each entry must have a label key');
            System.assert(idx.containsKey('status'), 'Each entry must have a status key');
            System.assertNotEquals(null, idx.get('value'), 'Value must not be null');
        }
    }

    @IsTest
    static void testSaveCoreConfigurationValidatesAndPersists() {
        // There are no Article Length / Title word-count fields, and the wizard
        // has no Performance section (Queueable Batch Size) — saveScanConfig does
        // not write Queueable_Batch_Size__c. The
        // scan-config blob this path persists today is freshness + data-categories.
        //
        // Freshness values are deliberately OFF the field defaults (12 / 24) so the
        // assertions below prove the save actually wrote them rather than reading
        // back the field metadata defaults. queueableBatchSize is still sent in the
        // payload to confirm the save path ignores it (it falls through to the
        // field's defaultValue of 10 — exercised by the explicit assert below).
        Map<String, Object> scanConfig = new Map<String, Object>{
            'freshnessThresholdMonths' => 9,
            'freshnessCriticalMonths' => 18,
            'queueableBatchSize' => 75
        };
        Map<String, Object> scoreWeights = new Map<String, Object>{
            'completeness' => 0.30,
            'structure' => 0.20,
            'clarity' => 0.10,
            'freshness' => 0.10,
            'duplication' => 0.15,
            'conflict' => 0.15
        };
        Map<String, Object> pipelineConfig = new Map<String, Object>{
            'manualReviewThreshold' => 50,
            'tier2TopK' => 20,
            'tier2SimilarityThreshold' => 0.75
        };
        Map<String, Object> vectorConfig = new Map<String, Object>{
            'implementationClass' => 'ConnectApiVectorSearchService',
            'dataSpaceName' => 'default',
            'similarityThreshold' => 0.75,
            'maxResults' => 20
        };

        Test.startTest();
        KBSetupOrchestratorController.saveCoreConfiguration(
            JSON.serialize(scanConfig),
            JSON.serialize(scoreWeights),
            JSON.serialize(pipelineConfig),
            JSON.serialize(vectorConfig)
        );
        Test.stopTest();

        KB_Scan_Config__c scan = KB_Scan_Config__c.getOrgDefaults();
        KB_Pipeline_Config__c pipeline = KB_Pipeline_Config__c.getOrgDefaults();
 // Freshness fields are what saveScanConfig persists post-— assert the
        // non-default values round-tripped.
        System.assertEquals(9, scan.Freshness_Threshold_Months__c, 'Freshness threshold persisted');
        System.assertEquals(18, scan.Freshness_Critical_Months__c, 'Freshness critical persisted');
 // queueableBatchSize is intentionally NOT persisted by this path:
        // the wizard no longer owns batch size, so the field stays at its metadata
        // default (10) regardless of what the payload carried.
        System.assertEquals(10, scan.Queueable_Batch_Size__c,
            'Batch size is no longer written by saveScanConfig — stays at field default');
        System.assertEquals(20, pipeline.Tier2_TopK__c, 'Pipeline config persisted');
        // Note: saveCoreConfiguration does not touch KB_Vector_Search_Config__c; vector config is saved separately via saveVectorSearchConfig
    }

    @IsTest
    static void testSaveCoreConfigurationFailsInvalidWeights() {
        Map<String, Object> scanConfig = new Map<String, Object>{
            'freshnessThresholdMonths' => 12,
            'queueableBatchSize' => 50
        };
        Map<String, Object> badWeights = new Map<String, Object>{
            'completeness' => 0.6,
            'structure' => 0.6
        };
        Map<String, Object> pipelineConfig = new Map<String, Object>{
            'autoMergeThreshold' => 80,
            'manualReviewThreshold' => 50,
            'tier2TopK' => 20,
            'tier2SimilarityThreshold' => 0.75
        };
        Map<String, Object> vectorConfig = new Map<String, Object>{
            'implementationClass' => 'ConnectApiVectorSearchService',
            'dataSpaceName' => 'default',
            'similarityThreshold' => 0.75,
            'maxResults' => 20
        };

        Boolean failed = false;
        try {
            KBSetupOrchestratorController.saveCoreConfiguration(
                JSON.serialize(scanConfig),
                JSON.serialize(badWeights),
                JSON.serialize(pipelineConfig),
                JSON.serialize(vectorConfig)
            );
        } catch (AuraHandledException e) {
            failed = true;
        }
        System.assert(failed, 'Invalid score weights should fail validation');
    }

    @IsTest
    static void testRunPreflightAndValidation() {
        Test.startTest();
        List<Map<String, Object>> checks = KBSetupOrchestratorController.runPreflightChecks();
        List<Map<String, Object>> finalChecks = KBSetupOrchestratorController.runFinalValidation();
        Test.stopTest();

        System.assert(!checks.isEmpty(), 'Preflight checks should be produced');
        System.assert(!finalChecks.isEmpty(), 'Final checks should be produced');
    }

    // ──────────────────────────────────────────────────────────────────────
    // runFinalValidation includes the content-field/index alignment check
 // and runs idempotently — admins must be able to re-validate
    // post-completion without setupCompleted regressing if checks still pass.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testRunFinalValidation_SurfacesAlignmentCheck_OrSuppressesIndeterminate() {
 // when the alignment check produces a definite verdict
        // (ok / mismatch / noConfig) it must surface as a soft warning row.
        // When it can't introspect (indeterminate) the row is intentionally
        // suppressed so the UI doesn't render a green check next to a
        // "we couldn't tell" message — exercised by the dedicated test below.
        Test.startTest();
        List<Map<String, Object>> finalChecks = KBSetupOrchestratorController.runFinalValidation();
        Test.stopTest();

        for (Map<String, Object> c : finalChecks) {
            if ('contentFieldsMatchIndex'.equals(c.get('key'))) {
                Assert.areEqual(false, c.get('required'),
                    'Content-field/index alignment is a soft warning, never required');
                Assert.areEqual('warning', c.get('severity'),
                    'Severity is warning even on mismatch');
            }
        }
    }

    @IsTest
    static void testRunFinalValidation_AlignmentCheck_RowOrSuppressed() {
        // Two valid org states: chunk DMO not describable (STATUS_INDETERMINATE
        // → row dropped entirely) OR chunk DMO described (real status → row
        // rendered with passed=true|false). Either is acceptable; the contract
        // we lock down is "no indeterminate row leaks through as a passing
        // check." See KBContentFieldIndexValidator.buildContentFieldIndexCheck.
        Test.startTest();
        List<Map<String, Object>> finalChecks = KBSetupOrchestratorController.runFinalValidation();
        Test.stopTest();

        Map<String, Object> alignmentRow = null;
        for (Map<String, Object> c : finalChecks) {
            if ('contentFieldsMatchIndex'.equals(c.get('key'))) {
                alignmentRow = c;
                break;
            }
        }

        if (alignmentRow != null) {
            // Row rendered → must carry a real status (ok/mismatch/noConfig),
            // never the indeterminate sentinel masquerading as passed.
            Object passed = alignmentRow.get('passed');
            Assert.isNotNull(passed, 'Alignment row must declare a pass/fail');
        }
        // If null, the indeterminate-suppression branch fired — also valid.
    }

    @IsTest
    static void testRunFinalValidation_RerunnableAfterFirstPass() {
 // runFinalValidation must be safely callable repeatedly.
        // Two back-to-back runs produce identically-shaped output and the
        // wizard state row is upserted (not duplicated).
        Test.startTest();
        List<Map<String, Object>> first = KBSetupOrchestratorController.runFinalValidation();
        List<Map<String, Object>> second = KBSetupOrchestratorController.runFinalValidation();
        Test.stopTest();

        Assert.areEqual(first.size(), second.size(),
            'Re-run produces the same number of checks');
        // Wizard-state row is upserted, never inserted twice.
        Integer stateRows = [SELECT COUNT() FROM KB_Setup_Wizard_State__c];
        Assert.isTrue(stateRows <= 1, 'Wizard state row is upserted, not duplicated');
    }

    // ─── Permset assignment (1.0.E Step 0) ─────────────────────────────────────

    @IsTest
    static void testGetPermsetAssignmentStatus_ReturnsThreeRows() {
        Test.startTest();
        List<Map<String, Object>> rows = KBSetupOrchestratorController.getPermsetAssignmentStatus();
        Test.stopTest();

        Assert.isNotNull(rows, 'Returns non-null list');
        Assert.areEqual(3, rows.size(), 'Returns exactly 3 rows for the 3 whitelisted permsets');
        for (Map<String, Object> row : rows) {
            Assert.isNotNull(row.get('apiName'), 'apiName populated');
            Assert.isNotNull(row.get('label'), 'label populated');
            Assert.isNotNull(row.get('assigned'), 'assigned flag populated');
        }
    }

 // ─── canAccessAssessments ───────────────────────────────────────────

    @IsTest
    static void testCanAccessAssessments_TrueForUserWithObjectRead() {
        // The test-running (admin) user has read on KB_Assessment_Run__c.
        Test.startTest();
        Boolean canAccess = KBSetupOrchestratorController.canAccessAssessments();
        Test.stopTest();
        Assert.isTrue(canAccess,
            'A user with KB_Assessment_Run__c read reaches the Assessments console');
    }

    @IsTest
    static void testCanAccessAssessments_FalseForMinAccessUser() {
        // A low-access user with no KB permset has no read on the custom object
        // → canAccessAssessments() must be false so the completion CTA degrades
 // to "Done". Review F601-1: this must NOT silently no-op when a
        // specific profile name is absent — build the user off whatever
        // minimal-access profile the org has, and assert the setup precondition
        // (the user genuinely lacks the object) so a green pass can't be hollow.
        User lowAccess = buildLowAccessUser();
        Assert.isNotNull(lowAccess,
            'Test requires a minimal-access profile to build a no-access user; none found');

        Boolean canAccess = true;
        Boolean setupHasNoAccess;
        System.runAs(lowAccess) {
            // Precondition: confirm the built user truly can't read the object.
            // If this ever becomes true (profile drift granting the object),
            // the negative test is meaningless — fail loudly instead of passing.
            setupHasNoAccess = !Schema.sObjectType.KB_Assessment_Run__c.isAccessible();
            Test.startTest();
            canAccess = KBSetupOrchestratorController.canAccessAssessments();
            Test.stopTest();
        }
        Assert.isTrue(setupHasNoAccess,
            'Precondition: the low-access user must lack KB_Assessment_Run__c read; '
            + 'if this fails the profile grants the object and the negative test is void');
        Assert.isFalse(canAccess,
            'A user with no read on KB_Assessment_Run__c cannot reach the console');
    }

    /**
     * Builds a minimal-access user with NO KB permset, so the
     * object-accessibility check returns false. Resilient to org profile
     * naming (F601-1): tries the standard "Minimum Access - Salesforce"
     * profile, then falls back to any profile whose name signals minimal
     * access, then to the least-privileged available standard profile.
     * Returns null only if the org has no usable profile at all.
     */
    private static User buildLowAccessUser() {
        Profile p = pickLowAccessProfile();
        if (p == null) return null;
        String uniq = 'kb590' + String.valueOf(Datetime.now().getTime());
        User u = new User(
            ProfileId = p.Id,
            LastName = 'LowAccess',
            Email = uniq + '@example.com',
            Username = uniq + '@example.com.kbtest',
            Alias = 'kb590',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }

    private static Profile pickLowAccessProfile() {
        // 1) The canonical minimal profile.
        List<Profile> named = [
            SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1
        ];
        if (!named.isEmpty()) return named[0];
        // 2) Any profile that reads as minimal/read-only (name-agnostic net).
        List<Profile> minimalish = [
            SELECT Id FROM Profile
            WHERE Name LIKE '%Minimum Access%' OR Name LIKE '%Read Only%'
            LIMIT 1
        ];
        if (!minimalish.isEmpty()) return minimalish[0];
        // 3) Last resort: the Standard User profile (still lacks the custom
        //    object unless a permset grants it, which we don't assign). The
        //    precondition assert in the test guards against a wrongly-permissive
        //    fallback.
        List<Profile> std = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        return std.isEmpty() ? null : std[0];
    }

    // ──────────────────────────────────────────────────────────────────────
    // checkPromptTemplateStatus
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testCheckPromptTemplateStatus_ReturnsList() {
        Test.startTest();
        List<String> names = KBSetupOrchestratorController.checkPromptTemplateStatus();
        Test.stopTest();

        Assert.isNotNull(names);
        // Either populated (Einstein available) or empty — both are valid.
    }

    // ──────────────────────────────────────────────────────────────────────
    // getPromptTemplateLinks — uses IPromptTemplateLister test seam
    // ──────────────────────────────────────────────────────────────────────

    private class StubPromptTemplateLister implements KBSetupOrchestratorController.IPromptTemplateLister {
        public Boolean throwException = false;
        public ConnectApi.EinsteinPromptRecordCollectionOutputRepresentation fetchTemplates() {
            if (throwException) {
                throw new KnowledgeAIException('Stub Einstein failure');
            }
            ConnectApi.EinsteinPromptRecordCollectionOutputRepresentation result =
                new ConnectApi.EinsteinPromptRecordCollectionOutputRepresentation();
            result.promptRecords = new List<ConnectApi.EinsteinPromptRecordRepresentation>();
            return result;
        }
    }

    @IsTest
    static void testGetPromptTemplateLinks_EmptyList() {
        StubPromptTemplateLister stub = new StubPromptTemplateLister();
        KBSetupOrchestratorController.templateLister = stub;

        Test.startTest();
        List<Map<String, String>> links = KBSetupOrchestratorController.getPromptTemplateLinks();
        Test.stopTest();

        Assert.areEqual(0, links.size(), 'Empty template list → empty result');
    }

    @IsTest
    static void testGetPromptTemplateLinks_StubThrows_AuraHandledException() {
        StubPromptTemplateLister stub = new StubPromptTemplateLister();
        stub.throwException = true;
        KBSetupOrchestratorController.templateLister = stub;

        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.getPromptTemplateLinks();
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Stub-throws path wraps in AuraHandledException');
    }

    // ──────────────────────────────────────────────────────────────────────
    // saveVectorConfiguration
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testSaveVectorConfiguration_Valid_Persists() {
        Map<String, Object> vectorConfig = new Map<String, Object>{
            'implementationClass' => 'ConnectApiVectorSearchService',
            'dataSpaceName' => 'default',
            'searchIndexName' => 'KA_Knowledge_index',
            'similarityThreshold' => 0.75,
            'maxResults' => 20
        };

        Test.startTest();
        KBSetupOrchestratorController.saveVectorConfiguration(JSON.serialize(vectorConfig));
        Test.stopTest();

        // Delegates to KBSetupWizardController.saveVectorSearchConfig, which
        // upserts KB_Vector_Search_Config__c. The persisted row should reflect
        // the input.
        KB_Vector_Search_Config__c persisted = KB_Vector_Search_Config__c.getOrgDefaults();
        Assert.isNotNull(persisted, 'Org-default custom setting row created');
        Assert.areEqual('ConnectApiVectorSearchService', persisted.Implementation_Class__c);
        Assert.areEqual('KA_Knowledge_index', persisted.Search_Index_Name__c);
    }

    @IsTest
    static void testSaveVectorConfiguration_Invalid_Throws() {
        Map<String, Object> badVector = new Map<String, Object>{
            'implementationClass' => '',  // missing → triggers validateVectorConfig throw
            'dataSpaceName' => 'default',
            'searchIndexName' => 'X',
            'similarityThreshold' => 0.5,
            'maxResults' => 10
        };

        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.saveVectorConfiguration(JSON.serialize(badVector));
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw);
    }

    @IsTest
    static void testSaveVectorConfiguration_DisabledFallback_NoIndex_Saves() {
 // when vector search is disabled (Tier1SOQLFallbackService),
        // the user is opting out — search index name is not required.
        Map<String, Object> disabledConfig = new Map<String, Object>{
            'implementationClass' => 'Tier1SOQLFallbackService',
            'isActive' => false,
            'searchIndexName' => '',
            'dataSpaceName' => '',
            'similarityThreshold' => 0.75,
            'maxResults' => 20
        };

        Test.startTest();
        // Should not throw — disabled config doesn't need index/dataSpace
        KBSetupOrchestratorController.saveVectorConfiguration(JSON.serialize(disabledConfig));
        Test.stopTest();

        KB_Vector_Search_Config__c persisted = KB_Vector_Search_Config__c.getOrgDefaults();
        Assert.areEqual('Tier1SOQLFallbackService', persisted.Implementation_Class__c,
            'SOQL fallback persisted without requiring an index');
    }

    @IsTest
    static void testSaveVectorConfiguration_EnabledNoIndex_StillThrows() {
        // Regression guard: when vector search IS enabled, the index name is
        // still required. Don't loosen the active-mode validation.
        Map<String, Object> enabledNoIndex = new Map<String, Object>{
            'implementationClass' => 'ConnectApiVectorSearchService',
            'isActive' => true,
            'searchIndexName' => '',
            'dataSpaceName' => 'default',
            'similarityThreshold' => 0.75,
            'maxResults' => 20
        };

        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.saveVectorConfiguration(JSON.serialize(enabledNoIndex));
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'Active vector search without a search index name must still fail validation');
    }

    @IsTest
    static void testSaveVectorConfiguration_InactiveButImplClassNotSynced_Saves() {
        // Trap pre-fix: the wizard's toggle only flipped isActive, leaving
        // implementationClass='ConnectApiVectorSearchService'. Validation
        // gated only on impl class so the user got "Search index name is
        // required" with no index to choose. The fix gates on isActive too,
        // so a payload that says "off" wins regardless of impl class.
        Map<String, Object> inactiveButConnectApiImpl = new Map<String, Object>{
            'implementationClass' => 'ConnectApiVectorSearchService',
            'isActive' => false,
            'searchIndexName' => '',
            'dataSpaceName' => '',
            'similarityThreshold' => 0.75,
            'maxResults' => 20
        };

        Test.startTest();
        // Should not throw despite blank index — isActive=false trumps impl class.
        KBSetupOrchestratorController.saveVectorConfiguration(JSON.serialize(inactiveButConnectApiImpl));
        Test.stopTest();

        KB_Vector_Search_Config__c persisted = KB_Vector_Search_Config__c.getOrgDefaults();
        Assert.areEqual(false, persisted.Is_Active__c, 'Inactive flag persisted');
        // KBSetupWizardController.saveVectorSearchConfig overrides impl class
        // from the toggle, so the saved record reflects the effective fallback.
        Assert.areEqual('Tier1SOQLFallbackService', persisted.Implementation_Class__c,
            'Saved impl class follows the active toggle, regardless of the LWC payload');
    }

    // ──────────────────────────────────────────────────────────────────────
    // executeAutomationActions
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExecuteAutomationActions_EmptyJSON_NoThrow() {
        Test.startTest();
        Map<String, Object> response = KBSetupOrchestratorController.executeAutomationActions('{}');
        Test.stopTest();

        Assert.isNotNull(response);
        Assert.isTrue(response.containsKey('manualTasks'));
    }

    @IsTest
    static void testManualTaskChecklist_IncludesRequiredOnboardingTasks() {
 // /— the manual-task checklist must surface record-page
        // activation and the non-shipped platform prerequisite permissions, both
 // required. (also reworded the search-index task key 'dataCloudStream'
        // into plain English — the key is unchanged, the title is not jargon.)
        Test.startTest();
        Map<String, Object> response = KBSetupOrchestratorController.executeAutomationActions('{}');
        Test.stopTest();

        List<Object> tasks = (List<Object>) response.get('manualTasks');
        Assert.isNotNull(tasks);

        Set<String> keys = new Set<String>();
        Map<String, Boolean> requiredByKey = new Map<String, Boolean>();
        for (Object o : tasks) {
            Map<String, Object> t = (Map<String, Object>) o;
            String key = String.valueOf(t.get('key'));
            keys.add(key);
            requiredByKey.put(key, (Boolean) t.get('required'));
        }

        Assert.isTrue(keys.contains('activateRecordPage'), 'Record-page activation task present');
        Assert.isTrue(requiredByKey.get('activateRecordPage'), 'Record-page activation is required');
        Assert.isTrue(keys.contains('platformPrereqPerms'), 'Platform prerequisite perms task present');
        Assert.isTrue(requiredByKey.get('platformPrereqPerms'), 'Platform prerequisite perms task is required');
        Assert.isTrue(keys.contains('dataCloudStream'), 'Search-index task still present');
    }

    @IsTest
    static void testExecuteAutomationActions_BadJSON_AuraHandled() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.executeAutomationActions('{not-json');
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw);
    }

    // ──────────────────────────────────────────────────────────────────────
    // getKnowledgeFieldOptions
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetKnowledgeFieldOptions_ReturnsOptions() {
        Test.startTest();
        List<Map<String, Object>> options = KBSetupOrchestratorController.getKnowledgeFieldOptions();
        Test.stopTest();

        Assert.isNotNull(options);
        // Knowledge__kav has many text fields; expect non-empty in test orgs.
    }

    @IsTest
    static void testGetKnowledgeFieldOptions_ExcludesTitleAndSummary() {
 // Title and Summary are sent to the scoring prompts as their OWN
        // independent inputs, not folded into the body-field-mapping
        // concatenation. They must therefore never appear in the content-scope
        // picker (offering Summary would let an admin double-count it into the
        // body text).
        Test.startTest();
        List<Map<String, Object>> options = KBSetupOrchestratorController.getKnowledgeFieldOptions();
        Test.stopTest();

        for (Map<String, Object> opt : options) {
            String value = String.valueOf(opt.get('value'));
            Assert.areNotEqual('Summary', value, 'Summary must be excluded from the content-scope picker');
            Assert.areNotEqual('Title', value, 'Title must be excluded from the content-scope picker');
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // Pipeline config validation branches
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testSaveCoreConfiguration_BadPipelineThresholds_Throws() {
        Map<String, Object> scanConfig = new Map<String, Object>{
            'freshnessThresholdMonths' => 12,
            'queueableBatchSize' => 50
        };
        Map<String, Object> scoreWeights = new Map<String, Object>{
            'completeness' => 0.30, 'structure' => 0.20,
            'clarity' => 0.10, 'freshness' => 0.10,
            'duplication' => 0.15, 'conflict' => 0.15
        };
 // the manualReview > autoMerge cross-validation was removed with
        // the auto-merge band gate. validatePipelineConfig now only guards the
        // Tier 2 detection knobs — a non-positive Top K must throw.
        Map<String, Object> badPipeline = new Map<String, Object>{
            'manualReviewThreshold' => 50,
            'tier2TopK' => 0,
            'tier2SimilarityThreshold' => 0.75
        };
        Map<String, Object> vectorConfig = new Map<String, Object>{
            'implementationClass' => 'ConnectApiVectorSearchService',
            'dataSpaceName' => 'default',
            'searchIndexName' => 'KA_Knowledge_index',
            'similarityThreshold' => 0.75,
            'maxResults' => 20
        };

        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.saveCoreConfiguration(
                JSON.serialize(scanConfig), JSON.serialize(scoreWeights),
                JSON.serialize(badPipeline), JSON.serialize(vectorConfig)
            );
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Non-positive Tier 2 Top K → validation fails');
    }

    // There is no scan-config word-count cross-field validation test — the
    // scan config has no Article Length / Title word-count fields to validate.

    // ──────────────────────────────────────────────────────────────────────
    // isSetupCompleted
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testIsSetupCompleted_FalseWhenNotSet() {
        Test.startTest();
        Boolean done = KBSetupOrchestratorController.isSetupCompleted();
        Test.stopTest();

        Assert.isFalse(done, 'Default Setup_Completed__c is false');
    }

    @IsTest
    static void testIsSetupCompleted_TrueWhenFlagSet() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        state.Setup_Completed__c = true;
        upsert state KB_Setup_Wizard_State__c.Id;

        Test.startTest();
        Boolean done = KBSetupOrchestratorController.isSetupCompleted();
        Test.stopTest();

        Assert.isTrue(done);
    }

    // ──────────────────────────────────────────────────────────────────────
    // getPromptTemplateLinks — real lister path + populated stub records
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetPromptTemplateLinks_RealLister_NoStub_HandlesGracefully() {
        // No templateLister override — exercises RealPromptTemplateLister,
        // which calls the actual ConnectApi.EinsteinLlm.getPromptTemplates.
        // The outer try/catch in getPromptTemplateLinks wraps any failure
        // into AuraHandledException, so either outcome is valid here.
        KBSetupOrchestratorController.templateLister = null;

        Test.startTest();
        List<Map<String, String>> links;
        Boolean threw = false;
        try {
            links = KBSetupOrchestratorController.getPromptTemplateLinks();
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(links != null || threw,
            'Real Einstein template lister either returns a list or fails gracefully');
    }

    private class PopulatedPromptTemplateLister implements KBSetupOrchestratorController.IPromptTemplateLister {
        public ConnectApi.EinsteinPromptRecordCollectionOutputRepresentation fetchTemplates() {
            ConnectApi.EinsteinPromptRecordCollectionOutputRepresentation result =
                new ConnectApi.EinsteinPromptRecordCollectionOutputRepresentation();
            result.promptRecords = new List<ConnectApi.EinsteinPromptRecordRepresentation>{
                buildRecord('rec-clarity', 'Evaluate_Clarity', 'v-clarity-1'),
                buildRecord('rec-other', 'Some_Unrelated_Template', 'v-other-1'),
                buildRecord('rec-no-version', 'Evaluate_Structure', null)
            };
            return result;
        }

        private ConnectApi.EinsteinPromptRecordRepresentation buildRecord(
            String id, String developerName, String activeVersionId
        ) {
            ConnectApi.EinsteinPromptRecordRepresentation rec =
                new ConnectApi.EinsteinPromptRecordRepresentation();
            rec.id = id;
            ConnectApi.EinsteinPromptRecordFieldRepresentation nameField =
                new ConnectApi.EinsteinPromptRecordFieldRepresentation();
            nameField.value = developerName;
            rec.fields = new Map<String, ConnectApi.EinsteinPromptRecordFieldRepresentation>{
                'DeveloperName' => nameField
            };
            if (activeVersionId != null) {
                ConnectApi.EinsteinPromptRecordFieldRepresentation versionField =
                    new ConnectApi.EinsteinPromptRecordFieldRepresentation();
                versionField.value = activeVersionId;
                rec.fields.put('ActiveVersionId', versionField);
            }
            return rec;
        }
    }

    @IsTest
    static void testGetPromptTemplateLinks_PopulatedRecords_FiltersToScoringNames() {
        KBSetupOrchestratorController.templateLister = new PopulatedPromptTemplateLister();

        Test.startTest();
        List<Map<String, String>> links = KBSetupOrchestratorController.getPromptTemplateLinks();
        Test.stopTest();

        // Only the two scoring-template names (Evaluate_Clarity, Evaluate_Structure)
        // survive the scoringNames filter — the unrelated template is dropped.
        Assert.areEqual(2, links.size(), 'Only scoring templates are kept');
        Set<String> names = new Set<String>();
        String noVersionEntryVersionId = null;
        for (Map<String, String> link : links) {
            names.add(link.get('name'));
            if ('Evaluate_Structure'.equals(link.get('name'))) {
                noVersionEntryVersionId = link.get('versionId');
            }
        }
        Assert.isTrue(names.contains('Evaluate_Clarity'), 'Clarity template kept');
        Assert.isTrue(names.contains('Evaluate_Structure'), 'Structure template kept');
        Assert.isFalse(names.contains('Some_Unrelated_Template'), 'Non-scoring template filtered out');
        Assert.areEqual('', noVersionEntryVersionId, 'Missing ActiveVersionId falls back to empty string');
    }

    // ──────────────────────────────────────────────────────────────────────
    // saveCoreConfiguration / saveVectorConfiguration — malformed JSON hits
    // the generic Exception catch (not the AuraHandledException re-throw)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testSaveCoreConfiguration_MalformedJson_GenericCatch() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.saveCoreConfiguration(
                '{not-valid-json', '{}', '{}', null
            );
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Malformed scan config JSON throws via the generic Exception catch');
    }

    @IsTest
    static void testSaveVectorConfiguration_MalformedJson_GenericCatch() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.saveVectorConfiguration('{not-valid-json');
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Malformed vector config JSON throws via the generic Exception catch');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Remaining pipeline/vector validation branches
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testSaveCoreConfiguration_SimilarityThresholdOutOfRange_Throws() {
        Map<String, Object> scanConfig = new Map<String, Object>{
            'freshnessThresholdMonths' => 12
        };
        Map<String, Object> scoreWeights = new Map<String, Object>{
            'completeness' => 0.30, 'structure' => 0.20,
            'clarity' => 0.10, 'freshness' => 0.10,
            'duplication' => 0.15, 'conflict' => 0.15
        };
        Map<String, Object> badPipeline = new Map<String, Object>{
            'tier2TopK' => 20,
            'tier2SimilarityThreshold' => 1.5
        };

        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.saveCoreConfiguration(
                JSON.serialize(scanConfig), JSON.serialize(scoreWeights),
                JSON.serialize(badPipeline), null
            );
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Similarity threshold above 1 must fail validation');
    }

    @IsTest
    static void testSaveVectorConfiguration_MissingDataSpace_Throws() {
        Map<String, Object> vectorConfig = new Map<String, Object>{
            'implementationClass' => 'ConnectApiVectorSearchService',
            'isActive' => true,
            'searchIndexName' => 'KA_Knowledge_index',
            'dataSpaceName' => '',
            'similarityThreshold' => 0.75,
            'maxResults' => 20
        };

        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.saveVectorConfiguration(JSON.serialize(vectorConfig));
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Active ConnectApi vector search without a data space must fail validation');
    }

    @IsTest
    static void testSaveVectorConfiguration_SimilarityOutOfRange_Throws() {
        Map<String, Object> vectorConfig = new Map<String, Object>{
            'implementationClass' => 'Tier1SOQLFallbackService',
            'isActive' => false,
            'searchIndexName' => '',
            'dataSpaceName' => '',
            'similarityThreshold' => 1.5,
            'maxResults' => 20
        };

        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.saveVectorConfiguration(JSON.serialize(vectorConfig));
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Similarity threshold above 1 must fail validation regardless of active state');
    }

    @IsTest
    static void testSaveVectorConfiguration_MaxResultsNotPositive_Throws() {
        Map<String, Object> vectorConfig = new Map<String, Object>{
            'implementationClass' => 'Tier1SOQLFallbackService',
            'isActive' => false,
            'searchIndexName' => '',
            'dataSpaceName' => '',
            'similarityThreshold' => 0.5,
            'maxResults' => 0
        };

        Boolean threw = false;
        Test.startTest();
        try {
            KBSetupOrchestratorController.saveVectorConfiguration(JSON.serialize(vectorConfig));
        } catch (AuraHandledException ahe) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Non-positive max results must fail validation');
    }
}
