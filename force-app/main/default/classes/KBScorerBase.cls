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
 * Virtual base class for all KB scoring dimensions.
 * Provides shared utilities: feedback-based score calculation, reasoning builder,
 * LLM-result merge helper.
 *
 * Each dimension scorer extends this class, overrides score(ArticleWrapper),
 * and (optionally) overrides enhanceWithLLM(DimensionScore, ArticleWrapper)
 * with dimension-specific LLM dispatch logic.
 *
 * LLM mode is mandatory. When the LLM call fails at runtime the
 * scorer falls back to a baseline score via its catch arm — that path is
 * reachable, the "LLM disabled by config" path is not.
 */
public virtual with sharing class KBScorerBase implements KBScorable {

    // Scorer_Mode__c values — the per-article-per-dimension record of how a
    // score was actually computed. This is the source of truth for "did the
    // LLM actually run for this score"; KB_Assessment_Run__c.Used_LLM__c is
    // derived from the presence of MODE_HYBRID rows at finalization.
    public static final String MODE_HYBRID = 'Hybrid';                          // LLM produced the score
    public static final String MODE_LLM_FALLBACK = 'LLM_Fallback_Deterministic'; // LLM attempted, threw/empty → baseline
    public static final String MODE_DETERMINISTIC = 'Deterministic';            // no LLM by design (gate-fail, Freshness)
    public static final String MODE_PIPELINE = 'Pipeline_Default';              // Duplication/Conflict from pipeline data
    public static final String MODE_UNASSESSABLE = 'Unassessable';              // no content body to assess

    protected KB_Scan_Config__c config;
    protected PromptTemplateService promptService;

    public KBScorerBase() {
        this.config = KB_Scan_Config__c.getInstance();
        this.promptService = PromptTemplateService.getInstance();
    }

    /**
     * Score an article for this dimension. Each scorer overrides this.
     */
    public virtual KBAssessmentModels.DimensionScore score(KBAssessmentModels.ArticleWrapper article) {
        return new KBAssessmentModels.DimensionScore();
    }

    /**
     * Returns the dimension name (e.g., 'Structure', 'Clarity'). Each scorer overrides.
     */
    public virtual String getDimensionName() {
        return 'Base';
    }

    // ==================== LLM Seam ====================
    // A dimension opts into LLM scoring by overriding scoringTemplateName() (and
    // evaluationType()). enhanceWithLLM() below then drives the whole call for
    // it — assemble inputs → evaluateArticle → merge → set score — so the three
    // LLM scorers no longer each carry a near-identical enhanceWithLLM override.

    /**
     * The GenAI prompt template this dimension scores against (e.g.
     * 'Evaluate_Structure'). null → this dimension does not call the LLM
     * (deterministic dimensions, or the base class itself); enhanceWithLLM is a
     * no-op passthrough in that case.
     */
    protected virtual String scoringTemplateName() {
        return null;
    }

    /**
     * The evaluation type passed to the response parser and used in the failure
     * message (e.g. 'structure' → "Structure evaluation failed: …").
     */
    protected virtual String evaluationType() {
        return null;
    }

    /**
     * The body content sent to the LLM as Input:Content. Default strips HTML
     * (Clarity / Completeness read plain text); Structure overrides this to send
     * the RAW markup so it can judge headings/lists/tables.
     */
    protected virtual String llmContent(KBAssessmentModels.ArticleWrapper article) {
        return article == null ? null : KBAssessmentUtils.stripHtml(article.content);
    }

    /**
     * Extra Input:* entries a dimension wants to thread into the prompt beyond
     * Title / Summary / Content — e.g. the multilingual Input:Language directive.
     * Default is none. Entries here are passed through verbatim (Content
     * truncation is applied only to Input:Content by evaluateArticle).
     */
    protected virtual Map<String, String> extraLlmInputs(KBAssessmentModels.ArticleWrapper article) {
        return new Map<String, String>();
    }

    /**
     * Shared LLM enhancement for every scoring dimension. When the dimension has
     * a template wired, this assembles the inputs, calls the LLM through the
     * PromptTemplateService seam, and — on success — merges the LLM feedback
     * (issueAnalyses-preferred so per-issue impact rides along; items surfaced
     * verbatim) and lets the LLM's 0-100 score become the dimension score.
     *
     * On no template, no promptService, a failed/empty result, or any thrown
     * exception it returns the deterministic result UNCHANGED (the same
     * instance) — the caller detects the untouched null-score sentinel and
     * applies its own fallback (counting model / baseline).
     */
    protected virtual KBAssessmentModels.DimensionScore enhanceWithLLM(
        KBAssessmentModels.DimensionScore deterministicResult,
        KBAssessmentModels.ArticleWrapper article
    ) {
        if (this.promptService == null || String.isBlank(scoringTemplateName())) {
            return deterministicResult;
        }
        try {
            PromptTemplateService.LLMEvaluationResult llmResult =
                this.promptService.evaluateArticle(
                    scoringTemplateName(),
                    assembleLlmInputs(article),
                    evaluationType()
                );

            if (llmResult == null || !llmResult.success) {
                return deterministicResult;
            }

            // Prefer the parallel issueAnalyses list so impact emitted by the
            // prompt template rides into the analysis records; fall back to plain
            // issue strings only when the LLM didn't emit per-issue severity
            // (older response shape, defensive). Items surface verbatim.
            Set<String> existingIssues = new Set<String>(deterministicResult.issues);
            if (llmResult.issueAnalyses != null && !llmResult.issueAnalyses.isEmpty()) {
                for (KBAssessmentModels.IssueAnalysis ia : llmResult.issueAnalyses) {
                    if (ia == null || String.isBlank(ia.text)) continue;
                    if (existingIssues.contains(ia.text)) continue;
                    deterministicResult.addIssue(ia.text, ia.impact, ia.effort, ia.priority);
                }
            } else if (llmResult.issues != null) {
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
            System.debug(LoggingLevel.ERROR, getDimensionName() + ' LLM enhancement failed: ' + e.getMessage());
            return deterministicResult;
        }
    }

    /**
     * Assembles the Input:* map for evaluateArticle: Title / Summary as their own
     * blank-guarded inputs (never folded into the body), Content from the
     * dimension's llmContent() seam, plus any extraLlmInputs(). Content
     * truncation is owned by PromptTemplateService.evaluateArticle.
     */
    private Map<String, String> assembleLlmInputs(KBAssessmentModels.ArticleWrapper article) {
        String title = article == null ? null : article.title;
        String summary = article == null ? null : article.summary;
        String language = article == null ? null : article.language;

        Map<String, String> inputs = new Map<String, String>{
            'Input:Title' => String.isBlank(title) ? '' : title,
            'Input:Summary' => String.isBlank(summary) ? '' : summary,
            'Input:Content' => llmContent(article)
        };
        // Input:Language drives the per-language scoring directive so a
        // non-English article is judged (and its issues/strengths written)
        // in its own language. If the wrapper carries no language, we EMIT
        // AN EMPTY STRING rather than hardcoding 'en_US' — the templates
        // interpret an empty Input:Language as "unknown" (their LANGUAGE
        // DIRECTIVE degrades gracefully — the LLM picks up cues from the
        // Title/Summary/Content). The old default silently mislabelled every
        // article without a Language field (or built from a projection that
        // omitted it) as English, contradicting the P1 multilingual promise.
        // Callers that KNOW the language should populate ArticleWrapper.language;
        // omitting it means "don't assert a language", not "assume English".
        inputs.put('Input:Language', String.isBlank(language) ? '' : language);

        Map<String, String> extras = extraLlmInputs(article);
        if (extras != null) {
            inputs.putAll(extras);
        }
        return inputs;
    }

    /**
     * Merge an LLM evaluation result into a deterministic score.
     * Deduplicates issues and strengths. LLM-contributed items are surfaced
 * verbatim — no source-path prefix (the prefix was an internal
     * implementation detail, not something a Knowledge Manager needs).
     * Per-issue impact emitted by the LLM (via the prompt template shape —
 * flows through `issueAnalyses` so downstream
     * KB_Dimension_Analysis__c rows can carry severity straight from the model.
     * Recalculates the final score based on merged feedback counts.
     * Safe to call with null/failed llmResult — returns deterministicResult unchanged.
     */
    @TestVisible
    protected KBAssessmentModels.DimensionScore mergeLlmResult(
        KBAssessmentModels.DimensionScore deterministicResult,
        PromptTemplateService.LLMEvaluationResult llmResult
    ) {
        if (llmResult == null || !llmResult.success) {
            return deterministicResult;
        }

        Set<String> existingIssues = new Set<String>(deterministicResult.issues);
        // Prefer the parallel issueAnalyses list when present so impact
        // rides along; fall back to plain issue text otherwise.
        if (llmResult.issueAnalyses != null && !llmResult.issueAnalyses.isEmpty()) {
            for (KBAssessmentModels.IssueAnalysis ia : llmResult.issueAnalyses) {
                if (ia == null || String.isBlank(ia.text)) continue;
                if (existingIssues.contains(ia.text)) continue;
                deterministicResult.addIssue(ia.text, ia.impact, ia.effort, ia.priority);
            }
        } else if (llmResult.issues != null) {
            for (String issue : llmResult.issues) {
                if (!existingIssues.contains(issue) && String.isNotBlank(issue)) {
                    deterministicResult.addIssue(issue);
                }
            }
        }

        Set<String> existingStrengths = new Set<String>(deterministicResult.strengths);
        for (String strength : llmResult.strengths) {
            if (!existingStrengths.contains(strength) && String.isNotBlank(strength)) {
                deterministicResult.strengths.add(strength);
            }
        }

        deterministicResult.score = calculateScoreFromFeedback(
            deterministicResult.strengths.size(),
            deterministicResult.issues.size()
        );
        return deterministicResult;
    }

    /**
     * Calculate score based on the balance of strengths vs issues.
     * Base score 70, +6 per strength (cap +30), -10 per issue (cap -40), range 20-100.
     */
    @TestVisible
    protected Decimal calculateScoreFromFeedback(Integer strengthCount, Integer issueCount) {
        if (strengthCount == 0 && issueCount == 0) {
            return 75;
        }

        Decimal baseScore = 70;
        Decimal strengthBonus = Math.min(strengthCount * 6, 30);
        Decimal issuePenalty = Math.min(issueCount * 10, 40);
        Decimal finalScore = baseScore + strengthBonus - issuePenalty;

        return Math.max(20, Math.min(100, finalScore)).setScale(0);
    }

    /**
     * Build human-readable reasoning from strengths and issues
     */
    @TestVisible
    protected String buildReasoning(KBAssessmentModels.DimensionScore score, String dimension) {
        List<String> parts = new List<String>();

        if (!score.strengths.isEmpty()) {
            parts.add('Strengths: ' + String.join(score.strengths, '; '));
        }
        if (!score.issues.isEmpty()) {
            parts.add('Issues: ' + String.join(score.issues, '; '));
        }

        if (parts.isEmpty()) {
            return dimension + ' meets basic requirements.';
        }

        return String.join(parts, '. ') + '.';
    }

    /**
     * Utility: calculate months since a given datetime
     */
    @TestVisible
    protected Integer getMonthsSince(Datetime dt) {
        if (dt == null) return 0;
        Long daysDiff = Date.today().daysBetween(dt.date());
        return (Integer)Math.abs(daysDiff / 30);
    }
}
