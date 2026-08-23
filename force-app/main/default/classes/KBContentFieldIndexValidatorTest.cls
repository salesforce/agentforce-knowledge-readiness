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
 * Coverage for KBContentFieldIndexValidator.
 *
 * The validator is hierarchy-custom-setting / global-describe driven, so we
 * exercise it through the @TestVisible overload that takes already-built
 * config records. The chunk DMO describe is org-state — present in test orgs
 * with Data Cloud provisioned, absent otherwise — so the "indeterminate"
 * branch is exercised via a deterministic non-existent index name.
 */
@IsTest
private class KBContentFieldIndexValidatorTest {

    private static KB_Scan_Config__c scanCfgWithFields(String csv) {
        KB_Scan_Config__c c = new KB_Scan_Config__c();
        c.Content_Field_Mapping_JSON__c = csv;
        return c;
    }

    private static KB_Vector_Search_Config__c vectorCfg(
        String indexName, Boolean isActive, String implClass
    ) {
        KB_Vector_Search_Config__c v = new KB_Vector_Search_Config__c();
        v.Search_Index_Name__c = indexName;
        v.Is_Active__c = isActive;
        v.Implementation_Class__c = implClass;
        return v;
    }

    @IsTest
    static void testGetMismatch_NoSelectedFields_NoConfig() {
        Test.startTest();
        Map<String, Object> result = KBContentFieldIndexValidator.getMismatch(
            scanCfgWithFields(null),
            vectorCfg('any_index', true, 'ConnectApiVectorSearchService')
        );
        Test.stopTest();

        Assert.areEqual(KBContentFieldIndexValidator.STATUS_NO_CONFIG, result.get('status'));
        Assert.isTrue(((List<String>) result.get('selectedFields')).isEmpty(),
            'No selected fields when scan config is blank');
        Assert.isNotNull(result.get('reason'));
    }

    @IsTest
    static void testGetMismatch_NoIndex_Indeterminate() {
        Test.startTest();
        Map<String, Object> result = KBContentFieldIndexValidator.getMismatch(
            scanCfgWithFields('Summary, Title'),
            vectorCfg('', true, 'ConnectApiVectorSearchService')
        );
        Test.stopTest();

        Assert.areEqual(KBContentFieldIndexValidator.STATUS_INDETERMINATE, result.get('status'),
            'Without an index name we cannot compare → indeterminate');
        List<String> selected = (List<String>) result.get('selectedFields');
        Assert.areEqual(2, selected.size(), 'Both selected fields parsed');
        Assert.areEqual('Summary', selected[0]);
        Assert.areEqual('Title', selected[1]);
    }

    @IsTest
    static void testGetMismatch_VectorDisabled_Indeterminate() {
        // Even with a configured index, an inactive vector search means the
        // index isn't going to be queried at runtime — comparison is moot.
        Test.startTest();
        Map<String, Object> result = KBContentFieldIndexValidator.getMismatch(
            scanCfgWithFields('Summary'),
            vectorCfg('my_index', false, 'Tier1SOQLFallbackService')
        );
        Test.stopTest();

        Assert.areEqual(KBContentFieldIndexValidator.STATUS_INDETERMINATE, result.get('status'));
        Assert.isNotNull(result.get('reason'));
    }

    @IsTest
    static void testGetMismatch_ChunkDmoMissing_Indeterminate() {
        // Use a deliberately nonsense index name so the chunk DMO describe
        // misses, regardless of whether Data Cloud is provisioned in the
        // test org. This locks in the "graceful degrade, never throw" rule.
        Test.startTest();
        Map<String, Object> result = KBContentFieldIndexValidator.getMismatch(
            scanCfgWithFields('Summary,Title'),
            vectorCfg('zzz_definitely_not_an_index_42', true, 'ConnectApiVectorSearchService')
        );
        Test.stopTest();

        Assert.areEqual(KBContentFieldIndexValidator.STATUS_INDETERMINATE, result.get('status'),
            'Missing chunk DMO → indeterminate, never throw');
        Assert.areEqual('zzz_definitely_not_an_index_42_chunk__dlm', result.get('chunkDmoName'),
            'Chunk DMO name resolved per naming convention');
        Assert.isNotNull(result.get('reason'),
            'Reason populated so the wizard can render a soft-info note');
    }

    @IsTest
    static void testResolveChunkDmoName_NamingVariants() {
        Assert.areEqual('foo_chunk__dlm',
            KBContentFieldIndexValidator.resolveChunkDmoName('foo_index'));
        Assert.areEqual('foo_chunk__dlm',
            KBContentFieldIndexValidator.resolveChunkDmoName('foo_index__dlm'));
        Assert.areEqual('foo_chunk__dlm',
            KBContentFieldIndexValidator.resolveChunkDmoName('foo_chunk'));
        Assert.areEqual('foo_chunk__dlm',
            KBContentFieldIndexValidator.resolveChunkDmoName('foo_chunk__dlm'));
        Assert.areEqual('plain_chunk__dlm',
            KBContentFieldIndexValidator.resolveChunkDmoName('plain'));
        Assert.areEqual(null,
            KBContentFieldIndexValidator.resolveChunkDmoName(''),
            'Blank input → null');
        Assert.areEqual(null,
            KBContentFieldIndexValidator.resolveChunkDmoName(null),
            'Null input → null');
    }

    @IsTest
    static void testFormatWarningDetails_OkAndIndeterminate() {
        // OK path
        Map<String, Object> ok = new Map<String, Object>{
            'status' => KBContentFieldIndexValidator.STATUS_OK,
            'reason' => null,
            'selectedFields' => new List<String>{ 'Summary' },
            'indexedFields' => new List<String>{ 'Summary' },
            'missingFromIndex' => new List<String>(),
            'extraInIndex' => new List<String>()
        };
        Assert.areEqual('Content fields and search-index fields match.',
            KBContentFieldIndexValidator.formatWarningDetails(ok));

        // Indeterminate path returns the reason verbatim
        Map<String, Object> ind = new Map<String, Object>{
            'status' => KBContentFieldIndexValidator.STATUS_INDETERMINATE,
            'reason' => 'Soft-info note',
            'selectedFields' => new List<String>(),
            'missingFromIndex' => new List<String>(),
            'extraInIndex' => new List<String>()
        };
        Assert.areEqual('Soft-info note',
            KBContentFieldIndexValidator.formatWarningDetails(ind));
    }

    @IsTest
    static void testFormatWarningDetails_MismatchPhrasing() {
        Map<String, Object> mismatch = new Map<String, Object>{
            'status' => KBContentFieldIndexValidator.STATUS_MISMATCH,
            'reason' => null,
            'selectedFields' => new List<String>{ 'Summary', 'FAQ_Answer__c', 'Internal_Notes__c' },
            'indexedFields' => new List<String>{ 'Summary', 'Title' },
            'missingFromIndex' => new List<String>{ 'FAQ_Answer__c', 'Internal_Notes__c' },
            'extraInIndex' => new List<String>{ 'Title' }
        };

        String details = KBContentFieldIndexValidator.formatWarningDetails(mismatch);

        // Phrasing should be calm and surface the field names.
        Assert.isTrue(details.contains('2 of 3'), 'Mismatch count surfaced');
        Assert.isTrue(details.contains('FAQ_Answer__c'), 'Missing field listed by name');
        Assert.isTrue(details.contains('Internal_Notes__c'), 'Missing field listed by name');
        Assert.isTrue(details.contains('Title'), 'Extra index field surfaced');
        Assert.isTrue(details.contains('Dimension analysis'),
            'Phrasing explains scoring vs dedup split');
    }

    @IsTest
    static void testGetMismatch_ZeroArgOverload_RunsAgainstOrgDefaults() {
        // Smoke test the zero-arg overload — exercises the org-default getter
        // path. Test orgs default to no scan config / no vector config, so
        // status is the no-config or indeterminate branch (we accept both —
        // both are valid no-throw outcomes).
        Test.startTest();
        Map<String, Object> result = KBContentFieldIndexValidator.getMismatch();
        Test.stopTest();

        String status = (String) result.get('status');
        Assert.isTrue(
            status == KBContentFieldIndexValidator.STATUS_NO_CONFIG
                || status == KBContentFieldIndexValidator.STATUS_INDETERMINATE,
            'Default org → no config or indeterminate, never mismatch/ok'
        );
    }

    // ──────────────────────────────────────────────────────────────────────
    // Live describe coverage. The diff path (Step 4) and the structural-
    // exclusion list in describeIndexedFieldNames are unreachable when the
    // chunk DMO can't be described — every other test exits at the
    // "indeterminate" branch. These tests inject a real, always-describable
    // SObjectType (Knowledge__kav, which always exists once Knowledge is
    // enabled) so we can lock the structural exclusion + diff arithmetic +
    // DMO-name normalization down with assertions against an actual Apex
    // describe.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testDescribeIndexedFieldNames_StripsStructuralFields() {
        Schema.SObjectType kav = Knowledge__kav.SObjectType;

        Test.startTest();
        List<String> fields =
            KBContentFieldIndexValidator.describeIndexedFieldNames(kav);
        Test.stopTest();

        Assert.isFalse(fields.isEmpty(),
            'Real SObject describe must return at least one non-structural field');

        // Structural columns must never appear in the diff surface.
        Set<String> lower = new Set<String>();
        for (String f : fields) lower.add(f.toLowerCase());
        Assert.isFalse(lower.contains('id'), 'Id stripped');
        Assert.isFalse(lower.contains('createddate'), 'CreatedDate stripped');
        Assert.isFalse(lower.contains('lastmodifieddate'), 'LastModifiedDate stripped');
        Assert.isFalse(lower.contains('createdbyid'), 'CreatedById stripped');
        Assert.isFalse(lower.contains('isdeleted'), 'IsDeleted stripped');

        // Sorted output — small, deterministic contract for the warning text.
        List<String> copy = new List<String>(fields);
        copy.sort();
        Assert.areEqual(copy, fields, 'describeIndexedFieldNames output is sorted');
    }

    @IsTest
    static void testDescribeIndexedFieldNames_NullType_ReturnsEmpty() {
        Test.startTest();
        List<String> fields = KBContentFieldIndexValidator.describeIndexedFieldNames(null);
        Test.stopTest();

        Assert.isTrue(fields.isEmpty(), 'Null SObjectType short-circuits to an empty list');
    }

    @IsTest
    static void testNormalizeDmoFieldName_StripsCcMarker() {
        // Pure-string contract for the Data Cloud "_c__c" naming convention.
        // Native DMO custom fields and standard fields pass through unchanged.
        Assert.areEqual('Title__c',
            KBContentFieldIndexValidator.normalizeDmoFieldName('Title_c__c'),
            'Doubled CRM marker normalized to source-side __c');
        Assert.areEqual('FAQ_Answer__c',
            KBContentFieldIndexValidator.normalizeDmoFieldName('FAQ_Answer_c__c'),
            'Doubled marker normalized for multi-word custom fields');
        Assert.areEqual('Title__c',
            KBContentFieldIndexValidator.normalizeDmoFieldName('Title__c'),
            'Native DMO __c passed through unchanged');
        Assert.areEqual('Title',
            KBContentFieldIndexValidator.normalizeDmoFieldName('Title'),
            'Standard field passed through unchanged');
        Assert.areEqual('',
            KBContentFieldIndexValidator.normalizeDmoFieldName(''),
            'Blank passed through');
        Assert.areEqual(null,
            KBContentFieldIndexValidator.normalizeDmoFieldName(null),
            'Null passed through');
    }
}
