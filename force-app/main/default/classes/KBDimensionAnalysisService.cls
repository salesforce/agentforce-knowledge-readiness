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
 * Builds KB_Dimension_Analysis__c records from scoring output.
 *
 * One row per individual issue or strength identified by a scorer for a given
 * (article assessment, dimension). Intended to be the normalized successor to
 * the older KB_Recommendation__c rows (issue-only) — for both objects
 * are written in parallel; will swap reads to this object and remove
 * the legacy one.
 *
 * KB_Dimension_Analysis__c is master-detail on KB_Dimension_Result__c, so
 * callers must insert dimension result rows first and then pass the resulting
 * Ids alongside the article assessment Id.
 */
public with sharing class KBDimensionAnalysisService {

    public static final String TYPE_ISSUE = 'Issue';
    public static final String TYPE_STRENGTH = 'Strength';

    private static final Integer ANALYSIS_TEXT_MAX = 32000;
    private static final Integer RECOMMENDATION_MAX = 32768;
    private static final Integer DIM_NAME_MAX = 80;

    // Whitelist for the restricted Impact__c picklist on KB_Dimension_Analysis__c.
    // The LLM is asked to pick from these values, but it sometimes drifts
    // (e.g. "Critical", "very high", "None", trailing whitespace). Any drift
    // value would fail the whole insert with INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST.
    // Normalise off-list values to null so the row still inserts and the
    // unsevered text remains visible to the author.
    //
    // Effort + Priority were dropped from the scoring-path severity model
 // the fix is done by AI (effectively zero human effort) and
    // the LLM can't reliably judge a human's effort, so the scoring prompts no
    // longer request them and this builder no longer writes Effort__c /
    // Priority__c. Impact is retained — it mirrors the score deduction. The
    // schema fields remain deployed (a separate destructive pass can drop them).
    @TestVisible
    private static final Set<String> VALID_IMPACT = new Set<String>{
        'High', 'Medium', 'Low'
    };

    /**
     * Coerce an LLM-emitted severity value to a valid picklist entry, or null.
     * Trim, exact-match against the whitelist (case-sensitive — the picklist
     * is too); if unmatched, try a case-insensitive lookup so common drift
     * like "high" → "High" still survives. Anything else returns null.
     */
    private static String coercePicklist(String raw, Set<String> valid) {
        if (String.isBlank(raw)) return null;
        String trimmed = raw.trim();
        if (valid.contains(trimmed)) return trimmed;
        for (String v : valid) {
            if (v.equalsIgnoreCase(trimmed)) return v;
        }
        return null;
    }

    /**
     * Build Issue + Strength rows for a single dimension.
     *
     * @param dimensionResultId    KB_Dimension_Result__c.Id (master-detail). Required.
     * @param articleAssessmentId  KB_Article_Assessment__c.Id (denormalized). Optional.
     * @param dimension            Dimension DeveloperName.
     * @param dimensionScore       Score wrapper carrying issues + strengths.
     */
    public static List<KB_Dimension_Analysis__c> buildForDimension(
        Id dimensionResultId,
        Id articleAssessmentId,
        String dimension,
        KBAssessmentModels.DimensionScore dimensionScore
    ) {
        List<KB_Dimension_Analysis__c> rows = new List<KB_Dimension_Analysis__c>();
        if (dimensionScore == null) return rows;

        String dim = truncate(dimension, DIM_NAME_MAX);

        // Impact is LLM-driven for every dimension except Freshness (issue
 // Effort + Priority are no longer written on either path (issue
 // Freshness keeps its deterministic recommendation mapper
        // because calendar-age issues all collapse to the same advice; its
        // Impact stays null (calendar age is a fact, not a severity judgement).
        Boolean useLlmSeverity = !'Freshness'.equalsIgnoreCase(dimension);

        if (dimensionScore.issues != null && !dimensionScore.issues.isEmpty()) {
            Set<String> seen = new Set<String>();
            for (Integer i = 0; i < dimensionScore.issues.size(); i++) {
                String issue = dimensionScore.issues.get(i);
                if (String.isBlank(issue)) continue;
                String analysisText = truncate(issue, ANALYSIS_TEXT_MAX);
                if (seen.contains(analysisText)) continue;
                seen.add(analysisText);

                KBAssessmentModels.IssueAnalysis ia = (useLlmSeverity
                        && dimensionScore.issueAnalyses != null
                        && i < dimensionScore.issueAnalyses.size())
                    ? dimensionScore.issueAnalyses.get(i)
                    : null;

                // For non-Freshness rows the LLM is the sole source of truth for
                // Impact — if it omits a value we leave the field blank rather
                // than fabricating one. Freshness uses the deterministic
                // recommendation mapper and leaves Impact null.
                String impact;
                String recommendation;
                if (useLlmSeverity) {
                    impact         = coercePicklist(ia != null ? ia.impact : null, VALID_IMPACT);
                    recommendation = issue;
                } else {
                    impact         = null;
                    recommendation = KBRecommendationService.mapIssueToRecommendation(dimension, issue);
                }

                KB_Dimension_Analysis__c row = new KB_Dimension_Analysis__c(
                    Dimension_Result__c   = dimensionResultId,
                    Article_Assessment__c = articleAssessmentId,
                    Type__c               = TYPE_ISSUE,
                    Dimension__c          = dim,
                    Analysis_Text__c      = analysisText,
                    Recommendation__c     = truncate(recommendation, RECOMMENDATION_MAX),
                    Impact__c             = impact,
                    Status__c             = 'Open'
                );
                rows.add(row);
            }
        }

        if (dimensionScore.strengths != null && !dimensionScore.strengths.isEmpty()) {
            Set<String> seenStrengths = new Set<String>();
            for (String strength : dimensionScore.strengths) {
                if (String.isBlank(strength)) continue;
                String analysisText = truncate(strength, ANALYSIS_TEXT_MAX);
                if (seenStrengths.contains(analysisText)) continue;
                seenStrengths.add(analysisText);

                rows.add(new KB_Dimension_Analysis__c(
                    Dimension_Result__c   = dimensionResultId,
                    Article_Assessment__c = articleAssessmentId,
                    Type__c               = TYPE_STRENGTH,
                    Dimension__c          = dim,
                    Analysis_Text__c      = analysisText,
                    Status__c             = 'Open'
                ));
            }
        }

        return rows;
    }

    private static String truncate(String text, Integer maxLength) {
        if (text == null) return null;
        if (text.length() <= maxLength) return text;
        return text.substring(0, maxLength);
    }
}
