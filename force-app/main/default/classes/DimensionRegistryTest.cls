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
@IsTest
private class DimensionRegistryTest {

    @IsTest
    static void testGetAll_ReturnsNonEmpty() {
        Test.startTest();
        Map<String, DimensionRegistry.DimensionDefinition> all = DimensionRegistry.getAll();
        Test.stopTest();

        Assert.isFalse(all.isEmpty(), 'Should return at least one dimension from CMDT');
        for (DimensionRegistry.DimensionDefinition d : all.values()) {
            Assert.isNotNull(d.developerName, 'DeveloperName populated');
            Assert.isNotNull(d.label, 'Label populated');
        }
    }

    @IsTest
    static void testGetActive_SubsetOfAll() {
        Map<String, DimensionRegistry.DimensionDefinition> all = DimensionRegistry.getAll();
        Map<String, DimensionRegistry.DimensionDefinition> active = DimensionRegistry.getActive();

        Assert.isTrue(active.size() <= all.size(), 'Active is subset of all');
        for (String key : active.keySet()) {
            Assert.isTrue(active.get(key).isActive, 'Active map only contains active dims');
        }
    }

    @IsTest
    static void testGetActiveDeveloperNames_MatchesActive() {
        Set<String> names = DimensionRegistry.getActiveDeveloperNames();
        Map<String, DimensionRegistry.DimensionDefinition> active = DimensionRegistry.getActive();

        Assert.areEqual(active.keySet(), names, 'Developer names match active map keys');
    }

    @IsTest
    static void testGet_KnownDimension() {
        DimensionRegistry.DimensionDefinition d = DimensionRegistry.get('Completeness');
        Assert.isNotNull(d, 'Completeness should exist in CMDT');
        Assert.areEqual('Completeness', d.developerName, 'Name matches');
        Assert.isTrue(d.isActive, 'Completeness is active');
    }

    @IsTest
    static void testGet_UnknownDimension() {
        DimensionRegistry.DimensionDefinition d = DimensionRegistry.get('NonexistentDim');
        Assert.isNull(d, 'Unknown dimension returns null');
    }

    @IsTest
    static void testGet_Blank() {
        Assert.isNull(DimensionRegistry.get(null), 'Null returns null');
        Assert.isNull(DimensionRegistry.get(''), 'Blank returns null');
    }

    @IsTest
    static void testAnyRequiresLLM() {
        // LLM-backed dims (Completeness/Structure/Clarity) → true.
        Assert.isTrue(
            DimensionRegistry.anyRequiresLLM(new Set<String>{ 'Freshness', 'Completeness' }),
            'A set containing an LLM-backed dimension should be true');
        // Deterministic-only dims (Freshness/Duplication/Conflict) → false.
        Assert.isFalse(
            DimensionRegistry.anyRequiresLLM(new Set<String>{ 'Freshness', 'Duplication', 'Conflict' }),
            'A deterministic-only dimension set should be false');
        // Null / empty / unknown → false.
        Assert.isFalse(DimensionRegistry.anyRequiresLLM(null), 'Null is false');
        Assert.isFalse(DimensionRegistry.anyRequiresLLM(new Set<String>()), 'Empty is false');
        Assert.isFalse(DimensionRegistry.anyRequiresLLM(new Set<String>{ 'NonexistentDim' }),
            'Unknown dimension is false');
    }

    @IsTest
    static void testGetActiveWeights_SumToOne() {
        Test.startTest();
        Map<String, Decimal> weights = DimensionRegistry.getActiveWeights();
        Test.stopTest();

        Assert.isFalse(weights.isEmpty(), 'Weights map non-empty');
        Decimal total = 0;
        for (Decimal w : weights.values()) {
            total += w;
        }
        Assert.isTrue(Math.abs(total - 1.0) < 0.02, 'Weights sum to ~1.0; got ' + total);
    }

    @IsTest
    static void testGetWeight_KnownDim() {
        Decimal w = DimensionRegistry.getWeight('Completeness');
        Assert.isTrue(w > 0, 'Completeness weight should be positive');
    }

    @IsTest
    static void testGetWeight_UnknownDimension_ReturnsZero() {
        Test.startTest();
        Decimal weight = DimensionRegistry.getWeight('NotARealDimension__NoSuchThing');
        Test.stopTest();

        Assert.areEqual(0, weight, 'Unregistered dimension falls back to 0 via the getWeight null-check');
    }

    @IsTest
    static void testGetActiveWeights_StringOverride_ParsesAndMerges() {
        KB_Score_Weight__c weights = new KB_Score_Weight__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Weights_JSON__c = '{"Completeness": "0.42"}'
        );
        upsert weights;
        DimensionRegistry.resetCache();

        Test.startTest();
        Map<String, Decimal> result = DimensionRegistry.getActiveWeights();
        Test.stopTest();

        Assert.areEqual(0.42, result.get('Completeness'),
            'A string-encoded numeric override should parse via Decimal.valueOf');
        DimensionRegistry.resetCache();
    }

    @IsTest
    static void testGetActiveWeights_UnparsableStringOverride_KeepsDefault() {
        Decimal defaultWeight = DimensionRegistry.getWeight('Completeness');

        KB_Score_Weight__c weights = new KB_Score_Weight__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Weights_JSON__c = '{"Completeness": "not-a-number"}'
        );
        upsert weights;
        DimensionRegistry.resetCache();

        Test.startTest();
        Map<String, Decimal> result = DimensionRegistry.getActiveWeights();
        Test.stopTest();

        Assert.areEqual(defaultWeight, result.get('Completeness'),
            'An unparsable string override is caught and the CMDT default is kept');
        DimensionRegistry.resetCache();
    }

    @IsTest
    static void testGetActiveWeights_MalformedJson_FallsBackToDefaults() {
        KB_Score_Weight__c weights = new KB_Score_Weight__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Weights_JSON__c = 'not valid json at all'
        );
        upsert weights;
        DimensionRegistry.resetCache();

        Test.startTest();
        Map<String, Decimal> result = DimensionRegistry.getActiveWeights();
        Test.stopTest();

        Assert.isFalse(result.isEmpty(),
            'Malformed Weights_JSON__c is caught and defaults are returned, not an exception');
        DimensionRegistry.resetCache();
    }

    @IsTest
    static void testRenormalise_SubsetSumsToOne() {
        Set<String> subset = new Set<String>{ 'Completeness', 'Structure' };
        Map<String, Decimal> renormed = DimensionRegistry.renormalise(subset);

        Assert.areEqual(2, renormed.size(), 'Only requested dims');
        Decimal total = 0;
        for (Decimal w : renormed.values()) total += w;
        Assert.isTrue(Math.abs(total - 1.0) < 0.02, 'Renormalized weights sum to ~1.0; got ' + total);
    }

    @IsTest
    static void testRenormalise_EmptySetReturnsAll() {
        Map<String, Decimal> renormed = DimensionRegistry.renormalise(new Set<String>());
        Assert.isFalse(renormed.isEmpty(), 'Empty set falls back to all active');
    }

    @IsTest
    static void testValidate_ActiveDimsPassValidation() {
        Test.startTest();
        List<String> errors = DimensionRegistry.validate();
        Test.stopTest();

        Assert.isTrue(errors.isEmpty(),
            'All active CMDT dimensions should pass validation. Errors: ' + String.join(errors, '; '));
    }

    @IsTest
    static void testEstimateCallouts_LLMEnabled() {
        Set<String> allDims = DimensionRegistry.getActiveDeveloperNames();
        Integer estimate = DimensionRegistry.estimateCallouts(allDims, 10, true);
        Assert.isTrue(estimate > 0, 'LLM-enabled should estimate > 0 callouts for 10 articles');
    }

    @IsTest
    static void testEstimateCallouts_LLMDisabled() {
        Set<String> allDims = DimensionRegistry.getActiveDeveloperNames();
        Integer estimate = DimensionRegistry.estimateCallouts(allDims, 10, false);
        Assert.areEqual(0, estimate, 'LLM-disabled should estimate 0 callouts');
    }
}
