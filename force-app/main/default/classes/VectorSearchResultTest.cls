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
 * Coverage for VectorSearchResult — pure DTO with two constructors and
 * six @AuraEnabled fields. Verifies field assignment and the no-arg
 * default-construction path.
 */
@IsTest
private class VectorSearchResultTest {

    @IsTest
    static void testNoArgConstructor_AllFieldsNull() {
        VectorSearchResult r = new VectorSearchResult();

        Assert.isNull(r.articleVersionId);
        Assert.isNull(r.articleTitle);
        Assert.isNull(r.articleNumber);
        Assert.isNull(r.similarityScore);
        Assert.isNull(r.matchedChunkText);
        Assert.isNull(r.pairedArticleVersionId,
            'pairedArticleVersionId is set by callers post-construction');
    }

    @IsTest
    static void testFiveArgConstructor_AssignsAllNonPairedFields() {
        VectorSearchResult r = new VectorSearchResult(
            'ka01ABC',
            'Reset password',
            'KA-1234',
            0.92,
            '<p>To reset your password…</p>'
        );

        Assert.areEqual('ka01ABC', r.articleVersionId);
        Assert.areEqual('Reset password', r.articleTitle);
        Assert.areEqual('KA-1234', r.articleNumber);
        Assert.areEqual(0.92, r.similarityScore);
        Assert.areEqual('<p>To reset your password…</p>', r.matchedChunkText);
        Assert.isNull(r.pairedArticleVersionId,
            'pairedArticleVersionId is set externally — not part of this ctor');
    }

    @IsTest
    static void testFieldAssignment_Mutable() {
        // Apex DTOs without setters still allow direct field assignment.
        // Lock in that the @AuraEnabled fields are read/write so callers
        // such as Tier1SOQLFallbackService.findSimilarPairs can populate
        // pairedArticleVersionId after construction.
        VectorSearchResult r = new VectorSearchResult();
        r.articleVersionId = 'ka01XYZ';
        r.articleTitle = 'Title';
        r.articleNumber = 'KA-5678';
        r.similarityScore = 0.5;
        r.matchedChunkText = 'chunk';
        r.pairedArticleVersionId = 'ka01PAIR';

        Assert.areEqual('ka01XYZ', r.articleVersionId);
        Assert.areEqual('ka01PAIR', r.pairedArticleVersionId);
    }
}
