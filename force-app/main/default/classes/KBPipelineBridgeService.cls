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
public with sharing class KBPipelineBridgeService {

    /**
     * Bulkified: Now calls the batch method to ensure consistent logic and SOQL efficiency.
     */
    public static Decimal getDuplicationScore(String articleId) {
        if (String.isBlank(articleId)) return 100;
        Map<String, Decimal> results = getBatchDuplicationScores(new List<String>{articleId});
        return results.get(articleId);
    }

    /**
     * Bulkified: Now calls the batch method.
     */
    public static Decimal getConflictScore(String articleId) {
        if (String.isBlank(articleId)) return 100;
        Map<String, Decimal> results = getBatchConflictScores(new List<String>{articleId});
        return results.get(articleId);
    }

    /**
     * Returns max confidence scores for duplicates.
     */
    public static Map<String, Decimal> getBatchDuplicationScores(List<String> articleIds) {
        return getBatchDuplicationScores(articleIds, null);
    }

    public static Map<String, Decimal> getBatchDuplicationScores(List<String> articleIds, Id runId) {
        return getScoresByFlagType(articleIds, new List<String>{'Duplicate'}, runId);
    }

    /**
     * Returns max confidence scores for conflicts (Contradiction).
 * the 'Overlap' flag type was retired; only Contradiction feeds the
     * Conflict dimension now.
     */
    public static Map<String, Decimal> getBatchConflictScores(List<String> articleIds) {
        return getBatchConflictScores(articleIds, null);
    }

    public static Map<String, Decimal> getBatchConflictScores(List<String> articleIds, Id runId) {
        return getScoresByFlagType(articleIds, new List<String>{'Contradiction'}, runId);
    }

    /**
     * REFACTORED: Generic private method to handle score calculation for any flag type.
     * This avoids code duplication and centralizes the SOQL logic.
     */
    private static Map<String, Decimal> getScoresByFlagType(List<String> articleIds, List<String> flagTypes, Id runId) {
        Map<String, Decimal> scoresMap = new Map<String, Decimal>();
        if (articleIds == null || articleIds.isEmpty()) return scoresMap;

        // Initialize all IDs with a default score of 100
        for (String id : articleIds) {
            scoresMap.put(id, 100.0);
        }

        // Convert to Set for O(1) lookups during the loop
        Set<String> targetIds = new Set<String>(articleIds);

 // exclude ALL user-discarded statuses (shared constant so this
        // stays in lockstep with the Action Center queue, Explorer, and scorers).
        Set<String> discardedStatuses = KBAssessmentModels.DISCARDED_STATUSES;

        List<Duplicate_Candidate__c> candidates;
        if (runId != null) {
            candidates = [
                SELECT Knowledge_Article_1__c, Knowledge_Article_2__c, Confidence_Score__c
                FROM Duplicate_Candidate__c
                WHERE Assessment_Run__c = :runId
                AND (Knowledge_Article_1__c IN :targetIds OR Knowledge_Article_2__c IN :targetIds)
                AND Flag_Type__c IN :flagTypes
                AND Status__c NOT IN :discardedStatuses
            ];
        } else {
            candidates = [
                SELECT Knowledge_Article_1__c, Knowledge_Article_2__c, Confidence_Score__c
                FROM Duplicate_Candidate__c
                WHERE (Knowledge_Article_1__c IN :targetIds OR Knowledge_Article_2__c IN :targetIds)
                AND Flag_Type__c IN :flagTypes
                AND Status__c NOT IN :discardedStatuses
            ];
        }

        // Track max confidence per article
        Map<String, Decimal> maxConfidenceMap = new Map<String, Decimal>();
        
        for (Duplicate_Candidate__c dc : candidates) {
            Decimal conf = (dc.Confidence_Score__c != null) ? dc.Confidence_Score__c : 0;
            
            // Check both lookups as the target article could be in either field
            updateMaxMap(maxConfidenceMap, dc.Knowledge_Article_1__c, conf, targetIds);
            updateMaxMap(maxConfidenceMap, dc.Knowledge_Article_2__c, conf, targetIds);
        }

        // Calculate final scores: 100 - maxConfidence
        for (String artId : maxConfidenceMap.keySet()) {
            Decimal calculatedScore = Math.max(0, 100 - maxConfidenceMap.get(artId));
            scoresMap.put(artId, calculatedScore);
        }

        return scoresMap;
    }

    /**
     * Optimization: Added Set<String> targetIds as a parameter to avoid re-creating 
     * the set inside the loop, which was a performance bottleneck.
     */
    private static void updateMaxMap(Map<String, Decimal> maxMap, String artId, Decimal conf, Set<String> targetIds) {
        if (artId != null && targetIds.contains(artId)) {
            Decimal currentMax = maxMap.get(artId);
            if (currentMax == null || conf > currentMax) {
                maxMap.put(artId, conf);
            }
        }
    }

    /**
     * Get all candidates for a single article (convenience wrapper).
     */
    public static List<Duplicate_Candidate__c> getCandidatesForArticle(String articleId) {
        if (String.isBlank(articleId)) return new List<Duplicate_Candidate__c>();
        Map<String, List<Duplicate_Candidate__c>> batch = getBatchCandidates(new List<String>{articleId});
        return batch.containsKey(articleId) ? batch.get(articleId) : new List<Duplicate_Candidate__c>();
    }

    /**
     * Bulkified Candidate Fetching: Useful if you need details for multiple articles at once.
     */
    public static Map<String, List<Duplicate_Candidate__c>> getBatchCandidates(List<String> articleIds) {
        return getBatchCandidates(articleIds, null);
    }

    public static Map<String, List<Duplicate_Candidate__c>> getBatchCandidates(List<String> articleIds, Id runId) {
        Map<String, List<Duplicate_Candidate__c>> results = new Map<String, List<Duplicate_Candidate__c>>();
        if (articleIds == null || articleIds.isEmpty()) return results;

        for (String articleId : articleIds) {
            results.put(articleId, new List<Duplicate_Candidate__c>());
        }

        List<Duplicate_Candidate__c> allCandidates;
        if (runId != null) {
            allCandidates = [
                SELECT Id, Name, Knowledge_Article_1__c, Knowledge_Article_2__c,
                       Article_1_Title__c, Article_2_Title__c, Confidence_Score__c,
                       Flag_Type__c, AI_Reasoning__c, Status__c, Source_Tier__c,
                       Score_Calculated_Date__c, Rejection_Reason__c
                FROM Duplicate_Candidate__c
                WHERE Assessment_Run__c = :runId
                AND (Knowledge_Article_1__c IN :articleIds OR Knowledge_Article_2__c IN :articleIds)
                ORDER BY Confidence_Score__c DESC
            ];
        } else {
            allCandidates = [
                SELECT Id, Name, Knowledge_Article_1__c, Knowledge_Article_2__c,
                       Article_1_Title__c, Article_2_Title__c, Confidence_Score__c,
                       Flag_Type__c, AI_Reasoning__c, Status__c, Source_Tier__c,
                       Score_Calculated_Date__c, Rejection_Reason__c
                FROM Duplicate_Candidate__c
                WHERE Knowledge_Article_1__c IN :articleIds OR Knowledge_Article_2__c IN :articleIds
                ORDER BY Confidence_Score__c DESC
            ];
        }

        for (Duplicate_Candidate__c dc : allCandidates) {
            if (results.containsKey(dc.Knowledge_Article_1__c)) {
                results.get(dc.Knowledge_Article_1__c).add(dc);
            }
            if (results.containsKey(dc.Knowledge_Article_2__c)) {
                results.get(dc.Knowledge_Article_2__c).add(dc);
            }
        }
        return results;
    }
}