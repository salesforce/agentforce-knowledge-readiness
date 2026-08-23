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
 * Tier 2 Fallback: Indexed Taxonomy SOQL Search.
 *
 * Used when Data Cloud Vector Search is unavailable. Uses selective SOQL
 * against Language and Title keywords to find 20 candidates.
 *
 * IMPORTANT: This is a LAST RESORT. Without semantic similarity, expect a
 * significantly higher false positive rate. Downstream tiers (3 and 4) will
 * absorb the noise at additional AI credit cost.
 */
public inherited sharing class Tier1SOQLFallbackService implements IVectorSearchService {

    public List<VectorSearchResult> searchSimilarArticles(
        String queryText,
        Integer maxResults,
        Decimal similarityThreshold
    ) {
        String keyword = extractSignificantKeyword(queryText);
        if (String.isBlank(keyword)) {
            return new List<VectorSearchResult>();
        }
        String safeKeyword = String.escapeSingleQuotes(keyword) + '%';
        Integer safeLimit = (maxResults != null && maxResults > 0) ? maxResults : 20;

        List<Knowledge__kav> candidates = [
            SELECT Id, Title, ArticleNumber
            FROM Knowledge__kav
            WHERE PublishStatus = 'Online'
            AND IsLatestVersion = true
            AND Title LIKE :safeKeyword
            ORDER BY LastModifiedDate DESC
            LIMIT :safeLimit
        ];

        List<VectorSearchResult> results = new List<VectorSearchResult>();
        for (Knowledge__kav kav : candidates) {
            VectorSearchResult r = new VectorSearchResult();
            r.articleVersionId = kav.Id;
            r.articleTitle = kav.Title;
            r.articleNumber = kav.ArticleNumber;
            r.similarityScore = 0.5;
            results.add(r);
        }
        return results;
    }

    public List<VectorSearchResult> findSimilarPairs(
        List<String> articleVersionIds,
        Integer maxResults,
        Decimal similarityThreshold
    ) {
        List<VectorSearchResult> allResults = new List<VectorSearchResult>();
        for (String versionId : articleVersionIds) {
            List<Id> candidateIds = findCandidatesByTaxonomy(Id.valueOf(versionId));
            if (candidateIds.isEmpty()) {
                continue;
            }
            List<Knowledge__kav> articles = [
                SELECT Id, Title, ArticleNumber
                FROM Knowledge__kav
                WHERE Id IN :candidateIds
            ];
            for (Knowledge__kav kav : articles) {
                VectorSearchResult r = new VectorSearchResult();
                r.articleVersionId = kav.Id;
                r.articleTitle = kav.Title;
                r.articleNumber = kav.ArticleNumber;
                r.similarityScore = 0.5;
                r.pairedArticleVersionId = versionId;
                allResults.add(r);
            }
        }
        return allResults;
    }

    /**
     * Finds up to 20 candidate articles similar to the target using
     * taxonomy-based SOQL with indexed trailing wildcards.
     *
 * Per / dedup-correctness principle: this is a dedup-candidate
     * search and intentionally does NOT honor the wizard's Step 2 prefilters
     * (publishStatus / language / articleType / titlePattern). Prefilters
     * scope which articles get *picked up by the batch runner* — they must
     * not also scope which neighbors a picked article is compared against,
     * or two admins running the same scan with different prefilters would
     * see different duplicate results on the same dataset. The vector path
     * (`ConnectApiVectorSearchService`) already ignores prefilters; this
     * fallback is now consistent with it.
     *
     * Hardcoded scopes that ARE applied (not prefilter-derived):
     *   - PublishStatus = 'Online' — Tier 2 looks for retrievable production
     *     duplicates; Draft/Archived versions can't be hit by retrieval and
     *     would produce noisy candidates.
     *   - Language = target article's own Language — cross-language pairs are
     *     rarely true duplicates; comparing en_US to ja produces noise. Falls
     *     back to en_US when the target article has no Language stamp.
     *   - IsLatestVersion = true — older versions are not retrievable.
     */
    public static List<Id> findCandidatesByTaxonomy(Id targetArticleVersionId) {
        Knowledge__kav targetArt = [
            SELECT Title, Language
            FROM Knowledge__kav
            WHERE Id = :targetArticleVersionId
            LIMIT 1
        ];

        // Extract significant keyword: longest word from title (strip stop words)
        String significantKeyword = extractSignificantKeyword(targetArt.Title);
        String safeKeyword = String.escapeSingleQuotes(significantKeyword) + '%';
        String effectiveLanguage = String.isNotBlank(targetArt.Language) ? targetArt.Language : 'en_US';

        // Strict query: language + title keyword (trailing wildcard for index usage)
        List<Knowledge__kav> candidates = [
            SELECT Id
            FROM Knowledge__kav
            WHERE PublishStatus = 'Online'
            AND IsLatestVersion = true
            AND Language = :effectiveLanguage
            AND Title LIKE :safeKeyword
            AND Id != :targetArticleVersionId
            LIMIT 20
        ];

        // Graceful degradation: if 0 matches, drop title filter
        if (candidates.isEmpty()) {
            candidates = [
                SELECT Id
                FROM Knowledge__kav
                WHERE PublishStatus = 'Online'
                AND IsLatestVersion = true
                AND Language = :effectiveLanguage
                AND Id != :targetArticleVersionId
                ORDER BY LastModifiedDate DESC
                LIMIT 20
            ];
        }

        List<Id> candidateIds = new List<Id>();
        for (Knowledge__kav c : candidates) {
            candidateIds.add(c.Id);
        }
        return candidateIds;
    }

    /**
     * Extracts the most significant (longest non-stop-word) keyword from a title.
     */
    private static String extractSignificantKeyword(String title) {
        if (String.isBlank(title)) {
            return '';
        }

        Set<String> stopWords = new Set<String>{
            'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been',
            'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from',
            'and', 'or', 'not', 'how', 'do', 'does', 'can', 'my', 'your',
            'i', 'you', 'we', 'it', 'this', 'that', 'what', 'when', 'why'
        };

        String longestWord = '';
        for (String word : title.toLowerCase().split('\\s+')) {
            String cleaned = word.replaceAll('[^a-z0-9]', '');
            if (cleaned.length() > longestWord.length() && !stopWords.contains(cleaned)) {
                longestWord = cleaned;
            }
        }

        return longestWord;
    }
}
