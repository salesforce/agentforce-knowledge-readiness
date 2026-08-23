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
private class KBDuplicateCandidateReconcilerTest {

    @isTest
    static void closeForPublishedArticles_marks_resolved_when_merged_matches() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'dc-recon-r');
        Id mergedKavId = arts[0].Id;
        Knowledge__kav fresh = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :mergedKavId];
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        Duplicate_Candidate__c dc = new Duplicate_Candidate__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_1__c = String.valueOf(arts[0].Id),
            Knowledge_Article_2__c = String.valueOf(arts[1].Id),
            Knowledge_Article_Id_1__c = String.valueOf(fresh.KnowledgeArticleId),
            Merged_Article__c = String.valueOf(mergedKavId),
            Merged_Knowledge_Article_Id__c = String.valueOf(fresh.KnowledgeArticleId),
            Composite_Key__c = 'test-dc-r-' + mergedKavId,
            Flag_Type__c = 'Duplicate',
            Status__c = 'Pending',
            Confidence_Score__c = 90,
            Source_Tier__c = 'Tier4_Agentic',
            Score_Calculated_Date__c = Datetime.now()
        );
        insert dc;

        Test.startTest();
        KBDuplicateCandidateReconciler.closeForPublishedArticles(
            new Set<Id>{ fresh.KnowledgeArticleId },
            new Set<Id>{ mergedKavId }
        );
        Test.stopTest();

        Duplicate_Candidate__c reloaded = [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :dc.Id];
        Assert.areEqual('Resolved', reloaded.Status__c);
    }

    @isTest
    static void closeForPublishedArticles_marks_superseded_when_other_version_published() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'dc-recon-s');
        Knowledge__kav fresh1 = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        Duplicate_Candidate__c dc = new Duplicate_Candidate__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_1__c = String.valueOf(arts[0].Id),
            Knowledge_Article_2__c = String.valueOf(arts[1].Id),
            Knowledge_Article_Id_1__c = String.valueOf(fresh1.KnowledgeArticleId),
            Composite_Key__c = 'test-dc-s-' + arts[0].Id,
            Flag_Type__c = 'Duplicate',
            Status__c = 'Pending',
            Confidence_Score__c = 80,
            Source_Tier__c = 'Tier4_Agentic',
            Score_Calculated_Date__c = Datetime.now()
        );
        insert dc;

        Test.startTest();
        // Article 1 got published, but no Merged_Article__c on this DC.
        // It must be marked Superseded — a different version was published
        // outside our flow.
        KBDuplicateCandidateReconciler.closeForPublishedArticles(
            new Set<Id>{ fresh1.KnowledgeArticleId },
            new Set<Id>{ arts[0].Id }
        );
        Test.stopTest();

        Duplicate_Candidate__c reloaded = [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :dc.Id];
        Assert.areEqual('Superseded', reloaded.Status__c);
    }

    // ──────────────────────────────────────────────────────────────────────
 // archiveMergedLosers derives the loser from the Duplicate_Candidate__c
    // junction (NOT a Merged_Into__c stamp on the loser, which is impossible:
    // Knowledge__kav fields are Draft-only writable — probe 2026-06-16). On
    // survivor publish, the loser = the non-survivor article on each Resolved
    // candidate pointing at that survivor master.
    //
    // NOTE: a POSITIVE archive assertion is impossible in pure Apex — test KAVs
    // can't reach PublishStatus='Online', so the archive-candidate query returns
    // empty and the publisher is never reached. The real archive is exercised by
    // the CDO49 org probe. These tests lock in the no-crash + correct-derivation
    // behaviour and the negative (non-matching survivor → no archive attempt).
    // ──────────────────────────────────────────────────────────────────────

    @isTest
    static void archiveMergedLosers_derivesLoserFromJunction_noCrashWhenNoOnlineLoser() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'dc-recon-arch');
        Knowledge__kav survivor = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        Knowledge__kav loser = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[1].Id];
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        // Resolved keep-survivor candidate: survivor master = arts[0], loser = arts[1].
        insert new Duplicate_Candidate__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_1__c = String.valueOf(arts[0].Id),
            Knowledge_Article_2__c = String.valueOf(arts[1].Id),
            Knowledge_Article_Id_1__c = String.valueOf(survivor.KnowledgeArticleId),
            Knowledge_Article_Id_2__c = String.valueOf(loser.KnowledgeArticleId),
            Merged_Knowledge_Article_Id__c = String.valueOf(survivor.KnowledgeArticleId),
            Composite_Key__c = 'test-dc-arch-' + arts[0].Id,
            Flag_Type__c = 'Duplicate',
            Status__c = 'Resolved',
            Confidence_Score__c = 95,
            Source_Tier__c = 'Tier4_Agentic',
            Score_Calculated_Date__c = Datetime.now()
        );

        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        KBDuplicateCandidateReconciler.publisher = pub;

        Test.startTest();
        // Survivor master published. The loser is derived from the junction; it is
        // not Online (test KAV) so nothing is archived — but the flow must not throw.
        KBDuplicateCandidateReconciler.closeForPublishedArticles(
            new Set<Id>{ survivor.KnowledgeArticleId },
            new Set<Id>{ arts[0].Id }
        );
        Test.stopTest();

        Assert.areEqual(0, pub.archiveCallCount,
            'loser is not Online in a test context → no archive attempt, no crash');
    }

    @isTest
    static void archiveMergedLosers_unrelatedSurvivor_noArchive() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'dc-recon-unrel');
        Knowledge__kav survivor = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        Knowledge__kav loser = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[1].Id];
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        insert new Duplicate_Candidate__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_1__c = String.valueOf(arts[0].Id),
            Knowledge_Article_2__c = String.valueOf(arts[1].Id),
            Knowledge_Article_Id_1__c = String.valueOf(survivor.KnowledgeArticleId),
            Knowledge_Article_Id_2__c = String.valueOf(loser.KnowledgeArticleId),
            Merged_Knowledge_Article_Id__c = String.valueOf(survivor.KnowledgeArticleId),
            Composite_Key__c = 'test-dc-unrel-' + arts[0].Id,
            Flag_Type__c = 'Duplicate',
            Status__c = 'Resolved',
            Confidence_Score__c = 95,
            Source_Tier__c = 'Tier4_Agentic',
            Score_Calculated_Date__c = Datetime.now()
        );

        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        KBDuplicateCandidateReconciler.publisher = pub;

        Test.startTest();
        // A DIFFERENT article published — no Resolved candidate points at it as a
        // survivor, so no loser is derived and nothing is archived.
        KBDuplicateCandidateReconciler.closeForPublishedArticles(
            new Set<Id>{ loser.KnowledgeArticleId },
            new Set<Id>{ arts[1].Id }
        );
        Test.stopTest();

        Assert.areEqual(0, pub.archiveCallCount, 'unrelated publish triggers no archive');
    }
}
