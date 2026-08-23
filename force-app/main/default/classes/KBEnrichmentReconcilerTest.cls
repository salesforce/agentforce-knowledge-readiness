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
@isTest
private class KBEnrichmentReconcilerTest {

    @isTest
    static void closeForPublishedArticles_marks_published_when_draft_matches() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(1, 'recon-pub');
        Id kavId = arts[0].Id;
        Knowledge__kav fresh = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :kavId];

 // Enrichment_Candidate__c is master-detail to the run — required parent.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Assessment_Run__c = run.Id,
            Source_Article_Version_Id__c = kavId,
            Source_Article_Title__c = 'A',
            Draft_Article_Version_Id__c = String.valueOf(kavId),
            Knowledge_Article_Id__c = String.valueOf(fresh.KnowledgeArticleId),
            Composite_Key__c = 'test-pub-' + kavId,
            Status__c = 'Pending',
            Is_Closed__c = false,
            Confidence_Score__c = 90
        );
        insert ec;

        Test.startTest();
        KBEnrichmentReconciler.closeForPublishedArticles(
            new Set<Id>{ fresh.KnowledgeArticleId },
            new Set<Id>{ kavId }
        );
        Test.stopTest();

        Enrichment_Candidate__c reloaded = [SELECT Status__c, Is_Closed__c FROM Enrichment_Candidate__c WHERE Id = :ec.Id];
        Assert.areEqual('Published', reloaded.Status__c, 'Matching draft id → Published');
        Assert.isTrue(reloaded.Is_Closed__c, 'Should be closed');
    }

    @isTest
    static void closeForPublishedArticles_marks_superseded_when_other_version_published() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'recon-sup');
        Id draftKavId = arts[0].Id;
        Id otherKavId = arts[1].Id; // same article id is unrealistic; use distinct article for the "other Online" KAV
        Knowledge__kav draftFresh = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :draftKavId];

 // Enrichment_Candidate__c is master-detail to the run — required parent.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Assessment_Run__c = run.Id,
            Source_Article_Version_Id__c = draftKavId,
            Source_Article_Title__c = 'A',
            Draft_Article_Version_Id__c = String.valueOf(draftKavId),
            Knowledge_Article_Id__c = String.valueOf(draftFresh.KnowledgeArticleId),
            Composite_Key__c = 'test-sup-' + draftKavId,
            Status__c = 'Pending',
            Is_Closed__c = false,
            Confidence_Score__c = 90
        );
        insert ec;

        Test.startTest();
        KBEnrichmentReconciler.closeForPublishedArticles(
            new Set<Id>{ draftFresh.KnowledgeArticleId },
            new Set<Id>{ otherKavId } // some other KAV went Online — not our draft
        );
        Test.stopTest();

        Enrichment_Candidate__c reloaded = [SELECT Status__c, Is_Closed__c FROM Enrichment_Candidate__c WHERE Id = :ec.Id];
        Assert.areEqual('Superseded', reloaded.Status__c, 'Different version Online → Superseded');
        Assert.isTrue(reloaded.Is_Closed__c);
    }

    @isTest
    static void closeForPublishedArticles_no_op_when_set_empty() {
        Test.startTest();
        KBEnrichmentReconciler.closeForPublishedArticles(new Set<Id>(), new Set<Id>());
        KBEnrichmentReconciler.closeForPublishedArticles(null, null);
        Test.stopTest();
        // Just asserting no exception.
        Assert.isTrue(true);
    }
}
