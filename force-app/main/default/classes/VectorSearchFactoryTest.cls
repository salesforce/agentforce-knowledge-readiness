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
 * Coverage for VectorSearchFactory — config resolution from custom setting,
 * CMDT, or hard-coded defaults; getInstance() with Type.forName lookup;
 * setMock/clearInstance test seams; ActiveVectorConfig DTO.
 */
@IsTest
private class VectorSearchFactoryTest {

    // ──────────────────────────────────────────────────────────────────────
    // Mock injection / clearInstance seams
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetInstance_MockOverride_ReturnsInjected() {
        MockVectorSearchService mock = new MockVectorSearchService();
        VectorSearchFactory.setMock(mock);

        IVectorSearchService service = VectorSearchFactory.getInstance();

        Assert.areEqual(mock, service, 'Factory returns the injected mock');
    }

    @IsTest
    static void testClearInstance_ResetsMock() {
        // Verify that clearInstance() actually clears the cached singleton:
        // configure the CS to point at MockVectorSearchService, install a
        // DIFFERENT mock, then clearInstance(). The next getInstance() must
        // resolve via Type.forName to a *fresh* MockVectorSearchService — not
        // return the originally-installed mock.
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getOrgDefaults();
        cs.Implementation_Class__c = 'MockVectorSearchService';
        cs.Is_Active__c = true;
        upsert cs KB_Vector_Search_Config__c.Id;

        MockVectorSearchService originalMock = new MockVectorSearchService();
        VectorSearchFactory.setMock(originalMock);
        Assert.areEqual(originalMock, VectorSearchFactory.getInstance(),
            'sanity: setMock installed the original');

        VectorSearchFactory.clearInstance();
        IVectorSearchService resolved = VectorSearchFactory.getInstance();

        Assert.isInstanceOfType(resolved, MockVectorSearchService.class,
            'After clearInstance, getInstance resolves via Type.forName to a fresh MockVectorSearchService');
        Assert.areNotEqual(originalMock, resolved,
            'The freshly-resolved instance must NOT be the originally-installed mock');
    }

    // ──────────────────────────────────────────────────────────────────────
    // getImplementationClass — CS / CMDT / default fallback
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetImplementationClass_FromCustomSetting() {
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getOrgDefaults();
        cs.Implementation_Class__c = 'MockVectorSearchService';
        cs.Is_Active__c = true;
        upsert cs KB_Vector_Search_Config__c.Id;

        Assert.areEqual('MockVectorSearchService',
            VectorSearchFactory.getImplementationClass());
    }

    @IsTest
    static void testGetImplementationClass_NoCSImpl_FallsBackToDefaultOrCMDT() {
        // CS exists but Implementation_Class__c blank → falls through to CMDT
        // query. Whether CMDT has a row or not, the method must return either
        // its value or the hard-coded default — never null.
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getOrgDefaults();
        cs.Implementation_Class__c = '';
        upsert cs KB_Vector_Search_Config__c.Id;

        String impl = VectorSearchFactory.getImplementationClass();

        Assert.isNotNull(impl, 'Implementation class is never null');
        Assert.isFalse(String.isBlank(impl), 'Returns non-blank value');
    }

    // ──────────────────────────────────────────────────────────────────────
    // getInstance — Type.forName lookup, blank-impl error path
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetInstance_ResolvesViaTypeForName() {
        // Force re-resolution (no static mock injected) and steer the impl
        // class to MockVectorSearchService — a real type that implements the
        // interface and is reachable via Type.forName.
        VectorSearchFactory.clearInstance();
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getOrgDefaults();
        cs.Implementation_Class__c = 'MockVectorSearchService';
        cs.Is_Active__c = true;
        upsert cs KB_Vector_Search_Config__c.Id;

        Test.startTest();
        IVectorSearchService svc = VectorSearchFactory.getInstance();
        Test.stopTest();

        Assert.isInstanceOfType(svc, MockVectorSearchService.class,
            'Type.forName should resolve to the configured class');
    }

    // ──────────────────────────────────────────────────────────────────────
    // isDataCloudAvailable
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testIsDataCloudAvailable_ReturnsBooleanWithoutThrowing() {
        // Org-state-dependent (depends on Data Cloud provisioning). Assert
        // only that a non-null Boolean is returned so the test is portable.
        Boolean available = VectorSearchFactory.isDataCloudAvailable();
        Assert.isNotNull(available);
    }

    // ──────────────────────────────────────────────────────────────────────
    // getActiveConfig — full config resolution with default backfill
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetActiveConfig_FromCustomSetting_AllFieldsSet() {
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getOrgDefaults();
        cs.Implementation_Class__c = 'ConnectApiVectorSearchService';
        cs.Search_Index_Name__c = 'My_Custom_Index';
        cs.Similarity_Threshold__c = 0.85;
        cs.Max_Results__c = 50;
        cs.Data_Space_Name__c = 'tenant_a';
        cs.Is_Active__c = true;
        upsert cs KB_Vector_Search_Config__c.Id;

        VectorSearchFactory.ActiveVectorConfig config = VectorSearchFactory.getActiveConfig();

        Assert.areEqual('ConnectApiVectorSearchService', config.implementationClass);
        Assert.areEqual('My_Custom_Index', config.searchIndexName);
        Assert.areEqual(0.85, config.similarityThreshold);
        Assert.areEqual(50, config.maxResults);
        Assert.areEqual('tenant_a', config.dataSpaceName);
    }

    @IsTest
    static void testGetActiveConfig_CSWithBlankFields_DefaultsBackfilled() {
        // CS is active and has at least one field set (gates the CS branch),
        // but other fields are null/blank. withDefaults() backfills each.
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getOrgDefaults();
        cs.Implementation_Class__c = '';
        cs.Search_Index_Name__c = 'Just_The_Index';
        cs.Similarity_Threshold__c = null;
        cs.Max_Results__c = null;
        cs.Data_Space_Name__c = '';
        cs.Is_Active__c = true;
        upsert cs KB_Vector_Search_Config__c.Id;

        VectorSearchFactory.ActiveVectorConfig config = VectorSearchFactory.getActiveConfig();

        Assert.areEqual('Just_The_Index', config.searchIndexName, 'CS field honored');
        Assert.areEqual('ConnectApiVectorSearchService', config.implementationClass,
            'Blank impl backfilled with default');
        Assert.areEqual(0.75, config.similarityThreshold, 'Null threshold → 0.75 default');
        Assert.areEqual(20, config.maxResults, 'Null maxResults → 20 default');
        Assert.areEqual('default', config.dataSpaceName, 'Blank space → default');
    }

    @IsTest
    static void testGetActiveConfig_CSInactive_FallsThrough() {
        // CS row exists but Is_Active__c=false → shouldUseCustomSetting returns
        // false → CMDT query runs. Outcome depends on org state:
        //   - CMDT has an active row: getActiveConfig returns it (non-null).
        //   - No active CMDT row: KnowledgeAIException thrown with the
        //     documented "No active Vector_Search_Config__mdt record found"
        //     message.
        // We branch on which path actually executed and assert specifically
        // — never both, never neither.
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getOrgDefaults();
        cs.Implementation_Class__c = 'X';
        cs.Is_Active__c = false;
        upsert cs KB_Vector_Search_Config__c.Id;

        VectorSearchFactory.ActiveVectorConfig config;
        KnowledgeAIException caught;
        try {
            config = VectorSearchFactory.getActiveConfig();
        } catch (KnowledgeAIException e) {
            caught = e;
        }

        if (config != null) {
            Assert.isNotNull(config.implementationClass,
                'CMDT-built config must include implementation class');
        } else {
            Assert.isNotNull(caught, 'CMDT row missing → must throw');
            Assert.isTrue(caught.getMessage().contains('Vector_Search_Config__mdt'),
                'Exception message references the missing CMDT');
        }
    }

    @IsTest
    static void testGetActiveConfig_CSNullImpl_AllOtherFieldsNull_FallsThrough() {
        // shouldUseCustomSetting requires at least one CS field populated.
        // With every CS field null + Is_Active__c=true, the method falls
        // through to CMDT — same outcome shape as testGetActiveConfig_CSInactive_FallsThrough.
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getOrgDefaults();
        cs.Implementation_Class__c = null;
        cs.Search_Index_Name__c = null;
        cs.Data_Space_Name__c = null;
        cs.Similarity_Threshold__c = null;
        cs.Max_Results__c = null;
        cs.Is_Active__c = true;
        upsert cs KB_Vector_Search_Config__c.Id;

        VectorSearchFactory.ActiveVectorConfig config;
        KnowledgeAIException caught;
        try {
            config = VectorSearchFactory.getActiveConfig();
        } catch (KnowledgeAIException e) {
            caught = e;
        }

        if (config != null) {
            Assert.isNotNull(config.implementationClass);
        } else {
            Assert.isNotNull(caught,
                'No active CMDT row → KnowledgeAIException is the documented path');
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // ActiveVectorConfig DTO
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testActiveVectorConfig_ConstructorAssignsFields() {
        VectorSearchFactory.ActiveVectorConfig c = new VectorSearchFactory.ActiveVectorConfig(
            'ImplClass', 'IndexName', 0.5, 10, 'spaceName'
        );

        Assert.areEqual('ImplClass', c.implementationClass);
        Assert.areEqual('IndexName', c.searchIndexName);
        Assert.areEqual(0.5, c.similarityThreshold);
        Assert.areEqual(10, c.maxResults);
        Assert.areEqual('spaceName', c.dataSpaceName);
    }
}
