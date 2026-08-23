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
@IsTest
public class MockPromptTemplateService extends PromptTemplateService {

    public PromptTemplateService.DraftEvaluationResult mockDraftResult;
    public PromptTemplateService.AnomalyEvaluationResult mockAnomalyResult;
    public Boolean throwException = false;
    public Integer draftCallCount = 0;
    public Integer anomalyCallCount = 0;

    public override PromptTemplateService.DraftEvaluationResult evaluateDraft(
        String draftText,
        List<VectorSearchResult> similarArticles
    ) {
        draftCallCount++;
        if (throwException) {
            throw new KnowledgeAIException('Mock LLM error');
        }
        return mockDraftResult;
    }

    public override PromptTemplateService.AnomalyEvaluationResult evaluatePublishedPair(
        String articleAText,
        String articleBText,
        String articleAId,
        String articleBId
    ) {
        anomalyCallCount++;
        if (throwException) {
            throw new KnowledgeAIException('Mock LLM error');
        }
        return mockAnomalyResult;
    }

    // Readiness scoring methods
    public PromptTemplateService.LLMEvaluationResult mockLLMResult;
    public Integer structureCallCount = 0;
    public Integer clarityCallCount = 0;
    public Integer completenessCallCount = 0;

    private PromptTemplateService.LLMEvaluationResult getDefaultMockLLMResult() {
        if (mockLLMResult != null) {
            return mockLLMResult;
        }
        PromptTemplateService.LLMEvaluationResult r = new PromptTemplateService.LLMEvaluationResult();
        r.score = 75;
        r.reasoning = 'Mock evaluation';
        r.success = true;
        return r;
    }

    // Captured arguments from the most recent evaluateStructure call so tests
 // can assert Title + Summary were wired through as their own inputs.
    public String lastStructureTitle;
    public String lastStructureSummary;

    public override PromptTemplateService.LLMEvaluationResult evaluateStructure(String title, String content, String summary) {
        structureCallCount++;
        lastStructureTitle = title;
        lastStructureSummary = summary;
        if (throwException) { throw new KnowledgeAIException('Mock structure error'); }
        return getDefaultMockLLMResult();
    }

    // Captured arguments from the most recent evaluateClarity call so tests
    // can assert Title/Summary were wired through.
    public String lastClarityTitle;
    public String lastClaritySummary;

    public override PromptTemplateService.LLMEvaluationResult evaluateClarity(
        String title,
        String content,
        String summary
    ) {
        clarityCallCount++;
        lastClarityTitle = title;
        lastClaritySummary = summary;
        if (throwException) { throw new KnowledgeAIException('Mock clarity error'); }
        return getDefaultMockLLMResult();
    }

    public override PromptTemplateService.LLMEvaluationResult evaluateCompleteness(String title, String structuredContent, String summary) {
        completenessCallCount++;
        if (throwException) { throw new KnowledgeAIException('Mock completeness error'); }
        return getDefaultMockLLMResult();
    }

    public PromptTemplateService.FixArticleResult mockFixArticleResult;
    public Integer fixArticleCallCount = 0;
    public String fixArticleLastIssuesList;
    public String fixArticleLastStrengthsList;
    public override PromptTemplateService.FixArticleResult fixArticleIssues(
        Map<String, String> articleFields, Map<String, Integer> fieldLimits,
        String issuesList, String strengthsList, String language
    ) {
        fixArticleCallCount++;
        fixArticleLastIssuesList    = issuesList;
        fixArticleLastStrengthsList = strengthsList;
        if (throwException) { throw new KnowledgeAIException('Mock fix error'); }
        if (mockFixArticleResult != null) { return mockFixArticleResult; }
        PromptTemplateService.FixArticleResult r = new PromptTemplateService.FixArticleResult();
        r.rewrittenFields = articleFields.clone();
        r.changesSummary = 'Mock fix applied';
        return r;
    }

 // shared consolidate (fix N=1 / merge N>1). Records the inputs so
    // tests can assert findings were threaded in; echoes a merged field map.
    public Integer consolidateCallCount = 0;
    public List<PromptTemplateService.ArticleInput> consolidateLastArticles;
    public PromptTemplateService.FixArticleResult mockConsolidateResult;
    public override PromptTemplateService.FixArticleResult consolidateArticles(
        List<PromptTemplateService.ArticleInput> articles,
        Map<String, Integer> fieldLimits,
        String language
    ) {
        consolidateCallCount++;
        consolidateLastArticles = articles;
        if (throwException) { throw new KnowledgeAIException('Mock consolidate error'); }
        if (mockConsolidateResult != null) { return mockConsolidateResult; }
        PromptTemplateService.FixArticleResult r = new PromptTemplateService.FixArticleResult();
        // Echo the first article's fields as the "merged" result so callers get
        // a non-empty field map (mirrors the real shape).
        r.rewrittenFields = (articles != null && !articles.isEmpty() && articles[0].fields != null)
            ? articles[0].fields.clone() : new Map<String, String>();
        r.changesSummary = 'Mock consolidate applied';
        return r;
    }

    // Tier 3: Triage
    public PromptTemplateService.TriageResult mockTriageResult;
    public Integer triageCallCount = 0;

    public override PromptTemplateService.TriageResult triageDuplicateCandidates(
        String targetTitle,
        String targetSummary,
        List<PromptTemplateService.CandidateSummary> candidates
    ) {
        triageCallCount++;
        if (throwException) {
            throw new KnowledgeAIException('Mock triage error');
        }
        return mockTriageResult;
    }

    // Tier 4: Fact extraction
    public String mockExtractedFacts = '- Fact 1\n- Fact 2';
    public Integer extractFactsCallCount = 0;
    // Every chunk text this mock has been asked to extract facts from, in call
    // order — lets tests assert WHICH content reached the LLM, not just how
    // many calls happened (e.g. proving a long article's tail wasn't dropped).
    public List<String> extractedChunkTexts = new List<String>();

    public override String extractArticleFacts(String articleChunkText) {
        extractFactsCallCount++;
        extractedChunkTexts.add(articleChunkText);
        if (throwException) {
            throw new KnowledgeAIException('Mock extract facts error');
        }
        return mockExtractedFacts;
    }

    // Tier 4: Fact evaluation
    public PromptTemplateService.FactEvaluationResult mockFactEvalResult;
    public Integer factEvalCallCount = 0;

    public override PromptTemplateService.FactEvaluationResult evaluateExtractedFacts(
        String factsA,
        String factsB
    ) {
        factEvalCallCount++;
        if (throwException) {
            throw new KnowledgeAIException('Mock fact eval error');
        }
        return mockFactEvalResult;
    }

    // Tier 4: Merged article draft
    public String mockMergedContent = '<h2>Merged Article</h2><p>Combined content.</p>';
    public Integer mergeCallCount = 0;

    public override String draftMergedArticle(
        String article1Text,
        String article2Text,
        String language
    ) {
        mergeCallCount++;
        if (throwException) {
            throw new KnowledgeAIException('Mock merge error');
        }
        return mockMergedContent;
    }

    // Issue severity annotation
    public List<PromptTemplateService.IssueSeverityAnnotation> mockSeverityAnnotations;
    public Integer annotateSeverityCallCount = 0;
    public Integer annotateSeverityLastIssueCount;
    public List<String> annotateSeverityLastStrengths;
    public String annotateSeverityLastArticleContent;
    public String annotateSeverityLastCounterpartContent;

    public override List<PromptTemplateService.IssueSeverityAnnotation> annotateIssueSeverity(
        String articleTitle,
        String articleSummary,
        String articleContent,
        String counterpartTitle,
        String counterpartSummary,
        String counterpartContent,
        List<String> issues,
        List<String> strengths
    ) {
        annotateSeverityCallCount++;
        annotateSeverityLastIssueCount = (issues == null) ? 0 : issues.size();
        annotateSeverityLastStrengths = strengths;
        annotateSeverityLastArticleContent = articleContent;
        annotateSeverityLastCounterpartContent = counterpartContent;
        if (throwException) {
            // Match production behaviour: swallow + return empty rather than throw
            return new List<PromptTemplateService.IssueSeverityAnnotation>();
        }
        if (mockSeverityAnnotations != null) {
            return mockSeverityAnnotations;
        }
        // Default: annotate every issue with neutral severity so callers exercise the wiring.
        List<PromptTemplateService.IssueSeverityAnnotation> defaults =
            new List<PromptTemplateService.IssueSeverityAnnotation>();
        if (issues != null) {
            for (Integer i = 0; i < issues.size(); i++) {
                PromptTemplateService.IssueSeverityAnnotation a =
                    new PromptTemplateService.IssueSeverityAnnotation();
                a.index = i;
                a.impact = 'Medium';
                defaults.add(a);
            }
        }
        return defaults;
    }

}
