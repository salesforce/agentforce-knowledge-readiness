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
 * Coverage for KBImprovementFixFacade — the canonical @AuraEnabled entry
 * for the AI Fix flow. The facade is intentionally thin (every method
 * delegates to KBImprovementFixService), so these tests assert the
 * delegation shape rather than re-test the orchestration logic that
 * KBImprovementFixServiceTest already covers.
 */
@IsTest
private class KBImprovementFixFacadeTest {

    private static KB_Dimension_Analysis__c setupRec(Knowledge__kav kav) {
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
            Status__c = 'Open'
        );
        insert rec;
        return rec;
    }

    @IsTest
    static void testFacade_DispatchArticleFix_DelegatesToService() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'facade-single')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        Test.startTest();
        KBImprovementFixFacade.dispatchArticleFix(
            kav.Id,
            true,
            new List<Id>{ rec.Id },
            new List<String>{ '[Completeness] Add a summary section.' }
        );
        Test.stopTest();

        KB_Dimension_Analysis__c reread =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Resolved', reread.Status__c,
            'Facade delegated to service which resolved the rec');
    }

    @IsTest
    static void testFacade_DispatchArticleFixesBulk_DelegatesAndReturnsResult() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'facade-bulk')[0];
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

        Assert.isNotNull(result, 'Facade returns the service result');
        Assert.isNotNull(result.pipelineRunId,
            'Facade exposes pipelineRunId for LWC empApi subscription');
    }

    /**
     * Finding 5 — bulk surface. The bulk method has its own try/catch with
     * the same setMessage pattern; this test exercises the catch by passing
     * a list containing a `null` element. The service iterates `requests`
     * to stamp `pipelineRunId` on each — a null element raises NPE at
     * `req.pipelineRunId = pipelineRunId`, which is a non-AHE exception.
     * The facade must catch that and re-throw as AHE with the friendly
     * prefix preserved through `setMessage(...)`.
     */
    @IsTest
    static void testDispatchArticleFixesBulk_WrapsCauseWithSetMessage() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'facade-bulk-wrap')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);
        PromptTemplateService.setMock(new MockPromptTemplateService());

        // Build a list with a real request followed by a null entry — the
        // service's stamp-pipelineRunId loop will NPE on the null and the
        // facade must wrap that in AHE.
        KBImprovementFixService.BulkFixRequest req = new KBImprovementFixService.BulkFixRequest();
        req.articleVersionId = kav.Id;
        req.useCurrentOnline = true;
        req.recIds = new List<Id>{ rec.Id };
        req.issueDescriptions = new List<String>{ '[Completeness] Add a summary section.' };

        Test.startTest();
        Boolean threw = false;
        String caughtMessage = null;
        try {
            KBImprovementFixFacade.dispatchArticleFixesBulk(
                new List<KBImprovementFixService.BulkFixRequest>{ req, null }
            );
        } catch (AuraHandledException ahe) {
            threw = true;
            caughtMessage = ahe.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'Bulk facade must wrap the underlying NPE as AuraHandledException');
        Assert.isNotNull(caughtMessage, 'Caught AHE has a non-null getMessage()');
        Assert.isTrue(caughtMessage.contains('Fix failed:'),
            'Friendly prefix preserved through setMessage() — got: ' + caughtMessage);
    }

    /**
     * The service used to wrap every
     * runtime exception in `new AuraHandledException('Fix failed: ' + msg)`,
     * but Aura strips the message client-side — the LWC user only saw the
     * generic 'Script-thrown exception' platform default. The fix moves the
     * AHE wrap to the facade and uses `setMessage(...)` so the friendly text
     * survives the Aura boundary.
     *
     * Verification path: force the underlying LLM call to throw via
     * `MockPromptTemplateService.throwException`. The service's catch block
     * marks recs Error and re-throws the original `KnowledgeAIException`.
     * The facade catches that non-AHE, wraps in AHE, calls `setMessage(...)`,
     * and re-throws.
     *
     * Assertion: the AHE caught at the test boundary has a message containing
     * both 'Fix failed:' (the facade's prefix) and the underlying cause text
     * ('Mock fix error'). If `setMessage()` regressed, `getMessage()` would
     * return the platform's 'Script-thrown exception' fallback and the
     * substring assertion fails.
     */
    @IsTest
    static void testDispatchArticleFix_WrapsCauseWithSetMessage() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'facade-wrap')[0];
        KB_Dimension_Analysis__c rec = setupRec(kav);

        MockPromptTemplateService mock = new MockPromptTemplateService();
        mock.throwException = true;   // → fixArticleIssues throws KnowledgeAIException('Mock fix error')
        PromptTemplateService.setMock(mock);

        Test.startTest();
        Boolean threw = false;
        String caughtMessage = null;
        try {
            KBImprovementFixFacade.dispatchArticleFix(
                kav.Id,
                true,
                new List<Id>{ rec.Id },
                new List<String>{ '[Completeness] Add a summary section.' }
            );
        } catch (AuraHandledException ahe) {
            threw = true;
            caughtMessage = ahe.getMessage();
        }
        Test.stopTest();

        Assert.isTrue(threw,
            'Facade must re-throw as AuraHandledException after underlying KnowledgeAIException');
        Assert.isNotNull(caughtMessage, 'Caught AHE has a non-null getMessage()');
        Assert.isTrue(caughtMessage.contains('Fix failed:'),
            'Friendly prefix preserved through setMessage() — got: ' + caughtMessage);
        Assert.isTrue(caughtMessage.contains('Mock fix error'),
            'Underlying cause text preserved through setMessage() — got: ' + caughtMessage);

        // The recs should still have flipped to Error inside the service's
        // catch block before the original exception was re-thrown.
        KB_Dimension_Analysis__c reloaded =
            [SELECT Status__c FROM KB_Dimension_Analysis__c WHERE Id = :rec.Id];
        Assert.areEqual('Error', reloaded.Status__c,
            'Service catch still marks recs Error before the re-throw');
    }

    /**
 * a USER_MODE FLS denial surfaces as "No such column 'X' on entity
     * 'Knowledge__kav'". toFriendly must translate that into an actionable FLS
     * message instead of the raw "Fix failed: No such column …".
     */
    @IsTest
    static void testToFriendly_FlsDenialTranslatedToActionableMessage() {
        Exception flsLike = new KnowledgeAIException(
            'No such column \'FAQ_Question__c\' on entity \'Knowledge__kav\'.'
        );

        Test.startTest();
        AuraHandledException ahe = KBImprovementFixFacade.toFriendly(flsLike);
        Test.stopTest();

        String msg = ahe.getMessage();
        Assert.isTrue(msg.containsIgnoreCase('Field-level security'),
            'FLS denial should translate to an FLS-grant message — got: ' + msg);
        Assert.isTrue(msg.containsIgnoreCase('Content Scope'),
            'Message points the admin at Content Scope config — got: ' + msg);
        Assert.isFalse(msg.contains('No such column'),
            'Raw schema-looking error should not leak to the user — got: ' + msg);
    }

    /**
 * a user without Knowledge object Create/Edit (no KB_Knowledge_Author
     * permset) hits a USER_MODE object-CRUD denial worded "DML operation UPDATE
     * not allowed on Knowledge__kav" (System.TypeException). toFriendly must
     * translate that into the actionable "assign KB Knowledge Author" message,
     * not the raw "Fix failed: DML operation …".
     */
    @IsTest
    static void testToFriendly_ObjectCrudDenialTranslatedToPermsetMessage() {
        Exception crudLike = new KnowledgeAIException(
            'DML operation UPDATE not allowed on Knowledge__kav'
        );

        Test.startTest();
        AuraHandledException ahe = KBImprovementFixFacade.toFriendly(crudLike);
        Test.stopTest();

        String msg = ahe.getMessage();
        Assert.isTrue(msg.containsIgnoreCase('KB Knowledge Author'),
            'Object-CRUD denial should name the KB Knowledge Author permset — got: ' + msg);
        Assert.isFalse(msg.containsIgnoreCase('DML operation'),
            'Raw DML-denial text should not leak to the user — got: ' + msg);
    }

    @IsTest
    static void testToFriendly_OtherErrorsKeepFixFailedPrefix() {
        Exception other = new KnowledgeAIException('Some other failure');

        Test.startTest();
        AuraHandledException ahe = KBImprovementFixFacade.toFriendly(other);
        Test.stopTest();

        Assert.isTrue(ahe.getMessage().contains('Fix failed: Some other failure'),
            'Non-FLS errors keep the existing prefix — got: ' + ahe.getMessage());
    }
}
