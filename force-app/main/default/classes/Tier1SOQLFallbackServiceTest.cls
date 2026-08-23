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
 * Coverage for the SOQL keyword fallback that runs when Data Cloud vector
 * search is unavailable.
 *
 * Per /: the fallback no longer honors wizard Step 2 prefilters
 * (dedup-correctness — both Tier 2 paths now scope candidates the same way
 * regardless of admin prefilter config). PublishStatus is hardcoded to
 * 'Online' and Language is taken from the target article. @TestSetup's KAVs
 * are inserted as Draft (the only status available at insert time); most
 * tests below accept the resulting "no candidates" outcome and assert
 * keyword-extraction + branch coverage instead. The tests nearer the bottom
 * that need real Online matches call KbManagement.PublishingService directly
 * within the test method to publish specific fixtures — that call works
 * fine from inside an @IsTest method (see KBEnrichmentControllerTest /
 * DuplicateCandidateControllerTest for other examples), just not from these
 * particular Draft-by-design tests.
 */
@IsTest
private class Tier1SOQLFallbackServiceTest {

    @TestSetup
    static void setup() {
        // Articles: one with the keyword "password" (matching), one with
        // "configuration" (also matching different keyword), one stop-words-
        // only ("the and a is"), one isolated language reference.
        // Inserted as Draft (the only PublishStatus available without
        // explicit publishing). The production query filters to Online, so
        // these are coverage-only fixtures — assertions are scoped to
        // keyword extraction and SOQL-execution branches that don't depend
        // on the result set being non-empty.
        List<Knowledge__kav> kavs = new List<Knowledge__kav>{
            new Knowledge__kav(
                Title = 'How to reset your password',
                UrlName = 'fallback-1-' + System.currentTimeMillis(),
                Language = 'en_US',
                Summary = 'Password reset article'
            ),
            new Knowledge__kav(
                Title = 'Password best practices guide',
                UrlName = 'fallback-2-' + System.currentTimeMillis(),
                Language = 'en_US',
                Summary = 'Password tips'
            ),
            new Knowledge__kav(
                Title = 'Configuration overview',
                UrlName = 'fallback-3-' + System.currentTimeMillis(),
                Language = 'en_US',
                Summary = 'Config'
            ),
            new Knowledge__kav(
                Title = 'the and a is',
                UrlName = 'fallback-4-' + System.currentTimeMillis(),
                Language = 'en_US',
                Summary = 'Stop words only'
            ),
            new Knowledge__kav(
                Title = 'Network connectivity troubleshooting',
                UrlName = 'fallback-5-' + System.currentTimeMillis(),
                Language = 'en_US',
                Summary = 'Network help'
            )
        };
        insert kavs;
    }

    private static Tier1SOQLFallbackService svc() {
        return new Tier1SOQLFallbackService();
    }

    @IsTest
    static void testSearchSimilarArticles_BlankQuery_ReturnsEmpty() {
        Test.startTest();
        List<VectorSearchResult> results = svc().searchSimilarArticles('', 20, 0.5);
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Blank query yields no candidates');
    }

    @IsTest
    static void testSearchSimilarArticles_StopWordsOnly_ReturnsEmpty() {
        // Indirectly exercises extractSignificantKeyword — every word is a
        // stop word, so longestWord is '' and the early return fires.
        Test.startTest();
        List<VectorSearchResult> results = svc().searchSimilarArticles('the and a is', 20, 0.5);
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Stop-words-only input yields no candidates');
    }

    @IsTest
    static void testSearchSimilarArticles_FiltersByPublishStatusOnline() {
        // Note: searchSimilarArticles HARDCODES PublishStatus='Online'
        // (unlike findCandidatesByTaxonomy which honors RuntimeFilters).
        // Test articles are Draft, so this query returns nothing — but
        // the keyword extraction + safeKeyword + safeLimit branches all
        // run, which is what we need for coverage.
        Test.startTest();
        List<VectorSearchResult> results = svc().searchSimilarArticles('password', 20, 0.5);
        Test.stopTest();

        Assert.areEqual(0, results.size(),
            'Searching for Online articles in a Draft-only test org returns empty');
    }

    @IsTest
    static void testSearchSimilarArticles_NullMaxResults_UsesDefault() {
        Test.startTest();
        List<VectorSearchResult> results = svc().searchSimilarArticles('password', null, 0.5);
        Test.stopTest();

        // Same as above — Draft-vs-Online means 0 results, but the default-
        // limit branch executes.
        Assert.areEqual(0, results.size(),
            'Default limit branch runs without throwing');
    }

    @IsTest
    static void testFindCandidatesByTaxonomy_PublishStatusOnline_RunsWithoutThrowing() {
 // Production query filters to PublishStatus='Online' (dedup-
        // correctness). Test articles are Draft, so the result is expected
        // empty — but the keyword-extraction + SOQL execution branches all
        // run, which is what we need for branch coverage.
        Knowledge__kav target = [
            SELECT Id FROM Knowledge__kav
            WHERE Title = 'How to reset your password' LIMIT 1
        ];

        Test.startTest();
        List<Id> candidates = Tier1SOQLFallbackService.findCandidatesByTaxonomy(target.Id);
        Test.stopTest();

        Assert.isNotNull(candidates, 'Result list is never null');
        Assert.isFalse(candidates.contains(target.Id), 'Target article never appears in its own candidates');
    }

    @IsTest
    static void testFindCandidatesByTaxonomy_NoTitleMatch_FallsThroughToLanguageBranch() {
        // Even when the keyword ("network") matches no Online article, the
        // graceful-degradation language-only fallback branch still executes.
        // No candidates returned (Drafts), but coverage hits both branches.
        Knowledge__kav target = [
            SELECT Id FROM Knowledge__kav
            WHERE Title = 'Network connectivity troubleshooting' LIMIT 1
        ];

        Test.startTest();
        List<Id> candidates = Tier1SOQLFallbackService.findCandidatesByTaxonomy(target.Id);
        Test.stopTest();

        Assert.isNotNull(candidates,
            'Language-fallback branch executes without throwing');
        Assert.isFalse(candidates.contains(target.Id), 'Target excluded from fallback');
    }

    // These three tests publish two of @TestSetup's own Draft fixtures via
    // KbManagement.PublishingService (proven safe to call directly inside an
    // @IsTest method elsewhere in this codebase, e.g.
    // KBEnrichmentControllerTest / DuplicateCandidateControllerTest) so the
    // Online-match loop bodies are reachable at all — plain Draft rows never
    // satisfy the production query's PublishStatus = 'Online' filter. Scoped
    // to each test method rather than @TestSetup, so the existing
    // Draft-only tests above (which assert exactly 0 results) are untouched.

    @IsTest
    static void testSearchSimilarArticles_PublishedArticles_ReturnsResults() {
        Knowledge__kav match = [
            SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Title = 'Password best practices guide' LIMIT 1
        ];
        KbManagement.PublishingService.publishArticle(match.KnowledgeArticleId, true);

        Test.startTest();
        List<VectorSearchResult> results = svc().searchSimilarArticles('Password', 20, 0.5);
        Test.stopTest();

        Assert.isFalse(results.isEmpty(),
            'A keyword prefix-matching the now-Online article\'s title must return it');
    }

    @IsTest
    static void testFindCandidatesByTaxonomy_PublishedArticles_ReturnsNonEmpty() {
        Knowledge__kav target = [
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav
            WHERE Title = 'How to reset your password' LIMIT 1
        ];
        Knowledge__kav match = [
            SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Title = 'Password best practices guide' LIMIT 1
        ];
        KbManagement.PublishingService.publishArticle(target.KnowledgeArticleId, true);
        KbManagement.PublishingService.publishArticle(match.KnowledgeArticleId, true);

        Test.startTest();
        List<Id> candidates = Tier1SOQLFallbackService.findCandidatesByTaxonomy(target.Id);
        Test.stopTest();

        Assert.isFalse(candidates.isEmpty(),
            'The significant keyword ("password") prefix-matches the other published article');
    }

    @IsTest
    static void testFindSimilarPairs_PublishedArticles_ReturnsEnrichedResults() {
        Knowledge__kav target = [
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav
            WHERE Title = 'How to reset your password' LIMIT 1
        ];
        Knowledge__kav match = [
            SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Title = 'Password best practices guide' LIMIT 1
        ];
        KbManagement.PublishingService.publishArticle(target.KnowledgeArticleId, true);
        KbManagement.PublishingService.publishArticle(match.KnowledgeArticleId, true);

        Test.startTest();
        List<VectorSearchResult> results = svc().findSimilarPairs(
            new List<String>{ String.valueOf(target.Id) }, 20, 0.5
        );
        Test.stopTest();

        Assert.isFalse(results.isEmpty(), 'The published target must surface at least one paired candidate');
        for (VectorSearchResult r : results) {
            Assert.areEqual(String.valueOf(target.Id), r.pairedArticleVersionId,
                'Each result is paired to the requested target');
        }
    }

    @IsTest
    static void testFindSimilarPairs_RunsWithoutThrowing() {
        Knowledge__kav target = [
            SELECT Id FROM Knowledge__kav
            WHERE Title = 'How to reset your password' LIMIT 1
        ];

        Test.startTest();
        List<VectorSearchResult> results = svc().findSimilarPairs(
            new List<String>{ String.valueOf(target.Id) }, 20, 0.5
        );
        Test.stopTest();

        Assert.isNotNull(results, 'findSimilarPairs returns a non-null list');
        // findSimilarPairs delegates to findCandidatesByTaxonomy which filters
        // Online-only — Drafts won't yield results. We assert the wrapper's
        // shape contract instead: every result (when produced) attaches the
        // target's version id and the fallback similarity score.
        for (VectorSearchResult r : results) {
            Assert.areEqual(String.valueOf(target.Id), r.pairedArticleVersionId,
                'Each result is paired to the requested target');
            Assert.areEqual(0.5, r.similarityScore, 'Fallback score is 0.5');
        }
    }
}
