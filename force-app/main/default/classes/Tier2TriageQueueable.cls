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
 * Tier 3: LLM-as-a-Judge Triage — "The Semi-Finals".
 *
 * Receives a list of (target, candidates) pairs from Tier 2. Processes them
 * one at a time within a single Queueable execution (1 LLM call each).
 *
 * All SOQL is bulkified upfront — article metadata and suppressed pairs are
 * pre-fetched before the processing loop. Zero SOQL inside the loop.
 *
 * Uses positional indexes in the prompt, not Salesforce IDs.
 * Zero-candidates instruction: return empty array if none found.
 * Checks Suppressed status before passing to Tier 4.
 */
public inherited sharing class Tier2TriageQueueable implements Queueable, Database.AllowsCallouts {

    private List<Tier1VectorSearchQueueable.ArticleCandidates> pairs;
    private Id assessmentRunId;
    private String executionMode;

    public Tier2TriageQueueable(List<Tier1VectorSearchQueueable.ArticleCandidates> pairs) {
        this.pairs = pairs;
        this.executionMode = KBRuntimeConfigService.getExecutionMode();
    }

    public Tier2TriageQueueable(List<Tier1VectorSearchQueueable.ArticleCandidates> pairs, Id assessmentRunId) {
        this.pairs = pairs;
        this.assessmentRunId = assessmentRunId;
        this.executionMode = KBRuntimeConfigService.getExecutionMode();
    }

    public Tier2TriageQueueable(
        List<Tier1VectorSearchQueueable.ArticleCandidates> pairs,
        Id assessmentRunId,
        String executionMode
    ) {
        this.pairs = pairs;
        this.assessmentRunId = assessmentRunId;
        this.executionMode = String.isNotBlank(executionMode)
            ? executionMode
            : KBRuntimeConfigService.getExecutionMode();
    }

    public void execute(QueueableContext context) {
 // Cancel gate.
        if (this.assessmentRunId != null && KBAssessmentService.isCancelled(this.assessmentRunId)) {
            return;
        }

        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        Integer maxFinalists = Integer.valueOf(config.Max_Finalists__c);
        PromptTemplateService promptService = PromptTemplateService.getInstance();

        // ====================================================================
        // BULK PRE-FETCH: all article metadata + suppressed keys (0 SOQL in loop)
        // ====================================================================

        // 1. Collect all article IDs across all pairs
        Set<Id> allArticleIds = new Set<Id>();
        for (Tier1VectorSearchQueueable.ArticleCandidates pair : pairs) {
            allArticleIds.add(pair.targetArticleVersionId);
            allArticleIds.addAll(pair.candidateIds);
        }

        // 2. Single SOQL to fetch all article metadata.
 // filter to Online here so non-Online (Draft / Archived /
        //    superseded prior-version) articles drop out of the map BEFORE the
        //    per-pair triageDuplicateCandidates() LLM callout below. Tier 4's
 // publish-status gate is the correctness backstop, but it's the
        //    last stop — without this pre-filter Tier 3 pays an Einstein callout
        //    for pairs Tier 4 then discards. A pair whose target or candidate is
        //    absent from articleMap is skipped (see the null checks in the loop),
        //    so those pairs never reach the callout. Literal 'Online' matches
        //    Tier 4's effective KBPublishStatusHelper.isOnline gate.
        Map<Id, Knowledge__kav> articleMap = new Map<Id, Knowledge__kav>([
            SELECT Id, Title, Summary
            FROM Knowledge__kav
            WHERE Id IN :allArticleIds
              AND PublishStatus = 'Online'
        ]);

        // 3. Pre-compute all possible composite keys for the suppression check.
        // Keys are run-scoped (assessmentRunId + pair), so suppression is honored
        // within this run / its reruns but does NOT carry across separate runs —
        // matching the per-run independence of the candidate model. The map lets
        // us translate a stored run-scoped key back to the run-agnostic key used
        // for the in-memory finalist checks below.
        Map<String, String> runScopedToPairKey = new Map<String, String>();
        for (Tier1VectorSearchQueueable.ArticleCandidates pair : pairs) {
            for (Id candId : pair.candidateIds) {
                String pairKey = KnowledgeAIGovernanceService.generateCompositeKey(
                    String.valueOf(pair.targetArticleVersionId), String.valueOf(candId)
                );
                String runScopedKey = KnowledgeAIGovernanceService.generateCompositeKey(
                    String.valueOf(pair.targetArticleVersionId), String.valueOf(candId), this.assessmentRunId
                );
                runScopedToPairKey.put(runScopedKey, pairKey);
            }
        }

        // 4. Single SOQL to fetch suppressed keys for THIS run; store as the
        // run-agnostic pair key so the finalist filter below can match.
        Set<String> suppressedKeys = new Set<String>();
        for (Duplicate_Candidate__c dc : [
            SELECT Composite_Key__c FROM Duplicate_Candidate__c
            WHERE Composite_Key__c IN :runScopedToPairKey.keySet() AND Status__c = 'Suppressed'
        ]) {
            String pairKey = runScopedToPairKey.get(dc.Composite_Key__c);
            if (pairKey != null) suppressedKeys.add(pairKey);
        }

        // ====================================================================
        // PROCESS PAIRS: LLM calls only, no SOQL
        // ====================================================================

        List<Tier3AgenticQueueable.FinalistPair> allFinalists =
            new List<Tier3AgenticQueueable.FinalistPair>();
        Set<String> seenFinalistKeys = new Set<String>();

        Integer maxCallsPerExecution = KBRuntimeConfigService.getMaxCalloutLimit();
        Integer callCount = 0;

        for (Tier1VectorSearchQueueable.ArticleCandidates pair : pairs) {
            if (callCount >= maxCallsPerExecution) {
                break;
            }

            Knowledge__kav targetArt = articleMap.get(pair.targetArticleVersionId);
            if (targetArt == null) {
                continue;
            }

            // Build candidate summaries from pre-fetched data
            List<PromptTemplateService.CandidateSummary> summaries =
                new List<PromptTemplateService.CandidateSummary>();
            List<Id> indexToIdMap = new List<Id>();

            for (Id candId : pair.candidateIds) {
                Knowledge__kav cand = articleMap.get(candId);
                if (cand != null) {
                    summaries.add(new PromptTemplateService.CandidateSummary(
                        cand.Id, cand.Title, cand.Summary
                    ));
                    indexToIdMap.add(cand.Id);
                }
            }

            if (summaries.isEmpty()) {
                continue;
            }

            // Single LLM call for this pair
            try {
                PromptTemplateService.TriageResult result = promptService.triageDuplicateCandidates(
                    targetArt.Title, targetArt.Summary, summaries
                );
                callCount++;

                // Early exit: no candidates
                if (result.topCandidateIndexes == null || result.topCandidateIndexes.isEmpty()) {
                    continue;
                }

                // Map positional indexes back to IDs, filter suppressed (Topics 3, 10)
                for (Integer idx : result.topCandidateIndexes) {
                    if (allFinalists.size() >= maxFinalists * pairs.size()) {
                        break; // Safety cap
                    }
                    if (idx < 0 || idx >= indexToIdMap.size()) {
                        continue;
                    }

                    Id finalistId = indexToIdMap[idx];
                    String key = KnowledgeAIGovernanceService.generateCompositeKey(
                        String.valueOf(pair.targetArticleVersionId), String.valueOf(finalistId)
                    );

                    if (!suppressedKeys.contains(key) && !seenFinalistKeys.contains(key)) {
                        seenFinalistKeys.add(key);
                        allFinalists.add(new Tier3AgenticQueueable.FinalistPair(
                            pair.targetArticleVersionId, finalistId
                        ));
                    }
                }

            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Tier 3: Triage failed for ' + pair.targetArticleVersionId + ': ' + e.getMessage());
            }
        }

        System.debug('Tier 3: Processed ' + callCount + ' articles. '
            + allFinalists.size() + ' finalist pairs.');

        // Hand off to Tier 4 via a Finalizer rather than a direct
 // System.enqueueJob. The pipeline chain is
        // DimensionQueueable → Tier2 → Tier3 → Tier4, which reaches depth 4 on
        // a non-production org whose chained-queueable stack-depth ceiling is
        // 5. Under any extra async pressure (e.g. concurrent duplicate runs)
        // the in-chain enqueue of Tier 4 trips "Maximum stack depth has been
        // reached" and the run wedges in Pipeline Running forever. A Finalizer
        // runs AFTER this queueable returns and its enqueueJob starts a FRESH
        // chain at depth 1 — breaking the accumulation with no scheduling
        // latency (unlike the System.schedule trampoline Tier 4 uses for the
        // callback). attachFinalizer is only permitted while running as a real
        // queueable; a synchronous caller (e.g. a test invoking execute()
        // directly) throws "attachFinalizer is not allowed in this context".
        // Fall back to a direct enqueue there — the depth concern only exists
        // in the real async chain, so the fallback is harmless.
        if (!allFinalists.isEmpty()) {
            try {
                System.attachFinalizer(new Tier4HandoffFinalizer(
                    allFinalists, this.assessmentRunId, this.executionMode
                ));
            } catch (System.HandledException e) {
                // Synchronous fallback (e.g. a test invoking execute() directly,
                // where attachFinalizer is disallowed). Run the legacy single-lane
                // queueable — its finish() hands off via System.schedule, so it
                // adds no chained enqueue. The parallel dispatcher is reserved for
                // the real async finalizer path below (fresh chain, depth 1).
                Id t4Id = System.enqueueJob(new Tier3AgenticQueueable(
                    allFinalists, this.assessmentRunId, this.executionMode
                ));
                KBAssessmentService.recordAsyncJob(this.assessmentRunId, t4Id);
            }
        } else {
            System.debug('Tier 3 complete: no finalists identified.');
            // No finalists — pipeline done, fire callback if assessment is waiting
            if (this.assessmentRunId != null) {
                Id cbId = System.enqueueJob(new KBAssessmentPipelineCallback(this.assessmentRunId));
                KBAssessmentService.recordAsyncJob(this.assessmentRunId, cbId);
            }
        }
    }

    /**
     * Finalizer that enqueues Tier 4 in a fresh queueable chain (depth resets
     * to 1), so the Tier2→Tier3→Tier4 handoff can never accumulate toward the
 * non-prod stack-depth ceiling. Runs after Tier3.execute returns.
     */
    public class Tier4HandoffFinalizer implements Finalizer {
        private final List<Tier3AgenticQueueable.FinalistPair> finalists;
        private final Id assessmentRunId;
        private final String executionMode;

        public Tier4HandoffFinalizer(
            List<Tier3AgenticQueueable.FinalistPair> finalists,
            Id assessmentRunId,
            String executionMode
        ) {
            this.finalists = finalists;
            this.assessmentRunId = assessmentRunId;
            this.executionMode = executionMode;
        }

        public void execute(FinalizerContext ctx) {
            // Hand off to the parallel dispatcher in a fresh chain (depth 1).
            // The dispatcher shards across up to 5 concurrent batch jobs, or
            // falls back to the single-lane queueable for small pair counts.
            Id t4Id = System.enqueueJob(new Tier3DispatchQueueable(
                this.finalists, this.assessmentRunId, this.executionMode
            ));
            KBAssessmentService.recordAsyncJob(this.assessmentRunId, t4Id);
        }
    }

}
