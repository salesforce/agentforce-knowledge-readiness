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
private class PromptTemplateServiceTest {

    @IsTest
    static void testMockInjection() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.mockDraftResult = new PromptTemplateService.DraftEvaluationResult();
        mock.mockDraftResult.hasConflict = false;

        PromptTemplateService.setMock(mock);

        PromptTemplateService service = PromptTemplateService.getInstance();
        PromptTemplateService.DraftEvaluationResult result = service.evaluateDraft(
            'Test text', new List<VectorSearchResult>()
        );

        System.assertEquals(false, result.hasConflict, 'Mock should return clean result');
        System.assertEquals(1, mock.draftCallCount, 'Draft should be called once');
    }

    @IsTest
    static void testMockAnomalyEvaluation() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.mockAnomalyResult = new PromptTemplateService.AnomalyEvaluationResult();
        mock.mockAnomalyResult.isAnomaly = true;
        mock.mockAnomalyResult.anomalyType = 'Contradiction';
        mock.mockAnomalyResult.reasoning = 'Articles contradict on procedure.';

        PromptTemplateService.setMock(mock);

        PromptTemplateService service = PromptTemplateService.getInstance();
        PromptTemplateService.AnomalyEvaluationResult result = service.evaluatePublishedPair(
            'Article A text', 'Article B text', 'idA', 'idB'
        );

        System.assertEquals(true, result.isAnomaly, 'Should be flagged as anomaly');
        System.assertEquals('Contradiction', result.anomalyType);
        System.assertEquals(1, mock.anomalyCallCount, 'Anomaly should be called once');
    }

    @IsTest
    static void testMockThrowsException() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.throwException = true;

        PromptTemplateService.setMock(mock);

        PromptTemplateService service = PromptTemplateService.getInstance();

        try {
            service.evaluateDraft('Test', new List<VectorSearchResult>());
            System.assert(false, 'Should have thrown exception');
        } catch (KnowledgeAIException e) {
            System.assert(e.getMessage().contains('Mock LLM error'));
        }
    }

    @IsTest
    static void testDraftEvaluationResultDefaults() {
        PromptTemplateService.DraftEvaluationResult result = new PromptTemplateService.DraftEvaluationResult();
        System.assertEquals(false, result.hasConflict, 'Default should be no conflict');
        System.assertNotEquals(null, result.conflicts, 'Conflicts list should be initialized');
        System.assertEquals(0, result.conflicts.size(), 'Conflicts should be empty');
    }

    @IsTest
    static void testAnomalyEvaluationResultDefaults() {
        PromptTemplateService.AnomalyEvaluationResult result = new PromptTemplateService.AnomalyEvaluationResult();
        System.assertEquals(false, result.isAnomaly, 'Default should be no anomaly');
    }

    // ──────────────────────────────────────────────────────────────────────
    // draftMergedArticle (Tier 4 Golden Record)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testDraftMergedArticle_ReturnsMergedContent() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.mockMergedContent = '<h2>Golden Record</h2><p>Merged from A and B.</p>';
        PromptTemplateService.setMock(mock);

        Test.startTest();
        PromptTemplateService service = PromptTemplateService.getInstance();
        String result = service.draftMergedArticle(
            'Article A body text about password resets.',
            'Article B body text about resetting your password.',
            'en_US'
        );
        Test.stopTest();

        Assert.areEqual('<h2>Golden Record</h2><p>Merged from A and B.</p>', result,
            'Should return the mock merged content');
        Assert.areEqual(1, mock.mergeCallCount, 'draftMergedArticle called once');
    }

    @IsTest
    static void testDraftMergedArticle_ThrowsOnLLMFailure() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.throwException = true;
        PromptTemplateService.setMock(mock);

        PromptTemplateService service = PromptTemplateService.getInstance();

        Test.startTest();
        Boolean threw = false;
        try {
            service.draftMergedArticle('Text A', 'Text B', 'en_US');
        } catch (KnowledgeAIException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Mock merge error'),
                'Exception message should surface the LLM error');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Should throw KnowledgeAIException when LLM fails');
        Assert.areEqual(1, mock.mergeCallCount, 'Method was attempted');
    }

    // ──────────────────────────────────────────────────────────────────────
    // invokePromptTemplate exception contract
    // ──────────────────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────────────────
 // Scoring-temperature pinning
    //
    // The Einstein call inside invokePromptTemplate is unreachable in a test
    // transaction, so we can't read back additionalConfig.temperature from a
    // live response. Instead the set-membership decision is factored into the
    // @TestVisible isScoringTemplate(...) helper and the constants are
    // @TestVisible — we assert the policy there: scoring/eval templates pin the
    // low temperature, draft/merge/rewrite/triage/extract templates do not.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testIsScoringTemplate_ScoringTemplatesPinned() {
        // Every evaluation/judgement call must be recognised as scoring so it
        // receives SCORING_TEMPERATURE: the readiness-scoring templates, the
        // severity-annotation call, and the two pipeline evaluators
        // (Evaluate_Extracted_Facts, Published_Anomaly_Evaluator) which return
        // a duplicate/anomaly judgement rather than generated prose.
        Assert.isTrue(PromptTemplateService.isScoringTemplate('Evaluate_Structure'),
            'Evaluate_Structure is a scoring template');
        Assert.isTrue(PromptTemplateService.isScoringTemplate('Evaluate_Clarity'),
            'Evaluate_Clarity is a scoring template');
        Assert.isTrue(PromptTemplateService.isScoringTemplate('Evaluate_Completeness'),
            'Evaluate_Completeness is a scoring template');
        Assert.isTrue(PromptTemplateService.isScoringTemplate('Annotate_Issue_Severity'),
            'Annotate_Issue_Severity is an evaluation call and is pinned too');
        Assert.isTrue(PromptTemplateService.isScoringTemplate('Evaluate_Extracted_Facts'),
            'Evaluate_Extracted_Facts judges duplicate/confidence — an evaluation, pinned');
        Assert.isTrue(PromptTemplateService.isScoringTemplate('Published_Anomaly_Evaluator'),
            'Published_Anomaly_Evaluator judges anomaly/contradiction — an evaluation, pinned');
    }

    @IsTest
    static void testIsScoringTemplate_GenerativeTemplatesNotPinned() {
        // GENERATIVE templates (draft / merge / fix / triage-selection /
        // fact-extraction) keep the platform default — low temperature would
        // make their prose robotic. Note: the *evaluators*
        // Evaluate_Extracted_Facts and Published_Anomaly_Evaluator are NOT here —
        // they are judgement calls and ARE pinned (see the scoring test).
        Assert.isFalse(PromptTemplateService.isScoringTemplate('Draft_Merged_Knowledge_Article'),
            'Draft_Merged_Knowledge_Article keeps default temperature');
        Assert.isFalse(PromptTemplateService.isScoringTemplate('Fix_Article_Issues_V2'),
            'Fix_Article_Issues_V2 keeps default temperature');
        Assert.isFalse(PromptTemplateService.isScoringTemplate('Draft_Evaluator'),
            'Draft_Evaluator keeps default temperature');
        Assert.isFalse(PromptTemplateService.isScoringTemplate('Triage_Duplicate_Candidates'),
            'Triage_Duplicate_Candidates keeps default temperature');
        Assert.isFalse(PromptTemplateService.isScoringTemplate('Extract_Article_Facts'),
            'Extract_Article_Facts keeps default temperature');
    }

    @IsTest
    static void testIsScoringTemplate_NullAndUnknownNotPinned() {
        Assert.isFalse(PromptTemplateService.isScoringTemplate(null),
            'Null template name is not scoring (guards NPE on Set.contains)');
        Assert.isFalse(PromptTemplateService.isScoringTemplate('Some_Unknown_Template'),
            'Unknown template defaults to non-scoring (platform default temperature)');
    }

    @IsTest
    static void testScoringTemperature_IsLowAndInValidRange() {
        // The pinned value must be as low as possible for determinism and
        // within the platform-accepted range.
        Assert.areEqual(0.0, PromptTemplateService.SCORING_TEMPERATURE,
            'Scoring temperature is pinned to 0.0 for maximum determinism');
        Assert.isTrue(PromptTemplateService.SCORING_TEMPERATURE >= 0.0
            && PromptTemplateService.SCORING_TEMPERATURE <= 2.0,
            'Scoring temperature stays within the accepted 0.0–2.0 range');
    }

    @IsTest
    static void testBuildInput_PinsTemperatureForScoringTemplateOnly() {
        // Closes the wiring gap: assert buildInput actually writes
        // additionalConfig.temperature for a scoring template, and leaves it
        // unset for a generative one. (invokePromptTemplate's Einstein callout
        // is unreachable in a test transaction, so buildInput is the seam.)
        Map<String, ConnectApi.WrappedValue> params =
            new Map<String, ConnectApi.WrappedValue>();

        ConnectApi.EinsteinPromptTemplateGenerationsInput scoringInput =
            PromptTemplateService.buildInput('Evaluate_Clarity', params);
        Assert.areEqual(
            PromptTemplateService.SCORING_TEMPERATURE,
            scoringInput.additionalConfig.temperature,
            'Scoring template input is pinned to SCORING_TEMPERATURE');
        Assert.areEqual('PromptTemplateGenerationsInvocable',
            scoringInput.additionalConfig.applicationName,
            'applicationName is preserved alongside the temperature pin');

        ConnectApi.EinsteinPromptTemplateGenerationsInput generativeInput =
            PromptTemplateService.buildInput('Draft_Merged_Knowledge_Article', params);
        Assert.isNull(generativeInput.additionalConfig.temperature,
            'Generative template input leaves temperature unset (platform default)');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Parser direct coverage (via @TestVisible)
    //
    // The Einstein call path is unreachable in test transactions, but the
    // JSON-parsing logic accounts for the bulk of the uncovered LOC. We
    // call the @TestVisible parsers directly on a freshly-constructed
    // service — no mock needed, no ConnectApi round-trip.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testParseDraftEvaluationResult_HappyPathWithConflicts() {
        PromptTemplateService svc = new PromptTemplateService();
        String json = '{'
            + '"hasConflict":true,'
            + '"conflicts":['
            +   '{"articleId":"ka01","articleTitle":"Old Article","type":"Contradiction","reasoning":"Different procedure"},'
            +   '{"articleId":"ka02","articleTitle":"Other","type":"Overlap","reasoning":"Same scope"}'
            + ']}';

        PromptTemplateService.DraftEvaluationResult result = svc.parseDraftEvaluationResult(json);

        Assert.isTrue(result.hasConflict, 'hasConflict surfaced');
        Assert.areEqual(2, result.conflicts.size(), 'Both conflicts parsed');
        Assert.areEqual('ka01', result.conflicts[0].conflictingArticleId);
        Assert.areEqual('Old Article', result.conflicts[0].conflictingArticleTitle);
        Assert.areEqual('Contradiction', result.conflicts[0].conflictType);
        Assert.areEqual('Different procedure', result.conflicts[0].reasoning);
    }

    @IsTest
    static void testParseDraftEvaluationResult_EmptyConflictsArray() {
        PromptTemplateService svc = new PromptTemplateService();
        PromptTemplateService.DraftEvaluationResult result =
            svc.parseDraftEvaluationResult('{"hasConflict":false,"conflicts":[]}');

        Assert.isFalse(result.hasConflict);
        Assert.areEqual(0, result.conflicts.size(), 'Empty conflicts list');
    }

    @IsTest
    static void testParseDraftEvaluationResult_MalformedThrows() {
        PromptTemplateService svc = new PromptTemplateService();

        Boolean threw = false;
        try {
            svc.parseDraftEvaluationResult('{not-valid');
        } catch (KnowledgeAIException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Failed to parse draft'),
                'Wrapped error references draft parser');
        }
        Assert.isTrue(threw, 'Malformed JSON throws KnowledgeAIException');
    }

    @IsTest
    static void testParseAnomalyEvaluationResult_HappyPath() {
        PromptTemplateService svc = new PromptTemplateService();
        PromptTemplateService.AnomalyEvaluationResult result = svc.parseAnomalyEvaluationResult(
            '{"isAnomaly":true,"anomalyType":"Contradiction","reasoning":"They disagree"}'
        );

        Assert.isTrue(result.isAnomaly);
        Assert.areEqual('Contradiction', result.anomalyType);
        Assert.areEqual('They disagree', result.reasoning);
    }

    @IsTest
    static void testParseAnomalyEvaluationResult_MalformedThrows() {
        PromptTemplateService svc = new PromptTemplateService();
        Boolean threw = false;
        try {
            svc.parseAnomalyEvaluationResult('not-json-at-all');
        } catch (KnowledgeAIException e) {
            threw = true;
        }
        Assert.isTrue(threw);
    }

    @IsTest
    static void testParseTriageResult_HappyPath() {
        PromptTemplateService svc = new PromptTemplateService();
        PromptTemplateService.TriageResult r = svc.parseTriageResult(
            '{"top_candidates":[0,2,4]}', 5
        );

        Assert.areEqual(3, r.topCandidateIndexes.size());
        Assert.areEqual(0, r.topCandidateIndexes[0]);
        Assert.areEqual(2, r.topCandidateIndexes[1]);
        Assert.areEqual(4, r.topCandidateIndexes[2]);
    }

    @IsTest
    static void testParseTriageResult_NullIndexesReturnsEmpty() {
        PromptTemplateService svc = new PromptTemplateService();
        PromptTemplateService.TriageResult r = svc.parseTriageResult(
            '{"top_candidates":null}', 5
        );

        Assert.areEqual(0, r.topCandidateIndexes.size(),
            'Null top_candidates yields empty list');
    }

    @IsTest
    static void testParseTriageResult_OutOfBoundsFiltered() {
        PromptTemplateService svc = new PromptTemplateService();
        // candidateCount=3 → indexes 0,1,2 valid; 3,99 dropped; -1 dropped.
        PromptTemplateService.TriageResult r = svc.parseTriageResult(
            '{"top_candidates":[-1,0,1,2,3,99]}', 3
        );

        Assert.areEqual(3, r.topCandidateIndexes.size(),
            'Only in-bounds indexes retained');
        Assert.isTrue(r.topCandidateIndexes.contains(0));
        Assert.isTrue(r.topCandidateIndexes.contains(1));
        Assert.isTrue(r.topCandidateIndexes.contains(2));
    }

    @IsTest
    static void testParseTriageResult_MalformedReturnsEmpty() {
        PromptTemplateService svc = new PromptTemplateService();
        // Triage parser is forgiving: malformed input returns an empty
        // result instead of throwing, so the pipeline can exit gracefully.
        PromptTemplateService.TriageResult r = svc.parseTriageResult(
            '{not-valid', 5
        );

        Assert.areEqual(0, r.topCandidateIndexes.size());
    }

    @IsTest
    static void testParseFactEvaluationResult_HappyPath() {
        PromptTemplateService svc = new PromptTemplateService();
        PromptTemplateService.FactEvaluationResult r = svc.parseFactEvaluationResult(
            '{"is_duplicate":true,"confidence_score":0.92,"reasoning":"Same procedure","anomaly_type":"Duplicate"}'
        );

        Assert.isTrue(r.isDuplicate);
        Assert.areEqual(0.92, r.confidenceScore);
        Assert.areEqual('Same procedure', r.reasoning);
        Assert.areEqual('Duplicate', r.anomalyType);
    }

    @IsTest
    static void testParseFactEvaluationResult_MalformedThrows() {
        PromptTemplateService svc = new PromptTemplateService();
        Boolean threw = false;
        try {
            svc.parseFactEvaluationResult('not-json');
        } catch (KnowledgeAIException e) {
            threw = true;
        }
        Assert.isTrue(threw);
    }

    // ──────────────────────────────────────────────────────────────────────
    // parseLLMEvaluationResult — fence stripping, score type coercion,
    // type-specific switch arms.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testParseLLMResult_ScoreAsInteger() {
        PromptTemplateService svc = new PromptTemplateService();
        PromptTemplateService.LLMEvaluationResult r = svc.parseLLMEvaluationResult(
            '{"score":80,"reasoning":"OK"}', 'structure'
        );

        Assert.isTrue(r.success);
        Assert.areEqual(80, r.score);
        Assert.areEqual('OK', r.reasoning);
    }

    @IsTest
    static void testParseLLMResult_ScoreAsDecimal() {
        PromptTemplateService svc = new PromptTemplateService();
        PromptTemplateService.LLMEvaluationResult r = svc.parseLLMEvaluationResult(
            '{"score":82.5,"reasoning":"Good"}', 'clarity'
        );

        Assert.isTrue(r.success);
        Assert.areEqual(82.5, r.score);
    }

    @IsTest
    static void testParseLLMResult_JsonFenceStripped() {
        PromptTemplateService svc = new PromptTemplateService();
        String fenced = '```json\n{"score":75,"reasoning":"fenced"}\n```';
        PromptTemplateService.LLMEvaluationResult r = svc.parseLLMEvaluationResult(fenced, 'clarity');

        Assert.isTrue(r.success, '```json fence stripped before parsing');
        Assert.areEqual(75, r.score);
    }

    @IsTest
    static void testParseLLMResult_TripleBacktickFenceStripped() {
        PromptTemplateService svc = new PromptTemplateService();
        String fenced = '```\n{"score":60,"reasoning":"plain fence"}\n```';
        PromptTemplateService.LLMEvaluationResult r = svc.parseLLMEvaluationResult(fenced, 'clarity');

        Assert.isTrue(r.success);
        Assert.areEqual(60, r.score);
    }

    @IsTest
    static void testParseLLMResult_MalformedSetsErrorMessage() {
        PromptTemplateService svc = new PromptTemplateService();
        PromptTemplateService.LLMEvaluationResult r = svc.parseLLMEvaluationResult(
            'totally not json', 'structure'
        );

        Assert.isFalse(r.success, 'Parse failure leaves success=false');
        Assert.isNotNull(r.errorMessage, 'Error message populated');
        Assert.isTrue(r.reasoning.startsWith('Raw response:'),
            'Reasoning falls back to truncated raw response');
    }

    @IsTest
    static void testParseLLMResult_StructureSwitchArm() {
        // The Structure response shape is now per-field (mirrors Completeness),
        // plus a top-level topicDrifts list. The old isSingleTopic/mainTopic
        // shape was retired with the prompt rewrite — see structure.md.
        PromptTemplateService svc = new PromptTemplateService();
        String json = '{'
            + '"score":85,'
            + '"reasoning":"Single topic with minor drift",'
            + '"topicDrifts":["intro mentions billing"],'
            + '"fieldResults":[{'
            + '  "field":"Resolution__c",'
            + '  "issues":["nested bullets will lose context"],'
            + '  "strengths":["each section is self-contained"]'
            + '}]'
            + '}';
        PromptTemplateService.LLMEvaluationResult r = svc.parseLLMEvaluationResult(json, 'structure');

        Assert.isTrue(r.success);
        Assert.areEqual(2, r.issues.size(),
            'Per-field issues + topicDrifts both flow into result.issues');
        Boolean hasFieldPrefixed = false;
        Boolean hasDrift = false;
        for (String issue : r.issues) {
            if (issue.startsWith('Resolution__c: ')) hasFieldPrefixed = true;
            if (issue.startsWith('Topic drift: ')) hasDrift = true;
        }
        Assert.isTrue(hasFieldPrefixed, 'Per-field issue prefixed with field API name');
        Assert.isTrue(hasDrift, 'Topic drift entry preserved with prefix');

        Assert.areEqual(1, r.strengths.size(), 'Per-field strengths surface');
        Assert.isTrue(r.strengths[0].startsWith('Resolution__c: '),
            'Per-field strength prefixed with field API name');
    }

    @IsTest
    static void testParseLLMResult_ClaritySwitchArm() {
        PromptTemplateService svc = new PromptTemplateService();
        String json = '{'
            + '"score":70,'
            + '"clarityIssues":["pronoun ambiguity"],'
            + '"strengths":["clear headings"]'
            + '}';
        PromptTemplateService.LLMEvaluationResult r = svc.parseLLMEvaluationResult(json, 'clarity');

        Assert.areEqual(1, r.issues.size());
        Assert.areEqual('pronoun ambiguity', r.issues[0],
            'Clarity issues use no prefix');
        Assert.areEqual(1, r.strengths.size());
        Assert.areEqual('clear headings', r.strengths[0]);
    }

    @IsTest
    static void testParseLLMResult_ChunkingSwitchArm() {
        PromptTemplateService svc = new PromptTemplateService();
        String json = '{'
            + '"score":65,'
            + '"orphanedReferences":["see above"],'
            + '"selfContainedSections":4'
            + '}';
        PromptTemplateService.LLMEvaluationResult r = svc.parseLLMEvaluationResult(json, 'chunking');

        Assert.areEqual(1, r.issues.size());
        Assert.isTrue(r.issues[0].startsWith('Orphaned: '));
        Assert.areEqual(1, r.strengths.size());
        Assert.isTrue(r.strengths[0].contains('4 self-contained sections'));
    }

    @IsTest
    static void testParseLLMResult_ConflictSwitchArm() {
        PromptTemplateService svc = new PromptTemplateService();
        String json = '{'
            + '"score":40,'
            + '"contradictions":["different procedure"],'
            + '"complementary":["matching prerequisite"]'
            + '}';
        PromptTemplateService.LLMEvaluationResult r = svc.parseLLMEvaluationResult(json, 'conflict');

        Assert.areEqual(1, r.issues.size());
        Assert.isTrue(r.issues[0].startsWith('Contradiction: '));
        Assert.areEqual(1, r.strengths.size());
        Assert.isTrue(r.strengths[0].startsWith('Complementary: '));
    }

    // ──────────────────────────────────────────────────────────────────────
    // Helpers — extractListField, truncateForLLM
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testExtractListField_NotAListShortCircuits() {
        PromptTemplateService svc = new PromptTemplateService();
        Map<String, Object> parsed = new Map<String, Object>{
            'someField' => 'not-a-list'
        };
        List<String> target = new List<String>();

        svc.extractListField(parsed, 'someField', target, 'P: ');

        Assert.areEqual(0, target.size(),
            'Non-list value short-circuits without throwing');
    }

    @IsTest
    static void testExtractListField_FiltersBlankAndNullStrings() {
        PromptTemplateService svc = new PromptTemplateService();
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
            '{"items":["good",null,"","also good"]}'
        );
        List<String> target = new List<String>();

        svc.extractListField(parsed, 'items', target, 'X: ');

        // Two valid entries kept; null and blank dropped.
        Assert.areEqual(2, target.size(), 'Only non-blank, non-null strings retained');
        Assert.areEqual('X: good', target[0]);
        Assert.areEqual('X: also good', target[1]);
    }

    @IsTest
    static void testTruncateForLLM_BlankReturnsEmpty() {
        PromptTemplateService svc = new PromptTemplateService();
        Assert.areEqual('', svc.truncateForLLM('', 100));
        Assert.areEqual('', svc.truncateForLLM(null, 100));
    }

    @IsTest
    static void testTruncateForLLM_UnderLimitUnchanged() {
        PromptTemplateService svc = new PromptTemplateService();
        Assert.areEqual('short', svc.truncateForLLM('short', 100));
    }

    @IsTest
    static void testTruncateForLLM_OverLimitTruncates() {
        PromptTemplateService svc = new PromptTemplateService();
        String longText = 'abcdefghij';
        String out = svc.truncateForLLM(longText, 5);

        Assert.isTrue(out.startsWith('abcde'));
        Assert.isTrue(out.endsWith('[truncated]'),
            'Truncation suffix appended');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Public-method paths still uncovered (mock-driven)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testTriageDuplicateCandidates_DelegatesToMock() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.TriageResult mockResult = new PromptTemplateService.TriageResult();
        mockResult.topCandidateIndexes = new List<Integer>{ 0, 1 };
        mock.mockTriageResult = mockResult;
        PromptTemplateService.setMock(mock);

        List<PromptTemplateService.CandidateSummary> candidates =
            new List<PromptTemplateService.CandidateSummary>{
                new PromptTemplateService.CandidateSummary('id1', 'Title A', 'Sum A'),
                new PromptTemplateService.CandidateSummary('id2', 'Title B', 'Sum B')
            };

        PromptTemplateService.TriageResult r = PromptTemplateService.getInstance()
            .triageDuplicateCandidates('Target', 'Target sum', candidates);

        Assert.areEqual(2, r.topCandidateIndexes.size());
        Assert.areEqual(1, mock.triageCallCount);
    }

    @IsTest
    static void testExtractArticleFacts_DelegatesToMock() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.mockExtractedFacts = '- A fact\n- Another fact';
        PromptTemplateService.setMock(mock);

        String facts = PromptTemplateService.getInstance().extractArticleFacts('chunk text');

        Assert.areEqual('- A fact\n- Another fact', facts);
        Assert.areEqual(1, mock.extractFactsCallCount);
    }

    @IsTest
    static void testEvaluateExtractedFacts_DelegatesToMock() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FactEvaluationResult mockRes = new PromptTemplateService.FactEvaluationResult();
        mockRes.isDuplicate = true;
        mockRes.confidenceScore = 0.95;
        mock.mockFactEvalResult = mockRes;
        PromptTemplateService.setMock(mock);

        PromptTemplateService.FactEvaluationResult r = PromptTemplateService.getInstance()
            .evaluateExtractedFacts('facts A', 'facts B');

        Assert.isTrue(r.isDuplicate);
        Assert.areEqual(0.95, r.confidenceScore);
        Assert.areEqual(1, mock.factEvalCallCount);
    }

    @IsTest
    static void testDraftMergedCluster_EmptyReturnsEmptyString() {
        // Direct call on the real service — no LLM round-trip needed for
        // the empty-list short-circuit branch.
        PromptTemplateService svc = new PromptTemplateService();
        Assert.areEqual('', svc.draftMergedCluster(null, 'en_US'));
        Assert.areEqual('', svc.draftMergedCluster(new List<String>(), 'en_US'));
    }

    @IsTest
    static void testDraftMergedCluster_SingleArticleReturnsAsIs() {
        PromptTemplateService svc = new PromptTemplateService();
        String only = '<p>Only article body.</p>';
        Assert.areEqual(only, svc.draftMergedCluster(new List<String>{ only }, 'en_US'),
            'Single-article cluster returns input unchanged — no LLM call');
    }

    @IsTest
    static void testDraftMergedCluster_TwoArticlesCallsMergeOnce() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.mockMergedContent = '<p>MERGED</p>';
        PromptTemplateService.setMock(mock);

        String result = PromptTemplateService.getInstance().draftMergedCluster(
            new List<String>{ '<p>A</p>', '<p>B</p>' }, 'en_US'
        );

        Assert.areEqual('<p>MERGED</p>', result);
        Assert.areEqual(1, mock.mergeCallCount, 'Two-article cluster → single merge call');
    }

    @IsTest
    static void testDraftMergedCluster_FourArticlesIteratesThreeTimes() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.mockMergedContent = '<p>RUNNING</p>';
        PromptTemplateService.setMock(mock);

        String result = PromptTemplateService.getInstance().draftMergedCluster(
            new List<String>{ '<p>A</p>', '<p>B</p>', '<p>C</p>', '<p>D</p>' }, 'en_US'
        );

        Assert.areEqual('<p>RUNNING</p>', result);
        Assert.areEqual(3, mock.mergeCallCount,
            'Four-article cluster iterates 3 times (running ⊕ B, ⊕ C, ⊕ D)');
    }

    // ──────────────────────────────────────────────────────────────────────
    // Readiness scorer exception fallbacks — each evaluate* method must
    // catch the inner exception and return an LLMEvaluationResult with
    // errorMessage populated rather than rethrowing. Setting mock=null
    // forces the real ConnectApi.EinsteinLlm call, which throws inside
    // a test transaction and exercises the catch block.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testEvaluateStructure_ExceptionReturnsErrorResult() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = new PromptTemplateService();

        Test.startTest();
        PromptTemplateService.LLMEvaluationResult r = svc.evaluateStructure('Title', 'Content', 'Summary');
        Test.stopTest();

        Assert.isNotNull(r.errorMessage, 'Errors swallowed into errorMessage');
        Assert.isTrue(r.errorMessage.contains('Structure evaluation failed'));
    }

    @IsTest
    static void testEvaluateClarity_ExceptionReturnsErrorResult() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = new PromptTemplateService();

        Test.startTest();
        PromptTemplateService.LLMEvaluationResult r = svc.evaluateClarity('Title', 'Content', 'Summary');
        Test.stopTest();

        Assert.isTrue(r.errorMessage.contains('Clarity evaluation failed'));
    }

    // ──────────────────────────────────────────────────────────────────────
    // Misc
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testIsEinsteinAvailable_ReturnsBooleanWithoutThrowing() {
        // Org-state-dependent — assert non-null Boolean only so the test
        // is portable across SDOs/scratch orgs with or without Einstein.
        Boolean available = PromptTemplateService.isEinsteinAvailable();
        Assert.isNotNull(available, 'Returns a Boolean either way');
    }

    @IsTest
    static void testCandidateSummary_ConstructorAssignsFields() {
        PromptTemplateService.CandidateSummary cs =
            new PromptTemplateService.CandidateSummary('id-1', 'A title', 'A summary');

        Assert.areEqual('id-1', cs.articleVersionId);
        Assert.areEqual('A title', cs.title);
        Assert.areEqual('A summary', cs.summary);
    }

    @IsTest
    static void testTriageResult_DefaultIsEmptyList() {
        PromptTemplateService.TriageResult r = new PromptTemplateService.TriageResult();
        Assert.isNotNull(r.topCandidateIndexes);
        Assert.areEqual(0, r.topCandidateIndexes.size());
    }

    @IsTest
    static void testFactEvaluationResult_Defaults() {
        PromptTemplateService.FactEvaluationResult r = new PromptTemplateService.FactEvaluationResult();
        Assert.isFalse(r.isDuplicate);
        Assert.areEqual(0, r.confidenceScore);
    }

    @IsTest
    static void testInvokePromptTemplateWrapsAllExceptionsAsKnowledgeAIException() {
        // The real Einstein runtime is not reachable from a test transaction (or returns
        // an unexpected variant such as EinsteinLlmGenerationSafetyScoreOutput). Either path
        // must surface as KnowledgeAIException — the queueable relies on that contract so its
        // outer catch can keep the assessment chain running rather than aborting mid-batch.
        PromptTemplateService.setMock(null);
        PromptTemplateService service = new PromptTemplateService();
        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();

        Test.startTest();
        Boolean threwKnowledgeAIException = false;
        try {
            service.invokePromptTemplate('Nonexistent_Template_For_Test', inputParams);
        } catch (KnowledgeAIException e) {
            threwKnowledgeAIException = true;
            System.assert(
                e.getMessage().contains('Nonexistent_Template_For_Test'),
                'Wrapped message should reference the template name. Got: ' + e.getMessage()
            );
        }
        Test.stopTest();

        System.assertEquals(
            true,
            threwKnowledgeAIException,
            'Any failure inside invokePromptTemplate must rethrow as KnowledgeAIException, '
                + 'so the queueable + scorer fallbacks can keep the chain running.'
        );
    }

    // ──────────────────────────────────────────────────────────────────────
 // annotateIssueSeverity (LLM emits effort/impact/priority)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testAnnotateIssueSeverity_EmptyIssues_ReturnsEmpty() {
        PromptTemplateService.setMock(null);
        PromptTemplateService service = new PromptTemplateService();

        List<PromptTemplateService.IssueSeverityAnnotation> result =
            service.annotateIssueSeverity('T', 'S', 'C', '', '', '', new List<String>(), new List<String>());

        Assert.areEqual(0, result.size(), 'Empty issue list short-circuits the LLM call');
    }

    @IsTest
    static void testAnnotateIssueSeverity_MockReturnsAnnotationsByIndex() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.IssueSeverityAnnotation a0 =
            new PromptTemplateService.IssueSeverityAnnotation();
        a0.index = 0; a0.impact = 'High';
        PromptTemplateService.IssueSeverityAnnotation a1 =
            new PromptTemplateService.IssueSeverityAnnotation();
        a1.index = 1; a1.impact = 'Low';
        mock.mockSeverityAnnotations = new List<PromptTemplateService.IssueSeverityAnnotation>{ a0, a1 };
        PromptTemplateService.setMock(mock);

        PromptTemplateService service = PromptTemplateService.getInstance();
        List<String> strengths = new List<String>{ 'Clear summary', 'Good headers' };
        List<PromptTemplateService.IssueSeverityAnnotation> result = service.annotateIssueSeverity(
            'Title A', 'Summary A', 'Body A',
            'Title B', 'Summary B', 'Body B',
            new List<String>{ 'Issue zero', 'Issue one' },
            strengths
        );

        Assert.areEqual(2, result.size(), 'One annotation per issue');
        Assert.areEqual(1, mock.annotateSeverityCallCount);
        Assert.areEqual(2, mock.annotateSeverityLastIssueCount);
        Assert.areEqual('High', result[0].impact);
        Assert.areEqual('Low', result[1].impact, 'Impact-only severity carried per index');
        Assert.areEqual(strengths, mock.annotateSeverityLastStrengths,
            'Strengths are forwarded so the model can avoid recommending fixes that erode them');
        Assert.areEqual('Body A', mock.annotateSeverityLastArticleContent,
            'Full article body (composed from configured content fields) reaches the LLM');
        Assert.areEqual('Body B', mock.annotateSeverityLastCounterpartContent);
    }

    @IsTest
    static void testAnnotateIssueSeverity_MockThrows_ReturnsEmptyButDoesNotPropagate() {
        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.throwException = true;
        PromptTemplateService.setMock(mock);

        PromptTemplateService service = PromptTemplateService.getInstance();
        List<PromptTemplateService.IssueSeverityAnnotation> result = service.annotateIssueSeverity(
            'T', 'S', 'C', '', '', '',
            new List<String>{ 'Some issue' },
            new List<String>()
        );

        Assert.areEqual(0, result.size(),
            'Severity annotation is best-effort — failures must NOT bubble out');
    }

    @IsTest
    static void testParseSeverityAnnotations_ValidJson() {
        PromptTemplateService svc = new PromptTemplateService();
        // The response still carries legacy effort/priority keys; the parser
 // must tolerate (ignore) them and read impact only.
        String response =
            '{"annotations":['
            + '{"index":0,"impact":"High","effort":"Quick Win","priority":"High"},'
            + '{"index":1,"impact":"Medium","effort":"Low","priority":"Medium"}'
            + ']}';

        List<PromptTemplateService.IssueSeverityAnnotation> result =
            svc.parseSeverityAnnotations(response, 2);

        Assert.areEqual(2, result.size());
        Assert.areEqual(0, result[0].index);
        Assert.areEqual('High', result[0].impact);
        Assert.areEqual('Medium', result[1].impact);
    }

    @IsTest
    static void testParseSeverityAnnotations_StrippedMarkdownFences() {
        PromptTemplateService svc = new PromptTemplateService();
        String response =
            '```json\n'
            + '{"annotations":[{"index":0,"impact":"Low","effort":"Low","priority":"Low"}]}\n'
            + '```';

        List<PromptTemplateService.IssueSeverityAnnotation> result =
            svc.parseSeverityAnnotations(response, 1);

        Assert.areEqual(1, result.size(), 'Markdown fences should be stripped before parse');
        Assert.areEqual('Low', result[0].impact);
    }

    @IsTest
    static void testParseSeverityAnnotations_OutOfRangeIndex_Filtered() {
        PromptTemplateService svc = new PromptTemplateService();
        String response =
            '{"annotations":['
            + '{"index":0,"impact":"High","effort":"Low","priority":"High"},'
            + '{"index":99,"impact":"Low","effort":"Low","priority":"Low"}'
            + ']}';

        List<PromptTemplateService.IssueSeverityAnnotation> result =
            svc.parseSeverityAnnotations(response, 1);

        Assert.areEqual(1, result.size(),
            'Annotations with index >= issueCount must be discarded');
        Assert.areEqual(0, result[0].index);
    }

    @IsTest
    static void testParseSeverityAnnotations_MalformedReturnsEmpty() {
        PromptTemplateService svc = new PromptTemplateService();
        // Should NOT throw — best-effort parser returns empty on parse failure
        List<PromptTemplateService.IssueSeverityAnnotation> result =
            svc.parseSeverityAnnotations('not-json', 3);

        Assert.areEqual(0, result.size());
    }

    @IsTest
    static void testBuildSeverityPayload_FullPayload() {
        PromptTemplateService svc = new PromptTemplateService();
        String payload = svc.buildSeverityPayload(
            'Title A', 'Summary A', 'Content A',
            'Title B', 'Summary B', 'Content B',
            new List<String>{ 'Issue one', 'Issue two' },
            new List<String>{ 'Strength one', 'Strength two' }
        );

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payload);
        Assert.isTrue(parsed.containsKey('article'),     'Article node always present');
        Assert.isTrue(parsed.containsKey('counterpart'), 'Counterpart node always present');
        Assert.isTrue(parsed.containsKey('issues'),      'Issues array always present');
        Assert.isTrue(parsed.containsKey('strengths'),   'Strengths array always present');

        Map<String, Object> article = (Map<String, Object>) parsed.get('article');
        Assert.areEqual('Title A',   article.get('title'));
        Assert.areEqual('Summary A', article.get('summary'));
        Assert.areEqual('Content A', article.get('content'));

        Map<String, Object> counterpart = (Map<String, Object>) parsed.get('counterpart');
        Assert.areEqual('Title B', counterpart.get('title'));

        List<Object> issues = (List<Object>) parsed.get('issues');
        Assert.areEqual(2, issues.size(), 'Both issues serialised');
        Map<String, Object> firstIssue = (Map<String, Object>) issues[0];
        Assert.areEqual(0, firstIssue.get('index'),
            'Index is preserved so the LLM response can be matched back to the original list');
        Assert.areEqual('Issue one', firstIssue.get('text'));

        List<Object> strengths = (List<Object>) parsed.get('strengths');
        Assert.areEqual(2, strengths.size(), 'Both strengths serialised');
        Assert.areEqual('Strength one', strengths[0]);
    }

    @IsTest
    static void testBuildSeverityPayload_NullCounterpart() {
        PromptTemplateService svc = new PromptTemplateService();
        String payload = svc.buildSeverityPayload(
            'Title A', null, null,
            null, null, null,
            new List<String>{ 'standalone issue' },
            null
        );

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payload);
        Assert.isNull(parsed.get('counterpart'),
            'Empty counterpart serialises to null so the LLM can short-circuit duplicate logic');
        Assert.areEqual(1, ((List<Object>) parsed.get('issues')).size());
        Assert.areEqual(0, ((List<Object>) parsed.get('strengths')).size(),
            'Null strengths serialise as empty array so the prompt schema stays stable');
    }

    @IsTest
    static void testBuildSeverityPayload_BlankIssuesSkipped() {
        PromptTemplateService svc = new PromptTemplateService();
        String payload = svc.buildSeverityPayload(
            'T', 'S', 'C',
            '', '', '',
            new List<String>{ 'real issue', '', '   ', null, 'another' },
            new List<String>{ 'kept', '', null, '   ', 'kept too' }
        );

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(payload);
        List<Object> issues = (List<Object>) parsed.get('issues');
        Assert.areEqual(2, issues.size(), 'Blank/null issues are dropped before serialisation');
        // Original index from the input list survives — first kept issue is at i=0,
        // and the next non-blank issue was originally at i=4.
        Assert.areEqual(0, ((Map<String, Object>) issues[0]).get('index'));
        Assert.areEqual(4, ((Map<String, Object>) issues[1]).get('index'));

        List<Object> strengths = (List<Object>) parsed.get('strengths');
        Assert.areEqual(2, strengths.size(),
            'Blank/null strengths are dropped — the LLM never sees padded entries');
        Assert.areEqual('kept', strengths[0]);
        Assert.areEqual('kept too', strengths[1]);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Production wrapper bodies — exercised via real PromptTemplateService.
    //
    // ConnectApi.EinsteinLlm is unreachable in test transactions, so the
    // inner callout throws. Every scoring wrapper has a try/catch that
    // returns an LLMEvaluationResult with errorMessage populated rather
    // than rethrowing. Calling these against a real (non-mock) service
    // covers the wrapper body, the input-param assembly, the catch arm,
    // and `getInstance()`'s lazy provisioning.
    //
    // The Tier 4/5 wrappers rethrow as KnowledgeAIException — covered
    // here too via try/catch.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testEvaluateStructure_FallbackOnEinsteinUnavailable() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Test.startTest();
        PromptTemplateService.LLMEvaluationResult result =
            svc.evaluateStructure('Title text', 'Content text', 'Summary text');
        Test.stopTest();

        Assert.isNotNull(result, 'Wrapper returns a result, never null');
        Assert.isFalse(result.success,
            'ConnectApi unavailable in test ctx → success stays false');
        Assert.isNotNull(result.errorMessage,
            'Catch arm populates errorMessage for the caller');
        Assert.isTrue(result.errorMessage.contains('Structure'),
            'errorMessage names the failing dimension');
    }

    @IsTest
    static void testEvaluateClarity_FallbackOnEinsteinUnavailable() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Test.startTest();
        PromptTemplateService.LLMEvaluationResult result =
            svc.evaluateClarity('Title text', 'Some article body content for the LLM.', 'Summary text');
        Test.stopTest();

        Assert.isNotNull(result.errorMessage);
        Assert.isTrue(result.errorMessage.contains('Clarity'),
            'errorMessage names the failing dimension');
    }

    @IsTest
    static void testEvaluateCompleteness_FallbackOnEinsteinUnavailable() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Test.startTest();
        PromptTemplateService.LLMEvaluationResult result =
            svc.evaluateCompleteness('Title', 'Body', 'Summary');
        Test.stopTest();

        Assert.isNotNull(result.errorMessage,
            'Completeness wrapper populates errorMessage when LLM unreachable');
        Assert.isTrue(result.errorMessage.contains('Completeness'));
    }

    @IsTest
    static void testEvaluateCompleteness_BlankSummaryHandled() {
        // Covers the `String.isNotBlank(summary) ? summary : ''` branch
        // before the catch fires.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Test.startTest();
        PromptTemplateService.LLMEvaluationResult result =
            svc.evaluateCompleteness('Title', 'Body', null);
        Test.stopTest();

        Assert.isNotNull(result.errorMessage,
            'Null summary still routed through the wrapper safely');
    }

    @IsTest
    static void testEvaluateDraft_RealServiceThrowsOnEinsteinUnavailable() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Boolean threw = false;
        Test.startTest();
        try {
            svc.evaluateDraft('Draft text', new List<VectorSearchResult>());
        } catch (KnowledgeAIException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Draft_Evaluator')
                || e.getMessage().contains('Prompt template'),
                'Error wraps the failing template name');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'evaluateDraft rethrows when LLM is unreachable');
    }

    @IsTest
    static void testEvaluatePublishedPair_WrapsErrorWithArticleIds() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Boolean threw = false;
        Test.startTest();
        try {
            svc.evaluatePublishedPair('A text', 'B text', 'idA', 'idB');
        } catch (KnowledgeAIException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('idA')
                && e.getMessage().contains('idB'),
                'Error message references both article IDs for triage');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'evaluatePublishedPair wraps the LLM error');
    }

    @IsTest
    static void testTriageDuplicateCandidates_RealServiceThrows() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        List<PromptTemplateService.CandidateSummary> candidates =
            new List<PromptTemplateService.CandidateSummary>{
                new PromptTemplateService.CandidateSummary('ka01', 'Title 1', 'Summary 1'),
                new PromptTemplateService.CandidateSummary('ka02', 'Title 2', 'Summary 2')
            };

        Boolean threw = false;
        Test.startTest();
        try {
            svc.triageDuplicateCandidates('Target Title', 'Target Summary', candidates);
        } catch (KnowledgeAIException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Triage wrapper builds candidate list, then throws');
    }

    @IsTest
    static void testExtractArticleFacts_RealServiceThrows() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Boolean threw = false;
        Test.startTest();
        try {
            svc.extractArticleFacts('A chunk of article text to extract facts from.');
        } catch (KnowledgeAIException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'extractArticleFacts wrapper invoked, then throws');
    }

    @IsTest
    static void testEvaluateExtractedFacts_RealServiceThrows() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Boolean threw = false;
        Test.startTest();
        try {
            svc.evaluateExtractedFacts('facts A', 'facts B');
        } catch (KnowledgeAIException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'evaluateExtractedFacts wrapper invoked, then throws');
    }

    @IsTest
    static void testDraftMergedArticle_RealServiceThrows() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Boolean threw = false;
        Test.startTest();
        try {
            svc.draftMergedArticle('article 1 body', 'article 2 body', 'en_US');
        } catch (KnowledgeAIException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'draftMergedArticle wrapper invoked, then throws');
    }

    @IsTest
    static void testDraftMergedCluster_EmptyShortCircuits() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // Both null and empty must short-circuit before any LLM call.
        Assert.areEqual('', svc.draftMergedCluster(null, 'en_US'),
            'Null list returns empty string');
        Assert.areEqual('', svc.draftMergedCluster(new List<String>(), 'en_US'),
            'Empty list returns empty string');
    }

    @IsTest
    static void testDraftMergedCluster_SingleArticleReturnedAsIs() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        String only = 'only article body';
        Assert.areEqual(only, svc.draftMergedCluster(new List<String>{ only }, 'en_US'),
            'Single article returns as-is — no LLM call');
    }

    @IsTest
    static void testFixArticleIssues_RealServiceThrows() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Boolean threw = false;
        Test.startTest();
        try {
            svc.fixArticleIssues(
                new Map<String, String>{ 'Summary' => 'old summary' },
                new Map<String, Integer>{ 'Summary' => 1000 },
                'issue 1\nissue 2',
                'strength 1',
                'en_US'
            );
        } catch (KnowledgeAIException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'fixArticleIssues wrapper invoked, then throws');
    }

    @IsTest
    static void testFixArticleIssues_BlankStrengthsListTakesElseBranch() {
        // Covers the `String.isBlank(strengthsList) ? '(none identified)' : strengthsList`
        // branch on line 682.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Boolean threw = false;
        Test.startTest();
        try {
            svc.fixArticleIssues(
                new Map<String, String>{ 'Summary' => 'old' },
                new Map<String, Integer>{ 'Summary' => 1000 },
                'issue text',
                null,
                'en_US'
            );
        } catch (KnowledgeAIException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Blank strengths route through default fallback string');
    }

    @IsTest
    static void testAnnotateIssueSeverity_EmptyIssuesShortCircuits() {
        // Lines 756-758: null/empty issues return [] without invoking the template.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Assert.areEqual(0,
            svc.annotateIssueSeverity('t', 's', 'c', null, null, null, null, null).size(),
            'Null issues short-circuit to empty list');
        Assert.areEqual(0,
            svc.annotateIssueSeverity('t', 's', 'c', null, null, null,
                new List<String>(), null).size(),
            'Empty issues short-circuit to empty list');
    }

    @IsTest
    static void testAnnotateIssueSeverity_SwallowsLLMFailure() {
        // Wrapper catches and returns empty rather than rethrowing —
        // exercises the System.debug + return path.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Test.startTest();
        List<PromptTemplateService.IssueSeverityAnnotation> result =
            svc.annotateIssueSeverity(
                'Title', 'Summary', 'Content',
                'CT', 'CS', 'CC',
                new List<String>{ 'issue text' },
                new List<String>{ 'strength text' }
            );
        Test.stopTest();

        Assert.isNotNull(result, 'Returns empty list, never null, on LLM failure');
        Assert.areEqual(0, result.size(),
            'LLM unreachable → empty annotations, non-fatal for caller');
    }

    @IsTest
    static void testGetInstance_LazyProvisioningWhenMockCleared() {
        // Covers lines 28-29 where the singleton is null and lazily created.
        PromptTemplateService.setMock(null);
        PromptTemplateService instance = PromptTemplateService.getInstance();
        Assert.isNotNull(instance, 'getInstance lazily provisions when no mock set');
    }

    // ──────────────────────────────────────────────────────────────────────
    // parseLLMEvaluationResult — completeness fieldResults branch
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testParseLLMResult_CompletenessFieldResults() {
        // Covers lines 343-360: the completeness `fieldResults` iteration —
        // currently uncovered because no other test feeds the per-field shape.
        PromptTemplateService svc = new PromptTemplateService();
        String json = '{'
            + '"score":75,'
            + '"reasoning":"per-field analysis",'
            + '"fieldResults":['
            +   '{"field":"Summary","issues":[{"text":"too short"}],"strengths":["clear"]},'
            +   '{"field":"Body","issues":["plain string issue"],"strengths":[]}'
            + '],'
            + '"summaryIssues":["legacy summary issue"],'
            + '"summaryStrengths":["legacy summary strength"]'
            + '}';

        PromptTemplateService.LLMEvaluationResult result =
            svc.parseLLMEvaluationResult(json, 'completeness');

        Assert.isTrue(result.success, 'Parsed successfully');
        Assert.areEqual(75, result.score, 'Score parsed');
        Assert.isTrue(result.issues.size() >= 3,
            'Per-field issues + legacy summary issue all collected');
        Boolean hasSummaryIssue = false;
        Boolean hasBodyIssue = false;
        for (String i : result.issues) {
            if (i.startsWith('Summary: too short')) hasSummaryIssue = true;
            if (i.startsWith('Body: plain string issue')) hasBodyIssue = true;
        }
        Assert.isTrue(hasSummaryIssue, 'Map-shaped issue prefixed with field name');
        Assert.isTrue(hasBodyIssue, 'String-shaped issue prefixed with field name');
        Boolean hasFieldStrength = false;
        for (String s : result.strengths) {
            if (s.startsWith('Summary: clear')) hasFieldStrength = true;
        }
        Assert.isTrue(hasFieldStrength,
            'Per-field strengths prefixed with field name');
    }

    // ──────────────────────────────────────────────────────────────────────
    // T10: parseFixArticleResult — sanitization + JSON parse paths
    // The full fixArticleIssues flow needs a real Einstein callout, so we
    // exercise the @TestVisible parser directly.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testFixArticleParser_MalformedJSON_Throws() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Boolean threw = false;
        String thrownMsg = null;
        try {
            svc.parseFixArticleResult('{ this is not valid json');
        } catch (KnowledgeAIException e) {
            threw = true;
            thrownMsg = e.getMessage();
        }

        Assert.isTrue(threw, 'Malformed JSON must raise KnowledgeAIException');
 // the one-arg overload uses the template-agnostic 'AI' label
        // (it no longer hardcodes the Fix_Article_Issues template name).
        Assert.isTrue(
            thrownMsg != null && thrownMsg.contains('Failed to parse AI response'),
            'Exception message identifies the failing parse step — got: ' + thrownMsg
        );
    }

    /**
 * (a): the parse-failure message names the ACTUAL template that
     * produced the response, so a merge failure no longer mislabels itself as
     * the Fix template. Pass each template name through the two-arg parser.
     */
    @IsTest
    static void testFixArticleParser_NamesTemplateInError() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        String mergeMsg = null;
        try {
            svc.parseFixArticleResult('{ not valid', 'Consolidate_Knowledge_Articles');
        } catch (KnowledgeAIException e) {
            mergeMsg = e.getMessage();
        }
        Assert.isTrue(
            mergeMsg != null && mergeMsg.contains('Consolidate_Knowledge_Articles'),
            'A merge parse failure names the merge template — got: ' + mergeMsg
        );
        Assert.isFalse(
            mergeMsg != null && mergeMsg.contains('Fix_Article_Issues'),
            'A merge parse failure must NOT mislabel itself as the Fix template — got: ' + mergeMsg
        );

        String fixMsg = null;
        try {
            svc.parseFixArticleResult('{ not valid', 'Fix_Article_Issues_V2');
        } catch (KnowledgeAIException e) {
            fixMsg = e.getMessage();
        }
        Assert.isTrue(
            fixMsg != null && fixMsg.contains('Fix_Article_Issues_V2'),
            'A Fix parse failure names the Fix template — got: ' + fixMsg
        );
    }

    /**
 * (b): a truncated / incomplete LLM response (the model hit an
     * output-token cap mid-object) degrades to an actionable message instead
     * of the raw Jackson "Unexpected end-of-input" dump.
     */
    @IsTest
    static void testFixArticleParser_TruncatedResponse_ActionableMessage() {
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // A JSON object cut off after a complete string value but before its
        // close markers → Jackson raises "Unexpected end-of-input: expected
        // close marker for OBJECT" (the exact signature from the issue).
        String truncated = '{"fields":{"Summary":"a complete value"';

        String msg = null;
        try {
            svc.parseFixArticleResult(truncated, 'Consolidate_Knowledge_Articles');
        } catch (KnowledgeAIException e) {
            msg = e.getMessage();
        }

        Assert.isTrue(msg != null, 'Truncated response must raise KnowledgeAIException');
        Assert.isTrue(
            msg.containsIgnoreCase('incomplete'),
            'Truncated response degrades to an actionable "incomplete" message — got: ' + msg
        );
        Assert.isFalse(
            msg.containsIgnoreCase('end-of-input'),
            'The raw Jackson parser dump must not reach the user — got: ' + msg
        );
        Assert.isTrue(
            msg.contains('Consolidate_Knowledge_Articles'),
            'The incomplete-response message still names the template — got: ' + msg
        );
    }

    @IsTest
    static void testFixArticleParser_SanitizesPilcrowAndCRLF() {
        // Cover the sanitization branches:
        //  * \r\n / \r / \n inside a JSON string value get escaped to \\n
        //    so JSON.deserializeUntyped accepts the payload.
        //  * pilcrow (¶) inside the parsed string value gets converted to \n.
        //  * Double-spaces collapse to single space and the value is trimmed.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // Build a response where the Summary value contains:
        //  - a literal CRLF (\r\n) → must be escaped before parse
        //  - a pilcrow (¶) → must be converted to \n in the parsed value
        //  - a leading double space + trailing space → must be trimmed
        String llmResponse =
            '{"fields":{"Summary":"  line one\r\nline two ¶ paragraph two "},'
            + '"changes_summary":"Tightened structure."}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(llmResponse);

        Assert.isNotNull(result.rewrittenFields, 'Result has rewrittenFields map');
        Assert.isTrue(result.rewrittenFields.containsKey('Summary'),
            'Parser pulled Summary out of fields');
        String parsed = result.rewrittenFields.get('Summary');
        // After sanitization \r\n becomes \\n, the parser turns \\n back into a real newline,
        // and the pilcrow gets converted to a real newline as well. Result: two newlines
        // in the output value; double spaces collapsed; trimmed.
        Assert.isTrue(parsed.startsWith('line one'),
            'Leading double-space trimmed — got: ' + parsed);
        Assert.isFalse(parsed.contains('¶'),
            'Pilcrow stripped — got: ' + parsed);
        Assert.isTrue(parsed.contains('\n'),
            'Newlines preserved as real \\n in the output — got: ' + parsed);
        Assert.areEqual('Tightened structure.', result.changesSummary,
            'changes_summary copied through');
    }

    @IsTest
    static void testFixArticleParser_HtmlValuePreservesTagsLinksAndSpacing() {
 // /: rich-text Knowledge fields round-trip HTML. The parser's
        // plain-text normalization (double-space collapse + pilcrow→\n) must
        // NOT touch HTML — collapsing whitespace corrupts markup, and tags/
        // links (<ol><li>, <a href>) must survive verbatim.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // The HTML value deliberately contains a double-space inside a <li>
        // (would be collapsed by the plain-text path) and an <a href> link
        // (would be dropped/mangled if the prompt/parser flattened it).
        String htmlValue =
            '<p>To reset the device:</p><ol>'
            + '<li>Hold  Power for 10 seconds.</li>'
            + '<li>See the <a href=\\"https://help.example.com/reset\\">reset guide</a>.</li>'
            + '</ol>';
        String llmResponse =
            '{"fields":{"FAQ_Answer__c":"' + htmlValue + '"},'
            + '"changes_summary":"Kept the list and reference link."}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(llmResponse);

        String parsed = result.rewrittenFields.get('FAQ_Answer__c');
        Assert.isTrue(parsed.contains('<ol>') && parsed.contains('<li>'),
            'List tags survived — got: ' + parsed);
        Assert.isTrue(parsed.contains('<a href="https://help.example.com/reset">'),
            'Anchor href preserved verbatim — got: ' + parsed);
        Assert.isTrue(parsed.contains('reset guide</a>'),
            'Anchor text + closing tag preserved — got: ' + parsed);
        Assert.isTrue(parsed.contains('Hold  Power'),
            'Significant double-space inside HTML NOT collapsed — got: ' + parsed);
        Assert.isTrue(PromptTemplateService.looksLikeHtml(parsed),
            'Value classified as HTML');
    }

    @IsTest
    static void testFixArticleParser_PlainTextStillNormalized() {
        // Guard: the HTML-aware branch must not regress the plain-text path —
        // a non-HTML value still gets pilcrow→\n and double-space collapse + trim.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        String llmResponse =
            '{"fields":{"Title":"  Reset  the device ¶ quickly "},'
            + '"changes_summary":"Tightened."}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(llmResponse);

        String parsed = result.rewrittenFields.get('Title');
        Assert.isFalse(PromptTemplateService.looksLikeHtml(parsed),
            'Plain-text value not classified as HTML — got: ' + parsed);
        Assert.isFalse(parsed.contains('¶'), 'Pilcrow converted — got: ' + parsed);
        Assert.isTrue(parsed.contains('\n'), 'Pilcrow became newline — got: ' + parsed);
        Assert.isFalse(parsed.contains('  '),
            'Double-spaces collapsed on plain text — got: ' + parsed);
        Assert.isTrue(parsed.startsWith('Reset'), 'Leading whitespace trimmed — got: ' + parsed);
    }

    @IsTest
    static void testFixArticleParser_NoFieldsKey_ReturnsEmptyRewrittenFields() {
        // Defensive: when the LLM returns a parseable JSON but without the
        // `fields` map, the parser must return a result with empty
        // rewrittenFields (so the caller can throw a clearer "no rewritten
        // fields" error instead of an obscure NPE).
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult('{"changes_summary":"nothing changed"}');

        Assert.isNotNull(result.rewrittenFields, 'rewrittenFields map allocated even on miss');
        Assert.areEqual(0, result.rewrittenFields.size(),
            'No fields key → empty rewrittenFields');
        Assert.areEqual('nothing changed', result.changesSummary,
            'changes_summary preserved on no-fields path');
    }

    @IsTest
    static void testFixArticleParser_CodeFencedResponse() {
 // the model sometimes wraps the object in a markdown code fence
        // (```json … ```). The fence must be stripped before parse so the
        // rewritten fields + changes_summary come through unchanged.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        String fenced =
            '```json\n'
            + '{"fields":{"FAQ_Answer__c":"x"},"changes_summary":"y"}\n'
            + '```';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(fenced);

        Assert.isTrue(result.rewrittenFields.containsKey('FAQ_Answer__c'),
            'Code fence stripped — field parsed out');
        Assert.areEqual('x', result.rewrittenFields.get('FAQ_Answer__c'),
            'Field value parsed from a code-fenced response');
        Assert.areEqual('y', result.changesSummary,
            'changes_summary parsed from a code-fenced response');
    }

    @IsTest
    static void testFixArticleParser_FenceCaseAndSpacingVariants() {
 // the fence language tag varies across model outputs — uppercase
        // (```JSON), spaced (``` json), and a bare fence with no tag (```).
        // All must strip to the same object so the fix isn't defeated by
        // formatting drift.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Map<String, String> variants = new Map<String, String>{
            'uppercase' => '```JSON\n{"fields":{"FAQ_Answer__c":"x"},"changes_summary":"y"}\n```',
            'spaced'    => '``` json\n{"fields":{"FAQ_Answer__c":"x"},"changes_summary":"y"}\n```',
            'bare'      => '```\n{"fields":{"FAQ_Answer__c":"x"},"changes_summary":"y"}\n```'
        };

        for (String label : variants.keySet()) {
            PromptTemplateService.FixArticleResult result =
                svc.parseFixArticleResult(variants.get(label));
            Assert.areEqual('x', result.rewrittenFields.get('FAQ_Answer__c'),
                'Field value parsed from a ' + label + ' code-fenced response');
            Assert.areEqual('y', result.changesSummary,
                'changes_summary parsed from a ' + label + ' code-fenced response');
        }
    }

    @IsTest
    static void testStripCodeFences_Variants() {
        // Shared fence stripper used by all prompt-response parsers. Covers the
        // language-tag variants and the internal-backtick case that the old
        // substringBeforeLast approach truncated.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // No fence → trimmed, unchanged.
        Assert.areEqual('{"a":1}', svc.stripCodeFences('  {"a":1}  '),
            'Unfenced payload returned trimmed');

        // Lowercase / uppercase / spaced language tag + bare fence all strip clean.
        Assert.areEqual('{"a":1}', svc.stripCodeFences('```json\n{"a":1}\n```'),
            'lowercase json fence stripped');
        Assert.areEqual('{"a":1}', svc.stripCodeFences('```JSON\n{"a":1}\n```'),
            'uppercase JSON fence stripped');
        Assert.areEqual('{"a":1}', svc.stripCodeFences('``` json\n{"a":1}\n```'),
            'spaced json fence stripped');
        Assert.areEqual('{"a":1}', svc.stripCodeFences('```\n{"a":1}\n```'),
            'bare fence stripped');

        // Internal triple-backticks in the payload must survive — the body of a
        // rewritten KB article can itself contain a code block. The old
        // substringBeforeLast('```') cut here; the line-based strip does not.
        String withInnerFence = '```json\n{"body":"see ```code``` here"}\n```';
        Assert.areEqual('{"body":"see ```code``` here"}',
            svc.stripCodeFences(withInnerFence),
            'internal backticks preserved (no substringBeforeLast truncation)');
    }

    @IsTest
    static void testFixArticleParser_EscapedMultilineBody() {
 // (review #1): a naked-escape payload whose body has a real
        // newline must still parse — the unwrap escapes bare control chars
        // before wrapping in quotes.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        String nakedMultiline =
            '{\\"fields\\":{\\"FAQ_Answer__c\\":\\"line1\nline2\\"},\\"changes_summary\\":\\"y\\"}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(nakedMultiline);
        Assert.areEqual('line1\nline2', result.rewrittenFields.get('FAQ_Answer__c'),
            'multi-line body parsed from a naked-escape response');
        Assert.areEqual('y', result.changesSummary,
            'changes_summary parsed from a naked-escape multi-line response');
    }

    @IsTest
    static void testFixArticleParser_PrettyPrintedJSON() {
 // ROOT CAUSE: the model often returns pretty-printed JSON
        // (structural newlines between tokens). The old whole-string control-char
        // escape turned those into literal \n, producing `{\n  "fields"...` →
        // "Unexpected character ('\' (code 92))". The context-aware escaper must
        // leave structural whitespace alone so pretty-printed JSON parses.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        String pretty =
            '{\n'
            + '  "fields": {\n'
            + '    "FAQ_Answer__c": "hello world"\n'
            + '  },\n'
            + '  "changes_summary": "tidied"\n'
            + '}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(pretty);
        Assert.areEqual('hello world', result.rewrittenFields.get('FAQ_Answer__c'),
            'pretty-printed JSON parses (structural newlines not corrupted)');
        Assert.areEqual('tidied', result.changesSummary,
            'changes_summary parsed from pretty-printed JSON');
    }

    @IsTest
    static void testFixArticleParser_PrettyPrintedWithInlineNewline() {
        // The hardest real case: pretty-printed JSON AND a real newline inside a
        // string value. Structural newlines must stay raw; the in-string newline
        // must be escaped. Only a context-aware escaper handles both at once.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        String prettyInline =
            '{\n'
            + '  "fields": {\n'
            + '    "FAQ_Answer__c": "line1\nline2"\n'
            + '  },\n'
            + '  "changes_summary": "ok"\n'
            + '}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(prettyInline);
        Assert.areEqual('line1\nline2', result.rewrittenFields.get('FAQ_Answer__c'),
            'in-string newline preserved while structural newlines stay raw');
        Assert.areEqual('ok', result.changesSummary,
            'changes_summary parsed from pretty+inline-newline JSON');
    }

    @IsTest
    static void testFixArticleParser_BackslashInValue() {
        // A Windows path with escaped backslashes inside a value must survive the
        // context-aware escaper untouched (the escape state must not double-process
        // the chars after a backslash).
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // JSON source contains \\ (an escaped backslash) → value is a single backslash path.
        String withPath = '{"fields":{"FAQ_Answer__c":"open C:\\\\app\\\\x.ini"},"changes_summary":"ok"}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(withPath);
        Assert.areEqual('open C:\\app\\x.ini', result.rewrittenFields.get('FAQ_Answer__c'),
            'escaped backslashes in a value decode to single backslashes');
    }

    @IsTest
    static void testFixArticleParser_NakedEscapeWithBackslashInValue() {
 // the INTERSECTION the earlier tests miss — a naked-escape payload
        // (only its quotes escaped, no outer quotes) whose value contains a
        // backslash (a Windows path). testFixArticleParser_BackslashInValue uses
        // the raw-object shape that parses on the first attempt and never reaches
        // the unwrap path; this shape fails the raw parse, takes the unwrap path,
        // and used to throw "Unrecognized character escape 'a'" because the
        // full-string decode collapsed the value's `\\` to `\`.
        //
        // Build the payload programmatically so the backslash count is exact:
        // start from the well-formed object, then escape ONLY the quotes (the
        // shape a model emits when it returns the object as escaped text).
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        Map<String, Object> obj = new Map<String, Object>{
            'fields' => new Map<String, Object>{ 'FAQ_Answer__c' => 'open C:' + '\\' + 'app' },
            'changes_summary' => 'ok'
        };
        // rawJson: {"fields":{"FAQ_Answer__c":"open C:\\app"},...}  (value = one backslash)
        String rawJson = JSON.serialize(obj);
        // naked-escape: escape only the quotes; the value's `\\` stays as-is.
        String naked = rawJson.replace('"', '\\"');

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(naked);
        Assert.areEqual('open C:\\app', result.rewrittenFields.get('FAQ_Answer__c'),
            'naked-escape payload with an in-value backslash recovers to the single-backslash path');
        Assert.areEqual('ok', result.changesSummary,
            'changes_summary parses from a naked-escape + in-value-backslash response');
    }

    @IsTest
    static void testFixArticleParser_CrlfInsideValue() {
        // Exercises the escaper's CRLF-collapse (skipLF) branch: a bare CR+LF
        // inside a string value fails the raw parse, so the escaper runs and must
        // collapse the pair to a single \n (not emit \n\n).
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // Real CR + LF (\r\n) sit inside the value → raw parse fails → escaper runs.
        String crlf = '{"fields":{"FAQ_Answer__c":"line1\r\nline2"},"changes_summary":"ok"}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(crlf);
        Assert.areEqual('line1\nline2', result.rewrittenFields.get('FAQ_Answer__c'),
            'CRLF inside a value collapses to a single newline');
    }

    @IsTest
    static void testFixArticleParser_BackslashThenBareNewline() {
 // Regression: a backslash immediately before a bare
        // control char inside a value must NOT leave the control char unescaped.
        // The escaper must escape a raw < 0x20 char regardless of a preceding
        // backslash, so the retry parse succeeds instead of throwing.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // value bytes: C : \ <LF> t e m p  (lone backslash, then a real newline)
        String tricky = '{"fields":{"FAQ_Answer__c":"C:\\\ntemp"},"changes_summary":"ok"}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(tricky);
        // Recovers to valid JSON (no throw); the backslash is preserved and the
        // bare newline is escaped rather than dropped.
        Assert.isTrue(result.rewrittenFields.containsKey('FAQ_Answer__c'),
            'backslash-then-bare-newline recovers instead of throwing');
        Assert.areEqual('ok', result.changesSummary,
            'changes_summary still parses after a backslash+bare-newline value');
    }

    @IsTest
    static void testFixArticleParser_OtherControlCharInValue() {
        // The escaper handles ALL bare control chars < 0x20 (not just CR/LF/tab):
        // a form-feed (0x0C) inside a value must be escaped to \u000c so the value
        // parses instead of throwing.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        String formFeed = '{"fields":{"FAQ_Answer__c":"a' + String.fromCharArray(new List<Integer>{ 12 })
            + 'b"},"changes_summary":"ok"}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(formFeed);
        Assert.isTrue(result.rewrittenFields.containsKey('FAQ_Answer__c'),
            'a bare form-feed inside a value is escaped and the value parses');
        Assert.areEqual('ok', result.changesSummary,
            'changes_summary parses after a form-feed value');
    }

    @IsTest
    static void testFixArticleParser_EscapedQuoteAndBareNewlineInValue() {
        // Exercises the escaper's escaped-flag path AND proves inString does not
        // get stuck on an escaped quote. The value has escaped quotes (\") AND a
        // bare newline — the bare newline fails the raw parse so the escaper runs;
        // it must treat \" as in-value (not a string close), escape the bare
        // newline, and still close the string at the real terminating quote.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // Apex literal: \\" → backslash+quote in the JSON; \n → a real newline.
        String tricky = '{"fields":{"FAQ_Answer__c":"say \\"hi\\"\nbye"},"changes_summary":"ok"}';

        PromptTemplateService.FixArticleResult result =
            svc.parseFixArticleResult(tricky);
        Assert.areEqual('say "hi"\nbye', result.rewrittenFields.get('FAQ_Answer__c'),
            'escaped quotes stay in-value (string not closed early) and the bare newline is escaped');
        Assert.areEqual('ok', result.changesSummary,
            'changes_summary still parses after an escaped-quote + bare-newline value');
    }

    @IsTest
    static void testFixArticleParser_EscapedStringifiedJSON() {
 // the model sometimes returns a JSON *string* whose content is
        // the object (escaped/stringified JSON) rather than a raw object. The
        // parser must unwrap it once and re-parse the inner JSON.
        PromptTemplateService.setMock(null);
        PromptTemplateService svc = PromptTemplateService.getInstance();

        // Fully-quoted form: the whole payload is a JSON string. Built via
        // JSON.serialize so the escaping is faithful to a real LLM response.
        String fullyQuoted = JSON.serialize(
            '{"fields":{"FAQ_Answer__c":"x"},"changes_summary":"y"}'
        );
        Assert.isTrue(fullyQuoted.startsWith('"'),
            'Sanity: fully-quoted stringified JSON starts with a quote');

        PromptTemplateService.FixArticleResult quotedResult =
            svc.parseFixArticleResult(fullyQuoted);
        Assert.areEqual('x', quotedResult.rewrittenFields.get('FAQ_Answer__c'),
            'Field value parsed from a fully-quoted stringified JSON response');
        Assert.areEqual('y', quotedResult.changesSummary,
            'changes_summary parsed from a fully-quoted stringified JSON response');

        // Naked-escape form: no outer quotes, just escaped inner quotes — this
 // is the exact "Unexpected character ('\' (code 92))" shape from.
        String nakedEscapes =
            '{\\"fields\\":{\\"FAQ_Answer__c\\":\\"x\\"},\\"changes_summary\\":\\"y\\"}';
        Assert.isTrue(nakedEscapes.startsWith('{\\"'),
            'Sanity: naked-escape JSON starts with {\\" (the column-3 backslash)');

        PromptTemplateService.FixArticleResult nakedResult =
            svc.parseFixArticleResult(nakedEscapes);
        Assert.areEqual('x', nakedResult.rewrittenFields.get('FAQ_Answer__c'),
            'Field value parsed from a naked-escape stringified JSON response');
        Assert.areEqual('y', nakedResult.changesSummary,
            'changes_summary parsed from a naked-escape stringified JSON response');
    }

    @IsTest
    static void testExtractIssueItems_MapShapeWithSeverity() {
        // Covers lines 389-398: Map<String,Object> branch with full severity fields.
        PromptTemplateService svc = new PromptTemplateService();
        PromptTemplateService.LLMEvaluationResult result =
            new PromptTemplateService.LLMEvaluationResult();

        List<Object> items = (List<Object>) JSON.deserializeUntyped(
            '[{"text":"missing intro","impact":"high","effort":"low","priority":"P1"},'
            + '{"text":"vague","impact":null,"effort":null,"priority":null},'
            + '{"text":""},'
            + '"plain string issue"]'
        );

        svc.extractIssueItems(items, result, 'TestPrefix: ');

        // 3 valid issues: 2 maps with text + 1 plain string. Empty-text map dropped.
        Assert.areEqual(3, result.issues.size(),
            'Empty text dropped; valid map + null-severity map + plain string kept');
        Assert.areEqual(3, result.issueAnalyses.size(),
            'IssueAnalysis lockstep with issues list');
        Assert.areEqual('TestPrefix: missing intro', result.issues[0]);
        Assert.areEqual('high', result.issueAnalyses[0].impact);
        Assert.areEqual('low', result.issueAnalyses[0].effort);
        Assert.areEqual('P1', result.issueAnalyses[0].priority);
        // Null severity fields stay null
        Assert.isNull(result.issueAnalyses[1].impact,
            'Null severity fields preserved as null, not stringified "null"');
        // Plain string issue gets null severities
        Assert.areEqual('TestPrefix: plain string issue', result.issues[2]);
        Assert.isNull(result.issueAnalyses[2].impact);
    }
}
