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
 * Service wrapping Einstein Prompt Builder invocations via native ConnectApi.
 * Isolates LLM dependencies for testability via mock injection.
 *
 * Uses ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate().
 *
 * Expected Prompt Builder Templates (configured in UI):
 * - Draft_Evaluator: Accepts draftText + similarChunks, returns JSON with hasConflict and conflicts array
 * - Published_Anomaly_Evaluator: Accepts articleAText + articleBText, returns JSON with isAnomaly, anomalyType, reasoning
 * - Triage_Duplicate_Candidates: Accepts TargetTitle + TargetSummary + CandidateList, returns top_candidates positional indexes
 * - Extract_Article_Facts: Accepts TextChunk, returns bulleted fact list
 * - Evaluate_Extracted_Facts: Accepts ArticleA_State + ArticleB_State, returns is_duplicate + confidence_score + reasoning
 * - Draft_Merged_Knowledge_Article: Accepts Article1_Text + Article2_Text, returns merged article content
 */
public virtual class PromptTemplateService {

    private static PromptTemplateService instance;

    /**
     * Temperature applied to SCORING prompt invocations to pin run-to-run
 * determinism. Scoring re-runs on the same article should not drift
     * by a few points each time — that erodes reviewer trust and makes
     * smoke-test calibration harder. We set this as low as the platform allows
     * (0.0) so the model deviates only when it has to for safety / JSON shape.
     *
     * Tunable: the issue notes "expect trial and error" — bump this if a future
     * scoring template needs a little headroom. Drafting / rewriting templates
     * deliberately do NOT get this — low temperature there produces robotic
     * prose, so they keep the platform default.
     */
    @TestVisible
    private static final Double SCORING_TEMPERATURE = 0.0;

    /**
     * The template api names that must run at SCORING_TEMPERATURE.
     *
     * RULE: every EVALUATION / JUDGEMENT call is pinned to a low temperature
     * for run-to-run determinism — not just the article-readiness scorers, but
     * any call whose job is to assess/score/classify rather than generate prose.
     * GENERATIVE calls (draft / merge / rewrite / triage-selection / fact
     * extraction / retrieval-metadata) are deliberately left at the platform
     * default so their output stays natural.
     *
     * Members, grouped by why they qualify:
     *   - Evaluate_Structure / Evaluate_Clarity / Evaluate_Completeness
     *       → the readiness-scoring templates (CLAUDE.md "LLM Architecture").
     *   - Annotate_Issue_Severity → severity judgement (pipeline path).
     *   - Evaluate_Extracted_Facts → judges whether two fact sets are duplicates
     *     (is_duplicate + confidence) — an evaluation, not generation.
     *   - Published_Anomaly_Evaluator → judges whether a published pair is an
     *     anomaly/contradiction — an evaluation, not generation.
     *
     * When adding a template: if it RETURNS A JUDGEMENT (score / boolean /
     * confidence / classification) add it here; if it GENERATES TEXT, leave it
     * at default.
     *
     * NOTE: this set is INTENTIONALLY BROADER than the "scoring templates" shown
     * on the Advanced Scoring Config wizard screen (kbSetupPromptEditor /
     * KBSetupOrchestratorController.SCORING_TEMPLATE_NAMES). That UI list is
     * scoped to the templates an admin tunes for the readiness *dimensions*, so
     * it deliberately excludes the pipeline evaluators (Annotate_Issue_Severity,
     * Evaluate_Extracted_Facts, Published_Anomaly_Evaluator) — even though they
     * belong here for temperature determinism. Same names, different purpose:
     * this is "pin a low temperature", that is "surface on the scoring screen".
 *
     */
    @TestVisible
    private static final Set<String> SCORING_TEMPLATES = new Set<String>{
        'Evaluate_Structure',
        'Evaluate_Clarity',
        'Evaluate_Completeness',
        'Annotate_Issue_Severity',
        'Evaluate_Extracted_Facts',
        'Published_Anomaly_Evaluator'
    };

    /**
     * True when the given template api name is a SCORING/evaluation call that
     * should be pinned to SCORING_TEMPERATURE for determinism. Factored out of
     * invokePromptTemplate so the set-membership logic is unit-testable without
     * a live Einstein callout.
     */
    @TestVisible
    private static Boolean isScoringTemplate(String templateApiName) {
        return templateApiName != null && SCORING_TEMPLATES.contains(templateApiName);
    }

    /**
     * Content character limit for LLM scoring and Fix prompts.
     * Reads KB_Scan_Config__c.LLM_Content_Char_Limit__c at runtime.
     *
     *   0 (default) = no cap — the full article body is sent to the LLM.
     *   Positive integer = cap at that many characters (minimum 1000 enforced).
     *
     * This is intentionally not surfaced in the Setup Wizard. Admins who need to
     * cap content length (e.g. to reduce token cost) can set the field directly
     * on the KB_Scan_Config__c hierarchy custom setting record.
     *
     * @TestVisible so unit tests can override without a live custom-setting row.
     */
    @TestVisible
    private static Integer contentCharLimit {
        get {
            if (contentCharLimit == null) {
                KB_Scan_Config__c cfg = KB_Scan_Config__c.getInstance();
                Integer configured = cfg != null && cfg.LLM_Content_Char_Limit__c != null
                    ? (Integer) cfg.LLM_Content_Char_Limit__c
                    : 0;
                // 0 = no cap (sentinel). Any positive value is a real cap; enforce min of 1000.
                contentCharLimit = (configured > 0) ? Math.max(configured, 1000) : 0;
            }
            return contentCharLimit;
        }
        set;
    }

    @TestVisible
    private static void setMock(PromptTemplateService mock) {
        instance = mock;
    }

    public static PromptTemplateService getInstance() {
        if (instance != null) {
            return instance;
        }
        instance = new PromptTemplateService();
        return instance;
    }

    /**
     * Evaluates a draft article against similar published articles.
     * Invokes the Draft_Evaluator prompt template.
     */
    public virtual DraftEvaluationResult evaluateDraft(
        String draftText,
        List<VectorSearchResult> similarArticles
    ) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:draftText', toWrappedValue(draftText));
        inputParams.put('Input:similarChunks', toWrappedValue(JSON.serialize(similarArticles)));

        String responseText = invokePromptTemplate('Draft_Evaluator', inputParams);
        return parseDraftEvaluationResult(responseText);
    }

    /**
     * Evaluates a pair of published articles for anomalies.
     * Invokes the Published_Anomaly_Evaluator prompt template.
     */
    public virtual AnomalyEvaluationResult evaluatePublishedPair(
        String articleAText,
        String articleBText,
        String articleAId,
        String articleBId
    ) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:articleAText', toWrappedValue(articleAText));
        inputParams.put('Input:articleBText', toWrappedValue(articleBText));

        try {
            String responseText = invokePromptTemplate('Published_Anomaly_Evaluator', inputParams);
            return parseAnomalyEvaluationResult(responseText);
        } catch (Exception e) {
            throw new KnowledgeAIException(
                'Published pair evaluation failed for ' + articleAId + ' / ' + articleBId + ': ' + e.getMessage()
            );
        }
    }

    /**
     * Invokes a Prompt Builder template via native ConnectApi and returns the generated text.
     */
    @TestVisible
    private String invokePromptTemplate(
        String templateApiName,
        Map<String, ConnectApi.WrappedValue> inputParams
    ) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            buildInput(templateApiName, inputParams);

        try {
            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
                ConnectApi.EinsteinLlm.generateMessagesForPromptTemplate(
                    templateApiName, input
                );

            if (response.generations == null || response.generations.isEmpty()) {
                throw new KnowledgeAIException(
                    'No generations returned from prompt template: ' + templateApiName
                );
            }

            return response.generations[0].text;
        } catch (ConnectApi.ConnectApiException e) {
            throw new KnowledgeAIException(
                'Prompt template invocation failed for ' + templateApiName + ': ' + e.getMessage()
            );
        } catch (Exception e) {
            // Includes System.TypeException from safety-score gate responses where the platform
            // returns EinsteinLlmGenerationSafetyScoreOutput instead of EinsteinLLMGenerationItemOutput
            throw new KnowledgeAIException(
                'Prompt template invocation failed for ' + templateApiName
                    + ' (' + e.getTypeName() + '): ' + e.getMessage()
            );
        }
    }

    /**
     * Assembles the EinsteinPromptTemplateGenerationsInput, including the
     * per-template temperature policy. Factored out of invokePromptTemplate so
     * the wiring (scoring template → temperature = SCORING_TEMPERATURE; other
     * templates → temperature left unset) is unit-testable without a live
     * Einstein callout, which is unreachable in a test transaction.
     */
    @TestVisible
    private static ConnectApi.EinsteinPromptTemplateGenerationsInput buildInput(
        String templateApiName,
        Map<String, ConnectApi.WrappedValue> inputParams
    ) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptTemplateGenerationsInvocable';
        // Pin EVALUATION/JUDGEMENT calls to a low temperature for run-to-run
 // determinism. Generative templates are deliberately left at the
        // platform default so their prose stays natural. Conditional per
        // template — never a blanket global. See SCORING_TEMPLATES for the rule.
        if (isScoringTemplate(templateApiName)) {
            input.additionalConfig.temperature = SCORING_TEMPERATURE;
        }
        // Digital Wallet consumption tagging: stamp every LLM call with the app,
        // its component, and the exact template so a customer admin can attribute
        // this app's Einstein spend in the Wallet's Consumption Cards. `tags` takes
        // arbitrary key/value pairs (values wrapped like inputParams), no
        // Einstein-GPT app-name pre-registration.
        input.tags = new Map<String, ConnectApi.WrappedValue>{
            'kb_readiness_app' => wrap('KBReadiness'),
            'kb_readiness_component' => wrap(componentForTemplate(templateApiName)),
            'kb_readiness_template' => wrap(templateApiName)
        };
        input.isPreview = false;
        input.inputParams = inputParams;
        return input;
    }

    // Coarse component bucket for Wallet reporting. Scoring = the three
    // Evaluate_* scorers; Fix = the AI-Fix rewrite; Severity = issue annotation;
    // everything else (dedup evaluators, draft/merge) is Pipeline.
    @TestVisible
    private static String componentForTemplate(String templateApiName) {
        if (templateApiName == null) return 'Pipeline';
        if (templateApiName.startsWith('Evaluate_') && templateApiName != 'Evaluate_Extracted_Facts') {
            return 'Scoring';
        }
        if (templateApiName == 'Fix_Article_Issues_V2') return 'Fix';
        if (templateApiName == 'Annotate_Issue_Severity') return 'Severity';
        return 'Pipeline';
    }

    // Static sibling of toWrappedValue for use from the static buildInput/tag path.
    private static ConnectApi.WrappedValue wrap(String value) {
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = value;
        return wv;
    }

    private ConnectApi.WrappedValue toWrappedValue(String value) {
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = value;
        return wv;
    }

    @TestVisible
    private DraftEvaluationResult parseDraftEvaluationResult(String jsonResponse) {
        DraftEvaluationResult result = new DraftEvaluationResult();

        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonResponse);
            result.hasConflict = (Boolean) parsed.get('hasConflict');
            result.conflicts = new List<ConflictDetail>();

            if (parsed.containsKey('conflicts') && parsed.get('conflicts') != null) {
                List<Object> conflictList = (List<Object>) parsed.get('conflicts');
                for (Object c : conflictList) {
                    Map<String, Object> conflictMap = (Map<String, Object>) c;
                    ConflictDetail detail = new ConflictDetail();
                    detail.conflictingArticleId = (String) conflictMap.get('articleId');
                    detail.conflictingArticleTitle = (String) conflictMap.get('articleTitle');
                    detail.conflictType = (String) conflictMap.get('type');
                    detail.reasoning = (String) conflictMap.get('reasoning');
                    result.conflicts.add(detail);
                }
            }
        } catch (Exception e) {
            throw new KnowledgeAIException(
                'Failed to parse draft evaluation response: ' + e.getMessage()
            );
        }

        return result;
    }

    @TestVisible
    private AnomalyEvaluationResult parseAnomalyEvaluationResult(String jsonResponse) {
        AnomalyEvaluationResult result = new AnomalyEvaluationResult();

        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonResponse);
            result.isAnomaly = (Boolean) parsed.get('isAnomaly');
            result.anomalyType = (String) parsed.get('anomalyType');
            result.reasoning = (String) parsed.get('reasoning');
        } catch (Exception e) {
            throw new KnowledgeAIException(
                'Failed to parse anomaly evaluation response: ' + e.getMessage()
            );
        }

        return result;
    }

    // =====================================================================
    // Readiness Scoring Methods (Phase 2 — replaces KBEinsteinLLMService)
    // =====================================================================

    /**
     * Evaluates structure / chunkability. The LLM judges chunk
     * self-containment, structural appropriateness, and topic coherence.
     *
 * Title and Summary are passed as their own dedicated inputs
     * never folded into the body Content — so the structural signal of a strong
     * title/summary is never lost when the admin-selected body fields are thin.
     */
    public virtual LLMEvaluationResult evaluateStructure(String title, String content, String summary) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:Title', toWrappedValue(String.isBlank(title) ? '' : title));
        inputParams.put('Input:Summary', toWrappedValue(String.isNotBlank(summary) ? summary : ''));
        inputParams.put('Input:Content', toWrappedValue(truncateForLLM(content, contentCharLimit)));

        try {
            String responseText = invokePromptTemplate('Evaluate_Structure', inputParams);
            return parseLLMEvaluationResult(responseText, 'structure');
        } catch (Exception e) {
            LLMEvaluationResult result = new LLMEvaluationResult();
            result.errorMessage = 'Structure evaluation failed: ' + e.getMessage();
            return result;
        }
    }

    /**
     * Evaluates semantic clarity (pronoun ambiguity, jargon bridging, sentence
     * complexity, passive voice, within-article contradictions).
     *
     * Title and Summary are passed as their own dedicated inputs — never folded
     * into the body Content.
     */
    public virtual LLMEvaluationResult evaluateClarity(
        String title,
        String content,
        String summary
    ) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:Title', toWrappedValue(String.isBlank(title) ? '' : title));
        inputParams.put('Input:Summary', toWrappedValue(String.isNotBlank(summary) ? summary : ''));
        inputParams.put('Input:Content', toWrappedValue(truncateForLLM(content, contentCharLimit)));

        try {
            String responseText = invokePromptTemplate('Evaluate_Clarity', inputParams);
            return parseLLMEvaluationResult(responseText, 'clarity');
        } catch (Exception e) {
            LLMEvaluationResult result = new LLMEvaluationResult();
            result.errorMessage = 'Clarity evaluation failed: ' + e.getMessage();
            return result;
        }
    }

    public virtual LLMEvaluationResult evaluateCompleteness(String title, String structuredContent, String summary) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:Title', toWrappedValue(title));
        inputParams.put('Input:Content', toWrappedValue(truncateForLLM(structuredContent, contentCharLimit)));
        inputParams.put('Input:Summary', toWrappedValue(String.isNotBlank(summary) ? summary : ''));

        try {
            String responseText = invokePromptTemplate('Evaluate_Completeness', inputParams);
            return parseLLMEvaluationResult(responseText, 'completeness');
        } catch (Exception e) {
            LLMEvaluationResult result = new LLMEvaluationResult();
            result.errorMessage = 'Completeness evaluation failed: ' + e.getMessage();
            return result;
        }
    }

    /**
     * Check if Einstein/Prompt Builder is available in this org
     */
    public static Boolean isEinsteinAvailable() {
        try {
            Type t = Type.forName('ConnectApi', 'EinsteinLlm');
            return t != null;
        } catch (Exception e) {
            return false;
        }
    }

    // =====================================================================
    // LLM Evaluation Result Parsing
    // =====================================================================

    @TestVisible
    private LLMEvaluationResult parseLLMEvaluationResult(String responseText, String evaluationType) {
        LLMEvaluationResult result = new LLMEvaluationResult();

        try {
            String cleanedResponse = stripCodeFences(responseText);

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleanedResponse);

            if (parsed.containsKey('score')) {
                Object scoreObj = parsed.get('score');
                if (scoreObj instanceof Decimal) {
                    result.score = (Decimal) scoreObj;
                } else if (scoreObj instanceof Integer) {
                    result.score = Decimal.valueOf((Integer) scoreObj);
                }
            }

            if (parsed.containsKey('reasoning')) {
                result.reasoning = (String) parsed.get('reasoning');
            }

            extractTypeSpecificFields(parsed, result, evaluationType);
            result.success = true;

        } catch (Exception e) {
            result.errorMessage = 'Failed to parse LLM response: ' + e.getMessage();
            result.reasoning = 'Raw response: ' + truncateForLLM(responseText, 300);
        }

        return result;
    }

    private void extractTypeSpecificFields(Map<String, Object> parsed, LLMEvaluationResult result, String evaluationType) {
        switch on evaluationType {
            when 'structure' {
                // Per-field structure (refactored Structure prompt). Uses
                // extractIssueItems so severity-aware issue objects flow
                // through as IssueAnalysis entries while plain strings still
                // work — the helper handles both shapes.
                if (parsed.containsKey('fieldResults') && parsed.get('fieldResults') instanceof List<Object>) {
                    List<Object> fieldResults = (List<Object>) parsed.get('fieldResults');
                    for (Object fr : fieldResults) {
                        Map<String, Object> fieldResult = (Map<String, Object>) fr;
                        String fieldName = fieldResult.containsKey('field') ? String.valueOf(fieldResult.get('field')) : 'Unknown';
                        if (fieldResult.containsKey('issues') && fieldResult.get('issues') instanceof List<Object>) {
                            extractIssueItems((List<Object>) fieldResult.get('issues'), result, fieldName + ': ');
                        }
                        if (fieldResult.containsKey('strengths') && fieldResult.get('strengths') instanceof List<Object>) {
                            for (Object strength : (List<Object>) fieldResult.get('strengths')) {
                                String val = String.valueOf(strength);
                                if (String.isNotBlank(val) && val != 'null') {
                                    result.strengths.add(fieldName + ': ' + val);
                                }
                            }
                        }
                    }
                }
                extractIssueList(parsed, 'topicDrifts', result, 'Topic drift: ');
            }
            when 'clarity' {
                extractIssueList(parsed, 'clarityIssues', result, '');
                extractListField(parsed, 'strengths', result.strengths, '');
            }
            when 'chunking' {
                extractIssueList(parsed, 'orphanedReferences', result, 'Orphaned: ');
                if (parsed.containsKey('selfContainedSections')) {
                    Integer count = Integer.valueOf(String.valueOf(parsed.get('selfContainedSections')));
                    if (count > 0) {
                        result.strengths.add(count + ' self-contained sections');
                    }
                }
            }
            when 'completeness' {
                if (parsed.containsKey('fieldResults') && parsed.get('fieldResults') instanceof List<Object>) {
                    List<Object> fieldResults = (List<Object>) parsed.get('fieldResults');
                    for (Object fr : fieldResults) {
                        Map<String, Object> fieldResult = (Map<String, Object>) fr;
                        String fieldName = fieldResult.containsKey('field') ? String.valueOf(fieldResult.get('field')) : 'Unknown';
                        if (fieldResult.containsKey('issues') && fieldResult.get('issues') instanceof List<Object>) {
                            extractIssueItems((List<Object>) fieldResult.get('issues'), result, fieldName + ': ');
                        }
                        if (fieldResult.containsKey('strengths') && fieldResult.get('strengths') instanceof List<Object>) {
                            for (Object strength : (List<Object>) fieldResult.get('strengths')) {
                                String val = String.valueOf(strength);
                                if (String.isNotBlank(val) && val != 'null') {
                                    result.strengths.add(fieldName + ': ' + val);
                                }
                            }
                        }
                    }
                }
                extractIssueList(parsed, 'summaryIssues', result, 'Summary: ');
                extractListField(parsed, 'summaryStrengths', result.strengths, 'Summary: ');
            }
            when 'conflict' {
                extractIssueList(parsed, 'contradictions', result, 'Contradiction: ');
                extractListField(parsed, 'complementary', result.strengths, 'Complementary: ');
            }
        }
    }

    /**
     * Extracts an `issues`-shaped list from the parsed JSON map and adds each
     * entry to `result.issues` + `result.issueAnalyses` in lockstep. Accepts
     * both legacy string items ("issue text") and the new per-issue object
     * shape ({ "text", "impact", "effort", "priority" }) so older deployed
     * templates keep working during rollout.
     */
    @TestVisible
    private void extractIssueList(Map<String, Object> parsed, String fieldName, LLMEvaluationResult result, String prefix) {
        if (parsed.containsKey(fieldName) && parsed.get(fieldName) instanceof List<Object>) {
            extractIssueItems((List<Object>) parsed.get(fieldName), result, prefix);
        }
    }

    @TestVisible
    private void extractIssueItems(List<Object> items, LLMEvaluationResult result, String prefix) {
        for (Object item : items) {
            if (item instanceof Map<String, Object>) {
                Map<String, Object> obj = (Map<String, Object>) item;
                Object textObj = obj.get('text');
                if (textObj == null) continue;
                String val = String.valueOf(textObj);
                if (String.isBlank(val) || val == 'null') continue;
                result.addIssue(
                    prefix + val,
                    nullableString(obj.get('impact')),
                    nullableString(obj.get('effort')),
                    nullableString(obj.get('priority'))
                );
            } else {
                String val = String.valueOf(item);
                if (String.isNotBlank(val) && val != 'null') {
                    result.addIssue(prefix + val, null, null, null);
                }
            }
        }
    }

    private String nullableString(Object o) {
        if (o == null) return null;
        String s = String.valueOf(o);
        return (String.isBlank(s) || s == 'null') ? null : s;
    }

    @TestVisible
    private void extractListField(Map<String, Object> parsed, String fieldName, List<String> targetList, String prefix) {
        if (parsed.containsKey(fieldName) && parsed.get(fieldName) instanceof List<Object>) {
            List<Object> items = (List<Object>) parsed.get(fieldName);
            for (Object item : items) {
                String val = String.valueOf(item);
                if (String.isNotBlank(val) && val != 'null') {
                    targetList.add(prefix + val);
                }
            }
        }
    }

    @TestVisible
    private String truncateForLLM(String text, Integer maxChars) {
        if (String.isBlank(text)) return '';
        // 0 = no cap — return full text
        if (maxChars == null || maxChars <= 0) return text;
        return text.length() <= maxChars ? text : text.substring(0, maxChars) + '... [truncated]';
    }

    // =====================================================================
    // Inner DTOs
    // =====================================================================

    /**
     * Result from LLM evaluation — compatible with the shape used by all scorers.
     * Replaces KBEinsteinLLMService.LLMEvaluationResult.
     *
     * `issues` and `issueAnalyses` are parallel lists kept in lockstep by the
     * parser. `issues` preserves the legacy String shape consumed directly by
     * the LWC card; `issueAnalyses` carries the per-issue impact/effort/priority
 * emitted by the new prompt templates. When the LLM returns
     * the legacy string shape, the corresponding IssueAnalysis still gets
     * created with null severity fields so consumers can fall back to
     * deterministic mappers.
     */
    public class LLMEvaluationResult {
        public Decimal score { get; set; }
        public String reasoning { get; set; }
        public List<String> issues { get; set; }
        public List<KBAssessmentModels.IssueAnalysis> issueAnalyses { get; set; }
        public List<String> strengths { get; set; }
        public Boolean success { get; set; }
        public String errorMessage { get; set; }

        public LLMEvaluationResult() {
            this.score = 0;
            this.issues = new List<String>();
            this.issueAnalyses = new List<KBAssessmentModels.IssueAnalysis>();
            this.strengths = new List<String>();
            this.success = false;
        }

        /**
         * Append an issue text + parallel IssueAnalysis carrier so consumers
         * who still iterate `issues` keep working unchanged.
         */
        public void addIssue(String text, String impact, String effort, String priority) {
            if (String.isBlank(text)) return;
            this.issues.add(text);
            this.issueAnalyses.add(new KBAssessmentModels.IssueAnalysis(text, impact, effort, priority));
        }
    }

    public class DraftEvaluationResult {
        @AuraEnabled public Boolean hasConflict;
        @AuraEnabled public List<ConflictDetail> conflicts;

        public DraftEvaluationResult() {
            this.hasConflict = false;
            this.conflicts = new List<ConflictDetail>();
        }
    }

    public class ConflictDetail {
        @AuraEnabled public String conflictingArticleId;
        @AuraEnabled public String conflictingArticleTitle;
        @AuraEnabled public String conflictType;
        @AuraEnabled public String reasoning;
    }

    public class AnomalyEvaluationResult {
        @AuraEnabled public Boolean isAnomaly;
        @AuraEnabled public String anomalyType;
        @AuraEnabled public String reasoning;

        public AnomalyEvaluationResult() {
            this.isAnomaly = false;
        }
    }

    // =====================================================================
    // Tier 3: Triage — single LLM call to narrow 20 candidates to top 3
    // =====================================================================

    /**
     * Triages up to 20 candidate articles against a target, returning the positional
     * indexes of the top duplicates. Uses positional indexes (not IDs) in the prompt
     * to prevent LLM from mangling Salesforce IDs. (Topics 3, 19)
     *
     * @param targetTitle Title of the target article
     * @param targetSummary Summary of the target article
     * @param candidates List of CandidateSummary (title + summary, indexed 0-N)
     * @return TriageResult with list of positional indexes (0-based)
     */
    public virtual TriageResult triageDuplicateCandidates(
        String targetTitle,
        String targetSummary,
        List<CandidateSummary> candidates
    ) {
        // Build numbered candidate list for the prompt
        String candidateList = '';
        for (Integer i = 0; i < candidates.size(); i++) {
            CandidateSummary c = candidates[i];
            candidateList += 'Candidate [' + i + '] Title: ' + c.title
                + ' | Summary: ' + c.summary + '\n\n';
        }

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:TargetTitle', toWrappedValue(targetTitle));
        inputParams.put('Input:TargetSummary', toWrappedValue(targetSummary));
        inputParams.put('Input:CandidateList', toWrappedValue(candidateList));

        String responseText = invokePromptTemplate('Triage_Duplicate_Candidates', inputParams);
        return parseTriageResult(responseText, candidates.size());
    }

    /**
     * Parses triage result with bounds checking. Returns empty list on parse failure
     * rather than throwing, so the pipeline can exit gracefully.
     */
    @TestVisible
    private TriageResult parseTriageResult(String jsonResponse, Integer candidateCount) {
        TriageResult result = new TriageResult();
        result.topCandidateIndexes = new List<Integer>();

        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonResponse);
            List<Object> indexes = (List<Object>) parsed.get('top_candidates');

            if (indexes == null) {
                return result;
            }

            for (Object idx : indexes) {
                Integer index = Integer.valueOf(idx);
                // Bounds check: ignore indexes outside valid range
                if (index >= 0 && index < candidateCount) {
                    result.topCandidateIndexes.add(index);
                }
            }
        } catch (Exception e) {
            // Parse failure: log and return empty result for graceful pipeline exit
            System.debug(LoggingLevel.ERROR,
                'Failed to parse triage result: ' + e.getMessage() + ' | Raw response: ' + jsonResponse);
        }

        return result;
    }

    // =====================================================================
    // Tier 4: Multi-Step Agentic Prompt Chain (Topic 20: not "RLM")
    // =====================================================================

    /**
     * Sub-agent: extracts dense facts from an article text chunk.
     * Called once per chunk, max chunks controlled by KM_Pipeline_Config__mdt.
     */
    public virtual String extractArticleFacts(String articleChunkText) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:TextChunk', toWrappedValue(articleChunkText));

        return invokePromptTemplate('Extract_Article_Facts', inputParams);
    }

    /**
     * Root agent: compares extracted facts from two articles for a final
     * duplicate/not-duplicate ruling with confidence score.
     */
    public virtual FactEvaluationResult evaluateExtractedFacts(
        String factsA,
        String factsB
    ) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:ArticleA_State', toWrappedValue(factsA));
        inputParams.put('Input:ArticleB_State', toWrappedValue(factsB));

        String responseText = invokePromptTemplate('Evaluate_Extracted_Facts', inputParams);
        return parseFactEvaluationResult(responseText);
    }

    @TestVisible
    private FactEvaluationResult parseFactEvaluationResult(String jsonResponse) {
        FactEvaluationResult result = new FactEvaluationResult();

        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonResponse);
            result.isDuplicate = (Boolean) parsed.get('is_duplicate');
            result.confidenceScore = Decimal.valueOf(String.valueOf(parsed.get('confidence_score')));
            result.reasoning = (String) parsed.get('reasoning');
            result.anomalyType = (String) parsed.get('anomaly_type');
        } catch (Exception e) {
            throw new KnowledgeAIException(
                'Failed to parse fact evaluation response: ' + e.getMessage()
            );
        }

        return result;
    }

    // =====================================================================
    // Tier 4: Golden Record merge draft
    // =====================================================================

    /**
     * Drafts a merged "Golden Record" article from two duplicate articles.
     * Returns the merged HTML content for the new article body.
     */
    public virtual String draftMergedArticle(
        String article1Text,
        String article2Text,
        String language
    ) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:Article1_Text', toWrappedValue(article1Text));
        inputParams.put('Input:Article2_Text', toWrappedValue(article2Text));

        return invokePromptTemplate('Draft_Merged_Knowledge_Article', inputParams);
    }

    /**
     * Draft a single golden-record body from N>=2 article texts. The
     * Draft_Merged_Knowledge_Article template accepts two inputs, so for
     * clusters >2 we iteratively merge the running draft with each next
     * article. Returns the final merged HTML. Caller must handle empty lists.
     */
    public virtual String draftMergedCluster(List<String> articleTexts, String language) {
        if (articleTexts == null || articleTexts.isEmpty()) {
            return '';
        }
        if (articleTexts.size() == 1) {
            return articleTexts[0];
        }
        String running = articleTexts[0];
        for (Integer i = 1; i < articleTexts.size(); i++) {
            running = draftMergedArticle(running, articleTexts[i], language);
        }
        return running;
    }

    public class FixArticleResult {
        public Map<String, String> rewrittenFields { get; set; }
        public String              changesSummary  { get; set; }
    }

    /**
 * One article in a consolidate request: its content fields plus the
     * issues + strengths diagnosed for it. The shared prompt receives a LIST of
     * these: 1 element ⇒ fix that article; N elements ⇒ merge them into one.
     */
    public class ArticleInput {
        public Map<String, String> fields;   // field API name -> value (mapped content fields)
        public List<String> issues;          // diagnosed issues to resolve
        public List<String> strengths;       // strengths to preserve
        public ArticleInput() {
            this.fields = new Map<String, String>();
            this.issues = new List<String>();
            this.strengths = new List<String>();
        }
    }

    /**
 * Shared "improve articles" LLM call behind BOTH the AI-Fix flow
     * (1 article → fix it) and the Tier-5 duplicate merge (N articles → merge
     * into one Golden Record). Both tasks have the same input shape — a list of
     * {fields, issues, strengths} per article — and the same output: a single
     * article's rewritten `fields` + a `changes_summary`. Feeding the LLM each
     * article's issues (to resolve) and strengths (to preserve) produces a
 * materially better result than merging on raw content alone (the
     * insight); for the merge case it also reconciles two articles' findings.
     *
     * The two callers keep their OWN orchestration (the fix flow versions the
     * same article; Tier 4 creates a Golden Record or enriches a survivor +
     * archives losers) — only the prompt + input contract are unified.
     *
     * fieldLimits caps each field's length; language localises the output.
     * Returns a FixArticleResult (rewrittenFields + changesSummary), parsed by
     * the same sanitiser the fix flow already uses.
     */
    public virtual FixArticleResult consolidateArticles(
        List<ArticleInput> articles,
        Map<String, Integer> fieldLimits,
        String language
    ) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:Articles_JSON', toWrappedValue(JSON.serialize(articles)));
        inputParams.put('Input:Field_Limits_JSON', toWrappedValue(JSON.serialize(fieldLimits)));
        inputParams.put('Input:Article_Count', toWrappedValue(String.valueOf(articles == null ? 0 : articles.size())));
        inputParams.put('Input:Language', toWrappedValue(String.isBlank(language) ? 'en_US' : language));

        String response = invokePromptTemplate('Consolidate_Knowledge_Articles', inputParams);
        return parseFixArticleResult(response, 'Consolidate_Knowledge_Articles');
    }

    public virtual FixArticleResult fixArticleIssues(
        Map<String, String>  articleFields,
        Map<String, Integer> fieldLimits,
        String               issuesList,
        String               strengthsList,
        String               language
    ) {
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:Article_Fields_JSON', toWrappedValue(JSON.serialize(articleFields)));
        inputParams.put('Input:Field_Limits_JSON',   toWrappedValue(JSON.serialize(fieldLimits)));
        inputParams.put('Input:Issues_List',         toWrappedValue(issuesList));
        inputParams.put('Input:Strengths_List',      toWrappedValue(String.isBlank(strengthsList) ? '(none identified)' : strengthsList));
        inputParams.put('Input:Language',            toWrappedValue(language));

        String response = invokePromptTemplate('Fix_Article_Issues_V2', inputParams);
        return parseFixArticleResult(response, 'Fix_Article_Issues_V2');
    }

    /**
     * Sanitizes the raw LLM response (escapes bare CR/LF/tab so JSON accepts
     * them, strips pilcrow characters that LLMs emit as paragraph markers)
     * and parses it into a `FixArticleResult`. Throws `KnowledgeAIException`
     * on malformed JSON.
     *
 * Tolerates two LLM response shapes that previously broke the parse:
     *  (a) a markdown code-fenced object (```json … ``` or bare ``` … ```) —
     *      the fence is stripped inline (mirrors the scoring parser's inline
     *      fence-strip), kept local to this method per the bug's scope.
     *  (b) a fully-escaped/stringified JSON object — the LLM returned a JSON
     *      *string* whose content is the object rather than a raw object. This
     *      arrives in two forms: fully quoted (`"{\"fields\":…}"`) or naked
     *      escapes with no outer quotes (`{\"fields\":…}` — the
     *      "Unexpected character ('\' (code 92))" at column 3). We try the
     *      normal parse first; on failure we unwrap once via a single
     *      `JSON.deserializeUntyped` as a String (wrapping the naked form in
     *      quotes so it becomes a valid JSON string), then re-parse the inner
     *      JSON. A genuinely unparseable response still throws the original
     *      clear exception.
     *
     * Extracted from `fixArticleIssues` so T10 (parser-path tests) can hit
     * the sanitization/parse logic without spinning up a real Einstein
     * callout.
     */
    @TestVisible
    private FixArticleResult parseFixArticleResult(String response) {
        // Back-compat overload — callers that don't know the template name
        // (and the parser-path tests) get a template-agnostic label.
        return parseFixArticleResult(response, 'AI');
    }

    /**
 * `templateName` is the developer name of the GenAI template whose
     * response we're parsing (`Consolidate_Knowledge_Articles` for the merge
     * flow, `Fix_Article_Issues_V2` for AI Fix). It's woven into the failure
     * message so a merge parse-failure no longer mislabels itself as the Fix
     * template. A truncated/incomplete payload (the model hit an output-token
     * cap mid-object) is also detected here and degraded to an actionable
     * "response was incomplete — retry" message instead of the raw Jackson
     * `Unexpected end-of-input` dump reaching the user.
     */
    @TestVisible
    private FixArticleResult parseFixArticleResult(String response, String templateName) {
        FixArticleResult result = new FixArticleResult();
        result.rewrittenFields = new Map<String, String>();
        try {
            // Strip a markdown code fence if the model wrapped the JSON in one.
            String cleaned = stripCodeFences(response);

            Map<String, Object> parsed;
            try {
                parsed = parseFixArticleObject(cleaned);
            } catch (Exception parseEx) {
                // The response may be a JSON *string* whose content is the object
                // (escaped/stringified JSON). The fully-quoted form casts to a
                // String (TypeException); the naked-escape form fails to parse
                // outright (JSONException). Both unwrap by deserializing as a
                // String — wrap the naked form in quotes first so it is one.
                // Escape bare control chars before wrapping so a multi-line body
                // with literal newlines/tabs still yields a valid JSON string.
                // Re-parse the inner JSON; if that also fails, rethrow the
                // original exception so the outer catch keeps its clear message.
                String forUnwrap = escapeBareControlChars(cleaned);
                String toUnwrap = forUnwrap.startsWith('"') ? forUnwrap : '"' + forUnwrap + '"';
                Object unwrapped;
                try {
                    unwrapped = JSON.deserializeUntyped(toUnwrap);
                } catch (Exception unusedEx) {
                    throw parseEx;
                }
                if (unwrapped instanceof String) {
                    try {
                        parsed = parseFixArticleObject((String) unwrapped);
                    } catch (Exception fullDecodeEx) {
 // a naked-escape payload is escaped ONCE (only its
                        // quotes), so a value's own JSON escape — `\\` for a literal
                        // backslash in a Windows path C:\app — is already valid.
                        // Deserializing the whole payload as a string above decoded a
                        // second time, collapsing that `\\` to a lone `\` and yielding
                        // an illegal escape like `\a` → the re-parse threw. Recover by
                        // undoing ONLY the quote-escaping layer so the delimiters
                        // become bare `"` while the value's escapes stay intact;
                        // parseFixArticleObject's own retry then handles any bare
                        // control chars. If this also fails, rethrow the original
                        // exception so the outer catch keeps its clear message.
                        try {
                            parsed = parseFixArticleObject(cleaned.replace('\\"', '"'));
                        } catch (Exception recoverEx) {
                            throw parseEx;
                        }
                    }
                } else {
                    throw parseEx;
                }
            }

            if (parsed.containsKey('fields') && parsed.get('fields') instanceof Map<String, Object>) {
                Map<String, Object> rawFields = (Map<String, Object>) parsed.get('fields');
                for (String k : rawFields.keySet()) {
                    if (rawFields.get(k) != null) {
                        String val = String.valueOf(rawFields.get(k));
                        // Strip pilcrow characters — LLMs sometimes emit ¶ as a paragraph marker
                        val = val.replace('¶', '\n');
 // whitespace inside HTML markup is significant — collapsing
                        // double-spaces corrupts <pre> content, attribute spacing, and
                        // indentation, and the pilcrow→\n swap is a plain-text notion that
                        // has no place inside tags. So only apply plain-text normalization
                        // when the value is NOT HTML. Rich-text Knowledge fields (FAQ_Answer__c,
                        // Solution__c, …) round-trip HTML source, which now flows through the
                        // Fix_Article_Issues_V2 prompt verbatim (lists, headings, <a href> links).
                        if (looksLikeHtml(val)) {
                            // HTML: leave markup untouched aside from trimming outer whitespace.
                            val = val.trim();
                        } else {
                            // Plain text: collapse accidental double-spaces as before.
                            val = val.replace('  ', ' ').trim();
                        }
                        result.rewrittenFields.put(k, val);
                    }
                }
            }
            result.changesSummary = parsed.containsKey('changes_summary')
                ? String.valueOf(parsed.get('changes_summary')) : '';
        } catch (Exception e) {
            String label = String.isBlank(templateName) ? 'AI' : templateName;
            String cause = e.getMessage();
            // A response cut off mid-JSON (output-token cap on long articles)
            // surfaces as Jackson's "Unexpected end-of-input" / "expected close
            // marker". Degrade to something the user can act on rather than the
            // raw parser dump.
            if (cause != null
                    && (cause.containsIgnoreCase('end-of-input')
                        || cause.containsIgnoreCase('expected close marker'))) {
                throw new KnowledgeAIException(
                    'The ' + label + ' response was incomplete — this can happen on very '
                    + 'long articles when the AI output is truncated. Retry, or shorten '
                    + 'the source content before trying again.'
                );
            }
            throw new KnowledgeAIException(
                'Failed to parse ' + label + ' response: ' + cause);
        }
        return result;
    }

    // Matches an HTML-ish tag: '<' + a letter or '/' + anything up to the next '>'.
    // Compiled once, reused per value.
    private static final Pattern HTML_TAG_PATTERN = Pattern.compile('<[a-zA-Z/][^>]*>');

    /**
     * Heuristic: does this value carry HTML markup? Used to decide whether
     * plain-text whitespace normalization (double-space collapse) is safe to
 * apply — it is NOT for HTML, where whitespace can be significant.
     * Deliberately conservative: a stray '<' with no tag shape stays plain text.
     */
    @TestVisible
    private static Boolean looksLikeHtml(String val) {
        if (String.isBlank(val)) {
            return false;
        }
        return HTML_TAG_PATTERN.matcher(val).find();
    }

    /**
     * Deserializes a raw JSON-object string into a map.
     *
     * Raw-first: try the text exactly as the model sent it. Apex's parser
     * natively tolerates structural whitespace, so compact AND pretty-printed
     * JSON both parse on this attempt with no preprocessing — this is the common
     * case (~all well-formed responses) and avoids walking/allocating the whole
     * body. Only if the raw parse fails do we retry with `escapeBareControlChars`,
     * which rescues the rarer case of bare CR/LF/tab sitting *inside* a string
     * value. (The old code escaped unconditionally, which corrupted pretty-printed
 * JSON — the failure.)
     *
     * Throws on genuinely malformed input — `System.JSONException` when the text
     * isn't valid JSON, or `System.TypeException` when it parses to a non-object
     * (e.g. a stringified JSON value) — so `parseFixArticleResult` can branch on
     * the failure into its escaped/stringified-JSON unwrap path.
     */
    private Map<String, Object> parseFixArticleObject(String jsonText) {
        try {
            return (Map<String, Object>) JSON.deserializeUntyped(jsonText);
        } catch (Exception rawEx) {
            // Raw parse failed — the model may have emitted bare control chars
            // inside string values. Retry with those escaped (only inside string
            // literals, so structural whitespace stays intact). If this attempt
            // also fails, its exception propagates so the caller can branch.
            return (Map<String, Object>) JSON.deserializeUntyped(escapeBareControlChars(jsonText));
        }
    }

    /**
     * Escapes bare CR/LF/tab that appear *inside JSON string literals* so
     * `JSON.deserializeUntyped` accepts the literal newlines/tabs LLMs sometimes
     * emit inside string values — WITHOUT corrupting structural whitespace.
     *
     * A naive whole-string `.replace('\n','\\n')` cannot tell a structural
     * newline (between tokens, e.g. in pretty-printed JSON — must stay raw) from
     * one inside a string value (must be escaped). It turned valid pretty-printed
     * JSON into `{\n  "fields"...`, which threw `Unexpected character ('\' (code
 * 92))`— the failure. Apex's parser already tolerates structural
     * whitespace, so the fix is to escape control chars ONLY while inside a
     * string literal, tracking quote/escape state char-by-char.
     */
    private String escapeBareControlChars(String jsonText) {
        if (String.isBlank(jsonText)) return jsonText;
        Integer len = jsonText.length();
        List<String> out = new List<String>();
        Boolean inString = false;   // are we inside a "..." literal?
        Boolean escaped = false;    // was the previous char an unescaped backslash?
        Boolean skipLF = false;     // swallow an LF that follows a CR (CRLF → one \n)
        for (Integer i = 0; i < len; i++) {
            Integer code = jsonText.charAt(i);
            if (skipLF && code == 10) {
                // Second half of a CRLF inside a string — already emitted \n.
                skipLF = false;
                continue;
            }
            skipLF = false;
            if (!inString) {
                // Outside a string: leave structural whitespace untouched.
                if (code == 34) { // "
                    inString = true;
                }
                out.add(jsonText.substring(i, i + 1));
                continue;
            }
            // Inside a string literal. A raw control char (< 0x20) is NEVER a
            // valid JSON escape target — escape it regardless of any preceding
            // backslash. Checking control chars BEFORE the `escaped` flag is what
            // fixes the regression where `\` + bare LF left the LF unescaped.
            if (code < 32) {
                if (code == 13) {            // CR
                    out.add('\\n');
                    skipLF = true;           // collapse a trailing LF (CRLF → one \n)
                } else if (code == 10) {     // LF
                    out.add('\\n');
                } else if (code == 9) {      // tab
                    out.add('\\t');
                } else {                     // any other control char → \u00XX
                    String hx = EncodingUtil.convertToHex(
                        Blob.valueOf(jsonText.substring(i, i + 1))
                    );
                    out.add('\\u00' + hx.right(2));
                }
                escaped = false;
            } else if (escaped) {
                // Target of a backslash escape (e.g. the n in \n, the " in \") —
                // emit verbatim; the pair is already a valid JSON escape.
                out.add(jsonText.substring(i, i + 1));
                escaped = false;
            } else if (code == 92) {  // backslash — starts an escape sequence
                out.add('\\');
                escaped = true;
            } else if (code == 34) {  // unescaped " closes the string
                out.add('"');
                inString = false;
            } else {
                out.add(jsonText.substring(i, i + 1));
            }
        }
        return String.join(out, '');
    }

    /**
     * Strips a single markdown code fence wrapping an LLM JSON response, if
     * present. Shared by every prompt-response parser so they handle fences
     * uniformly (one definition, no per-parser drift).
     *
     * Handles the language-tag variants models emit — ```json, ```JSON,
     * ``` json, and a bare ``` — case-insensitively. Strips only the opening
     * fence line and a trailing fence, NOT via substringBeforeLast (which would
     * cut at an internal ``` when an article body itself contains a code block
     * and the closing fence is missing). A response with no leading fence is
     * returned trimmed and unchanged.
     */
    @TestVisible
    private String stripCodeFences(String response) {
        if (response == null) return '';
        String cleaned = response.trim();
        if (!cleaned.startsWith('```')) return cleaned;

        // Drop the opening fence and any language tag on the same line.
        cleaned = cleaned.substringAfter('```');
        Integer firstNewline = cleaned.indexOf('\n');
        if (firstNewline >= 0) {
            String firstLine = cleaned.substring(0, firstNewline).trim();
            // The opening-fence line holds only an optional language tag.
            if (firstLine.length() <= 10) {
                cleaned = cleaned.substring(firstNewline + 1);
            }
        } else {
            // Single-line fenced payload, e.g. ```json {...} ``` — drop a
            // leading language tag if one is present.
            cleaned = cleaned.trim();
            if (cleaned.startsWithIgnoreCase('json')) {
                cleaned = cleaned.removeStartIgnoreCase('json');
            }
        }

        // Drop a trailing closing fence if the response is well-formed.
        cleaned = cleaned.trim();
        if (cleaned.endsWith('```')) {
            cleaned = cleaned.removeEnd('```');
        }
        return cleaned.trim();
    }

    /**
     * Per-issue severity carrier returned by `annotateIssueSeverity`.
     * Mirrors the shape that `Annotate_Issue_Severity` emits: index points
     * back at the input issue list so the caller can match annotations to
     * originals without relying on text equality.
     *
 * Impact-only: effort/priority were dropped — the pipeline
     * (Duplication/Conflict) severity path annotates Impact alone.
     */
    public class IssueSeverityAnnotation {
        @AuraEnabled public Integer index { get; set; }
        @AuraEnabled public String impact { get; set; }
    }

    /**
 * Annotates a list of issues with impact (Impact-only since). Used by
     * the Duplication and Conflict scorers to add severity to pipeline-derived
     * issues, where the source signals (Tier 2/3/4 confidence scores) tell us
     * how likely a duplicate exists but not how impactful it is.
     *
     * @param articleTitle      Title of the article under review
     * @param articleSummary    Summary of the article under review
     * @param articleContent    Body content of the article under review
     * @param counterpartTitle  Counterpart article title (may be blank)
     * @param counterpartSummary Counterpart article summary (may be blank)
     * @param counterpartContent Counterpart article content (may be blank)
     * @param issues            Issue texts to annotate (matched by index in response)
     * @param strengths         Article strengths (so the model doesn't recommend
     *                          fixes that would erode what was already good)
     * @return List of annotations sized 0..issues.size(); empty on parse failure.
     */
    public virtual List<IssueSeverityAnnotation> annotateIssueSeverity(
        String articleTitle,
        String articleSummary,
        String articleContent,
        String counterpartTitle,
        String counterpartSummary,
        String counterpartContent,
        List<String> issues,
        List<String> strengths
    ) {
        if (issues == null || issues.isEmpty()) {
            return new List<IssueSeverityAnnotation>();
        }

        // Single JSON payload: lets us evolve the schema (add fields, drop
        // optional sections) without touching the GenAI Prompt Template
        // metadata each time, and keeps us under the 5-input cap with
        // headroom for future templates.
        String payload = buildSeverityPayload(
            articleTitle, articleSummary, articleContent,
            counterpartTitle, counterpartSummary, counterpartContent,
            issues, strengths
        );

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        inputParams.put('Input:Payload', toWrappedValue(payload));

        try {
            String response = invokePromptTemplate('Annotate_Issue_Severity', inputParams);
            return parseSeverityAnnotations(response, issues.size());
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Issue severity annotation failed (non-fatal): ' + e.getMessage());
            return new List<IssueSeverityAnnotation>();
        }
    }

    @TestVisible
    private String buildSeverityPayload(
        String articleTitle, String articleSummary, String articleContent,
        String counterpartTitle, String counterpartSummary, String counterpartContent,
        List<String> issues,
        List<String> strengths
    ) {
        Map<String, Object> payload = new Map<String, Object>();
        payload.put('article', buildArticleNode(articleTitle, articleSummary, articleContent));
        Map<String, Object> counterpart = buildArticleNode(counterpartTitle, counterpartSummary, counterpartContent);
        payload.put('counterpart', counterpart != null ? counterpart : null);

        List<String> strengthNodes = new List<String>();
        if (strengths != null) {
            for (String s : strengths) {
                if (String.isNotBlank(s)) strengthNodes.add(s.trim());
            }
        }
        payload.put('strengths', strengthNodes);

        List<Map<String, Object>> issueNodes = new List<Map<String, Object>>();
        for (Integer i = 0; i < issues.size(); i++) {
            String text = issues[i];
            if (String.isBlank(text)) continue;
            issueNodes.add(new Map<String, Object>{
                'index' => i,
                'text'  => text
            });
        }
        payload.put('issues', issueNodes);
        return JSON.serialize(payload, true);
    }

    private Map<String, Object> buildArticleNode(String title, String summary, String content) {
        String trimmedContent = truncateForLLM(content, contentCharLimit);
        Boolean hasAny = String.isNotBlank(title)
            || String.isNotBlank(summary)
            || String.isNotBlank(trimmedContent);
        if (!hasAny) return null;
        return new Map<String, Object>{
            'title'   => String.isNotBlank(title) ? title : '',
            'summary' => String.isNotBlank(summary) ? summary : '',
            'content' => String.isNotBlank(trimmedContent) ? trimmedContent : ''
        };
    }

    @TestVisible
    private List<IssueSeverityAnnotation> parseSeverityAnnotations(String response, Integer issueCount) {
        List<IssueSeverityAnnotation> result = new List<IssueSeverityAnnotation>();
        if (String.isBlank(response)) return result;

        try {
            String cleaned = stripCodeFences(response);
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
            if (!parsed.containsKey('annotations') || !(parsed.get('annotations') instanceof List<Object>)) {
                return result;
            }
            for (Object o : (List<Object>) parsed.get('annotations')) {
                if (!(o instanceof Map<String, Object>)) continue;
                Map<String, Object> m = (Map<String, Object>) o;
                IssueSeverityAnnotation a = new IssueSeverityAnnotation();
                if (m.get('index') != null) {
                    try { a.index = Integer.valueOf(String.valueOf(m.get('index'))); }
                    catch (Exception ex) { a.index = null; }
                }
 // Impact-only: effort/priority keys in the response are
                // ignored — the pipeline severity path carries Impact alone.
                a.impact = nullableString(m.get('impact'));
                if (a.index != null && a.index >= 0 && a.index < issueCount) {
                    result.add(a);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'Failed to parse issue severity annotations: ' + e.getMessage());
        }
        return result;
    }

    // =====================================================================
    // New DTOs for Tiers 3-5
    // =====================================================================

    public class CandidateSummary {
        public String articleVersionId;
        public String title;
        public String summary;

        public CandidateSummary(String articleVersionId, String title, String summary) {
            this.articleVersionId = articleVersionId;
            this.title = title;
            this.summary = summary;
        }
    }

    public class TriageResult {
        @AuraEnabled public List<Integer> topCandidateIndexes;

        public TriageResult() {
            this.topCandidateIndexes = new List<Integer>();
        }
    }

    public class FactEvaluationResult {
        @AuraEnabled public Boolean isDuplicate;
        @AuraEnabled public Decimal confidenceScore;
        @AuraEnabled public String reasoning;
        @AuraEnabled public String anomalyType; // Duplicate or Contradiction ('Overlap' retired)

        public FactEvaluationResult() {
            this.isDuplicate = false;
            this.confidenceScore = 0;
        }
    }

}
