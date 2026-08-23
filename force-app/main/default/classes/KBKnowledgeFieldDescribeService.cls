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
 * Describe-only resolver for the Knowledge__kav (or whichever __kav variant the
 * org uses) field list that the advanced filter UI exposes. Drives both the
 * LWC field combobox and the server-side allowlist for the SOQL guard
 * in KBFilterClauseCompiler (see plan §3).
 *
 * Pure describe — no SOQL, no DML. Internal `Map<String, FieldDescriptor>`
 * cache keyed by API name is rebuilt on first call per transaction. Combined
 * with `cacheable=true` on the Aura method, the LWC's @wire pipeline keeps
 * describe-load cost off the critical path for steady-state interactions.
 *
 * Security posture: the FieldDescriptor list is the only allowlist any
 * downstream caller (clause compiler, formula parser) consults. Filtering to
 * `isFilterable() == true` minus a hard deny-list of types that don't belong
 * in a SOQL WHERE (LongTextArea, RichText, Address, EncryptedString, Base64,
 * AnyType, plus Reference (lookup/master-detail) and ID fields — excluded per
 * as navigation into related records rather than direct article
 * attributes) keeps the allowlist safe by construction.
 */
public with sharing class KBKnowledgeFieldDescribeService {

    /**
     * Display types we explicitly refuse to expose as filterable, even when
     * Schema reports them as such. LongTextArea / RichText / Base64 are not
     * usable in a SOQL WHERE for normal scalar predicates; Address is a
     * compound type whose individual components are surfaced separately;
     * EncryptedString returns masked values and shouldn't be filterable;
     * AnyType is opaque and Apex-side typing breaks down. Reference and ID
 * fields (lookups) are excluded per — the advanced filter is for
     * direct article attributes, not navigation into related records.
     */
    private static final Set<Schema.DisplayType> DENY_TYPES = new Set<Schema.DisplayType>{
        Schema.DisplayType.TEXTAREA,
        Schema.DisplayType.ENCRYPTEDSTRING,
        Schema.DisplayType.BASE64,
        Schema.DisplayType.ADDRESS,
        Schema.DisplayType.ANYTYPE,
        Schema.DisplayType.REFERENCE,
        Schema.DisplayType.ID
    };

    /**
     * Per-transaction cache. The KAV object name is resolved once via
     * KBAssessmentService.getKnowledgeObjectApiNameStatic and the resulting
     * descriptors are kept in this static — describe lookups are
     * multi-millisecond on cold paths, so even cheap callers (e.g. the LWC's
     * cacheable wire on initial mount) avoid the round-trip on subsequent
     * invocations within the same transaction.
     */
    @TestVisible
    private static Map<String, FieldDescriptor> cachedFields;

    @TestVisible
    private static String cachedObjectName;

    public class FieldDescriptor {
        @AuraEnabled public String apiName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String type { get; set; }
        @AuraEnabled public Boolean nillable { get; set; }
        @AuraEnabled public String relationshipName { get; set; }
        @AuraEnabled public List<PicklistValue> picklistValues { get; set; }

        public FieldDescriptor() {
            this.picklistValues = new List<PicklistValue>();
        }
    }

    public class PicklistValue {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Boolean active { get; set; }

        public PicklistValue() {}

        public PicklistValue(String value, String label, Boolean active) {
            this.value = value;
            this.label = label;
            this.active = active;
        }
    }

    /**
     * LWC entry point — used by `kbArticleSelector` to populate the field
     * combobox. cacheable so the LWC's @wire only round-trips once per
     * stable input set.
     */
    @AuraEnabled(cacheable=true)
    public static List<FieldDescriptor> getFilterableFields() {
        return new List<FieldDescriptor>(loadFields().values());
    }

    /**
     * Server-side allowlist consulted by KBFilterClauseCompiler. Returns the
     * cached map directly so callers can do O(1) field-existence checks.
     */
    public static Map<String, FieldDescriptor> getFieldMap() {
        return loadFields();
    }

    @TestVisible
    private static Map<String, FieldDescriptor> loadFields() {
        if (cachedFields != null) {
            return cachedFields;
        }

        String objectName = KBAssessmentService.getKnowledgeObjectApiNameStatic();
        cachedObjectName = objectName;

        Map<String, FieldDescriptor> result = new Map<String, FieldDescriptor>();

        if (String.isBlank(objectName)) {
            cachedFields = result;
            return cachedFields;
        }

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectName);
        if (sot == null) {
            cachedFields = result;
            return cachedFields;
        }

        Schema.DescribeSObjectResult dsor = sot.getDescribe();
        Map<String, Schema.SObjectField> fields = dsor.fields.getMap();

        for (String name : fields.keySet()) {
            Schema.DescribeFieldResult dfr = fields.get(name).getDescribe();

            if (!dfr.isFilterable()) continue;
            if (DENY_TYPES.contains(dfr.getType())) continue;

            FieldDescriptor fd = new FieldDescriptor();
            fd.apiName = dfr.getName();
            fd.label = dfr.getLabel();
            fd.type = String.valueOf(dfr.getType());
            fd.nillable = dfr.isNillable();
            // Relationship name disambiguates lookups that share a platform label
            // (several User lookups all label as "User ID"). Null for non-reference
 // fields — the LWC only uses it on label collisions.
            fd.relationshipName = dfr.getRelationshipName();

            if (dfr.getType() == Schema.DisplayType.PICKLIST
                || dfr.getType() == Schema.DisplayType.MULTIPICKLIST) {
                for (Schema.PicklistEntry e : dfr.getPicklistValues()) {
                    fd.picklistValues.add(new PicklistValue(
                        e.getValue(),
                        e.getLabel(),
                        e.isActive()
                    ));
                }
            }

            result.put(fd.apiName, fd);
        }

        cachedFields = result;
        return cachedFields;
    }

    /**
     * Test seam — clears the per-transaction cache so a test that loads a
     * mock describe map and then expects a fresh resolution can do so without
     * relying on test-method isolation.
     */
    @TestVisible
    private static void clearCache() {
        cachedFields = null;
        cachedObjectName = null;
    }

    /**
     * Test seam — replace the cache with a fixture map. Lets compiler tests
     * (KBFilterClauseCompilerTest) avoid the describe round-trip and assert
     * specifically against the field-validation guard.
     */
    @TestVisible
    private static void seedCache(Map<String, FieldDescriptor> fixture) {
        cachedFields = fixture;
    }
}
