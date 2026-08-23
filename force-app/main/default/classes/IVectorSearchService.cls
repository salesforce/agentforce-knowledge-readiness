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
 * Interface for Data Cloud vector search operations.
 * Implementations can use ConnectApi or REST callouts.
 * Swap the active implementation via Vector_Search_Config__mdt.
 */
public interface IVectorSearchService {

    /**
     * Searches for published articles similar to the given query text.
     * Used by the draft verification flow (point-of-creation check).
     *
     * @param queryText The text to search against the vector index
     * @param maxResults Maximum number of results to return
     * @param similarityThreshold Minimum similarity score (0.00 - 1.00)
     * @return List of similar articles with similarity scores
     */
    List<VectorSearchResult> searchSimilarArticles(
        String queryText,
        Integer maxResults,
        Decimal similarityThreshold
    );

    /**
     * Finds pairs of published articles with high similarity.
     * Used by the batch audit job (continuous sanity check).
     *
     * @param articleVersionIds The article version IDs to find pairs for
     * @param maxResults Maximum number of similar results per article
     * @param similarityThreshold Minimum similarity score (0.00 - 1.00)
     * @return List of paired results with similarity scores
     */
    List<VectorSearchResult> findSimilarPairs(
        List<String> articleVersionIds,
        Integer maxResults,
        Decimal similarityThreshold
    );
}
