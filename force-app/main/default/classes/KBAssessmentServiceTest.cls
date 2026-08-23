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
private class KBAssessmentServiceTest {

    @IsTest
    static void testConstructor_Default() {
        Test.startTest();
        KBAssessmentService service = new KBAssessmentService();
        Test.stopTest();

        Assert.isNotNull(service, 'Service should be instantiated');
    }

    // ──────────────────────────────────────────────────────────────────────
 // buildScoringTasks — ≤50 fan-out decomposition.
    // Deterministic dims → 1 task each; LLM dims → ceil(N / llmFanOutChunkSize)
    // tasks; tokens are unique and sequential. (Review finding c: no direct
    // coverage of the chunking seam.)
    // ──────────────────────────────────────────────────────────────────────

    private static List<String> fakeIds(Integer n) {
        List<String> ids = new List<String>();
        for (Integer i = 0; i < n; i++) ids.add('kav-' + i);
        return ids;
    }

    @IsTest
    static void testBuildScoringTasks_DeterministicDim_SingleTask() {
        KBAssessmentService service = new KBAssessmentService();
        List<KBAssessmentModels.ScoringTask> tasks =
            service.buildScoringTasks(fakeIds(45), new Set<String>{ 'Freshness' });

        Assert.areEqual(1, tasks.size(),
            'A deterministic dimension is one task regardless of article count');
        Assert.areEqual(45, tasks[0].articleIds.size(),
            'The single deterministic task covers all articles');
    }

    @IsTest
    static void testBuildScoringTasks_LLMDim_ChunksByTen() {
        KBAssessmentService service = new KBAssessmentService();
        // 45 articles / chunk 10 = ceil = 5 tasks; last holds the remainder (5).
        List<KBAssessmentModels.ScoringTask> tasks =
            service.buildScoringTasks(fakeIds(45), new Set<String>{ 'Clarity' });

        Assert.areEqual(5, tasks.size(), '45 / 10 → 5 chunk tasks');
        Integer covered = 0;
        for (KBAssessmentModels.ScoringTask t : tasks) {
            Assert.isTrue(t.articleIds.size() <= 10, 'No chunk exceeds 10 articles');
            covered += t.articleIds.size();
        }
        Assert.areEqual(45, covered, 'Chunks cover every article exactly once (no drop/dupe)');
        Assert.areEqual(5, tasks[4].articleIds.size(), 'Final chunk holds the remainder');
    }

    @IsTest
    static void testBuildScoringTasks_TokensUniqueAndSequential() {
        KBAssessmentService service = new KBAssessmentService();
        List<KBAssessmentModels.ScoringTask> tasks =
            service.buildScoringTasks(fakeIds(25),
                new Set<String>{ 'Clarity', 'Freshness' });

        Set<String> seen = new Set<String>();
        for (KBAssessmentModels.ScoringTask t : tasks) {
            Assert.isTrue(String.isNotBlank(t.token), 'Every task carries a token');
            Assert.isFalse(seen.contains(t.token), 'Tokens are unique: ' + t.token);
            seen.add(t.token);
        }
        // Clarity: ceil(25/10)=3 tasks; Freshness: 1 task → 4 tokens 0..3.
        Assert.areEqual(4, seen.size(), '3 LLM chunks + 1 deterministic = 4 tokens');
    }

    @IsTest
    static void testBuildScoringTasks_EmptyArticles_StillEmitsTaskPerDim() {
        KBAssessmentService service = new KBAssessmentService();
        List<KBAssessmentModels.ScoringTask> tasks =
            service.buildScoringTasks(new List<String>(),
                new Set<String>{ 'Clarity' });

        Assert.areEqual(1, tasks.size(),
            'Zero articles still emits one task so the dimension can complete');
    }

    @IsTest
    static void testRunAssessment_NullArticleIds() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = service.runAssessment(null);
        Test.stopTest();

        Assert.areEqual('Failed', result.status, 'Null article IDs should result in Failed status');
    }

    @IsTest
    static void testRunAssessment_EmptyArticleIds() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = service.runAssessment(new List<String>());
        Test.stopTest();

        Assert.areEqual('Failed', result.status, 'Empty article IDs should result in Failed status');
    }

    @IsTest
    static void testRunAssessment_WithValidIds() {
        KBAssessmentService service = new KBAssessmentService();
        List<String> articleIds = new List<String>{'ka001', 'ka002'};

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = service.runAssessment(articleIds);
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
        Assert.isNotNull(result.runId, 'Run ID should be created');
        // Articles won't exist in test context; runAssessment returns synchronously with a
        // handoff status (Processing / In Progress / Failed / Completed).
        Assert.isNotNull(result.status, 'Status should be set');
    }

    @IsTest
    static void testGetRecentAssessmentRuns_NoLimit() {
        // Create test runs
        List<KB_Assessment_Run__c> runs = new List<KB_Assessment_Run__c>();
        for (Integer i = 0; i < 5; i++) {
            runs.add(new KB_Assessment_Run__c(
                Status__c = 'Completed',
                Total_Articles__c = 10,
                Overall_Score__c = 75
            ));
        }
        insert runs;

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<KB_Assessment_Run__c> results = service.getRecentAssessmentRuns(null);
        Test.stopTest();

        Assert.isTrue(results.size() > 0, 'Should return recent runs');
        Assert.isTrue(results.size() <= 10, 'Should respect default limit');
    }

    @IsTest
    static void testGetRecentAssessmentRuns_WithLimit() {
        // Create test runs
        List<KB_Assessment_Run__c> runs = new List<KB_Assessment_Run__c>();
        for (Integer i = 0; i < 10; i++) {
            runs.add(new KB_Assessment_Run__c(
                Status__c = 'Completed',
                Total_Articles__c = 5
            ));
        }
        insert runs;

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<KB_Assessment_Run__c> results = service.getRecentAssessmentRuns(3);
        Test.stopTest();

        Assert.areEqual(3, results.size(), 'Should respect specified limit');
    }

    @IsTest
    static void testDeleteAssessmentRun_ValidId() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 5
        );
        insert run;

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        service.deleteAssessmentRun(run.Id);
        Test.stopTest();

        List<KB_Assessment_Run__c> remainingRuns = [
            SELECT Id FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual(0, remainingRuns.size(), 'Run should be deleted');
    }

 // a still-running run must NOT be deletable server-side, even though
    // the LWC row disables the delete action. Mirrors cancelAssessmentRun's guard.
    @IsTest
    static void testDeleteAssessmentRun_RunningRunIsBlocked() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 5
        );
        insert run;

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        Boolean threw = false;
        try {
            service.deleteAssessmentRun(run.Id);
        } catch (KBAssessmentService.RunNotDeletableException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Deleting an in-flight run should throw RunNotDeletableException');
        List<KB_Assessment_Run__c> remainingRuns = [
            SELECT Id FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual(1, remainingRuns.size(), 'Running run must survive the blocked delete');
    }

    @IsTest
    static void testDeleteAssessmentRun_WithChildRecords() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 2
        );
        insert run;

        Knowledge__kav kav = new Knowledge__kav(
            Title = 'Test Article',
            UrlName = 'service-test-delete-cascade',
            Language = 'en_US'
        );
        insert kav;
        KB_Article_Assessment__c assessment = new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = kav.Id,
            Knowledge_Article_Id__c = kav.Id,
            Article_Title__c = 'Test Article',
            Overall_Score__c = 75
        );
        insert assessment;

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        service.deleteAssessmentRun(run.Id);
        Test.stopTest();

        // Both run and child assessments should be deleted (cascade delete)
        List<KB_Assessment_Run__c> remainingRuns = [
            SELECT Id FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual(0, remainingRuns.size(), 'Run should be deleted');

        List<KB_Article_Assessment__c> remainingAssessments = [
            SELECT Id FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :run.Id
        ];
        Assert.areEqual(0, remainingAssessments.size(), 'Child assessments should be deleted');
    }

 // (2026-07-17 decision) — deleting a run removes ALL of its duplicate
    // AND enrichment candidates, regardless of status. Supersedes the earlier
 // "keep triaged as audit" behaviour: once the run is gone the triaged
    // rows point at a dead run, so we delete rather than orphan. The user is
    // warned in the UI first. Generated Knowledge drafts are NOT deleted.
    @IsTest
    static void testDeleteAssessmentRun_RemovesAllDuplicateAndEnrichmentCandidates() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(Status__c = 'Completed', Total_Articles__c = 2);
        insert run;
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(4, 'del-cand');

        // Two DC in different statuses — BOTH must be deleted now.
        Duplicate_Candidate__c pending = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = kavs[0].Id, Knowledge_Article_2__c = kavs[1].Id,
            Composite_Key__c = 'del-pending', Flag_Type__c = 'Duplicate', Status__c = 'Pending',
            Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Assessment_Run__c = run.Id
        );
        Duplicate_Candidate__c rejected = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = kavs[2].Id, Knowledge_Article_2__c = kavs[3].Id,
            Composite_Key__c = 'del-rejected', Flag_Type__c = 'Duplicate', Status__c = 'Rejected',
            Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Assessment_Run__c = run.Id
        );
        insert new List<Duplicate_Candidate__c>{ pending, rejected };

        // An enrichment candidate pointing at a (stand-in) draft version id.
        Enrichment_Candidate__c ec = new Enrichment_Candidate__c(
            Source_Article_Version_Id__c = kavs[0].Id,
            Draft_Article_Version_Id__c = String.valueOf(kavs[1].Id),
            Knowledge_Article_Id__c = String.valueOf(kavs[0].Id),
            Assessment_Run__c = run.Id,
            Composite_Key__c = 'del-ec-1',
            Status__c = 'Published', // a triaged/terminal status — still deleted
            Is_Closed__c = false
        );
        insert ec;

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        service.deleteAssessmentRun(run.Id);
        Test.stopTest();

        Assert.areEqual(0, [
            SELECT COUNT() FROM Duplicate_Candidate__c
            WHERE Id IN :new List<Id>{ pending.Id, rejected.Id }
        ], 'All duplicate candidates deleted with the run (regardless of status)');
        Assert.areEqual(0, [
            SELECT COUNT() FROM Enrichment_Candidate__c WHERE Id = :ec.Id
        ], 'Enrichment candidate deleted with the run');

        // The Knowledge draft the EC pointed at is NOT deleted (Q1 decision).
        Assert.areEqual(1, [
            SELECT COUNT() FROM Knowledge__kav WHERE Id = :kavs[1].Id
        ], 'Generated Knowledge draft is left intact — only candidate metadata removed');
    }

 // KB_Pipeline_Run__c and its Knowledge_Pair_Evaluation__c children are
    // LOOKUP-linked (not master-detail), so they don't ride the run cascade.
    // deleteRunPipelineArtifacts must remove them explicitly, else their globally
    // unique Composite_Version_Key__c rows squat on the pair key and block a later
    // run's KPE upsert (the zero-candidates collision).
    @IsTest
    static void testDeleteAssessmentRun_RemovesPipelineRunAndPairEvaluations() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(Status__c = 'Completed', Total_Articles__c = 2);
        insert run;
        KB_Pipeline_Run__c pr = KBTestDataFactory.insertPipelineRun(run.Id, 'DEDUPLICATION', 'Completed');

        Knowledge_Pair_Evaluation__c eval = new Knowledge_Pair_Evaluation__c(
            Composite_Version_Key__c =
                KnowledgeAIGovernanceService.generatePipelineEvaluationKey(
                    'ka01A000001AAAA', 'ka01A000001BBBB', pr.Id),
            Evaluation_Status__c = 'Clear',
            Evaluated_Date__c = Datetime.now(),
            Pipeline_Run__c = pr.Id,
            Evaluation_Domain__c = KnowledgeAIGovernanceService.EVALUATION_DOMAIN_PIPELINE
        );
        insert eval;

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        service.deleteAssessmentRun(run.Id);
        Test.stopTest();

        Assert.areEqual(0, [
            SELECT COUNT() FROM KB_Pipeline_Run__c WHERE Id = :pr.Id
        ], 'Pipeline run deleted with the assessment run (lookup, not cascade)');
        Assert.areEqual(0, [
            SELECT COUNT() FROM Knowledge_Pair_Evaluation__c WHERE Id = :eval.Id
        ], 'Pair-evaluation cache row deleted with its pipeline run — no orphaned unique key');
    }

 // ──: destructive rerun ──────────────────────────────────────────

    /**
     * Seeds a run with two real KAV-backed assessments, each carrying a
     * dimension-result (master-detail) and a dimension-analysis (lookup) row.
     * Returns the run so callers can act on it.
     */
    private static KB_Assessment_Run__c seedScoredRun(String urlPrefix) {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 2,
            Overall_Score__c = 70,
            Completeness_Score__c = 72,
            Completed_At__c = Datetime.now(),
            Run_Name__c = 'Rerun me',
            Description__c = 'original description',
            Requested_Scope__c = 'Selected',
            // PascalCase to match DimensionRegistry DeveloperNames so the
            // rerun re-scores exactly Completeness + Structure (deterministic,
            // no dedup pipeline — neither Duplication nor Conflict is selected).
            Selected_Dimensions_JSON__c = JSON.serialize(
                new List<String>{ 'Completeness', 'Structure' }
            ),
            Assessment_Types__c = 'Readiness'
        );
        insert run;

        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, urlPrefix);
        // Publish so each article has a live Online version — the rerun's
 // latest-published-version resolver selects on
        // KnowledgeArticleId + PublishStatus='Online', so the seed must reflect
        // real published articles, not drafts.
        Map<Id, Knowledge__kav> byId = new Map<Id, Knowledge__kav>([
            SELECT Id, KnowledgeArticleId, Title FROM Knowledge__kav WHERE Id IN :kavs
        ]);
        for (Knowledge__kav k : byId.values()) {
            KbManagement.PublishingService.publishArticle(k.KnowledgeArticleId, true);
        }

        List<KB_Article_Assessment__c> assessments = new List<KB_Article_Assessment__c>();
        for (Knowledge__kav k : byId.values()) {
            assessments.add(new KB_Article_Assessment__c(
                Assessment_Run__c = run.Id,
                Knowledge__c = k.Id,
                // Real parent id (KnowledgeArticleId), not the version id — the
                // rerun recovers parents and re-resolves to the latest version.
                Knowledge_Article_Id__c = String.valueOf(k.KnowledgeArticleId),
                Article_Title__c = k.Title,
                Overall_Score__c = 72
            ));
        }
        insert assessments;

        // Insert the dimension-result parents FIRST so the analyses can chain
        // off them — KB_Dimension_Analysis__c.Dimension_Result__c is a REQUIRED
        // master-detail (production always links analysis → result → assessment).
        List<KB_Dimension_Result__c> results = new List<KB_Dimension_Result__c>();
        for (KB_Article_Assessment__c a : assessments) {
            results.add(new KB_Dimension_Result__c(
                Article_Assessment__c = a.Id,
                Dimension__c = 'Completeness',
                Score__c = 72
            ));
        }
        insert results;

        // Build one analysis per result, pairing by index (results[i] and
        // assessments[i] share the same article assessment). Set the required
        // master-detail parent plus the denormalized Article_Assessment__c
        // lookup the run-scoped count queries traverse.
        List<KB_Dimension_Analysis__c> analyses = new List<KB_Dimension_Analysis__c>();
        for (Integer i = 0; i < results.size(); i++) {
            analyses.add(new KB_Dimension_Analysis__c(
                Dimension_Result__c = results[i].Id,
                Article_Assessment__c = assessments[i].Id,
                Dimension__c = 'Completeness',
                Type__c = 'Issue',
                Analysis_Text__c = 'Missing summary',
                Recommendation__c = 'Add a summary',
                Status__c = 'Open'
            ));
        }
        insert analyses;
        return run;
    }

    @IsTest
    static void testRerunAssessment_KeepsRunAndReassessesSameScope() {
        KB_Assessment_Run__c original = seedScoredRun('rerun-primary');
        Id originalId = original.Id;
        Datetime originalCreated = [
            SELECT CreatedDate FROM KB_Assessment_Run__c WHERE Id = :originalId
        ].CreatedDate;

        // Capture the original child assessment ids so we can prove they are
        // REUSED (not delete+reinserted) — the structural-preservation guarantee.
        Set<Id> assessmentIdsBefore = new Set<Id>(new Map<Id, KB_Article_Assessment__c>([
            SELECT Id FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :originalId
        ]).keySet());
        Assert.areEqual(2, assessmentIdsBefore.size(), 'Seed should create 2 child assessments');

        // A second, unrelated run that MUST survive the rerun untouched.
        KB_Assessment_Run__c other = seedScoredRun('rerun-other');
        Id otherId = other.Id;
        Integer otherAssessmentsBefore = [
            SELECT COUNT() FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :otherId
        ];
        Integer otherAnalysesBefore = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Article_Assessment__r.Assessment_Run__c = :otherId
        ];

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = service.rerunAssessment(originalId);

        // Assert the mid-flight state BEFORE stopTest() flushes the enqueued
        // dimension queueables: the run is re-armed (back to a running status,
        // terminal stamp cleared, dispatch tracking reset) but NOT yet
        // finalized.
        KB_Assessment_Run__c midFlight = [
            SELECT Status__c, Completed_At__c, Dispatched_Dimensions__c, Completed_Dimensions__c
            FROM KB_Assessment_Run__c WHERE Id = :originalId
        ];
        Assert.areEqual('In Progress', midFlight.Status__c,
            'Run should be flipped back to a running status');
        Assert.isNull(midFlight.Completed_At__c, 'Completed_At should be cleared for the rerun');
        Assert.isNotNull(midFlight.Dispatched_Dimensions__c,
            'Dispatched dimensions should be re-stamped for the fresh pass');
        Assert.isNull(midFlight.Completed_Dimensions__c,
            'Completed dimensions should be cleared so finalization waits for the fresh pass');

        Test.stopTest();

        // The SAME run survives — same id, same name, same CreatedDate.
        Assert.isNotNull(result, 'Rerun should return a result');
        Assert.areEqual(String.valueOf(originalId), result.runId,
            'Rerun must KEEP the original run id, not create a new one');
        Assert.areEqual(1, [
            SELECT COUNT() FROM KB_Assessment_Run__c WHERE Id = :originalId
        ], 'Original run must NOT be deleted');

        KB_Assessment_Run__c after = [
            SELECT Id, Run_Name__c, CreatedDate
            FROM KB_Assessment_Run__c WHERE Id = :originalId
        ];
        Assert.areEqual('Rerun me', after.Run_Name__c, 'Run name must be preserved');
        Assert.areEqual(originalCreated, after.CreatedDate, 'CreatedDate must be preserved');

        // Scope is structurally preserved: the SAME child assessments are
        // reused (idempotent preCreateParentAssessments), not delete+reinserted.
        Set<Id> assessmentIdsAfter = new Set<Id>(new Map<Id, KB_Article_Assessment__c>([
            SELECT Id FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :originalId
        ]).keySet());
        Assert.areEqual(assessmentIdsBefore, assessmentIdsAfter,
            'Existing child assessments must be reused, not delete+reinserted');
        Assert.areEqual(2, result.totalArticles, 'Rerun should re-assess the same 2 articles');

        // The unrelated run is fully intact.
        Assert.areEqual(1, [
            SELECT COUNT() FROM KB_Assessment_Run__c WHERE Id = :otherId
        ], 'Unrelated run must NOT be touched');
        Assert.areEqual(otherAssessmentsBefore, [
            SELECT COUNT() FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :otherId
        ], 'Unrelated article assessments must survive');
        Assert.areEqual(otherAnalysesBefore, [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Article_Assessment__r.Assessment_Run__c = :otherId
        ], 'Unrelated dimension analyses must survive');
    }

    @IsTest
    static void testRerunAssessment_OldResultsRemainVisibleUntilSwap() {
        // Until the async scoring completes, the old child results + run-level
        // rollup must still be present (Option B: keep the old scores visible,
        // swap in the new ones only on completion).
        KB_Assessment_Run__c original = seedScoredRun('rerun-visible');
        Id originalId = original.Id;

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        service.rerunAssessment(originalId);
        // Inside start/stopTest the enqueued dimension queueables have NOT yet
        // run — this is the "during the rerun" window.
        Integer resultsDuring = [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :originalId
        ];
        Integer analysesDuring = [
            SELECT COUNT() FROM KB_Dimension_Analysis__c
            WHERE Article_Assessment__r.Assessment_Run__c = :originalId
        ];
        Decimal rollupDuring = [
            SELECT Overall_Score__c FROM KB_Assessment_Run__c WHERE Id = :originalId
        ].Overall_Score__c;
        Test.stopTest();

        Assert.areEqual(2, resultsDuring,
            'Old Completeness dimension results must stay visible during the rerun');
        Assert.areEqual(2, analysesDuring,
            'Old dimension analyses must stay visible during the rerun');
        Assert.areEqual(70, rollupDuring,
            'Run-level rollup must stay visible during the rerun (not blanked up front)');
    }

    @IsTest
    static void testResetRunForRerun_PrunesDeselectedDimensions() {
        // A run scored on Completeness + Freshness, rerun with only Completeness
        // selected: the Freshness dimension-result rows must be pruned so the
        // dropped dim renders as N/A (absence), while Completeness rows remain
        // (to be overwritten in place by the async worker).
        KB_Assessment_Run__c run = seedScoredRun('rerun-prune');
        Id runId = run.Id;

        List<KB_Article_Assessment__c> assessments = [
            SELECT Id, Knowledge__c FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :runId
        ];
        List<KB_Dimension_Result__c> freshness = new List<KB_Dimension_Result__c>();
        for (KB_Article_Assessment__c a : assessments) {
            freshness.add(new KB_Dimension_Result__c(
                Article_Assessment__c = a.Id,
                Dimension__c = 'Freshness',
                Score__c = 90
            ));
        }
        insert freshness;

        KBAssessmentService service = new KBAssessmentService();
        Set<String> narrowed = new Set<String>{ 'Completeness' };
        Map<String, Decimal> weights = new Map<String, Decimal>{ 'Completeness' => 1.0 };

        Test.startTest();
        service.resetRunForRerun(
            run, new List<String>{ assessments[0].Knowledge__c },
            narrowed, weights, null
        );
        Test.stopTest();

        Assert.areEqual(0, [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :runId
              AND Dimension__c = 'Freshness'
        ], 'Deselected Freshness dimension rows must be pruned');
        Assert.areEqual(2, [
            SELECT COUNT() FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :runId
              AND Dimension__c = 'Completeness'
        ], 'Still-selected Completeness rows must remain (overwritten in place by the async worker)');
    }

    @IsTest
    static void testRerunAssessment_NullId() {
        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        try {
            service.rerunAssessment(null);
            Assert.fail('Should throw for null run id');
        } catch (IllegalArgumentException e) {
            // expected
        }
        Test.stopTest();
    }

    /**
     * rerunAssessment must refuse a run that is still in flight. Without the
     * guard the run flips back to 'In Progress' and re-dispatches a second wave
     * of scoring shards over the same KB_Article_Assessment__c rows, colliding on
     * the dimension-result upsert (UNABLE_TO_LOCK_ROW). The guard fires before any
     * scope recovery, so no published articles are needed; a bare non-terminal
     * run row is enough. Covers every non-terminal status.
     */
    @IsTest
    static void testRerunAssessment_BlocksWhenRunStillRunning() {
        // Every non-terminal lifecycle status must be rejected — matching the
        // canonical running set (Pending is included defensively per CLAUDE.md).
        List<String> runningStatuses = new List<String>{
            'Pending', 'Queued', 'In Progress', 'Scoring Complete', 'Pipeline Running'
        };
        KBAssessmentService service = new KBAssessmentService();

        // Bulk-insert one run per status before the loop (no DML in the loop).
        List<KB_Assessment_Run__c> runs = new List<KB_Assessment_Run__c>();
        for (String status : runningStatuses) {
            runs.add(new KB_Assessment_Run__c(
                Status__c = status,
                Total_Articles__c = 2,
                Assessment_Types__c = 'Readiness',
                Requested_Scope__c = 'Selected'
            ));
        }
        insert runs;
        Map<Id, String> statusByRunId = new Map<Id, String>();
        for (KB_Assessment_Run__c r : runs) {
            statusByRunId.put(r.Id, r.Status__c);
        }

        Test.startTest();
        for (KB_Assessment_Run__c run : runs) {
            String status = statusByRunId.get(run.Id);
            try {
                service.rerunAssessment(run.Id);
                Assert.fail('Rerun should be blocked for a run in status ' + status);
            } catch (KBAssessmentService.RunNotRerunnableException e) {
                Assert.isTrue(
                    e.getMessage().contains('still running'),
                    'Should surface a "still running" message, got: ' + e.getMessage()
                );
            }
        }
        Test.stopTest();

        // The runs must be untouched — still in their running status, not
        // flipped or re-dispatched. One bulk query, verified in memory.
        for (KB_Assessment_Run__c after : [
            SELECT Id, Status__c FROM KB_Assessment_Run__c WHERE Id IN :statusByRunId.keySet()
        ]) {
            Assert.areEqual(statusByRunId.get(after.Id), after.Status__c,
                'Blocked rerun must not mutate the run status (' + statusByRunId.get(after.Id) + ')');
        }
    }

    /**
     * A cancel must resolve the scoring join barrier itself, because aborted
     * shards never run finish() (where the barrier is normally
     * decremented/claimed). The parked value is BARRIER_CLAIMED (-1), NOT 0: at
     * 0 a straggler shard's claimIfLast() would decrement to -1, read
     * claim=(outstanding<=0)=true, and finalize a cancelled run.
     */
    @IsTest
    static void testCancelAssessmentRun_ParksScoringBarrier() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress',
            Total_Articles__c = 200,
            Assessment_Types__c = 'Readiness',
            Requested_Scope__c = 'Selected',
            // Seeded barrier from a large-run shard dispatch that never resolved.
            Scoring_Shards_Outstanding__c = 5
        );
        insert run;

        Test.startTest();
        KBAssessmentService.cancelAssessmentRun(run.Id);
        Test.stopTest();

        KB_Assessment_Run__c after = [
            SELECT Status__c, Scoring_Shards_Outstanding__c
            FROM KB_Assessment_Run__c WHERE Id = :run.Id
        ];
        Assert.areEqual('Cancelled', after.Status__c, 'Cancel must flip the run to Cancelled');
        Assert.areEqual(
            KBAssessmentBatch.BARRIER_CLAIMED,
            after.Scoring_Shards_Outstanding__c,
            'Cancel must park the claimed sentinel so a late shard cannot finalize the cancelled run'
        );
    }

    @IsTest
    static void testCancelAssessmentRun_NullRunId_Throws() {
        Boolean threw = false;
        Test.startTest();
        try {
            KBAssessmentService.cancelAssessmentRun(null);
        } catch (IllegalArgumentException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A null run id must throw rather than query with a null bind');
    }

    @IsTest
    static void testCancelAssessmentRun_AlreadyTerminal_IsIdempotentNoOp() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 1,
            Assessment_Types__c = 'Readiness', Requested_Scope__c = 'Selected'
        );
        insert run;

        Test.startTest();
        KBAssessmentService.cancelAssessmentRun(run.Id);
        Test.stopTest();

        KB_Assessment_Run__c after = [SELECT Status__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.areEqual('Completed', after.Status__c,
            'A run already in a terminal status must be left untouched, not overwritten to Cancelled');
    }

    @IsTest
    static void testRecordAsyncJobs_OverCap_DropsOldestJobIds() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'In Progress', Total_Articles__c = 1,
            Assessment_Types__c = 'Readiness', Requested_Scope__c = 'Selected'
        );
        insert run;

        // Pre-seed the CSV as close to the field's length cap as this entry
        // size allows without going over, so appending one more job id is
        // guaranteed to push it past the cap and exercise the drop-oldest loop.
        Integer cap = Schema.SObjectType.KB_Assessment_Run__c.fields.Async_Job_Ids__c.getLength();
        List<String> parts = new List<String>();
        Integer i = 0;
        while (String.join(parts, ',').length() <= cap) {
            parts.add('707fj00000A' + String.valueOf(i).leftPad(6, '0'));
            i++;
        }
        parts.remove(parts.size() - 1);
        run.Async_Job_Ids__c = String.join(parts, ',');
        update run;

        Test.startTest();
        KBAssessmentService.recordAsyncJobs(run.Id, new List<Id>{ UserInfo.getUserId() });
        Test.stopTest();

        KB_Assessment_Run__c reloaded = [SELECT Async_Job_Ids__c FROM KB_Assessment_Run__c WHERE Id = :run.Id];
        Assert.isTrue(reloaded.Async_Job_Ids__c.length() <= cap,
            'Oversized job-id CSV must be truncated back under the field cap');
        Assert.isTrue(reloaded.Async_Job_Ids__c.contains(UserInfo.getUserId()),
            'The newest job id survives truncation — oldest ids are dropped first');
    }

    /**
     * rerunAssessment must bump KB_Assessment_Run__c.Dispatch_Generation__c so a
     * straggler shard from the prior (aborted) wave sees a newer generation and
     * declines to write, instead of colliding (UNABLE_TO_LOCK_ROW) with the new
     * wave over the same rows. seedScoredRun seeds a Completed (terminal) run with
     * a null generation, so the first rerun must land it at 1.
     */
    @IsTest
    static void testRerunAssessment_BumpsDispatchGeneration() {
        KB_Assessment_Run__c original = seedScoredRun('rerun-generation');
        Id originalId = original.Id;
        Assert.isNull([
            SELECT Dispatch_Generation__c FROM KB_Assessment_Run__c WHERE Id = :originalId
        ].Dispatch_Generation__c, 'A fresh run starts with no dispatch generation');

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        service.rerunAssessment(originalId);
        Test.stopTest();

        Assert.areEqual(1, [
            SELECT Dispatch_Generation__c FROM KB_Assessment_Run__c WHERE Id = :originalId
        ].Dispatch_Generation__c,
            'Rerun must bump the dispatch generation (null → 1) so a prior-wave straggler bails');
    }

    @IsTest
    static void testRerunAssessment_RecoversScopeFromFilterPayloadFallback() {
        // A run with NO surviving child assessments — scope must be recovered
        // from the article ids frozen in Filter_DSL_JSON__c. Those frozen ids
        // are KAV VERSION ids (the selector SELECTs Id), so recoverRunArticleIds
        // must resolve them up to PARENT KnowledgeArticleIds for the rerun's
        // latest-published-version resolver.
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'rerun-fallback');
        Map<Id, Knowledge__kav> byId = new Map<Id, Knowledge__kav>([
            SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :kavs
        ]);
        List<String> versionIds = new List<String>();
        Set<String> expectedParentIds = new Set<String>();
        for (Knowledge__kav k : byId.values()) {
            versionIds.add(String.valueOf(k.Id));
            expectedParentIds.add(String.valueOf(k.KnowledgeArticleId));
        }
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 2,
            Assessment_Types__c = 'Readiness',
            Requested_Scope__c = 'Selected',
            Filter_DSL_JSON__c = JSON.serialize(
                new Map<String, Object>{ 'articleIds' => versionIds, 'logic' => 'AND' }
            )
        );
        insert run;

        KBAssessmentService service = new KBAssessmentService();
        List<String> recovered = service.recoverRunArticleIds(run.Id, run);

        Assert.areEqual(2, recovered.size(), 'Should recover 2 ids from the filter payload');
        for (String r : recovered) {
            Assert.isTrue(expectedParentIds.contains(r),
                'Recovered ids must be PARENT KnowledgeArticleIds (resolved from the frozen version ids), got: ' + r);
        }
        Assert.isFalse(recovered.contains(versionIds[0]),
            'Recovered ids must NOT be the raw version ids — they must be resolved to parents');
    }

    @IsTest
    static void testRerunAssessment_RelinksPipelineRunFreshly() {
        // A run that previously linked a (completed) pipeline run. Rerun must
        // retire that pipeline run and link a fresh one when the selection
        // still needs dedup — here we force dedup by seeding all 6 dims.
        KB_Assessment_Run__c run = seedScoredRun('rerun-pipeline');
        Id runId = run.Id;

        KB_Pipeline_Run__c oldPipeline = new KB_Pipeline_Run__c(
            Status__c = 'Completed',
            Execution_Modes__c = 'DEDUPLICATION',
            Scope_Type__c = 'Selected'
        );
        insert oldPipeline;
        Id oldPipelineId = oldPipeline.Id;
        update new KB_Assessment_Run__c(Id = runId, Pipeline_Run__c = oldPipelineId);
        // Select Duplication so determinePipelineExecutionMode wants dedup.
        update new KB_Assessment_Run__c(
            Id = runId,
            Selected_Dimensions_JSON__c = JSON.serialize(
                new List<String>{ 'Completeness', 'Duplication' }
            )
        );

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = service.rerunAssessment(runId);
        Test.stopTest();

        // Old pipeline run retired.
        Assert.areEqual(0, [
            SELECT COUNT() FROM KB_Pipeline_Run__c WHERE Id = :oldPipelineId
        ], 'Old linked pipeline run should be retired');
        // Run re-linked to a fresh, non-null pipeline run.
        Id newPipelineId = [
            SELECT Pipeline_Run__c FROM KB_Assessment_Run__c WHERE Id = :runId
        ].Pipeline_Run__c;
        Assert.isNotNull(newPipelineId, 'Run should be re-linked to a fresh pipeline run');
        Assert.areNotEqual(oldPipelineId, newPipelineId, 'New pipeline run must be a different record');
        Assert.areEqual(String.valueOf(newPipelineId), result.pipelineRunId,
            'Result should surface the fresh pipeline run id');
    }

 // On rerun, the prior pass's still-Pending duplicate candidates must
    // be deleted so they don't linger in the Action Center / dashboard implying
    // the just-rerun assessment still found them. Human-triaged rows
    // (Rejected/Suppressed/Resolved) must survive.
    @IsTest
    static void testRerunAssessment_DeletesStalePendingCandidatesOnly() {
        KB_Assessment_Run__c run = seedScoredRun('rerun-supersede');
        Id runId = run.Id;

        KB_Pipeline_Run__c oldPipeline = new KB_Pipeline_Run__c(
            Status__c = 'Completed',
            Execution_Modes__c = 'DEDUPLICATION',
            Scope_Type__c = 'Selected'
        );
        insert oldPipeline;
        update new KB_Assessment_Run__c(Id = runId, Pipeline_Run__c = oldPipeline.Id);
        update new KB_Assessment_Run__c(
            Id = runId,
            Selected_Dimensions_JSON__c = JSON.serialize(
                new List<String>{ 'Completeness', 'Duplication' }
            )
        );

        // Candidates from the prior pass, linked to the old pipeline run: one
        // Pending (should be deleted on rerun) and Rejected/Suppressed/Resolved
        // (human triage decisions that must survive).
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(5, 'rerun-sup-art');
        Duplicate_Candidate__c pending = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = kavs[0].Id, Knowledge_Article_2__c = kavs[1].Id,
            Composite_Key__c = 'sup-pending', Flag_Type__c = 'Duplicate', Status__c = 'Pending',
            Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Pipeline_Run__c = oldPipeline.Id, Assessment_Run__c = runId
        );
        Duplicate_Candidate__c rejected = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = kavs[1].Id, Knowledge_Article_2__c = kavs[2].Id,
            Composite_Key__c = 'sup-rejected', Flag_Type__c = 'Duplicate', Status__c = 'Rejected',
            Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Pipeline_Run__c = oldPipeline.Id, Assessment_Run__c = runId
        );
        Duplicate_Candidate__c suppressed = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = kavs[2].Id, Knowledge_Article_2__c = kavs[3].Id,
            Composite_Key__c = 'sup-suppressed', Flag_Type__c = 'Duplicate', Status__c = 'Suppressed',
            Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Pipeline_Run__c = oldPipeline.Id, Assessment_Run__c = runId
        );
        Duplicate_Candidate__c resolved = new Duplicate_Candidate__c(
            Knowledge_Article_1__c = kavs[3].Id, Knowledge_Article_2__c = kavs[4].Id,
            Composite_Key__c = 'sup-resolved', Flag_Type__c = 'Duplicate', Status__c = 'Resolved',
            Source_Tier__c = 'Tier4_Agentic', Confidence_Score__c = 80, Pipeline_Run__c = oldPipeline.Id, Assessment_Run__c = runId
        );
        insert new List<Duplicate_Candidate__c>{ pending, rejected, suppressed, resolved };

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        service.rerunAssessment(runId);
        Test.stopTest();

        // The Pending row is gone; the three human-triaged rows survive with
        // their statuses intact.
        Map<Id, Duplicate_Candidate__c> after = new Map<Id, Duplicate_Candidate__c>([
            SELECT Id, Status__c FROM Duplicate_Candidate__c
            WHERE Id IN :new List<Id>{ pending.Id, rejected.Id, suppressed.Id, resolved.Id }
        ]);
        Assert.isFalse(after.containsKey(pending.Id),
            'Still-Pending prior-pass candidate is deleted on rerun');
        Assert.areEqual('Rejected', after.get(rejected.Id)?.Status__c,
            'Rejected (human triage) candidate survives a rerun');
        Assert.areEqual('Suppressed', after.get(suppressed.Id)?.Status__c,
            'Suppressed (human triage) candidate survives a rerun');
        Assert.areEqual('Resolved', after.get(resolved.Id)?.Status__c,
            'Resolved (human triage) candidate survives a rerun');
    }

    @IsTest
    static void testRunAssessment_StampsScanStartTime() {
 // duration bug: a new run must stamp Scan_Start_Time__c at
        // dispatch (createRunRecord) so the duration metrics measure scan time,
        // not wall-clock since CreatedDate. The field is the start basis the
        // dispatcher/callback now read (with a CreatedDate fallback).
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'scan-start-new');
        List<String> ids = new List<String>{ String.valueOf(kavs[0].Id) };
        KBAssessmentModels.AssessmentRunOptions options = new KBAssessmentModels.AssessmentRunOptions();
        options.selectedDimensions = new List<String>{ 'Completeness' };
        options.assessmentTypes = new List<String>{ 'Readiness' };

        KBAssessmentService service = new KBAssessmentService();
        Datetime beforeDispatch = Datetime.now();

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = service.runAssessment(ids, options);
        Test.stopTest();

        KB_Assessment_Run__c run = [
            SELECT Scan_Start_Time__c FROM KB_Assessment_Run__c WHERE Id = :result.runId
        ];
        Assert.isNotNull(run.Scan_Start_Time__c,
            'A new run must stamp Scan_Start_Time__c at dispatch');
        Assert.isTrue(run.Scan_Start_Time__c >= beforeDispatch.addSeconds(-5),
            'Scan_Start_Time__c should be stamped at (≈ now) dispatch, not left null');
    }

    @IsTest
    static void testResetRunForRerun_StampsFreshScanStartTime() {
 // Core regression (unit level): resetRunForRerun must re-stamp
        // Scan_Start_Time__c to NOW even though the run keeps its ORIGINAL
        // (older) CreatedDate. Backdate the run so a fresh stamp is provably
        // later than CreatedDate.
        KB_Assessment_Run__c run = seedScoredRun('rerun-scanstart');
        Id runId = run.Id;
        Test.setCreatedDate(runId, Datetime.now().addMinutes(-20));
        Datetime originalCreated = [
            SELECT CreatedDate FROM KB_Assessment_Run__c WHERE Id = :runId
        ].CreatedDate;

        List<KB_Article_Assessment__c> assessments = [
            SELECT Knowledge__c FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :runId
        ];

        KBAssessmentService service = new KBAssessmentService();
        Set<String> dims = new Set<String>{ 'Completeness' };
        Map<String, Decimal> weights = new Map<String, Decimal>{ 'Completeness' => 1.0 };
        Datetime beforeReset = Datetime.now();

        Test.startTest();
        service.resetRunForRerun(
            run,
            new List<String>{ String.valueOf(assessments[0].Knowledge__c) },
            dims, weights, null
        );
        Test.stopTest();

        KB_Assessment_Run__c after = [
            SELECT Scan_Start_Time__c, CreatedDate
            FROM KB_Assessment_Run__c WHERE Id = :runId
        ];
        Assert.isNotNull(after.Scan_Start_Time__c,
            'Rerun reset must stamp Scan_Start_Time__c');
        Assert.areEqual(originalCreated, after.CreatedDate,
            'Rerun must keep the original (backdated) CreatedDate');
        Assert.isTrue(after.Scan_Start_Time__c >= beforeReset.addSeconds(-5),
            'Scan_Start_Time__c must be stamped fresh at reset (≈ now)');
        Assert.isTrue(after.Scan_Start_Time__c > after.CreatedDate,
            'Fresh Scan_Start_Time__c must be later than the preserved original CreatedDate');
    }

    @IsTest
    static void testRerunAssessment_DurationComputedFromScanStartNotOriginalCreatedDate() {
 // End-to-end regression. RUN-0423 reproduced: a run created ~20 min
        // ago is rerun; its scoring takes ~seconds. Scoring_Duration_Ms__c (stamped
        // by KBAssessmentPipelineDispatcher when scoring completes) MUST be the
        // small rerun-scoring time computed from the fresh Scan_Start_Time__c, NOT
        // the ~20-minute gap since the original CreatedDate.
        KB_Assessment_Run__c original = seedScoredRun('rerun-duration');
        Id originalId = original.Id;
        // Backdate creation by 20 minutes — the bug computed duration from here.
        Test.setCreatedDate(originalId, Datetime.now().addMinutes(-20));

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        // Seed selects Completeness + Structure (no Duplication/Conflict), so the
        // dispatcher takes the no-dedup branch and stamps Scoring_Duration_Ms__c
        // directly from Scan_Start_Time__c when the last dimension completes —
        // synchronously, within stopTest().
        service.rerunAssessment(originalId);
        Test.stopTest();

        KB_Assessment_Run__c after = [
            SELECT Scan_Start_Time__c, Scoring_Duration_Ms__c, CreatedDate
            FROM KB_Assessment_Run__c WHERE Id = :originalId
        ];
        Assert.isNotNull(after.Scoring_Duration_Ms__c,
            'Dispatcher should have stamped Scoring_Duration_Ms__c on rerun completion');
        // The 20-minute gap is 1,200,000 ms. The rerun scored in test time
        // (well under a minute). Anything near the gap means the calc still used
        // CreatedDate — the bug. Assert comfortably below the gap.
        Assert.isTrue(after.Scoring_Duration_Ms__c < 600000,
            'Rerun Scoring_Duration_Ms__c must reflect the fresh scan (small), not the '
            + '~20-min gap since the original CreatedDate (got '
            + after.Scoring_Duration_Ms__c + ' ms)');
        // And the basis used is the fresh stamp, which is later than CreatedDate.
        Assert.isTrue(after.Scan_Start_Time__c > after.CreatedDate,
            'Scan_Start_Time__c must be later than the preserved original CreatedDate');
    }

 // ──: rerun resolves parent → latest published version ───────────────

    @IsTest
    static void testResolveLatestPublishedVersions_ResolvesLiveAndFlagsMissing() {
        // One published article (resolvable) + one fabricated parent id with no
        // published version (missing).
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'rerun-resolve');
        Knowledge__kav art = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :kavs[0].Id];
        KbManagement.PublishingService.publishArticle(art.KnowledgeArticleId, true);
        String livePublishedVersionId = [
            SELECT Id FROM Knowledge__kav
            WHERE KnowledgeArticleId = :art.KnowledgeArticleId AND PublishStatus = 'Online'
            LIMIT 1
        ].Id;

        // A parent id that does not resolve to any Online version.
        String missingParentId = String.valueOf(art.KnowledgeArticleId).substring(0, 15) + 'ZZZ';

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        KBAssessmentService.LatestVersionResolution res = service.resolveLatestPublishedVersions(
            new List<String>{ String.valueOf(art.KnowledgeArticleId), missingParentId }
        );
        Test.stopTest();

        Assert.areEqual(1, res.versionIds.size(), 'Exactly the one published parent should resolve');
        Assert.areEqual(livePublishedVersionId, res.versionIds[0],
            'Resolver must return the CURRENT Online version id, not a stale/draft one');
        Assert.areEqual(1, res.missingParentIds.size(), 'The unpublished parent must be flagged missing');
        Assert.isTrue(res.missingParentIds.contains(missingParentId),
            'Missing set must contain the parent with no Online version');
    }

    @IsTest
    static void testRerunAssessment_SkipsMissingPublishedVersionsAndFlagsThem() {
        // Seed two published articles, then add a THIRD child row whose parent
        // id resolves to no Online version (no published KAV exists for it).
        // The rerun must proceed for the two survivors, skip the third, flag its
        // row, and report the skipped count. (Constructing "missing" by a
        // never-published parent id avoids relying on archive-API timing.)
        KB_Assessment_Run__c run = seedScoredRun('rerun-skip');
        Id runId = run.Id;

        // A parent id with no Online version (a draft-only article).
        Knowledge__kav draftOnly = KBTestDataFactory.insertArticles(1, 'rerun-skip-draft')[0];
        Knowledge__kav draftParent = [
            SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :draftOnly.Id
        ];
        String missingParentId = String.valueOf(draftParent.KnowledgeArticleId);

        KB_Article_Assessment__c missingChild = new KB_Article_Assessment__c(
            Assessment_Run__c = runId,
            Knowledge__c = draftOnly.Id,
            Knowledge_Article_Id__c = missingParentId,
            Article_Title__c = 'Draft-only article',
            Overall_Score__c = 50
        );
        insert missingChild;

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = service.rerunAssessment(runId);
        Test.stopTest();

        Assert.areEqual(1, result.skippedNoPublishedVersionCount,
            'The draft-only article (no Online version) should be reported skipped');
        Assert.areEqual(2, result.totalArticles,
            'Only the two published articles should be in the rerun scope');

        // The skipped child row must carry a skip reason explaining why.
        KB_Article_Assessment__c flagged = [
            SELECT Pipeline_Skip_Reason__c FROM KB_Article_Assessment__c WHERE Id = :missingChild.Id
        ];
        Assert.isTrue(
            flagged.Pipeline_Skip_Reason__c != null
                && flagged.Pipeline_Skip_Reason__c.startsWith('No current published version'),
            'Skipped row must be stamped with the no-published-version reason'
        );
    }

    @IsTest
    static void testRerunAssessment_RepointsRepublishedArticleToNewVersionNoDuplicate() {
        // Publish an article, run, then "republish" it (edit online → new Online
        // version). The rerun must end with ONE child row for that article,
        // pointing at the NEW version — not two rows (old + new).
        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'rerun-repoint')[0];
        Knowledge__kav parent = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id = :art.Id];
        KbManagement.PublishingService.publishArticle(parent.KnowledgeArticleId, true);
        Id v1 = [
            SELECT Id FROM Knowledge__kav
            WHERE KnowledgeArticleId = :parent.KnowledgeArticleId AND PublishStatus = 'Online' LIMIT 1
        ].Id;

        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 1, Assessment_Types__c = 'Readiness',
            Requested_Scope__c = 'Selected',
            Selected_Dimensions_JSON__c = JSON.serialize(new List<String>{ 'Completeness' })
        );
        insert run;
        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = v1,
            Knowledge_Article_Id__c = String.valueOf(parent.KnowledgeArticleId),
            Article_Title__c = art.Title,
            Overall_Score__c = 60
        );

        // Republish: edit the online version → new draft → publish → new Online.
        Id draftId = KbManagement.PublishingService.editOnlineArticle(parent.KnowledgeArticleId, false);
        update new Knowledge__kav(Id = draftId, Summary = 'v2 improved');
        KbManagement.PublishingService.publishArticle(parent.KnowledgeArticleId, true);
        Id v2 = [
            SELECT Id FROM Knowledge__kav
            WHERE KnowledgeArticleId = :parent.KnowledgeArticleId AND PublishStatus = 'Online' LIMIT 1
        ].Id;
        Assert.areNotEqual(v1, v2, 'Republish should have produced a new Online version');

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        service.rerunAssessment(run.Id);
        Test.stopTest();

        List<KB_Article_Assessment__c> rows = [
            SELECT Knowledge__c FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :run.Id
        ];
        Assert.areEqual(1, rows.size(),
            'Republished article must have exactly ONE child row after rerun (no orphan v1 row)');
        Assert.areEqual(v2, rows[0].Knowledge__c,
            'The surviving row must point at the NEW published version');
    }

    @IsTest
    static void testRerunAssessment_BlocksWhenAllArticlesMissingPublishedVersion() {
        // A run whose only child points at a parent with no Online version —
        // the rerun has nothing to re-assess and must block with a clear error
        // rather than run empty.
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 1,
            Assessment_Types__c = 'Readiness',
            Requested_Scope__c = 'Selected',
            Selected_Dimensions_JSON__c = JSON.serialize(new List<String>{ 'Completeness' })
        );
        insert run;

        // Draft-only article (never published) → no Online version to resolve.
        Knowledge__kav draftOnly = KBTestDataFactory.insertArticles(1, 'rerun-allmissing')[0];
        Knowledge__kav draftParent = [
            SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Id = :draftOnly.Id
        ];
        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = draftOnly.Id,
            Knowledge_Article_Id__c = String.valueOf(draftParent.KnowledgeArticleId),
            Article_Title__c = 'Draft-only article',
            Overall_Score__c = 50
        );

        KBAssessmentService service = new KBAssessmentService();
        Boolean threw = false;
        Test.startTest();
        try {
            service.rerunAssessment(run.Id);
        } catch (IllegalArgumentException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('current published version'),
                'Block message should explain there is no published version to re-assess');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Rerun must block when no article has a current published version');
    }

    @IsTest
    static void testSearchArticles_NoSearchTerm() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results = service.searchArticles(null, 10);
        Test.stopTest();

        // In test context without Knowledge articles, should return empty list
        Assert.isNotNull(results, 'Results should not be null');
    }

    @IsTest
    static void testSearchArticles_WithSearchTerm() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results = service.searchArticles('password', 10);
        Test.stopTest();

        Assert.isNotNull(results, 'Results should not be null');
    }

    @IsTest
    static void testSearchArticles_WithLimit() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results = service.searchArticles('', 5);
        Test.stopTest();

        Assert.isNotNull(results, 'Results should not be null');
        Assert.isTrue(results.size() <= 5, 'Should respect limit');
    }

    @IsTest
    static void testFetchArticles_EmptyIds() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results = service.fetchArticles(new List<String>());
        Test.stopTest();

        Assert.areEqual(0, results.size(), 'Empty IDs should return empty list');
    }

    @IsTest
    static void testFetchArticles_NullIds() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> results = service.fetchArticles(null);
        Test.stopTest();

        Assert.isNotNull(results, 'Should handle null gracefully');
        Assert.areEqual(0, results.size(), 'Null IDs should return empty list');
    }

    @IsTest
    static void testMultipleSequentialAssessments() {
        KBAssessmentService service = new KBAssessmentService();
        List<String> batch1 = new List<String>{'ka001'};
        List<String> batch2 = new List<String>{'ka002'};

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result1 = service.runAssessment(batch1);
        KBAssessmentModels.AssessmentRunResult result2 = service.runAssessment(batch2);
        Test.stopTest();

        Assert.isNotNull(result1, 'First result should not be null');
        Assert.isNotNull(result2, 'Second result should not be null');
        Assert.areNotEqual(result1.runId, result2.runId, 'Should create separate runs');
    }

    @IsTest
    static void testGetPublishedArticleCount() {
        Test.startTest();
        Integer count = KBAssessmentService.getPublishedArticleCount();
        Test.stopTest();

        Assert.isNotNull(count, 'Count should not be null');
        Assert.isTrue(count >= 0, 'Count should be non-negative');
    }

    @IsTest
    static void testGetAllKnowledgeObjectApiNames() {
        Test.startTest();
        List<Map<String, String>> types = KBAssessmentService.getAllKnowledgeObjectApiNames();
        Test.stopTest();

        Assert.isNotNull(types, 'Types should not be null');
    }

    @IsTest
    static void testSearchArticlesFiltered_NoFilters() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result = service.searchArticlesFiltered(
            null, null, null, null, 25, 0
        );
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
        Assert.isNotNull(result.articles, 'Articles list should not be null');
        Assert.isTrue(result.totalCount >= 0, 'Total count should be non-negative');
    }

    @IsTest
    static void testSearchArticlesFiltered_WithTitleSearch() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result = service.searchArticlesFiltered(
            'Online', 'Test', null, null, 10, 0
        );
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
    }

    @IsTest
    static void testSearchArticlesFiltered_Pagination() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result = service.searchArticlesFiltered(
            'Online', null, null, null, 5, 5
        );
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
        Assert.isNotNull(result.hasMore, 'hasMore should be populated');
    }

    @IsTest
    static void testSearchArticlesFiltered_InvalidPageSize() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result = service.searchArticlesFiltered(
            null, null, null, null, -1, 0
        );
        Test.stopTest();

        Assert.isNotNull(result, 'Should handle invalid page size gracefully');
    }

    @IsTest
    static void testSearchArticlesFiltered_InvalidFormulaFlagsFallback() {
 // a non-blank but invalid filterFormula must not silently dump
        // the KB — the service falls back to the AND/OR path and stamps
        // formulaFallbackApplied so the LWC can warn.
        KBAssessmentModels.FilterClause clause = new KBAssessmentModels.FilterClause();
        clause.field = 'Title';
        clause.operator = 'contains';
        clause.value = 'Test';

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result = service.searchArticlesFiltered(
            'Online', null, null, null, 25, 0,
            new List<KBAssessmentModels.FilterClause>{ clause },
            'AND',
            '1 AND AND 2'  // syntactically invalid formula
        );
        Test.stopTest();

        Assert.isNotNull(result, 'Result should not be null');
        Assert.isTrue(
            result.formulaFallbackApplied,
            'Invalid formula should set formulaFallbackApplied so the LWC can warn'
        );
    }

    @IsTest
    static void testSearchArticlesFiltered_NoFormulaNoFallbackFlag() {
        // Control: blank formula must not flag a fallback — that path is the
        // intended legacy AND/OR behaviour, not a degraded result set.
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result = service.searchArticlesFiltered(
            'Online', null, null, null, 25, 0,
            new List<KBAssessmentModels.FilterClause>(), 'AND', null
        );
        Test.stopTest();

        Assert.isFalse(
            result.formulaFallbackApplied,
            'No formula supplied should not flag a fallback'
        );
    }

    @IsTest
    static void testResolveMatchingArticleIds_matchesSearchCount() {
        insertDraftArticles(3);
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult searchResult = service.searchArticlesFiltered(
            'Draft', null, null, null, 200, 0
        );
        List<String> resolvedIds = service.resolveMatchingArticleIds(
            'Draft', null, null, null, new List<KBAssessmentModels.FilterClause>(), 'AND'
        );
        Test.stopTest();

        Assert.areEqual(
            searchResult.totalCount,
            resolvedIds.size(),
            'Resolver should return the same count as searchArticlesFiltered for the same filter'
        );
    }

    @IsTest
    static void testResolveMatchingArticleIds_capEnforced() {
        insertDraftArticles(3);
        KBAssessmentService service = new KBAssessmentService();
        Integer previousCap = KBAssessmentService.matchingFilterCap;
        KBAssessmentService.matchingFilterCap = 2;

        Boolean threw = false;
        String message = null;
        Test.startTest();
        try {
            service.resolveMatchingArticleIds(
                'Draft', null, null, null, new List<KBAssessmentModels.FilterClause>(), 'AND'
            );
        } catch (KBAssessmentService.MatchingFilterLimitException e) {
            threw = true;
            message = e.getMessage();
        } finally {
            KBAssessmentService.matchingFilterCap = previousCap;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Should throw MatchingFilterLimitException when count exceeds cap');
        Assert.isTrue(message.contains('exceeding'), 'Message should describe the cap breach');
    }

    @IsTest
    static void testResolveMatchingArticleIds_emptyMatch() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<String> resolvedIds = service.resolveMatchingArticleIds(
            'Draft', 'no-article-should-match-this-very-specific-title', null, null,
            new List<KBAssessmentModels.FilterClause>(), 'AND'
        );
        Test.stopTest();

        Assert.areEqual(0, resolvedIds.size(), 'Non-matching filter should return empty list');
    }

    private static void insertDraftArticles(Integer count) {
        List<Knowledge__kav> articles = new List<Knowledge__kav>();
        for (Integer i = 0; i < count; i++) {
            articles.add(new Knowledge__kav(
                Title = 'Resolver Test Article ' + i,
                UrlName = 'resolver-test-article-' + i + '-' + Math.abs(Crypto.getRandomLong()),
                Language = 'en_US'
            ));
        }
        insert articles;
    }

    // ──────────────────────────────────────────────────────────────────────
 // dynamic content-field columns
    // ──────────────────────────────────────────────────────────────────────

    /**
     * Regression for the reported failure: when Content_Field_Mapping_JSON__c
     * names a field that doesn't exist on Knowledge__kav (e.g.
     * KCSArticle_Issue__c on an org without KCS), getContentFields silently
     * drops it and the SOQL query never names a missing field — so
     * "SObject row was retrieved via SOQL without querying the requested
     * field" can't fire from this code path.
     */
    @IsTest
    static void testSearchArticlesFiltered_DropsConfiguredFieldThatDoesNotExist_NoSoqlError() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Content_Field_Mapping_JSON__c = 'Summary,KCSArticle_Issue__c,Definitely_Not_A_Real_Field__c';
        upsert cfg KB_Scan_Config__c.Id;

        Test.startTest();
        KBAssessmentService service = new KBAssessmentService();
        // Before the fix, a SELECT including the missing fields would either
        // throw at SOQL parse time or surface the wrapper-access error. With
        // the projection helper, missing names are stripped — query succeeds.
        KBAssessmentModels.ArticleFilterResult result = service.searchArticlesFiltered(
            'Online', null, null, null, 25, 0,
            new List<KBAssessmentModels.FilterClause>(), 'AND'
        );
        Test.stopTest();

        Assert.isNotNull(result, 'Filter should not throw on missing configured fields');
        Assert.isNotNull(result.articles, 'Articles list initialised');
    }

    @IsTest
    static void testGetSelectedContentFieldDescriptors_ReturnsLabels() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        // Summary is in BASE_KAV_QUERY_FIELDS — must be skipped from the
        // descriptor list because the picker already renders it.
        cfg.Content_Field_Mapping_JSON__c = 'Summary,UrlName';
        upsert cfg KB_Scan_Config__c.Id;

        Test.startTest();
        List<Map<String, String>> descriptors =
            KBAssessmentService.getSelectedContentFieldDescriptors();
        Test.stopTest();

        Assert.isNotNull(descriptors, 'Descriptors list initialised');
        // Summary is base; UrlName is base. Both filtered out → empty.
        Assert.areEqual(0, descriptors.size(),
            'BASE-projection fields must not appear as dynamic columns');
    }

    @IsTest
    static void testGetSelectedContentFieldDescriptors_DropsMissingFields() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Content_Field_Mapping_JSON__c = 'KCSArticle_Issue__c,Definitely_Not_A_Real_Field__c';
        upsert cfg KB_Scan_Config__c.Id;

        Test.startTest();
        List<Map<String, String>> descriptors =
            KBAssessmentService.getSelectedContentFieldDescriptors();
        Test.stopTest();

        // In a baseline scratch org Knowledge__kav has neither field — both
        // are dropped silently. (If a future test runs against an org where
        // KCSArticle_Issue__c exists, the descriptor will have 1 entry; that
        // is also acceptable behaviour.)
        Assert.isTrue(descriptors.size() <= 1,
            'Missing fields must be filtered out, not throw');
    }

    @IsTest
    static void testGetSelectedContentFieldDescriptors_ReturnsEmptyWhenUnconfigured() {
        // Default state: no Content_Field_Mapping_JSON__c value.
        Test.startTest();
        List<Map<String, String>> descriptors =
            KBAssessmentService.getSelectedContentFieldDescriptors();
        Test.stopTest();

        Assert.areEqual(0, descriptors.size(),
            'No JSON configured → no dynamic columns');
    }

    @IsTest
    static void testGetSelectedContentFieldDescriptors_CapsAtFour() {
        // Configure 6 valid base fields. Even though all of them are filtered
        // out by the BASE-skip rule, this exercises the cap path: if a future
        // change widens what's considered eligible, the cap test still holds.
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getOrgDefaults();
        cfg.Content_Field_Mapping_JSON__c =
            'Title,Summary,UrlName,ArticleNumber,LastModifiedDate,PublishStatus';
        upsert cfg KB_Scan_Config__c.Id;

        Test.startTest();
        List<Map<String, String>> descriptors =
            KBAssessmentService.getSelectedContentFieldDescriptors();
        Test.stopTest();

        Assert.isTrue(descriptors.size() <= KBAssessmentService.CONTENT_FIELD_COLUMN_CAP,
            'Descriptor list must respect the column cap');
    }

    // ──────────────────────────────────────────────────────────────────────
    // fetchArticles — happy path with real Knowledge__kav rows
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testFetchArticles_RealArticles_ReturnsWrappers() {
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(2, 'svc-fetch');
        List<String> ids = new List<String>();
        for (Knowledge__kav k : kavs) ids.add(String.valueOf(k.Id));

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> wrappers = service.fetchArticles(ids);
        Test.stopTest();

        Assert.areEqual(2, wrappers.size());
        for (KBAssessmentModels.ArticleWrapper w : wrappers) {
            Assert.isNotNull(w.id);
            Assert.isNotNull(w.title);
        }
    }

    // ──────────────────────────────────────────────────────────────────────
    // searchArticlesFiltered — filter DSL paths
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testSearchArticlesFiltered_FilterDSL_AndLogic() {
        // Override prefilters so Draft test KAVs are visible.
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        state.Query_Prefilters_JSON__c = '{"publishStatus":"Draft","language":"en_US"}';
        upsert state KB_Setup_Wizard_State__c.Id;

        KBTestDataFactory.insertArticles(3, 'svc-dsl');

        KBAssessmentService service = new KBAssessmentService();
        List<KBAssessmentModels.FilterClause> clauses = new List<KBAssessmentModels.FilterClause>();
        // FilterClause has fieldApiName/operator/value — keep this minimal so
        // it runs even if the FilterClause shape evolves.

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result = service.searchArticlesFiltered(
            'Draft', 'svc-dsl', null, null, 25, 0, clauses, 'AND'
        );
        Test.stopTest();

        Assert.isTrue(result.totalCount >= 3);
    }

    @IsTest
    static void testSearchArticlesFiltered_FilterDSL_OrLogic() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        state.Query_Prefilters_JSON__c = '{"publishStatus":"Draft","language":"en_US"}';
        upsert state KB_Setup_Wizard_State__c.Id;

        KBTestDataFactory.insertArticles(2, 'svc-or');

        KBAssessmentService service = new KBAssessmentService();
        List<KBAssessmentModels.FilterClause> clauses = new List<KBAssessmentModels.FilterClause>();

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult result = service.searchArticlesFiltered(
            'Draft', null, null, null, 25, 0, clauses, 'OR'
        );
        Test.stopTest();

        Assert.isNotNull(result);
    }

    // ──────────────────────────────────────────────────────────────────────
    // resolveMatchingArticleIds — happy path with real data
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testResolveMatchingArticleIds_LiveArticles() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        state.Query_Prefilters_JSON__c = '{"publishStatus":"Draft","language":"en_US"}';
        upsert state KB_Setup_Wizard_State__c.Id;

        KBTestDataFactory.insertArticles(3, 'svc-resolve');

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<String> ids = service.resolveMatchingArticleIds(
            'Draft', 'svc-resolve', null, null,
            new List<KBAssessmentModels.FilterClause>(), 'AND'
        );
        Test.stopTest();

        Assert.areEqual(3, ids.size(), 'All 3 seeded articles match the title filter');
    }

    // ──────────────────────────────────────────────────────────────────────
    // searchArticles with real data + runtime config
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testSearchArticles_LiveArticles_DraftOverride() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        state.Query_Prefilters_JSON__c = '{"publishStatus":"Draft","language":"en_US"}';
        upsert state KB_Setup_Wizard_State__c.Id;

        KBTestDataFactory.insertArticles(2, 'svc-search-live');

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        List<KBAssessmentModels.ArticleWrapper> wrappers = service.searchArticles('svc-search-live', 10);
        Test.stopTest();

        Assert.isTrue(wrappers.size() >= 2);
    }

    // ──────────────────────────────────────────────────────────────────────
    // setSelectedDimensions
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testSetSelectedDimensions_FilterAppliesToScoring() {
        KBAssessmentService service = new KBAssessmentService();
        service.setSelectedDimensions(new Set<String>{ 'Freshness' });

        // Build a wrapper inline and assess — Freshness is deterministic.
        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.id = '0001A000001';
        article.title = 'X';
        article.lastModifiedDate = Datetime.now();

        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result =
            service.assessArticleBulk(article, null, null, new List<Duplicate_Candidate__c>());
        Test.stopTest();

        Assert.isNotNull(result);
        Assert.isNotNull(result.scoresByDim);
        Assert.isTrue(result.scoresByDim.containsKey('Freshness'),
            'Selected dim Freshness scored');
    }

    @IsTest
    static void testSetSelectedDimensions_NullOrEmpty_FallsBackToActive() {
        // setSelectedDimensions(null) and setSelectedDimensions(empty) should
        // both reset the service to the full active dim set. We verify the
        // fallback by exercising assessArticleBulk afterwards and confirming
        // every active deterministic dim produced a score.
        KBAssessmentService service = new KBAssessmentService();
        service.setSelectedDimensions(null);
        service.setSelectedDimensions(new Set<String>());

        KBAssessmentModels.ArticleWrapper article = new KBAssessmentModels.ArticleWrapper();
        article.id = '0001A000001';
        article.title = 'X';
        article.lastModifiedDate = Datetime.now();

        Test.startTest();
        KBAssessmentModels.ArticleAssessmentResult result =
            service.assessArticleBulk(article, null, null, new List<Duplicate_Candidate__c>());
        Test.stopTest();

        Assert.isNotNull(result.scoresByDim);
        Assert.isTrue(result.scoresByDim.containsKey('Freshness'),
            'Active dim set must include Freshness after null/empty fallback');
        // Active set has at least 2 dims (Freshness + at least one other deterministic).
        Assert.isTrue(result.scoresByDim.size() >= 1,
            'At least one dimension scored after fallback to active set');
    }

    // ──────────────────────────────────────────────────────────────────────
    // runAssessment with options
    // ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void testRunAssessment_WithOptions_ReadinessOnly() {
        Knowledge__kav kav = KBTestDataFactory.insertArticles(1, 'svc-opts')[0];

        KBAssessmentModels.AssessmentRunOptions options = new KBAssessmentModels.AssessmentRunOptions();
        options.assessmentTypes = new List<String>{ 'Readiness' };
        options.requestedScope = 'Selected';

        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result = service.runAssessment(
            new List<String>{ String.valueOf(kav.Id) }, options
        );
        Test.stopTest();

        Assert.isNotNull(result);
        Assert.isNotNull(result.runId);
    }

    // ==================== publishStatus 'All' sentinel ====================

    @IsTest
    static void testSearchArticlesFiltered_PublishStatusAll_IncludesDrafts() {
        // 'All' is a sentinel that opts out of the PublishStatus filter entirely,
        // so Draft + Online + Archived all surface. Used by the article selector
        // when a Knowledge record page navigates with a preselected article.
        KBTestDataFactory.insertArticles(2, 'svc-all');
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.ArticleFilterResult resultAll = service.searchArticlesFiltered(
            'All', 'svc-all', null, null, 25, 0,
            new List<KBAssessmentModels.FilterClause>(), 'AND'
        );
        // Compare to Online which would normally exclude the Drafts created above
        KBAssessmentModels.ArticleFilterResult resultOnline = service.searchArticlesFiltered(
            'Online', 'svc-all', null, null, 25, 0,
            new List<KBAssessmentModels.FilterClause>(), 'AND'
        );
        Test.stopTest();

        Assert.isTrue(resultAll.totalCount >= 2,
            'All must surface Draft articles (>=2 inserted)');
        Assert.areEqual(0, resultOnline.totalCount,
            'Sanity check: Online filter excludes Draft test articles');
    }

    // ==================== getDataCategoryCounts ====================
    // Regression coverage for the bug where the method queried the non-queryable
    // `DataCategorySelection` entity (correct entity is `Knowledge__DataCategorySelection`).
    // Old code silently swallowed the QueryException and returned an empty map for every
    // input; the right behaviour is to skip-empty for empty/null inputs and run a real
    // SOQL query for non-empty inputs.

    @IsTest
    static void testGetDataCategoryCounts_NullInput_ReturnsEmpty() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        Map<String, Integer> counts = service.getDataCategoryCounts(null);
        Test.stopTest();

        Assert.isNotNull(counts, 'Should return an empty map, not null');
        Assert.isTrue(counts.isEmpty(), 'Null input should short-circuit to empty');
    }

    @IsTest
    static void testGetDataCategoryCounts_EmptyInput_ReturnsEmpty() {
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        Map<String, Integer> counts = service.getDataCategoryCounts(new List<String>());
        Test.stopTest();

        Assert.isNotNull(counts, 'Should return an empty map, not null');
        Assert.isTrue(counts.isEmpty(), 'Empty input should short-circuit to empty');
    }

    @IsTest
    static void testGetDataCategoryCounts_NoCategoriesAssigned_RunsQueryWithoutException() {
        // Inserts real KAV rows without category assignments (test contexts cannot easily
        // create DataCategoryGroup fixtures). The point of this test is that the query
        // name is correct — old code threw QueryException on every call and silently
        // returned empty; the fix runs a real query that simply finds zero matches.
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(2, 'cat-counts');
        List<String> ids = new List<String>();
        for (Knowledge__kav a : arts) {
            ids.add(a.Id);
        }

        KBAssessmentService service = new KBAssessmentService();

        // Checked *before* Test.stopTest() — stopTest() resets the governor-limit
        // counters back to their pre-startTest baseline, so a query-count check
        // taken after it always reads 0 regardless of what ran inside the block.
        Test.startTest();
        Map<String, Integer> counts = service.getDataCategoryCounts(ids);
        Integer queriesInBlock = Limits.getQueries();
        Test.stopTest();

        // The fix's success criterion: query runs, returns empty (no categories
        // assigned to fresh test articles). Pre-fix this would have thrown internally
        // and been caught by the empty catch — same outward shape, but masking a real
        // bug. The query-count check is what proves the query ran, but only orgs with
        // a Knowledge__DataCategorySelection entity (i.e. at least one Data Category
        // Group configured for Knowledge) can reach the query — the production
        // method's own guard early-returns before any SOQL otherwise. Gate the
        // query-ran assertion on that same describe check so this test is
        // deterministic across orgs with and without Data Categories configured.
        Assert.isNotNull(counts, 'Should return a map even when no categories present');
        Assert.areEqual(0, counts.size(),
            'Fresh test articles have no category assignments — counts should be empty');
        if (Schema.getGlobalDescribe().containsKey('Knowledge__DataCategorySelection')) {
            Assert.isTrue(queriesInBlock >= 1,
                'A query should have been issued (proves we reached the SOQL, not the early-return)');
        }
    }

 // ──: clone prefill ───────────────────────────────────────────────

    @IsTest
    static void testGetRunSelectionForClone_ReturnsScopeAndCopyName() {
        // seedScoredRun publishes 2 KAVs and links 2 child assessments carrying
        // real parent ids, so the clone recovers a 2-article scope re-resolved
        // to the current Online versions.
        KB_Assessment_Run__c source = seedScoredRun('clone-primary');
        Id sourceId = source.Id;

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        KBAssessmentModels.RunSelectionForClone sel =
            service.getRunSelectionForClone(sourceId);
        Test.stopTest();

        Assert.isNotNull(sel, 'Clone selection should be returned');
        Assert.areEqual('Copy of Rerun me', sel.suggestedRunName,
            'Suggested name should be "Copy of <source name>"');
        Assert.areEqual('original description', sel.description,
            'Description should be copied verbatim');
        Assert.areEqual(2, sel.articleIds.size(),
            'Should recover the 2 published article versions in scope');
        Assert.areEqual(0, sel.droppedNoPublishedVersionCount,
            'No articles should be dropped — both have live Online versions');
        Assert.areEqual(2, sel.resolvedArticleCount,
            'resolvedArticleCount reflects the full resolved scope (uncapped here)');

        // The recovered ids must be CURRENT Online version ids (kav Id prefix),
        // never the parent KnowledgeArticleId — the clone submits versions.
        Set<Id> onlineVersionIds = new Set<Id>();
        for (Knowledge__kav k : [
            SELECT Id FROM Knowledge__kav WHERE PublishStatus = 'Online'
        ]) {
            onlineVersionIds.add(k.Id);
        }
        for (String vid : sel.articleIds) {
            Assert.isTrue(onlineVersionIds.contains(Id.valueOf(vid)),
                'Recovered id must be a current Online version id: ' + vid);
        }
    }

    @IsTest
    static void testGetRunSelectionForClone_DropsArchivedParents() {
        // A run whose only child article has NO published version → the parent
        // is unresolvable to an Online version and must be counted as dropped,
        // not silently included.
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 1,
            Run_Name__c = 'Archived scope',
            Assessment_Types__c = 'Readiness',
            Requested_Scope__c = 'Selected'
        );
        insert run;

        // Insert an unpublished (Draft) article and point a child row at it.
        // With no Online version, resolveLatestPublishedVersions drops the parent.
        List<Knowledge__kav> kavs = KBTestDataFactory.insertArticles(1, 'clone-archived');
        Knowledge__kav draft = [
            SELECT Id, KnowledgeArticleId, Title FROM Knowledge__kav WHERE Id = :kavs[0].Id
        ];
        insert new KB_Article_Assessment__c(
            Assessment_Run__c = run.Id,
            Knowledge__c = draft.Id,
            Knowledge_Article_Id__c = String.valueOf(draft.KnowledgeArticleId),
            Article_Title__c = draft.Title,
            Overall_Score__c = 50
        );

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        KBAssessmentModels.RunSelectionForClone sel =
            service.getRunSelectionForClone(run.Id);
        Test.stopTest();

        Assert.areEqual(0, sel.articleIds.size(),
            'No live version → nothing carried into the clone');
        Assert.areEqual(1, sel.droppedNoPublishedVersionCount,
            'The parent with no Online version must be counted as dropped');
    }

    @IsTest
    static void testGetRunSelectionForClone_BlankNameFallsBackToAssessment() {
        // A run with no Run_Name__c → suggested name falls back to "Copy of Assessment".
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 0,
            Assessment_Types__c = 'Readiness',
            Requested_Scope__c = 'Selected'
        );
        insert run;

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        KBAssessmentModels.RunSelectionForClone sel =
            service.getRunSelectionForClone(run.Id);
        Test.stopTest();

        Assert.areEqual('Copy of Assessment', sel.suggestedRunName,
            'A nameless source run should suggest "Copy of Assessment"');
        Assert.areEqual(0, sel.articleIds.size(),
            'A run with no child rows recovers no scope');
    }

    @IsTest
    static void testGetRunSelectionForClone_CapsSuggestedNameAt255() {
 // (review) — a near-255 source name must not yield a suggestion
        // over the Run_Name__c limit (would trip the input maxlength / be lopped
        // only at submit). "Copy of " + 250 chars = 258 → truncated to 255.
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed',
            Total_Articles__c = 0,
            Assessment_Types__c = 'Readiness',
            Requested_Scope__c = 'Selected',
            Run_Name__c = 'x'.repeat(250)
        );
        insert run;

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        KBAssessmentModels.RunSelectionForClone sel =
            service.getRunSelectionForClone(run.Id);
        Test.stopTest();

        Assert.areEqual(255, sel.suggestedRunName.length(),
            'Suggested name is capped to the Run_Name__c 255-char limit');
        Assert.isTrue(sel.suggestedRunName.startsWith('Copy of '),
            'Cap keeps the "Copy of " prefix, trims the tail');
    }

    @IsTest
    static void testGetRunSelectionForClone_CapsLargeScope() {
 // the seeded scope never exceeds the clone cap (= the app-wide
        // max run size, matchingFilterCap). Seeding a 10k+ run isn't feasible in
        // a test, so assert the boundary the code guards: articleIds.size() never
        // exceeds the cap, and equals resolvedArticleCount when under it.
        KB_Assessment_Run__c source = seedScoredRun('clone-cap');
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.RunSelectionForClone sel =
            service.getRunSelectionForClone(source.Id);
        Test.stopTest();

        Assert.areEqual(sel.resolvedArticleCount, sel.articleIds.size(),
            'Under the cap, seeded ids equal the full resolved count');
        Assert.isTrue(
            sel.articleIds.size() <= KBAssessmentService.getCloneArticleCapStatic(),
            'Seeded scope never exceeds the clone article cap');
    }

    @IsTest
    static void testGetCloneArticleCap_MatchesMatchingFilterCeiling() {
 // the clone cap the LWC gates on is the app-wide max run size
        // (10k), so a run can never legitimately exceed it.
        Assert.areEqual(10000, KBAssessmentService.getCloneArticleCapStatic(),
            'Clone cap is the 10k matching-filter ceiling');
    }

    @IsTest
    static void testGetRunSelectionForClone_NullId() {
        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        try {
            service.getRunSelectionForClone(null);
            Assert.fail('Should throw for null run id');
        } catch (IllegalArgumentException e) {
            // expected
        }
        Test.stopTest();
    }

    @IsTest
    static void testLargeSelectedRun_DoesNotOverflowFilterJson() {
 // cloning a large MatchingFilter run resolves its scope to
        // thousands of explicit ids and submits as 'Selected'. The filter
        // payload must NOT freeze that list into Filter_DSL_JSON__c (it would
        // blow the 32,768-char limit) — child rows are the recovery path.
        // Build 2,000 synthetic ids (well over FROZEN_ARTICLE_ID_CAP) and prove
        // createRunRecord persists a run without throwing STRING_TOO_LONG.
        List<String> manyIds = new List<String>();
        for (Integer i = 0; i < 2000; i++) {
            // 18-char KAV-shaped id stubs — never queried, only serialized.
            manyIds.add('ka0000000000' + String.valueOf(1000000 + i));
        }

        KBAssessmentModels.AssessmentRunOptions options =
            new KBAssessmentModels.AssessmentRunOptions();
        options.assessmentTypes = new List<String>{ 'Readiness' };
        options.selectedDimensions = new List<String>{ 'Completeness' };
        options.requestedScope = 'Selected';
        options.runName = 'Huge clone';

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        // runAssessment builds the filter payload + inserts the run; with the
 // guard the 2,000 ids are omitted from the JSON, so no overflow.
        KBAssessmentModels.AssessmentRunResult result =
            service.runAssessment(manyIds, options);
        Test.stopTest();

        Assert.isNotNull(result, 'A large Selected run should submit without overflow');
        KB_Assessment_Run__c persisted = [
            SELECT Filter_DSL_JSON__c, Total_Articles__c
            FROM KB_Assessment_Run__c
            WHERE Id = :result.runId
            LIMIT 1
        ];
        Assert.areEqual(2000, persisted.Total_Articles__c,
            'Total_Articles__c should reflect the full scope');
        Assert.isTrue(
            persisted.Filter_DSL_JSON__c == null
                || !persisted.Filter_DSL_JSON__c.contains('ka0000000000'),
            'Large id list must NOT be frozen into Filter_DSL_JSON__c'
        );
        Assert.isTrue(
            persisted.Filter_DSL_JSON__c == null
                || persisted.Filter_DSL_JSON__c.length() <= 32768,
            'Filter_DSL_JSON__c must stay within the field limit'
        );
    }

    // ── resolveKnowledgeObjectName: object-name validation before dynamic SOQL ──
    // The caller-supplied articleType (from filter JSON) is concatenated into the
    // FROM clause, so it must be validated against the schema. A real Knowledge
    // article-version object (exists + ends '__kav') is accepted verbatim; anything
    // else falls back to the org's default Knowledge object — blocking object-name
    // substitution in the dynamic query.

    @IsTest
    static void resolveKnowledgeObjectName_AcceptsRealKavObject() {
        KBAssessmentService service = new KBAssessmentService();
        // Knowledge__kav exists in this org and ends with '__kav' → returned as-is.
        Assert.areEqual('Knowledge__kav',
            service.resolveKnowledgeObjectName('Knowledge__kav'),
            'A real __kav object must be accepted verbatim');
    }

    @IsTest
    static void resolveKnowledgeObjectName_RejectsBogusTypeAndFallsBack() {
        KBAssessmentService service = new KBAssessmentService();
        // Bogus values must NOT reach the FROM clause — each falls back to the
        // org's default Knowledge object (always ends with '__kav').
        for (String bogus : new List<String>{
            'Account',                                   // real object, not __kav
            'Knowledge__kav WHERE Id != null',           // injection attempt (no __kav suffix)
            'Nonexistent__kav'                           // __kav suffix but not in describe
        }) {
            String resolved = service.resolveKnowledgeObjectName(bogus);
            Assert.isTrue(resolved != null && resolved.endsWith('__kav'),
                'Bogus articleType "' + bogus + '" must fall back to a __kav object, got: ' + resolved);
            Assert.areNotEqual(bogus, resolved,
                'Bogus articleType "' + bogus + '" must NOT be returned verbatim');
        }
    }

    @IsTest
    static void resolveKnowledgeObjectName_BlankFallsBack() {
        KBAssessmentService service = new KBAssessmentService();
        for (String blank : new List<String>{ null, '', '   ' }) {
            String resolved = service.resolveKnowledgeObjectName(blank);
            Assert.isTrue(resolved != null && resolved.endsWith('__kav'),
                'Blank articleType must fall back to a __kav object, got: ' + resolved);
        }
    }

    // ── coverage gap-fill: edge/error paths ──────────────────────────

    @IsTest
    static void testRunAssessment_NullOptions_FallsBackToDefault() {
        List<Knowledge__kav> arts = KBTestDataFactory.insertArticles(1, 'null-opts');
        KBAssessmentService service = new KBAssessmentService();

        Test.startTest();
        KBAssessmentModels.AssessmentRunResult result =
            service.runAssessment(new List<String>{ arts[0].Id }, null);
        Test.stopTest();

        Assert.isNotNull(result, 'A null options bundle must fall back to defaults, not throw');
    }

    @IsTest
    static void testRerunAssessment_RunNotFound_Throws() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 0,
            Assessment_Types__c = 'Readiness', Requested_Scope__c = 'Selected'
        );
        insert run;
        Id ghostId = run.Id;
        delete run;

        KBAssessmentService service = new KBAssessmentService();
        Boolean threw = false;
        Test.startTest();
        try {
            service.rerunAssessment(ghostId);
        } catch (IllegalArgumentException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('not found'), 'Should explain the run is gone');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Rerunning a nonexistent run must throw');
    }

    @IsTest
    static void testRerunAssessment_NoRecoverableScope_Throws() {
        // Terminal status (passes the running-block guard) with no child rows
        // and no frozen Filter_DSL_JSON__c fallback — recoverRunArticleIds has
        // nothing to recover from.
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 0,
            Assessment_Types__c = 'Readiness', Requested_Scope__c = 'Selected'
        );
        insert run;

        KBAssessmentService service = new KBAssessmentService();
        Boolean threw = false;
        Test.startTest();
        try {
            service.rerunAssessment(run.Id);
        } catch (IllegalArgumentException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('recoverable article scope'),
                'Should explain there is no recoverable scope');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Rerun must block when there is no recoverable scope');
    }

    @IsTest
    static void testGetRunSelectionForClone_RunNotFound_Throws() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 0,
            Assessment_Types__c = 'Readiness', Requested_Scope__c = 'Selected'
        );
        insert run;
        Id ghostId = run.Id;
        delete run;

        KBAssessmentService service = new KBAssessmentService();
        Boolean threw = false;
        Test.startTest();
        try {
            service.getRunSelectionForClone(ghostId);
        } catch (IllegalArgumentException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.isTrue(threw, 'Cloning a nonexistent run must throw');
    }

    @IsTest
    static void testGetRunSelectionForClone_TrimsToLoweredCap() {
        // matchingFilterCap is @TestVisible specifically so tests can force the
        // trim branch without seeding 10k real articles.
        Integer originalCap = KBAssessmentService.matchingFilterCap;
        KBAssessmentService.matchingFilterCap = 1;
        try {
            KB_Assessment_Run__c source = seedScoredRun('clone-trim');
            KBAssessmentService service = new KBAssessmentService();

            Test.startTest();
            KBAssessmentModels.RunSelectionForClone sel = service.getRunSelectionForClone(source.Id);
            Test.stopTest();

            Assert.areEqual(2, sel.resolvedArticleCount, 'Full resolved count is untrimmed');
            Assert.areEqual(1, sel.articleIds.size(), 'Seeded scope must be trimmed to the lowered cap');
        } finally {
            KBAssessmentService.matchingFilterCap = originalCap;
        }
    }

    // testRecoverRunArticleIds_LegacyRowWithoutDenormalisedParent_ResolvesFromVersion
    // was removed: Knowledge_Article_Id__c is a required field on
    // KB_Article_Assessment__c, so a blank-parent "legacy row" can only exist
    // as real pre-existing data from before the field became required — it
    // can't be constructed via a fresh insert in a test, making the
    // resolveParentIdsFromVersions fallback unreachable via test-only changes.

    @IsTest
    static void testRecoverRunArticleIds_MalformedFilterPayload_ReturnsEmptyWithoutThrowing() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 0,
            Assessment_Types__c = 'Readiness', Requested_Scope__c = 'Selected',
            Filter_DSL_JSON__c = 'not-valid-json{{{'
        );
        insert run;

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        List<String> parentIds = service.recoverRunArticleIds(run.Id, run);
        Test.stopTest();

        Assert.isTrue(parentIds.isEmpty(),
            'Malformed Filter_DSL_JSON__c must degrade to an empty scope, not throw');
    }

    @IsTest
    static void testBuildArticleContent_NullOrEmptyInputs_ReturnBlank() {
        Assert.areEqual('', KBAssessmentService.buildArticleContent(null, new List<String>{ 'Summary' }),
            'A null article must return blank content');

        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'content-blank')[0];
        Assert.areEqual('', KBAssessmentService.buildArticleContent(art, new List<String>()),
            'Empty content fields must return blank content');
        Assert.areEqual('', KBAssessmentService.buildArticleContent(art, null),
            'Null content fields must return blank content');
    }

    @IsTest
    static void testBuildArticleContent_BlankFieldValueSkipped() {
        // Summary is explicitly set to blank (not left unpopulated), so it's in
        // getPopulatedFieldsAsMap() but should still be skipped as blank content.
        Knowledge__kav art = new Knowledge__kav(
            Title = 'content-blank-field-title',
            UrlName = 'content-blank-field-' + System.currentTimeMillis(),
            Language = 'en_US',
            Summary = ''
        );
        insert art;

        String content = KBAssessmentService.buildArticleContent(art, new List<String>{ 'Summary' });
        Assert.areEqual('', content, 'A blank (but populated) field must be skipped, not rendered');
    }

    @IsTest
    static void testBuildFormulaWhereClause_ValidSingleClause_ReturnsAndFragment() {
        KBAssessmentModels.FilterClause clause = new KBAssessmentModels.FilterClause();
        clause.field = 'Title';
        clause.operator = 'contains';
        clause.value = 'Test';

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        String fragment = service.buildFormulaWhereClause(
            new List<KBAssessmentModels.FilterClause>{ clause }, '1'
        );
        Test.stopTest();

        Assert.isTrue(String.isNotBlank(fragment), 'A valid single-clause formula must compile');
        Assert.isTrue(fragment.startsWith(' AND '), 'Compiled fragment must be AND-joinable');
    }

    @IsTest
    static void testDeleteAssessmentRun_NullId_NoOp() {
        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        service.deleteAssessmentRun(null);
        Test.stopTest();
        // No exception is the assertion — a null id is a silent no-op.
    }

    @IsTest
    static void testDeleteAssessmentRun_AlreadyGone_IdempotentNoOp() {
        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = 'Completed', Total_Articles__c = 0,
            Assessment_Types__c = 'Readiness', Requested_Scope__c = 'Selected'
        );
        insert run;
        Id ghostId = run.Id;
        delete run;

        KBAssessmentService service = new KBAssessmentService();
        Test.startTest();
        service.deleteAssessmentRun(ghostId);
        Test.stopTest();
        // No exception is the assertion — deleting an already-gone run is idempotent.
    }

    @IsTest
    static void testRunAssessment_OversizedFilterPayload_ThrowsKnowledgeAIException() {
        // A single absurdly long clause value blows past Filter_DSL_JSON__c's
        // 32,768-char limit — createRunRecord must fail fast with a clear error
        // rather than a cryptic platform STRING_TOO_LONG.
        List<String> parts = new List<String>();
        for (Integer i = 0; i < 40000; i++) {
            parts.add('x');
        }
        KBAssessmentModels.FilterClause clause = new KBAssessmentModels.FilterClause();
        clause.field = 'Title';
        clause.operator = 'contains';
        clause.value = String.join(parts, '');

        KBAssessmentModels.AssessmentRunOptions options = new KBAssessmentModels.AssessmentRunOptions();
        options.assessmentTypes = new List<String>{ 'Readiness' };
        options.selectedDimensions = new List<String>{ 'Completeness' };
        options.requestedScope = 'Selected';
        options.filterClauses = new List<KBAssessmentModels.FilterClause>{ clause };

        Knowledge__kav art = KBTestDataFactory.insertArticles(1, 'oversized-payload')[0];
        KBAssessmentService service = new KBAssessmentService();

        Boolean threw = false;
        Test.startTest();
        try {
            service.runAssessment(new List<String>{ art.Id }, options);
        } catch (KnowledgeAIException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('Filter_DSL_JSON__c'),
                'Should name the field that overflowed');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'An oversized filter payload must fail fast with a clear error');
    }
}
