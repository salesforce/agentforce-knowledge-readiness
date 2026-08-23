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
 * Unit tests for KBDimensionAnalysisService — the in-memory builder for
 * KB_Dimension_Analysis__c rows. Pure construction; no DML required.
 */
@IsTest
private class KBDimensionAnalysisServiceTest {

    private static KBAssessmentModels.DimensionScore makeScore(
        Decimal value, List<String> issues, List<String> strengths
    ) {
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = value;
        s.issues = issues == null ? new List<String>() : issues;
        s.strengths = strengths == null ? new List<String>() : strengths;
        return s;
    }

    private static Id fakeId(SObjectType t) {
        return t.getDescribe().getKeyPrefix() + '0'.repeat(15);
    }

    @IsTest
    static void buildForDimension_NullScore_ReturnsEmpty() {
        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            null, null, 'Completeness', null
        );
        Assert.areEqual(0, rows.size(), 'Null score → no rows');
    }

    @IsTest
    static void buildForDimension_IssuesAndStrengths_BothEmitted() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        Id assessmentId = fakeId(KB_Article_Assessment__c.SObjectType);
        KBAssessmentModels.DimensionScore s = makeScore(
            45,
            new List<String>{ 'Body too short', 'Missing summary' },
            new List<String>{ 'Clear title' }
        );

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, assessmentId, 'Completeness', s
        );

        Assert.areEqual(3, rows.size(), 'Two issues + one strength = 3 rows');
        Integer issueRows = 0, strengthRows = 0;
        for (KB_Dimension_Analysis__c r : rows) {
            Assert.areEqual(resultId, r.Dimension_Result__c, 'Master-detail set');
            Assert.areEqual(assessmentId, r.Article_Assessment__c, 'Denormalized lookup set');
            Assert.areEqual('Completeness', r.Dimension__c, 'Dimension copied');
            Assert.areEqual('Open', r.Status__c, 'Defaults to Open');
            if (r.Type__c == KBDimensionAnalysisService.TYPE_ISSUE) {
                issueRows++;
                Assert.isNotNull(r.Recommendation__c, 'Issues carry a recommendation');
            }
            if (r.Type__c == KBDimensionAnalysisService.TYPE_STRENGTH) {
                strengthRows++;
                Assert.isNull(r.Recommendation__c, 'Strengths have no recommendation');
                Assert.isNull(r.Impact__c, 'Strengths have no impact');
            }
        }
        Assert.areEqual(2, issueRows, 'Two issues');
        Assert.areEqual(1, strengthRows, 'One strength');
    }

    @IsTest
    static void buildForDimension_DuplicateIssues_Deduped() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = makeScore(
            50,
            new List<String>{ 'Missing summary', 'Missing summary' },
            null
        );

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Completeness', s
        );

        Assert.areEqual(1, rows.size(), 'Duplicate issue text deduped');
    }

    @IsTest
    static void buildForDimension_BlankEntries_Skipped() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = makeScore(
            60,
            new List<String>{ '', '   ', null },
            new List<String>{ '' }
        );

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Clarity', s
        );

        Assert.areEqual(0, rows.size(), 'Blank entries are skipped');
    }

    @IsTest
    static void buildForDimension_Freshness_NoSeverityAcrossScoreBands() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);

        // Severity is Impact-only and Freshness never takes LLM impact (issue
 // Effort/Priority retired off the object). A Freshness issue row
        // carries no Impact regardless of score band.
        List<KB_Dimension_Analysis__c> high = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Freshness',
            makeScore(30, new List<String>{ '24 months stale' }, null)
        );
        Assert.areEqual(1, high.size(), 'Freshness issue row emitted');
        Assert.isNull(high[0].Impact__c, 'Freshness carries no Impact');

        List<KB_Dimension_Analysis__c> low = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Freshness',
            makeScore(85, new List<String>{ '6 months stale' }, null)
        );
        Assert.areEqual(1, low.size(), 'Freshness issue row emitted');
        Assert.isNull(low[0].Impact__c, 'Freshness carries no Impact');
    }

    @IsTest
    static void buildForDimension_LlmImpact_Stamped_EffortPriorityDropped() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = 55;
        // addIssue keeps issues + issueAnalyses in lockstep. Even if a stale
        // IssueAnalysis still carries effort/priority, the builder must only
 // stamp Impact__c now (Impact-only).
        s.addIssue('Body too short', 'High',   'Quick Win', 'High');
        s.addIssue('Missing summary', 'Medium', 'Low',       'Medium');

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Completeness', s
        );

        Assert.areEqual(2, rows.size());
        Map<String, KB_Dimension_Analysis__c> byText = new Map<String, KB_Dimension_Analysis__c>();
        for (KB_Dimension_Analysis__c r : rows) byText.put(r.Analysis_Text__c, r);
        Assert.areEqual('High', byText.get('Body too short').Impact__c, 'LLM impact stamped');
        Assert.areEqual('Medium', byText.get('Missing summary').Impact__c);
    }

    @IsTest
    static void buildForDimension_FreshnessIgnoresLlmImpact_WritesNoSeverity() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = 35;
        // Freshness never takes LLM severity (calendar age is a fact). With
 // Effort + Priority dropped, a Freshness issue row now
        // carries no severity at all — Impact is null.
        s.addIssue('2 year stale critical', 'Low', 'Quick Win', 'Low');

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Freshness', s
        );

        Assert.areEqual(1, rows.size());
        Assert.isNull(rows[0].Impact__c, 'Freshness ignores LLM impact');
    }

    @IsTest
    static void buildForDimension_NonFreshness_ImpactOnly_NoEffortOrPriority() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = 50;
        // The LLM now emits impact only; effort/priority are no longer
 // requested or written. Impact is preserved on the row.
        s.addIssue('Missing summary', 'High', null, null);

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Completeness', s
        );

        Assert.areEqual(1, rows.size());
        Assert.areEqual('High', rows[0].Impact__c, 'LLM impact preserved');    }

    @IsTest
    static void buildForDimension_NonFreshnessRecommendation_CopiesIssueVerbatim() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        // Issue text crafted to NOT match any KBRecommendationService keyword
        // patterns. If the service still routed through the static mapper we'd
        // see the generic "Review article completeness..." fallback instead.
        String llmIssue = 'Step 3 references a deprecated CLI flag --legacy-tls; replace with --tls-version=1.3 to match current platform requirements.';
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = 55;
        s.addIssue(llmIssue, 'High', 'Quick Win', 'High');

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Completeness', s
        );

        Assert.areEqual(1, rows.size());
        Assert.areEqual(llmIssue, rows[0].Recommendation__c,
            'Non-Freshness recommendations should be the LLM-emitted issue verbatim');
    }

    @IsTest
    static void buildForDimension_FreshnessRecommendation_StillUsesStaticMapper() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = makeScore(
            35, new List<String>{ 'Article is critically old (24 months)' }, null
        );

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Freshness', s
        );

        Assert.areEqual(1, rows.size());
        Assert.areNotEqual('Article is critically old (24 months)', rows[0].Recommendation__c,
            'Freshness should still expand into the canned review-and-update advice');
        Assert.isTrue(rows[0].Recommendation__c.contains('outdated'),
            'Freshness recommendation comes from the static mapper');
    }

    @IsTest
    static void buildForDimension_TruncatesLongAnalysisText() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        String huge = 'x'.repeat(40000);
        KBAssessmentModels.DimensionScore s = makeScore(
            50, new List<String>{ huge }, null
        );

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Completeness', s
        );

        Assert.areEqual(1, rows.size());
        Assert.areEqual(32000, rows[0].Analysis_Text__c.length(),
            'Analysis text clamped to LongTextArea max');
    }

    // ─────────────────────────────────────────────────────────────────────
    // Impact picklist value coercion
    //
    // Impact__c is a restricted picklist. Any LLM drift outside the whitelist
    // would fail the all-or-nothing insert with
    // INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST and (because the queueable's
    // catch swallowed the DML exception) leave the dimension with zero
    // analysis rows. coercePicklist normalises the LLM value to a valid
    // picklist entry, or null if it cannot. Effort + Priority are no longer
 // written, so they stay null regardless of input.
    // ─────────────────────────────────────────────────────────────────────

    @IsTest
    static void buildForDimension_LlmImpact_CoercesCaseDrift() {
        // The LLM occasionally emits lowercase ("high"). Coerce to "High".
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = 50;
        s.addIssue('Missing summary', 'high', 'quick win', 'medium');

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Completeness', s
        );

        Assert.areEqual(1, rows.size());
        Assert.areEqual('High', rows[0].Impact__c, 'Lowercase impact coerced to canonical');    }

    @IsTest
    static void buildForDimension_LlmImpact_OffListNullifies() {
        // LLM hallucinates an impact value not in the picklist. Coerce to null
        // rather than passing through and breaking the insert.
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = 50;
        s.addIssue('Suspicious finding', 'Critical', 'Trivial', 'Urgent');

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Completeness', s
        );

        Assert.areEqual(1, rows.size(), 'Row still emitted — only severity nullified');
        Assert.isNull(rows[0].Impact__c, 'Off-list impact coerced to null');        Assert.areEqual('Suspicious finding', rows[0].Analysis_Text__c, 'Issue text preserved');
    }

    @IsTest
    static void buildForDimension_LlmImpact_TrimsWhitespace() {
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = 50;
        // Trailing spaces from LLM output should not block the picklist match.
        s.addIssue('Padded values', '  High  ', ' Quick Win ', 'Medium ');

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Completeness', s
        );

        Assert.areEqual('High', rows[0].Impact__c, 'Padded impact trimmed + coerced');    }

    @IsTest
    static void buildForDimension_LlmImpact_BlankStaysNull() {
        // Blank/null impact from the LLM stays null on the row.
        Id resultId = fakeId(KB_Dimension_Result__c.SObjectType);
        KBAssessmentModels.DimensionScore s = new KBAssessmentModels.DimensionScore();
        s.score = 50;
        s.addIssue('Missing summary', '', '   ', null);

        List<KB_Dimension_Analysis__c> rows = KBDimensionAnalysisService.buildForDimension(
            resultId, null, 'Completeness', s
        );

        Assert.isNull(rows[0].Impact__c);    }
}
