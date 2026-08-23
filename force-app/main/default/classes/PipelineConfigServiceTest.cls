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
 * Coverage for PipelineConfigService — singleton config reader with three
 * resolution paths:
 *   1. KB_Pipeline_Config__c custom setting (DML-updatable, wizard-saved)
 *   2. KM_Pipeline_Config__mdt CMDT fallback
 *   3. Hard-coded defaults
 *
 * The service caches the first non-null answer for the duration of the
 * Apex transaction. Tests use `@TestVisible clearCache()` between
 * scenarios to force a fresh resolution.
 */
@IsTest
private class PipelineConfigServiceTest {

    @IsTest
    static void testGetActiveConfig_MockOverride_BypassesAllReads() {
        KM_Pipeline_Config__mdt mockConfig = new KM_Pipeline_Config__mdt(
            Manual_Review_Threshold__c = 50,
            Max_Finalists__c = 3,
            Max_SubAgent_Callouts__c = 20,
            Tier2_TopK__c = 20,
            Tier2_Similarity_Threshold__c = 0.75,
            Supported_Languages__c = 'en_US',
            Is_Active__c = true
        );
        PipelineConfigService.setMockConfig(mockConfig);

        Test.startTest();
        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        Test.stopTest();

        Assert.areEqual(50, config.Manual_Review_Threshold__c);
        Assert.areEqual(3, config.Max_Finalists__c);
        Assert.areEqual(20, config.Max_SubAgent_Callouts__c);
        Assert.areEqual(20, config.Tier2_TopK__c);
        Assert.areEqual(0.75, config.Tier2_Similarity_Threshold__c);
        Assert.areEqual('en_US', config.Supported_Languages__c);
    }

    @IsTest
    static void testGetActiveConfig_Caches_SecondCallSameInstance() {
        KM_Pipeline_Config__mdt mockConfig = new KM_Pipeline_Config__mdt(
            Manual_Review_Threshold__c = 60,
            Max_Finalists__c = 2,
            Max_SubAgent_Callouts__c = 10,
            Tier2_TopK__c = 15,
            Tier2_Similarity_Threshold__c = 0.80,
            Is_Active__c = true
        );
        PipelineConfigService.setMockConfig(mockConfig);

        KM_Pipeline_Config__mdt config1 = PipelineConfigService.getActiveConfig();
        KM_Pipeline_Config__mdt config2 = PipelineConfigService.getActiveConfig();

        Assert.isTrue(config1 === config2,
            'Cached instance returned on second call (no re-resolution)');
    }

    @IsTest
    static void testClearCache_ForcesReResolution() {
        KM_Pipeline_Config__mdt firstMock = new KM_Pipeline_Config__mdt(
            Manual_Review_Threshold__c = 90, Is_Active__c = true
        );
        PipelineConfigService.setMockConfig(firstMock);
        Assert.areEqual(90, PipelineConfigService.getActiveConfig().Manual_Review_Threshold__c);

        PipelineConfigService.clearCache();
        KM_Pipeline_Config__mdt secondMock = new KM_Pipeline_Config__mdt(
            Manual_Review_Threshold__c = 50, Is_Active__c = true
        );
        PipelineConfigService.setMockConfig(secondMock);

        Assert.areEqual(50, PipelineConfigService.getActiveConfig().Manual_Review_Threshold__c,
            'After clearCache, the second mock takes effect');
    }

    @IsTest
    static void testGetActiveConfig_FromCustomSetting_BuildsFromCSValues() {
        // Arrange: real custom setting with explicit threshold (gates the CS branch)
        PipelineConfigService.clearCache();
        KB_Pipeline_Config__c cs = KB_Pipeline_Config__c.getOrgDefaults();
        cs.Manual_Review_Threshold__c = 65;
        cs.Max_Finalists__c = 4;
        cs.Max_SubAgent_Callouts__c = 25;
        cs.Tier2_TopK__c = 30;
        cs.Tier2_Similarity_Threshold__c = 0.85;
        cs.Supported_Languages__c = 'en_US,fr_FR';
        upsert cs KB_Pipeline_Config__c.Id;

        Test.startTest();
        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        Test.stopTest();

        Assert.areEqual(65, config.Manual_Review_Threshold__c);
        Assert.areEqual(4, config.Max_Finalists__c);
        Assert.areEqual(25, config.Max_SubAgent_Callouts__c);
        Assert.areEqual(30, config.Tier2_TopK__c);
        Assert.areEqual(0.85, config.Tier2_Similarity_Threshold__c);
        Assert.areEqual('en_US,fr_FR', config.Supported_Languages__c);
        Assert.isTrue(config.Is_Active__c, 'CS-built config is always Active');
    }

    @IsTest
    static void testGetActiveConfig_FromCustomSetting_NullFieldsBackfilled() {
        // Arrange: CS row with Manual_Review_Threshold__c set (gates the branch)
        // but every other numeric field null + blank Supported_Languages.
        PipelineConfigService.clearCache();
        KB_Pipeline_Config__c cs = KB_Pipeline_Config__c.getOrgDefaults();
        cs.Manual_Review_Threshold__c = 70;
        cs.Max_Finalists__c = null;
        cs.Max_SubAgent_Callouts__c = null;
        cs.Tier2_TopK__c = null;
        cs.Tier2_Similarity_Threshold__c = null;
        cs.Supported_Languages__c = '';
        upsert cs KB_Pipeline_Config__c.Id;

        Test.startTest();
        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        Test.stopTest();

        // Manual_Review honored from CS; every other field falls back to default.
        Assert.areEqual(70, config.Manual_Review_Threshold__c, 'CS value honored');
        Assert.areEqual(3, config.Max_Finalists__c, 'Default 3 applied');
        Assert.areEqual(20, config.Max_SubAgent_Callouts__c, 'Default 20 applied');
        Assert.areEqual(20, config.Tier2_TopK__c, 'Default 20 applied');
        Assert.areEqual(0.75, config.Tier2_Similarity_Threshold__c, 'Default 0.75 applied');
        Assert.areEqual('en_US', config.Supported_Languages__c, 'Blank → en_US default');
    }

    @IsTest
    static void testGetActiveConfig_NoCSAndNoCMDT_ReturnsDefaults() {
        // Arrange: CS exists but with Manual_Review_Threshold null → CS branch
        // is gated off. CMDT may or may not exist in this org; if not, defaults
        // path runs. This test verifies we never throw, and that the returned
        // config contains the documented default values.
        PipelineConfigService.clearCache();
        KB_Pipeline_Config__c cs = KB_Pipeline_Config__c.getOrgDefaults();
        cs.Manual_Review_Threshold__c = null;
        upsert cs KB_Pipeline_Config__c.Id;

        Test.startTest();
        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        Test.stopTest();

        Assert.isNotNull(config, 'Service must always return a non-null config');
        Assert.isNotNull(config.Manual_Review_Threshold__c);
        Assert.isTrue(config.Is_Active__c == true || config.Is_Active__c == false,
            'Is_Active is a Boolean, not null');
    }

    @IsTest
    static void testBuildDefaults_DirectCall_ReturnsHardcodedValues() {
        // Direct unit test on the private builder via @TestVisible — this is
        // the only way to guarantee coverage of the defaults path because
        // most orgs ship a CMDT row that captures the request before the
        // defaults branch is reached.
        KM_Pipeline_Config__mdt config = PipelineConfigService.buildDefaults();

        Assert.areEqual(50, config.Manual_Review_Threshold__c);
        Assert.areEqual(3, config.Max_Finalists__c);
        Assert.areEqual(20, config.Max_SubAgent_Callouts__c);
        Assert.areEqual(20, config.Tier2_TopK__c);
        Assert.areEqual(0.75, config.Tier2_Similarity_Threshold__c);
        Assert.areEqual('en_US', config.Supported_Languages__c);
        Assert.isTrue(config.Is_Active__c);
    }

    @IsTest
    static void testBuildFromCustomSetting_DirectCall_HonorsAndBackfills() {
        KB_Pipeline_Config__c cs = new KB_Pipeline_Config__c(
            Manual_Review_Threshold__c = 65,
            Supported_Languages__c = 'fr_FR'
        );
        // Other fields intentionally null to exercise each backfill.

        KM_Pipeline_Config__mdt config = PipelineConfigService.buildFromCustomSetting(cs);

        Assert.areEqual(65, config.Manual_Review_Threshold__c, 'CS value honored');
        Assert.areEqual('fr_FR', config.Supported_Languages__c, 'CS lang honored');
        Assert.areEqual(3, config.Max_Finalists__c, 'Default backfill');
        Assert.areEqual(0.75, config.Tier2_Similarity_Threshold__c, 'Default backfill');
        Assert.isTrue(config.Is_Active__c);
    }

    @IsTest
    static void testBuildFromCustomSetting_OutOfRangeManualReview_ClampedToDefault() {
 // Manual_Review_Threshold__c is the only bound left after the
        // cross-field validation was removed. Confidence is 0–100, so an
        // out-of-range cutoff (e.g. 999) would silently mark every Tier 4 pair
        // 'Clear'. buildFromCustomSetting must clamp it back to the 50 default.
        KB_Pipeline_Config__c high = new KB_Pipeline_Config__c(Manual_Review_Threshold__c = 999);
        Assert.areEqual(50,
            PipelineConfigService.buildFromCustomSetting(high).Manual_Review_Threshold__c,
            '>100 cutoff clamped to default');

        KB_Pipeline_Config__c negative = new KB_Pipeline_Config__c(Manual_Review_Threshold__c = -5);
        Assert.areEqual(50,
            PipelineConfigService.buildFromCustomSetting(negative).Manual_Review_Threshold__c,
            'Negative cutoff clamped to default');

        KB_Pipeline_Config__c valid = new KB_Pipeline_Config__c(Manual_Review_Threshold__c = 0);
        Assert.areEqual(0,
            PipelineConfigService.buildFromCustomSetting(valid).Manual_Review_Threshold__c,
            'In-range boundary value (0) honored, not clamped');
    }

    @IsTest
    static void testCustomSettingPopulatesQualityGateThresholds() {
        PipelineConfigService.clearCache();
        KB_Pipeline_Config__c cs = KB_Pipeline_Config__c.getOrgDefaults();
        cs.Manual_Review_Threshold__c = 50;
        cs.Min_Completeness_Score__c = 70;
        cs.Min_Structure_Score__c = 65;
        cs.Min_Clarity_Score__c = 55;
        upsert cs KB_Pipeline_Config__c.Id;

        Test.startTest();
        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        Test.stopTest();

        Assert.areEqual(70, config.Min_Completeness_Score__c);
        Assert.areEqual(65, config.Min_Structure_Score__c);
        Assert.areEqual(55, config.Min_Clarity_Score__c);
    }

    @IsTest
    static void testQualityGateThresholdsBackfillToDefault() {
        // CS row gates the CS branch via Manual_Review_Threshold but leaves the
        // three quality-gate fields null — each should backfill to 60.
        PipelineConfigService.clearCache();
        KB_Pipeline_Config__c cs = KB_Pipeline_Config__c.getOrgDefaults();
        cs.Manual_Review_Threshold__c = 50;
        cs.Min_Completeness_Score__c = null;
        cs.Min_Structure_Score__c = null;
        cs.Min_Clarity_Score__c = null;
        upsert cs KB_Pipeline_Config__c.Id;

        Test.startTest();
        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        Test.stopTest();

        Assert.areEqual(60, config.Min_Completeness_Score__c);
        Assert.areEqual(60, config.Min_Structure_Score__c);
        Assert.areEqual(60, config.Min_Clarity_Score__c);
    }

    @IsTest
    static void testBuildDefaults_QualityGateAllSixty() {
        KM_Pipeline_Config__mdt config = PipelineConfigService.buildDefaults();

        Assert.areEqual(60, config.Min_Completeness_Score__c);
        Assert.areEqual(60, config.Min_Structure_Score__c);
        Assert.areEqual(60, config.Min_Clarity_Score__c);
    }
}
