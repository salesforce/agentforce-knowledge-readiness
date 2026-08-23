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
 * Apex Controller for the Admin Setup Wizard.
 * Provides @AuraEnabled methods for the wizard steps:
 *   - Scan Config (KB_Scan_Config__c)
 *   - Score Weights (KB_Score_Weight__c)
 *   - Pipeline Configuration (KB_Pipeline_Config__c)
 *   - Vector Search (KB_Vector_Search_Config__c)
 */
public with sharing class KBSetupWizardController {

    // ==================== Step 1: Scan Configuration ====================

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getScanConfig() {
        KB_Scan_Config__c config = KB_Scan_Config__c.getInstance();
        Map<String, Object> result = new Map<String, Object>();

        result.put('freshnessThresholdMonths', config != null && config.Freshness_Threshold_Months__c != null ? config.Freshness_Threshold_Months__c : 12);
        result.put('freshnessCriticalMonths', config != null && config.Freshness_Critical_Months__c != null ? config.Freshness_Critical_Months__c : 24);
        // The Article Length section (Min Article Word Count, Optimal Min/Max Words,
        // Heavy Penalty Threshold) and the Title section (Min Title Length) were
 // removed from the wizard in — the four word-count fields were dead
        // (no scorer read them) and were deleted; Min_Title_Length__c is still read
        // by KBCompletenessScorer's title gate and now lives only on the
        // KB_Scan_Config__c custom setting (admin-set directly — see README). The
        // Performance section (Queueable Batch Size) was removed from the wizard
 // in.
        result.put('usesDataCategories', config != null && config.Uses_Data_Categories__c == true);

        List<String> contentFieldMapping = new List<String>();
        if (config != null && String.isNotBlank(config.Content_Field_Mapping_JSON__c)) {
            for (String f : config.Content_Field_Mapping_JSON__c.split(',')) {
                String trimmed = f.trim();
                if (String.isNotBlank(trimmed)) contentFieldMapping.add(trimmed);
            }
        }
        result.put('contentFieldMapping', contentFieldMapping);

        return result;
    }

    @AuraEnabled
    public static void saveScanConfig(String configJSON) {
        try {
            Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(configJSON);

            KB_Scan_Config__c config = KB_Scan_Config__c.getOrgDefaults();
            if (config.Id == null) {
                config = new KB_Scan_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
            }

            if (params.containsKey('freshnessThresholdMonths')) config.Freshness_Threshold_Months__c = toDecimal(params.get('freshnessThresholdMonths'));
            if (params.containsKey('freshnessCriticalMonths')) config.Freshness_Critical_Months__c = toDecimal(params.get('freshnessCriticalMonths'));
 // The Article Length / Title word-count fields and the Performance
 // section's Queueable Batch Size are no longer written by the
            // wizard. The four word-count fields were dead code and were deleted;
            // Min_Title_Length__c is admin-set directly on the KB_Scan_Config__c
            // custom setting (see README).
            if (params.containsKey('usesDataCategories')) {
                config.Uses_Data_Categories__c = Boolean.valueOf(params.get('usesDataCategories'));
            }
            if (params.containsKey('contentFieldMapping')) {
                Object raw = params.get('contentFieldMapping');
                if (raw instanceof List<Object>) {
                    List<String> fields = new List<String>();
                    for (Object item : (List<Object>) raw) {
                        String f = String.valueOf(item).trim();
                        if (String.isNotBlank(f)) fields.add(f);
                    }
                    config.Content_Field_Mapping_JSON__c = fields.isEmpty() ? null : String.join(fields, ',');
                }
            }

            upsert config;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to save scan config: ' + e.getMessage());
        }
    }

    // ==================== Step 2: Score Weights ====================

    /**
     * Read admin-editable weights from KB_Score_Weight__c.Weights_JSON__c,
     * merged over CMDT defaults. Keys are dimension DeveloperNames
     * (Completeness, Structure, Clarity, etc.). Unknown or missing keys
     * inherit from KB_Scoring_Dimension__mdt.Default_Weight__c via the registry.
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Decimal> getScoreWeights() {
        return DimensionRegistry.getActiveWeights();
    }

    /**
     * Persist admin weights into KB_Score_Weight__c.Weights_JSON__c as a
     * single JSON blob keyed by dimension DeveloperName. Unrecognised keys
     * are dropped. Totals must sum to ~1.0; caller is responsible for
     * renormalisation if not.
     */
    @AuraEnabled
    public static void saveScoreWeights(String weightsJSON) {
        try {
            Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(weightsJSON);

            // Match input keys to CMDT DeveloperNames case-insensitively. The
            // wizard LWC historically emits lowercase keys ('completeness') while
            // the registry speaks CMDT DeveloperNames ('Completeness'). Normalize
            // so either round-trips cleanly — and emit the CMDT form to storage.
            Set<String> known = DimensionRegistry.getActiveDeveloperNames();
            Map<String, String> lowerToKnown = new Map<String, String>();
            for (String n : known) {
                lowerToKnown.put(n.toLowerCase(), n);
            }

            Map<String, Decimal> clean = new Map<String, Decimal>();
            Decimal total = 0;
            for (String key : params.keySet()) {
                String normalized = lowerToKnown.get(key == null ? '' : key.toLowerCase());
                if (normalized == null) continue;
                Decimal w = toDecimal(params.get(key));
                if (w == null) continue;
                clean.put(normalized, w);
                total += w;
            }
            if (Math.abs(total - 1.0) > 0.01) {
                throw new AuraHandledException('Weights must sum to 1.0 (100%). Current total: ' + total);
            }

            KB_Score_Weight__c weights = KB_Score_Weight__c.getOrgDefaults();
            if (weights.Id == null) {
                weights = new KB_Score_Weight__c(SetupOwnerId = UserInfo.getOrganizationId());
            }
            weights.Weights_JSON__c = JSON.serialize(clean);
            upsert weights;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to save score weights: ' + e.getMessage());
        }
    }

    // ==================== Step 6: Pipeline Configuration ====================

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getPipelineConfig() {
        KB_Pipeline_Config__c config = KB_Pipeline_Config__c.getInstance();
        Map<String, Object> result = new Map<String, Object>();

 // "Duplicate Detection" screen knobs.
        result.put('maxFinalists', config != null && config.Max_Finalists__c != null ? config.Max_Finalists__c : 3);
        result.put('tier2TopK', config != null && config.Tier2_TopK__c != null ? config.Tier2_TopK__c : 20);
        result.put('tier2SimilarityThreshold', config != null && config.Tier2_Similarity_Threshold__c != null ? config.Tier2_Similarity_Threshold__c : 0.75);
        result.put('supportedLanguages', config != null && String.isNotBlank(config.Supported_Languages__c) ? config.Supported_Languages__c : 'en_US');
 // Off-screen-but-live custom-setting knobs: Manual_Review_Threshold__c
        // (Tier 4 flagging cutoff), Max_SubAgent_Callouts__c (Tier 4 budget),
        // Max_Callout_Limit__c (Tier 3 budget) are still returned so any admin
        // surface that reads this map keeps working — they're just no longer
        // collected on the setup screen (managed via the custom setting + README).
        result.put('manualReviewThreshold', config != null && config.Manual_Review_Threshold__c != null ? config.Manual_Review_Threshold__c : 50);
        result.put('maxSubAgentCallouts', config != null && config.Max_SubAgent_Callouts__c != null ? config.Max_SubAgent_Callouts__c : 20);
        result.put('maxCalloutLimit', config != null && config.Max_Callout_Limit__c != null ? config.Max_Callout_Limit__c : 90);
        // Max_Chunk_Size__c schema field is retained but not surfaced on this
        // screen — it tunes the chunk size for Tier 4's fact-extraction chunking
        // (unrelated to Data Cloud, which chunks independently at index time).
        // Admins adjust it via the custom setting / CMDT directly.
        // Min_Completeness_Score__c / Min_Structure_Score__c / Min_Clarity_Score__c schema
        // fields are also retained — admins manage them via Custom Settings UI / CMDT
 // PipelineConfigService still reads them with CMDT fallback.
 // Auto_Merge_Threshold__c / Input_Scope__c / Frequency__c were dropped:
        // the auto-merge band gate was retired (merges are user-approved) and
 // Input Scope / Frequency had no runtime consumer.
        result.put('defaultExecutionMode', config != null && String.isNotBlank(config.Default_Execution_Mode__c) ? config.Default_Execution_Mode__c : 'DEDUPLICATION');

        return result;
    }

    @AuraEnabled
    public static void savePipelineConfig(String configJSON) {
        try {
            Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(configJSON);

            KB_Pipeline_Config__c config = KB_Pipeline_Config__c.getOrgDefaults();
            if (config.Id == null) {
                config = new KB_Pipeline_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
            }

            if (params.containsKey('maxFinalists')) config.Max_Finalists__c = toDecimal(params.get('maxFinalists'));
            if (params.containsKey('tier2TopK')) config.Tier2_TopK__c = toDecimal(params.get('tier2TopK'));
            if (params.containsKey('tier2SimilarityThreshold')) config.Tier2_Similarity_Threshold__c = toDecimal(params.get('tier2SimilarityThreshold'));
            if (params.containsKey('supportedLanguages')) config.Supported_Languages__c = String.valueOf(params.get('supportedLanguages'));
 // Off-screen-but-live custom-setting knobs — still accepted if a
            // payload supplies them, but the setup screen no longer sends them.
            if (params.containsKey('manualReviewThreshold')) config.Manual_Review_Threshold__c = toDecimal(params.get('manualReviewThreshold'));
            if (params.containsKey('maxSubAgentCallouts')) config.Max_SubAgent_Callouts__c = toDecimal(params.get('maxSubAgentCallouts'));
            if (params.containsKey('maxCalloutLimit')) config.Max_Callout_Limit__c = toDecimal(params.get('maxCalloutLimit'));
            // Deduplication is the only pipeline execution mode. Hardcode the
            // value on every save so
            // legacy rows get coerced and any drifted client payload is ignored.
            // Min_Completeness_Score__c / Min_Structure_Score__c / Min_Clarity_Score__c
            // schema is preserved (field-meta still on disk + read path still
 // exposes them) but the wizard step no longer collects them per.
 // Auto_Merge_Threshold__c / Input_Scope__c / Frequency__c dropped.
            config.Default_Execution_Mode__c = KBRuntimeConfigService.MODE_DEDUPLICATION;

            upsert config;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to save pipeline config: ' + e.getMessage());
        }
    }

    // ==================== Step 8: Vector Search Configuration ====================

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getVectorSearchConfig() {
        KB_Vector_Search_Config__c config = KB_Vector_Search_Config__c.getInstance();
        Map<String, Object> result = new Map<String, Object>();

        result.put('implementationClass', config != null && String.isNotBlank(config.Implementation_Class__c) ? config.Implementation_Class__c : 'ConnectApiVectorSearchService');
        result.put('searchIndexName', config != null && String.isNotBlank(config.Search_Index_Name__c) ? config.Search_Index_Name__c : '');
        result.put('maxResults', config != null && config.Max_Results__c != null ? config.Max_Results__c : 20);
        result.put('dataSpaceName', config != null && String.isNotBlank(config.Data_Space_Name__c) ? config.Data_Space_Name__c : 'default');
        result.put('isActive', config != null && config.Is_Active__c != null ? config.Is_Active__c : true);
 // whether the configured search index is an Agentforce Data Library.
        // Drives the publish-status prefilter in ConnectApiVectorSearchService.
        result.put('isAdl', config != null && config.Is_ADL__c != null ? config.Is_ADL__c : false);

        return result;
    }

    @AuraEnabled
    public static void saveVectorSearchConfig(String configJSON) {
        try {
            Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(configJSON);

            KB_Vector_Search_Config__c config = KB_Vector_Search_Config__c.getOrgDefaults();
            if (config.Id == null) {
                config = new KB_Vector_Search_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
            }

            Boolean active = params.containsKey('isActive') ? Boolean.valueOf(params.get('isActive')) : true;
            config.Implementation_Class__c = active ? 'ConnectApiVectorSearchService' : 'Tier1SOQLFallbackService';
            if (params.containsKey('searchIndexName')) config.Search_Index_Name__c = String.valueOf(params.get('searchIndexName'));
            if (params.containsKey('maxResults')) config.Max_Results__c = toDecimal(params.get('maxResults'));
            if (params.containsKey('dataSpaceName')) config.Data_Space_Name__c = String.valueOf(params.get('dataSpaceName'));
            if (params.containsKey('isActive')) config.Is_Active__c = Boolean.valueOf(params.get('isActive'));
            if (params.containsKey('isAdl')) config.Is_ADL__c = Boolean.valueOf(params.get('isAdl'));

            upsert config;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to save vector search config: ' + e.getMessage());
        }
    }

    // ==================== Utility ====================

    private static Decimal toDecimal(Object value) {
        if (value == null) return null;
        if (value instanceof Decimal) return (Decimal) value;
        if (value instanceof Integer) return Decimal.valueOf((Integer) value);
        if (value instanceof Long) return Decimal.valueOf((Long) value);
        if (value instanceof Double) return Decimal.valueOf((Double) value);
        return Decimal.valueOf(String.valueOf(value));
    }
}
