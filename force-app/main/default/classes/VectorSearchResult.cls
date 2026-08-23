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
 * DTO representing a single result from a Data Cloud vector search.
 * Used across both the draft verification and batch audit flows.
 */
public class VectorSearchResult {

    @AuraEnabled public String articleVersionId;
    @AuraEnabled public String articleTitle;
    @AuraEnabled public String articleNumber;
    @AuraEnabled public Decimal similarityScore;
    @AuraEnabled public String matchedChunkText;
    @AuraEnabled public String pairedArticleVersionId;

    public VectorSearchResult() {}

    public VectorSearchResult(
        String articleVersionId,
        String articleTitle,
        String articleNumber,
        Decimal similarityScore,
        String matchedChunkText
    ) {
        this.articleVersionId = articleVersionId;
        this.articleTitle = articleTitle;
        this.articleNumber = articleNumber;
        this.similarityScore = similarityScore;
        this.matchedChunkText = matchedChunkText;
    }
}
