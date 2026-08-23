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
public with sharing class KBRuntimeConfigService {

    /**
     * Default async batch size when KB_Scan_Config__c.Queueable_Batch_Size__c is unset.
     * Sized to keep each Queueable execution under the 10-min Apex async limit on hybrid
     * scoring (~5s per LLM call, up to 4 LLM calls per article). Admins can raise this via
     * the Setup Wizard for deterministic-only runs.
     */
    public static final Integer DEFAULT_BATCH_SIZE = 10;

    public static final String MODE_DEDUPLICATION = 'DEDUPLICATION';

    public class RuntimeFilters {
        public String publishStatus;
        public String language;
        public Set<String> supportedLanguages;
        public String titlePattern;
        public String articleType;

        public String getTitleLikePattern() {
            if (String.isBlank(titlePattern)) {
                return null;
            }
            return '%' + titlePattern + '%';
        }

        public Boolean isKnowledgeArticleType() {
            return String.isBlank(articleType) || articleType == 'Knowledge__kav';
        }
    }

    public static RuntimeFilters getRuntimeFilters() {
        RuntimeFilters filters = new RuntimeFilters();
        filters.publishStatus = 'Online';
        filters.language = 'en_US';
        filters.supportedLanguages = new Set<String>{ 'en_US' };

        KB_Pipeline_Config__c pipelineConfig = KB_Pipeline_Config__c.getInstance();
        if (pipelineConfig != null && String.isNotBlank(pipelineConfig.Supported_Languages__c)) {
            Set<String> parsed = parseLanguageSet(pipelineConfig.Supported_Languages__c);
            if (!parsed.isEmpty()) {
                filters.supportedLanguages = parsed;
                if (!filters.supportedLanguages.contains(filters.language)) {
                    filters.language = firstLanguage(parsed);
                }
            }
        }

        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getInstance();
        if (state != null && String.isNotBlank(state.Query_Prefilters_JSON__c)) {
            try {
                Map<String, Object> prefilters = (Map<String, Object>) JSON.deserializeUntyped(state.Query_Prefilters_JSON__c);
                String status = asString(prefilters.get('publishStatus'));
                String language = asString(prefilters.get('language'));
                if (String.isNotBlank(status)) {
                    filters.publishStatus = status;
                }
                if (String.isNotBlank(language)) {
                    filters.language = language;
                    filters.supportedLanguages.add(language);
                }
                String titlePattern = asString(prefilters.get('titlePattern'));
                String articleType = asString(prefilters.get('articleType'));
                if (String.isNotBlank(titlePattern)) {
                    filters.titlePattern = titlePattern;
                }
                if (String.isNotBlank(articleType)) {
                    filters.articleType = articleType;
                }
            } catch (Exception e) {
                // Keep defaults when saved JSON is malformed/truncated.
            }
        }

        return filters;
    }

    public static Integer getProcessingBatchSize() {
        KB_Scan_Config__c scanConfig = KB_Scan_Config__c.getInstance();
        if (scanConfig != null
            && scanConfig.Queueable_Batch_Size__c != null
            && scanConfig.Queueable_Batch_Size__c > 0
        ) {
            return scanConfig.Queueable_Batch_Size__c.intValue();
        }
        return DEFAULT_BATCH_SIZE;
    }

    public static String getExecutionMode() {
        KB_Pipeline_Config__c pipelineConfig = KB_Pipeline_Config__c.getInstance();
        String mode = pipelineConfig != null ? asString(pipelineConfig.Default_Execution_Mode__c) : '';
        if (mode == MODE_DEDUPLICATION) {
            return mode;
        }
        return MODE_DEDUPLICATION;
    }

    public static Integer getMaxCalloutLimit() {
        KB_Pipeline_Config__c pipelineConfig = KB_Pipeline_Config__c.getInstance();
        if (pipelineConfig != null
            && pipelineConfig.Max_Callout_Limit__c != null
            && pipelineConfig.Max_Callout_Limit__c > 0) {
            return pipelineConfig.Max_Callout_Limit__c.intValue();
        }
        return 90;
    }

    public static Integer getMaxChunkSize() {
        KB_Pipeline_Config__c pipelineConfig = KB_Pipeline_Config__c.getInstance();
        if (pipelineConfig != null
            && pipelineConfig.Max_Chunk_Size__c != null
            && pipelineConfig.Max_Chunk_Size__c > 0) {
            return pipelineConfig.Max_Chunk_Size__c.intValue();
        }
        return 500;
    }

    private static Set<String> parseLanguageSet(String raw) {
        Set<String> languages = new Set<String>();
        if (String.isBlank(raw)) {
            return languages;
        }
        String normalized = raw.replace(';', ',');
        for (String token : normalized.split(',')) {
            String value = token != null ? token.trim() : '';
            if (String.isNotBlank(value)) {
                languages.add(value);
            }
        }
        return languages;
    }

    private static String firstLanguage(Set<String> values) {
        if (values == null || values.isEmpty()) {
            return 'en_US';
        }
        List<String> listValues = new List<String>(values);
        listValues.sort();
        return listValues[0];
    }

    private static String asString(Object value) {
        return value == null ? '' : String.valueOf(value).trim();
    }
}
