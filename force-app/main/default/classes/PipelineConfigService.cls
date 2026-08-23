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
 * Singleton service for reading pipeline configuration.
 * Reads from KB_Pipeline_Config__c (hierarchy custom setting) first,
 * falls back to KM_Pipeline_Config__mdt (custom metadata type).
 * Used by all tiers of the deduplication pipeline.
 */
public inherited sharing class PipelineConfigService {

    private static KM_Pipeline_Config__mdt cachedConfig;

    public static KM_Pipeline_Config__mdt getActiveConfig() {
        if (cachedConfig != null) {
            return cachedConfig;
        }

        // Try custom setting first (DML-updatable via wizard). Manual_Review_
        // Threshold__c is the populated-row sentinel (there is no auto-merge band
        // gate — merges are always explicitly user-approved).
        KB_Pipeline_Config__c cs = KB_Pipeline_Config__c.getInstance();
        if (cs != null && cs.Manual_Review_Threshold__c != null) {
            cachedConfig = buildFromCustomSetting(cs);
            return cachedConfig;
        }

        // Fall back to CMDT
        List<KM_Pipeline_Config__mdt> configs = [
            SELECT Manual_Review_Threshold__c,
                   Max_Finalists__c, Max_SubAgent_Callouts__c,
                   Tier2_TopK__c, Tier2_Similarity_Threshold__c,
                   Supported_Languages__c, Is_Active__c,
                   Min_Completeness_Score__c, Min_Structure_Score__c, Min_Clarity_Score__c
            FROM KM_Pipeline_Config__mdt
            WHERE Is_Active__c = true
            LIMIT 1
        ];

        if (configs.isEmpty()) {
            // Return defaults instead of throwing
            cachedConfig = buildDefaults();
            return cachedConfig;
        }

        cachedConfig = configs[0];
        return cachedConfig;
    }

    @TestVisible
    private static KM_Pipeline_Config__mdt buildFromCustomSetting(KB_Pipeline_Config__c cs) {
        KM_Pipeline_Config__mdt mdt = new KM_Pipeline_Config__mdt();
 // with the cross-field manualReview <= autoMerge validation gone,
        // this is the only bound left. Confidence is 0–100, so an out-of-range
        // cutoff (e.g. > 100) would silently mark every Tier 4 pair 'Clear'.
        // Clamp off-range values back to the 50 default.
        Decimal mr = cs.Manual_Review_Threshold__c;
        mdt.Manual_Review_Threshold__c = (mr != null && mr >= 0 && mr <= 100) ? mr : 50;
        mdt.Max_Finalists__c = cs.Max_Finalists__c != null ? cs.Max_Finalists__c : 3;
        mdt.Max_SubAgent_Callouts__c = cs.Max_SubAgent_Callouts__c != null ? cs.Max_SubAgent_Callouts__c : 20;
        mdt.Tier2_TopK__c = cs.Tier2_TopK__c != null ? cs.Tier2_TopK__c : 20;
        mdt.Tier2_Similarity_Threshold__c = cs.Tier2_Similarity_Threshold__c != null ? cs.Tier2_Similarity_Threshold__c : 0.75;
        mdt.Supported_Languages__c = String.isNotBlank(cs.Supported_Languages__c) ? cs.Supported_Languages__c : 'en_US';
        mdt.Min_Completeness_Score__c = cs.Min_Completeness_Score__c != null ? cs.Min_Completeness_Score__c : 60;
        mdt.Min_Structure_Score__c = cs.Min_Structure_Score__c != null ? cs.Min_Structure_Score__c : 60;
        mdt.Min_Clarity_Score__c = cs.Min_Clarity_Score__c != null ? cs.Min_Clarity_Score__c : 60;
        mdt.Is_Active__c = true;
        return mdt;
    }

    @TestVisible
    private static KM_Pipeline_Config__mdt buildDefaults() {
        KM_Pipeline_Config__mdt mdt = new KM_Pipeline_Config__mdt();
        mdt.Manual_Review_Threshold__c = 50;
        mdt.Max_Finalists__c = 3;
        mdt.Max_SubAgent_Callouts__c = 20;
        mdt.Tier2_TopK__c = 20;
        mdt.Tier2_Similarity_Threshold__c = 0.75;
        mdt.Supported_Languages__c = 'en_US';
        mdt.Min_Completeness_Score__c = 60;
        mdt.Min_Structure_Score__c = 60;
        mdt.Min_Clarity_Score__c = 60;
        mdt.Is_Active__c = true;
        return mdt;
    }

    @TestVisible
    private static void setMockConfig(KM_Pipeline_Config__mdt mockConfig) {
        cachedConfig = mockConfig;
    }

    @TestVisible
    private static void clearCache() {
        cachedConfig = null;
    }
}
