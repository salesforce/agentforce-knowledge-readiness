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
 * Tier 4: Multi-Step Agentic Prompt Chain — "The Finals". (Topic 20: not "RLM")
 *
 * Receives all finalist pairs from Tier 3.
 *
 * For each finalist pair:
 *   1. Semantic chunking of article body
 *   2. Sub-agent: extract facts per chunk (max chunks from config, Topic 7)
 *   3. Root agent: compare extracted facts for final ruling
 *
 * Callout budget: KM_Pipeline_Config__mdt.Max_SubAgent_Callouts__c is a
 * PER-TRANSACTION pace, not a coverage limit. When a run has more finalist pairs
 * than one transaction's budget allows, the budget-reached point defers the
 * unprocessed pairs to a self-chained continuation — every pair is
 * eventually compared, nothing is silently dropped. The continuation re-derives
 * its already-evaluated set from the persisted Knowledge_Pair_Evaluation__c rows,
 * so no pair is compared twice. A zero-progress link (budget too low to compare
 * even one pair) aborts the chain and stamps an actionable error on the run.
 *
 * Results upserted to Duplicate_Candidate__c on Composite_Key__c.
 */
public inherited sharing class Tier3AgenticQueueable implements Queueable, Database.AllowsCallouts {

    private List<FinalistPair> finalistPairs;
    private Id assessmentRunId;
    private String executionMode;
    private Id pipelineRunId;
 // Pair-progress tracking across the self-chained continuation. The
    // head link seeds grandTotalPairs from its own finalist count and starts
    // pairsDoneBeforeThisLink at 0; each continuation carries the running totals
    // forward so the LWC can render "compared X of Y article pairs".
    private Integer grandTotalPairs;
    private Integer pairsDoneBeforeThisLink = 0;

    private void initializePipelineRunId() {
        if (this.pipelineRunId != null || this.assessmentRunId == null) {
            return;
        }
        try {
            this.pipelineRunId = [
                SELECT Pipeline_Run__c
                FROM KB_Assessment_Run__c
                WHERE Id = :this.assessmentRunId
                LIMIT 1
            ].Pipeline_Run__c;
        } catch (Exception e) {
            this.pipelineRunId = null;
        }
    }

    private void enqueueAssessmentCallback() {
        if (this.assessmentRunId == null) {
            System.debug(LoggingLevel.WARN, 'Tier 4: Callback handoff skipped because assessmentRunId is null.');
            return;
        }
        Datetime dt = Datetime.now().addMinutes(1);
        String cronExp = String.format(
            '0 {0} {1} {2} {3} ? {4}',
            new List<Object>{
                dt.minute(), dt.hour(), dt.day(), dt.month(), dt.year()
            }
        );
        String jobName = 'KBPipelineCallback_' + String.valueOf(this.assessmentRunId).left(12) + '_' + String.valueOf(System.now().getTime());
        System.debug(LoggingLevel.INFO,
            'Tier 4: Scheduling callback trampoline for run ' + this.assessmentRunId
            + ' with job ' + jobName + ' and cron ' + cronExp);
        Id triggerId = System.schedule(jobName, cronExp, new KBAssessmentPipelineCallbackSchedulable(this.assessmentRunId));
        KBAssessmentService.recordAsyncJob(this.assessmentRunId, triggerId);
    }

    public Tier3AgenticQueueable(List<FinalistPair> finalistPairs, Id assessmentRunId) {
        this.finalistPairs = finalistPairs;
        this.assessmentRunId = assessmentRunId;
        this.executionMode = KBRuntimeConfigService.getExecutionMode();
        this.grandTotalPairs = finalistPairs != null ? finalistPairs.size() : 0;
        initializePipelineRunId();
    }

 // Continuation constructor: carries the chain-wide pair totals so
    // progress messaging stays accurate across links.
    public Tier3AgenticQueueable(
        List<FinalistPair> finalistPairs,
        Id assessmentRunId,
        String executionMode,
        Integer grandTotalPairs,
        Integer pairsDoneBeforeThisLink
    ) {
        this(finalistPairs, assessmentRunId, executionMode);
        this.grandTotalPairs = grandTotalPairs;
        this.pairsDoneBeforeThisLink = pairsDoneBeforeThisLink != null ? pairsDoneBeforeThisLink : 0;
    }

    public Tier3AgenticQueueable(List<FinalistPair> finalistPairs, Id assessmentRunId, String executionMode) {
        this.finalistPairs = finalistPairs;
        this.assessmentRunId = assessmentRunId;
        this.executionMode = String.isNotBlank(executionMode)
            ? executionMode
            : KBRuntimeConfigService.getExecutionMode();
        this.grandTotalPairs = finalistPairs != null ? finalistPairs.size() : 0;
        initializePipelineRunId();
    }

    public void execute(QueueableContext context) {
 // Cancel gate.
        if (this.assessmentRunId != null && KBAssessmentService.isCancelled(this.assessmentRunId)) {
            return;
        }

        if (finalistPairs == null || finalistPairs.isEmpty()) {
            if (this.assessmentRunId != null) {
                enqueueAssessmentCallback();
            }
            return;
        }

        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        Integer maxCallouts = Integer.valueOf(config.Max_SubAgent_Callouts__c);

        // Delegate the per-pair loop to the shared evaluator (also used by the
        // parallel Tier3AgenticBatch path) so the two runtimes can never drift
 // on the dedup guards (published-only, triaged-protection,
        // composite-key dedup, facts cache). We pass
 // maxCallouts so the evaluator applies reserve-before-start pacing:
        // pairs that can't finish within this transaction's budget come back in
        // r.remainingPairs for a continuation, with nothing extracted for them.
        Tier3PairEvaluator.Result r = Tier3PairEvaluator.evaluatePairs(
            finalistPairs, this.assessmentRunId, this.pipelineRunId, maxCallouts
        );

        Integer evaluatedPairs = r.evaluatedPairs;
        List<FinalistPair> remainingPairs = r.remainingPairs;
        Boolean budgetHit = r.budgetHit;

        System.debug(LoggingLevel.INFO,
            'Tier 4 summary: inputPairs=' + (finalistPairs != null ? finalistPairs.size() : 0)
            + ', evaluated=' + evaluatedPairs
            + ', flagged=' + r.flaggedPairs
            + ', clear=' + r.clearPairs
            + ', skipped=' + r.skippedPairs
            + ', errors=' + r.erroredPairs
            + ', budgetHit=' + budgetHit
            + ', maxCallouts=' + maxCallouts
            + ', pipelineRunId=' + this.pipelineRunId
            + ', assessmentRunId=' + this.assessmentRunId);

        // Live pair-progress for the LWC. cumulativeDone counts pairs actually
        // compared across the whole chain (prior links + this link). The grand
        // total is the head link's finalist count; remaining work is whatever
        // we're about to defer to a continuation.
        Integer cumulativeDone = this.pairsDoneBeforeThisLink + evaluatedPairs;
        publishPairProgress(cumulativeDone, this.grandTotalPairs);

        // Upsert results on composite key (Topic 9: idempotent, deduplicated).
        // Candidates are master-detail children of the assessment run, so the run
        // is always non-null here (the pipeline is only ever launched with a run)
        // and visibility is controlled-by-parent — no explicit sharing needed.
        List<Duplicate_Candidate__c> results = r.flaggedCandidates;
        if (!results.isEmpty()) {
 // Keep one candidate per pair per run, and never resurface
            // a human-triaged row — the helper returns only the rows to write.
            List<Duplicate_Candidate__c> toUpsert =
                Tier3PairEvaluator.attachExistingIdsForRunScopedUpsert(results, this.assessmentRunId);
            if (!toUpsert.isEmpty()) {
                upsert toUpsert;
            }
        }

        if (!r.evaluations.isEmpty()) {
            upsert r.evaluations Composite_Version_Key__c;
        }

 // budget reached with work still to do → chain a continuation for
        // the deferred pairs instead of silently dropping them. The continuation
        // re-derives cached keys from the persisted Knowledge_Pair_Evaluation__c
        // rows, so pairs evaluated in this link are skipped (no double-work).
        if (budgetHit && !remainingPairs.isEmpty()) {
            // Zero-progress guard: deferred pairs are always genuinely
            // unprocessed (cached/self/blank pairs are skipped BEFORE the budget
            // check, never deferred). So if this link compared zero pairs yet
            // still has work to defer, the budget is too low to handle even one
            // pair — chaining would loop forever.
            if (evaluatedPairs == 0) {
                System.debug(LoggingLevel.ERROR,
                    'Tier 4: callout budget (' + maxCallouts + ') too low to evaluate any pair — '
                    + 'aborting continuation to avoid an infinite chain. Raise Max_SubAgent_Callouts__c.');
                recordBudgetTooLow(maxCallouts);
                // Finalize so the run does not hang; the run carries the error note.
                if (this.assessmentRunId != null) {
                    enqueueAssessmentCallback();
                }
                return;
            }

            System.debug(LoggingLevel.INFO,
                'Tier 4: callout budget reached — chaining continuation for '
                + remainingPairs.size() + ' remaining pair(s).');
            Id continuationId = System.enqueueJob(
                new Tier3AgenticQueueable(
                    remainingPairs, this.assessmentRunId, this.executionMode,
                    this.grandTotalPairs, cumulativeDone
                )
            );
            // Register the continuation so the cancel-from-LWC path (which
            // abortJob's every id in KB_Assessment_Run__c.Async_Job_Ids__c) can
            // stop the chain — otherwise continuations keep running after Cancel.
            if (this.assessmentRunId != null) {
                KBAssessmentService.recordAsyncJob(this.assessmentRunId, continuationId);
            }
            return;
        }

        System.debug('Tier 4 complete. Pipeline finished.');

        // Fire assessment callback if an assessment run is waiting for pipeline results
        if (this.assessmentRunId != null) {
            System.debug(LoggingLevel.INFO,
                'Tier 4: Handing off to callback trampoline for run ' + this.assessmentRunId);
            enqueueAssessmentCallback();
        }
    }

    /**
 * surface a misconfigured (too-low) callout budget on the run instead
     * of spinning silently. Best-effort — never let a status-write failure mask
     * the original condition.
     */
    private void recordBudgetTooLow(Integer maxCallouts) {
        if (this.assessmentRunId == null) {
            return;
        }
        publishBudgetTooLow(maxCallouts);
    }

    /**
     * Live "compared X of Y article pairs" progress for the dedup phase. The
     * LWC (kbAssessmentRunProgress) renders the Platform Event Message__c — this
     * makes the otherwise-opaque Tier 4 tail show concrete pair counts. The run
     * status stays 'Pipeline Running' (set by the dispatcher); the LWC's
     * monotonic latch keeps the bar from moving backward off this event.
     */
    private void publishPairProgress(Integer done, Integer total) {
        if (this.assessmentRunId == null || total == null || total <= 0) {
            return;
        }
        try {
            // Current_Batch__c / Total_Batches__c carry the pair counts during
            // the pipeline phase so the LWC can animate the bar across the
            // 80→100% dedup tail. Scoring is finished by the time these fire, so
            // reusing the numeric fields is unambiguous — the LWC interprets
            // them as pair counts only while status is 'Pipeline Running'.
            EventBus.publish(new KB_Assessment_Progress__e(
                Assessment_Id__c = this.assessmentRunId,
                Status__c = 'Pipeline Running',
                Message__c = 'Checking for duplicates and conflicts — compared ' + done + ' of ' + total + ' article pairs…',
                Current_Batch__c = done,
                Total_Batches__c = total
            ));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Tier 4: publishPairProgress failed: ' + e.getMessage());
        }
    }

    private void publishBudgetTooLow(Integer maxCallouts) {
        String msg = 'Deduplication could not run: the Max Sub-Agent Callouts budget ('
            + maxCallouts + ') is too low to compare even one article pair. '
            + 'Raise it on the KB_Pipeline_Config__c custom setting and re-run.';
        // Durable record on the run row (queryable / survives the async window).
        try {
            update new KB_Assessment_Run__c(
                Id = this.assessmentRunId,
                Status_Message__c = msg
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'Tier 4: failed to record budget-too-low note: ' + e.getMessage());
        }
        // Live surfacing: the LWC (kbAssessmentRunProgress) renders the Platform
        // Event Message__c, not the run row, so publish here too — otherwise the
 // warning would only ever land in the DB (review nit on).
        try {
            EventBus.publish(new KB_Assessment_Progress__e(
                Assessment_Id__c = this.assessmentRunId,
                Status__c = 'In Progress',
                Message__c = msg
            ));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Tier 4: failed to publish budget-too-low event: ' + e.getMessage());
        }
    }

    /**
     * DTO representing a target-finalist pair for Tier 4 evaluation.
     */
    public class FinalistPair {
        public Id targetId;
        public Id finalistId;

        public FinalistPair(Id targetId, Id finalistId) {
            this.targetId = targetId;
            this.finalistId = finalistId;
        }
    }
}
