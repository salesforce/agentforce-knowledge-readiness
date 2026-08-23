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
 * Coverage for KBRuntimeConfigService — the static config-resolution
 * facade over KB_Pipeline_Config__c, KB_Scan_Config__c, and
 * KB_Setup_Wizard_State__c hierarchy custom settings.
 *
 * Each test seeds the Hierarchy "Org Defaults" tier (returned by
 * `getOrgDefaults()`) with `upsert <var> <SObject>.Id` — same pattern
 * used by Tier1SOQLFallbackServiceTest. Pure custom-setting work — no
 * KAV DML, no callouts, no async.
 */
@IsTest
private class KBRuntimeConfigServiceTest {

    // ──────────────────────────────────────────────────────────────────────
    // RuntimeFilters DTO helpers
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testRuntimeFilters_TitleLikePattern_BlankReturnsNull() {
        KBRuntimeConfigService.RuntimeFilters f = new KBRuntimeConfigService.RuntimeFilters();
        f.titlePattern = '';
        Assert.isNull(f.getTitleLikePattern(), 'Blank pattern returns null');
    }

    @IsTest
    static void testRuntimeFilters_TitleLikePattern_WrappedInPercent() {
        KBRuntimeConfigService.RuntimeFilters f = new KBRuntimeConfigService.RuntimeFilters();
        f.titlePattern = 'foo';
        Assert.areEqual('%foo%', f.getTitleLikePattern(), 'Pattern wrapped in % literals');
    }

    @IsTest
    static void testRuntimeFilters_IsKnowledgeArticleType_BlankIsTrue() {
        KBRuntimeConfigService.RuntimeFilters f = new KBRuntimeConfigService.RuntimeFilters();
        f.articleType = '';
        Assert.isTrue(f.isKnowledgeArticleType(), 'Blank articleType defaults to Knowledge__kav');
    }

    @IsTest
    static void testRuntimeFilters_IsKnowledgeArticleType_ExplicitMatch() {
        KBRuntimeConfigService.RuntimeFilters f = new KBRuntimeConfigService.RuntimeFilters();
        f.articleType = 'Knowledge__kav';
        Assert.isTrue(f.isKnowledgeArticleType(), 'Knowledge__kav is the recognized type');
    }

    @IsTest
    static void testRuntimeFilters_IsKnowledgeArticleType_OtherIsFalse() {
        KBRuntimeConfigService.RuntimeFilters f = new KBRuntimeConfigService.RuntimeFilters();
        f.articleType = 'FAQ__kav';
        Assert.isFalse(f.isKnowledgeArticleType(), 'Non-Knowledge type returns false');
    }

    // ──────────────────────────────────────────────────────────────────────
    // getRuntimeFilters
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetRuntimeFilters_DefaultsWhenNoConfig() {
        Test.startTest();
        KBRuntimeConfigService.RuntimeFilters f = KBRuntimeConfigService.getRuntimeFilters();
        Test.stopTest();

        Assert.areEqual('Online', f.publishStatus, 'Default publishStatus is Online');
        Assert.areEqual('en_US', f.language, 'Default language is en_US');
        Assert.isTrue(f.supportedLanguages.contains('en_US'),
            'Default supportedLanguages includes en_US');
    }

    @IsTest
    static void testGetRuntimeFilters_SupportedLanguagesCommaSeparated() {
        KB_Pipeline_Config__c cfg = KB_Pipeline_Config__c.getOrgDefaults();
        cfg.Supported_Languages__c = 'en_US,fr_FR,es';
        upsert cfg KB_Pipeline_Config__c.Id;

        Test.startTest();
        KBRuntimeConfigService.RuntimeFilters f = KBRuntimeConfigService.getRuntimeFilters();
        Test.stopTest();

        Assert.areEqual(3, f.supportedLanguages.size(), 'Three languages parsed');
        Assert.isTrue(f.supportedLanguages.contains('fr_FR'));
        Assert.areEqual('en_US', f.language, 'Default en_US preserved when in supported set');
    }

    @IsTest
    static void testGetRuntimeFilters_SupportedLanguagesSemicolonSeparated() {
        // Exercises the `;`→`,` normalization branch in parseLanguageSet.
        KB_Pipeline_Config__c cfg = KB_Pipeline_Config__c.getOrgDefaults();
        cfg.Supported_Languages__c = 'en_US;de';
        upsert cfg KB_Pipeline_Config__c.Id;

        Test.startTest();
        KBRuntimeConfigService.RuntimeFilters f = KBRuntimeConfigService.getRuntimeFilters();
        Test.stopTest();

        Assert.areEqual(2, f.supportedLanguages.size(), 'Semicolon-separated also parses');
        Assert.isTrue(f.supportedLanguages.contains('de'));
    }

    @IsTest
    static void testGetRuntimeFilters_LanguageFallbackWhenDefaultNotSupported() {
        // When supportedLanguages does NOT include en_US, language flips to
        // the alphabetically-first supported language (firstLanguage helper).
        KB_Pipeline_Config__c cfg = KB_Pipeline_Config__c.getOrgDefaults();
        cfg.Supported_Languages__c = 'fr_FR;de';
        upsert cfg KB_Pipeline_Config__c.Id;

        Test.startTest();
        KBRuntimeConfigService.RuntimeFilters f = KBRuntimeConfigService.getRuntimeFilters();
        Test.stopTest();

        Assert.areEqual('de', f.language, 'Language flips to alphabetically-first supported value');
        Assert.isFalse(f.supportedLanguages.contains('en_US'),
            'en_US not in the configured set');
    }

    @IsTest
    static void testGetRuntimeFilters_PrefiltersJSONOverridesAll() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        state.Query_Prefilters_JSON__c = '{'
            + '"publishStatus":"Draft",'
            + '"language":"fr_FR",'
            + '"titlePattern":"How to",'
            + '"articleType":"FAQ__kav"'
            + '}';
        upsert state KB_Setup_Wizard_State__c.Id;

        Test.startTest();
        KBRuntimeConfigService.RuntimeFilters f = KBRuntimeConfigService.getRuntimeFilters();
        Test.stopTest();

        Assert.areEqual('Draft', f.publishStatus);
        Assert.areEqual('fr_FR', f.language);
        Assert.areEqual('How to', f.titlePattern);
        Assert.areEqual('FAQ__kav', f.articleType);
        Assert.isTrue(f.supportedLanguages.contains('fr_FR'),
            'Prefilter language is added to supportedLanguages set');
    }

    @IsTest
    static void testGetRuntimeFilters_PrefiltersJSONMalformedKeepsDefaults() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        state.Query_Prefilters_JSON__c = '{not-valid-json';
        upsert state KB_Setup_Wizard_State__c.Id;

        Test.startTest();
        KBRuntimeConfigService.RuntimeFilters f = KBRuntimeConfigService.getRuntimeFilters();
        Test.stopTest();

        // Catch path swallows the error and preserves defaults.
        Assert.areEqual('Online', f.publishStatus, 'Default preserved when JSON malformed');
        Assert.areEqual('en_US', f.language);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Numeric / scope getters — default vs override
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetProcessingBatchSize_DefaultAndOverride() {
        Assert.areEqual(KBRuntimeConfigService.DEFAULT_BATCH_SIZE,
            KBRuntimeConfigService.getProcessingBatchSize(),
            'Default batch size when unset');

        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Queueable_Batch_Size__c = 25;
        upsert cfg KB_Scan_Config__c.Id;

        Assert.areEqual(25, KBRuntimeConfigService.getProcessingBatchSize(),
            'Override honored');
    }

    @IsTest
    static void testGetExecutionMode_AllPaths() {
        // Default with no config
        Assert.areEqual(KBRuntimeConfigService.MODE_DEDUPLICATION,
            KBRuntimeConfigService.getExecutionMode());

        KB_Pipeline_Config__c cfg = KB_Pipeline_Config__c.getOrgDefaults();
        cfg.Default_Execution_Mode__c = 'BOGUS';
        upsert cfg KB_Pipeline_Config__c.Id;
        Assert.areEqual(KBRuntimeConfigService.MODE_DEDUPLICATION,
            KBRuntimeConfigService.getExecutionMode(),
            'Invalid mode falls back to DEDUPLICATION');
    }

    @IsTest
    static void testGetMaxCalloutLimit_DefaultAndOverride() {
        Assert.areEqual(90, KBRuntimeConfigService.getMaxCalloutLimit(),
            'Default callout limit is 90');

        KB_Pipeline_Config__c cfg = KB_Pipeline_Config__c.getOrgDefaults();
        cfg.Max_Callout_Limit__c = 60;
        upsert cfg KB_Pipeline_Config__c.Id;

        Assert.areEqual(60, KBRuntimeConfigService.getMaxCalloutLimit());
    }

    @IsTest
    static void testGetMaxChunkSize_DefaultAndOverride() {
        Assert.areEqual(500, KBRuntimeConfigService.getMaxChunkSize(),
            'Default chunk size is 500');

        KB_Pipeline_Config__c cfg = KB_Pipeline_Config__c.getOrgDefaults();
        cfg.Max_Chunk_Size__c = 1000;
        upsert cfg KB_Pipeline_Config__c.Id;

        Assert.areEqual(1000, KBRuntimeConfigService.getMaxChunkSize());
    }
}
