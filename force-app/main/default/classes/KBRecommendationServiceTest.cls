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
private class KBRecommendationServiceTest {

    // ==================== getPriority ====================

    @IsTest
    static void testGetPriority_High() {
        String priority = KBRecommendationService.getPriority(30);
        Assert.areEqual('High', priority, 'Score below 40 should be High priority');
    }

    @IsTest
    static void testGetPriority_Medium() {
        String priority = KBRecommendationService.getPriority(55);
        Assert.areEqual('Medium', priority, 'Score 40-69 should be Medium priority');
    }

    @IsTest
    static void testGetPriority_Low() {
        String priority = KBRecommendationService.getPriority(80);
        Assert.areEqual('Low', priority, 'Score 70+ should be Low priority');
    }

    @IsTest
    static void testGetPriority_NullScore() {
        String priority = KBRecommendationService.getPriority(null);
        Assert.areEqual('Medium', priority, 'Null score should default to Medium');
    }

    @IsTest
    static void testGetPriority_BoundaryAt40() {
        Assert.areEqual('Medium', KBRecommendationService.getPriority(40), 'Score exactly 40 is Medium');
        Assert.areEqual('High',   KBRecommendationService.getPriority(39), 'Score 39 is High');
    }

    @IsTest
    static void testGetPriority_BoundaryAt70() {
        Assert.areEqual('Low',    KBRecommendationService.getPriority(70), 'Score exactly 70 is Low');
        Assert.areEqual('Medium', KBRecommendationService.getPriority(69), 'Score 69 is Medium');
    }

 // ==================== mapIssueToEffort (Freshness-only post-) ====================

    @IsTest
    static void testMapIssueToEffort_FreshnessIsMedium() {
        // The mapper now collapses every Freshness issue to Medium — calendar
        // age advice always lands at "review and rewrite anything stale".
        Assert.areEqual('Medium',
            KBRecommendationService.mapIssueToEffort('Freshness', 'Article is stale'));
        Assert.areEqual('Medium',
            KBRecommendationService.mapIssueToEffort('Freshness', 'Article is critically old (24 months)'));
        Assert.areEqual('Medium',
            KBRecommendationService.mapIssueToEffort('Freshness', 'unrelated freshness signal'));
    }

 // ==================== mapIssueToRecommendation (Freshness-only post-) ====================

    @IsTest
    static void testMapIssueToRecommendation_FreshnessCritical() {
        String rec = KBRecommendationService.mapIssueToRecommendation(
            'Freshness', 'Article is critically old (24 months)'
        );
        Assert.isTrue(rec.contains('critically') || rec.contains('immediate'),
            'Critically-old recommendation should indicate urgency');
    }

    @IsTest
    static void testMapIssueToRecommendation_FreshnessStale() {
        String rec = KBRecommendationService.mapIssueToRecommendation(
            'Freshness', 'Article is stale - 12 months old'
        );
        Assert.isTrue(rec.contains('12') || rec.contains('update') || rec.contains('review'),
            'Stale-age recommendation should suggest review/update');
    }

    @IsTest
    static void testMapIssueToRecommendation_FreshnessFallback() {
        String rec = KBRecommendationService.mapIssueToRecommendation(
            'Freshness', 'unrelated freshness signal'
        );
        Assert.isTrue(rec.contains('review'),
            'Freshness fallback should suggest a content review');
    }

    @IsTest
    static void testMapIssueToRecommendation_NullIssueIsSafe() {
        // Defence-in-depth: null/blank issue text should not throw — the
        // mapper guards against null and falls through to the generic
        // review-and-update advice.
        String rec = KBRecommendationService.mapIssueToRecommendation('Freshness', null);
        Assert.isNotNull(rec, 'Null issue should still produce a recommendation');
    }
}
