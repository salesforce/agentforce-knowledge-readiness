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
 * Tier 2 fan-out worker: scores ONE dimension for ALL articles in a run,
 * in a single queueable hop. Six of these (one per dimension) are enqueued
 * in parallel by KBAssessmentService for runs of size ≤ 50 (the queueable
 * tier ceiling). No chaining, no trampoline.
 *
 * Each worker:
 *   1. Loads article wrappers + pre-loaded pipeline data.
 *   2. Scores its dimension for every article.
 *   3. Upserts KB_Dimension_Result__c rows (one per article for this dim).
 *   4. Appends its name to KB_Assessment_Run__c.Completed_Dimensions__c
 *      under a FOR UPDATE lock.
 *   5. If it's the last dim to finish (completed == dispatched), enqueues
 *      KBAssessmentPipelineCallback for run-level finalization.
 *
 * Governor budget per hop is a full 100 callouts / 100 SOQL. The 50-article
 * cap (set in KBAssessmentService.resolveQueueableThreshold) is a wall-clock
 * guard rather than a callout-budget one — at 1 callout/article post-
 * the callout governor would allow more, but ~7s/callout × 50 already
 * approaches the queueable's practical wall-clock limit. Deterministic dims
 * (Freshness/Duplication/Conflict) can process hundreds per hop.
 */
public with sharing class KBAssessmentDimensionQueueable implements Queueable, Database.AllowsCallouts {

    private Id runId;
    private List<String> articleIds;
    private String dimensionName;
    // Completion token (B). Identifies THIS task in the run's dispatched-token
    // set. When null (legacy 3-arg path / single-task dims) the completion gate
    // falls back to keying on the dimension name, preserving old behaviour.
    private String taskToken;
    // The run's dispatch generation captured at dispatch time (twin of the
    // batch-tier gate in KBAssessmentBatch). execute() re-reads the run's current
    // generation and bails before writing if it has advanced: a straggler
    // queueable from an aborted prior wave (abortJob lets an in-flight execute()
    // drain to completion) declines to write instead of colliding
    // (UNABLE_TO_LOCK_ROW) with the new wave over the same KB_Dimension_Result__c
    // / KB_Article_Assessment__c rows. Null = not captured (legacy 3/4-arg
    // callers, e.g. tests) → gate skipped, preserving old behaviour. The
    // dispatcher coalesces the run's null generation to 0 before passing it, so a
    // real wave always carries a non-null value and the null sentinel
    // unambiguously means "not captured".
    private Decimal dispatchGeneration;

    public KBAssessmentDimensionQueueable(
        Id runId,
        List<String> articleIds,
        String dimensionName
    ) {
        this(runId, articleIds, dimensionName, null, null);
    }

    public KBAssessmentDimensionQueueable(
        Id runId,
        List<String> articleIds,
        String dimensionName,
        String taskToken
    ) {
        this(runId, articleIds, dimensionName, taskToken, null);
    }

    public KBAssessmentDimensionQueueable(
        Id runId,
        List<String> articleIds,
        String dimensionName,
        String taskToken,
        Decimal dispatchGeneration
    ) {
        this.runId = runId;
        this.articleIds = articleIds;
        this.dimensionName = dimensionName;
        this.taskToken = taskToken;
        this.dispatchGeneration = dispatchGeneration;
    }

    public void execute(QueueableContext context) {
 // Cancel gate. Soft-stop: if a user cancelled the run
        // while this queueable was in the flex queue, no-op. Do NOT call
        // markCompleted() — that would advance Completed_Dimensions__c and
        // race the cancel state machine.
        if (KBAssessmentService.isCancelled(this.runId)) return;
        // Generation gate. abortJob lets an in-flight execute() drain to
        // completion; if the run was re-dispatched (rerun) since this wave was
        // enqueued, a newer wave now owns the same result rows. This straggler
        // declines to write rather than collide with it (UNABLE_TO_LOCK_ROW).
        // The cancel gate above covers the cancelled-and-not-yet-reran case;
        // this covers the reran case (where status is back to In Progress so
        // isCancelled is false). Also skip markCompleted() — the new wave owns
        // completion tracking. Twin of KBAssessmentBatch.isSupersededByNewerWave().
        if (isSupersededByNewerWave()) return;

 // emit a KB_Assessment_Progress__e heartbeat at the start
        // of every dimension so the runner LWC's progress bar advances even
        // before the first dimension finishes. Without this the LWC would
        // sit on the 'Queued' event from KBAssessmentService for the full
        // duration of the slowest LLM dimension on small runs.
        publishProgress('In Progress', 'Starting ' + this.dimensionName + ' dimension', null, null);

        try {
            KBAssessmentService service = new KBAssessmentService();
            service.setSelectedDimensions(new Set<String>{ this.dimensionName });
            List<KBAssessmentModels.ArticleWrapper> articles = service.fetchArticles(this.articleIds);

            if (articles.isEmpty()) {
                markCompleted();
                return;
            }

            Map<String, Decimal> dupScores = new Map<String, Decimal>();
            Map<String, Decimal> conflictScores = new Map<String, Decimal>();
            Map<String, List<Duplicate_Candidate__c>> allCandidates = new Map<String, List<Duplicate_Candidate__c>>();

            DimensionRegistry.DimensionDefinition def = DimensionRegistry.get(this.dimensionName);
            if (def != null && def.requiresPipelineData) {
                if (this.dimensionName == 'Duplication') {
                    dupScores = KBPipelineBridgeService.getBatchDuplicationScores(this.articleIds);
                } else if (this.dimensionName == 'Conflict') {
                    conflictScores = KBPipelineBridgeService.getBatchConflictScores(this.articleIds);
                }
                allCandidates = KBPipelineBridgeService.getBatchCandidates(this.articleIds);
            }

            // Load existing parent assessments for this run keyed by article id,
            // so we can stamp the master-detail on new child rows.
            Map<String, Id> parentIdByArticle = new Map<String, Id>();
            for (KB_Article_Assessment__c p : [
                SELECT Id, Knowledge__c FROM KB_Article_Assessment__c
                WHERE Assessment_Run__c = :this.runId
            ]) {
                parentIdByArticle.put(p.Knowledge__c, p.Id);
            }

            // Map existing child rows by (article, dim) so we can update in place.
            Map<String, KB_Dimension_Result__c> existingByArticle = new Map<String, KB_Dimension_Result__c>();
            for (KB_Dimension_Result__c d : [
                SELECT Id, Article_Assessment__c, Dimension__c,
                       Article_Assessment__r.Knowledge__c
                FROM KB_Dimension_Result__c
                WHERE Article_Assessment__r.Assessment_Run__c = :this.runId
                  AND Dimension__c = :this.dimensionName
            ]) {
                existingByArticle.put(d.Article_Assessment__r.Knowledge__c, d);
            }

            List<KB_Dimension_Result__c> toUpsert = new List<KB_Dimension_Result__c>();
            // Collect parentId→score for recommendation generation below (avoids double scoring).
            Map<Id, KBAssessmentModels.DimensionScore> scoreByParentId =
                new Map<Id, KBAssessmentModels.DimensionScore>();

            for (KBAssessmentModels.ArticleWrapper article : articles) {
                Id parentId = parentIdByArticle.get(article.id);
                if (parentId == null) continue; // parent assessment not created yet — skip

                Decimal dupScore = dupScores.containsKey(article.id) ? dupScores.get(article.id) : null;
                Decimal confScore = conflictScores.containsKey(article.id) ? conflictScores.get(article.id) : null;
                List<Duplicate_Candidate__c> candidates = allCandidates.containsKey(article.id)
                    ? allCandidates.get(article.id) : new List<Duplicate_Candidate__c>();

                KBAssessmentModels.ArticleAssessmentResult result =
                    service.assessArticleBulk(article, dupScore, confScore, candidates);
                KBAssessmentModels.DimensionScore score = result.getScore(this.dimensionName);
                if (score == null) continue;

                scoreByParentId.put(parentId, score);

                KB_Dimension_Result__c existing = existingByArticle.get(article.id);
                KB_Dimension_Result__c row = new KB_Dimension_Result__c(
                    Article_Assessment__c = parentId,
                    Dimension__c = this.dimensionName
                );
                if (existing != null) {
                    row.Id = existing.Id;
                }
                row.Score__c = score.score;
                row.Reasoning__c = score.reasoning != null && score.reasoning.length() > 32000
                    ? score.reasoning.substring(0, 32000)
                    : score.reasoning;
                row.Is_Unassessable__c = score.isUnassessable == true;
                row.Scorer_Mode__c = score.scorerMode;
                row.Execution_Ms__c = score.executionMs;
                toUpsert.add(row);
            }

            if (!toUpsert.isEmpty()) upsert toUpsert;

            // Replace KB_Dimension_Analysis__c rows for this (run, dim). They
            // are master-detail children of KB_Dimension_Result__c and only
            // become deletable once we have the parent Ids — which is now.
            if (!toUpsert.isEmpty()) {
                Set<Id> resultIds = new Set<Id>();
                for (KB_Dimension_Result__c r : toUpsert) {
                    if (r.Id != null) resultIds.add(r.Id);
                }
                if (!resultIds.isEmpty()) {
                    delete [
                        SELECT Id FROM KB_Dimension_Analysis__c
                        WHERE Dimension_Result__c IN :resultIds
                    ];
                }

                List<KB_Dimension_Analysis__c> analyses = new List<KB_Dimension_Analysis__c>();
                for (KB_Dimension_Result__c r : toUpsert) {
                    if (r.Id == null) continue;
                    KBAssessmentModels.DimensionScore s = scoreByParentId.get(r.Article_Assessment__c);
                    if (s == null) continue;
                    analyses.addAll(KBDimensionAnalysisService.buildForDimension(
                        r.Id, r.Article_Assessment__c, this.dimensionName, s
                    ));
                }
                // Partial-success insert: one bad row (e.g. unexpected
                // picklist drift from the LLM) must NOT take out the whole
                // batch and silently leave a dimension with zero analysis
                // rows. KBDimensionAnalysisService.coercePicklist handles
                // the common cases; this is the belt-and-braces failsafe.
                if (!analyses.isEmpty()) {
                    Database.SaveResult[] saves = Database.insert(analyses, false);
                    Integer failed = 0;
                    for (Integer i = 0; i < saves.size(); i++) {
                        if (!saves[i].isSuccess()) {
                            failed++;
                            if (failed <= 5) {
                                System.debug(LoggingLevel.ERROR,
                                    'KBAssessmentDimensionQueueable(' + this.dimensionName
                                    + '): analysis row insert failed: '
                                    + saves[i].getErrors()[0].getMessage()
                                    + ' | text=' + analyses[i].Analysis_Text__c
                                    + ' | impact=' + analyses[i].Impact__c);
                            }
                        }
                    }
                    if (failed > 0) {
                        System.debug(LoggingLevel.WARN,
                            'KBAssessmentDimensionQueueable(' + this.dimensionName
                            + '): ' + failed + '/' + analyses.size()
                            + ' analysis rows failed to insert (logged above).');
                    }
                }
            }

            markCompleted();

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'KBAssessmentDimensionQueueable(' + this.dimensionName + ') failed: ' +
                e.getMessage() + '\n' + e.getStackTraceString());
            // Best-effort: still mark this dim as completed so finalization
            // can proceed on the dims that did succeed. If this also fails
            // (e.g. row-lock contention), the run will eventually time out
            // and the diagnostics tab surfaces it.
            try {
                markCompleted();
            } catch (Exception retryErr) {
                System.debug(LoggingLevel.ERROR,
                    'KBAssessmentDimensionQueueable(' + this.dimensionName
                    + '): markCompleted retry also failed: ' + retryErr.getMessage());
            }
        }
    }

    /**
     * True when a rerun has re-dispatched this run since this wave was enqueued,
     * so a newer wave of workers now owns the run's scoring rows and this
     * (straggler) queueable must not write. Compares the generation captured at
     * dispatch against the run's current Dispatch_Generation__c.
     *
     * Fail-safe posture: if the generation was never captured (null — legacy
     * callers / tests) OR the re-read throws, return false so scoring proceeds. A
     * stale write is the pre-existing behaviour; the gate only ever SKIPS work it
     * is certain is superseded, never blocks a legitimate first wave.
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
                'KBAssessmentDimensionQueueable(' + this.dimensionName
                + '): generation re-read failed for run ' + this.runId + ': ' + e.getMessage());
            return false;
        }
    }

    /**
     * Append this dimension to Completed_Dimensions__c under FOR UPDATE lock.
     * If we're the last dim to complete, enqueue KBAssessmentPipelineCallback
     * for run-level finalization.
     */
    private void markCompleted() {
        KB_Assessment_Run__c run = [
            SELECT Id, Status__c, Dispatched_Dimensions__c, Completed_Dimensions__c
            FROM KB_Assessment_Run__c
            WHERE Id = :this.runId
            FOR UPDATE
        ];

        // Idempotency: if the run already advanced past In Progress, another
        // queueable already dispatched finalization. Don't double-dispatch.
        if (run.Status__c != 'In Progress') return;

        // Completion unit: the task token when this queueable was dispatched as
        // one of several chunks for a dimension (B); otherwise the dimension
        // name (legacy single-task path). Dispatched_Dimensions__c holds whichever
        // the dispatcher persisted, so the set-membership gate is consistent.
        String unit = String.isNotBlank(this.taskToken) ? this.taskToken : this.dimensionName;

        Set<String> completed = new Set<String>();
        if (String.isNotBlank(run.Completed_Dimensions__c)) {
            for (String d : run.Completed_Dimensions__c.split(',')) {
                if (String.isNotBlank(d)) completed.add(d.trim());
            }
        }
        completed.add(unit);

        Set<String> dispatched = new Set<String>();
        if (String.isNotBlank(run.Dispatched_Dimensions__c)) {
            for (String d : run.Dispatched_Dimensions__c.split(',')) {
                if (String.isNotBlank(d)) dispatched.add(d.trim());
            }
        }

        Boolean isLastDim = completed.containsAll(dispatched) && !dispatched.isEmpty();

        // Write the updated completed list AND flip status atomically while
        // we still hold the FOR UPDATE lock. This prevents a second queueable
        // from seeing the same pre-dispatch state.
        run.Completed_Dimensions__c = String.join(new List<String>(completed), ',');
        if (isLastDim) {
            run.Status__c = 'Scoring Complete';
        }
        update run;

 // per-dimension completion event. Drives the runner's
        // progress bar via the existing Current_Batch__c / Total_Batches__c
        // math (Math.round(10 + (currentBatch / totalBatches) * 45)). We
        // publish OUTSIDE the if(isLastDim) branch so the bar advances on
        // every completion, not just the final one.
        publishProgress(
            'In Progress',
            'Completed ' + this.dimensionName + ' dim (' + completed.size() + '/' + dispatched.size() + ')',
            completed.size(),
            dispatched.size()
        );

        if (isLastDim) {
            KBAssessmentPipelineDispatcher.dispatchFinalization(this.runId);
        }
    }

    /**
 * emit a KB_Assessment_Progress__e event tagged with this
     * run id. Best-effort — a publish failure must not take out scoring.
     * The runner LWC subscribes via lightning/empApi and uses the existing
     * progress getter (`Math.round(10 + (currentBatch / totalBatches) * 45)`)
     * to advance the progress bar. currentBatch/totalBatches may be null
     * for the start-of-dimension heartbeat — the LWC falls back to the
     * articles-processed branch in that case.
     */
    private void publishProgress(String status, String message, Integer currentBatch, Integer totalBatches) {
        try {
            KB_Assessment_Progress__e evt = new KB_Assessment_Progress__e(
                Assessment_Id__c = this.runId,
                Status__c = status,
                Message__c = message != null && message.length() > 255 ? message.substring(0, 255) : message
            );
            if (currentBatch != null) evt.Current_Batch__c = currentBatch;
            if (totalBatches != null) evt.Total_Batches__c = totalBatches;
            EventBus.publish(evt);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentDimensionQueueable(' + this.dimensionName
                + '): publishProgress failed: ' + e.getMessage());
        }
    }
}