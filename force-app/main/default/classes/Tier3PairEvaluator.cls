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
 * Shared per-pair evaluation logic for Tier 4 (the agentic "finals").
 *
 * Extracted so the two Tier 4 runtimes share ONE implementation:
 *   - Tier3AgenticQueueable — legacy single-lane chain (small runs / fallback).
 *   - Tier3AgenticBatch     — parallel sharded path (C); up to 5 shards run
 *     concurrently.
 *
 * evaluatePairs() compares a list of finalist pairs: extracts facts per article
 * (semantic-chunked, cached within the call), asks the LLM to compare, and
 * returns the flagged Duplicate_Candidate__c rows + the Knowledge_Pair_Evaluation__c
 * audit rows. Persistence, sharing, progress and callback handoff stay with the
 * callers (they differ per runtime). Pure compute + LLM here — no DML.
 *
 * Guards applied to every pair (must match across both runtimes — see/):
 *   - self-pair (same version id) → skip
 *   - already processed in-scope (composite key, A↔B == B↔A) → skip
 *   - already evaluated in a prior link (persisted Knowledge_Pair_Evaluation__c) → skip
 *   - either side not currently Online (Draft / Archived / superseded prior
 * version) → skip
 *   - blank body → skip
 *
 * LLM-call pacing budget: by default NOT enforced (the Batch path passes
 * maxCallouts null — its scopes are kept small by batchScopeSize instead). The
 * legacy queueable passes a budget so pairs that can't finish within the
 * per-transaction pace are deferred to a continuation instead of silently
 * dropped — see Result.remainingPairs / Result.budgetHit. The reserve-before-
 * start rule means a pair is never started unless it can finish, so no facts
 * are extracted for a pair the continuation has to re-extract. Note: despite
 * the "callout" name, the Einstein LLM call this paces does not actually count
 * toward Limits.getCallouts() (verified empirically) — the budget is a real,
 * useful pacing/cost control, just not a hard governor-limit guard.
 */
public with sharing class Tier3PairEvaluator {

 // the 'Overlap' anomaly type was removed. The pipeline now flags only
    // {Duplicate, Contradiction}; the old Overlap-specific confidence floor is
    // gone (all anomalies share the configured minConfidence). Breadth of
    // detection is governed by the Data Cloud similarity threshold, not a
    // per-type floor here.
    private static final String FLAG_DUPLICATE = 'Duplicate';
    private static final String FLAG_CONTRADICTION = 'Contradiction';

    /**
 * /— derive the persisted Flag_Type__c from the LLM ruling, as a
     * defence-in-depth backstop to the prompt contract:
 * CONTRADICTION PRECEDENCE: if the ruling names a contradiction it
     *    wins over Duplicate, so a pair that is both routes to human
     *    contradiction-resolution rather than auto-merge. (The prompt is also
     *    instructed to emit Contradiction in the "both" case; this guards a slip.)
 * OVERLAP REMOVAL: 'Overlap' is no longer a valid Flag_Type__c
     *    picklist value. If a stale prompt version still emits it, coerce to
     *    Duplicate (a former "near-twin overlap" is the duplicate-family outcome)
     *    rather than writing an invalid restricted-picklist value.
     */
    @TestVisible
    private static String resolveFlagType(PromptTemplateService.FactEvaluationResult evalResult) {
        String anomaly = evalResult != null ? evalResult.anomalyType : null;
        if (FLAG_CONTRADICTION.equalsIgnoreCase(anomaly)) {
            return FLAG_CONTRADICTION;
        }
        // Anything else that carries an anomaly (Duplicate, legacy Overlap, or a
        // blank anomalyType with isDuplicate=true) resolves to Duplicate.
        return FLAG_DUPLICATE;
    }

    /** Outcome of evaluating a batch of pairs. */
    public class Result {
        public List<Duplicate_Candidate__c> flaggedCandidates = new List<Duplicate_Candidate__c>();
        public List<Knowledge_Pair_Evaluation__c> evaluations = new List<Knowledge_Pair_Evaluation__c>();
        public Integer evaluatedPairs = 0;
        public Integer flaggedPairs = 0;
        public Integer clearPairs = 0;
        public Integer erroredPairs = 0;
        public Integer skippedPairs = 0;
 // budget path: pairs deferred because the per-transaction callout
        // budget could not finish them. Empty when maxCallouts is null.
        public List<Tier3AgenticQueueable.FinalistPair> remainingPairs =
            new List<Tier3AgenticQueueable.FinalistPair>();
        public Boolean budgetHit = false;
    }

    /**
     * Budget-unaware entry point (Batch path). Evaluates every eligible pair;
     * each Batch chunk has its own fresh 100-callout governor so no pacing is
     * needed here.
     */
    public static Result evaluatePairs(
        List<Tier3AgenticQueueable.FinalistPair> pairs,
        Id assessmentRunId,
        Id pipelineRunId
    ) {
        return evaluatePairs(pairs, assessmentRunId, pipelineRunId, null);
    }

    /**
     * Budget-aware entry point (legacy queueable path). `maxCallouts` caps the
     * callouts this call may spend; a pair whose full worst-case cost
     * (extraction for each uncached article + 1 comparison) would exceed the
     * remaining budget is deferred — it and every pair after it are returned in
     * Result.remainingPairs with Result.budgetHit = true, and NOTHING is
     * extracted for them (reserve-before-start → no wasted LLM cost on the
     * continuation). Pass null to disable budgeting.
     */
    public static Result evaluatePairs(
        List<Tier3AgenticQueueable.FinalistPair> pairs,
        Id assessmentRunId,
        Id pipelineRunId,
        Integer maxCallouts
    ) {
        Result r = new Result();
        if (pairs == null || pairs.isEmpty()) {
            return r;
        }

        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        PromptTemplateService promptService = PromptTemplateService.getInstance();
        Decimal minConfidence = config.Manual_Review_Threshold__c != null
            ? config.Manual_Review_Threshold__c : 50;
        Boolean budgeted = maxCallouts != null;
        Integer calloutCount = 0;

 // Load article bodies + publish status once.: PublishStatus is
        // required for the published-only gate below.
        Set<Id> allIds = new Set<Id>();
        for (Tier3AgenticQueueable.FinalistPair fp : pairs) {
            if (fp == null) continue;
            allIds.add(fp.targetId);
            allIds.add(fp.finalistId);
        }
        Map<Id, Knowledge__kav> articleMap = new Map<Id, Knowledge__kav>();
        for (Knowledge__kav art : [
            SELECT Id, Title, Summary, KnowledgeArticleId, PublishStatus
            FROM Knowledge__kav
            WHERE Id IN :allIds
        ]) {
            articleMap.put(art.Id, art);
        }

        // Skip pairs already evaluated in a prior chunk/link (persisted audit rows).
 // Keys are pipeline-run-scoped to match the stored KPE key.
        Set<String> allKeys = new Set<String>();
        for (Tier3AgenticQueueable.FinalistPair fp : pairs) {
            if (fp == null || fp.targetId == null || fp.finalistId == null
                || fp.targetId == fp.finalistId) continue;
            allKeys.add(KnowledgeAIGovernanceService.generatePipelineEvaluationKey(
                String.valueOf(fp.targetId), String.valueOf(fp.finalistId), pipelineRunId));
        }
        Set<String> cachedKeys = loadCachedEvaluationKeys(allKeys, pipelineRunId);

        Map<Id, String> factsCache = new Map<Id, String>();
 // budgeted path only. The reserve-before-start step chunks each
        // uncached body purely to .size() it for cost; caching those lists here
        // (keyed by version id) lets the extraction step reuse them instead of
        // re-running semanticChunk on the identical body. Null on the
        // non-budgeted (Batch) path — which has no reserve step — so extraction
        // there chunks on demand and discards per pair, exactly as before this
        // change (no chunk-list retention across the shard scope).
        Map<Id, List<String>> chunksCache = budgeted ? new Map<Id, List<String>>() : null;
        Set<String> processedKeys = new Set<String>();
        Map<String, Duplicate_Candidate__c> resultsByKey = new Map<String, Duplicate_Candidate__c>();

        for (Integer i = 0; i < pairs.size(); i++) {
            Tier3AgenticQueueable.FinalistPair fp = pairs[i];
            if (fp == null || fp.targetId == null || fp.finalistId == null) continue;
            if (fp.targetId == fp.finalistId) { r.skippedPairs++; continue; }

            // compositeKey stays run-agnostic: it dedupes within THIS batch
            // (processedKeys) and keys resultsByKey. The persisted-cache check
 // uses the pipeline-run-scoped key to match the stored KPE row.
            String compositeKey = KnowledgeAIGovernanceService.generateCompositeKey(
                String.valueOf(fp.targetId), String.valueOf(fp.finalistId));
            String cacheKey = KnowledgeAIGovernanceService.generatePipelineEvaluationKey(
                String.valueOf(fp.targetId), String.valueOf(fp.finalistId), pipelineRunId);
            if (processedKeys.contains(compositeKey) || cachedKeys.contains(cacheKey)) {
                r.skippedPairs++; continue;
            }

            Knowledge__kav targetArticle = articleMap.get(fp.targetId);
            Knowledge__kav finalistArticle = articleMap.get(fp.finalistId);

 // only compare CURRENT PUBLISHED articles. A Draft, an
            // Archived article, or a superseded prior version must never be
            // flagged as a duplicate. "Online" is the whole test: an article has
            // at most one Online version, so this also stops a prior version
            // being flagged as a duplicate of its own current version (same
            // KnowledgeArticleId, different KAV id — which the version-id
            // self-pair guard above misses). Uses KBPublishStatusHelper (shared
            // null-safe, case-insensitive classifier). This gate runs BEFORE the
            // budget reservation so a non-published pair is skipped, never
            // deferred to a continuation.
            if (targetArticle == null || finalistArticle == null
                || !KBPublishStatusHelper.isOnline(targetArticle.PublishStatus)
                || !KBPublishStatusHelper.isOnline(finalistArticle.PublishStatus)) {
                r.skippedPairs++; continue;
            }

            String targetBody = buildArticleBody(targetArticle);
            String finalistBody = buildArticleBody(finalistArticle);
            if (String.isBlank(targetBody) || String.isBlank(finalistBody)) {
                r.skippedPairs++; continue;
            }

 // reserve-before-start: compute the full worst-case cost of this
            // pair and defer it (and everything after) if it can't finish within
            // the remaining budget. Only applies when budgeted (queueable path).
            if (budgeted) {
 // Chunk each uncached body once and cache it — its.size
                // is the callout cost, and extraction below reuses the same list.
                Integer targetCost = 0;
                if (!factsCache.containsKey(fp.targetId)) {
                    List<String> targetChunks = chunkAndCache(fp.targetId, targetBody, chunksCache);
                    targetCost = targetChunks.size();
                }
                Integer finalistCost = 0;
                if (!factsCache.containsKey(fp.finalistId)) {
                    List<String> finalistChunks = chunkAndCache(fp.finalistId, finalistBody, chunksCache);
                    finalistCost = finalistChunks.size();
                }
                Integer pairCost = targetCost + finalistCost + 1; // +1 = comparison
                if (calloutCount + pairCost > maxCallouts) {
                    r.budgetHit = true;
                    for (Integer j = i; j < pairs.size(); j++) {
                        r.remainingPairs.add(pairs[j]);
                    }
                    break;
                }
            }
            processedKeys.add(compositeKey);

            try {
                String targetFacts = factsCache.get(fp.targetId);
                if (targetFacts == null) {
 // reuse the list the budgeted reserve step already
                    // computed; the non-budgeted path chunks on demand here.
                    List<String> chunks = chunkAndCache(fp.targetId, targetBody, chunksCache);
                    targetFacts = extractFacts(chunks, promptService);
                    calloutCount += chunks.size();
                    factsCache.put(fp.targetId, targetFacts);
                }
                String finalistFacts = factsCache.get(fp.finalistId);
                if (finalistFacts == null) {
                    List<String> chunks = chunkAndCache(fp.finalistId, finalistBody, chunksCache);
                    finalistFacts = extractFacts(chunks, promptService);
                    calloutCount += chunks.size();
                    factsCache.put(fp.finalistId, finalistFacts);
                }

                PromptTemplateService.FactEvaluationResult evalResult =
                    promptService.evaluateExtractedFacts(targetFacts, finalistFacts);
                calloutCount++;
                r.evaluatedPairs++;

                Boolean hasAnomaly = evalResult.isDuplicate == true
                    || String.isNotBlank(evalResult.anomalyType);
 // all anomaly types ({Duplicate, Contradiction}) share the
                // configured minConfidence; the Overlap-specific floor was removed.
                Boolean meetsThreshold = evalResult.confidenceScore != null
                    && evalResult.confidenceScore >= minConfidence;
                String evaluationStatus = (hasAnomaly && meetsThreshold) ? 'Flagged' : 'Clear';

                r.evaluations.add(new Knowledge_Pair_Evaluation__c(
 // Run-scoped: Composite_Version_Key__c is
                    // globally unique, so a bare pair key collides across runs and
                    // the DUPLICATE_VALUE rolls back the whole pair-eval upsert
                    // (candidates included). Prefix the pipeline run id — matches
                    // the run-scoped cache read below.
                    Composite_Version_Key__c =
                        KnowledgeAIGovernanceService.generatePipelineEvaluationKey(
                            String.valueOf(fp.targetId), String.valueOf(fp.finalistId), pipelineRunId),
                    Evaluation_Status__c = evaluationStatus,
                    Evaluated_Date__c = Datetime.now(),
                    Pipeline_Run__c = pipelineRunId,
                    Evaluation_Domain__c = KnowledgeAIGovernanceService.EVALUATION_DOMAIN_PIPELINE
                ));

                if (hasAnomaly && meetsThreshold) {
                    r.flaggedPairs++;
                    resultsByKey.put(compositeKey, new Duplicate_Candidate__c(
                        Knowledge_Article_1__c = fp.targetId,
                        Knowledge_Article_2__c = fp.finalistId,
                        Knowledge_Article_Id_1__c = String.valueOf(targetArticle.KnowledgeArticleId),
                        Knowledge_Article_Id_2__c = String.valueOf(finalistArticle.KnowledgeArticleId),
                        Assessment_Run__c = assessmentRunId,
                        Pipeline_Run__c = pipelineRunId,
                        // Run-scoped: the KPE cache above uses the run-agnostic
                        // compositeKey, but the candidate's unique key must embed
                        // the assessment run so concurrent runs over the same pair
                        // don't collide (INSUFFICIENT_ACCESS/DUPLICATE_VALUE).
                        Composite_Key__c = KnowledgeAIGovernanceService.generateCompositeKey(
                            String.valueOf(fp.targetId), String.valueOf(fp.finalistId), assessmentRunId),
                        Confidence_Score__c = evalResult.confidenceScore,
                        AI_Reasoning__c = evalResult.reasoning,
                        Flag_Type__c = resolveFlagType(evalResult),
                        Status__c = 'Pending',
                        Source_Tier__c = 'Tier4_Agentic',
                        Score_Calculated_Date__c = Datetime.now(),
                        Article_1_Title__c = targetArticle.Title,
                        Article_2_Title__c = finalistArticle.Title
                    ));
                } else {
                    r.clearPairs++;
                }
            } catch (Exception e) {
                r.erroredPairs++;
                System.debug(LoggingLevel.ERROR,
                    'Tier3PairEvaluator: failed for pair ' + fp.targetId + ' / '
                    + fp.finalistId + ': ' + e.getMessage());
            }
        }

        r.flaggedCandidates = resultsByKey.values();
        return r;
    }

 // compositeKeys are the pipeline-run-scoped KPE keys (
    // generatePipelineEvaluationKey), so the returned set matches the run-scoped
    // key the caller checks. The Pipeline_Run__c filter is now redundant (the key
    // encodes it) but kept as belt-and-braces / a selective index aid.
    public static Set<String> loadCachedEvaluationKeys(Set<String> compositeKeys, Id pipelineRunId) {
        Set<String> cached = new Set<String>();
        if (compositeKeys == null || compositeKeys.isEmpty() || pipelineRunId == null) {
            return cached;
        }
        for (Knowledge_Pair_Evaluation__c eval : [
            SELECT Composite_Version_Key__c
            FROM Knowledge_Pair_Evaluation__c
            WHERE Composite_Version_Key__c IN :compositeKeys
            AND Pipeline_Run__c = :pipelineRunId
            AND Evaluation_Domain__c = :KnowledgeAIGovernanceService.EVALUATION_DOMAIN_PIPELINE
        ]) {
            cached.add(eval.Composite_Version_Key__c);
        }
        return cached;
    }

    private static String extractFacts(List<String> chunks, PromptTemplateService promptService) {
        String allFacts = '';
        for (String chunk : chunks) {
            allFacts += promptService.extractArticleFacts(chunk) + '\n';
        }
        return allFacts;
    }

    public static String buildArticleBody(Knowledge__kav article) {
        if (article == null) return null;
        String body = '';
        if (String.isNotBlank(article.Title)) body += article.Title + '\n\n';
        if (String.isNotBlank(article.Summary)) body += article.Summary;
        return body.trim();
    }

    /**
 * memoised semanticChunk keyed by version id. When `chunksCache` is
     * non-null (budgeted path) it lets the reserve-before-start step and the
     * extraction step share one chunking of each uncached body instead of
     * computing it twice. A null cache (non-budgeted Batch path) chunks on demand
 * and retains nothing, matching the pre- per-pair behaviour.
     */
    private static List<String> chunkAndCache(
        Id articleId, String body, Map<Id, List<String>> chunksCache
    ) {
        if (chunksCache == null) {
            return semanticChunk(body);
        }
        List<String> chunks = chunksCache.get(articleId);
        if (chunks == null) {
            chunks = semanticChunk(body);
            chunksCache.put(articleId, chunks);
        }
        return chunks;
    }

 // invocation counter for semanticChunk. This is the ONLY signal that
    // distinguishes the pre-fix double-chunk (chunked once in the reserve step,
    // again in extraction) from the fixed single-chunk: extractFactsCallCount
    // can't, because extraction (and thus the LLM fact call) ran exactly once
    // per body on both. Bumped on every semanticChunk entry; asserted by the
    // budgeted-path test.
    @TestVisible
    private static Integer semanticChunkCallCount = 0;

    // Chunks the ENTIRE body — no cap on chunk count. A per-article chunk-count
    // ceiling (Max_Chunks_Per_Article__c, retired — see .claude/destructive/
    // tier3-max-chunks-per-article/) used to live here and silently dropped
    // every paragraph past it. It was sized as a defensive callout budget, but
    // the Einstein LLM call it guarded against does not count toward
    // Limits.getCallouts() (verified empirically), so the cap wasn't bounding
    // anything real, just truncating long articles. Cost and latency now scale
    // with actual article length, matching how the scoring dimensions already
    // treat body length — a presence gate, not a size ceiling.
    private static List<String> semanticChunk(String text) {
        semanticChunkCallCount++;
        List<String> chunks = new List<String>();
        if (String.isBlank(text)) return chunks;
        Integer maxChunkSize = KBRuntimeConfigService.getMaxChunkSize();
        List<String> paragraphs = text.split('\n\n');
        String currentChunk = '';
        for (String para : paragraphs) {
            if (currentChunk.length() + para.length() > maxChunkSize) {
                if (String.isNotBlank(currentChunk)) chunks.add(currentChunk.trim());
                currentChunk = para;
            } else {
                currentChunk += '\n\n' + para;
            }
        }
        if (String.isNotBlank(currentChunk)) {
            chunks.add(currentChunk.trim());
        }
        if (chunks.isEmpty() && String.isNotBlank(text)) {
            chunks.add(text.abbreviate(2000));
        }
        return chunks;
    }

    /**
 * Run-scoped upsert helper: keep one candidate per pair per run, and
     * finding #1 — never resurface a human-triaged (Rejected/Resolved/Suppressed)
     * candidate. A still-Pending row is reused in place (Id stamped); a triaged
     * row is dropped from the upsert so the human decision stands and we don't
     * collide with the unique Composite_Key__c by inserting a fresh row.
     *
     * Returns the rows that should actually be upserted (a subset of `results`).
     */
    public static List<Duplicate_Candidate__c> attachExistingIdsForRunScopedUpsert(
        List<Duplicate_Candidate__c> results, Id runId
    ) {
        Set<String> keys = new Set<String>();
        for (Duplicate_Candidate__c rec : results) {
            if (String.isNotBlank(rec.Composite_Key__c)) keys.add(rec.Composite_Key__c);
        }
        if (keys.isEmpty()) return results;

        // Composite_Key__c is unique and run-scoped → at most one existing row
        // per pair PER RUN. Within a rerun the key is stable so this finds the
        // prior row and reuses it in place; across different runs the keys differ
        // so nothing matches and each run inserts its own row (no cross-user
        // collision). Track Id + status to reuse a Pending row or protect a
        // triaged one.
        Map<String, Id> idByKey = new Map<String, Id>();
        Map<String, String> statusByKey = new Map<String, String>();
        for (Duplicate_Candidate__c existing : [
            SELECT Id, Composite_Key__c, Status__c FROM Duplicate_Candidate__c
            WHERE Composite_Key__c IN :keys
        ]) {
            idByKey.put(existing.Composite_Key__c, existing.Id);
            statusByKey.put(existing.Composite_Key__c, existing.Status__c);
        }

        List<Duplicate_Candidate__c> toUpsert = new List<Duplicate_Candidate__c>();
        for (Duplicate_Candidate__c rec : results) {
            String existingStatus = statusByKey.get(rec.Composite_Key__c);
 // statuses that a re-run must NOT overwrite. 'Not a Duplicate'
            // is deliberately absent: it is a SOFT / this-run-only discard, so on
            // the next assessment the pair is re-evaluated and the row is reused
            // in place (Id stamped below) — resetting it to the fresh Pending
            // result so a genuinely-still-duplicate pair re-surfaces. The legacy
            // permanent discards (Rejected / Suppressed) and the terminal
            // Resolved / Superseded remain protected.
            if (existingStatus != null && PRESERVED_STATUSES.contains(existingStatus)) {
                continue; // human-triaged / terminal — leave it untouched
            }
            if (idByKey.containsKey(rec.Composite_Key__c)) {
                rec.Id = idByKey.get(rec.Composite_Key__c);
            }
            toUpsert.add(rec);
        }
        return toUpsert;
    }

    /**
 * statuses a re-run leaves untouched. Everything else (Pending and the
     * soft 'Not a Duplicate') is overwritten with the fresh evaluation so the
     * pair can re-surface. 'Rejected' / 'Suppressed' are the LEGACY permanent
 * discards (retained for pre- rows); 'Resolved' / 'Superseded' are
     * terminal. Note 'Not a Duplicate' is intentionally NOT in this set.
     */
    @TestVisible
    private static final Set<String> PRESERVED_STATUSES = new Set<String>{
        'Rejected', 'Suppressed', 'Resolved', 'Superseded'
    };
}
