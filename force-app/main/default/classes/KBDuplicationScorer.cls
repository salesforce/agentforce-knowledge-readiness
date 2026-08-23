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
 * Duplication Dimension Scorer
 * Evaluates: semantic overlap across the article set.
 * Reads scores from the 5-tier pipeline via KBPipelineBridgeService.
 * Score = 100 - pipeline confidence.
 *
 * scoreDuplicationBulk remains public because KBAssessmentPipelineCallback
 * calls it directly after pipeline finalization with pre-loaded data.
 */
public with sharing class KBDuplicationScorer extends KBScorerBase {

    public KBDuplicationScorer() {
        super();
    }

    public override String getDimensionName() {
        return 'Duplication';
    }

    public override KBAssessmentModels.DimensionScore score(KBAssessmentModels.ArticleWrapper article) {
        return scoreDuplication(article != null ? article.id : null);
    }

    /**
     * Non-bulk scoring path — queries pipeline bridge for this single article.
     */
    private KBAssessmentModels.DimensionScore scoreDuplication(String articleId) {
        if (String.isBlank(articleId)) {
            return new KBAssessmentModels.DimensionScore();
        }
        Decimal pipelineScore = KBPipelineBridgeService.getDuplicationScore(articleId);
        List<Duplicate_Candidate__c> candidates = KBPipelineBridgeService.getCandidatesForArticle(articleId);
        return buildDuplicationScore(articleId, pipelineScore, candidates);
    }

    /**
     * Bulk path — accepts pre-loaded pipeline data (0 SOQL).
     * Called by KBAssessmentPipelineCallback after pipeline completes.
     */
    public KBAssessmentModels.DimensionScore scoreDuplicationBulk(String articleId, Decimal pipelineScore, List<Duplicate_Candidate__c> candidates) {
        return buildDuplicationScore(articleId, pipelineScore, candidates != null ? candidates : new List<Duplicate_Candidate__c>());
    }

    private KBAssessmentModels.DimensionScore buildDuplicationScore(String articleId, Decimal pipelineScore, List<Duplicate_Candidate__c> candidates) {
        KBAssessmentModels.DimensionScore result = new KBAssessmentModels.DimensionScore();

        Integer dupCount = 0;
        for (Duplicate_Candidate__c dc : candidates) {
            if (dc.Flag_Type__c == 'Duplicate' && !KBAssessmentModels.DISCARDED_STATUSES.contains(dc.Status__c)) {
                dupCount++;
                if (dupCount <= 3) {
                    String otherTitle = dc.Knowledge_Article_1__c == articleId ? dc.Article_2_Title__c : dc.Article_1_Title__c;
                    result.addIssue('Potential duplicate of "' + otherTitle + '" (confidence: ' +
                        (dc.Confidence_Score__c != null ? dc.Confidence_Score__c.setScale(0) : 0) +
                        '%, source: ' + dc.Source_Tier__c + ').');
                }
            }
        }

        if (dupCount > 3) {
            result.addIssue(dupCount + ' duplicate candidates found — this article may need consolidation.');
        }

        if (dupCount == 0) {
            result.strengths.add('No duplicate articles detected by the deduplication pipeline.');
        }

        result.score = pipelineScore;
        result.reasoning = buildReasoning(result, 'Duplication');
        result.scorerMode = MODE_PIPELINE;
        return result;
    }
}
