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
 * Tier 3: Batch Apex scoring for large runs (>50 articles).
 *
 * Each execute() chunk:
 *   - Receives up to scopeSize article parents (KB_Article_Assessment__c).
 *   - Scores all selected dimensions for every article in the chunk.
 *   - Writes KB_Dimension_Result__c child rows (upsert).
 *   - Updates each parent's Overall_Score__c / Readiness_Status__c.
 *
 * finish() enqueues KBAssessmentPipelineCallback for run-level finalization.
 *
 * scopeSize is tuned to the LLM callout budget. Each execute() gets its own
 * 100-callout governor.
 *
 * PARALLEL SHARDING: chunks WITHIN one batch job run sequentially (not in
 * parallel — the org's 5-concurrent limit is across DISTINCT jobs). So large
 * runs are split into up to 5 shards by KBAssessmentService.dispatchBatch, each
 * a separate KBAssessmentBatch over its own article slice; those 5 jobs run
 * concurrently. A shard scores only its `shardArticleIds` (when provided);
 * finish() decrements the run's Scoring_Shards_Outstanding__c join barrier and
 * only the last shard to finish dispatches pipeline finalization. When
 * shardArticleIds is null the class behaves as the legacy single-batch path.
 *
 * Unlike queueable chaining there is no stack-depth concern — Batch Apex
 * handles arbitrary sizes natively.
 */
public with sharing class KBAssessmentBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {

    private Id runId;
    private Set<String> selectedDimensions;
    // Governor-informed chunk size. Callers can override but the router
    // picks a safe default based on per-article callout totals.
    public Integer scopeSize;
    // When non-null, this shard scores ONLY these article ids (parallel path).
    // Null = legacy single-batch over the whole run.
    private List<String> shardArticleIds;
    // True when this batch is one of several parallel shards — gates the
    // join-barrier handoff in finish().
    private Boolean isShard = false;
    // 1-based shard identity, stamped on each progress event as Current_Batch__c
    // so the runner LWC can sum shard-local counts into a whole-run total instead
 // of letting each shard's count clobber the others'.
    private Integer shardIndex = 1;
    // The run's dispatch generation captured in start(). Each execute() chunk
    // re-reads the run's current generation and bails before writing if it no
    // longer matches: a straggler shard from an aborted prior wave (abortJob lets
    // an in-flight chunk drain) declines to write instead of colliding
    // (UNABLE_TO_LOCK_ROW) with the new wave over the same KB_Article_Assessment__c
    // rows. Null = not captured (e.g. a test that drives execute() directly
    // without start()) — the gate is skipped so existing behaviour is unchanged.
    // Survives across chunks via Database.Stateful (declared on the class).
    @TestVisible
    private Decimal dispatchGeneration;

 // cumulative progress counters. Database.Stateful is already
    // declared above so these survive across execute() chunks. We publish a
    // KB_Assessment_Progress__e per chunk with cumulativeProcessed /
    // totalScope so the runner LWC's progress bar advances smoothly instead
    // of sitting on the 'Queued' event for the duration of the run.
    @TestVisible
    private Integer cumulativeProcessed = 0;
    @TestVisible
    private Integer totalScope = 0;

    public KBAssessmentBatch(Id runId, Set<String> selectedDimensions) {
        this.runId = runId;
        this.selectedDimensions = (selectedDimensions == null || selectedDimensions.isEmpty())
            ? DimensionRegistry.getActiveDeveloperNames()
            : new Set<String>(selectedDimensions);
        this.scopeSize = computeScopeSize();
    }

    // Parallel-shard constructor: scores only `shardArticleIds`. finish() routes
    // through the Scoring_Shards_Outstanding__c join barrier. Defaults the shard
    // index to 1 (single-shard callers / tests).
    public KBAssessmentBatch(Id runId, Set<String> selectedDimensions, List<String> shardArticleIds) {
        this(runId, selectedDimensions, shardArticleIds, 1);
    }

    // Parallel-shard constructor with an explicit 1-based shard index. The index
    // is stamped on progress events (Current_Batch__c) so the runner LWC keeps a
    // per-shard count map and sums the latest-per-shard reading — concurrent
 // shards no longer clobber one another's Articles_Processed__c.
    public KBAssessmentBatch(Id runId, Set<String> selectedDimensions, List<String> shardArticleIds, Integer shardIndex) {
        this(runId, selectedDimensions);
        this.shardArticleIds = shardArticleIds;
        this.isShard = true;
        this.shardIndex = (shardIndex == null || shardIndex < 1) ? 1 : shardIndex;
    }

    public Integer getScopeSize() {
        return this.scopeSize;
    }

    // Tuning constants for computeScopeSize. Extracted so future tuning is a
    // one-line edit. secondsPerCallout is conservative (Storm/sandbox); production
    // averages 2–3s but we size for the slow case to avoid timeouts.
    private static final Integer DETERMINISTIC_SCOPE_SIZE = 100;
    private static final Integer MIN_SCOPE_SIZE = 5;
    private static final Integer CALLOUT_GOVERNOR = 90; // 100 - headroom
    private static final Integer WALL_CLOCK_BUDGET_SECONDS = 480;
    private static final Integer SECONDS_PER_CALLOUT = 10;

    private Integer computeScopeSize() {
        Integer calloutsPerArticle = 0;
        for (String dim : this.selectedDimensions) {
            DimensionRegistry.DimensionDefinition def = DimensionRegistry.get(dim);
            if (def == null || !def.requiresLLM) continue;
            calloutsPerArticle += def.calloutsPerArticle;
        }
        if (calloutsPerArticle == 0) return DETERMINISTIC_SCOPE_SIZE;

        Integer calloutCap = CALLOUT_GOVERNOR / calloutsPerArticle;
        Integer wallClockCap = WALL_CLOCK_BUDGET_SECONDS / (calloutsPerArticle * SECONDS_PER_CALLOUT);
        return Math.max(MIN_SCOPE_SIZE, Math.min(calloutCap, wallClockCap));
    }

    public Iterable<SObject> start(Database.BatchableContext bc) {
 // Cancel gate: if the run was cancelled before this
        // batch reached start(), return an empty locator so no chunks dispatch.
        // Locator filter on a never-matched id keeps this allocation-cheap.
        if (KBAssessmentService.isCancelled(this.runId)) {
            return Database.getQueryLocator([
                SELECT Id FROM KB_Article_Assessment__c WHERE Id = null
            ]);
        }
 // source totalScope from KB_Assessment_Run__c.Total_Articles__c,
        // which KBAssessmentService stamps at run creation time. Avoids an
        // extra COUNT() over KB_Article_Assessment__c and keeps the value
        // consistent with what the LWC's `Total_Articles__c` payload field
        // would otherwise see. Falls back to a COUNT() if the row was
        // created before that field was populated.
        try {
            KB_Assessment_Run__c run = [
                SELECT Total_Articles__c, Dispatch_Generation__c FROM KB_Assessment_Run__c
                WHERE Id = :this.runId LIMIT 1
            ];
            if (run.Total_Articles__c != null) {
                this.totalScope = run.Total_Articles__c.intValue();
            }
            // Capture the generation this wave was dispatched at, so execute()
            // can detect a rerun that started a newer wave and bail. Coalesce a
            // null DB value (brand-new run, never reran) to 0 so that once
            // start() has run the captured value is ALWAYS non-null: the null
            // sentinel then unambiguously means "start() never ran" (the
            // direct-execute() test path), which the gate treats as skip. A rerun
            // bumps the run to 1, so a straggler that captured 0 correctly sees
            // 1 > 0 and bails.
            this.dispatchGeneration = run.Dispatch_Generation__c != null
                ? run.Dispatch_Generation__c : 0;
        } catch (Exception ignored) { /* non-fatal */ }
        if (this.totalScope == null || this.totalScope == 0) {
            this.totalScope = [
                SELECT COUNT() FROM KB_Article_Assessment__c
                WHERE Assessment_Run__c = :this.runId
            ];
        }
        // Parallel shards: totalScope stays as the run-level Total_Articles__c
        // so each shard's progress events report "X of 402" not "X of 100".
        // cumulativeProcessed is shard-LOCAL; each shard also stamps its 1-based
        // shardIndex (as Current_Batch__c) so the runner LWC keeps a per-shard
        // count map and sums the latest-per-shard reading into the whole-run
        // total. Concurrent shards therefore accumulate rather than clobber one
 // another's counts.
        // Iterate the parent assessment rows — they were pre-created by
        // KBAssessmentService.runAssessment before dispatching this batch.
        // Parallel shard: scope to just this shard's article ids. (Bind the
        // list to a local var so the locator's WHERE can reference it.)
        if (this.isShard && this.shardArticleIds != null) {
            List<String> shardIds = this.shardArticleIds;
            return Database.getQueryLocator([
                SELECT Id, Knowledge__c, Article_Title__c
                FROM KB_Article_Assessment__c
                WHERE Assessment_Run__c = :this.runId
                  AND Knowledge__c IN :shardIds
                ORDER BY Id ASC
            ]);
        }
        return Database.getQueryLocator([
            SELECT Id, Knowledge__c, Article_Title__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :this.runId
            ORDER BY Id ASC
        ]);
    }

    public void execute(Database.BatchableContext bc, List<KB_Article_Assessment__c> scope) {
        if (scope == null || scope.isEmpty()) return;
 // Per-chunk cancel gate. The start gate prevents new
        // chunks from dispatching but chunks already in flight at cancel time
        // need to short-circuit too.
        if (KBAssessmentService.isCancelled(this.runId)) return;
        // Per-chunk generation gate. abortJob lets an in-flight chunk drain to
        // completion; if the run was re-dispatched (rerun) since this wave
        // launched, a newer wave now owns the same KB_Article_Assessment__c rows.
        // This straggler declines to write rather than collide with it
        // (UNABLE_TO_LOCK_ROW). Checked before any scoring/DML so the drained
        // chunk costs nothing further. The cancel gate above covers the
        // cancelled-and-not-yet-reran case; this covers the reran case (where
        // status is back to 'In Progress' so isCancelled is false).
        if (isSupersededByNewerWave()) return;

        List<String> articleIds = new List<String>();
        Map<String, Id> parentIdByArticle = new Map<String, Id>();
        for (KB_Article_Assessment__c a : scope) {
            articleIds.add(a.Knowledge__c);
            parentIdByArticle.put(a.Knowledge__c, a.Id);
        }

        KBAssessmentService service = new KBAssessmentService();
        service.setSelectedDimensions(this.selectedDimensions);
        List<KBAssessmentModels.ArticleWrapper> articles = service.fetchArticles(articleIds);
        if (articles.isEmpty()) return;

        Map<String, Decimal> dupScores = new Map<String, Decimal>();
        Map<String, Decimal> conflictScores = new Map<String, Decimal>();
        Map<String, List<Duplicate_Candidate__c>> allCandidates = new Map<String, List<Duplicate_Candidate__c>>();
        if (this.selectedDimensions.contains('Duplication')) {
            dupScores = KBPipelineBridgeService.getBatchDuplicationScores(articleIds);
        }
        if (this.selectedDimensions.contains('Conflict')) {
            conflictScores = KBPipelineBridgeService.getBatchConflictScores(articleIds);
        }
        if (this.selectedDimensions.contains('Duplication') || this.selectedDimensions.contains('Conflict')) {
            allCandidates = KBPipelineBridgeService.getBatchCandidates(articleIds);
        }

        // Existing child rows, indexed by (articleId, dim)
        Map<String, KB_Dimension_Result__c> existing = new Map<String, KB_Dimension_Result__c>();
        for (KB_Dimension_Result__c d : [
            SELECT Id, Dimension__c, Article_Assessment__r.Knowledge__c
            FROM KB_Dimension_Result__c
            WHERE Article_Assessment__c IN :scope
        ]) {
            existing.put(d.Article_Assessment__r.Knowledge__c + '|' + d.Dimension__c, d);
        }

        List<KB_Dimension_Result__c> toUpsert = new List<KB_Dimension_Result__c>();
        // Parallel to toUpsert (same index): the "parentId|dim" key for each row,
        // plus a lookup from that key to the in-memory DimensionScore. Used after
        // upsert to build KB_Dimension_Analysis__c issue/strength rows — the batch
 // computes them but, pre-, never persisted them (the queueable path
        // did). Keyed this way so it works for both new and existing result rows.
        List<String> rowMetaKeys = new List<String>();
        Map<String, KBAssessmentModels.DimensionScore> scoreByMetaKey =
            new Map<String, KBAssessmentModels.DimensionScore>();
        List<KB_Article_Assessment__c> parentUpdates = new List<KB_Article_Assessment__c>();
        // DimensionRegistry's static cache survives across execute() chunks in
        // Database.Stateful — each chunk runs in its own transaction but the JVM
        // instance is reused. This is intentionally exploited for CMDT read perf.
        Map<String, Decimal> effectiveWeights = DimensionRegistry.renormalise(this.selectedDimensions);

        for (KBAssessmentModels.ArticleWrapper article : articles) {
            Id parentId = parentIdByArticle.get(article.id);
            if (parentId == null) continue;

            Decimal dupScore = dupScores.containsKey(article.id) ? dupScores.get(article.id) : null;
            Decimal confScore = conflictScores.containsKey(article.id) ? conflictScores.get(article.id) : null;
            List<Duplicate_Candidate__c> candidates = allCandidates.containsKey(article.id)
                ? allCandidates.get(article.id) : new List<Duplicate_Candidate__c>();

            KBAssessmentModels.ArticleAssessmentResult result =
                service.assessArticleBulk(article, dupScore, confScore, candidates);
            result.calculateOverallScore(this.selectedDimensions, effectiveWeights);

            // Child rows
            if (result.scoresByDim != null) {
                for (String dim : result.scoresByDim.keySet()) {
                    KBAssessmentModels.DimensionScore s = result.getScore(dim);
                    if (s == null) continue;
                    String key = article.id + '|' + dim;
                    KB_Dimension_Result__c prev = existing.get(key);
                    // Always set Article_Assessment__c + Dimension__c (even when
                    // updating an existing row by Id) so persistAnalyses can read
                    // them off the row without a re-query. Harmless on update —
                    // they're the same values the row already holds.
                    KB_Dimension_Result__c row = new KB_Dimension_Result__c(
                        Article_Assessment__c = parentId,
                        Dimension__c = dim
                    );
                    if (prev != null) {
                        row.Id = prev.Id;
                    }
                    row.Score__c = s.score;
                    row.Reasoning__c = s.reasoning != null && s.reasoning.length() > 32000
                        ? s.reasoning.substring(0, 32000) : s.reasoning;
                    row.Is_Unassessable__c = s.isUnassessable == true;
                    row.Scorer_Mode__c = s.scorerMode;
                    row.Execution_Ms__c = s.executionMs;
                    String metaKey = parentId + '|' + dim;
                    toUpsert.add(row);
                    rowMetaKeys.add(metaKey);
                    scoreByMetaKey.put(metaKey, s);
                }
            }

            parentUpdates.add(new KB_Article_Assessment__c(
                Id = parentId,
                Overall_Score__c = result.overallScore,
                Readiness_Status__c = result.readinessStatus,
                Has_Conflicts__c = result.hasConflicts == true,
                Conflict_Details__c = result.conflictDetails
            ));
        }

        if (!toUpsert.isEmpty()) upsert toUpsert;
        if (!parentUpdates.isEmpty()) update parentUpdates;

 // persist issue/strength analysis rows for the scored dimensions.
 // The batch computes them (they're on each DimensionScore) but pre-
        // never wrote them, so large (>50) runs lost all LLM issue/strength
        // detail. Mirror KBAssessmentDimensionQueueable: replace existing rows
        // for these results (idempotent re-run) then partial-success insert.
        persistAnalyses(toUpsert, rowMetaKeys, scoreByMetaKey);

 // per-chunk progress event. cumulativeProcessed survives
        // across chunks because the class is Database.Stateful. The runner
        // LWC's progress getter renders movement via Articles_Processed__c /
        // Total_Articles__c when Current_Batch__c isn't supplied.
        this.cumulativeProcessed += scope.size();
        publishChunkProgress();
    }

    /**
 * emit a KB_Assessment_Progress__e event after each chunk.
     * Best-effort — a publish failure must not take out the chunk.
     */
    private void publishChunkProgress() {
        try {
            KB_Assessment_Progress__e evt = new KB_Assessment_Progress__e(
                Assessment_Id__c = this.runId,
                Status__c = 'In Progress',
                Message__c = 'Scored ' + this.cumulativeProcessed + '/' + this.totalScope + ' articles',
                Articles_Processed__c = this.cumulativeProcessed,
                Total_Articles__c = this.totalScope
            );
            // Parallel shards: Articles_Processed__c is shard-LOCAL. Stamp the
            // 1-based shard index so the runner LWC sums the latest count per
            // shard into a whole-run total instead of one shard's count
            // overwriting another's. Single-batch (non-shard) events omit this
 // and the LWC keeps its legacy single-source behaviour.
            if (this.isShard) {
                evt.Current_Batch__c = this.shardIndex;
            }
            EventBus.publish(evt);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentBatch: publishChunkProgress failed: ' + e.getMessage());
        }
    }

    /**
 * build + persist KB_Dimension_Analysis__c issue/strength rows for the
     * just-upserted dimension results. Mirrors KBAssessmentDimensionQueueable's
     * persistence (delete-then-insert per result for idempotent re-runs; partial-
     * success insert so one bad picklist row can't wipe the chunk's analyses).
     *
     * upsertedRows[i] corresponds to metaKeys[i]; after the upsert each row has an
     * Id. scoreByMetaKey resolves the in-memory DimensionScore carrying the
     * issues/strengths.
     */
    private void persistAnalyses(
        List<KB_Dimension_Result__c> upsertedRows,
        List<String> metaKeys,
        Map<String, KBAssessmentModels.DimensionScore> scoreByMetaKey
    ) {
        if (upsertedRows == null || upsertedRows.isEmpty()) return;

        Set<Id> resultIds = new Set<Id>();
        for (KB_Dimension_Result__c r : upsertedRows) {
            if (r.Id != null) resultIds.add(r.Id);
        }
        if (resultIds.isEmpty()) return;

        // Idempotent re-run: drop existing analysis rows for these results first.
        delete [
            SELECT Id FROM KB_Dimension_Analysis__c
            WHERE Dimension_Result__c IN :resultIds
        ];

        List<KB_Dimension_Analysis__c> analyses = new List<KB_Dimension_Analysis__c>();
        for (Integer i = 0; i < upsertedRows.size(); i++) {
            KB_Dimension_Result__c r = upsertedRows[i];
            if (r.Id == null) continue;
            String metaKey = i < metaKeys.size() ? metaKeys[i] : null;
            KBAssessmentModels.DimensionScore s = metaKey == null ? null : scoreByMetaKey.get(metaKey);
            if (s == null) continue;
            analyses.addAll(KBDimensionAnalysisService.buildForDimension(
                r.Id, r.Article_Assessment__c, r.Dimension__c, s
            ));
        }
        if (analyses.isEmpty()) return;

        // Partial-success: a single drift row (e.g. unexpected picklist) must not
        // take out the whole chunk's analyses — log and continue.
        Database.SaveResult[] saves = Database.insert(analyses, false);
        Integer failed = 0;
        for (Integer i = 0; i < saves.size(); i++) {
            if (!saves[i].isSuccess()) {
                failed++;
                if (failed <= 5) {
                    System.debug(LoggingLevel.ERROR,
                        'KBAssessmentBatch: analysis row insert failed: '
                        + saves[i].getErrors()[0].getMessage()
                        + ' | text=' + analyses[i].Analysis_Text__c
                        + ' | impact=' + analyses[i].Impact__c);
                }
            }
        }
        if (failed > 0) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentBatch: ' + failed + '/' + analyses.size()
                + ' analysis rows failed to insert (logged above).');
        }
    }

    public void finish(Database.BatchableContext bc) {
        // Parallel shards: only the LAST shard to finish dispatches finalization,
        // gated by the Scoring_Shards_Outstanding__c join barrier. A non-final
        // shard returns without dispatching.
        if (this.isShard) {
            if (!isLastShard()) return;
        }
        // Hand off: if the run wants the dedup pipeline (executionMode =
        // DEDUPLICATION with Duplication / Conflict selected), dispatch
        // Tier2 which chains through Tier3 → Tier4 and eventually enqueues
        // KBAssessmentPipelineCallback. Otherwise the dispatcher enqueues
        // the callback directly so the run finalises without pipeline work.
        KBAssessmentPipelineDispatcher.dispatchFinalization(this.runId);
    }

    // Sentinel parked in the barrier once a shard has CLAIMED finalization.
    // Any later shard (including a catch-arm recovery) that reads a negative
    // count knows finalization was already claimed and bails, so finalization
    // fires at most once even though the catch arm below can no longer rely on
    // the count having been decremented (a thrown FOR UPDATE leaves it intact).
    // Public so KBAssessmentService.cancelAssessmentRun can park the same
    // sentinel when it aborts shards (aborted shards skip finish(), so cancel
    // must resolve the barrier itself).
    public static final Integer BARRIER_CLAIMED = -1;

    /**
     * True when a rerun has re-dispatched this run since this wave was launched,
     * so a newer wave of shards now owns the run's scoring rows and this
     * (straggler) chunk must not write. Compares the generation captured in
     * start() against the run's current Dispatch_Generation__c.
     *
     * Fail-safe posture: if the generation was never captured (null — e.g. a
     * test driving execute() directly without start(), or a run predating the
     * field) OR the re-read throws, return false so scoring proceeds. A stale
     * write is the pre-existing behaviour; the gate only ever SKIPS work it is
     * certain is superseded, never blocks a legitimate first wave.
     */
    private Boolean isSupersededByNewerWave() {
        if (this.dispatchGeneration == null) return false;
        try {
            KB_Assessment_Run__c run = [
                SELECT Dispatch_Generation__c FROM KB_Assessment_Run__c
                WHERE Id = :this.runId LIMIT 1
            ];
            Decimal current = run.Dispatch_Generation__c != null
                ? run.Dispatch_Generation__c : 0;
            return current > this.dispatchGeneration;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentBatch.isSupersededByNewerWave: generation re-read failed for run '
                + this.runId + ': ' + e.getMessage());
            return false;
        }
    }

    /**
     * Decrement the scoring join barrier under FOR UPDATE and decide whether
     * THIS shard finalizes. Only the shard that drives the count to 0 claims
     * finalization — it parks a negative sentinel so a concurrent/late shard
     * can't finalize a second time. A barrier-read failure does NOT blindly
     * finalize (that was the double-fire source); it attempts one guarded
     * re-claim so a genuinely stuck run still recovers without double-dispatch.
     *
     * Rationale: KBAssessmentPipelineCallback finalization re-runs the dedup
     * pipeline + severity annotation, which cost LLM callouts — a double-fire
     * is idempotent on persisted data but pays those callouts twice. Mirrors
     * the status-gated idempotency in KBAssessmentDimensionQueueable.markCompleted.
     */
    private Boolean isLastShard() {
        try {
            return claimIfLast();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'KBAssessmentBatch.isLastShard barrier failed: ' + e.getMessage());
            // Do NOT blind-finalize. Re-attempt the claim in a fresh transaction;
            // only finalize if this shard actually wins the claim. If the
            // re-attempt also throws, bubble false — another shard (or the
            // dispatchBatch barrier correction) still owns the un-hang path.
            try {
                return claimIfLast();
            } catch (Exception e2) {
                System.debug(LoggingLevel.ERROR,
                    'KBAssessmentBatch.isLastShard re-claim failed: ' + e2.getMessage());
                return false;
            }
        }
    }

    /**
     * Atomic decrement-and-claim under FOR UPDATE. Returns true only if this
     * transaction takes the barrier to 0 AND it had not already been claimed.
     */
    private Boolean claimIfLast() {
        KB_Assessment_Run__c run = [
            SELECT Id, Scoring_Shards_Outstanding__c
            FROM KB_Assessment_Run__c
            WHERE Id = :this.runId
            FOR UPDATE
        ];
        Decimal outstanding = run.Scoring_Shards_Outstanding__c != null
            ? run.Scoring_Shards_Outstanding__c : 0;
        // Already claimed by another shard — do not finalize again.
        if (outstanding < 0) return false;
        outstanding = outstanding - 1;
        Boolean claim = (outstanding <= 0);
        // Park the sentinel on claim so a peer that reads it later bails; on a
        // non-final decrement store the real remaining count.
        run.Scoring_Shards_Outstanding__c = claim ? BARRIER_CLAIMED : outstanding;
        update run;
        return claim;
    }
}
