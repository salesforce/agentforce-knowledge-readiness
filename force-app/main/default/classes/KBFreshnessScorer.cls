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
 * Freshness Dimension Scorer
 * Evaluates: article age based on LastModifiedDate vs configurable staleness thresholds.
 * Deterministic only — no LLM enhancement.
 *
 * Thresholds from KB_Scan_Config__c:
 * - Freshness_Threshold_Months__c (default 12): articles older than this are penalised
 * - Freshness_Critical_Months__c  (default 24): articles older than this score very low
 */
public with sharing class KBFreshnessScorer extends KBScorerBase {

    public KBFreshnessScorer() {
        super();
    }

    public override String getDimensionName() {
        return 'Freshness';
    }

    public override KBAssessmentModels.DimensionScore score(KBAssessmentModels.ArticleWrapper article) {
        return scoreFreshness(article.lastModifiedDate);
    }

    @TestVisible
    private KBAssessmentModels.DimensionScore scoreFreshness(Datetime lastModifiedDate) {
        KBAssessmentModels.DimensionScore result = new KBAssessmentModels.DimensionScore();

        Integer thresholdMonths = config != null && config.Freshness_Threshold_Months__c != null
            ? (Integer)config.Freshness_Threshold_Months__c : 12;
        Integer criticalMonths = config != null && config.Freshness_Critical_Months__c != null
            ? (Integer)config.Freshness_Critical_Months__c : 24;

        if (lastModifiedDate == null) {
            result.score = 50;
            result.addIssue('No modification date available - cannot assess freshness.');
            result.reasoning = buildReasoning(result, 'Freshness');
            result.scorerMode = MODE_DETERMINISTIC;
            return result;
        }

        Integer monthsSince = getMonthsSince(lastModifiedDate);

        if (monthsSince > criticalMonths) {
            result.addIssue('CRITICAL: Article is severely outdated (' + monthsSince + ' months since last update). Outdated content risks providing incorrect answers and causing hallucinations.');
            result.addIssue('Article has not been reviewed in over ' + criticalMonths + ' months. Immediate review recommended.');
        } else if (monthsSince > thresholdMonths) {
            result.addIssue('Article is stale (' + monthsSince + ' months since last update). Content older than ' + thresholdMonths + ' months should be reviewed for accuracy.');
        } else if (monthsSince > 6) {
            result.strengths.add('Article was updated within the last year (' + monthsSince + ' months ago).');
        } else if (monthsSince > 1) {
            result.strengths.add('Article is fresh (updated ' + monthsSince + ' months ago).');
        } else {
            result.strengths.add('Article is very fresh (updated within the last month).');
        }

        result.score = calculateScoreFromFeedback(result.strengths.size(), result.issues.size());
        result.reasoning = buildReasoning(result, 'Freshness');
        result.scorerMode = MODE_DETERMINISTIC;
        return result;
    }
}
