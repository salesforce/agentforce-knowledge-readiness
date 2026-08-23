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
private class KBSetupWizardControllerTest {

    // ==================== Step 1: Scan Config ====================

    @IsTest
    static void testGetScanConfig_ReturnsDefaults() {
        Map<String, Object> config = KBSetupWizardController.getScanConfig();

        System.assertNotEquals(null, config, 'Config should not be null');
        // The active scan-config surface is narrower than the historical one —
        // dead fields (minSummaryLength, deterministicWeight, llmWeight,
        // einsteinModelName, etc.) have been retired per CLAUDE.md. Only
        // assert defaults for fields the controller actively reads.
        System.assertEquals(12, config.get('freshnessThresholdMonths'), 'Default freshness threshold');
        System.assertEquals(24, config.get('freshnessCriticalMonths'), 'Default freshness critical');
 // removed the Article Length section (minArticleWordCount,
        // optimalMinWords, optimalMaxWords, maxWordsThreshold) and the Title
        // section (minTitleLength) from the wizard. The four word-count fields
        // were dead and deleted; Min_Title_Length__c lives only on the custom
 // setting now. removed the Performance section
        // (queueableBatchSize). Assert none of them surface in the wizard payload.
        System.assert(!config.containsKey('minTitleLength'),
            'minTitleLength no longer surfaced by the wizard');
        System.assert(!config.containsKey('minArticleWordCount'),
            'minArticleWordCount no longer surfaced by the wizard');
        System.assert(!config.containsKey('optimalMinWords'),
            'optimalMinWords removed from the wizard');
        System.assert(!config.containsKey('optimalMaxWords'),
            'optimalMaxWords removed from the wizard');
        System.assert(!config.containsKey('maxWordsThreshold'),
            'maxWordsThreshold removed from the wizard');
        System.assert(!config.containsKey('queueableBatchSize'),
            'queueableBatchSize removed from the wizard');
        System.assertEquals(false, config.get('usesDataCategories'), 'Default uses-data-categories is off');
    }

    @IsTest
    static void testSaveScanConfig_PersistsUsesDataCategories() {
        Map<String, Object> configMap = new Map<String, Object>{
            'usesDataCategories' => true
        };

        Test.startTest();
        KBSetupWizardController.saveScanConfig(JSON.serialize(configMap));
        Test.stopTest();

        KB_Scan_Config__c saved = KB_Scan_Config__c.getOrgDefaults();
        System.assertEquals(true, saved.Uses_Data_Categories__c,
            'Uses-data-categories flag should be persisted');
    }

    @IsTest
    static void testSaveScanConfig_CreatesOrgDefaults() {
        // Only persist fields the controller actively writes. Dead fields
        // (minSummaryLength, duplicationThreshold, einsteinModelName, etc.)
 // have been retired — see CLAUDE.md dead-field list. removed
        // the Article Length / Title word-count fields (minTitleLength,
        // minArticleWordCount, optimalMinWords, optimalMaxWords, maxWordsThreshold)
        // from the wizard entirely; the four word-count fields were dead and deleted.
        Map<String, Object> configMap = new Map<String, Object>{
            'freshnessThresholdMonths' => 6,
            'freshnessCriticalMonths' => 18
        };

        Test.startTest();
        KBSetupWizardController.saveScanConfig(JSON.serialize(configMap));
        Test.stopTest();

        KB_Scan_Config__c saved = KB_Scan_Config__c.getOrgDefaults();
        System.assertEquals(6, saved.Freshness_Threshold_Months__c, 'Freshness threshold saved');
        System.assertEquals(18, saved.Freshness_Critical_Months__c, 'Freshness critical saved');
    }

    @IsTest
    static void testSaveScanConfig_DoesNotTouchTitleLength() {
 // Regression for Min_Title_Length__c is still read by the
        // Completeness title gate but is no longer wizard-managed — it lives
        // only on the KB_Scan_Config__c custom setting. Even if a caller passes
        // the retired minTitleLength key, the wizard must not overwrite the
 // admin-set value. (The four word-count fields were deleted in.)
        KB_Scan_Config__c seed = new KB_Scan_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Min_Title_Length__c = 10
        );
        upsert seed;

        Map<String, Object> configMap = new Map<String, Object>{
            'minTitleLength' => 99
        };

        Test.startTest();
        KBSetupWizardController.saveScanConfig(JSON.serialize(configMap));
        Test.stopTest();

        KB_Scan_Config__c saved = KB_Scan_Config__c.getOrgDefaults();
        System.assertEquals(10, saved.Min_Title_Length__c,
            'Wizard must not overwrite the custom-setting title-length value');
    }

    @IsTest
    static void testSaveScanConfig_UpdatesExisting() {
        KB_Scan_Config__c config = new KB_Scan_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Freshness_Threshold_Months__c = 12
        );
        upsert config;

        Map<String, Object> updateMap = new Map<String, Object>{
            'freshnessThresholdMonths' => 9
        };

        Test.startTest();
        KBSetupWizardController.saveScanConfig(JSON.serialize(updateMap));
        Test.stopTest();

        KB_Scan_Config__c saved = KB_Scan_Config__c.getOrgDefaults();
        System.assertEquals(9, saved.Freshness_Threshold_Months__c, 'Updated freshness threshold');
    }

    @IsTest
    static void testSaveScanConfig_InvalidJSON() {
        Boolean exceptionThrown = false;
        try {
            KBSetupWizardController.saveScanConfig('not valid json{');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw AuraHandledException for invalid JSON');
    }

    @IsTest
    static void testGetScanConfig_WithExistingValues() {
        KB_Scan_Config__c config = new KB_Scan_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Freshness_Threshold_Months__c = 6
        );
        upsert config;

        Map<String, Object> result = KBSetupWizardController.getScanConfig();
        System.assertEquals(6, result.get('freshnessThresholdMonths'), 'Should return saved value');
    }

    // ==================== Step 2: Score Weights ====================

    @IsTest
    static void testGetScoreWeights_ReturnsDefaults() {
        Map<String, Decimal> weights = KBSetupWizardController.getScoreWeights();

        System.assertNotEquals(null, weights, 'Weights should not be null');
        // Keys are DeveloperNames from KB_Scoring_Dimension__mdt (PascalCase).
        // Values come from CMDT Default_Weight__c when Weights_JSON__c is empty.
        System.assertEquals(0.30, weights.get('Completeness'), 'Default completeness weight');
        System.assertEquals(0.20, weights.get('Structure'), 'Default structure weight');
        System.assertEquals(0.10, weights.get('Clarity'), 'Default clarity weight');
        System.assertEquals(0.10, weights.get('Freshness'), 'Default freshness weight');
        System.assertEquals(0.15, weights.get('Duplication'), 'Default duplication weight');
        System.assertEquals(0.15, weights.get('Conflict'), 'Default conflict weight');
    }

    @IsTest
    static void testSaveScoreWeights_ValidWeights() {
        Map<String, Object> weightsMap = new Map<String, Object>{
            'Completeness' => 0.30,
            'Structure' => 0.20,
            'Clarity' => 0.10,
            'Freshness' => 0.10,
            'Duplication' => 0.15,
            'Conflict' => 0.15
        };

        Test.startTest();
        KBSetupWizardController.saveScoreWeights(JSON.serialize(weightsMap));
        Test.stopTest();

        KB_Score_Weight__c saved = KB_Score_Weight__c.getOrgDefaults();
        System.assertNotEquals(null, saved.Weights_JSON__c, 'Weights_JSON__c should be populated');
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(saved.Weights_JSON__c);
        System.assertEquals(0.30, Decimal.valueOf(String.valueOf(parsed.get('Completeness'))), 'Completeness saved');
        System.assertEquals(0.20, Decimal.valueOf(String.valueOf(parsed.get('Structure'))), 'Structure saved');
    }

    @IsTest
    static void testSaveScoreWeights_InvalidTotal() {
        Map<String, Object> weightsMap = new Map<String, Object>{
            'Completeness' => 0.50,
            'Structure' => 0.50,
            'Clarity' => 0.10
        };

        Boolean exceptionThrown = false;
        try {
            KBSetupWizardController.saveScoreWeights(JSON.serialize(weightsMap));
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw AuraHandledException for invalid weight total');
    }

    @IsTest
    static void testSaveScoreWeights_InvalidJSON() {
        Boolean exceptionThrown = false;
        try {
            KBSetupWizardController.saveScoreWeights('bad json');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw for invalid JSON');
    }

    @IsTest
    static void testGetScoreWeights_WithExistingValues() {
        // Seed only Completeness + Structure; other dims should fall back to CMDT defaults.
        // Note: two-key seed won't sum to 1.0, which is fine for read-only tests
        // (getScoreWeights just returns the merged map; it doesn't validate totals).
        Map<String, Decimal> seeded = new Map<String, Decimal>{
            'Completeness' => 0.30,
            'Structure' => 0.10
        };
        KB_Score_Weight__c weights = new KB_Score_Weight__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Weights_JSON__c = JSON.serialize(seeded)
        );
        upsert weights;

        // DimensionRegistry caches per transaction — clear it so the test
        // picks up the newly-seeded custom setting.
        DimensionRegistry.resetCache();

        Map<String, Decimal> result = KBSetupWizardController.getScoreWeights();
        System.assertEquals(0.30, result.get('Completeness'), 'Should return saved Completeness');
        System.assertEquals(0.10, result.get('Structure'), 'Should return saved Structure');
    }

    // ==================== Edge Cases & Cross-Cutting ====================

    @IsTest
    static void testSaveScanConfig_PartialUpdate() {
        // Only send a subset of fields
        Map<String, Object> partial = new Map<String, Object>{
            'freshnessThresholdMonths' => 3
        };

        Test.startTest();
        KBSetupWizardController.saveScanConfig(JSON.serialize(partial));
        Test.stopTest();

        KB_Scan_Config__c saved = KB_Scan_Config__c.getOrgDefaults();
        System.assertEquals(3, saved.Freshness_Threshold_Months__c, 'Should save partial update');
    }

    @IsTest
    static void testSaveScoreWeights_ExactlyOnePointZero() {
        Map<String, Object> weightsMap = new Map<String, Object>{
            'Completeness' => 0.20,
            'Structure' => 0.20,
            'Clarity' => 0.15,
            'Freshness' => 0.15,
            'Duplication' => 0.15,
            'Conflict' => 0.15
        };

        Test.startTest();
        KBSetupWizardController.saveScoreWeights(JSON.serialize(weightsMap));
        Test.stopTest();

        KB_Score_Weight__c saved = KB_Score_Weight__c.getOrgDefaults();
        System.assertNotEquals(null, saved.Weights_JSON__c, 'Weights_JSON__c populated');
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(saved.Weights_JSON__c);
        System.assertEquals(0.20, Decimal.valueOf(String.valueOf(parsed.get('Completeness'))), 'Equal weight saved');
    }

    @IsTest
    static void testSaveVectorSearchConfig_ActiveSetsImplementationClass() {
        Map<String, Object> config = new Map<String, Object>{
            'searchIndexName' => 'KA_Knowledge_index',
            'maxResults' => 20,
            'dataSpaceName' => 'default',
            'isActive' => true
        };

        Test.startTest();
        KBSetupWizardController.saveVectorSearchConfig(JSON.serialize(config));
        Test.stopTest();

        KB_Vector_Search_Config__c saved = KB_Vector_Search_Config__c.getOrgDefaults();
        System.assertEquals('ConnectApiVectorSearchService', saved.Implementation_Class__c, 'Active=true must set ConnectApiVectorSearchService');
        System.assertEquals('KA_Knowledge_index', saved.Search_Index_Name__c, 'Search index name saved');
        System.assertEquals(true, saved.Is_Active__c, 'Is_Active saved');
    }

    @IsTest
    static void testSaveVectorSearchConfig_InactiveSwitchesToSoqlFallback() {
        Map<String, Object> config = new Map<String, Object>{
            'searchIndexName' => 'KA_Knowledge_index',
            'isActive' => false
        };

        Test.startTest();
        KBSetupWizardController.saveVectorSearchConfig(JSON.serialize(config));
        Test.stopTest();

        KB_Vector_Search_Config__c saved = KB_Vector_Search_Config__c.getOrgDefaults();
        System.assertEquals('Tier1SOQLFallbackService', saved.Implementation_Class__c,
            'Active=false routes through the SOQL fallback implementation');
        System.assertEquals(false, saved.Is_Active__c, 'Is_Active saved as false');
    }

    @IsTest
    static void testGetPipelineConfig_IncludesAdvancedFields() {
        Map<String, Object> config = KBSetupWizardController.getPipelineConfig();

        System.assertNotEquals(null, config, 'Config should not be null');
        System.assert(config.containsKey('maxCalloutLimit'), 'Must include maxCalloutLimit');
        System.assert(config.containsKey('defaultExecutionMode'), 'Must include defaultExecutionMode');
        System.assertEquals(90, config.get('maxCalloutLimit'), 'Default max callout limit');
        System.assertEquals('DEDUPLICATION', config.get('defaultExecutionMode'), 'Default execution mode');
 // Input Scope / Frequency dropped — never read by any runtime caller.
        System.assert(!config.containsKey('inputScope'), 'inputScope dropped');
        System.assert(!config.containsKey('frequency'), 'frequency dropped');
 // Auto-Merge Threshold dropped — auto-merge band gate retired.
        System.assert(!config.containsKey('autoMergeThreshold'), 'autoMergeThreshold dropped');
 // Confidence_Threshold__c removed — wizard no longer surfaces it.
        System.assert(!config.containsKey('confidenceThreshold'),
            'confidenceThreshold no longer surfaced by wizard');
 // Chunking fields removed from wizard surface — schema retained.
        System.assert(!config.containsKey('maxChunksPerArticle'),
            'maxChunksPerArticle no longer surfaced by wizard');
        System.assert(!config.containsKey('maxChunkSize'),
            'maxChunkSize no longer surfaced by wizard');
 // Quality-gate thresholds moved out of wizard — schema retained.
        System.assert(!config.containsKey('minCompletenessScore'),
            'minCompletenessScore no longer surfaced by wizard');
        System.assert(!config.containsKey('minStructureScore'),
            'minStructureScore no longer surfaced by wizard');
        System.assert(!config.containsKey('minClarityScore'),
            'minClarityScore no longer surfaced by wizard');
    }

    @IsTest
    static void testSavePipelineConfig_PersistsAdvancedFields() {
        Map<String, Object> config = new Map<String, Object>{
            'manualReviewThreshold' => 50,
            'tier2TopK' => 20,
            'tier2SimilarityThreshold' => 0.75,
            'maxCalloutLimit' => 85
        };

        Test.startTest();
        KBSetupWizardController.savePipelineConfig(JSON.serialize(config));
        Test.stopTest();

        KB_Pipeline_Config__c saved = KB_Pipeline_Config__c.getOrgDefaults();
        System.assertEquals(85, saved.Max_Callout_Limit__c, 'Max callout limit saved');
        System.assertEquals(50, saved.Manual_Review_Threshold__c,
            'Off-screen Manual Review Threshold still accepted when supplied');
 // Transformation retired: savePipelineConfig hardcodes
        // Default_Execution_Mode__c to DEDUPLICATION on every save regardless
        // of the client payload, so legacy rows get coerced and any drifted
        // client payload is ignored.
        System.assertEquals('DEDUPLICATION', saved.Default_Execution_Mode__c, 'Execution mode hardcoded to DEDUPLICATION');
 // Input_Scope__c / Frequency__c dropped — no longer saved.
    }

    @IsTest
    static void testSavePipelineConfig_InvalidJSON() {
        Boolean exceptionThrown = false;
        try {
            KBSetupWizardController.savePipelineConfig('not valid json{');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw AuraHandledException for invalid JSON');
    }

    @IsTest
    static void testSaveVectorSearchConfig_InvalidJSON() {
        Boolean exceptionThrown = false;
        try {
            KBSetupWizardController.saveVectorSearchConfig('not valid json{');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assert(exceptionThrown, 'Should throw AuraHandledException for invalid JSON');
    }

    @IsTest
    static void testSaveScanConfig_PersistsContentFieldMapping() {
        Map<String, Object> configMap = new Map<String, Object>{
            'contentFieldMapping' => new List<String>{ 'Body__c', 'Extra_Notes__c', '' }
        };

        Test.startTest();
        KBSetupWizardController.saveScanConfig(JSON.serialize(configMap));
        Test.stopTest();

        KB_Scan_Config__c saved = KB_Scan_Config__c.getOrgDefaults();
        Assert.areEqual('Body__c,Extra_Notes__c', saved.Content_Field_Mapping_JSON__c,
            'Blank entries are dropped and remaining fields joined');
    }

    @IsTest
    static void testSaveScanConfig_EmptyContentFieldMapping_ClearsField() {
        KB_Scan_Config__c seed = new KB_Scan_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Content_Field_Mapping_JSON__c = 'Body__c'
        );
        upsert seed;

        Map<String, Object> configMap = new Map<String, Object>{
            'contentFieldMapping' => new List<String>()
        };

        Test.startTest();
        KBSetupWizardController.saveScanConfig(JSON.serialize(configMap));
        Test.stopTest();

        KB_Scan_Config__c saved = KB_Scan_Config__c.getOrgDefaults();
        Assert.isNull(saved.Content_Field_Mapping_JSON__c, 'Empty mapping list clears the field');
    }

    @IsTest
    static void testGetScanConfig_ReturnsContentFieldMapping() {
        KB_Scan_Config__c seed = new KB_Scan_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Content_Field_Mapping_JSON__c = 'Body__c, Extra_Notes__c'
        );
        upsert seed;

        Test.startTest();
        Map<String, Object> config = KBSetupWizardController.getScanConfig();
        Test.stopTest();

        List<String> mapping = (List<String>) config.get('contentFieldMapping');
        Assert.areEqual(2, mapping.size(), 'Both configured content fields returned, trimmed');
        Assert.isTrue(mapping.contains('Body__c'));
        Assert.isTrue(mapping.contains('Extra_Notes__c'));
    }

}
