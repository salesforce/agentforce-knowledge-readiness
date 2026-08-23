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
 * Coverage for KBImprovementFixService (orchestration layer). Tests exercise
 * the orchestration through the canonical @AuraEnabled entry point
 * (`KBImprovementFixFacade`) so the contract under test mirrors what the LWC
 * and any future Agentforce action invoke at runtime.
 *
 * LLM calls are exercised via MockPromptTemplateService so no callout
 * budget is consumed. The service uses Database.queryWithBinds + USER_MODE,
 * so test users must have Knowledge__kav read/edit visible — KBTestDataFactory
 * inserts Draft articles owned by the running user which satisfies that.
 */
@IsTest
private class KBImprovementFixServiceTest {

    private static KB_Dimension_Analysis__c setupRec(Knowledge__kav kav) {
        return setupRec(kav, 'Open');
    }

    private static KB_Dimension_Analysis__c setupRec(Knowledge__kav kav, String status) {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_Id__c = kav.Id,
            Article_Title__c = kav.Title,
            Overall_Score__c = 45,
            Readiness_Status__c = 'Needs Work'
        );
        insert aa;
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id,
            Dimension__c = 'Completeness',
            Score__c = 45
        );
        insert dr;
        KB_Dimension_Analysis__c rec = new KB_Dimension_Analysis__c(
            Article_Assessment__c = aa.Id,
            Dimension_Result__c = dr.Id,
            Type__c = 'Issue',
            Dimension__c = 'Completeness',
            Recommendation__c = 'Add a summary section.',
            Status__c = status
        );
        insert rec;
        return rec;
    }

    @IsTest
    static void testDispatchArticleFix_BlankArticleId_Throws() {
        Test.startTest();
        try {
            KBImprovementFixFacade.dispatchArticleFix(
                '',
                true,
                new List<Id>{ UserInfo.getUserId() },
                new List<String>{ 'some issue' }
            );
            Assert.fail('Expected AuraHandledException for blank articleId');
        } catch (AuraHandledException e) {
            // expected
        }
        Test.stopTest();
    }

    @IsTest
    static void testDispatchArticleFix_EmptyRecIds_Throws() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fix');
        Test.startTest();
        try {
            KBImprovementFixFacade.dispatchArticleFix(
                kavs[0].Id,
                true,
                new List<Id>(),
                new List<String>{ 'issue' }
            );
            Assert.fail('Expected AuraHandledException for empty recIds');
        } catch (AuraHandledException e) {
            // expected
        }
        Test.stopTest();
    }

    /**
     * T5 (restructured): ArticleNotFound now stamps Queued first (because the
     * FOR UPDATE lock + Queued update happen BEFORE the article fetch), then
     * the catch flips to Error. We use a real article id pattern so the lock
     * step succeeds; the article SOQL itself returns empty → KnowledgeAIException
     * → catch → markRecsStatus('Error').
     */
    @IsTest
    static void testDispatchArticleFix_ArticleNotFound_StampsQueuedThenError() {
        // Insert a valid kav so we can build a valid rec, but pass a different
        // valid-shape Knowledge__kav id to dispatchArticleFix so the SOQL
        // fetch returns empty and we hit the "Article not found" branch.
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixnotfound');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);

        // Build a valid-shape Knowledge__kav id that doesn't match any row.
        // Knowledge__kav uses a 3-character key prefix; we mint one with a
        // 15-char numeric suffix (a valid-shape but non-existent id).
        // An all-zero suffix is rejected by Salesforce as "Invalid id", so
        // we pad with a numeric tail that's structurally valid.
        String kavPrefix = Knowledge__kav.SObjectType.getDescribe().getKeyPrefix();
        Id ghostId = (Id)(kavPrefix + '000000000000001');

        Test.startTest();
        Boolean threw = false;
        try {
            KBImprovementFixFacade.dispatchArticleFix(
                ghostId,
                false,                       // skip the Online-version lookup branch
                new List<Id>{ rec.Id },
                new List<String>{ 'issue' }
            );
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Service rethrows AuraHandledException after marking Error');
        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Error', reloaded.Status__c,
            'Recs flip to Error after the article-not-found catch');
    }

    /**
     * T5 (additional): ensure invalid (malformed) version id surfaces as Error
     * via the same catch path, separate from the well-formed-but-missing case.
     */
    @IsTest
    static void testDispatchArticleFix_InvalidIdShape_FailsToError() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixmalformed');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);

        Test.startTest();
        Boolean threw = false;
        try {
            KBImprovementFixFacade.dispatchArticleFix(
                'not-a-real-id',
                false,
                new List<Id>{ rec.Id },
                new List<String>{ 'issue' }
            );
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Malformed id triggers a downstream exception');
        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Error', reloaded.Status__c,
            'Malformed id still flips recs to Error via the catch path');
    }

    /**
     * T6: re-query the Draft kav after dispatch and assert the Title and
     * Summary equal the rewritten values. Default mock returns input as
     * output — we override with explicit rewrites so a silent drop would
     * fail this assertion.
     */
    @IsTest
    static void testDispatchArticleFix_HappyPath_PersistsRewrittenFieldsToDraft() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixhappy');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FixArticleResult forced = new PromptTemplateService.FixArticleResult();
        forced.rewrittenFields = new Map<String, String>{
            'Title'   => 'AI-rewritten title',
            'Summary' => 'AI-rewritten summary that the LLM produced.'
        };
        forced.changesSummary = 'Mock changes summary';
        mock.mockFixArticleResult = forced;
        PromptTemplateService.setMock(mock);

        Test.startTest();
        KBImprovementFixFacade.dispatchArticleFix(
            kavs[0].Id,
            true,
            new List<Id>{ rec.Id },
            new List<String>{ '[Completeness] Add a summary section.' }
        );
        Test.stopTest();

        // Re-query the kav and assert rewritten fields landed.
        Knowledge__kav reread = [
            SELECT Id, Title, Summary, PublishStatus
            FROM Knowledge__kav
            WHERE Id = :kavs[0].Id LIMIT 1
        ];
        Assert.areEqual('AI-rewritten title', reread.Title,
            'Title must be persisted from the LLM rewrite');
        Assert.areEqual('AI-rewritten summary that the LLM produced.', reread.Summary,
            'Summary must be persisted from the LLM rewrite');

        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Resolved', reloaded.Status__c,
            'Rec flips to Resolved on happy path');
    }

 // the Enrichment_Candidate__c created by a fix must be stamped with
    // the assessment run behind the fixed rec, so drafts are traceable to their
 // run (filter-by-run in the inbox + cascade cleanup).
    @IsTest
    static void testDispatchArticleFix_StampsAssessmentRunOnCandidate() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixrun');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);
        // The run behind this rec's assessment — what we expect stamped on the EC.
        Id expectedRunId = [
            SELECT Article_Assessment__r.Assessment_Run__c
            FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id
        ].Article_Assessment__r.Assessment_Run__c;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FixArticleResult forced = new PromptTemplateService.FixArticleResult();
        forced.rewrittenFields = new Map<String, String>{
            'Summary' => 'AI-rewritten summary that the LLM produced.'
        };
        forced.changesSummary = 'Mock changes summary';
        mock.mockFixArticleResult = forced;
        PromptTemplateService.setMock(mock);

        Test.startTest();
        KBImprovementFixFacade.dispatchArticleFix(
            kavs[0].Id, true, new List<Id>{ rec.Id },
            new List<String>{ '[Completeness] Add a summary section.' }
        );
        Test.stopTest();

        // KnowledgeArticleId isn't reflected on the in-memory row after insert;
        // the fix flow keys the EC's Composite_Key__c on it, so re-query.
        String articleId = String.valueOf(
            [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :kavs[0].Id LIMIT 1].KnowledgeArticleId
        );
        Enrichment_Candidate__c ec = [
            SELECT Assessment_Run__c FROM Enrichment_Candidate__c
            WHERE Knowledge_Article_Id__c = :articleId
            LIMIT 1
        ];
        Assert.areEqual(expectedRunId, ec.Assessment_Run__c,
            'EC is stamped with the run that produced the fixed rec');
    }

    @IsTest
    static void testDispatchArticleFix_PassesStrengthsToPrompt() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixstrengths');
        KB_Dimension_Analysis__c issueRec = setupRec(kavs[0]);

        // Add a Strength row on the same assessment, on a different dimension
        KB_Dimension_Result__c structureResult = new KB_Dimension_Result__c(
            Article_Assessment__c = issueRec.Article_Assessment__c,
            Dimension__c = 'Structure',
            Score__c = 90
        );
        insert structureResult;
        insert new KB_Dimension_Analysis__c(
            Article_Assessment__c = issueRec.Article_Assessment__c,
            Dimension_Result__c   = structureResult.Id,
            Type__c               = 'Strength',
            Dimension__c          = 'Structure',
            Analysis_Text__c      = 'Clear section headings and short paragraphs',
            Status__c             = 'Open'
        );

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Test.startTest();
        KBImprovementFixFacade.dispatchArticleFix(
            kavs[0].Id,
            true,
            new List<Id>{ issueRec.Id },
            new List<String>{ '[Completeness] Add a summary section.' }
        );
        Test.stopTest();

        Assert.areEqual(1, mock.fixArticleCallCount, 'fix prompt called once');
        Assert.isNotNull(mock.fixArticleLastStrengthsList, 'strengths list passed to prompt');
        Assert.isTrue(
            mock.fixArticleLastStrengthsList.contains('Clear section headings'),
            'strengths list contains Strength row text — got: ' + mock.fixArticleLastStrengthsList
        );
        Assert.isTrue(
            mock.fixArticleLastStrengthsList.contains('[Structure]'),
            'strengths list prefixes each line with its dimension'
        );
    }

    @IsTest
    static void testDispatchArticleFix_NoStrengths_PassesEmptyList() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixnostrength');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Test.startTest();
        KBImprovementFixFacade.dispatchArticleFix(
            kavs[0].Id,
            true,
            new List<Id>{ rec.Id },
            new List<String>{ '[Completeness] Add a summary section.' }
        );
        Test.stopTest();

        Assert.areEqual('', mock.fixArticleLastStrengthsList,
            'No Strength rows on the assessment → empty strengths list (service builds an empty string; PromptTemplateService normalizes that to "(none identified)" before sending to the LLM)');
    }

    /**
     * T4: LLM returns empty rewrittenFields → service must throw the
     * "no rewritten fields" KnowledgeAIException, mark rec Error, and
     * NOT create an Enrichment_Candidate__c.
     */
    @IsTest
    static void testDispatchArticleFix_EmptyLLMResponse_FlipsToErrorNoCandidate() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixempty');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FixArticleResult forced = new PromptTemplateService.FixArticleResult();
        forced.rewrittenFields = new Map<String, String>(); // <- empty
        forced.changesSummary  = '';
        mock.mockFixArticleResult = forced;
        PromptTemplateService.setMock(mock);

        Integer candidatesBefore = [SELECT COUNT() FROM Enrichment_Candidate__c];

        Test.startTest();
        Boolean threw = false;
        try {
            KBImprovementFixFacade.dispatchArticleFix(
                kavs[0].Id,
                true,
                new List<Id>{ rec.Id },
                new List<String>{ '[Completeness] Add a summary section.' }
            );
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Empty rewrittenFields throws via the no-fields guard');
        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Error', reloaded.Status__c, 'Rec flips to Error');
        Integer candidatesAfter = [SELECT COUNT() FROM Enrichment_Candidate__c];
        Assert.areEqual(candidatesBefore, candidatesAfter,
            'No Enrichment_Candidate__c created when LLM returns empty fields');
    }

    /**
 * LLM returns rewrites but the running user can't edit ANY of the
     * targeted fields (all skipped by the isUpdateable FLS filter in
     * persistDraft). Previously this wrote an Id-only record — a no-op update
     * that succeeded — and the rec was marked Resolved with nothing rewritten
     * (a silent success). It must now fail loudly: rec → Error, no phantom
     * draft, no Enrichment_Candidate__c.
     *
     * We can't strip FLS from a real content field as the admin test user, so
     * we exercise the exact guard branch by returning only a real-but-
     * non-updateable field (CreatedById is never updateable for anyone) — it
     * hits `!dfr.isUpdateable() → continue`, leaving contentFieldsWritten == 0.
     */
    @IsTest
    static void testDispatchArticleFix_NoWritableContentField_FlipsToErrorNotResolved() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixnofls');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);
        String originalSummary = kavs[0].Summary;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FixArticleResult forced = new PromptTemplateService.FixArticleResult();
        // Only a non-updateable field → every field is skipped by the FLS filter.
        forced.rewrittenFields = new Map<String, String>{ 'CreatedById' => UserInfo.getUserId() };
        forced.changesSummary  = 'should not persist';
        mock.mockFixArticleResult = forced;
        PromptTemplateService.setMock(mock);

        Integer candidatesBefore = [SELECT COUNT() FROM Enrichment_Candidate__c];

        Test.startTest();
        Boolean threw = false;
        String msg;
        try {
            KBImprovementFixFacade.dispatchArticleFix(
                kavs[0].Id,
                true,
                new List<Id>{ rec.Id },
                new List<String>{ '[Completeness] Add a summary section.' }
            );
        } catch (Exception e) {
            threw = true;
            msg = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw, 'No writable content field must throw, not silently succeed');
        Assert.isTrue(
            msg != null && msg.containsIgnoreCase('content fields'),
            'Error carries the actionable content-field FLS message; got: ' + msg
        );
        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Error', reloaded.Status__c,
            'Rec flips to Error (retryable) — NOT a false Resolved');
        Integer candidatesAfter = [SELECT COUNT() FROM Enrichment_Candidate__c];
        Assert.areEqual(candidatesBefore, candidatesAfter,
            'No Enrichment_Candidate__c created when nothing was written');
        // The draft body is untouched.
        Knowledge__kav reread =
            [SELECT Summary FROM Knowledge__kav WHERE Id = :kavs[0].Id LIMIT 1];
        Assert.areEqual(originalSummary, reread.Summary,
            'Article content is unchanged when the write was a no-op');
    }

    /**
 * (review finding F599-1): the realistic split — the LLM returns a
     * writable Title AND content fields the user CANNOT edit. Title alone is
     * NOT a fix (the recommendations are body/content issues), so the guard
     * must still fire. Previously Title was counted unconditionally, so
     * fieldsWritten was ≥1, the guard was bypassed, only Title changed, and the
 * rec was marked Resolved — the exact silent success targets. Now the
     * guard counts CONTENT fields only, and Title is FLS-gated like the rest.
     *
     * We return Title (writable for the admin runner) + CreatedById (a real,
     * never-updateable stand-in for a content field the user can't edit), so
     * contentFieldsWritten == 0 while Title would otherwise "count".
     */
    @IsTest
    static void testDispatchArticleFix_TitleWritableButNoContentFLS_FlipsToError() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixtitleonly');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);
        String originalTitle = kavs[0].Title;
        String originalSummary = kavs[0].Summary;

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.FixArticleResult forced = new PromptTemplateService.FixArticleResult();
        forced.rewrittenFields = new Map<String, String>{
            'Title'       => 'AI-rewritten title that must NOT persist alone',
            'CreatedById' => UserInfo.getUserId() // non-updateable content stand-in
        };
        forced.changesSummary = 'should not persist';
        mock.mockFixArticleResult = forced;
        PromptTemplateService.setMock(mock);

        Integer candidatesBefore = [SELECT COUNT() FROM Enrichment_Candidate__c];

        Test.startTest();
        Boolean threw = false;
        String msg;
        try {
            KBImprovementFixFacade.dispatchArticleFix(
                kavs[0].Id, true, new List<Id>{ rec.Id },
                new List<String>{ '[Completeness] Rewrite the body.' }
            );
        } catch (Exception e) {
            threw = true; msg = e.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'Title-writable but no content FLS must still throw (Title alone is not a fix)');
        Assert.isTrue(msg != null && msg.containsIgnoreCase('content fields'),
            'Carries the content-field FLS message; got: ' + msg);
        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Error', reloaded.Status__c,
            'Rec → Error, NOT Resolved, when only Title was writable (F599-1)');
        Assert.areEqual(candidatesBefore, [SELECT COUNT() FROM Enrichment_Candidate__c],
            'No Enrichment_Candidate__c created');
        // Neither Title nor Summary persisted (the whole write was guarded off).
        Knowledge__kav reread =
            [SELECT Title, Summary FROM Knowledge__kav WHERE Id = :kavs[0].Id LIMIT 1];
        Assert.areEqual(originalTitle, reread.Title,
            'Title must NOT persist when the fix bailed out on no writable content');
        Assert.areEqual(originalSummary, reread.Summary, 'Summary unchanged');
    }

    /**
     * C1: a second dispatch on already-Queued recs must NOT call the LLM.
     * We pre-Queue the rec, then dispatch — the FOR UPDATE filter on
     * Status__c='Open' returns zero rows and we bail out before the LLM.
     */
    @IsTest
    static void testDispatchArticleFix_AlreadyQueuedRec_SkipsLLM() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixqueued');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0], 'Queued'); // pre-Queued

        MockPromptTemplateService mock = new MockPromptTemplateService();
        PromptTemplateService.setMock(mock);

        Test.startTest();
        KBImprovementFixFacade.dispatchArticleFix(
            kavs[0].Id,
            true,
            new List<Id>{ rec.Id },
            new List<String>{ '[Completeness] Add a summary section.' }
        );
        Test.stopTest();

        Assert.areEqual(0, mock.fixArticleCallCount,
            'C1 guard: rec not Open → LLM must not be called');
        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Queued', reloaded.Status__c,
            'Rec status untouched when guard short-circuits');
    }

    /**
     * A happy-path single-shot dispatch creates one Enrichment_Candidate__c
     * parented to the resolved assessment run. Visibility is inherited from the
 * run (master-detail / controlled-by-parent,) — there is no explicit
     * sharing step — so we assert the candidate exists and carries the expected
     * run-scoped composite key.
     */
    @IsTest
    static void testDispatchArticleFix_HappyPath_CreatesEnrichmentCandidate() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixshare');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        Test.startTest();
        KBImprovementFixFacade.dispatchArticleFix(
            kavs[0].Id,
            true,
            new List<Id>{ rec.Id },
            new List<String>{ '[Completeness] Add a summary section.' }
        );
        Test.stopTest();

        // Re-query the kav to get the auto-populated KnowledgeArticleId
        // (the returned in-memory record from `insert` doesn't always carry it).
        Knowledge__kav reread = [
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :kavs[0].Id LIMIT 1
        ];
        List<Enrichment_Candidate__c> cands = [
            SELECT Id, Composite_Key__c, Source_Article_Version_Id__c
            FROM Enrichment_Candidate__c
            WHERE Source_Article_Version_Id__c = :String.valueOf(kavs[0].Id)
        ];
        Assert.areEqual(1, cands.size(), 'Single Enrichment_Candidate__c created');
        // Key is run-scoped now: 'ai-fix-' + <assessmentRunId> + '-' + <articleId>.
        // Assert the stable ends (prefix + article suffix) without hardcoding the
        // run id, and that it is genuinely run-scoped (longer than the legacy form).
        String key = cands[0].Composite_Key__c;
        Assert.isTrue(key.startsWith('ai-fix-'), 'Composite key keeps the ai-fix- prefix');
        Assert.isTrue(key.endsWith('-' + reread.KnowledgeArticleId),
            'Composite key still tracks the parent KnowledgeArticleId');
        Assert.isTrue(key != 'ai-fix-' + reread.KnowledgeArticleId,
            'Composite key is run-scoped (embeds the assessment run id)');
    }

    /**
     * T3: useCurrentOnline=true — the SOQL "find Online version" runs.
     * In test context no Online version exists, so the lookup returns empty
     * and effectiveVersionId stays as the originally-passed version id.
     * We can't actually publish in a test, so this asserts that the
     * Online-resolution branch doesn't break the happy path.
     */
    @IsTest
    static void testDispatchArticleFix_UseCurrentOnline_LookupBranchExecutes() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'fixonline');
        KB_Dimension_Analysis__c rec = setupRec(kavs[0]);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        Test.startTest();
        KBImprovementFixFacade.dispatchArticleFix(
            kavs[0].Id,
            true,                           // <- useCurrentOnline branch
            new List<Id>{ rec.Id },
            new List<String>{ '[Completeness] Add a summary section.' }
        );
        Test.stopTest();

        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Resolved', reloaded.Status__c,
            'useCurrentOnline=true with no Online version still completes via Draft fallback');
    }

    // ──────────────────────────────────────────────────────────────────────
 // T1: dispatchArticleFixesBulk — Queueable branch (≤ 50,)
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testDispatchArticleFixesBulk_SmallSize_TakesQueueablePath_StampsQueued() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'fixbulk-small')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        KBImprovementFixService.BulkFixRequest req = new KBImprovementFixService.BulkFixRequest();
        req.articleVersionId = kav.Id;
        req.useCurrentOnline = true;
        req.recIds = new List<Id>{ rec.Id };
        req.issueDescriptions = new List<String>{ '[Completeness] Add a summary section.' };

        Test.startTest();
        KBImprovementFixService.BulkDispatchResult result =
            KBImprovementFixFacade.dispatchArticleFixesBulk(
                new List<KBImprovementFixService.BulkFixRequest>{ req }
            );
        Test.stopTest();

        // Within the same transaction the queueable runs synchronously after
        // stopTest() — by then the rec has been processed end-to-end.
        Assert.isNotNull(result, 'Bulk dispatch returns a result');
        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Resolved', reloaded.Status__c,
            'Queueable branch processed the request end-to-end');
    }

    @IsTest
    static void testDispatchArticleFixesBulk_NullOrEmpty_NoOp() {
        // Null and empty input list both return without enqueueing.
        Test.startTest();
        KBImprovementFixService.BulkDispatchResult r1 =
            KBImprovementFixFacade.dispatchArticleFixesBulk(null);
        KBImprovementFixService.BulkDispatchResult r2 =
            KBImprovementFixFacade.dispatchArticleFixesBulk(
                new List<KBImprovementFixService.BulkFixRequest>()
            );
        Test.stopTest();

        Assert.isNotNull(r1, 'Null input returns a non-null result');
        Assert.isNull(r1.pipelineRunId, 'Null input creates no pipeline run row');
        Assert.isNotNull(r2, 'Empty input returns a non-null result');
        Assert.isNull(r2.pipelineRunId, 'Empty input creates no pipeline run row');
    }

    /**
 * T1 (Batch branch).— with > 50 requests, the dispatcher routes to
     * `Database.executeBatch(KBFixArticleBatch, 10)` instead of the self-chaining
     * Queueable (which caps at 5×10 = 50 and would silently drop the tail). We
     * can't run a many-request batch end-to-end in test context (the platform
     * requires the iterable size to match the chunk size, otherwise "No more than
     * one executeBatch can be called"), so we flip `suppressBatchEnqueueForTest=true`
     * and assert the dispatcher still creates the pipeline run row and routes
     * through the `> 50` branch. 51 requests is the smallest that trips it.
     */
    @IsTest
    static void testDispatchArticleFixesBulk_LargeSize_TakesBatchPath() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'fixbulk-large')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        List<KBImprovementFixService.BulkFixRequest> reqs =
            new List<KBImprovementFixService.BulkFixRequest>();
        for (Integer i = 0; i < 51; i++) {
            KBImprovementFixService.BulkFixRequest r = new KBImprovementFixService.BulkFixRequest();
            r.articleVersionId  = kav.Id;
            r.useCurrentOnline  = true;
            r.recIds            = i == 0 ? new List<Id>{ rec.Id } : new List<Id>();
            r.issueDescriptions = new List<String>{ 'irrelevant' };
            reqs.add(r);
        }

        // Suppress the actual Database.executeBatch call so the platform
        // doesn't trip the chunk-size guard.
        KBImprovementFixService.suppressBatchEnqueueForTest = true;

        try {
            KBImprovementFixService.BulkDispatchResult result =
                KBImprovementFixFacade.dispatchArticleFixesBulk(reqs);

            Assert.isNotNull(result, 'Batch branch returns a result');
            Assert.isNotNull(result.pipelineRunId,
                'Batch branch still creates the AI Fix pipeline run row');
            KB_Pipeline_Run__c run = [
                SELECT Execution_Modes__c, Total_Input_Articles__c
                FROM KB_Pipeline_Run__c WHERE Id = :result.pipelineRunId LIMIT 1
            ];
            Assert.areEqual('AI Fix', run.Execution_Modes__c, 'Pipeline run tagged correctly');
            Assert.areEqual(51, (Integer)run.Total_Input_Articles__c,
                'Total_Input_Articles__c reflects the >50 request count');
 // Discriminating assertion: with the batch enqueue
            // suppressed, the >50 branch enqueues NOTHING. If the threshold ever
            // regressed to 500, 51 requests would take the Queueable branch and
            // System.enqueueJob would bump this to 1 — so a threshold revert now
            // fails here rather than passing silently.
            Assert.areEqual(0, Limits.getQueueableJobs(),
                '>50 requests must take the Batch path — no Queueable is enqueued');
        } finally {
            KBImprovementFixService.suppressBatchEnqueueForTest = false;
        }
    }

    /**
     * AR2 publish-side: bulk dispatch must stamp a KB_Pipeline_Run__c row
     * with Execution_Modes__c='AI Fix' and return its id on the result. The
     * LWC will subscribe to that run id via lightning/empApi (WT-4 wiring).
     */
    @IsTest
    static void testDispatchArticleFixesBulk_CreatesAIFixPipelineRun() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'fixbulk-run')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        KBImprovementFixService.BulkFixRequest req = new KBImprovementFixService.BulkFixRequest();
        req.articleVersionId = kav.Id;
        req.useCurrentOnline = true;
        req.recIds = new List<Id>{ rec.Id };
        req.issueDescriptions = new List<String>{ 'issue' };

        Test.startTest();
        KBImprovementFixService.BulkDispatchResult result =
            KBImprovementFixFacade.dispatchArticleFixesBulk(
                new List<KBImprovementFixService.BulkFixRequest>{ req }
            );
        Test.stopTest();

        Assert.isNotNull(result.pipelineRunId,
            'Bulk dispatch returns a pipelineRunId so the LWC can subscribe');
        KB_Pipeline_Run__c run = [
            SELECT Id, Execution_Modes__c, Status__c, Total_Input_Articles__c
            FROM KB_Pipeline_Run__c WHERE Id = :result.pipelineRunId LIMIT 1
        ];
        Assert.areEqual('AI Fix', run.Execution_Modes__c,
            'Pipeline run tagged with Execution_Modes__c=AI Fix');
        Assert.areEqual(1, (Integer)run.Total_Input_Articles__c,
            'Pipeline run records article count');
    }
}
