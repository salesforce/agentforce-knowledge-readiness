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
 * Structure Dimension Scorer.
 *
 * Two-stage scoring (mirrors KBCompletenessScorer post-):
 *   1. Deterministic gate — articles with no body content score the GATE_FAIL
 *      floor and skip the LLM.
 *   2. LLM evaluation (Evaluate_Structure) — judges chunk self-containment,
 *      structural appropriateness, and topic coherence. The LLM's 0-100
 *      score becomes the dimension score directly.
 *   3. Catch-arm fallback (LLM call fails at runtime) — bottom out at the
 *      gate-pass floor (60) so an org with the LLM transiently down still
 *      produces a plausible score rather than failing closed at 20.
 *
 * What the LLM handles instead of this scorer (not done deterministically):
 *   - Word-count tier thresholds — admin-tunable thresholds were arbitrary,
 *     conflict with the simpler-setup goal, and the LLM judges length-vs-structure
 *     in context better than fixed cuts.
 *   - Q&amp;A format detection — the deterministic check fired on any article
 *     containing a question word plus &quot;solution&quot;/&quot;answer&quot;, which is far too
 *     broad. The LLM judges retrieval-friendliness directly.
 *   - Structured list rewards — counting &lt;ul&gt;/&lt;ol&gt; doesn't measure usefulness;
 *     nested bullets actually hurt chunking when context is lost from the
 *     parent heading.
 *   - Heading presence / vague-heading detection — the LLM sees the HTML and
 *     can judge &quot;Background: PCI Compliance&quot; (descriptive) vs &quot;Notes&quot; (vague)
 *     contextually.
 *   - Topic-shift phrase scanning — hardcoded phrase list (&quot;additionally&quot;,
 *     &quot;moving on to&quot;, etc.) produced false positives on well-written articles
 *     and missed real drift that didn't use those phrases.
 */
public virtual with sharing class KBStructureScorer extends KBScorerBase {

    // Score floor when the no-content gate fails (article has no body).
    @TestVisible
    private static final Decimal GATE_FAIL_SCORE = 20;

    // Fallback score when the LLM call fails at runtime. Reflects
    // "structurally indeterminate, not failing" — the deterministic checks the
    // old scorer used were dropped because they didn't reliably predict
    // chunkability, so without the LLM there's nothing left to differentiate
    // articles. Pinning to a mid-range default avoids bottoming out at 20
    // when the LLM is transiently unavailable.
    @TestVisible
    private static final Decimal LLM_FAILURE_SCORE = 60;

    public KBStructureScorer() {
        super();
    }

    public override String getDimensionName() {
        return 'Structure';
    }

    public override KBAssessmentModels.DimensionScore score(KBAssessmentModels.ArticleWrapper article) {
        return scoreStructure(
            article == null ? null : article.content,
            article == null ? null : article.title,
            article == null ? null : article.summary,
            article == null ? null : article.language
        );
    }

    /**
     * @TestVisible 2-arg form preserved for the existing test suite (which
     * supplies content + title primitives). Delegates with a null Summary/Language.
     */
    @TestVisible
    private KBAssessmentModels.DimensionScore scoreStructure(String htmlContent, String title) {
        return scoreStructure(htmlContent, title, null, null);
    }

    /**
     * Title and Summary are threaded as their own dedicated LLM inputs — never
     * folded into the body Content. Language drives the per-language scoring
     * directive so a non-English article is judged in its own language.
     */
    private KBAssessmentModels.DimensionScore scoreStructure(String htmlContent, String title, String summary, String language) {
        KBAssessmentModels.DimensionScore result = new KBAssessmentModels.DimensionScore();

        if (String.isBlank(htmlContent)) {
            result.addIssue('BLOCKING: Article has no content to assess for structure.');
            result.score = GATE_FAIL_SCORE;
            result.reasoning = buildReasoning(result, 'Structure');
            result.scorerMode = MODE_DETERMINISTIC; // gate-fail skips the LLM
            return result;
        }

        // Gate passes. Try LLM; if it succeeds, its score wins. Otherwise
        // bottom out at LLM_FAILURE_SCORE — see field comment above.
        // null is the "no opinion yet" sentinel — distinguishes "LLM didn't
        // produce a score" from "LLM scored 0", so a legitimate worst-case 0
        // from the LLM is preserved while a silent failure correctly falls back.
        result.score = null;

        KBAssessmentModels.ArticleWrapper llmArticle = new KBAssessmentModels.ArticleWrapper();
        llmArticle.title = title;
        llmArticle.summary = summary;
        llmArticle.content = htmlContent;
        llmArticle.language = language;
        result = enhanceWithLLM(result, llmArticle);

        if (result.score == null) {
            result.score = LLM_FAILURE_SCORE;
            result.reasoning = 'Einstein evaluation unavailable for this article — score 60 is a fallback baseline, not a quality assertion.';
            result.scorerMode = MODE_LLM_FALLBACK;
        } else {
            result.reasoning = buildReasoning(result, 'Structure');
            result.scorerMode = MODE_HYBRID;
        }
        return result;
    }

    // ==================== LLM Seam ====================
    // The call/merge/score flow lives in KBScorerBase.enhanceWithLLM; this
    // dimension only declares which template it scores against and that its
    // LLM input is the RAW HTML markup (headings/lists/tables), not stripped.

    protected override String scoringTemplateName() {
        return 'Evaluate_Structure';
    }

    protected override String evaluationType() {
        return 'structure';
    }

    /**
     * Structure judges the RAW HTML markup, so — unlike Clarity / Completeness —
     * the body must NOT be stripped before it reaches the LLM.
     */
    protected override String llmContent(KBAssessmentModels.ArticleWrapper article) {
        return article == null ? null : article.content;
    }
}
