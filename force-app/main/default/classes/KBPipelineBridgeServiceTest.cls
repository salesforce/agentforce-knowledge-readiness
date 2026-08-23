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
private class KBPipelineBridgeServiceTest {

    @TestSetup
    static void setupTestData() {
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        // Create test Duplicate_Candidate__c records
        List<Duplicate_Candidate__c> candidates = new List<Duplicate_Candidate__c>();

        candidates.add(new Duplicate_Candidate__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_1__c = 'kA0xx0000000001',
            Knowledge_Article_2__c = 'kA0xx0000000002',
            Article_1_Title__c = 'Article A',
            Article_2_Title__c = 'Article B',
            Confidence_Score__c = 85,
            Flag_Type__c = 'Duplicate',
            Status__c = 'Pending',
            Source_Tier__c = 'Tier4_Agentic',
            Composite_Key__c = 'kA0xx0000000001|kA0xx0000000002'
        ));

        candidates.add(new Duplicate_Candidate__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_1__c = 'kA0xx0000000001',
            Knowledge_Article_2__c = 'kA0xx0000000003',
            Article_1_Title__c = 'Article A',
            Article_2_Title__c = 'Article C',
            Confidence_Score__c = 70,
            Flag_Type__c = 'Contradiction',
            Status__c = 'Pending',
            Source_Tier__c = 'Tier4_Agentic',
            Composite_Key__c = 'kA0xx0000000001|kA0xx0000000003'
        ));

        candidates.add(new Duplicate_Candidate__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_1__c = 'kA0xx0000000004',
            Knowledge_Article_2__c = 'kA0xx0000000005',
            Article_1_Title__c = 'Article D',
            Article_2_Title__c = 'Article E',
            Confidence_Score__c = 60,
            Flag_Type__c = 'Duplicate',
            Status__c = 'Rejected',
            Source_Tier__c = 'Tier1_ExactMatch',
            Composite_Key__c = 'kA0xx0000000004|kA0xx0000000005'
        ));

        insert candidates;
    }

    @IsTest
    static void testGetDuplicationScore_withCandidate() {
        Decimal score = KBPipelineBridgeService.getDuplicationScore('kA0xx0000000001');
        System.assertEquals(15, score, 'Score should be 100 - 85 = 15');
    }

    @IsTest
    static void testGetDuplicationScore_noCandidate() {
        Decimal score = KBPipelineBridgeService.getDuplicationScore('kA0xx0000000999');
        System.assertEquals(100, score, 'No candidates means score 100');
    }

    @IsTest
    static void testGetDuplicationScore_rejectedExcluded() {
        Decimal score = KBPipelineBridgeService.getDuplicationScore('kA0xx0000000004');
        System.assertEquals(100, score, 'Rejected candidates should be excluded');
    }

    @IsTest
    static void testGetDuplicationScore_blankId() {
        System.assertEquals(100, KBPipelineBridgeService.getDuplicationScore(null));
        System.assertEquals(100, KBPipelineBridgeService.getDuplicationScore(''));
    }

    @IsTest
    static void testGetConflictScore_withCandidate() {
        Decimal score = KBPipelineBridgeService.getConflictScore('kA0xx0000000001');
        System.assertEquals(30, score, 'Score should be 100 - 70 = 30');
    }

    @IsTest
    static void testGetConflictScore_noCandidate() {
        Decimal score = KBPipelineBridgeService.getConflictScore('kA0xx0000000999');
        System.assertEquals(100, score);
    }

    @IsTest
    static void testGetBatchDuplicationScores() {
        List<String> ids = new List<String>{'kA0xx0000000001', 'kA0xx0000000002', 'kA0xx0000000999'};
        Map<String, Decimal> scores = KBPipelineBridgeService.getBatchDuplicationScores(ids);

        System.assertEquals(3, scores.size());
        System.assertEquals(15, scores.get('kA0xx0000000001'));
        System.assertEquals(15, scores.get('kA0xx0000000002'));
        System.assertEquals(100, scores.get('kA0xx0000000999'));
    }

    @IsTest
    static void testGetBatchConflictScores() {
        List<String> ids = new List<String>{'kA0xx0000000001', 'kA0xx0000000003'};
        Map<String, Decimal> scores = KBPipelineBridgeService.getBatchConflictScores(ids);

        System.assertEquals(30, scores.get('kA0xx0000000001'));
        System.assertEquals(30, scores.get('kA0xx0000000003'));
    }

    @IsTest
    static void testGetBatchScores_emptyList() {
        Map<String, Decimal> scores = KBPipelineBridgeService.getBatchDuplicationScores(new List<String>());
        System.assert(scores.isEmpty());
    }

    @IsTest
    static void testGetCandidatesForArticle() {
        List<Duplicate_Candidate__c> candidates = KBPipelineBridgeService.getCandidatesForArticle('kA0xx0000000001');
        System.assertEquals(2, candidates.size());
    }

    @IsTest
    static void testGetCandidatesForArticle_blank() {
        List<Duplicate_Candidate__c> candidates = KBPipelineBridgeService.getCandidatesForArticle(null);
        System.assert(candidates.isEmpty());
    }
}
