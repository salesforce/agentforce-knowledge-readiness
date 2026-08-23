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
 * Conflict Dimension Scorer
 * Evaluates: contradictory factual claims across same-topic articles.
 * Reads scores from the 5-tier pipeline via KBPipelineBridgeService
 * (Duplicate_Candidate__c with Flag_Type = 'Contradiction').
 *
 * scoreConflictBulk remains public because KBAssessmentPipelineCallback calls
 * it directly after pipeline finalization with pre-loaded data.
 */
public with sharing class KBConflictScorer extends KBScorerBase {

    public KBConflictScorer() {
        super();
    }

    public override String getDimensionName() {
        return 'Conflict';
    }

    public override KBAssessmentModels.DimensionScore score(KBAssessmentModels.ArticleWrapper article) {
        return scoreConflict(article != null ? article.id : null);
    }

    /**
     * Non-bulk scoring path — queries pipeline bridge for this single article.
     */
    private KBAssessmentModels.DimensionScore scoreConflict(String articleId) {
        if (String.isBlank(articleId)) {
            return new KBAssessmentModels.DimensionScore();
        }
        Decimal pipelineScore = KBPipelineBridgeService.getConflictScore(articleId);
        List<Duplicate_Candidate__c> candidates = KBPipelineBridgeService.getCandidatesForArticle(articleId);
        return buildConflictScore(articleId, pipelineScore, candidates);
    }

    /**
     * Bulk path — accepts pre-loaded pipeline data (0 SOQL).
     * Called by KBAssessmentPipelineCallback after pipeline completes.
     */
    public KBAssessmentModels.DimensionScore scoreConflictBulk(String articleId, Decimal pipelineScore, List<Duplicate_Candidate__c> candidates) {
        return buildConflictScore(articleId, pipelineScore, candidates != null ? candidates : new List<Duplicate_Candidate__c>());
    }

    private KBAssessmentModels.DimensionScore buildConflictScore(String articleId, Decimal pipelineScore, List<Duplicate_Candidate__c> candidates) {
        KBAssessmentModels.DimensionScore result = new KBAssessmentModels.DimensionScore();

        Integer conflictCount = 0;
        for (Duplicate_Candidate__c dc : candidates) {
 // Conflict dimension counts only Contradiction candidates now;
 // the 'Overlap' flag type was retired.— skip ALL discarded
            // rows (incl. the consolidated 'Not a Duplicate') via the shared set.
            if (dc.Flag_Type__c == 'Contradiction'
                && !KBAssessmentModels.DISCARDED_STATUSES.contains(dc.Status__c)) {
                conflictCount++;
                if (conflictCount <= 3) {
                    String otherTitle = dc.Knowledge_Article_1__c == articleId ? dc.Article_2_Title__c : dc.Article_1_Title__c;
                    result.addIssue('Contradicts "' + otherTitle + '" (confidence: ' +
                        (dc.Confidence_Score__c != null ? dc.Confidence_Score__c.setScale(0) : 0) +
                        '%, source: ' + dc.Source_Tier__c + ').');
                }
            }
        }

        if (conflictCount > 3) {
            result.addIssue(conflictCount + ' conflict candidates found — review for inconsistent information.');
        }

        if (conflictCount == 0) {
            result.strengths.add('No conflicting articles detected by the pipeline.');
        }

        result.score = pipelineScore;
        result.reasoning = buildReasoning(result, 'Conflict');
        result.scorerMode = MODE_PIPELINE;
        return result;
    }
}
