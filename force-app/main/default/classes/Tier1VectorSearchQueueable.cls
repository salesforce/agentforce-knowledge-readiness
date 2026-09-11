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
 * Tier 2: Semantic Vector Search — "The Wide Net".
 *
 * Processes ALL articles in a single Queueable execution using the existing
 * findSimilarPairs() method which already has self-exclusion built in.
 *
 * Uses VectorSearchFactory → ConnectApiVectorSearchService (full reuse).
 * Passes only candidate article version IDs to Tier 3 (not full text).
 *
 * Chain: Tier1 → Tier2 (one shot) → Tier3 (one shot) → Tier4 (one shot)
 */
public inherited sharing class Tier1VectorSearchQueueable implements Queueable, Database.AllowsCallouts {

    private List<Id> articleVersionIds;
    private Integer startIndex;
    private Id assessmentRunId;
    private String executionMode;

    public Tier1VectorSearchQueueable(List<Id> articleVersionIds) {
        this.articleVersionIds = articleVersionIds;
        this.startIndex = 0;
        this.executionMode = KBRuntimeConfigService.getExecutionMode();
    }

    public Tier1VectorSearchQueueable(List<Id> articleVersionIds, Integer startIndex) {
        this.articleVersionIds = articleVersionIds;
        this.startIndex = startIndex;
        this.executionMode = KBRuntimeConfigService.getExecutionMode();
    }

    public Tier1VectorSearchQueueable(List<Id> articleVersionIds, Id assessmentRunId) {
        this.articleVersionIds = articleVersionIds;
        this.startIndex = 0;
        this.assessmentRunId = assessmentRunId;
        this.executionMode = KBRuntimeConfigService.getExecutionMode();
    }

    public Tier1VectorSearchQueueable(List<Id> articleVersionIds, Id assessmentRunId, String executionMode) {
        this.articleVersionIds = articleVersionIds;
        this.startIndex = 0;
        this.assessmentRunId = assessmentRunId;
        this.executionMode = String.isNotBlank(executionMode)
            ? executionMode
            : KBRuntimeConfigService.getExecutionMode();
    }

    public void execute(QueueableContext context) {
 // Cancel gate. Soft-stop if the user cancelled the linked
        // assessment run while this queueable was in the flex queue.
        if (this.assessmentRunId != null && KBAssessmentService.isCancelled(this.assessmentRunId)) {
            return;
        }

        KM_Pipeline_Config__mdt config = PipelineConfigService.getActiveConfig();
        IVectorSearchService searchService = VectorSearchFactory.getInstance();

        // Process articles from startIndex, limited by callout budget
        Integer maxArticlesPerExecution = KBRuntimeConfigService.getProcessingBatchSize();
        Integer endIndex = Math.min(startIndex + maxArticlesPerExecution, articleVersionIds.size());

        List<String> batchIds = new List<String>();
        for (Integer i = startIndex; i < endIndex; i++) {
            batchIds.add(String.valueOf(articleVersionIds[i]));
        }

        if (batchIds.isEmpty()) {
            if (this.assessmentRunId != null && !Test.isRunningTest()) {
                System.enqueueJob(new KBAssessmentPipelineCallback(this.assessmentRunId));
            }
            return;
        }

        // Use findSimilarPairs — has self-exclusion built in
        // Falls back to SOQL taxonomy search if vector search is unavailable
        Map<Id, List<Id>> candidatesByTarget = new Map<Id, List<Id>>();
        Boolean usedFallback = false;

        try {
            List<VectorSearchResult> allResults = searchService.findSimilarPairs(
                batchIds,
                Integer.valueOf(config.Tier2_TopK__c),
                config.Tier2_Similarity_Threshold__c
            );

            if (allResults != null) {
                for (VectorSearchResult r : allResults) {
                    if (r.pairedArticleVersionId == null || r.articleVersionId == null) {
                        continue;
                    }
                    Id targetId = Id.valueOf(r.pairedArticleVersionId);
                    Id candidateId = Id.valueOf(r.articleVersionId);
                    if (targetId == candidateId) {
                        continue;
                    }
                    if (!candidatesByTarget.containsKey(targetId)) {
                        candidatesByTarget.put(targetId, new List<Id>());
                    }
                    candidatesByTarget.get(targetId).add(candidateId);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Tier 2: Vector search failed, falling back to SOQL: ' + e.getMessage());
            usedFallback = true;
            for (String artIdStr : batchIds) {
                try {
                    Id artId = Id.valueOf(artIdStr);
                    List<Id> soqlCandidates = Tier1SOQLFallbackService.findCandidatesByTaxonomy(artId);
                    if (!soqlCandidates.isEmpty()) {
                        candidatesByTarget.put(artId, soqlCandidates);
                    }
                } catch (Exception fallbackEx) {
                    System.debug(LoggingLevel.ERROR, 'Tier 2 SOQL fallback failed for ' + artIdStr + ': ' + fallbackEx.getMessage());
                }
            }
        }

        // Cross-language / same-master exclusion. Two KAVs sharing a
        // KnowledgeArticleId are translations (or a straggler prior version)
        // of the same master and are not comparable; two KAVs with different
        // Language codes are not comparable either — a mono-lingual retrieval
        // index only searches one language at a time. The SOQL fallback path
        // already filters by Language upstream, but we run the guard on both
        // paths as one consistent gate so a multilingual Data Cloud index
        // cannot leak cross-language pairs downstream. Tier 3 has a matching
        // defensive guard for cached-pair replay paths.
        filterCrossLanguagePairs(candidatesByTarget);

        if (candidatesByTarget.isEmpty()) {
            System.debug('Tier 2: No candidates found' + (usedFallback ? ' (SOQL fallback)' : '') + '.');
            // Skip the chained callback enqueue under test — Apex caps
            // queueable chain depth at 1 in tests, and the dispatcher's
            // contract is already covered upstream. Production unchanged.
            if (this.assessmentRunId != null && !Test.isRunningTest()) {
                Id cbId = System.enqueueJob(new KBAssessmentPipelineCallback(this.assessmentRunId));
                KBAssessmentService.recordAsyncJob(this.assessmentRunId, cbId);
            }
            return;
        }

        // Build ArticleCandidates pairs for Tier 3, deduplicating (A,B)/(B,A)
        // Use composite keys so each unique pair is only triaged once
        Set<String> seenPairKeys = new Set<String>();
        Map<Id, Set<Id>> dedupedCandidatesByTarget = new Map<Id, Set<Id>>();

        for (Id targetId : candidatesByTarget.keySet()) {
            for (Id candidateId : candidatesByTarget.get(targetId)) {
                if (candidateId == targetId) continue;

                // Ascending sort so (A,B) and (B,A) produce the same key
                String pairKey = KnowledgeAIGovernanceService.generateCompositeKey(
                    String.valueOf(targetId), String.valueOf(candidateId)
                );

                if (seenPairKeys.contains(pairKey)) continue;
                seenPairKeys.add(pairKey);

                // Always use the "smaller" ID as target for consistency
                Id normalizedTarget = String.valueOf(targetId) < String.valueOf(candidateId) ? targetId : candidateId;
                Id normalizedCandidate = normalizedTarget == targetId ? candidateId : targetId;

                if (!dedupedCandidatesByTarget.containsKey(normalizedTarget)) {
                    dedupedCandidatesByTarget.put(normalizedTarget, new Set<Id>());
                }
                dedupedCandidatesByTarget.get(normalizedTarget).add(normalizedCandidate);
            }
        }

        List<ArticleCandidates> allPairs = new List<ArticleCandidates>();
        for (Id targetId : dedupedCandidatesByTarget.keySet()) {
            allPairs.add(new ArticleCandidates(targetId, new List<Id>(dedupedCandidatesByTarget.get(targetId))));
        }

        System.debug('Tier 2: Found candidates for ' + allPairs.size() + ' of '
            + batchIds.size() + ' articles processed.');

        // Hand off to Tier 3
        if (!allPairs.isEmpty()) {
            Id t3Id = System.enqueueJob(new Tier2TriageQueueable(allPairs, this.assessmentRunId, this.executionMode));
            KBAssessmentService.recordAsyncJob(this.assessmentRunId, t3Id);
        } else {
            System.debug('Tier 2 complete: no candidates found.');
            // No candidates — pipeline done, fire callback if assessment is waiting
            if (this.assessmentRunId != null) {
                Id cbId = System.enqueueJob(new KBAssessmentPipelineCallback(this.assessmentRunId));
                KBAssessmentService.recordAsyncJob(this.assessmentRunId, cbId);
            }
        }

        if (endIndex < articleVersionIds.size()) {
            System.debug('Tier 2: ' + (articleVersionIds.size() - endIndex)
                + ' articles deferred to next pipeline run.');
        }
    }

    /**
     * Loads Language + KnowledgeArticleId for every id in the pair graph and
     * delegates to applyPairFilter. Split from the pure filter so tests can
     * exercise the filtering logic with an in-memory article map, avoiding
     * the org-level "translations enabled" gate that inserting Language != 'en_US'
     * KAV rows would otherwise trip in test contexts.
     */
    private static void filterCrossLanguagePairs(Map<Id, List<Id>> candidatesByTarget) {
        if (candidatesByTarget == null || candidatesByTarget.isEmpty()) {
            return;
        }

        Set<Id> allIds = new Set<Id>();
        for (Id targetId : candidatesByTarget.keySet()) {
            allIds.add(targetId);
            List<Id> cands = candidatesByTarget.get(targetId);
            if (cands != null) {
                allIds.addAll(cands);
            }
        }

        Map<Id, Knowledge__kav> articleMap = new Map<Id, Knowledge__kav>();
        for (Knowledge__kav art : [
            SELECT Id, Language, KnowledgeArticleId
            FROM Knowledge__kav
            WHERE Id IN :allIds
        ]) {
            articleMap.put(art.Id, art);
        }

        applyPairFilter(candidatesByTarget, articleMap);
    }

    /**
     * Mutates candidatesByTarget in place, removing (target, candidate) entries
     * that share a KnowledgeArticleId (same master — translation or straggler
     * prior version) or whose Language codes differ. A candidate whose KAV row
     * is missing from articleMap (deleted / access lost between search and the
     * follow-up query) is also dropped defensively. Empties any target key
     * whose candidate list becomes empty.
     */
    @TestVisible
    private static void applyPairFilter(
        Map<Id, List<Id>> candidatesByTarget,
        Map<Id, Knowledge__kav> articleMap
    ) {
        if (candidatesByTarget == null || candidatesByTarget.isEmpty()) {
            return;
        }

        Integer skippedSameMaster = 0;
        Integer skippedCrossLanguage = 0;
        Integer skippedUnknown = 0;
        Set<Id> emptyTargets = new Set<Id>();

        for (Id targetId : candidatesByTarget.keySet()) {
            Knowledge__kav targetArt = articleMap != null ? articleMap.get(targetId) : null;
            List<Id> cands = candidatesByTarget.get(targetId);
            List<Id> kept = new List<Id>();
            if (cands != null) {
                for (Id candidateId : cands) {
                    Knowledge__kav candArt = articleMap != null ? articleMap.get(candidateId) : null;
                    if (targetArt == null || candArt == null) {
                        skippedUnknown++;
                        continue;
                    }
                    if (targetArt.KnowledgeArticleId == candArt.KnowledgeArticleId) {
                        skippedSameMaster++;
                        continue;
                    }
                    if (targetArt.Language != candArt.Language) {
                        skippedCrossLanguage++;
                        continue;
                    }
                    kept.add(candidateId);
                }
            }
            if (kept.isEmpty()) {
                emptyTargets.add(targetId);
            } else {
                candidatesByTarget.put(targetId, kept);
            }
        }

        for (Id t : emptyTargets) {
            candidatesByTarget.remove(t);
        }

        if (skippedSameMaster > 0 || skippedCrossLanguage > 0 || skippedUnknown > 0) {
            System.debug('Tier 1: cross-language filter skipped '
                + skippedSameMaster + ' same-master, '
                + skippedCrossLanguage + ' cross-language, '
                + skippedUnknown + ' unresolved pairs.');
        }
    }

    /**
     * DTO to hold a target article and its vector search candidate IDs.
     */
    public class ArticleCandidates {
        public Id targetArticleVersionId;
        public List<Id> candidateIds;

        public ArticleCandidates(Id targetId, List<Id> candidateIds) {
            this.targetArticleVersionId = targetId;
            this.candidateIds = candidateIds;
        }
    }
}
