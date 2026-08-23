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
 * Scoring dispatcher. Data-driven: every dispatch looks up the scorer class
 * via DimensionRegistry and instantiates through Type.forName(). Adding a
 * new dimension = deploy one KB_Scoring_Dimension__mdt record pointing to a
 * new KBScorable implementation.
 */
public with sharing class KBScoringService {

    private Map<String, KBScorable> scorerCache;

    public KBScoringService() {
        this.scorerCache = new Map<String, KBScorable>();
        List<String> validationErrors = DimensionRegistry.validate();
        if (!validationErrors.isEmpty()) {
            System.debug(LoggingLevel.ERROR,
                'DimensionRegistry validation failed: ' + String.join(validationErrors, '; '));
        }
    }

    /**
     * Score a single article for the requested dimensions. Pipeline-data
     * dimensions (Duplication/Conflict today) prefer pre-loaded scores /
     * candidates so the caller can amortise pipeline reads across a batch.
     *
     * Unselected dimensions are not touched — their scoresByDim entry stays
     * null, signalling "not assessed" to aggregation.
     */
    public KBAssessmentModels.ArticleAssessmentResult scoreDimensions(
        KBAssessmentModels.ArticleWrapper article,
        Set<String> selectedDimensions,
        Decimal dupPipelineScore,
        Decimal conflictPipelineScore,
        List<Duplicate_Candidate__c> candidates
    ) {
        KBAssessmentModels.ArticleAssessmentResult result = new KBAssessmentModels.ArticleAssessmentResult();
        if (article == null) return result;

        result.articleId = article.id;
        result.articleTitle = String.isNotBlank(article.title) ? article.title : 'Untitled Article';
        result.articleNumber = article.articleNumber;
        result.knowledgeArticleId = article.knowledgeArticleId;

        Set<String> selected = (selectedDimensions == null || selectedDimensions.isEmpty())
            ? DimensionRegistry.getActiveDeveloperNames()
            : selectedDimensions;

        String plainContent = KBAssessmentUtils.stripHtml(article.content);
        Boolean hasContent = String.isNotBlank(plainContent) && plainContent.trim().length() > 10;
        List<Duplicate_Candidate__c> safeCandidates = candidates != null ? candidates : new List<Duplicate_Candidate__c>();

        for (String dimName : selected) {
            DimensionRegistry.DimensionDefinition def = DimensionRegistry.get(dimName);
            if (def == null || !def.isActive) continue;

            KBAssessmentModels.DimensionScore score = scoreOneDimension(
                def, article, hasContent, dupPipelineScore, conflictPipelineScore, safeCandidates
            );
            if (score != null) {
                result.setScore(dimName, score);
            }
        }

        return result;
    }

    private KBAssessmentModels.DimensionScore scoreOneDimension(
        DimensionRegistry.DimensionDefinition def,
        KBAssessmentModels.ArticleWrapper article,
        Boolean hasContent,
        Decimal dupPipelineScore,
        Decimal conflictPipelineScore,
        List<Duplicate_Candidate__c> candidates
    ) {
        // Structure and Clarity require body content — other dimensions still run
        if (!hasContent && def.requiresLLM) {
            return buildNoContentScore();
        }

        KBScorable scorer = getScorer(def);
        if (scorer == null) return null;

        Long startMs = System.currentTimeMillis();
        KBAssessmentModels.DimensionScore result;

        // Pipeline dimensions have bulk APIs that take pre-loaded data.
        // Fall back to the polymorphic score() if no bulk data is present.
        if (def.requiresPipelineData) {
            if (scorer instanceof KBDuplicationScorer && dupPipelineScore != null) {
                result = ((KBDuplicationScorer) scorer).scoreDuplicationBulk(article.id, dupPipelineScore, candidates);
            } else if (scorer instanceof KBConflictScorer && conflictPipelineScore != null) {
                result = ((KBConflictScorer) scorer).scoreConflictBulk(article.id, conflictPipelineScore, candidates);
            } else {
                result = scorer.score(article);
            }
        } else {
            result = scorer.score(article);
        }

        if (result != null) {
            result.executionMs = System.currentTimeMillis() - startMs;
        }
        return result;
    }

    /**
     * Instantiate (and cache) the scorer for a dimension via Type.forName().
     * Returns null if the CMDT points to a non-existent or non-KBScorable class.
     */
    private KBScorable getScorer(DimensionRegistry.DimensionDefinition def) {
        if (def == null || String.isBlank(def.scorerClass)) return null;
        if (this.scorerCache.containsKey(def.developerName)) {
            return this.scorerCache.get(def.developerName);
        }

        Type t = Type.forName(def.scorerClass);
        if (t == null) {
            System.debug(LoggingLevel.ERROR,
                'KBScoringService: scorer class "' + def.scorerClass +
                '" not found for dimension ' + def.developerName);
            return null;
        }
        Object instance;
        try {
            instance = t.newInstance();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'KBScoringService: failed to instantiate ' + def.scorerClass + ': ' + e.getMessage());
            return null;
        }
        if (!(instance instanceof KBScorable)) {
            System.debug(LoggingLevel.ERROR,
                'KBScoringService: class ' + def.scorerClass + ' does not implement KBScorable');
            return null;
        }

        KBScorable scorer = (KBScorable) instance;
        this.scorerCache.put(def.developerName, scorer);
        return scorer;
    }

    private KBAssessmentModels.DimensionScore buildNoContentScore() {
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = null;
        s.isUnassessable = true;
        s.issues.add('Unable to assess: Article has no content body.');
        s.reasoning = 'Issues: Unable to assess: Article has no content body.';
        s.scorerMode = KBScorerBase.MODE_UNASSESSABLE;
        return s;
    }
}
