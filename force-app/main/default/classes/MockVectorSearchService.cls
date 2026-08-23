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
public class MockVectorSearchService implements IVectorSearchService {

    public List<VectorSearchResult> mockSearchResults = new List<VectorSearchResult>();
    public List<VectorSearchResult> mockPairResults = new List<VectorSearchResult>();
    public Integer searchCallCount = 0;
    public Integer pairCallCount = 0;
    public Boolean throwException = false;

    public List<VectorSearchResult> searchSimilarArticles(
        String queryText,
        Integer maxResults,
        Decimal similarityThreshold
    ) {
        searchCallCount++;
        if (throwException) {
            throw new KnowledgeAIException('Mock vector search error');
        }
        return mockSearchResults;
    }

    public List<VectorSearchResult> findSimilarPairs(
        List<String> articleVersionIds,
        Integer maxResults,
        Decimal similarityThreshold
    ) {
        pairCallCount++;
        if (throwException) {
            throw new KnowledgeAIException('Mock vector search error');
        }
        return mockPairResults;
    }
}
