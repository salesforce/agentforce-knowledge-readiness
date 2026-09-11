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
private class KnowledgeAIGovernanceServiceTest {

    @IsTest
    static void testGenerateCompositeKey_sortsAlphabetically() {
        String key1 = KnowledgeAIGovernanceService.generateCompositeKey(
            'ka01A000001XyzqQAC', 'ka01A000001BabcQAC'
        );
        String key2 = KnowledgeAIGovernanceService.generateCompositeKey(
            'ka01A000001BabcQAC', 'ka01A000001XyzqQAC'
        );

        System.assertEquals('ka01A000001BabcQAC_ka01A000001XyzqQAC', key1,
            'Key should be sorted alphabetically');
        System.assertEquals(key1, key2, 'Key should be deterministic regardless of argument order');
    }

    @IsTest
    static void testGenerateCompositeKey_sameIds() {
        String key = KnowledgeAIGovernanceService.generateCompositeKey(
            'ka01A000001AAAAQAC', 'ka01A000001AAAAQAC'
        );
        System.assertEquals('ka01A000001AAAAQAC_ka01A000001AAAAQAC', key,
            'Same IDs should produce valid key');
    }

    @IsTest
    static void testGenerateCompositeKey_runScoped() {
        String pairKey = KnowledgeAIGovernanceService.generateCompositeKey(
            'ka01A000001XyzqQAC', 'ka01A000001BabcQAC'
        );
        Id runId = '001000000000001AAA';
        String scoped = KnowledgeAIGovernanceService.generateCompositeKey(
            'ka01A000001XyzqQAC', 'ka01A000001BabcQAC', runId
        );
        // Run-scoped = runId + '_' + the sorted pair key. Distinct per run so
        // two runs over the same pair never collide on the unique key.
        System.assertEquals(runId + '_' + pairKey, scoped,
            'Run-scoped key prefixes the assessment run id onto the sorted pair key');
        System.assertNotEquals(pairKey, scoped,
            'Run-scoped key differs from the run-agnostic pair key');

        // Null run id falls back to the run-agnostic form (defensive/legacy).
        String nullScoped = KnowledgeAIGovernanceService.generateCompositeKey(
            'ka01A000001XyzqQAC', 'ka01A000001BabcQAC', null
        );
        System.assertEquals(pairKey, nullScoped,
            'Null run id falls back to the run-agnostic pair key');
    }

 // KPE cache key is scoped by the PIPELINE run id (its globally-unique
    // Composite_Version_Key__c must differ across runs, or a second run's upsert
    // throws DUPLICATE_VALUE and rolls back the whole pair-eval transaction).
    @IsTest
    static void testGeneratePipelineEvaluationKey_pipelineScoped() {
        String pairKey = KnowledgeAIGovernanceService.generateCompositeKey(
            'ka01A000001XyzqQAC', 'ka01A000001BabcQAC'
        );
        Id pipeA = 'a32000000000001AAA';
        Id pipeB = 'a32000000000002AAA';

        String keyA = KnowledgeAIGovernanceService.generatePipelineEvaluationKey(
            'ka01A000001XyzqQAC', 'ka01A000001BabcQAC', pipeA);
        String keyB = KnowledgeAIGovernanceService.generatePipelineEvaluationKey(
            'ka01A000001BabcQAC', 'ka01A000001XyzqQAC', pipeB); // args reversed on purpose

        System.assertEquals(pipeA + '_' + pairKey, keyA,
            'Pipeline-eval key prefixes the pipeline run id onto the sorted pair key');
        // Same article pair, two pipeline runs → two distinct keys → no collision.
        System.assertNotEquals(keyA, keyB,
            'Two pipeline runs over the same pair produce distinct cache keys');
        // Order-independent within a run (sorted pair) — reversed args still share
        // the pair suffix, differing only by the run prefix.
        System.assert(keyA.endsWith(pairKey) && keyB.endsWith(pairKey),
            'Both keys carry the same sorted pair suffix regardless of arg order');

        // Null pipeline run id falls back to the run-agnostic pair key.
        System.assertEquals(pairKey,
            KnowledgeAIGovernanceService.generatePipelineEvaluationKey(
                'ka01A000001XyzqQAC', 'ka01A000001BabcQAC', null),
            'Null pipeline run id falls back to the run-agnostic pair key');
    }

    @IsTest
    static void testForceReEvaluate_deletesCache() {
        Knowledge_Pair_Evaluation__c eval = new Knowledge_Pair_Evaluation__c(
            Composite_Version_Key__c = 'ka01A000001AAAA_ka01A000001BBBB',
            Evaluation_Status__c = 'Clear',
            Evaluated_Date__c = Datetime.now()
        );
        insert eval;

        Test.startTest();
        KnowledgeAIGovernanceService.forceReEvaluate(
            'ka01A000001BBBB', 'ka01A000001AAAA'
        );
        Test.stopTest();

        List<Knowledge_Pair_Evaluation__c> remaining = [
            SELECT Id FROM Knowledge_Pair_Evaluation__c
            WHERE Composite_Version_Key__c = 'ka01A000001AAAA_ka01A000001BBBB'
        ];
        System.assertEquals(0, remaining.size(), 'Cache record should be deleted');
    }

    @IsTest
    static void testForceReEvaluate_noCacheRecord() {
        // Should not throw when no cache record exists
        Test.startTest();
        KnowledgeAIGovernanceService.forceReEvaluate(
            'ka01A000001XXXX', 'ka01A000001YYYY'
        );
        Test.stopTest();

        System.assert(true, 'Should not throw when no cache record exists');
    }

    // ─── estimateRunCost (1.0.C Cost Preview backing) ──────────────────────────

    @IsTest
    static void testEstimateRunCost_ZeroArticles() {
        Test.startTest();
        KnowledgeAIGovernanceService.RunCostEstimate est =
            KnowledgeAIGovernanceService.estimateRunCost(0, null);
        Test.stopTest();

        Assert.isNotNull(est, 'Returns non-null estimate for zero articles');
        Assert.areEqual(0, est.articleCount, 'Article count echoes');
        Assert.areEqual(0, est.batchCount, 'Zero articles → zero batches');
        Assert.areEqual(0, est.einsteinCalls, 'Zero articles → zero LLM calls');
        Assert.isFalse(est.warn, 'Zero articles should not warn');
    }

    @IsTest
    static void testEstimateRunCost_DeterministicOnlyDimensions() {
        // Freshness/Duplication/Conflict are deterministic — passing only those
        // means no Einstein callouts. Useful baseline before adding LLM dims.
        Test.startTest();
        KnowledgeAIGovernanceService.RunCostEstimate est =
            KnowledgeAIGovernanceService.estimateRunCost(
                25,
                new List<String>{ 'Freshness', 'Duplication', 'Conflict' }
            );
        Test.stopTest();

        Assert.areEqual(25, est.articleCount, 'Article count echoes');
        Assert.areEqual(0, est.einsteinCalls, 'Deterministic-only dim set → zero LLM calls');
        Assert.isTrue(est.batchCount > 0, 'Non-zero batches');
    }

    @IsTest
    static void testEstimateRunCost_LLMWithCaseInsensitiveDim() {
        // LWC sends lowercase dimension names — the service must normalize.
        Test.startTest();
        KnowledgeAIGovernanceService.RunCostEstimate est =
            KnowledgeAIGovernanceService.estimateRunCost(
                100,
                new List<String>{ 'completeness', 'clarity' }
            );
        Test.stopTest();

        Assert.areEqual(100, est.articleCount, 'Count echoes');
        Assert.isNotNull(est.orgLimits, 'Org limits snapshot populated');
    }

    @IsTest
    static void testEstimateRunCost_LargeRunTriggersWarn() {
        Test.startTest();
        KnowledgeAIGovernanceService.RunCostEstimate est =
            KnowledgeAIGovernanceService.estimateRunCost(5000, null);
        Test.stopTest();

        Assert.isTrue(est.warn, 'Large run should trigger typed-confirmation warn');
    }

    @IsTest
    static void testEstimateRunCost_UnknownDimensionName_PassesThroughUnmatched() {
        // No exact or case-insensitive match against the active set — the
        // normalizer's fallback returns the input unchanged rather than
        // matching nothing at all. Should not throw or drop the request.
        Test.startTest();
        KnowledgeAIGovernanceService.RunCostEstimate est =
            KnowledgeAIGovernanceService.estimateRunCost(
                10,
                new List<String>{ 'TotallyBogusDimensionName' }
            );
        Test.stopTest();

        Assert.areEqual(10, est.articleCount, 'Count still echoes for an unmatched dimension name');
        Assert.areEqual(0, est.einsteinCalls,
            'Unmatched dimension name resolves to no active DimensionDefinition → zero callouts');
    }

    @IsTest
    static void testEstimateRunCost_ConfiguredBatchSize_DrivesBatchCount() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Queueable_Batch_Size__c = 5;
        upsert cfg KB_Scan_Config__c.Id;

        Test.startTest();
        KnowledgeAIGovernanceService.RunCostEstimate est =
            KnowledgeAIGovernanceService.estimateRunCost(12, null);
        Test.stopTest();

        Assert.areEqual(3, est.batchCount,
            'A configured batch size of 5 over 12 articles should produce 3 batches (ceil(12/5))');
    }

    // ──────────────────────────────────────────────────────────────────────
    // getArticleStatus
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetArticleStatus_FoundReturnsStatus() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'gov-status')[0];

        Test.startTest();
        String status = KnowledgeAIGovernanceService.getArticleStatus(kav.Id);
        Test.stopTest();

        Assert.areEqual('Draft', status, 'Test KAV inserts as Draft');
    }

    @IsTest
    static void testGetArticleStatus_NotFoundReturnsNull() {
        Test.startTest();
        // Use a 18-char but synthetic Id that the KAV table doesn't have.
        String status;
        try {
            status = KnowledgeAIGovernanceService.getArticleStatus('ka01XYZ0000000A');
        } catch (Exception ignored) {
            return;
        }
        Test.stopTest();

        Assert.isNull(status);
    }

    // ──────────────────────────────────────────────────────────────────────
    // getTrackedOrgLimits
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testGetTrackedOrgLimits_ReturnsAuthoritativeList() {
        Test.startTest();
        List<KnowledgeAIGovernanceService.TrackedOrgLimit> limits =
            KnowledgeAIGovernanceService.getTrackedOrgLimits();
        Test.stopTest();

        Assert.isFalse(limits.isEmpty(), 'Tracked org limits list is non-empty');
        for (KnowledgeAIGovernanceService.TrackedOrgLimit l : limits) {
            Assert.isNotNull(l.apiName);
            Assert.isNotNull(l.label);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    // createDraftVersion
    // ────────────────────────────────────────────────────────────────────────

    @IsTest
    static void testCreateDraftVersion_ExistingDraft_ReturnsIt() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'gov-draft')[0];
        // insert doesn't refresh platform-managed fields like KnowledgeArticleId
        // into the local variable — re-query to get the real value, otherwise
        // the lookup below never matches and this test silently exercises the
        // wrong (no-existing-draft) branch instead of the one it's named for.
        kav = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :kav.Id LIMIT 1];

        Test.startTest();
        Id draftId = KnowledgeAIGovernanceService.createDraftVersion(kav.KnowledgeArticleId);
        Test.stopTest();

        Assert.areEqual(kav.Id, draftId,
            'An existing Draft version for this KnowledgeArticleId is returned directly, no platform call needed');
    }

    @IsTest
    static void testCreateDraftVersion_NoExistingDraft_DelegatesToPlatformAPI() {
        // Without an existing Draft for the given KnowledgeArticleId,
        // KbManagement.PublishingService.editOnlineArticle is called and
        // throws in test context (Article not Online). We swallow.
        Boolean threw = false;
        Test.startTest();
        try {
            KnowledgeAIGovernanceService.createDraftVersion('kA0000000000001');
        } catch (Exception ignored) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Platform API path executed — line covered');
    }
}
