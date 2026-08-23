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
 * Factory for obtaining the active IVectorSearchService implementation.
 * Runtime config prefers KB_Vector_Search_Config__c (wizard-saved custom setting),
 * then falls back to Vector_Search_Config__mdt (custom metadata type).
 * Supports test injection via setMock().
 */
public inherited sharing class VectorSearchFactory {

    private static IVectorSearchService instance;
    private static final String DEFAULT_IMPL_CLASS = 'ConnectApiVectorSearchService';
    private static final String DEFAULT_SEARCH_INDEX = 'KA_Knowledge_index';
    private static final Decimal DEFAULT_SIMILARITY_THRESHOLD = 0.75;
    private static final Decimal DEFAULT_MAX_RESULTS = 20;
    private static final String DEFAULT_DATA_SPACE = 'default';

    public static IVectorSearchService getInstance() {
        if (instance != null) {
            return instance;
        }

        String implClassName = getImplementationClass();
        if (String.isBlank(implClassName)) {
            throw new KnowledgeAIException('No vector search implementation configured.');
        }

        Type implType = Type.forName(implClassName);
        if (implType == null) {
            throw new KnowledgeAIException(
                'Vector search implementation class not found: ' + implClassName
            );
        }

        instance = (IVectorSearchService) implType.newInstance();
        return instance;
    }

    public static Boolean isDataCloudAvailable() {
        return Type.forName('ConnectApi', 'CdpQuery') != null;
    }

    public static String getImplementationClass() {
        // Try custom setting first
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        if (cs != null && String.isNotBlank(cs.Implementation_Class__c)) {
            return cs.Implementation_Class__c;
        }

        // Fall back to CMDT
        List<Vector_Search_Config__mdt> configs = [
            SELECT Implementation_Class__c
            FROM Vector_Search_Config__mdt
            WHERE Is_Active__c = true
            LIMIT 1
        ];

        if (configs.isEmpty()) {
            return DEFAULT_IMPL_CLASS;
        }

        return configs[0].Implementation_Class__c;
    }

    public static ActiveVectorConfig getActiveConfig() {
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        if (shouldUseCustomSetting(cs)) {
            return withDefaults(new ActiveVectorConfig(
                cs.Implementation_Class__c,
                cs.Search_Index_Name__c,
                cs.Similarity_Threshold__c,
                cs.Max_Results__c,
                cs.Data_Space_Name__c
            ));
        }

        List<Vector_Search_Config__mdt> configs = [
            SELECT Implementation_Class__c,
                   Search_Index_Name__c, Similarity_Threshold__c, Max_Results__c,
                   Data_Space_Name__c
            FROM Vector_Search_Config__mdt
            WHERE Is_Active__c = true
            LIMIT 1
        ];

        if (configs.isEmpty()) {
            throw new KnowledgeAIException(
                'No active Vector_Search_Config__mdt record found. Please configure one.'
            );
        }

        Vector_Search_Config__mdt mdt = configs[0];
        return withDefaults(new ActiveVectorConfig(
            mdt.Implementation_Class__c,
            mdt.Search_Index_Name__c,
            mdt.Similarity_Threshold__c,
            mdt.Max_Results__c,
            mdt.Data_Space_Name__c
        ));
    }

    private static Boolean shouldUseCustomSetting(KB_Vector_Search_Config__c cs) {
        if (cs == null || cs.Is_Active__c == false) {
            return false;
        }
        return String.isNotBlank(cs.Implementation_Class__c)
            || String.isNotBlank(cs.Search_Index_Name__c)
            || String.isNotBlank(cs.Data_Space_Name__c)
            || cs.Similarity_Threshold__c != null
            || cs.Max_Results__c != null;
    }

    private static ActiveVectorConfig withDefaults(ActiveVectorConfig config) {
        if (String.isBlank(config.implementationClass)) {
            config.implementationClass = DEFAULT_IMPL_CLASS;
        }
        if (String.isBlank(config.searchIndexName)) {
            config.searchIndexName = DEFAULT_SEARCH_INDEX;
        }
        if (config.similarityThreshold == null) {
            config.similarityThreshold = DEFAULT_SIMILARITY_THRESHOLD;
        }
        if (config.maxResults == null || config.maxResults <= 0) {
            config.maxResults = DEFAULT_MAX_RESULTS;
        }
        if (String.isBlank(config.dataSpaceName)) {
            config.dataSpaceName = DEFAULT_DATA_SPACE;
        }
        return config;
    }

    @TestVisible
    private static void setMock(IVectorSearchService mock) {
        instance = mock;
    }

    @TestVisible
    private static void clearInstance() {
        instance = null;
    }

    public class ActiveVectorConfig {
        public String implementationClass;
        public String searchIndexName;
        public Decimal similarityThreshold;
        public Decimal maxResults;
        public String dataSpaceName;

        public ActiveVectorConfig(
            String implementationClass,
            String searchIndexName,
            Decimal similarityThreshold,
            Decimal maxResults,
            String dataSpaceName
        ) {
            this.implementationClass = implementationClass;
            this.searchIndexName = searchIndexName;
            this.similarityThreshold = similarityThreshold;
            this.maxResults = maxResults;
            this.dataSpaceName = dataSpaceName;
        }
    }
}
