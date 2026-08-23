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
 * Completeness Dimension Scorer.
 *
 * Two-stage scoring:
 *   1. Deterministic gates (hard fails) — title/summary/body presence and basic
 *      title format. Gate failure produces a fixed low score (20) and skips the LLM.
 *   2. LLM evaluation (Evaluate_Completeness) — when gates pass, the LLM judges
 *      content substance, factual density, and summary effectiveness as a
 *      retrieval breadcrumb. The LLM's 0-100 score becomes the dimension score
 *      directly; issues/strengths from both layers are surfaced for user feedback
 *      but do not recalculate the score.
 *   3. Catch-arm fallback (LLM call fails at runtime) — falls back to the
 *      counting model (calculateScoreFromFeedback) using the small set of
 *      gate signals plus link-heavy and data-category checks.
 *
 * What the LLM handles instead of this scorer (not done deterministically):
 *   - Vague/deflection phrase counting — context-dependent, cannot be done by regex.
 *   - Actionable-content / numbered-step heuristics — penalises non-procedural
 *     articles (policies, references) which are equally valid agent content.
 *   - Background-article phrase detection — fires on legitimate openers.
 *   - Generic-title regex (article-N, "FAQ", "Help") — pattern accumulation never
 *     converges; LLM judges informativeness.
 *   - Body word-count minimum — coarse and overlapped with Structure; substance
 *     is judged by the LLM.
 *   - Attachment strength signal — attachments are not indexed by Data Libraries.
 */
public with sharing class KBCompletenessScorer extends KBScorerBase {

    // Score floor when a hard gate fails (no title / summary / body, or unusable title)
    @TestVisible
    private static final Decimal GATE_FAIL_SCORE = 20;

    public KBCompletenessScorer() {
        super();
    }

    public override String getDimensionName() {
        return 'Completeness';
    }

    public override KBAssessmentModels.DimensionScore score(KBAssessmentModels.ArticleWrapper article) {
        Boolean hasSummary = article != null && String.isNotBlank(article.summary);
        Integer categoryCount = (article != null && article.dataCategories != null) ? article.dataCategories : 0;
        return scoreCompleteness(article, hasSummary, false, categoryCount);
    }

    /**
     * @TestVisible convenience wrapper — preserves the 6-arg signature used by
     * unit tests so the existing test suite can keep building inputs as primitives.
     */
    @TestVisible
    private KBAssessmentModels.DimensionScore scoreCompleteness(
        String title,
        String summary,
        String content,
        Boolean hasSummary,
        Boolean hasAttachments,
        Integer categoryCount
    ) {
        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.title = title;
        article.summary = summary;
        article.content = content;
        return scoreCompleteness(article, hasSummary, hasAttachments, categoryCount);
    }

    private KBAssessmentModels.DimensionScore scoreCompleteness(
        KBAssessmentModels.ArticleWrapper article,
        Boolean hasSummary,
        Boolean hasAttachments,
        Integer categoryCount
    ) {
        KBAssessmentModels.DimensionScore result = new KBAssessmentModels.DimensionScore();

        if (article == null) {
            result.addIssue('BLOCKING: No article supplied.');
            result.score = GATE_FAIL_SCORE;
            result.reasoning = buildReasoning(result, 'Completeness');
            return result;
        }

        String title = article.title;
        String summary = article.summary;
        String content = article.content;

        Boolean gateFailed = evaluateGates(title, summary, content, result);

        evaluateDataCategories(categoryCount, result);
        evaluateLinkRatio(content, result);
        evaluateSummaryFormat(title, summary, content, result);

        if (gateFailed) {
            // Hard fail — article is fundamentally not ready. Don't burn an LLM callout.
            result.score = GATE_FAIL_SCORE;
            result.reasoning = buildReasoning(result, 'Completeness');
            result.scorerMode = MODE_DETERMINISTIC; // gate-fail skips the LLM
            return result;
        }

        // Gates pass. Try LLM; if it succeeds, its score wins.
        // Otherwise fall back to the counting model on the deterministic signals.
        // null is the "no opinion yet" sentinel — distinguishes "LLM didn't produce
        // a score" from "LLM scored 0", so a legitimate worst-case 0 from the LLM
        // is preserved while a silent failure correctly falls back.
        result.score = null;
        KBAssessmentModels.ArticleWrapper llmArticle = new KBAssessmentModels.ArticleWrapper();
        llmArticle.title = title;
        llmArticle.summary = summary;
        llmArticle.content = KBAssessmentUtils.stripHtml(String.isBlank(content) ? '' : content);
        result = enhanceWithLLM(result, llmArticle);

        if (result.score == null) {
            // LLM call failed at runtime — fall back to the counting model on the
            // deterministic gate/category/link signals already collected above.
            result.score = calculateScoreFromFeedback(result.strengths.size(), result.issues.size());
            result.scorerMode = MODE_LLM_FALLBACK;
        } else {
            result.scorerMode = MODE_HYBRID;
        }

        result.reasoning = buildReasoning(result, 'Completeness');
        return result;
    }

    // ==================== Gate Evaluation ====================

    /**
     * Evaluates the hard gates (title/summary/body presence + basic title format).
     * Returns true if any blocking gate failed. Issues are appended to result.
     */
    private Boolean evaluateGates(String title, String summary, String content, KBAssessmentModels.DimensionScore result) {
        Boolean gateFailed = false;

        if (String.isBlank(title)) {
            result.addIssue('BLOCKING: No title. Title carries significant embedding weight and is required for retrieval.');
            gateFailed = true;
        } else {
            Integer titleWords = KBAssessmentUtils.countWords(title);
            Integer minTitleLength = config != null && config.Min_Title_Length__c != null
                ? (Integer) config.Min_Title_Length__c : 10;

            if (title.length() < minTitleLength) {
                result.addIssue('BLOCKING: Title is too short (' + title.length() + ' chars, minimum ' + minTitleLength + ').');
                gateFailed = true;
            } else if (titleWords < 3) {
                result.addIssue('BLOCKING: Title has too few words (' + titleWords + '). Titles need to be specific enough to anchor retrieval.');
                gateFailed = true;
            } else if (titleWords > 15) {
                result.addIssue('Title is very long (' + titleWords + ' words). Consider tightening to 5-10 words.');
                // Long title is informational, not blocking.
            } else {
                result.strengths.add('Title format meets length and word-count gates.');
            }
        }

        if (String.isBlank(summary)) {
            result.addIssue('BLOCKING: No summary. Summary is critical for retrieval pre-filtering and embedding quality.');
            gateFailed = true;
        }

        if (String.isBlank(content)) {
            result.addIssue('BLOCKING: Missing body content - article has no substantive content.');
            gateFailed = true;
        }

        return gateFailed;
    }

    // ==================== Deterministic Signals ====================

    /**
     * Data category check. Behaviour depends on Uses_Data_Categories__c —
     * if the org's Knowledge implementation uses data categories (for visibility,
     * scoped retrieval, or governance), missing categories are a scored issue.
     * If categories aren't part of the org's Knowledge model, it's informational only.
     */
    private void evaluateDataCategories(Integer categoryCount, KBAssessmentModels.DimensionScore result) {
        Boolean usesDataCategories = config != null
            && config.Uses_Data_Categories__c == true;
        Integer count = categoryCount == null ? 0 : categoryCount;

        if (count == 0) {
            if (usesDataCategories) {
                result.addIssue('No data categories assigned. Your org uses data categories for Knowledge governance — articles without one may be invisible to the agent or bypass visibility controls.');
            } else {
                // Informational note — not added to issues so it doesn't penalise.
                result.strengths.add('No data categories assigned (informational; data categories are not part of your Knowledge model).');
            }
        } else if (count == 1) {
            result.strengths.add('Data category assigned for retrieval filtering.');
        } else {
            result.strengths.add(count + ' data categories assigned - good for multi-path retrieval.');
        }
    }

    /**
     * Link-heavy ratio. Pure HTML measurement — doesn't require language understanding.
     * >30% link text → issue (the answer lives elsewhere).
     */
    private void evaluateLinkRatio(String content, KBAssessmentModels.DimensionScore result) {
        if (String.isBlank(content)) return;

        String plainContent = KBAssessmentUtils.stripHtml(content);
        Integer wordCount = KBAssessmentUtils.countWords(plainContent);
        if (wordCount <= 0) return;

        Integer linkTextWords = countLinkTextWords(content);
        Decimal linkRatio = Decimal.valueOf(linkTextWords) / wordCount;

        if (linkRatio > 0.30) {
            result.addIssue('Article is link-heavy (' + Math.round(linkRatio * 100) + '% of content is link text). The actual answer appears to live elsewhere - inline the key information.');
        }
        // 15-30% range dropped — too many false positives on legitimate articles
        // with descriptive hyperlinks.
    }

    /**
     * Format-only summary checks (presence is gated above). Catches summary that
     * duplicates the title, the first sentence, or is wildly out of size bounds.
     */
    private void evaluateSummaryFormat(String title, String summary, String content, KBAssessmentModels.DimensionScore result) {
        if (String.isBlank(summary)) return;

        if (String.isNotBlank(title) && summary.equalsIgnoreCase(title)) {
            result.addIssue('Summary is identical to title. Summary should be a genuine 1-2 sentence capture of the answer.');
            return;
        }

        if (String.isNotBlank(content)) {
            List<String> sentences = KBAssessmentUtils.getSentences(KBAssessmentUtils.stripHtml(content));
            if (!sentences.isEmpty() && summary.equalsIgnoreCase(sentences[0])) {
                result.addIssue('Summary appears to be a copy of the first sentence. Write a distinct summary that captures the key answer.');
                return;
            }
        }

        Integer summaryWords = KBAssessmentUtils.countWords(summary);
        if (summaryWords < 10) {
            result.addIssue('Summary is too brief (' + summaryWords + ' words). Aim for 1-2 complete sentences.');
        } else if (summaryWords > 100) {
            result.addIssue('Summary is lengthy (' + summaryWords + ' words). Keep to 1-2 sentences for optimal metadata filtering.');
        } else {
            result.strengths.add('Summary is well-sized.');
        }
    }

    // ==================== LLM Enhancement ====================

    /**
     * Single LLM call to Evaluate_Completeness. When the LLM succeeds, its 0-100
     * score becomes the dimension score directly; the deterministic counting model
     * is bypassed because the LLM has already weighed severity. Issues/strengths
     * from both layers are surfaced as user feedback (does NOT drive the score in
     * this path).
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
                this.promptService.evaluateCompleteness(article.title, article.content, article.summary);

            if (llmResult == null || !llmResult.success) {
                return deterministicResult;
            }

            // Append LLM-contributed feedback (deduped) for user surfacing.
            // Prefer the parallel issueAnalyses list so impact emitted by the
            // prompt template rides into the analysis records rather than being
            // recomputed by the deterministic mappers. Items surface verbatim —
 // no source-path prefix.
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

            // LLM score wins — it has already judged severity. Counting model is bypassed.
            deterministicResult.score = llmResult.score;
            return deterministicResult;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Completeness LLM enhancement failed: ' + e.getMessage());
            return deterministicResult;
        }
    }

    // ==================== Helpers ====================

    private Integer countLinkTextWords(String htmlContent) {
        if (String.isBlank(htmlContent)) return 0;

        Integer totalWords = 0;
        Pattern linkTextPattern = Pattern.compile('<a\\s+[^>]*>([^<]*)</a>');
        Matcher m = linkTextPattern.matcher(htmlContent.toLowerCase());
        while (m.find()) {
            String linkText = m.group(1);
            if (String.isNotBlank(linkText)) {
                totalWords += KBAssessmentUtils.countWords(linkText.trim());
            }
        }
        return totalWords;
    }
}
