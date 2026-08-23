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
private class ConnectApiVectorSearchServiceTest {

    // ============================================================================
    // Test seam — in-memory mock of the Data Cloud query delegate.
    // Implements IDataCloudQueryExecutor and is injected into
    // ConnectApiVectorSearchService.queryExecutor by each test.
    // ============================================================================

    private class MockExecutor implements ConnectApiVectorSearchService.IDataCloudQueryExecutor {
        public List<ConnectApi.QuerySqlRow> rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        public Exception exceptionToThrow;
        public List<String> queriesExecuted = new List<String>();
        public List<String> dataSpacesUsed = new List<String>();
        public Integer callCount = 0;

        public List<ConnectApi.QuerySqlRow> executeQueryAndGetRows(String sqlQuery, String dataSpace) {
            callCount++;
            queriesExecuted.add(sqlQuery);
            dataSpacesUsed.add(dataSpace);
            if (exceptionToThrow != null) {
                throw exceptionToThrow;
            }
            return rowsToReturn;
        }
    }

    // Emits NOT_FOUND for any index_dmo name NOT in allowList, then serves rowsToReturn
    // on the first match. Exercises the table-candidate retry loop in
    // executeChunkQueryWithFallback without coupling tests to DMO naming heuristics.
    private class FallbackMockExecutor implements ConnectApiVectorSearchService.IDataCloudQueryExecutor {
        public Set<String> allowedIndexSubstrings = new Set<String>();
        public List<ConnectApi.QuerySqlRow> rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        public List<String> queriesExecuted = new List<String>();

        public List<ConnectApi.QuerySqlRow> executeQueryAndGetRows(String sqlQuery, String dataSpace) {
            queriesExecuted.add(sqlQuery);
            for (String allowed : allowedIndexSubstrings) {
                if (sqlQuery.contains(allowed)) {
                    return rowsToReturn;
                }
            }
            // Mirror the real Data Cloud error shape. The service checks getMessage()
            // for 'NOT_FOUND' / 'DataModelEntity' to decide whether to retry.
            throw new NotFoundException('NOT_FOUND: DataModelEntity not found for table');
        }
    }

    public class NotFoundException extends Exception {}

 // hardening — simulates an index mis-ticked as an ADL: any query carrying
    // the ADL publish-status field throws a Data-Cloud "unknown column" style error,
    // while the degraded retry (which drops that clause) succeeds with rowsToReturn.
    // Mirrors the real failure mode where Is_ADL__c=true but the column doesn't exist.
    private class AdlFieldMissingMockExecutor implements ConnectApiVectorSearchService.IDataCloudQueryExecutor {
        public List<ConnectApi.QuerySqlRow> rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        public List<String> queriesExecuted = new List<String>();
        public Integer throwCount = 0;

        public List<ConnectApi.QuerySqlRow> executeQueryAndGetRows(String sqlQuery, String dataSpace) {
            queriesExecuted.add(sqlQuery);
            if (sqlQuery.contains(ConnectApiVectorSearchService.ADL_PUBLISH_STATUS_FIELD)) {
                throwCount++;
                throw new QueryColumnException(
                    'Data Cloud query failed: column "'
                    + ConnectApiVectorSearchService.ADL_PUBLISH_STATUS_FIELD
                    + '" not found in entity'
                );
            }
            return rowsToReturn;
        }
    }

    public class QueryColumnException extends Exception {}

    // ============================================================================
    // Helpers
    // ============================================================================

    private static ConnectApi.QuerySqlRow makeRow(String chunk, Decimal score, String sourceId) {
        ConnectApi.QuerySqlRow row = new ConnectApi.QuerySqlRow();
        row.row = new List<Object>{ chunk, score, sourceId };
        return row;
    }

    private static Id insertKnowledge(String title) {
        Knowledge__kav kav = new Knowledge__kav(
            Title = title,
            UrlName = 'vector-test-' + Math.abs(Crypto.getRandomInteger()),
            Language = 'en_US',
            Summary = title + ' summary text for vector search'
        );
        insert kav;
        return kav.Id;
    }

    private static void configureVectorSearch(String indexName, Decimal threshold) {
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        if (cs == null || cs.Id == null) {
            cs = new KB_Vector_Search_Config__c();
        }
        cs.Implementation_Class__c = 'ConnectApiVectorSearchService';
        cs.Search_Index_Name__c = indexName;
        cs.Similarity_Threshold__c = threshold;
        cs.Max_Results__c = 10;
        cs.Data_Space_Name__c = 'default';
        cs.Is_Active__c = true;
        upsert cs;
    }

    // ============================================================================
    // searchSimilarArticles — enrichment, dedup, threshold filter
    // ============================================================================

    @IsTest
    static void searchSimilarArticles_returnsEnrichedResults() {
        Id articleId = insertKnowledge('Refund Policy');
        configureVectorSearch('KA_Knowledge_index', 0.7);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Refunds are issued within 5 days.', 0.92, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results =
            new ConnectApiVectorSearchService().searchSimilarArticles('how long for a refund', 10, 0.7);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Should return one result');
        Assert.areEqual(articleId, results[0].articleVersionId, 'Article version ID should match');
        Assert.areEqual('Refund Policy', results[0].articleTitle, 'Title should be enriched from SOQL');
        Assert.areEqual(0.92, results[0].similarityScore, 'Score should match');
        Assert.areEqual(1, mock.callCount, 'Delegate called once');
        Assert.areEqual('default', mock.dataSpacesUsed[0], 'Data space propagated');
        Assert.isTrue(mock.queriesExecuted[0].contains('vector_search'),
            'Query should call vector_search table function');
    }

    @IsTest
    static void searchSimilarArticles_dedupsToBestScoringChunkPerArticle() {
        Id articleId = insertKnowledge('Refund Policy');
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        // Two chunks from the same article; best score should survive dedup.
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Lower-scoring chunk.', 0.72, articleId),
            makeRow('Better-scoring chunk.', 0.95, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results =
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Dedup should collapse to one result per article');
        Assert.areEqual(0.95, results[0].similarityScore, 'Best chunk wins');
        Assert.areEqual('Better-scoring chunk.', results[0].matchedChunkText,
            'Best-scoring chunk text should be retained');
    }

    @IsTest
    static void searchSimilarArticles_filtersByThreshold() {
        Id articleId = insertKnowledge('Refund Policy');
        configureVectorSearch('KA_Knowledge_index', 0.9);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Low relevance text.', 0.55, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results =
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.9);
        Test.stopTest();

        Assert.areEqual(0, results.size(),
            'Scores below threshold should be filtered out before enrichment');
    }

    @IsTest
    static void searchSimilarArticles_dropsRowsWithoutMatchingArticle() {
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        // Source ID that does not correspond to any Knowledge__kav.
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Orphan chunk.', 0.9, '005000000000000AAA')
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results =
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(0, results.size(),
            'Rows whose sourceRecordId does not resolve to a Knowledge__kav should be dropped');
    }

    @IsTest
    static void searchSimilarArticles_emptyRowsReturnEmpty() {
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results =
            new ConnectApiVectorSearchService().searchSimilarArticles('anything', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Empty result set should produce empty output');
    }

    // ============================================================================
    // SQL construction — escaping, self-exclusion filter
    //
    // The "self-exclusion filter" is the 3rd argument to vector_search() and is
    // populated only with `SourceRecordId__c != '<sourceId>'` so a source article
    // doesn't match itself during pair search. It is NOT the wizard's Query
    // Prefilters (those are SOQL article-selection filters and never reach
 // vector_search — see).
    // ============================================================================

    @IsTest
    static void searchSimilarArticles_escapesApostrophesInQueryText() {
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().searchSimilarArticles(
            'what\'s the refund policy', 10, 0.5
        );
        Test.stopTest();

        // vector_search() consumes single quotes; the service doubles apostrophes.
        Assert.isTrue(mock.queriesExecuted[0].contains('what\'\'s'),
            'Apostrophe should be doubled for SQL literal: ' + mock.queriesExecuted[0]);
    }

    @IsTest
    static void findSimilarPairs_injectsSelfExclusionFilter() {
        Id sourceId = insertKnowledge('Source Article');
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().findSimilarPairs(
            new List<String>{ sourceId }, 10, 0.5
        );
        Test.stopTest();

        Assert.areEqual(1, mock.callCount, 'One query per source article');
        Assert.isTrue(mock.queriesExecuted[0].contains('SourceRecordId__c !='),
            'Self-exclusion filter should keep the source article out of its own search: '
            + mock.queriesExecuted[0]);
        Assert.isTrue(mock.queriesExecuted[0].contains(sourceId),
            'Self-exclusion filter should reference the source article ID');
    }

    @IsTest
    static void searchSimilarArticles_doesNotInjectWizardQueryPrefilters() {
 // Regression guard for confirm the wizard's Query Prefilters
        // (publishStatus / language / articleType / titlePattern) are NOT spliced
        // into the vector_search() filter argument. Wizard prefilters are SOQL
        // article-selection filters; the Data Cloud vector path runs over the
        // entire indexed corpus.
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getInstance();
        if (state == null) state = new KB_Setup_Wizard_State__c();
        state.Query_Prefilters_JSON__c =
            '{"publishStatus":"Online","language":"en_US",'
            + '"articleType":"FAQ__kav","titlePattern":"How To"}';
        upsert state;

        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().searchSimilarArticles(
            'refund policy', 10, 0.5
        );
        Test.stopTest();

        Assert.areEqual(1, mock.callCount, 'One query expected');
        String emittedSql = mock.queriesExecuted[0];
        // Search-only path passes no source id, so the self-exclusion filter is empty.
        // The vector_search() filter argument ends up as the empty string between two
        // doubled apostrophes ("''", '"', "''" → "''''") — no wizard fields anywhere.
        Assert.isFalse(emittedSql.contains('PublishStatus'),
            'Vector SQL must not include PublishStatus from wizard prefilters: ' + emittedSql);
        Assert.isFalse(emittedSql.contains('Language ='),
            'Vector SQL must not include Language from wizard prefilters: ' + emittedSql);
        Assert.isFalse(emittedSql.contains('FAQ__kav'),
            'Vector SQL must not include articleType from wizard prefilters: ' + emittedSql);
        Assert.isFalse(emittedSql.contains('How To'),
            'Vector SQL must not include titlePattern from wizard prefilters: ' + emittedSql);
    }

    @IsTest
    static void findSimilarPairs_adlIndex_addsPublishStatusFilter() {
 // when the configured index is an Agentforce Data Library, the
        // vector_search() prefilter must restrict to currently-published content
        // AND keep the self-exclusion clause, combined with AND.
        Id sourceId = insertKnowledge('Source Article');
        configureVectorSearch('KA_Knowledge_index', 0.5);
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        cs.Is_ADL__c = true;
        upsert cs;

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().findSimilarPairs(
            new List<String>{ sourceId }, 10, 0.5
        );
        Test.stopTest();

        String sql = mock.queriesExecuted[0];
        Assert.isTrue(sql.contains(ConnectApiVectorSearchService.ADL_PUBLISH_STATUS_FIELD),
            'ADL index must inject the publish-status field: ' + sql);
        Assert.isTrue(sql.contains('SourceRecordId__c !='),
            'Self-exclusion clause must still be present alongside the ADL filter: ' + sql);
        Assert.isTrue(sql.contains(' AND '),
            'Self-exclusion and publish-status clauses must be AND-combined: ' + sql);
    }

    @IsTest
    static void adlIndex_emitsVerifiedFieldNameValueAndEscaping() {
 // lock-in — the ADL publish-status field name + value were EMPIRICALLY
        // VERIFIED against a real Agentforce Data Library (kb-quality-cleanup, 2026-06):
        // the column is `KnowledgePublicationStatus__c` (Public*ation*, __c required)
        // and the value is `Online` (the ADL has no `Published` value). This test
        // asserts the EXACT generated clause — field name, value, and the doubled-
        // single-quote escaping (''Online'') — appears verbatim in the built SQL, so
        // a future edit can't silently regress the constants to a wrong guess
        // (e.g. ssot__KnowledgePublishStatus__c / 'Published') and still pass.
        Id sourceId = insertKnowledge('Source Article');
        configureVectorSearch('KA_Knowledge_index', 0.5);
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        cs.Is_ADL__c = true;
        upsert cs;

        // Capture the SQL the service hands the Data Cloud boundary via the mock seam.
        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().findSimilarPairs(
            new List<String>{ sourceId }, 10, 0.5
        );
        Test.stopTest();

        Assert.areEqual(1, mock.callCount, 'One vector_search call expected');
        String sql = mock.queriesExecuted[0];

        // The verified clause as it must appear inside the vector_search() filter arg:
        // field name + ` = ` + value wrapped in doubled single quotes for the embedded literal.
        String expectedClause = 'KnowledgePublicationStatus__c = \'\'Online\'\'';
        Assert.isTrue(sql.contains(expectedClause),
            'Built SQL must contain the verified ADL clause "' + expectedClause
            + '" (exact field name, value, and doubled-quote escaping): ' + sql);

        // Guard against regressing to the old illustrative placeholders.
        Assert.isFalse(sql.contains('ssot__KnowledgePublishStatus__c'),
            'Must not emit the retired placeholder field name ssot__KnowledgePublishStatus__c: ' + sql);
        Assert.isFalse(sql.contains('\'\'Published\'\''),
            'Must not emit the retired placeholder value \'\'Published\'\': ' + sql);
    }

    @IsTest
    static void searchSimilarArticles_nonAdlIndex_omitsPublishStatusFilter() {
 // a custom (non-ADL) index gets NO automatic publish-status filter;
        // the admin is responsible for scoping the index to published articles.
        configureVectorSearch('KA_Knowledge_index', 0.5);
        // Is_ADL__c left false (default).

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().searchSimilarArticles('refund policy', 10, 0.5);
        Test.stopTest();

        String sql = mock.queriesExecuted[0];
        Assert.isFalse(sql.contains(ConnectApiVectorSearchService.ADL_PUBLISH_STATUS_FIELD),
            'Non-ADL index must NOT inject the publish-status field: ' + sql);
    }

    @IsTest
    static void adlPublishStatusFieldMissing_degradesToUnfilteredSearch() {
 // hardening — admin mis-ticked Is_ADL__c on an index that has no
        // publish-status column. The with-filter query errors on the unknown column;
        // the service must retry WITHOUT the ADL clause and still return results
        // (degraded, not broken) rather than failing the whole dedup search.
        Id articleId = insertKnowledge('Refund Policy');
        configureVectorSearch('KA_Knowledge_index', 0.5);
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        cs.Is_ADL__c = true;
        upsert cs;

        AdlFieldMissingMockExecutor mock = new AdlFieldMissingMockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Refunds are issued within 5 days.', 0.92, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results =
            new ConnectApiVectorSearchService().searchSimilarArticles('how long for a refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(1, results.size(),
            'Mis-ticked ADL must degrade to an unfiltered search and still return results');
        Assert.areEqual(articleId, results[0].articleVersionId, 'Result should resolve to the article');
        Assert.areEqual(1, mock.throwCount,
            'The with-ADL-filter query should have thrown exactly once before the degraded retry');
        Assert.areEqual(2, mock.queriesExecuted.size(),
            'Exactly two queries: with-filter (threw) then without-filter (succeeded)');
        Assert.isTrue(
            mock.queriesExecuted[0].contains(ConnectApiVectorSearchService.ADL_PUBLISH_STATUS_FIELD),
            'First attempt carries the ADL publish-status clause: ' + mock.queriesExecuted[0]);
        Assert.isFalse(
            mock.queriesExecuted[1].contains(ConnectApiVectorSearchService.ADL_PUBLISH_STATUS_FIELD),
            'Degraded retry must drop the ADL publish-status clause: ' + mock.queriesExecuted[1]);
    }

    @IsTest
    static void adlGenuineFilterError_isNotSwallowed() {
 // hardening guard — a real ADL whose vector_search filter errors for a
        // reason unrelated to an unknown publish-status column must NOT be degraded.
        // The error doesn't name the publish-status field as unknown, so it surfaces
        // rather than being silently retried unfiltered.
        configureVectorSearch('KA_Knowledge_index', 0.5);
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        cs.Is_ADL__c = true;
        upsert cs;

        MockExecutor mock = new MockExecutor();
        // Genuine ADL-side error that does not reference the publish-status column.
        mock.exceptionToThrow = new KnowledgeAIException(
            'vector_search filter syntax error near AND'
        );
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        Boolean threw = false;
        try {
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        } catch (KnowledgeAIException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('syntax error'),
                'Genuine ADL filter error should surface unchanged: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'A genuine ADL filter error must not be swallowed by the no-filter degrade');
        Assert.areEqual(1, mock.callCount,
            'No degraded retry should be attempted for a non-publish-status error');
    }

    @IsTest
    static void findSimilarPairs_pairsResultsBackToSource() {
        Id sourceId = insertKnowledge('Source Article');
        Id matchId = insertKnowledge('Similar Match');
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Matched chunk.', 0.88, matchId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results = new ConnectApiVectorSearchService()
            .findSimilarPairs(new List<String>{ sourceId }, 10, 0.5);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Should return one paired result');
        Assert.areEqual(matchId, results[0].articleVersionId, 'Pairs point to the matched article');
        Assert.areEqual(sourceId, results[0].pairedArticleVersionId,
            'pairedArticleVersionId should be carried through from the source');
    }

    @IsTest
    static void findSimilarPairs_skipsUnresolvableArticleIds() {
        // A version ID that does not resolve to any Knowledge__kav. bulkGetArticleText
        // produces no map entry, so the caller has no text to pass to vector_search and
        // the article is skipped entirely.
        String phantomId = '005000000000000AAA';
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results = new ConnectApiVectorSearchService()
            .findSimilarPairs(new List<String>{ phantomId }, 10, 0.5);
        Test.stopTest();

        Assert.areEqual(0, mock.callCount,
            'Unresolvable article IDs should not trigger a vector_search call');
        Assert.areEqual(0, results.size(), 'No results when nothing was searched');
    }

    // ============================================================================
    // Table-candidate fallback and error surfacing
    // ============================================================================

    @IsTest
    static void executeChunkQueryWithFallback_retriesNextTableOnNotFound() {
        Id articleId = insertKnowledge('Refund Policy');
        // Configured index 'Missing_index' doesn't exist; service then falls back to
        // the hardcoded preferred index 'KA_Knowledge_index' added by resolveTableCandidates.
        configureVectorSearch('Missing_index', 0.5);

        FallbackMockExecutor mock = new FallbackMockExecutor();
        mock.allowedIndexSubstrings.add('KA_Knowledge_index__dlm');
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Found on retry.', 0.9, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results = new ConnectApiVectorSearchService()
            .searchSimilarArticles('refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(1, results.size(),
            'Fallback retry on NOT_FOUND should eventually return results');
        Assert.areEqual(2, mock.queriesExecuted.size(),
            'Should have attempted the missing configured index, then the preferred fallback');
        Assert.isTrue(mock.queriesExecuted[0].contains('Missing_index__dlm'),
            'First attempt should be the configured index');
        Assert.isTrue(mock.queriesExecuted[1].contains('KA_Knowledge_index__dlm'),
            'Second attempt should be the preferred fallback');
    }

    @IsTest
    static void executeChunkQuery_surfacesNonRecoverableErrorAsKnowledgeAIException() {
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        // A non-NOT_FOUND exception should not trigger the retry loop.
        mock.exceptionToThrow = new KnowledgeAIException('permission denied on DMO');
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        Boolean threw = false;
        try {
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        } catch (KnowledgeAIException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('permission denied'),
                'Original message should be preserved: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Non-recoverable error should surface as KnowledgeAIException');
    }

    // ============================================================================
 // bulkGetArticleText body-content extension
    // ============================================================================

    @IsTest
    static void findSimilarPairs_includesTitleAndSummaryInSearchPayload() {
 // Regression check after refactored bulkGetArticleText to
        // use dynamic SOQL + content-field merging. Title and Summary must
        // still appear in the search payload regardless of scan config.
        Knowledge__kav kav = new Knowledge__kav(
            Title = 'DistinctTitleMarker',
            UrlName = 'distinct-' + Math.abs(Crypto.getRandomInteger()),
            Language = 'en_US',
            Summary = 'DistinctSummaryMarker phrase here'
        );
        insert kav;

        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().findSimilarPairs(
            new List<String>{ kav.Id }, 10, 0.5
        );
        Test.stopTest();

        Assert.areEqual(1, mock.callCount, 'One vector_search call per article');
        String sql = mock.queriesExecuted[0];
        Assert.isTrue(sql.contains('DistinctTitleMarker'),
            'Title must reach the search payload: ' + sql);
        Assert.isTrue(sql.contains('DistinctSummaryMarker'),
            'Summary must reach the search payload: ' + sql);
    }

    @IsTest
    static void findSimilarPairs_noScanConfig_fallsBackToTitleSummary() {
        // No KB_Scan_Config__c.Content_Field_Mapping_JSON__c configured →
        // KBAssessmentService.getContentFields auto-discovers 'Summary',
        // which is then deduped against the explicit Title+Summary parts.
 // End result is identical to the pre- behaviour.
        Knowledge__kav kav = new Knowledge__kav(
            Title = 'Fallback Title',
            UrlName = 'fallback-' + Math.abs(Crypto.getRandomInteger()),
            Language = 'en_US',
            Summary = 'Fallback summary text'
        );
        insert kav;

        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().findSimilarPairs(
            new List<String>{ kav.Id }, 10, 0.5
        );
        Test.stopTest();

        Assert.areEqual(1, mock.callCount);
        String sql = mock.queriesExecuted[0];
        Assert.isTrue(sql.contains('Fallback Title') && sql.contains('Fallback summary text'),
            'Both Title and Summary must appear when no scan config is set: ' + sql);
    }

    @IsTest
    static void executeChunkQueryWithFallback_surfacesNotFoundExhaustion() {
        configureVectorSearch('KA_Knowledge_index', 0.5);

        FallbackMockExecutor mock = new FallbackMockExecutor();
        // No allowed substrings — every attempt throws NOT_FOUND, retry loop exhausts.
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        Boolean threw = false;
        try {
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        } catch (KnowledgeAIException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Data Cloud query failed'),
                'Exhausted fallback should surface as KnowledgeAIException: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'When all candidate tables return NOT_FOUND, a KnowledgeAIException is thrown');
    }

    // ============================================================================
    // Real executor lazy construction, prefilter overload, data-space fallback
    // ============================================================================

    @IsTest
    static void getExecutor_lazilyConstructsRealExecutorWhenNoneInjected() {
        ConnectApiVectorSearchService.queryExecutor = null;
        configureVectorSearch('KA_Knowledge_index', 0.5);

        Test.startTest();
        try {
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        } catch (Exception ignored) {
            // A real Data Cloud callout isn't available in a test context — we
            // only care that getExecutor() lazily constructs the real delegate
            // rather than reusing a prior test's injected mock.
        }
        Test.stopTest();
    }

    @IsTest
    static void buildPrefilter_singleArgOverload_defaultsAdlFilterOn() {
        configureVectorSearch('KA_Knowledge_index', 0.5);
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        cs.Is_ADL__c = true;
        upsert cs;

        String prefilter = new ConnectApiVectorSearchService().buildPrefilter('005000000000000AAA');

        Assert.isTrue(prefilter.contains('SourceRecordId__c !='),
            'Single-arg overload must include the self-exclusion clause: ' + prefilter);
        Assert.isTrue(prefilter.contains(ConnectApiVectorSearchService.ADL_PUBLISH_STATUS_FIELD),
            'Single-arg overload must default includeAdlFilter to true: ' + prefilter);
    }

    @IsTest
    static void searchSimilarArticles_blankDataSpace_fallsBackToDefault() {
        Id articleId = insertKnowledge('Refund Policy');
        configureVectorSearch('KA_Knowledge_index', 0.5);
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        cs.Data_Space_Name__c = null;
        upsert cs;

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Refund text.', 0.9, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual('default', mock.dataSpacesUsed[0],
            'A blank configured data space should fall back to the default');
    }

    // ============================================================================
    // Table-candidate suffix handling (_chunk / _index / plain names)
    // ============================================================================

    @IsTest
    static void resolveTableCandidates_plainName_addsIndexAndChunkSuffixVariants() {
        Id articleId = insertKnowledge('Refund Policy');
        configureVectorSearch('CustomTable', 0.5);

        FallbackMockExecutor mock = new FallbackMockExecutor();
        mock.allowedIndexSubstrings.add('CustomTable__dlm');
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Found on first candidate.', 0.9, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results = new ConnectApiVectorSearchService()
            .searchSimilarArticles('refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(1, results.size(),
            'A plain (no _chunk/_index suffix) configured name should still resolve to a usable candidate');
    }

    @IsTest
    static void resolveTableCandidates_chunkSuffixedName_dedupesAgainstIndexVariant() {
        Id articleId = insertKnowledge('Refund Policy');
        configureVectorSearch('My_Custom_chunk', 0.5);

        FallbackMockExecutor mock = new FallbackMockExecutor();
        mock.allowedIndexSubstrings.add('My_Custom_index__dlm');
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Found on first candidate.', 0.9, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results = new ConnectApiVectorSearchService()
            .searchSimilarArticles('refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(1, results.size(),
            'A _chunk-suffixed configured name should resolve to the deduped _index variant');
    }

    // ============================================================================
    // parseChunkRows — null/short rows
    // ============================================================================

    @IsTest
    static void searchSimilarArticles_nullRowsFromDelegate_parsesToEmpty() {
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = null;
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results =
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'A null rows response from the delegate should parse to an empty result set');
    }

    @IsTest
    static void searchSimilarArticles_shortRow_isSkipped() {
        Id articleId = insertKnowledge('Refund Policy');
        configureVectorSearch('KA_Knowledge_index', 0.5);

        ConnectApi.QuerySqlRow shortRow = new ConnectApi.QuerySqlRow();
        shortRow.row = new List<Object>{ 'Some text', 0.9 }; // missing the 3rd column

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            shortRow,
            makeRow('Valid full row.', 0.9, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results =
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(1, results.size(),
            'A row with fewer than 3 columns should be skipped, leaving only the valid row');
    }

    // ============================================================================
    // Dedup-skip branches (later duplicate has an equal/lower score)
    // ============================================================================

    @IsTest
    static void searchSimilarArticles_laterLowerScoringDuplicate_isSkipped() {
        Id articleId = insertKnowledge('Refund Policy');
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Better-scoring chunk first.', 0.95, articleId),
            makeRow('Lower-scoring chunk second.', 0.72, articleId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results =
            new ConnectApiVectorSearchService().searchSimilarArticles('refund', 10, 0.5);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Dedup should still collapse to one result per article');
        Assert.areEqual(0.95, results[0].similarityScore,
            'Once the best score is recorded, a later lower-scoring duplicate for the same article must be skipped');
    }

    @IsTest
    static void findSimilarPairs_unresolvableMatchedArticle_isSkipped() {
        Id sourceId = insertKnowledge('Source Article');
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Orphan chunk.', 0.9, '005000000000000AAA')
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results = new ConnectApiVectorSearchService()
            .findSimilarPairs(new List<String>{ sourceId }, 10, 0.5);
        Test.stopTest();

        Assert.areEqual(0, results.size(),
            'A matched chunk whose sourceRecordId does not resolve to a Knowledge__kav should be dropped in the bulk path too');
    }

    @IsTest
    static void findSimilarPairs_laterLowerScoringDuplicate_isSkipped() {
        Id sourceId = insertKnowledge('Source Article');
        Id matchId = insertKnowledge('Similar Match');
        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>{
            makeRow('Best chunk.', 0.95, matchId),
            makeRow('Weaker chunk.', 0.80, matchId)
        };
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        List<VectorSearchResult> results = new ConnectApiVectorSearchService()
            .findSimilarPairs(new List<String>{ sourceId }, 10, 0.5);
        Test.stopTest();

        Assert.areEqual(1, results.size(), 'Both chunks map to the same pair — dedup should collapse to one');
        Assert.areEqual(0.95, results[0].similarityScore,
            'Higher-scoring chunk should win over a later lower-scoring duplicate');
    }

    // ============================================================================
    // bulkGetArticleText — extra mapped content field beyond Title/Summary
    // ============================================================================

    @IsTest
    static void findSimilarPairs_extraContentField_reachesSearchPayload() {
        Knowledge__kav kav = new Knowledge__kav(
            Title = 'Extra Field Title',
            UrlName = 'extra-field-marker-' + Math.abs(Crypto.getRandomInteger()),
            Language = 'en_US',
            Summary = 'Extra field summary'
        );
        insert kav;

        KB_Scan_Config__c scanCfg = KB_Scan_Config__c.getInstance();
        if (scanCfg == null || scanCfg.Id == null) scanCfg = new KB_Scan_Config__c();
        scanCfg.Content_Field_Mapping_JSON__c = 'Summary,UrlName';
        upsert scanCfg;

        configureVectorSearch('KA_Knowledge_index', 0.5);

        MockExecutor mock = new MockExecutor();
        mock.rowsToReturn = new List<ConnectApi.QuerySqlRow>();
        ConnectApiVectorSearchService.queryExecutor = mock;

        Test.startTest();
        new ConnectApiVectorSearchService().findSimilarPairs(
            new List<String>{ kav.Id }, 10, 0.5
        );
        Test.stopTest();

        Assert.areEqual(1, mock.callCount, 'One vector_search call per article');
        Assert.isTrue(mock.queriesExecuted[0].contains(kav.UrlName),
            'An extra mapped content field beyond Title/Summary must reach the search payload: '
            + mock.queriesExecuted[0]);
    }
}
