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
 * IVectorSearchService implementation using ConnectApi.CdpQuery.querySql (v62.0)
 * for Data Cloud vector search. Supports data spaces and pagination.
 *
 * Uses the vector_search() table function with a subquery JOIN pattern:
 *   SELECT c.Chunk__c, v.score__c, c.SourceRecordId__c
 *   FROM chunk_dmo c
 *   JOIN (
 *     SELECT SourceRecordId__c, score__c
 *     FROM vector_search(TABLE("index_dmo"), 'search text', '', topK)
 *   ) v ON c.RecordId__c = v.SourceRecordId__c
 *
 * Execution is async: submit → poll status server-side → paginate rows.
 * Server-side status waits don't consume Apex CPU or hold a DB connection.
 * Article metadata is resolved via follow-up SOQL on Knowledge__kav.
 */
public inherited sharing class ConnectApiVectorSearchService implements IVectorSearchService {

    private static final String DEFAULT_DATA_SPACE = 'default';
    private static final String PREFERRED_FALLBACK_INDEX = 'KA_Knowledge_index';

 // Agentforce Data Library (ADL) publish-status prefilter.
    //
    // An ADL ingests EVERY version of an article (Online, Draft, Archived), so
    // without a filter the dedup vector search surfaces prior/unpublished versions
    // of the same article as "duplicates". When the admin marks the configured
    // search index as an ADL (KB_Vector_Search_Config__c.Is_ADL__c = true) we AND
    // this expression into the vector_search() prefilter slot so only currently-
    // published content is searched.
    //
    // VERIFIED against a real Agentforce Data Library (org kb-quality-cleanup, 2026-06)
    // via live vector_search() probes — these are the confirmed column name and value,
    // not placeholders:
    //   • Column is `KnowledgePublicationStatus__c` — note Public*ation* (not Publish),
    //     and the `__c` suffix is REQUIRED (the bare `KnowledgePublicationStatus`
    //     fails with "unknown column").
    //   • The value is `Online` — the ADL's KnowledgePublicationStatus values are
    //     Online / Draft; there is no `Published` value.
    // Proof: vector_search(..., 'KnowledgePublicationStatus__c = ''Online''', 200)
    // returned 200 Online / 0 Draft, vs 148 Online / 52 Draft with no filter.
    // Kept @TestVisible for the lock-in test below and any future per-org override.
    @TestVisible
    private static String ADL_PUBLISH_STATUS_FIELD = 'KnowledgePublicationStatus__c';
    @TestVisible
    private static String ADL_PUBLISH_STATUS_VALUE = 'Online';

    // Server-side poll window. Data Cloud blocks up to this long before responding,
    // which avoids burning Apex CPU in a client-side sleep loop.
    private static final Integer STATUS_WAIT_MS = 10000;
    private static final Long PAGE_SIZE = 10000;

    // EXPERIMENT (consumption tagging): pass a workloadName to the Data Cloud
    // querySql call so this app's queries can be isolated in the Digital Wallet /
    // consumption reporting (Salesforce Support-facing tag). The submit-only
    // querySql(input, workloadName, dataspace) overload accepts it; querySqlRows
    // /querySqlStatus have no such parameter. Safe to remove if it doesn't move
    // the needle in the wallet.
    @TestVisible
    private static String DATA_CLOUD_WORKLOAD_NAME = 'KB_Readiness_Assessment';

    // Column positions in the SELECT: Chunk__c=0, score__c=1, SourceRecordId__c=2
    private static final Integer COL_CHUNK = 0;
    private static final Integer COL_SCORE = 1;
    private static final Integer COL_SOURCE_ID = 2;

    // Test seam. Tests inject a mock that returns canned rows or throws, so the
    // ConnectApi.CdpQuery.querySql call path is exercised without needing a live
    // Data Cloud index or SeeAllData=true. Production uses the real delegate.
    public interface IDataCloudQueryExecutor {
        List<ConnectApi.QuerySqlRow> executeQueryAndGetRows(String sqlQuery, String dataSpace);
    }

    @TestVisible
    private static IDataCloudQueryExecutor queryExecutor;

    private static IDataCloudQueryExecutor getExecutor() {
        if (queryExecutor == null) {
            queryExecutor = new RealDataCloudQueryExecutor();
        }
        return queryExecutor;
    }

    public List<VectorSearchResult> searchSimilarArticles(
        String queryText,
        Integer maxResults,
        Decimal similarityThreshold
    ) {
        VectorSearchFactory.ActiveVectorConfig config = VectorSearchFactory.getActiveConfig();

        List<ChunkResult> chunks = executeChunkQueryWithFallback(config, queryText, null, maxResults);
        return enrichWithKnowledgeData(filterByThreshold(chunks, similarityThreshold), null);
    }

    public List<VectorSearchResult> findSimilarPairs(
        List<String> articleVersionIds,
        Integer maxResults,
        Decimal similarityThreshold
    ) {
        VectorSearchFactory.ActiveVectorConfig config = VectorSearchFactory.getActiveConfig();
        Map<String, String> articleTextMap = bulkGetArticleText(articleVersionIds);
        List<ChunkResult> allChunks = new List<ChunkResult>();

        for (String sourceVersionId : articleVersionIds) {
            String articleText = articleTextMap.get(sourceVersionId);
            if (String.isBlank(articleText)) {
                continue;
            }

            List<ChunkResult> chunks = executeChunkQueryWithFallback(
                config, articleText, sourceVersionId, maxResults
            );
            List<ChunkResult> filtered = filterByThreshold(chunks, similarityThreshold);

            for (ChunkResult cr : filtered) {
                cr.pairedSourceVersionId = sourceVersionId;
            }
            allChunks.addAll(filtered);
        }

        return bulkEnrichWithKnowledgeData(allChunks);
    }

    private String buildVectorQuery(
        VectorTableNames tableNames,
        String queryText,
        String excludeArticleVersionId,
        Integer maxResults
    ) {
        return buildVectorQuery(tableNames, queryText, excludeArticleVersionId, maxResults, true);
    }

    private String buildVectorQuery(
        VectorTableNames tableNames,
        String queryText,
        String excludeArticleVersionId,
        Integer maxResults,
        Boolean includeAdlFilter
    ) {
        String escapedText = queryText.replace('\'', '\'\'');

        // The 3rd argument to vector_search() is its own filter expression. It is
        // used for two things, AND-combined:
        //   1. Excluding the source article from its own results during pair search.
 // 2. Restricting an Agentforce Data Library to currently-published
        //      content — an ADL ingests all article versions, so without this an
        //      article's own prior/Draft/Archived versions surface as duplicates.
        // It is NOT the wizard's "Query Prefilters" (KB_Setup_Wizard_State__c.Query_Prefilters_JSON__c):
        // those are SOQL article-selection filters that never flowed into vector_search().
 // Scoping dedup search to the selected articles is tracked by.
        String prefilter = buildPrefilter(excludeArticleVersionId, includeAdlFilter);

        return 'SELECT c.Chunk__c, v.score__c, c.SourceRecordId__c '
            + 'FROM ' + tableNames.chunkDmo + ' c '
            + 'JOIN ( '
            + '  SELECT SourceRecordId__c, score__c '
            + '  FROM vector_search(TABLE("' + tableNames.indexDmo + '"), '
            + '\'' + escapedText + '\', '
            + '\'' + prefilter + '\', '
            + maxResults
            + ') '
            + ') v ON c.RecordId__c = v.SourceRecordId__c '
            + 'ORDER BY v.score__c DESC';
    }

    /**
     * Builds the vector_search() prefilter expression: the per-pair self-exclusion
 * (when supplied) AND, for an ADL-backed index, a publish-status clause
     * so only currently-published content is searched.
     *
     * The whole expression is embedded inside single quotes in the outer SQL, so
     * inner string literals use doubled single quotes (e.g. ''Online''), matching
     * the existing self-exclusion escaping.
     */
    @TestVisible
    private String buildPrefilter(String excludeArticleVersionId) {
        return buildPrefilter(excludeArticleVersionId, true);
    }

    /**
     * @param includeAdlFilter When false, the ADL publish-status clause is omitted
     *        even for an ADL-flagged index. Used by the degraded retry in
     *        executeChunkQueryWithFallback when the publish-status column turns out
     *        not to exist on the index (admin mis-ticked Is_ADL__c). The self-exclusion
     *        clause is unaffected by this flag.
     */
    @TestVisible
    private String buildPrefilter(String excludeArticleVersionId, Boolean includeAdlFilter) {
        List<String> clauses = new List<String>();

        if (String.isNotBlank(excludeArticleVersionId)) {
            clauses.add('SourceRecordId__c != \'\'' + String.escapeSingleQuotes(excludeArticleVersionId) + '\'\'');
        }

        if (includeAdlFilter && isAdlIndex()) {
            clauses.add(ADL_PUBLISH_STATUS_FIELD + ' = \'\'' + ADL_PUBLISH_STATUS_VALUE + '\'\'');
        }

        return String.join(clauses, ' AND ');
    }

    /**
     * True when the admin has flagged the configured search index as an Agentforce
     * Data Library (KB_Vector_Search_Config__c.Is_ADL__c). Read directly from the
     * custom setting here rather than via VectorSearchFactory.ActiveVectorConfig so
     * the ADL signal is self-contained to this implementation.
     */
    @TestVisible
    private Boolean isAdlIndex() {
        KB_Vector_Search_Config__c cs = KB_Vector_Search_Config__c.getInstance();
        return cs != null && cs.Is_ADL__c == true;
    }

    private List<ChunkResult> executeChunkQuery(VectorSearchFactory.ActiveVectorConfig config, String query) {
        String dataSpace = String.isNotBlank(config.dataSpaceName)
            ? config.dataSpaceName
            : DEFAULT_DATA_SPACE;

        try {
            List<ConnectApi.QuerySqlRow> rows = getExecutor().executeQueryAndGetRows(query, dataSpace);
            return parseChunkRows(rows);
        } catch (ConnectApi.ConnectApiException e) {
            throw new KnowledgeAIException('Data Cloud query failed: ' + e.getMessage());
        }
    }

    @TestVisible
    private class RealDataCloudQueryExecutor implements IDataCloudQueryExecutor {
        public List<ConnectApi.QuerySqlRow> executeQueryAndGetRows(String sqlQuery, String dataSpace) {
            ConnectApi.QuerySqlInput input = new ConnectApi.QuerySqlInput();
            input.sql = sqlQuery;

            ConnectApi.QuerySqlOutput output = ConnectApi.CdpQuery.querySql(
                input, DATA_CLOUD_WORKLOAD_NAME, dataSpace);
            ConnectApi.QuerySqlStatus status = output.status;

            List<ConnectApi.QuerySqlRow> rows = output.dataRows != null
                ? new List<ConnectApi.QuerySqlRow>(output.dataRows)
                : new List<ConnectApi.QuerySqlRow>();

            // Drain remaining rows once produced. Server-side wait avoids client-side CPU burn.
            while (!isTerminal(status) || status.rowCount > rows.size()) {
                if (status.rowCount > rows.size()) {
                    ConnectApi.QuerySqlPageOutput page = ConnectApi.CdpQuery.querySqlRows(
                        status.queryId, (Long) rows.size(), PAGE_SIZE, dataSpace
                    );
                    if (page.dataRows != null && !page.dataRows.isEmpty()) {
                        rows.addAll(page.dataRows);
                        continue;
                    }
                }
                if (isTerminal(status)) {
                    break;
                }
                status = ConnectApi.CdpQuery.querySqlStatus(status.queryId, dataSpace, STATUS_WAIT_MS);
            }

            return rows;
        }

        private Boolean isTerminal(ConnectApi.QuerySqlStatus status) {
            return status != null
                && status.completionStatus != null
                && (status.completionStatus == ConnectApi.QuerySqlStatusEnum.FINISHED
                    || status.completionStatus == ConnectApi.QuerySqlStatusEnum.RESULTSPRODUCED);
        }
    }

    private List<ChunkResult> executeChunkQueryWithFallback(
        VectorSearchFactory.ActiveVectorConfig config,
        String queryText,
        String excludeArticleVersionId,
        Integer maxResults
    ) {
        List<VectorTableNames> tableCandidates = resolveTableCandidates(config.searchIndexName);
        Exception lastError;

        for (VectorTableNames tableNames : tableCandidates) {
            String query = buildVectorQuery(tableNames, queryText, excludeArticleVersionId, maxResults);
            try {
                return executeChunkQuery(config, query);
            } catch (Exception e) {
                lastError = e;
                String msg = String.valueOf(e.getMessage());
 // hardening — the index was flagged Is_ADL__c=true but the ADL
                // publish-status column doesn't exist on it (admin mis-ticked the box
                // on a custom index). Rather than fail the whole dedup search, retry
                // this same table WITHOUT the ADL clause (self-exclusion kept) so the
                // search degrades to unfiltered instead of breaking. The WARN leaves a
                // breadcrumb pointing at the mis-configuration. Checked BEFORE the
                // table-name retry below: this condition is strictly narrower (it must
                // name the publish-status field) and a Data-Cloud "unknown column" error
                // can carry the same NOT_FOUND token a missing-table error does — so a
                // mis-ticked ADL must degrade here, not get misrouted to table-retry.
                if (isAdlPublishStatusUnknownError(msg)) {
                    System.debug(
                        LoggingLevel.WARN,
                        'KB index "' + config.searchIndexName + '" is flagged as an ADL '
                        + '(Is_ADL__c=true) but the publish-status field "' + ADL_PUBLISH_STATUS_FIELD
                        + '" was not found on it. Retrying dedup vector search WITHOUT the publish-status '
                        + 'filter — results will be unfiltered (may include unpublished versions). '
                        + 'Verify Is_ADL__c / the ADL data model. Underlying error: ' + msg
                    );
                    String degradedQuery = buildVectorQuery(
                        tableNames, queryText, excludeArticleVersionId, maxResults, false
                    );
                    return executeChunkQuery(config, degradedQuery);
                }
                // If the table name is missing, try next naming variant.
                if (msg.contains('NOT_FOUND') || msg.contains('DataModelEntity')) {
                    continue;
                }
                throw e;
            }
        }

        if (lastError != null) {
            throw new KnowledgeAIException(
                'Data Cloud query failed for search index "' + config.searchIndexName
                + '". Verify index/chunk DMO names in Setup Wizard Step 6. Last error: '
                + lastError.getMessage()
            );
        }
        throw new KnowledgeAIException('Data Cloud query failed: no valid index table candidates were generated.');
    }

    /**
     * True only when the error looks like the ADL publish-status column being
     * unknown/invalid on the index — i.e. the admin ticked Is_ADL__c on an index
     * that has no such field. Deliberately narrow: requires BOTH that the message
     * references the configured publish-status field name AND that it reads like a
     * missing/invalid column error. This keeps the degrade from swallowing a genuine
     * ADL filter error on a real ADL (which would not name the publish-status field
     * as unknown). Returns false unless the index is actually flagged as an ADL.
     */
    @TestVisible
    private Boolean isAdlPublishStatusUnknownError(String rawMessage) {
        if (!isAdlIndex() || String.isBlank(rawMessage)) {
            return false;
        }
        String msg = rawMessage.toLowerCase();
        Boolean namesPublishStatusField = msg.contains(ADL_PUBLISH_STATUS_FIELD.toLowerCase());
        Boolean looksLikeUnknownColumn = msg.contains('column')
            || msg.contains('field')
            || msg.contains('invalid_field')
            || msg.contains('not found')
            || msg.contains('unknown')
            || msg.contains('does not exist')
            || msg.contains('no such');
        return namesPublishStatusField && looksLikeUnknownColumn;
    }

    private List<VectorTableNames> resolveTableCandidates(String configuredSearchIndexName) {
        List<VectorTableNames> candidates = new List<VectorTableNames>();
        Set<String> seenIndexDmos = new Set<String>();

        String raw = configuredSearchIndexName != null ? configuredSearchIndexName.trim() : '';
        if (String.isBlank(raw)) {
            return candidates;
        }

        String base = raw.endsWith('__dlm') ? raw.substring(0, raw.length() - 5) : raw;
        List<String> indexBaseCandidates = new List<String>{ base };

        if (base.endsWith('_chunk')) {
            indexBaseCandidates.add(base.replace('_chunk', '_index'));
        } else if (!base.endsWith('_index')) {
            indexBaseCandidates.add(base + '_index');
        }

        for (String baseCandidate : indexBaseCandidates) {
            if (String.isBlank(baseCandidate)) {
                continue;
            }
            String indexBase = baseCandidate;
            String chunkBase;
            if (indexBase.endsWith('_index')) {
                chunkBase = indexBase.replace('_index', '_chunk');
            } else if (indexBase.endsWith('_chunk')) {
                chunkBase = indexBase;
                indexBase = indexBase.replace('_chunk', '_index');
            } else {
                chunkBase = indexBase + '_chunk';
            }

            String indexDmo = indexBase + '__dlm';
            if (seenIndexDmos.contains(indexDmo)) {
                continue;
            }
            seenIndexDmos.add(indexDmo);
            candidates.add(new VectorTableNames(indexDmo, chunkBase + '__dlm'));
        }

        // Always include the known-good project default as final fallback.
        addCandidateIfNew(candidates, seenIndexDmos, PREFERRED_FALLBACK_INDEX);

        return candidates;
    }

    private void addCandidateIfNew(
        List<VectorTableNames> candidates,
        Set<String> seenIndexDmos,
        String indexBase
    ) {
        if (String.isBlank(indexBase)) {
            return;
        }
        String normalizedIndexBase = indexBase.endsWith('__dlm')
            ? indexBase.substring(0, indexBase.length() - 5)
            : indexBase;
        String chunkBase = normalizedIndexBase.endsWith('_index')
            ? normalizedIndexBase.replace('_index', '_chunk')
            : normalizedIndexBase + '_chunk';
        String indexDmo = normalizedIndexBase + '__dlm';
        if (seenIndexDmos.contains(indexDmo)) {
            return;
        }
        seenIndexDmos.add(indexDmo);
        candidates.add(new VectorTableNames(indexDmo, chunkBase + '__dlm'));
    }

    private List<ChunkResult> parseChunkRows(List<ConnectApi.QuerySqlRow> rows) {
        List<ChunkResult> chunks = new List<ChunkResult>();
        if (rows == null) {
            return chunks;
        }

        for (ConnectApi.QuerySqlRow row : rows) {
            List<Object> cols = row != null ? row.row : null;
            if (cols == null || cols.size() < 3) {
                continue;
            }

            ChunkResult cr = new ChunkResult();
            cr.chunkText = cols[COL_CHUNK] != null ? String.valueOf(cols[COL_CHUNK]) : null;
            cr.sourceRecordId = cols[COL_SOURCE_ID] != null ? String.valueOf(cols[COL_SOURCE_ID]) : null;
            if (cols[COL_SCORE] != null) {
                cr.similarityScore = Decimal.valueOf(String.valueOf(cols[COL_SCORE]));
            }
            chunks.add(cr);
        }

        return chunks;
    }

    private List<ChunkResult> filterByThreshold(List<ChunkResult> chunks, Decimal threshold) {
        List<ChunkResult> filtered = new List<ChunkResult>();
        for (ChunkResult cr : chunks) {
            if (cr.similarityScore != null && cr.similarityScore >= threshold) {
                filtered.add(cr);
            }
        }
        return filtered;
    }

    private List<VectorSearchResult> enrichWithKnowledgeData(
        List<ChunkResult> chunks,
        String pairedArticleVersionId
    ) {
        if (chunks.isEmpty()) {
            return new List<VectorSearchResult>();
        }

        Set<String> sourceIds = new Set<String>();
        for (ChunkResult cr : chunks) {
            if (String.isNotBlank(cr.sourceRecordId)) {
                sourceIds.add(cr.sourceRecordId);
            }
        }

        Map<String, Knowledge__kav> articleMap = new Map<String, Knowledge__kav>();
        for (Knowledge__kav art : [
            SELECT Id, Title, ArticleNumber
            FROM Knowledge__kav
            WHERE Id IN :sourceIds
        ]) {
            articleMap.put(art.Id, art);
        }

        Map<String, VectorSearchResult> deduped = new Map<String, VectorSearchResult>();
        for (ChunkResult cr : chunks) {
            Knowledge__kav article = articleMap.get(cr.sourceRecordId);
            if (article == null) {
                continue;
            }

            String versionId = article.Id;
            if (deduped.containsKey(versionId)
                && deduped.get(versionId).similarityScore >= cr.similarityScore) {
                continue;
            }

            VectorSearchResult r = new VectorSearchResult();
            r.articleVersionId = versionId;
            r.articleTitle = article.Title;
            r.articleNumber = article.ArticleNumber;
            r.matchedChunkText = cr.chunkText;
            r.similarityScore = cr.similarityScore;
            r.pairedArticleVersionId = pairedArticleVersionId;
            deduped.put(versionId, r);
        }

        return deduped.values();
    }

    private List<VectorSearchResult> bulkEnrichWithKnowledgeData(List<ChunkResult> allChunks) {
        if (allChunks.isEmpty()) {
            return new List<VectorSearchResult>();
        }

        Set<String> allSourceIds = new Set<String>();
        for (ChunkResult cr : allChunks) {
            if (String.isNotBlank(cr.sourceRecordId)) {
                allSourceIds.add(cr.sourceRecordId);
            }
        }

        Map<String, Knowledge__kav> articleMap = new Map<String, Knowledge__kav>();
        for (Knowledge__kav art : [
            SELECT Id, Title, ArticleNumber
            FROM Knowledge__kav
            WHERE Id IN :allSourceIds
        ]) {
            articleMap.put(art.Id, art);
        }

        Map<String, VectorSearchResult> deduped = new Map<String, VectorSearchResult>();
        for (ChunkResult cr : allChunks) {
            Knowledge__kav article = articleMap.get(cr.sourceRecordId);
            if (article == null) {
                continue;
            }

            String versionId = article.Id;
            String dedupKey = cr.pairedSourceVersionId + '_' + versionId;
            if (deduped.containsKey(dedupKey)
                && deduped.get(dedupKey).similarityScore >= cr.similarityScore) {
                continue;
            }

            VectorSearchResult r = new VectorSearchResult();
            r.articleVersionId = versionId;
            r.articleTitle = article.Title;
            r.articleNumber = article.ArticleNumber;
            r.matchedChunkText = cr.chunkText;
            r.similarityScore = cr.similarityScore;
            r.pairedArticleVersionId = cr.pairedSourceVersionId;
            deduped.put(dedupKey, r);
        }

        return deduped.values();
    }

    private Map<String, String> bulkGetArticleText(List<String> articleVersionIds) {
        Map<String, String> textMap = new Map<String, String>();
        Set<String> idSet = new Set<String>(articleVersionIds);

        // Reuse admin-configured body fields (same source as the assessment scorer)
        // so Tier 2 search picks up content-level duplicates with different titles.
        List<String> bodyFields = KBAssessmentService.getContentFields('Knowledge__kav');
        Set<String> selectedFields = new Set<String>{ 'Id', 'Title', 'Summary' };
        for (String f : bodyFields) {
            if (String.isNotBlank(f)) selectedFields.add(f);
        }

        String soql = 'SELECT ' + String.join(new List<String>(selectedFields), ', ')
                    + ' FROM Knowledge__kav WHERE Id IN :idSet';

        // System mode (default) on purpose: selectedFields includes the
        // admin-mapped Knowledge content fields (FLS is the customer's to grant)
        // so Tier 2 vector dedup compares real body text. USER_MODE would throw
        // on those fields for a Knowledge-read-only persona and break dedup.
        // Dedup must compare against every candidate, not just one user's
        // data-category-visible slice; this runs from a queueable in system
        // context so the read isn't narrowed to a running user's categories.
        for (Knowledge__kav art : (List<Knowledge__kav>) Database.query(soql)) {
            List<String> parts = new List<String>();
            if (String.isNotBlank(art.Title)) parts.add(art.Title);
            if (String.isNotBlank(art.Summary)) parts.add(art.Summary);
            for (String f : bodyFields) {
                if (f.equalsIgnoreCase('Title') || f.equalsIgnoreCase('Summary')) continue;
                Object v = art.get(f);
                if (v != null && String.isNotBlank(String.valueOf(v))) {
                    parts.add(String.valueOf(v));
                }
            }
            textMap.put(art.Id, String.join(parts, ' ').trim());
        }
        return textMap;
    }

    private class ChunkResult {
        String sourceRecordId;
        String chunkText;
        Decimal similarityScore;
        String pairedSourceVersionId;
    }

    private class VectorTableNames {
        String indexDmo;
        String chunkDmo;

        VectorTableNames(String indexDmo, String chunkDmo) {
            this.indexDmo = indexDmo;
            this.chunkDmo = chunkDmo;
        }
    }
}
