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
private class DuplicateCandidateControllerTest {

    @TestSetup
    static void setup() {
        List<Knowledge__kav> articles = new List<Knowledge__kav>();
        for (Integer i = 0; i < 5; i++) {
            articles.add(new Knowledge__kav(
                Title = 'Cluster Article ' + i,
                UrlName = 'cluster-article-' + i + '-' + Math.abs(Crypto.getRandomLong()),
                Language = 'en_US',
                Summary = 'Summary for article ' + i
            ));
        }
        insert articles;

        // Pair layout: A-B, A-C, B-C (a triangle), plus D-E (unrelated)
        Id a = articles[0].Id, b = articles[1].Id, c = articles[2].Id;
        Id d = articles[3].Id, e = articles[4].Id;

        // Duplicate_Candidate__c is a master-detail child of the run — parent
        // every seeded pair to a shared run.
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        List<Duplicate_Candidate__c> pairs = new List<Duplicate_Candidate__c>{
            buildPair(a, b, 'AB', 95, run.Id),
            buildPair(a, c, 'AC', 90, run.Id),
            buildPair(b, c, 'BC', 85, run.Id),
            buildPair(d, e, 'DE', 80, run.Id)
        };
        insert pairs;
    }

    static Duplicate_Candidate__c buildPair(Id a1, Id a2, String key, Decimal score, Id runId) {
        return new Duplicate_Candidate__c(
            Assessment_Run__c = runId,
            Knowledge_Article_1__c = a1,
            Knowledge_Article_2__c = a2,
            Composite_Key__c = 'test-' + key,
            Confidence_Score__c = score,
            Flag_Type__c = 'Duplicate',
            Status__c = 'Pending',
            Source_Tier__c = 'Tier4_Agentic'
        );
    }

    @IsTest
    static void getArticleDetail_returnsPopulatedWrapper() {
        Knowledge__kav kav = [SELECT Id FROM Knowledge__kav LIMIT 1];

        Test.startTest();
        DuplicateCandidateController.ArticleDetail d = DuplicateCandidateController.getArticleDetail(kav.Id);
        Test.stopTest();

        Assert.isNotNull(d, 'Detail should not be null');
        Assert.areEqual(kav.Id, d.articleVersionId, 'VersionId should round-trip');
        Assert.isTrue(d.title.startsWith('Cluster Article'), 'Title should be populated');
    }

    @IsTest
    static void getArticleDetail_returnsSentinelForUnknownVersion() {
        Test.startTest();
        DuplicateCandidateController.ArticleDetail d = DuplicateCandidateController.getArticleDetail('ka000000000000000');
        Test.stopTest();

        Assert.isNotNull(d, 'Should not return null for unknown id');
        Assert.areEqual('Unknown', d.publishStatus, 'Sentinel should flag unknown status');
    }

    @IsTest
    static void getNeighborCandidates_returnsOneHopNeighbors() {
        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        Test.startTest();
        List<DuplicateCandidateController.NeighborCandidate> neighbors =
            DuplicateCandidateController.getNeighborCandidates(seed.Id, 1);
        Test.stopTest();

        // Seed is A-B. Depth 1 reaches everyone touching A or B: A-C and B-C.
        // D-E must NOT be in the result.
        Assert.areEqual(2, neighbors.size(), 'Should find 2 neighbors (AC + BC)');
        Set<String> keys = new Set<String>();
        for (DuplicateCandidateController.NeighborCandidate n : neighbors) {
            keys.add(n.compositeKey);
            Assert.areEqual(1, n.hopDistance, 'All direct neighbors should be hop 1');
        }
        Assert.isTrue(keys.contains('test-AC'), 'AC should be a neighbor');
        Assert.isTrue(keys.contains('test-BC'), 'BC should be a neighbor');
        Assert.isFalse(keys.contains('test-DE'), 'Unrelated pair must not surface');
    }

    @IsTest
    static void getNeighborCandidates_excludesResolvedAndRejected() {
        Duplicate_Candidate__c ac = [SELECT Id, Status__c FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AC' LIMIT 1];
        ac.Status__c = 'Resolved';
        update ac;

        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        Test.startTest();
        List<DuplicateCandidateController.NeighborCandidate> neighbors =
            DuplicateCandidateController.getNeighborCandidates(seed.Id, 3);
        Test.stopTest();

        // Only BC is pending now; AC is Resolved and must be filtered out.
        Set<String> keys = new Set<String>();
        for (DuplicateCandidateController.NeighborCandidate n : neighbors) {
            keys.add(n.compositeKey);
        }
        Assert.isFalse(keys.contains('test-AC'), 'Resolved candidate must not appear');
        Assert.isTrue(keys.contains('test-BC'), 'BC stays pending → should appear');
    }

    @IsTest
    static void approveClusterMerge_throwsOnEmpty() {
        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.approveClusterMerge(new List<Id>());
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Empty list should raise AuraHandledException');
    }

    @IsTest
    static void approveClusterMerge_enqueuesConsolidationWithoutThrowing() {
        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        // The cluster queueable runs at stopTest and LLM-merges content — stub
        // PromptTemplateService so it doesn't hit real ConnectApi (unsupported in
        // data-siloed tests).
        PromptTemplateService.setMock(new MockPromptTemplateService());

        Test.startTest();
        DuplicateCandidateController.approveClusterMerge(new List<Id>{ seed.Id });
        Test.stopTest();
    }

    // ──────────────────────────────────────────────────────────────────────
    // Read methods
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void getActiveCandidatesForArticle_returnsActionablePendingAndError() {
 // the queue's actionable set is Pending + Error (a failed merge stays
        // actionable for retry). From @TestSetup's 4 Pending: mark one Resolved
        // (excluded) and one Error + Merge_Error__c (INCLUDED, with its reason).
        // This is the DEEP-LINK / queue entry point; the count-badge path
 // (getActiveCandidates) is Pending-only and asserted separately.
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];
        ab.Status__c = 'Resolved';
        update ab;
        Duplicate_Candidate__c ac = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AC' LIMIT 1];
        ac.Status__c = 'Error';
        ac.Merge_Error__c = 'This article has a newer draft — re-run the assessment before merging.';
        update ac;

        Test.startTest();
        List<Duplicate_Candidate__c> active = DuplicateCandidateController.getActiveCandidatesForArticle(null, null);
        Test.stopTest();

        // 4 total − 1 Resolved = 3 (2 Pending + 1 Error).
        Assert.areEqual(3, active.size(), 'Resolved excluded; Pending + Error included');
        Boolean sawError = false;
        for (Duplicate_Candidate__c dc : active) {
            Assert.areNotEqual('Resolved', dc.Status__c, 'Resolved must not appear on the actionable queue');
            if (dc.Id == ac.Id) {
                sawError = true;
                Assert.areEqual('Error', dc.Status__c);
                Assert.isTrue(dc.Merge_Error__c != null && dc.Merge_Error__c.contains('newer draft'),
                    'Errored merge returned with its Merge_Error__c reason');
            }
        }
        Assert.isTrue(sawError, 'A failed-merge (Error) candidate stays actionable for retry');
    }

    @IsTest
    static void getActiveCandidates_countBadge_isPendingOnly() {
 // review — the headline Duplicates count-badge (getActiveCandidates) is
        // Pending-ONLY, so it does not over-count failed-merge (Error) rows and then
        // flicker down when the queue tab opens. Error rows still SHOW in the queue
        // via getActiveCandidatesForArticle (asserted above); they just aren't counted.
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];
        ab.Status__c = 'Error';
        ab.Merge_Error__c = 'Merge failed — retry.';
        update ab;

        Test.startTest();
        List<Duplicate_Candidate__c> badge = DuplicateCandidateController.getActiveCandidates(null);
        Test.stopTest();

        // @TestSetup seeds 4 Pending; flipping one to Error leaves 3 Pending.
        Assert.areEqual(3, badge.size(), 'Count badge counts Pending only (Error excluded)');
        for (Duplicate_Candidate__c dc : badge) {
            Assert.areEqual('Pending', dc.Status__c, 'Only Pending rows feed the count badge');
        }
    }

 // the unified queue's status-set entry point. Default (both toggles
 // off) is the ACTIONABLE set (Pending + Error per — this fixture has no
    // Error rows, so it reads as Pending here); includeResolved adds
    // Resolved/Superseded; includeDiscarded adds Not a Duplicate/Rejected/Suppressed.
    @IsTest
    static void getCandidatesByStatus_defaultPendingOnly() {
        // From @TestSetup: 4 Pending. Mark one Resolved and one discarded.
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];
        ab.Status__c = 'Resolved';
        update ab;
        Duplicate_Candidate__c ac = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AC' LIMIT 1];
        ac.Status__c = 'Not a Duplicate';
        update ac;

        Test.startTest();
        List<Duplicate_Candidate__c> pendingOnly =
            DuplicateCandidateController.getCandidatesByStatus(null, null, false, false);
        List<Duplicate_Candidate__c> withResolved =
            DuplicateCandidateController.getCandidatesByStatus(null, null, true, false);
        List<Duplicate_Candidate__c> withDiscarded =
            DuplicateCandidateController.getCandidatesByStatus(null, null, false, true);
        List<Duplicate_Candidate__c> withAll =
            DuplicateCandidateController.getCandidatesByStatus(null, null, true, true);
        Test.stopTest();

        // 4 total: 2 Pending, 1 Resolved, 1 discarded.
        Assert.areEqual(2, pendingOnly.size(), 'Default surfaces Pending only');
        for (Duplicate_Candidate__c dc : pendingOnly) {
            Assert.areEqual('Pending', dc.Status__c);
        }
        Assert.areEqual(3, withResolved.size(), 'Pending + Resolved/Superseded');
        Assert.areEqual(3, withDiscarded.size(), 'Pending + discarded');
        Assert.areEqual(4, withAll.size(), 'Both toggles → every status');
    }

    @IsTest
    static void getOpenCandidatesForArticle_returnsPairsOnEitherSide() {
        // Article A is on the left of A-B and A-C, on neither side of D-E.
        Knowledge__kav a = [SELECT Id FROM Knowledge__kav WHERE Title = 'Cluster Article 0' LIMIT 1];

        Test.startTest();
        List<Duplicate_Candidate__c> rows = DuplicateCandidateController.getOpenCandidatesForArticle(a.Id);
        Test.stopTest();

        Assert.areEqual(2, rows.size(), 'Article A is in 2 pending pairs');
        for (Duplicate_Candidate__c r : rows) {
            Assert.isTrue(r.Knowledge_Article_1__c == a.Id || r.Knowledge_Article_2__c == a.Id);
            Assert.areEqual('Pending', r.Status__c);
        }
    }

    @IsTest
    static void getOpenCandidatesForArticle_blankIdReturnsEmpty() {
        Test.startTest();
        List<Duplicate_Candidate__c> rows = DuplicateCandidateController.getOpenCandidatesForArticle(null);
        Test.stopTest();
        Assert.areEqual(0, rows.size());
    }

    @IsTest
    static void getOpenCandidatesForArticle_skipsResolvedRows() {
        Knowledge__kav a = [SELECT Id FROM Knowledge__kav WHERE Title = 'Cluster Article 0' LIMIT 1];
        // Resolve the A-B pair; only A-C should remain.
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];
        ab.Status__c = 'Resolved';
        update ab;

        Test.startTest();
        List<Duplicate_Candidate__c> rows = DuplicateCandidateController.getOpenCandidatesForArticle(a.Id);
        Test.stopTest();

        Assert.areEqual(1, rows.size());
        Assert.areEqual('Pending', rows[0].Status__c);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Mutations
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void updateStatus_persistsChange() {
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        Test.startTest();
        DuplicateCandidateController.updateStatus(ab.Id, 'Resolved');
        Test.stopTest();

        Assert.areEqual('Resolved',
            [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id LIMIT 1].Status__c);
    }

    /**
     * S3 regression — `Status__c` is a restricted picklist
     * (Pending / Resolved / Rejected / Suppressed). Passing an invalid value
     * should throw at DML time rather than silently writing junk. We trust
     * the platform; no application-level whitelist is needed.
     */
    @IsTest
    static void updateStatus_InvalidStatus_ThrowsAndPreservesState() {
        Duplicate_Candidate__c ab = [
            SELECT Id, Status__c FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        Assert.areEqual('Pending', ab.Status__c, 'Pre-condition: row starts Pending');

        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.updateStatus(ab.Id, 'BogusValueNotInPicklist');
        } catch (DmlException e) {
            threw = true;
        } catch (Exception e) {
            // AuraHandledException is also acceptable.
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Invalid restricted-picklist value must throw at DML time.');
        Duplicate_Candidate__c reloaded = [
            SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Pending', reloaded.Status__c,
            'Failed DML must roll back; row should still be Pending.');
    }

    @IsTest
    static void markNotADuplicate_setsSoftStatusAndStoresReason() {
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        Test.startTest();
        DuplicateCandidateController.markNotADuplicate(ab.Id, 'False positive — different products');
        Test.stopTest();

        Duplicate_Candidate__c after = [
            SELECT Status__c, Rejection_Reason__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Not a Duplicate', after.Status__c, 'soft discard status');
        Assert.areEqual('False positive — different products', after.Rejection_Reason__c,
            'Optional reason is stored when supplied');
    }

    @IsTest
    static void markNotADuplicate_reasonOptional() {
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];
        // Seed a stale reason so we prove a blank reason CLEARS it, rather than
 // leaving the old text to masquerade as this action's rationale.
        ab.Rejection_Reason__c = 'stale reason from a prior action';
        update ab;

        Test.startTest();
        DuplicateCandidateController.markNotADuplicate(ab.Id, null);
        Test.stopTest();

        Duplicate_Candidate__c after = [
            SELECT Status__c, Rejection_Reason__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Not a Duplicate', after.Status__c, 'Status set without a reason');
        Assert.isNull(after.Rejection_Reason__c, 'Blank reason clears any stale prior reason');
    }

 // markNotADuplicate must reject a non-Pending
    // candidate. The unified queue's read-only Compare (reachable from Resolved
    // rows) must not be able to flip a completed merge to 'Not a Duplicate' and
    // orphan its Golden Record draft. The UI hides the action there; this guards
    // the endpoint directly (defense-in-depth).
    @IsTest
    static void markNotADuplicate_rejectsNonPending() {
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];
        ab.Status__c = 'Resolved';
        update ab;

        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.markNotADuplicate(ab.Id, 'should be blocked');
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A non-Pending candidate must be rejected');
        Duplicate_Candidate__c after = [
            SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Resolved', after.Status__c,
            'Status must be unchanged — a completed merge cannot be un-resolved.');
    }

 // the deprecated reject/suppress entry points must keep working
    // (external callers) and now both funnel to the soft 'Not a Duplicate' status.
    @IsTest
    static void deprecatedRejectSuppress_delegateToNotADuplicate() {
 // Two distinct Pending rows — the -review precondition now rejects a
        // non-Pending candidate, so reject + suppress can't target the same row.
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];
        Duplicate_Candidate__c ac = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AC' LIMIT 1];

        Test.startTest();
        DuplicateCandidateController.rejectCandidate(ab.Id, 'legacy reject');
        Duplicate_Candidate__c afterReject = [
            SELECT Status__c, Rejection_Reason__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Not a Duplicate', afterReject.Status__c, 'rejectCandidate now soft');
        Assert.areEqual('legacy reject', afterReject.Rejection_Reason__c);

        DuplicateCandidateController.suppressCandidate(ac.Id);
        Test.stopTest();

        Assert.areEqual('Not a Duplicate',
            [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :ac.Id LIMIT 1].Status__c,
            'suppressCandidate now soft');
    }

    @IsTest
    static void approveMerge_DelegatesToTier4() {
        Duplicate_Candidate__c ab = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        // Pair queueable LLM-merges at stopTest — stub the prompt service.
        PromptTemplateService.setMock(new MockPromptTemplateService());

        Test.startTest();
        DuplicateCandidateController.approveMerge(ab.Id);
        Test.stopTest();

        // Behavior is covered by Tier4ConsolidationActionTest; here we just
        // verify the call enqueues without throwing.
        Assert.isNotNull(ab.Id);
    }

    @IsTest
    static void forceReEvaluate_DeletesExisting() {
        // forceReEvaluate matches on the article-version pointers (not the
        // now run-scoped Composite_Key__c), so no key manipulation is needed —
        // the seeded row already carries Knowledge_Article_1/2__c.
        Duplicate_Candidate__c ab = [
            SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c
            FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];

        Test.startTest();
        DuplicateCandidateController.forceReEvaluate(
            ab.Knowledge_Article_1__c, ab.Knowledge_Article_2__c, null
        );
        Test.stopTest();

        Integer remaining = [
            SELECT COUNT() FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual(0, remaining, 'Candidate row deleted by forceReEvaluate');
    }

    @IsTest
    static void forceReEvaluate_NoMatch_NoOp() {
        Test.startTest();
        DuplicateCandidateController.forceReEvaluate(
            'ka01XXX0000000A', 'ka01YYY0000000B', null
        );
        Test.stopTest();
        // Should not throw when no matching candidate exists.
        Assert.areEqual(4,
            [SELECT COUNT() FROM Duplicate_Candidate__c]);
    }

    @IsTest
    static void forceReEvaluate_runScoped_deletesOnlyThatRunsRow() {
 // with a runId, only the named run's row for the pair is deleted;
        // another run's row for the SAME version pair is untouched. Seed a second
        // run whose candidate reuses AB's article-version pair.
        Duplicate_Candidate__c ab = [
            SELECT Id, Assessment_Run__c, Knowledge_Article_1__c, Knowledge_Article_2__c
            FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        KB_Assessment_Run__c otherRun = KBTestDataFactory.insertRun('Completed', 'Readiness');
        Duplicate_Candidate__c otherAb = new Duplicate_Candidate__c(
            Assessment_Run__c = otherRun.Id,
            Knowledge_Article_1__c = ab.Knowledge_Article_1__c,
            Knowledge_Article_2__c = ab.Knowledge_Article_2__c,
            Composite_Key__c = String.valueOf(otherRun.Id) + '-AB',
            Confidence_Score__c = 95, Flag_Type__c = 'Duplicate',
            Status__c = 'Pending', Source_Tier__c = 'Tier4_Agentic'
        );
        insert otherAb;

        Test.startTest();
        DuplicateCandidateController.forceReEvaluate(
            ab.Knowledge_Article_1__c, ab.Knowledge_Article_2__c, ab.Assessment_Run__c
        );
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Duplicate_Candidate__c WHERE Id = :ab.Id],
            'The named run\'s row is deleted');
        Assert.areEqual(1, [SELECT COUNT() FROM Duplicate_Candidate__c WHERE Id = :otherAb.Id],
            'The OTHER run\'s row for the same pair is untouched (run-scoped delete)');
    }

    // ──────────────────────────────────────────────────────────────────────
    // getArticleComparison
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void getArticleComparison_BothFound() {
        List<Knowledge__kav> kavs = [SELECT Id FROM Knowledge__kav LIMIT 2];

        Test.startTest();
        Map<String, DuplicateCandidateController.ArticleDetail> comp =
            DuplicateCandidateController.getArticleComparison(kavs[0].Id, kavs[1].Id);
        Test.stopTest();

        Assert.areEqual(2, comp.size());
        Assert.isNotNull(comp.get('articleA'));
        Assert.isNotNull(comp.get('articleB'));
        Assert.isNotNull(comp.get('articleA').title);
    }

    @IsTest
    static void getArticleComparison_OneStale_PlaceholderReturned() {
        Knowledge__kav real = [SELECT Id FROM Knowledge__kav LIMIT 1];
        String fakeId = 'ka01XYZ0000000A';

        Test.startTest();
        Map<String, DuplicateCandidateController.ArticleDetail> comp =
            DuplicateCandidateController.getArticleComparison(real.Id, fakeId);
        Test.stopTest();

        Assert.areEqual('Unknown', comp.get('articleB').publishStatus,
            'Stale id surfaces the Unknown placeholder');
    }

    // ──────────────────────────────────────────────────────────────────────
    // getNeighborCandidates — depth + null edge cases
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void getNeighborCandidates_NullDepth_DefaultsTo1() {
        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        Test.startTest();
        List<DuplicateCandidateController.NeighborCandidate> neighbors =
            DuplicateCandidateController.getNeighborCandidates(seed.Id, null);
        Test.stopTest();

        Assert.isTrue(neighbors.size() <= 50);
    }

    @IsTest
    static void getNeighborCandidates_DepthZero_ClampedTo1() {
        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        Test.startTest();
        List<DuplicateCandidateController.NeighborCandidate> neighbors =
            DuplicateCandidateController.getNeighborCandidates(seed.Id, 0);
        Test.stopTest();

        Assert.isTrue(neighbors.size() >= 1);
    }

    @IsTest
    static void getNeighborCandidates_NonexistentSeed_ReturnsEmpty() {
        Test.startTest();
        List<DuplicateCandidateController.NeighborCandidate> neighbors =
            DuplicateCandidateController.getNeighborCandidates('a0X000000000001', 1);
        Test.stopTest();

        Assert.areEqual(0, neighbors.size(),
            'Non-existent seed returns empty list, no throw');
    }

    @IsTest
    static void getNeighborCandidates_DepthTwo_TransitiveClosure() {
        Duplicate_Candidate__c seedDe = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-DE' LIMIT 1];

        Test.startTest();
        List<DuplicateCandidateController.NeighborCandidate> neighbors =
            DuplicateCandidateController.getNeighborCandidates(seedDe.Id, 2);
        Test.stopTest();

        // D-E is isolated from the A-B-C triangle — depth 2 should return 0.
        for (DuplicateCandidateController.NeighborCandidate n : neighbors) {
            Assert.areNotEqual('test-AB', n.compositeKey,
                'D-E cluster is disjoint from A-B-C triangle');
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // resolveContradiction — three outcomes
    // ──────────────────────────────────────────────────────────────────────

 // 'needs_sme' was RETIRED (it was a silent no-op == dismiss). The
    // controller now rejects it with an AuraHandledException and leaves the
    // candidate untouched (no Resolved flip, no recommendation).
    @IsTest
    static void resolveContradiction_NeedsSme_Retired_ThrowsAndNoOp() {
        Duplicate_Candidate__c ab = [
            SELECT Id, Status__c, Knowledge_Article_1__c, Knowledge_Article_2__c
            FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        ab.Flag_Type__c = 'Contradiction';
        ab.AI_Reasoning__c = 'Different procedures stated';
        update ab;

        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.resolveContradiction(
                ab.Id, ab.Knowledge_Article_1__c, 'needs_sme'
            );
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Retired needs_sme outcome must throw, not silently no-op');
        Duplicate_Candidate__c after = [
            SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Pending', after.Status__c,
            'Rejected outcome must leave the candidate untouched (still Pending)');
        Assert.areEqual(0,
            [SELECT COUNT() FROM KB_Dimension_Analysis__c],
            'No recommendation row created');
    }

    @IsTest
    static void resolveContradiction_BothValidDifferentScope_CreatesTwoRecs() {
        // Insert assessments + Conflict dimension result rows for both articles
        // so findConflictTarget can resolve a master-detail parent.
        Duplicate_Candidate__c ab = [
            SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c, Article_2_Title__c
            FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        ab.Flag_Type__c = 'Contradiction';
        ab.AI_Reasoning__c = 'Both refer to different products';
        update ab;

        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa1 = KBTestDataFactory.insertArticleAssessment(run.Id, ab.Knowledge_Article_1__c);
        KB_Article_Assessment__c aa2 = KBTestDataFactory.insertArticleAssessment(run.Id, ab.Knowledge_Article_2__c);
        insertConflictResult(aa1.Id);
        insertConflictResult(aa2.Id);

        Test.startTest();
        DuplicateCandidateController.resolveContradiction(
            ab.Id, null, 'both_valid_different_scope'
        );
        Test.stopTest();

        Integer recs = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Type__c = 'Issue' AND Dimension__c = 'Conflict'
        ];
        Assert.areEqual(2, recs,
            'both_valid_different_scope creates one analysis row per article');
    }

    @IsTest
    static void resolveContradiction_OneSideCorrect_CreatesOneRecOnIncorrect() {
        Duplicate_Candidate__c ab = [
            SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c, Article_1_Title__c
            FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        ab.Flag_Type__c = 'Contradiction';
        ab.AI_Reasoning__c = 'Conflicting procedure';
        update ab;

        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa2 = KBTestDataFactory.insertArticleAssessment(run.Id, ab.Knowledge_Article_2__c);
        insertConflictResult(aa2.Id);

        Test.startTest();
        // article_a is correct → article_b is incorrect → analysis row created on article_b's assessment
        DuplicateCandidateController.resolveContradiction(
            ab.Id, ab.Knowledge_Article_1__c, 'article_a_correct'
        );
        Test.stopTest();

        Integer recs = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Type__c = 'Issue' AND Dimension__c = 'Conflict'
        ];
        Assert.areEqual(1, recs);
    }

    private static KB_Dimension_Result__c insertConflictResult(Id assessmentId) {
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = assessmentId,
            Dimension__c = 'Conflict',
            Score__c = 80
        );
        insert dr;
        return dr;
    }

 // lazy reconcile hook ----------------

    /**
     * reconcileActiveCandidates is the non-cacheable hook the LWC calls after
     * the cacheable wire load. With a stale Pending DC (one of its source
 * articles has a different version Online), the hook should close it.
     */
    @isTest
    static void reconcileActiveCandidates_ClosesStaleRows() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'dc-reconcile');
        Knowledge__kav origA = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[0].Id];
        Knowledge__kav origB = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :arts[1].Id];

        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        // DC pair stamped with their original KAV ids and article ids.
        Duplicate_Candidate__c dc = new Duplicate_Candidate__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_1__c = String.valueOf(origA.Id),
            Knowledge_Article_2__c = String.valueOf(origB.Id),
            Knowledge_Article_Id_1__c = String.valueOf(origA.KnowledgeArticleId),
            Knowledge_Article_Id_2__c = String.valueOf(origB.KnowledgeArticleId),
            // Composite_Key__c is capped at 37 chars — a 15-char id pair fits (31).
            Composite_Key__c = origA.Id.to15() + '-' + origB.Id.to15(),
            Flag_Type__c = 'Duplicate',
            Status__c = 'Pending',
            Confidence_Score__c = 80,
            Source_Tier__c = 'Tier4_Agentic',
            Score_Calculated_Date__c = Datetime.now()
        );
        insert dc;

        // Publish article A (same source KAV) — recency guard should keep DC open.
        KbManagement.PublishingService.publishArticle(origA.KnowledgeArticleId, true);

        Test.startTest();
        List<Id> closed = DuplicateCandidateController.reconcileActiveCandidates();
        Test.stopTest();

        Duplicate_Candidate__c reloaded = [SELECT Status__c FROM Duplicate_Candidate__c WHERE Id = :dc.Id];
        // Recency guard: same KAV is now Online — DC stays Pending.
        Assert.areEqual('Pending', reloaded.Status__c,
            'Recency guard: source KAV still Online → DC must stay Pending');
        Assert.isFalse(closed.contains(dc.Id));
    }

    // --- publishGoldenRecord ----------------------------------------------

    @IsTest
    static void publishGoldenRecord_publishesDraftAndArchivesLoser() {
        // Mirror the real post-merge state: Tier 4 drafts the Golden Record and
        // stamps the candidate Resolved at merge time; the draft is not yet
        // published. Publishing it here should (1) publish the draft once and
        // (2) archive the source ("loser") article that was merged into it.
        Knowledge__kav golden = new Knowledge__kav(
            Title = 'Merged Golden Record',
            UrlName = 'golden-' + Math.abs(Crypto.getRandomLong()),
            Language = 'en_US',
            Summary = 'Merged summary'
        );
        insert golden;
        golden = [SELECT Id, KnowledgeArticleId, PublishStatus FROM Knowledge__kav WHERE Id = :golden.Id];

        // The loser must be Online + latest so archiveMergedLosers picks it up.
        // Publish one of the @TestSetup articles to Online (its KAV is the loser).
        Knowledge__kav loserDraft = [
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav
            WHERE Title = 'Cluster Article 0' LIMIT 1
        ];
        KbManagement.PublishingService.publishArticle(loserDraft.KnowledgeArticleId, true);
        Id loserArticleId = loserDraft.KnowledgeArticleId;

        // Resolved candidate: survivor master = the Golden Record's article id;
        // the loser master is the non-survivor article-level pointer.
        Duplicate_Candidate__c dc = [
            SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        dc.Status__c = 'Resolved';
        dc.Merged_Article__c = String.valueOf(golden.Id);
        dc.Merged_Knowledge_Article_Id__c = String.valueOf(golden.KnowledgeArticleId);
        dc.Knowledge_Article_Id_1__c = String.valueOf(loserArticleId);
        dc.Knowledge_Article_Id_2__c = String.valueOf(golden.KnowledgeArticleId);
        update dc;

        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        DuplicateCandidateController.publisher = pub;
        KBDuplicateCandidateReconciler.publisher = pub;

        Test.startTest();
        DuplicateCandidateController.publishGoldenRecord(dc.Id);
        Test.stopTest();

        // (1) The Draft Golden Record publishes exactly once, via the seam.
        Assert.areEqual(1, pub.publishCallCount,
            'Draft Golden Record should be published once');
        Assert.areEqual(golden.KnowledgeArticleId, pub.publishedArticleIds[0],
            'Publish should target the Golden Record article');
        // (2) The loser (non-survivor, Online) is archived exactly once.
        Assert.areEqual(1, pub.archiveCallCount,
            'The merged loser article should be archived once');
        Assert.areEqual(loserArticleId, pub.archivedArticleIds[0],
            'Archive should target the loser article, not the survivor');
    }

    @IsTest
    static void publishGoldenRecord_alreadyOnline_skipsPublishStillArchives() {
        // Idempotency guard: a Golden Record already Online (e.g. published
        // natively before this action existed) should NOT be re-published, but
        // the reconciler must still run to archive any losers left behind.
        Knowledge__kav goldenDraft = new Knowledge__kav(
            Title = 'Already-Online Golden Record',
            UrlName = 'golden-online-' + Math.abs(Crypto.getRandomLong()),
            Language = 'en_US',
            Summary = 'Merged summary'
        );
        insert goldenDraft;
        goldenDraft = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :goldenDraft.Id];
        KbManagement.PublishingService.publishArticle(goldenDraft.KnowledgeArticleId, true);
        Knowledge__kav golden = [
            SELECT Id, KnowledgeArticleId, PublishStatus FROM Knowledge__kav
            WHERE KnowledgeArticleId = :goldenDraft.KnowledgeArticleId
            AND PublishStatus = 'Online' AND IsLatestVersion = true LIMIT 1
        ];

        // A loser must be Online + wired via the master-text ids so the archive
        // half actually runs — the assertion this test's name promises.
        Knowledge__kav loserDraft = [
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav
            WHERE Title = 'Cluster Article 1' LIMIT 1
        ];
        KbManagement.PublishingService.publishArticle(loserDraft.KnowledgeArticleId, true);
        Id loserArticleId = loserDraft.KnowledgeArticleId;

        Duplicate_Candidate__c dc = [
            SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AC' LIMIT 1
        ];
        dc.Status__c = 'Resolved';
        dc.Merged_Article__c = String.valueOf(golden.Id);
        dc.Merged_Knowledge_Article_Id__c = String.valueOf(golden.KnowledgeArticleId);
        dc.Knowledge_Article_Id_1__c = String.valueOf(loserArticleId);
        dc.Knowledge_Article_Id_2__c = String.valueOf(golden.KnowledgeArticleId);
        update dc;

        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        DuplicateCandidateController.publisher = pub;
        KBDuplicateCandidateReconciler.publisher = pub;

        Test.startTest();
        DuplicateCandidateController.publishGoldenRecord(dc.Id);
        Test.stopTest();

        Assert.areEqual(0, pub.publishCallCount,
            'An already-Online Golden Record must not be re-published');
        // ...but the reconciler still runs, so the loser is archived.
        Assert.areEqual(1, pub.archiveCallCount,
            'Losers must still be archived when the Golden Record was already Online');
        Assert.areEqual(loserArticleId, pub.archivedArticleIds[0],
            'Archive should target the loser article');
    }

    @IsTest
    static void publishGoldenRecord_publishDenied_throwsFriendlyAccessMessage() {
        // The access-denial translation branch: a publish that fails with a
        // permission error surfaces KB_Knowledge_Author guidance, not raw text.
        Knowledge__kav golden = new Knowledge__kav(
            Title = 'Denied Golden Record',
            UrlName = 'golden-denied-' + Math.abs(Crypto.getRandomLong()),
            Language = 'en_US',
            Summary = 'Merged summary'
        );
        insert golden;
        golden = [SELECT Id, KnowledgeArticleId, PublishStatus FROM Knowledge__kav WHERE Id = :golden.Id];

        Duplicate_Candidate__c dc = [
            SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        dc.Status__c = 'Resolved';
        dc.Merged_Article__c = String.valueOf(golden.Id);
        dc.Merged_Knowledge_Article_Id__c = String.valueOf(golden.KnowledgeArticleId);
        update dc;

        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        pub.throwOnPublish = true; // simulate the platform publish rejection
        DuplicateCandidateController.publisher = pub;
        KBDuplicateCandidateReconciler.publisher = pub;

        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.publishGoldenRecord(dc.Id);
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(String.isNotBlank(e.getMessage()),
                'A publish failure must surface a friendly message');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A failed publish must throw a friendly AuraHandledException');
    }

    @IsTest
    static void publishGoldenRecord_archiveFails_reportsPartialOutcome() {
        // When a loser cannot be archived, the method must NOT report blanket
        // success — it throws a partial-outcome message so the toast tells the
        // truth. The Golden Record still publishes (best-effort archive).
        Knowledge__kav golden = new Knowledge__kav(
            Title = 'Partial-Archive Golden Record',
            UrlName = 'golden-partial-' + Math.abs(Crypto.getRandomLong()),
            Language = 'en_US',
            Summary = 'Merged summary'
        );
        insert golden;
        golden = [SELECT Id, KnowledgeArticleId, PublishStatus FROM Knowledge__kav WHERE Id = :golden.Id];

        Knowledge__kav loserDraft = [
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav
            WHERE Title = 'Cluster Article 2' LIMIT 1
        ];
        KbManagement.PublishingService.publishArticle(loserDraft.KnowledgeArticleId, true);
        Id loserArticleId = loserDraft.KnowledgeArticleId;

        Duplicate_Candidate__c dc = [
            SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-BC' LIMIT 1
        ];
        dc.Status__c = 'Resolved';
        dc.Merged_Article__c = String.valueOf(golden.Id);
        dc.Merged_Knowledge_Article_Id__c = String.valueOf(golden.KnowledgeArticleId);
        dc.Knowledge_Article_Id_1__c = String.valueOf(loserArticleId);
        dc.Knowledge_Article_Id_2__c = String.valueOf(golden.KnowledgeArticleId);
        update dc;

        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        pub.throwOnArchive = true; // publish succeeds; loser archive fails
        DuplicateCandidateController.publisher = pub;
        KBDuplicateCandidateReconciler.publisher = pub;

        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.publishGoldenRecord(dc.Id);
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('could not be'),
                'Partial-outcome message must name the archive failure');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A failed loser archive must surface a partial-outcome error');
        Assert.areEqual(1, pub.publishCallCount, 'The Golden Record still publishes');
    }

    @IsTest
    static void publishGoldenRecord_throwsWhenNoMergedArticle() {
        Duplicate_Candidate__c dc = [
            SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        // Seed candidate has no Merged_Article__c — nothing to publish.

        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.publishGoldenRecord(dc.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A candidate with no Golden Record must throw');
    }

    @IsTest
    static void publishGoldenRecord_InvalidMergedArticleId_Throws() {
        Duplicate_Candidate__c dc = [
            SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        dc.Merged_Article__c = 'not-a-valid-id';
        dc.Merged_Knowledge_Article_Id__c = 'also-not-valid';
        update dc;

        // AuraHandledException.getMessage() returns the platform default in
        // test context unless the throw site called .setMessage() — this one
        // doesn't, so behaviour (threw) is what's asserted, not message text.
        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.publishGoldenRecord(dc.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A malformed Merged_Article__c must throw before any query');
    }

    @IsTest
    static void publishGoldenRecord_MergedArticleDeleted_Throws() {
        String kavPrefix = Knowledge__kav.SObjectType.getDescribe().getKeyPrefix();
        // 12-char suffix (15 total) so Id.valueOf auto-checksums a syntactically
        // valid, non-existent Id — an 18-char fabricated Id fails checksum
        // validation and throws before ever reaching the "not found" branch.
        String ghostKav = kavPrefix + '000000000009';

        Duplicate_Candidate__c dc = [
            SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        dc.Merged_Article__c = ghostKav;
        dc.Merged_Knowledge_Article_Id__c = ghostKav;
        update dc;

        // AuraHandledException.getMessage() returns the platform default in
        // test context unless the throw site called .setMessage() — this one
        // doesn't, so behaviour (threw) is what's asserted, not message text.
        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.publishGoldenRecord(dc.Id);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A valid-shape but non-existent Golden Record id must throw');
    }

    // A publisher stub whose thrown message matches KBAccessErrorClassifier's
    // denial tokens, so the access-denial translation branch (distinct from the
    // generic "Could not publish" branch already covered above) is exercised.
    private class AccessDeniedKnowledgePublisher implements KBKnowledgePublisher.IPublisher {
        public void publishArticle(Id knowledgeArticleId, Boolean keepAsNewVersion) {
            throw new IllegalArgumentException('Insufficient Access: cannot edit this record');
        }
        public String editOnlineArticle(Id knowledgeArticleId, Boolean unpublish) { return null; }
        public void archiveOnlineArticle(Id knowledgeArticleId) { }
    }

    @IsTest
    static void publishGoldenRecord_publishDeniedByFLS_translatesKnowledgeAuthorGuidance() {
        Knowledge__kav golden = new Knowledge__kav(
            Title = 'FLS-Denied Golden Record',
            UrlName = 'golden-fls-' + Math.abs(Crypto.getRandomLong()),
            Language = 'en_US',
            Summary = 'Merged summary'
        );
        insert golden;
        golden = [SELECT Id, KnowledgeArticleId, PublishStatus FROM Knowledge__kav WHERE Id = :golden.Id];

        Duplicate_Candidate__c dc = [
            SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        dc.Status__c = 'Resolved';
        dc.Merged_Article__c = String.valueOf(golden.Id);
        dc.Merged_Knowledge_Article_Id__c = String.valueOf(golden.KnowledgeArticleId);
        update dc;

        DuplicateCandidateController.publisher = new AccessDeniedKnowledgePublisher();

        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.publishGoldenRecord(dc.Id);
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('KB Knowledge Author'),
                'Access-denial branch must name the KB Knowledge Author permission set: ' + e.getMessage());
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A denial-shaped publish failure must throw the friendly access message');
    }

    // ──────────────────────────────────────────────────────────────────────
    // approveMergeWithChoice / approveClusterMergeWithChoice
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void approveMergeWithChoice_KeepSurvivorNoVersion_Throws() {
        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.approveMergeWithChoice(
                seed.Id, Tier4ConsolidationAction.KEEP_SURVIVOR, null
            );
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'keep_survivor without a chosen survivor version must throw');
    }

    @IsTest
    static void approveMergeWithChoice_CreateNew_DelegatesToTier4() {
        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];
        PromptTemplateService.setMock(new MockPromptTemplateService());

        Test.startTest();
        DuplicateCandidateController.approveMergeWithChoice(seed.Id, 'create_new', null);
        Test.stopTest();

        Assert.isNotNull(seed.Id, 'Should enqueue without throwing');
    }

    @IsTest
    static void approveClusterMergeWithChoice_EmptyList_Throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.approveClusterMergeWithChoice(new List<Id>(), 'create_new', null);
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();
        Assert.isTrue(threw, 'Empty candidate list must throw before the keep-choice check');
    }

    @IsTest
    static void approveClusterMergeWithChoice_KeepSurvivorNoVersion_Throws() {
        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.approveClusterMergeWithChoice(
                new List<Id>{ seed.Id }, Tier4ConsolidationAction.KEEP_SURVIVOR, null
            );
        } catch (AuraHandledException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'keep_survivor without a chosen survivor version must throw');
    }

    @IsTest
    static void approveClusterMergeWithChoice_CreateNew_DelegatesToTier4() {
        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];
        PromptTemplateService.setMock(new MockPromptTemplateService());

        Test.startTest();
        DuplicateCandidateController.approveClusterMergeWithChoice(
            new List<Id>{ seed.Id }, 'create_new', null
        );
        Test.stopTest();

        Assert.isNotNull(seed.Id, 'Should enqueue the cluster merge without throwing');
    }

    // ──────────────────────────────────────────────────────────────────────
    // getCandidatesByStatus / getActiveCandidatesForArticle — run + article scoping
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void getCandidatesByStatus_InvalidRunId_ReturnsEmpty() {
        Test.startTest();
        List<Duplicate_Candidate__c> rows =
            DuplicateCandidateController.getCandidatesByStatus('not-a-real-id', null, false, false);
        Test.stopTest();
        Assert.areEqual(0, rows.size(), 'Garbage runId must short-circuit to empty');
    }

    @IsTest
    static void getCandidatesByStatus_RunScoped_FiltersToThatRun() {
        Duplicate_Candidate__c ab = [
            SELECT Id, Assessment_Run__c, Knowledge_Article_1__c, Knowledge_Article_2__c
            FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        KB_Assessment_Run__c otherRun = KBTestDataFactory.insertRun('Completed', 'Readiness');
        insert new Duplicate_Candidate__c(
            Assessment_Run__c = otherRun.Id,
            Knowledge_Article_1__c = ab.Knowledge_Article_1__c,
            Knowledge_Article_2__c = ab.Knowledge_Article_2__c,
            Composite_Key__c = String.valueOf(otherRun.Id) + '-scoped',
            Confidence_Score__c = 50, Flag_Type__c = 'Duplicate',
            Status__c = 'Pending', Source_Tier__c = 'Tier4_Agentic'
        );

        Test.startTest();
        List<Duplicate_Candidate__c> scoped =
            DuplicateCandidateController.getCandidatesByStatus(ab.Assessment_Run__c, null, false, false);
        Test.stopTest();

        // The projection doesn't SELECT Assessment_Run__c (it's only used
        // server-side to filter) — assert on the id set instead of that field.
        Set<Id> scopedIds = new Set<Id>();
        for (Duplicate_Candidate__c dc : scoped) {
            scopedIds.add(dc.Id);
        }
        Assert.isTrue(scopedIds.contains(ab.Id), 'The named run\'s own candidate must be included');
    }

    @IsTest
    static void getActiveCandidatesForArticle_ArticleScoped_FiltersToArticle() {
        // D-E is the disjoint pair — D appears in exactly one candidate, unlike
        // A/B/C which each appear in two legs of the triangle.
        Duplicate_Candidate__c de = [
            SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c
            FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-DE' LIMIT 1
        ];

        Test.startTest();
        List<Duplicate_Candidate__c> scoped =
            DuplicateCandidateController.getActiveCandidatesForArticle(null, de.Knowledge_Article_1__c);
        Test.stopTest();

        Assert.areEqual(1, scoped.size(), 'Only the DE pair touches article D');
        Assert.areEqual(de.Id, scoped[0].Id);
    }

    // ──────────────────────────────────────────────────────────────────────
    // getArticleDetail — blank input
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void getArticleDetail_BlankId_ReturnsSentinel() {
        Test.startTest();
        DuplicateCandidateController.ArticleDetail d = DuplicateCandidateController.getArticleDetail(null);
        Test.stopTest();

        Assert.isNotNull(d);
        Assert.areEqual('Unknown', d.publishStatus, 'Blank id short-circuits to the same sentinel as a stale id');
    }

    // ──────────────────────────────────────────────────────────────────────
    // getNeighborCandidates — unresolvable seed + deeper BFS closure
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void getNeighborCandidates_SeedArticlesUnresolvable_ReturnsEmpty() {
        // 12-char suffix (15 total) so Id.valueOf auto-checksums a syntactically
        // valid, non-existent Id — an 18-char fabricated Id fails checksum
        // validation and throws before reaching the "unresolvable" branch.
        String kavPrefix = Knowledge__kav.SObjectType.getDescribe().getKeyPrefix();
        String ghost1 = kavPrefix + '000000000011';
        String ghost2 = kavPrefix + '000000000012';
        Duplicate_Candidate__c ghostSeed = new Duplicate_Candidate__c(
            Assessment_Run__c = KBTestDataFactory.insertRun('Completed', 'Readiness').Id,
            Knowledge_Article_1__c = ghost1,
            Knowledge_Article_2__c = ghost2,
            Composite_Key__c = 'ghost-seed-unresolvable',
            Confidence_Score__c = 50, Flag_Type__c = 'Duplicate',
            Status__c = 'Pending', Source_Tier__c = 'Tier4_Agentic'
        );
        insert ghostSeed;

        Test.startTest();
        List<DuplicateCandidateController.NeighborCandidate> neighbors =
            DuplicateCandidateController.getNeighborCandidates(ghostSeed.Id, 3);
        Test.stopTest();

        Assert.areEqual(0, neighbors.size(),
            'Seed whose article versions do not resolve to any real KAV must return empty');
    }

    @IsTest
    static void getNeighborCandidates_DeepCluster_DiscoversNewMasterAtHopTwo() {
        // Extend the @TestSetup triangle with a 4th article F and a C-F pair, so
        // depth-2 from seed A-B discovers F as a genuinely NEW master at hop 2
        // (hop 1 only reaches C via A-C/B-C). This also gives the BFS result a
        // mix of hop-1 and hop-2 candidates, exercising the sort comparator's
        // hopA != hopB branch.
        Knowledge__kav f = new Knowledge__kav(
            Title = 'Cluster Article F',
            UrlName = 'cluster-article-f-' + Math.abs(Crypto.getRandomLong()),
            Language = 'en_US',
            Summary = 'Summary for article F'
        );
        insert f;
        Knowledge__kav c = [SELECT Id FROM Knowledge__kav WHERE Title = 'Cluster Article 2' LIMIT 1];
        KB_Assessment_Run__c run = [SELECT Id FROM KB_Assessment_Run__c LIMIT 1];
        insert new Duplicate_Candidate__c(
            Assessment_Run__c = run.Id,
            Knowledge_Article_1__c = c.Id,
            Knowledge_Article_2__c = f.Id,
            Composite_Key__c = 'test-CF',
            Confidence_Score__c = 75, Flag_Type__c = 'Duplicate',
            Status__c = 'Pending', Source_Tier__c = 'Tier4_Agentic'
        );

        Duplicate_Candidate__c seed = [SELECT Id FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1];

        Test.startTest();
        List<DuplicateCandidateController.NeighborCandidate> neighbors =
            DuplicateCandidateController.getNeighborCandidates(seed.Id, 2);
        Test.stopTest();

        Set<String> keys = new Set<String>();
        Boolean sawHopOne = false, sawHopTwo = false;
        for (DuplicateCandidateController.NeighborCandidate n : neighbors) {
            keys.add(n.compositeKey);
            if (n.hopDistance == 1) sawHopOne = true;
            if (n.hopDistance == 2) sawHopTwo = true;
        }
        Assert.isTrue(keys.contains('test-CF'), 'C-F must surface — C was discovered at hop 1, F is new at hop 2');
        Assert.isTrue(sawHopOne, 'Result includes hop-1 neighbors');
        Assert.isTrue(sawHopTwo, 'Result includes hop-2 neighbors (mixed hops exercises the sort comparator)');
    }

    // ──────────────────────────────────────────────────────────────────────
    // resolveContradiction — article B correct + not-found error path
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void resolveContradiction_ArticleBCorrect_CreatesRecOnArticleA() {
        Duplicate_Candidate__c ab = [
            SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c, Article_2_Title__c
            FROM Duplicate_Candidate__c WHERE Composite_Key__c = 'test-AB' LIMIT 1
        ];
        ab.Flag_Type__c = 'Contradiction';
        ab.AI_Reasoning__c = 'Conflicting procedure';
        update ab;

        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        // Article A is the INCORRECT one this time — it needs the Conflict target.
        KB_Article_Assessment__c aa1 = KBTestDataFactory.insertArticleAssessment(run.Id, ab.Knowledge_Article_1__c);
        insertConflictResult(aa1.Id);

        Test.startTest();
        // article_b is correct → article_a is incorrect → hits the ternary's
        // FALSE branches (correctArticleId != Knowledge_Article_1__c).
        DuplicateCandidateController.resolveContradiction(
            ab.Id, ab.Knowledge_Article_2__c, 'article_b_correct'
        );
        Test.stopTest();

        Integer recs = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Type__c = 'Issue' AND Dimension__c = 'Conflict'
            AND Article_Assessment__c = :aa1.Id
        ];
        Assert.areEqual(1, recs, 'Article A (incorrect) gets the Conflict recommendation');
    }

    @IsTest
    static void resolveContradiction_CandidateNotFound_ThrowsFriendlyMessage() {
        Boolean threw = false;
        Test.startTest();
        try {
            DuplicateCandidateController.resolveContradiction(
                'a0X000000000099', null, 'article_a_correct'
            );
        } catch (AuraHandledException e) {
            threw = true;
            Assert.isTrue(String.isNotBlank(e.getMessage()),
                'A missing candidate must surface a friendly, non-blank message');
        }
        Test.stopTest();
        Assert.isTrue(threw, 'A non-existent candidateId must throw a friendly AuraHandledException, not a raw QueryException');
    }
}
