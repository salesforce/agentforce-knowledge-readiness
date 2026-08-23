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
 * Clarity Dimension Scorer.
 *
 * Pure LLM-as-judge model:
 *   1. Gate: no body content → score 20, skip LLM.
 *   2. LLM evaluation (Evaluate_Clarity, GPT-5.4) — judges pronoun
 *      ambiguity, jargon bridging, sentence complexity, passive voice,
 *      AND internal contradictions WITHIN this one article (e.g. two
 *      sections giving conflicting reset instructions) in one pass. The LLM
 *      owns the score, the issue text, and the remediation language.
 * Refs,.
 *
 * Within-article contradiction detection lives here, not in the
 * cross-article Conflict scorer: Conflict is article-to-article (pipeline
 * data only); a self-contradiction is a single-article clarity defect that
 * makes a retrieved chunk give the wrong answer in isolation. The LLM emits
 * each contradiction as an ordinary clarityIssues entry, so it flows through
 * the existing issues / issueAnalyses channel with impact — no new free-text
 * is appended to Reasoning__c, keeping the LWC reasoning round-trip (see
 * kbArticleScoreCard) unaffected.
 *
 * Clarity is judged by the LLM, not by deterministic checks (jargon density,
 * ambiguous-reference regex, passive-voice regex, sentence-complexity
 * thresholds) — the LLM handles these in context better than regex.
 */
public with sharing class KBClarityScorer extends KBScorerBase {

    // Score floor when the no-content gate fails.
    @TestVisible
    private static final Decimal GATE_FAIL_SCORE = 20;

    // Fallback score when the LLM call fails at runtime. LLM-disabled-by-config
 // is no longer a path; this only fires from the catch arm below.
    @TestVisible
    private static final Decimal LLM_FAILURE_BASELINE = 60;

    public KBClarityScorer() {
        super();
    }

    public override String getDimensionName() {
        return 'Clarity';
    }

    public override KBAssessmentModels.DimensionScore score(KBAssessmentModels.ArticleWrapper article) {
        return scoreClarity(
            article == null ? null : article.content,
            article == null ? null : article.title,
            article == null ? null : article.summary
        );
    }

    /**
     * @TestVisible 2-arg form preserved for the existing test suite (which
     * supplies content + title primitives). Delegates with a null Summary.
     */
    @TestVisible
    private KBAssessmentModels.DimensionScore scoreClarity(String content, String title) {
        return scoreClarity(content, title, null);
    }

    /**
     * Title and Summary are threaded as their own dedicated LLM inputs (issue
 * never folded into the body Content.
     */
    private KBAssessmentModels.DimensionScore scoreClarity(String content, String title, String summary) {
        KBAssessmentModels.DimensionScore result = new KBAssessmentModels.DimensionScore();

        if (String.isBlank(content)) {
            result.addIssue('BLOCKING: Article has no content to assess for clarity.');
            result.score = GATE_FAIL_SCORE;
            result.reasoning = buildReasoning(result, 'Clarity');
            result.scorerMode = MODE_DETERMINISTIC; // gate-fail skips the LLM
            return result;
        }

        String plainContent = KBAssessmentUtils.stripHtml(content);

        // Try LLM; if it succeeds, its score wins. Otherwise fall back to a
        // baseline score.
        // null is the "no opinion yet" sentinel — distinguishes "LLM didn't
        // produce a score" from "LLM scored 0", so a legitimate worst-case 0
        // from the LLM is preserved while a silent failure correctly falls back.
        result.score = null;

        KBAssessmentModels.ArticleWrapper llmArticle = new KBAssessmentModels.ArticleWrapper();
        llmArticle.title = title;
        llmArticle.summary = summary;
        llmArticle.content = plainContent;
        result = enhanceWithLLM(result, llmArticle);

        if (result.score == null) {
            result.score = LLM_FAILURE_BASELINE;
            result.reasoning = 'Einstein evaluation unavailable for this article — score 60 is a fallback baseline, not a quality assertion.';
            result.scorerMode = MODE_LLM_FALLBACK;
        } else {
            result.reasoning = buildReasoning(result, 'Clarity');
            result.scorerMode = MODE_HYBRID;
        }
        return result;
    }

    // ==================== LLM Enhancement ====================

    /**
     * Single LLM call to Evaluate_Clarity. When the LLM succeeds, its 0-100
     * score becomes the dimension score directly; issues/strengths from the
     * LLM are surfaced as user feedback.
     */
    protected override KBAssessmentModels.DimensionScore enhanceWithLLM(
        KBAssessmentModels.DimensionScore deterministicResult,
        KBAssessmentModels.ArticleWrapper article
    ) {
        if (this.promptService == null) {
            return deterministicResult;
        }
        try {
            PromptTemplateService.LLMEvaluationResult llmResult =
                this.promptService.evaluateClarity(
                    article.title, article.content, article.summary
                );

            if (llmResult == null || !llmResult.success) {
                return deterministicResult;
            }

            Set<String> existingIssues = new Set<String>(deterministicResult.issues);
            // Prefer the parallel issueAnalyses list so impact rides along into
            // KB_Dimension_Analysis__c. Fall back to plain issue strings only
            // when the LLM didn't emit per-issue severity (older response shape,
 // defensive). Items surface verbatim — no source-path prefix.
            if (llmResult.issueAnalyses != null && !llmResult.issueAnalyses.isEmpty()) {
                for (KBAssessmentModels.IssueAnalysis ia : llmResult.issueAnalyses) {
                    if (ia == null || String.isBlank(ia.text)) continue;
                    if (existingIssues.contains(ia.text)) continue;
                    deterministicResult.addIssue(ia.text, ia.impact, ia.effort, ia.priority);
                }
            } else {
                for (String issue : llmResult.issues) {
                    if (String.isNotBlank(issue) && !existingIssues.contains(issue)) {
                        deterministicResult.addIssue(issue);
                    }
                }
            }
            Set<String> existingStrengths = new Set<String>(deterministicResult.strengths);
            for (String strength : llmResult.strengths) {
                if (String.isNotBlank(strength) && !existingStrengths.contains(strength)) {
                    deterministicResult.strengths.add(strength);
                }
            }

            // LLM score wins — it has already judged severity in context.
            deterministicResult.score = llmResult.score;
            return deterministicResult;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Clarity LLM enhancement failed: ' + e.getMessage());
            return deterministicResult;
        }
    }
}
