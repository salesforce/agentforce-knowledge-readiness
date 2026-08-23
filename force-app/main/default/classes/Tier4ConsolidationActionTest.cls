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
 * Coverage for Tier4ConsolidationAction — covers both inner queueables:
 * ConsolidationQueueable: single-candidate user-approved merge (
 *     no confidence band gate; an approved merge always drafts + resolves)
 *   - ClusterConsolidationQueueable: BFS-style implied-closure expansion
 *     across master KnowledgeArticleId, latest-version selection, draft
 *     creation, candidate resolution batch.
 *
 * StubPromptService (extends PromptTemplateService) intercepts both
 * draftMergedArticle and draftMergedCluster so no Einstein round-trip
 * happens. Tests use real Knowledge__kav + Duplicate_Candidate__c rows
 * so the bulkified SOQL paths execute as in production.
 */
@IsTest
private class Tier4ConsolidationActionTest {

    @TestSetup
    static void setup() {
        List<Knowledge__kav> articles = new List<Knowledge__kav>();
        for (Integer i = 0; i < 5; i++) {
            articles.add(new Knowledge__kav(
                Title = 'Cluster Seed ' + i,
                UrlName = 'cluster-seed-' + i + '-' + Math.abs(Crypto.getRandomLong()),
                Language = 'en_US',
                Summary = 'Body for article ' + i
            ));
        }
        insert articles;

        Id a = articles[0].Id, b = articles[1].Id, c = articles[2].Id;
        Id d = articles[3].Id, e = articles[4].Id;

        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');

        List<Duplicate_Candidate__c> pairs = new List<Duplicate_Candidate__c>{
            buildPair(run.Id, a, b, 'AB', 95, 'Tier4_Agentic'),
            buildPair(run.Id, a, c, 'AC', 90, 'Tier4_Agentic'),
            buildPair(run.Id, b, c, 'BC', 85, 'Tier4_Agentic'),
            buildPair(run.Id, d, e, 'DE', 80, 'Tier4_Agentic'),
            buildPair(run.Id, a, b, 'AB-low', 30, 'Tier4_Agentic'), // log-only band
            buildPair(run.Id, a, c, 'AC-mid', 60, 'Tier4_Agentic') // manual-review band
        };
        insert pairs;
    }

    static Duplicate_Candidate__c buildPair(Id runId, Id a1, Id a2, String key, Decimal score, String tier) {
        return new Duplicate_Candidate__c(
            Assessment_Run__c = runId,
            Knowledge_Article_1__c = a1,
            Knowledge_Article_2__c = a2,
            Composite_Key__c = 't5-' + key,
            Confidence_Score__c = score,
            Flag_Type__c = 'Duplicate',
            Status__c = 'Pending',
            Source_Tier__c = tier
        );
    }

 // Tier 4 now merges via the shared consolidateArticles call (findings-
    // aware), so the stubs override THAT (the old draftMerged* overrides are no
    // longer reached by Tier 4). The stub echoes a merged field map so the
    // queueable produces a non-empty Golden Record / survivor draft.
    public class StubPromptService extends PromptTemplateService {
 // capture the last consolidate inputs so tests can assert the
        // articles' issues/strengths were threaded into the merge prompt.
        // Instance field (Apex forbids static on inner-class members); the test
        // reads it back via the registered mock instance after stopTest.
        public List<PromptTemplateService.ArticleInput> lastArticles;
        public override PromptTemplateService.FixArticleResult consolidateArticles(
            List<PromptTemplateService.ArticleInput> articles,
            Map<String, Integer> fieldLimits, String language
        ) {
            lastArticles = articles;
            PromptTemplateService.FixArticleResult r = new PromptTemplateService.FixArticleResult();
            r.rewrittenFields = (articles != null && !articles.isEmpty() && articles[0].fields != null)
                ? articles[0].fields.clone() : new Map<String, String>();
            if (r.rewrittenFields.isEmpty()) r.rewrittenFields.put('Summary', 'MERGED');
            r.changesSummary = 'Stub consolidate';
            return r;
        }
    }

    public class ThrowingPromptService extends PromptTemplateService {
        public override PromptTemplateService.FixArticleResult consolidateArticles(
            List<PromptTemplateService.ArticleInput> articles,
            Map<String, Integer> fieldLimits, String language
        ) {
            throw new KnowledgeAIException('Stub cluster merge failure');
        }
    }

    private static Duplicate_Candidate__c byKey(String key) {
        return [SELECT Id, Status__c, Merged_Article__c, Merged_Article_Version__c, Confidence_Score__c
                FROM Duplicate_Candidate__c WHERE Composite_Key__c = :key LIMIT 1];
    }

    // ──────────────────────────────────────────────────────────────────────
    // consolidate (Invocable) — enqueues the single-candidate queueable
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testConsolidate_Invocable_EnqueuesQueueable() {
        PromptTemplateService.setMock(new StubPromptService());
        Duplicate_Candidate__c ab = byKey('t5-AB');

        Test.startTest();
        Tier4ConsolidationAction.consolidate(new List<Id>{ ab.Id });
        Test.stopTest();

        // After Test.stopTest the queueable runs; high-confidence pair gets Resolved + drafted.
        Duplicate_Candidate__c after = byKey('t5-AB');
        Assert.areEqual('Resolved', after.Status__c);
        Assert.isNotNull(after.Merged_Article__c, 'Auto-merge band → merged draft attached');
    }

    // ──────────────────────────────────────────────────────────────────────
    // ConsolidationQueueable — score band routing
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testConsolidationQueueable_AutoMergeBand_DraftsAndResolves() {
        PromptTemplateService.setMock(new StubPromptService());
        Duplicate_Candidate__c ab = byKey('t5-AB');

        Tier4ConsolidationAction.ConsolidationQueueable q =
            new Tier4ConsolidationAction.ConsolidationQueueable(new List<Id>{ ab.Id });

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Duplicate_Candidate__c after = byKey('t5-AB');
        Assert.areEqual('Resolved', after.Status__c);
        Assert.isNotNull(after.Merged_Article__c);
 // the native-related-list lookup is stamped to the same Golden
        // Record version id as the Text field (drives the merge-lineage related
        // list on the Knowledge record page).
        Assert.areEqual(after.Merged_Article__c, String.valueOf(after.Merged_Article_Version__c),
            'Merged_Article_Version__c lookup mirrors the Merged_Article__c version id');

        // Draft Knowledge__kav exists with Merged: prefix.
        Integer drafts = [SELECT COUNT() FROM Knowledge__kav WHERE Title LIKE 'Merged:%'];
        Assert.isTrue(drafts >= 1);
    }

 // the confidence-score band gate was removed — an explicit user
    // approval ALWAYS merges, regardless of the candidate's confidence score.
    // A mid-confidence candidate that the old code parked in the "manual
    // review" band now drafts + resolves like any other approved merge.
    @IsTest
    static void testConsolidationQueueable_MidConfidence_StillMergesOnApproval() {
        PromptTemplateService.setMock(new StubPromptService());
        Duplicate_Candidate__c acMid = byKey('t5-AC-mid');

        Tier4ConsolidationAction.ConsolidationQueueable q =
            new Tier4ConsolidationAction.ConsolidationQueueable(new List<Id>{ acMid.Id });

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Duplicate_Candidate__c after = byKey('t5-AC-mid');
        Assert.areEqual('Resolved', after.Status__c,
            'user-approved merge resolves regardless of confidence');
        Assert.isNotNull(after.Merged_Article__c,
            'mid-confidence approved merge still drafts a Golden Record');
    }

 // a low-confidence candidate (old "log only" band) also merges once
    // the user has explicitly approved it — no silent no-op.
    @IsTest
    static void testConsolidationQueueable_LowConfidence_StillMergesOnApproval() {
        PromptTemplateService.setMock(new StubPromptService());
        Duplicate_Candidate__c abLow = byKey('t5-AB-low');

        Tier4ConsolidationAction.ConsolidationQueueable q =
            new Tier4ConsolidationAction.ConsolidationQueueable(new List<Id>{ abLow.Id });

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Duplicate_Candidate__c after = byKey('t5-AB-low');
        Assert.areEqual('Resolved', after.Status__c,
            'low-confidence approved merge resolves (no band gate)');
        Assert.isNotNull(after.Merged_Article__c,
            'low-confidence approved merge still drafts a Golden Record');
    }

    @IsTest
    static void testConsolidationQueueable_NonPendingCandidates_NoOp() {
        PromptTemplateService.setMock(new StubPromptService());
        Duplicate_Candidate__c ab = byKey('t5-AB');
        ab.Status__c = 'Resolved';
        update ab;

        Tier4ConsolidationAction.ConsolidationQueueable q =
            new Tier4ConsolidationAction.ConsolidationQueueable(new List<Id>{ ab.Id });

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        // Tighter than a global Title LIKE 'Merged:%' count: assert that the
        // specific candidate's Merged_Article__c lookup is null. Resilient
        // against test-ordering side effects from other tests in the class.
        Duplicate_Candidate__c after = [
            SELECT Merged_Article__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.isNull(after.Merged_Article__c,
            'Non-pending candidate must not be linked to a new draft');
    }

    @IsTest
    static void testConsolidationQueueable_PromptThrows_MarksErrorNotSilent() {
        PromptTemplateService.setMock(new ThrowingPromptService());
        Duplicate_Candidate__c ab = byKey('t5-AB');

        Tier4ConsolidationAction.ConsolidationQueueable q =
            new Tier4ConsolidationAction.ConsolidationQueueable(new List<Id>{ ab.Id });

 // a merge failure must NOT be silent and must NOT re-throw-and-roll-
        // back (which would erase the status). The candidate is stamped Status=Error
        // + Merge_Error__c so the Duplicates queue shows a visible "Failed" row with
        // the reason, and the pair stays actionable for a retry.
        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Duplicate_Candidate__c after = [
            SELECT Status__c, Merge_Error__c, Merged_Article__c
            FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Error', after.Status__c, 'Failed merge marks the candidate Error');
        Assert.isNotNull(after.Merge_Error__c, 'Failed merge records a reason in Merge_Error__c');
        Assert.isNull(after.Merged_Article__c, 'No draft linked on a failed merge');
    }

 // review finding — the pair CREATE_NEW path's `insert newDrafts` was a
    // bare DML outside try/catch: an insert-level failure (INSUFFICIENT_ACCESS on
    // Knowledge create, REQUIRED_FIELD_MISSING, a validation rule, or a URLName
    // DUPLICATE_VALUE) escaped uncaught and rolled back the status write — leaving
 // the pair silently Pending, the exact silent-failure removes. Here we
    // force a deterministic DUPLICATE_VALUE by pre-inserting a draft whose UrlName
    // collides with the one the queueable generates (dc.Id.to15() + '-' + art1
    // UrlName). The in-memory merge SUCCEEDS (StubPromptService), so the candidate
    // is optimistically Resolved — only the insert fails — proving the wrapped
    // insert flips it to Error rather than rolling back.
    @IsTest
    static void testConsolidationQueueable_DraftInsertFails_MarksErrorNotRolledBack() {
        PromptTemplateService.setMock(new StubPromptService());
        Duplicate_Candidate__c ab = byKey('t5-AB');

        // art1 is the version referenced by Knowledge_Article_1__c; reproduce the
        // queueable's UrlName formula and squat on it so the bulk insert collides.
        Duplicate_Candidate__c full = [
            SELECT Knowledge_Article_1__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Knowledge__kav art1 = [
            SELECT UrlName FROM Knowledge__kav WHERE Id = :full.Knowledge_Article_1__c LIMIT 1
        ];
        String collidingUrl = ((Id) ab.Id).to15() + '-' + art1.UrlName;
        if (collidingUrl.length() > 255) collidingUrl = collidingUrl.abbreviate(255);
        insert new Knowledge__kav(
            Title = 'URL squatter', UrlName = collidingUrl,
            Language = 'en_US', Summary = 'occupies the merged draft UrlName'
        );

        Tier4ConsolidationAction.ConsolidationQueueable q =
            new Tier4ConsolidationAction.ConsolidationQueueable(new List<Id>{ ab.Id });

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Duplicate_Candidate__c after = [
            SELECT Status__c, Merge_Error__c, Merged_Article__c, Merged_Article_Version__c
            FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Error', after.Status__c,
            'A draft-insert failure must stamp Error, not roll back to Pending');
        Assert.isNotNull(after.Merge_Error__c, 'The insert failure records a reason');
        Assert.isNull(after.Merged_Article__c, 'No draft linked when the insert failed');
        Assert.isNull(after.Merged_Article_Version__c, 'No version-lookup linked when the insert failed');
    }

 // staleness guard: if an article changed AFTER the duplicate was detected
    // (a newer draft/version), the merge must be blocked — never merge on a stale
    // verdict or clobber newer edits. The guard skips the EVALUATED version (that
    // one is expected), so the test needs a SECOND version of a candidate article
    // that post-dates detection. We back-date Score_Calculated_Date__c and point
    // the candidate at a stand-in "evaluated" version id that is NOT the article's
    // current version — so the current fixture version reads as newer-than-analysis.
    @IsTest
    static void testConsolidationQueueable_StaleArticle_BlocksMerge() {
        PromptTemplateService.setMock(new StubPromptService());
        Duplicate_Candidate__c ab = byKey('t5-AB');

        // Simulate "the article changed since detection": back-date the candidate's
        // detection time to a year ago. The fixture's article versions were created
        // in @TestSetup ("now"), so they post-date detection → the guard sees a
        // newer-than-analysis version and must block the merge.
        ab.Score_Calculated_Date__c = Datetime.now().addYears(-1);
        update ab;

        Tier4ConsolidationAction.ConsolidationQueueable q =
            new Tier4ConsolidationAction.ConsolidationQueueable(new List<Id>{ ab.Id });

        Test.startTest();
        q.execute(null);
        Test.stopTest();

 // a stale-blocked merge is stamped Error + a "newer version" reason
        // (visible on the queue), NOT silently left Pending and NOT a rollback-throw.
        Duplicate_Candidate__c after = [
            SELECT Status__c, Merge_Error__c, Merged_Article__c
            FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Error', after.Status__c, 'Stale article blocks the merge → Error status');
        Assert.isTrue(after.Merge_Error__c != null && after.Merge_Error__c.contains('newer'),
            'Merge_Error__c explains the staleness; got: ' + after.Merge_Error__c);
        Assert.isNull(after.Merged_Article__c, 'No Golden Record drafted for a stale merge');
    }

    @IsTest
    static void testConsolidationQueueable_MultipleCandidates_BulkProcessed() {
 // confidence score is irrelevant now (no band gate) — both
        // approved candidates merge + resolve. AB (95) and DE (80) suffice.
        PromptTemplateService.setMock(new StubPromptService());
        Id ab = byKey('t5-AB').Id;
        Id deId = byKey('t5-DE').Id;

        Tier4ConsolidationAction.ConsolidationQueueable q =
            new Tier4ConsolidationAction.ConsolidationQueueable(new List<Id>{ ab, deId });

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        Integer resolvedHigh = [
            SELECT COUNT() FROM Duplicate_Candidate__c
            WHERE Id IN :new List<Id>{ ab, deId } AND Status__c = 'Resolved'
        ];
        Assert.areEqual(2, resolvedHigh, 'Both approved pairs resolved (no band gate)');
    }

    // ──────────────────────────────────────────────────────────────────────
    // ClusterConsolidationQueueable
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void consolidateCluster_mergesImpliedClosure() {
        PromptTemplateService.setMock(new StubPromptService());

        Duplicate_Candidate__c ab = byKey('t5-AB');
        Duplicate_Candidate__c ac = byKey('t5-AC');

        Test.startTest();
        Tier4ConsolidationAction.consolidateCluster(new List<Id>{ ab.Id, ac.Id });
        Test.stopTest();

        // User ticked AB + AC. Closure is {A, B, C}, so BC (never ticked) is implied.
        List<Duplicate_Candidate__c> resolved = [
            SELECT Id, Composite_Key__c, Status__c, Merged_Article__c, Merged_Article_Version__c
            FROM Duplicate_Candidate__c
            WHERE Composite_Key__c IN ('t5-AB', 't5-AC', 't5-BC')
        ];
        Set<Id> mergedTargets = new Set<Id>();
        for (Duplicate_Candidate__c dc : resolved) {
            Assert.areEqual('Resolved', dc.Status__c, dc.Composite_Key__c + ' Resolved');
            Assert.isNotNull(dc.Merged_Article__c);
 // the version lookup mirrors the Text version id at the
            // CREATE_NEW *cluster* write site (distinct from the pair site at ~line 135).
            Assert.areEqual(dc.Merged_Article__c, String.valueOf(dc.Merged_Article_Version__c),
                dc.Composite_Key__c + ' Merged_Article_Version__c mirrors Merged_Article__c');
            mergedTargets.add(dc.Merged_Article__c);
        }
        Assert.areEqual(1, mergedTargets.size(),
            'All 3 candidates share one Merged_Article__c');

        // The shared Merged_Article__c is a Knowledge__kav draft with the
        // documented "Merged: <originalTitle>" prefix.
        Id draftId = new List<Id>(mergedTargets)[0];
        Knowledge__kav draft = [SELECT Title FROM Knowledge__kav WHERE Id = :draftId LIMIT 1];
        Assert.isTrue(draft.Title.startsWith('Merged:'),
            'Draft article title preserves the "Merged:" prefix from the production naming rule');

        Duplicate_Candidate__c de = byKey('t5-DE');
        Assert.areEqual('Pending', de.Status__c,
            'Unrelated pair must stay Pending');
    }

    @IsTest
    static void consolidateCluster_noopForEmptyInput() {
        Test.startTest();
        Tier4ConsolidationAction.consolidateCluster(new List<Id>());
        Test.stopTest();

        Integer pending = [SELECT COUNT() FROM Duplicate_Candidate__c WHERE Status__c = 'Pending'];
        Assert.isTrue(pending >= 4, 'Nothing changes on empty input');
    }

    @IsTest
    static void consolidateCluster_ignoresNonPendingSeeds() {
        PromptTemplateService.setMock(new StubPromptService());

        Duplicate_Candidate__c ab = byKey('t5-AB');
        ab.Status__c = 'Resolved';
        update ab;

        Test.startTest();
        Tier4ConsolidationAction.consolidateCluster(new List<Id>{ ab.Id });
        Test.stopTest();

        Integer drafts = [SELECT COUNT() FROM Knowledge__kav WHERE Title LIKE 'Merged:%'];
        Assert.areEqual(0, drafts,
            'No draft when seed is non-pending');
    }

    @IsTest
    static void consolidateCluster_PromptThrows_NoDraft_NoResolve() {
        PromptTemplateService.setMock(new ThrowingPromptService());

        Duplicate_Candidate__c ab = byKey('t5-AB');
        Duplicate_Candidate__c ac = byKey('t5-AC');

 // cluster expansion succeeded but the draft merge failed. The
        // queueable must stamp EVERY cluster candidate Status=Error + Merge_Error__c
        // (visible on the queue) rather than re-throwing (which would roll back the
        // stamp) or silently returning. No draft is linked.
        Test.startTest();
        Tier4ConsolidationAction.consolidateCluster(new List<Id>{ ab.Id, ac.Id });
        Test.stopTest(); // async queueable executes here — no exception now

        // Assert on BOTH user-ticked seeds AND the implied BC pair.
        Duplicate_Candidate__c afterAb = [SELECT Status__c, Merge_Error__c, Merged_Article__c FROM Duplicate_Candidate__c WHERE Id = :ab.Id];
        Duplicate_Candidate__c afterAc = [SELECT Status__c, Merged_Article__c FROM Duplicate_Candidate__c WHERE Id = :ac.Id];
        Duplicate_Candidate__c afterBc = byKey('t5-BC');
        Assert.areEqual('Error', afterAb.Status__c, 'AB marked Error');
        Assert.isNotNull(afterAb.Merge_Error__c, 'AB carries a failure reason');
        Assert.areEqual('Error', afterAc.Status__c, 'AC marked Error');
        Assert.areEqual('Error', afterBc.Status__c, 'Implied BC marked Error');
        Assert.isNull(afterAb.Merged_Article__c, 'AB has no draft link');
        Assert.isNull(afterAc.Merged_Article__c, 'AC has no draft link');
    }

    // ──────────────────────────────────────────────────────────────────────
 // KEEP_SURVIVOR — enrich survivor as a new draft version; the loser is
    // archived later (on survivor publish) via the candidate junction, NOT via a
    // stamp on the loser article. A probe (2026-06-16) proved Knowledge__kav
    // custom fields are writable only on a Draft, so the old loser Merged_Into__c
    // stamp silently no-opped. This test locks in that the merge path writes ONLY
    // the survivor draft and points the candidate at the survivor master.
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void keepSurvivor_enrichesSurvivor_pointsCandidateAtSurvivor_noLoserWrite() {
        PromptTemplateService.setMock(new StubPromptService());

        // The high-confidence AB pair. art1 is the survivor we keep.
        Duplicate_Candidate__c ab = [
            SELECT Id, Knowledge_Article_1__c, Knowledge_Article_2__c
            FROM Duplicate_Candidate__c WHERE Composite_Key__c = 't5-AB' LIMIT 1
        ];
        Id survivorVersionId = Id.valueOf(ab.Knowledge_Article_1__c);
        Id loserVersionId = Id.valueOf(ab.Knowledge_Article_2__c);

        Map<Id, Knowledge__kav> versions = new Map<Id, Knowledge__kav>([
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav
            WHERE Id IN (:survivorVersionId, :loserVersionId)
        ]);
        String survivorMaster = String.valueOf(versions.get(survivorVersionId).KnowledgeArticleId);
        String loserMaster = String.valueOf(versions.get(loserVersionId).KnowledgeArticleId);

        // Stub the publisher (editOnlineArticle returns a draft id) and writer
        // (record-only — KAVs can't reach Online in tests).
        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        pub.returnDraftId = String.valueOf(survivorVersionId); // a real KAV id stands in for the draft
        MockKavDraftWriter writer = new MockKavDraftWriter();
        Tier4ConsolidationAction.publisher = pub;
        Tier4ConsolidationAction.draftWriter = writer;

        Tier4ConsolidationAction.ConsolidationQueueable q =
            new Tier4ConsolidationAction.ConsolidationQueueable(
                new List<Id>{ ab.Id },
                Tier4ConsolidationAction.KEEP_SURVIVOR,
                survivorVersionId
            );

        Test.startTest();
        q.execute(null);
        Test.stopTest();

        // Survivor draft was opened + written; loser article was NOT archived at
        // merge (that's deferred to survivor publish) and NOT written.
        Assert.areEqual(1, pub.editCallCount, 'editOnlineArticle opened the survivor draft once');
        Assert.areEqual(versions.get(survivorVersionId).KnowledgeArticleId, pub.editedArticleIds[0],
            'editOnlineArticle is called with the survivor MASTER (KnowledgeArticleId)');
        Assert.areEqual(0, pub.archiveCallCount, 'no archive at merge time (deferred to publish)');

        // The writer only touched the survivor draft — never the loser article.
        for (Knowledge__kav w : writer.writtenDrafts) {
            Assert.areNotEqual(loserVersionId, w.Id, 'loser article must never be written');
        }

        // Candidate now points at the survivor (draft + master) so the reconciler
        // can both fire the Resolved happy-path and derive the loser to archive.
        Duplicate_Candidate__c after = [
            SELECT Status__c, Merged_Article__c, Merged_Article_Version__c, Merged_Knowledge_Article_Id__c
            FROM Duplicate_Candidate__c WHERE Id = :ab.Id
        ];
        Assert.areEqual('Resolved', after.Status__c, 'keep-survivor merge resolves the candidate');
 // the version lookup mirrors the Text version id at the KEEP_SURVIVOR site too.
        Assert.areEqual(after.Merged_Article__c, String.valueOf(after.Merged_Article_Version__c),
            'keep-survivor Merged_Article_Version__c mirrors Merged_Article__c');
        Assert.areEqual(survivorMaster, after.Merged_Knowledge_Article_Id__c,
            'candidate survivor master = the kept article');
        // The loser (the non-survivor article id) is recoverable from the pair.
        Assert.areNotEqual(survivorMaster, loserMaster, 'sanity: survivor != loser');
    }

 // review nit — lock in the 4th (and last un-asserted) Tier4 write site:
    // the cluster KEEP_SURVIVOR path (Tier4ConsolidationAction.cls:751). Mirrors
    // the pair keep-survivor test, but drives the CLUSTER queueable so every
    // candidate in the closure {AB, AC, BC} gets Merged_Article_Version__c mirrored
    // to the survivor draft id — not just the ticked seeds.
    @IsTest
    static void keepSurvivorCluster_mirrorsVersionLookupAtAllClosureCandidates() {
        PromptTemplateService.setMock(new StubPromptService());

        // Ticked seeds AB + AC → closure {A, B, C}; keep article A (survivor).
        Duplicate_Candidate__c ab = [
            SELECT Id, Knowledge_Article_1__c FROM Duplicate_Candidate__c WHERE Composite_Key__c = 't5-AB' LIMIT 1
        ];
        Duplicate_Candidate__c ac = byKey('t5-AC');
        Id survivorVersionId = Id.valueOf(ab.Knowledge_Article_1__c); // article A

        Knowledge__kav survivor = [
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :survivorVersionId LIMIT 1
        ];

        // Stub the publisher (editOnlineArticle → draft id) and writer (record-only).
        MockKnowledgePublisher pub = new MockKnowledgePublisher();
        pub.returnDraftId = String.valueOf(survivorVersionId); // a real KAV id stands in for the draft
        MockKavDraftWriter writer = new MockKavDraftWriter();
        Tier4ConsolidationAction.publisher = pub;
        Tier4ConsolidationAction.draftWriter = writer;

        Test.startTest();
        Tier4ConsolidationAction.consolidateCluster(
            new List<Id>{ ab.Id, ac.Id },
            Tier4ConsolidationAction.KEEP_SURVIVOR,
            survivorVersionId
        );
        Test.stopTest();

        // The survivor draft was opened once; no new Golden Record was inserted.
        Assert.areEqual(1, pub.editCallCount, 'editOnlineArticle opened the cluster survivor draft once');
        Integer newGolden = [SELECT COUNT() FROM Knowledge__kav WHERE Title LIKE 'Merged:%'];
        Assert.areEqual(0, newGolden, 'keep-survivor does NOT create a new Golden Record');

        // Every candidate in the closure {AB, AC, BC} resolves and mirrors the
        // version lookup to the survivor draft id (the 4th write site).
        List<Duplicate_Candidate__c> resolved = [
            SELECT Composite_Key__c, Status__c, Merged_Article__c, Merged_Article_Version__c
            FROM Duplicate_Candidate__c
            WHERE Composite_Key__c IN ('t5-AB', 't5-AC', 't5-BC')
        ];
        Assert.areEqual(3, resolved.size(), 'closure {AB, AC, BC} all present');
        for (Duplicate_Candidate__c dc : resolved) {
            Assert.areEqual('Resolved', dc.Status__c, dc.Composite_Key__c + ' Resolved');
            Assert.areEqual(String.valueOf(survivorVersionId), String.valueOf(dc.Merged_Article__c),
                dc.Composite_Key__c + ' points at the survivor draft');
            Assert.areEqual(dc.Merged_Article__c, String.valueOf(dc.Merged_Article_Version__c),
                dc.Composite_Key__c + ' Merged_Article_Version__c mirrors Merged_Article__c (cluster keep-survivor, )');
        }
    }

 // the pair merge threads each article's diagnosed issues/strengths
    // into the shared consolidate prompt (not just raw content). Seed an Issue +
    // a Strength on one of the pair's articles and assert they reach the call.
    @IsTest
    static void merge_threadsArticleFindingsIntoConsolidatePrompt() {
        Duplicate_Candidate__c ab = [
            SELECT Id, Knowledge_Article_1__c FROM Duplicate_Candidate__c WHERE Composite_Key__c = 't5-AB' LIMIT 1
        ];
        // Build a findings chain on article 1: run → article assessment → dim result → analyses.
        Id ver1 = ab.Knowledge_Article_1__c;
        KB_Assessment_Run__c run = KBTestDataFactory.insertRun('Completed', 'Readiness');
        KB_Article_Assessment__c aa = KBTestDataFactory.insertArticleAssessment(run.Id, ver1);
        KB_Dimension_Result__c dr = new KB_Dimension_Result__c(
            Article_Assessment__c = aa.Id, Dimension__c = 'Completeness', Score__c = 40
        );
        insert dr;
        insert new List<KB_Dimension_Analysis__c>{
            new KB_Dimension_Analysis__c(
                Dimension_Result__c = dr.Id, Article_Assessment__c = aa.Id,
                Dimension__c = 'Completeness', Type__c = 'Issue',
                Analysis_Text__c = 'Summary is missing key steps', Status__c = 'Open'),
            new KB_Dimension_Analysis__c(
                Dimension_Result__c = dr.Id, Article_Assessment__c = aa.Id,
                Dimension__c = 'Completeness', Type__c = 'Strength',
                Analysis_Text__c = 'Title is clear and answerable', Status__c = 'Open')
        };

        StubPromptService stub = new StubPromptService();
        PromptTemplateService.setMock(stub);

        Test.startTest();
        // Default keep-choice via the legacy no-arg path = create-new merge.
        DuplicateCandidateController.approveMerge(ab.Id);
        Test.stopTest();

        Assert.isNotNull(stub.lastArticles, 'consolidateArticles was called');
        // Flatten all issues/strengths the prompt received across both articles.
        List<String> allIssues = new List<String>();
        List<String> allStrengths = new List<String>();
        for (PromptTemplateService.ArticleInput ai : stub.lastArticles) {
            if (ai.issues != null) allIssues.addAll(ai.issues);
            if (ai.strengths != null) allStrengths.addAll(ai.strengths);
        }
        Boolean issueThreaded = false;
        for (String s : allIssues) { if (s.contains('missing key steps')) issueThreaded = true; }
        Boolean strengthThreaded = false;
        for (String s : allStrengths) { if (s.contains('clear and answerable')) strengthThreaded = true; }
        Assert.isTrue(issueThreaded, 'Article issue must be threaded into the merge prompt');
        Assert.isTrue(strengthThreaded, 'Article strength must be threaded into the merge prompt');
    }

    // ──────────────────────────────────────────────────────────────────────
 // friendlyMergeError — message shaping
    // ──────────────────────────────────────────────────────────────────────

    // applyTitle throws a complete, already-actionable sentence. friendlyMergeError
    // must pass it through verbatim rather than doubling it with "Merge failed: ".
    // The message names BOTH causes (no write permset OR missing Title FLS) so an
    // analysis-only user isn't misdirected to grant Title FLS when the real gap is
    // the KB_Knowledge_Author write permset.
    @IsTest
    static void friendlyMergeError_TitleFlsMessage_PassesThroughUnprefixed() {
        KnowledgeAIException ex = new KnowledgeAIException(
            'Cannot set the merged article Title on Knowledge__kav.Title — the '
            + 'running user can\'t edit it. Two things can cause this: you may '
            + 'not have Knowledge write access (ask an admin to assign the '
            + 'KB Knowledge Author permission set — Knowledge Create/Edit — plus '
            + 'Manage Articles + Publish Articles and the Knowledge User license); '
            + 'or you have write access but lack field-level security (Edit) on '
            + 'your Content Scope fields (Setup Wizard, Step 2). Grant whichever '
            + 'applies, then retry the merge.');

        String msg = Tier4ConsolidationAction.friendlyMergeError(ex);

        Assert.isFalse(msg.startsWithIgnoreCase('Merge failed:'),
            'applyTitle message must pass through un-prefixed (no doubled "Merge failed:")');
        Assert.isTrue(msg.contains('Knowledge__kav.Title'),
            'Original actionable text must be preserved verbatim (passthrough match)');
        Assert.isTrue(msg.containsIgnoreCase('KB Knowledge Author'),
            'Message names the write-permset cause (not just Title FLS)');
        Assert.isTrue(msg.containsIgnoreCase('field-level security'),
            'Message still names the FLS cause too');
    }

    // An unrelated failure must still get the generic "Merge failed: " prefix —
    // the new passthrough branch must not over-match.
    @IsTest
    static void friendlyMergeError_UnrelatedError_KeepsMergeFailedPrefix() {
        String msg = Tier4ConsolidationAction.friendlyMergeError(
            new KnowledgeAIException('URLName collides with an existing draft'));

        Assert.isTrue(msg.startsWith('Merge failed:'),
            'Unrelated errors must keep the generic "Merge failed: " prefix');
    }
}
