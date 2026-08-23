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
 * Compares the admin-selected Knowledge content fields (KB_Scan_Config__c.
 * Content_Field_Mapping_JSON__c — used by the assessment / dimension-analysis
 * scorers) against the fields actually embedded in the Data Cloud chunk DMO
 * pointed to by KB_Vector_Search_Config__c.Search_Index_Name__c. A mismatch
 * means the dedup pipeline (Tier 2 vector search) and the dimension scorers
 * are reading different content surfaces — almost always unintentional.
 *
 * surface this as a non-blocking warning on the Setup Wizard
 * Validate & Save step. Some admins deliberately scope the index narrower
 * than the scoring fields (e.g. for cost or recall reasons), so this is a
 * warning, never a blocker.
 *
 * Index introspection is best-effort. Data Cloud chunk DMOs are surfaced as
 * SObjects in the Apex describe map (`<chunk_base>__dlm`), so we can read
 * their field set without an extra ConnectApi call. When the chunk DMO is
 * not present in the describe map (Data Cloud not provisioned, index not
 * yet built, naming convention changed), we degrade silently — the validator
 * returns "indeterminate" and no warning is emitted. Diagnostic context
 * still ships in the result so the wizard can render a soft-info note.
 */
public with sharing class KBContentFieldIndexValidator {

    private KBContentFieldIndexValidator() {}

    public static final String STATUS_OK = 'ok';
    public static final String STATUS_MISMATCH = 'mismatch';
    public static final String STATUS_INDETERMINATE = 'indeterminate';
    public static final String STATUS_NO_CONFIG = 'noConfig';

    /**
     * Returns a structured comparison of the selected content fields vs the
     * fields embedded in the active search index's chunk DMO.
     *
     * Shape:
     *   {
     *     status: 'ok' | 'mismatch' | 'indeterminate' | 'noConfig',
     *     selectedFields: ['Field__c', ...],
     *     indexedFields: ['Field__c', ...] | null,
     *     missingFromIndex: ['Field__c', ...],
     *     extraInIndex: ['Field__c', ...],
     *     chunkDmoName: 'foo_chunk__dlm' | null,
     *     indexName: 'foo_index' | null,
     *     reason: 'Human-readable indeterminate/no-config explanation' | null
     *   }
     */
    public static Map<String, Object> getMismatch() {
        return getMismatch(
            KB_Scan_Config__c.getInstance(),
            KB_Vector_Search_Config__c.getInstance()
        );
    }

    /**
     * Pure-data overload for tests. Pass already-loaded scan/vector configs
     * so unit tests don't have to manipulate org-default custom settings.
     */
    @TestVisible
    public static Map<String, Object> getMismatch(
        KB_Scan_Config__c scanCfg,
        KB_Vector_Search_Config__c vectorCfg
    ) {
        Map<String, Object> out = new Map<String, Object>{
            'status' => STATUS_INDETERMINATE,
            'selectedFields' => new List<String>(),
            'indexedFields' => null,
            'missingFromIndex' => new List<String>(),
            'extraInIndex' => new List<String>(),
            'chunkDmoName' => null,
            'indexName' => null,
            'reason' => null
        };

        // Step 1 — selected content fields.
        List<String> selected = parseSelectedContentFields(scanCfg);
        out.put('selectedFields', selected);
        if (selected.isEmpty()) {
            out.put('status', STATUS_NO_CONFIG);
            out.put('reason', 'No content fields selected — set the content scope in Step 2 first.');
            return out;
        }

        // Step 2 — resolve the chunk DMO API name from the configured search index.
        String indexName = vectorCfg == null ? null : vectorCfg.Search_Index_Name__c;
        out.put('indexName', indexName);
        if (String.isBlank(indexName)) {
            out.put('reason', 'No search index configured — Tier 2 will fall back to SOQL keyword search.');
            return out;
        }
        // Vector search disabled (e.g. SOQL fallback explicitly chosen): mismatch
        // is moot because the index isn't going to be queried.
        Boolean vectorActive = vectorCfg != null
            && vectorCfg.Is_Active__c
            && String.isNotBlank(vectorCfg.Implementation_Class__c)
            && vectorCfg.Implementation_Class__c == 'ConnectApiVectorSearchService';
        if (!vectorActive) {
            out.put('reason', 'Vector search is disabled — index field comparison is not applicable.');
            return out;
        }

        String chunkDmo = resolveChunkDmoName(indexName);
        out.put('chunkDmoName', chunkDmo);

        // Step 3 — describe the chunk DMO. If the SObject is not in the global
        // describe map, Data Cloud either isn't provisioned or the naming
        // convention is different — fall through indeterminate.
        Schema.SObjectType dmoType = Schema.getGlobalDescribe().get(chunkDmo);
        if (dmoType == null) {
            out.put('reason',
                'Search index "' + indexName + '" is not visible in this org\'s schema yet. ' +
                'If Data Cloud is provisioned and the index is built, verify the chunk DMO name.'
            );
            return out;
        }

        List<String> indexedFields = describeIndexedFieldNames(dmoType);
        out.put('indexedFields', indexedFields);
        if (indexedFields.isEmpty()) {
            out.put('reason',
                'Chunk DMO "' + chunkDmo + '" is empty or has no source-field metadata yet.'
            );
            return out;
        }

        // Step 4 — compute the diff.
        Set<String> indexedLower = lowerSet(indexedFields);
        Set<String> selectedLower = lowerSet(selected);

        List<String> missing = new List<String>();
        for (String s : selected) {
            if (!indexedLower.contains(s.toLowerCase())) {
                missing.add(s);
            }
        }
        List<String> extra = new List<String>();
        for (String i : indexedFields) {
            if (!selectedLower.contains(i.toLowerCase())) {
                extra.add(i);
            }
        }

        out.put('missingFromIndex', missing);
        out.put('extraInIndex', extra);
        out.put('status', missing.isEmpty() && extra.isEmpty() ? STATUS_OK : STATUS_MISMATCH);
        out.put('reason', null);
        return out;
    }

    /**
     * Convenience: render a single human-readable summary string for the
     * "field-mismatch" warning's `details` slot. Mirrors the structure used
     * by other preflight checks. Returns null when there's nothing to say.
     */
    @TestVisible
    public static String formatWarningDetails(Map<String, Object> result) {
        String status = (String) result.get('status');
        if (status == STATUS_OK) {
            return 'Content fields and search-index fields match.';
        }
        if (status == STATUS_NO_CONFIG || status == STATUS_INDETERMINATE) {
            return (String) result.get('reason');
        }
        // Mismatch — phrase calmly. Dimension analysis still runs on selected
        // fields; only dedup is affected.
        List<String> missing = (List<String>) result.get('missingFromIndex');
        List<String> selected = (List<String>) result.get('selectedFields');
        List<String> extra = (List<String>) result.get('extraInIndex');

        Integer missingCount = missing == null ? 0 : missing.size();
        Integer selectedCount = selected == null ? 0 : selected.size();

        List<String> parts = new List<String>();
        if (missingCount > 0) {
            parts.add(
                missingCount + ' of ' + selectedCount +
                ' selected content field(s) are not present in the search index ('
                + String.join(missing, ', ') +
                '). Dimension analysis will use them; the dedup pipeline will not.'
            );
        }
        if (extra != null && !extra.isEmpty()) {
            parts.add(
                'Index also embeds field(s) not selected for assessment: '
                + String.join(extra, ', ') + '.'
            );
        }
        return String.join(parts, ' ');
    }

    // ─── helpers ───────────────────────────────────────────────────────────

    private static List<String> parseSelectedContentFields(KB_Scan_Config__c scanCfg) {
        List<String> result = new List<String>();
        if (scanCfg == null || String.isBlank(scanCfg.Content_Field_Mapping_JSON__c)) {
            return result;
        }
        for (String f : scanCfg.Content_Field_Mapping_JSON__c.split(',')) {
            String trimmed = f == null ? '' : f.trim();
            if (String.isNotBlank(trimmed)) {
                result.add(trimmed);
            }
        }
        return result;
    }

    /**
     * Translate the configured search index name (which may already be a
     * vector DMO or a base name) into its chunk DMO API name. Mirrors the
     * naming conventions ConnectApiVectorSearchService.resolveTableCandidates
     * relies on so the validator stays in sync with the runtime resolver.
     */
    @TestVisible
    public static String resolveChunkDmoName(String configuredSearchIndexName) {
        if (String.isBlank(configuredSearchIndexName)) {
            return null;
        }
        String raw = configuredSearchIndexName.trim();
        String base = raw.endsWith('__dlm')
            ? raw.substring(0, raw.length() - 5)
            : raw;
        String chunkBase;
        if (base.endsWith('_chunk')) {
            chunkBase = base;
        } else if (base.endsWith('_index')) {
            chunkBase = base.replace('_index', '_chunk');
        } else {
            chunkBase = base + '_chunk';
        }
        return chunkBase + '__dlm';
    }

    /**
     * Pulls the field names from a chunk DMO describe. We intentionally
     * exclude the structural columns Data Cloud injects (RecordId__c,
     * Chunk__c, SourceRecordId__c, score__c, etc.) so the comparison is
     * strictly against the indexed source fields. Anything that doesn't
     * follow that convention is fine — it just contributes one entry to
     * `extraInIndex` and the warning text reflects it accurately.
     *
     * Data Cloud names ingested CRM custom fields with a doubled marker
     * (`Foo__c` on Knowledge becomes `Foo_c__c` on the DMO). We normalize
     * those back to the source-side `Foo__c` form before adding so the
     * diff against the admin-selected fields lines up. Native DMO `__c`
     * fields are passed through unchanged.
     */
    @TestVisible
    private static List<String> describeIndexedFieldNames(Schema.SObjectType dmoType) {
        List<String> result = new List<String>();
        if (dmoType == null) {
            return result;
        }
        Schema.DescribeSObjectResult d = dmoType.getDescribe();
        Map<String, Schema.SObjectField> fields = d.fields.getMap();
        Set<String> structural = new Set<String>{
            'id', 'recordid__c', 'sourcerecordid__c', 'chunk__c',
            'chunkid__c', 'chunkindex__c', 'score__c', 'embedding__c',
            'createddate', 'lastmodifieddate', 'systemmodstamp',
            'createdbyid', 'lastmodifiedbyid', 'ownerid', 'isdeleted',
            'name'
        };
        // Dedup by normalized name to avoid double-counting when both the
        // ingested `Foo_c__c` and a native `Foo__c` happen to coexist.
        Set<String> seen = new Set<String>();
        for (String apiName : fields.keySet()) {
            String lower = apiName.toLowerCase();
            if (structural.contains(lower)) continue;
            String normalized = normalizeDmoFieldName(apiName);
            if (seen.contains(normalized.toLowerCase())) continue;
            seen.add(normalized.toLowerCase());
            result.add(normalized);
        }
        result.sort();
        return result;
    }

    /**
     * Normalize a Data Cloud DMO field name back to its CRM source-side
     * form: trailing `_c__c` → `__c`. Native DMO custom fields and standard
     * fields are passed through unchanged.
     */
    @TestVisible
    private static String normalizeDmoFieldName(String apiName) {
        if (String.isBlank(apiName)) return apiName;
        // Case-sensitive on the suffix: Salesforce DMO field API names always
        // use the lowercase `_c__c` marker for ingested CRM custom fields.
        if (apiName.length() > 5 && apiName.endsWith('_c__c')) {
            return apiName.substring(0, apiName.length() - 5) + '__c';
        }
        return apiName;
    }

    private static Set<String> lowerSet(List<String> items) {
        Set<String> out = new Set<String>();
        if (items == null) return out;
        for (String s : items) {
            if (String.isNotBlank(s)) out.add(s.toLowerCase());
        }
        return out;
    }
}
