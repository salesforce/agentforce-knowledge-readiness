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
public with sharing class KBAssessmentService {

    // Fields already in the base KAV SELECT clause. Used to deduplicate
    // content-field additions and avoid "duplicate field selected" SOQL errors.
    private static final Set<String> BASE_KAV_QUERY_FIELDS = new Set<String>{
        'id', 'title', 'articlenumber', 'knowledgearticleid', 'summary', 'urlname', 'lastmodifieddate', 'publishstatus'
    };

    private KBScoringService scoringService;
    private Set<String> selectedDimensions;
    private Map<String, Decimal> effectiveWeights;

    // Set by buildBaseWhere when a non-blank filterFormula was supplied but
    // could not be applied (invalid/unsatisfiable) and the legacy AND/OR path
    // was used instead — a *different* result set than the user asked for.
    // searchArticlesFiltered copies this onto the result DTO so the LWC can
 // toast the silent fallback.
    private Boolean formulaFallbackApplied = false;

    public KBAssessmentService() {
        this.scoringService = new KBScoringService();
        this.selectedDimensions = DimensionRegistry.getActiveDeveloperNames();
        this.effectiveWeights = getBaseWeights();
    }

    /**
     * Restrict scoring to a subset of the 6 readiness dimensions.
     * Passing null or an empty set resets to all dimensions.
     * Weights are renormalised so the selected dimensions sum to 1.0.
     */
    public void setSelectedDimensions(Set<String> dimensions) {
        this.selectedDimensions = (dimensions == null || dimensions.isEmpty())
            ? DimensionRegistry.getActiveDeveloperNames()
            : new Set<String>(dimensions);
        this.effectiveWeights = renormalizeWeights(this.selectedDimensions, getBaseWeights());
    }

    public KBAssessmentModels.AssessmentRunResult runAssessment(
        List<String> articleIds,
        KBAssessmentModels.AssessmentRunOptions options
    ) {
        KBAssessmentModels.AssessmentRunResult runResult = new KBAssessmentModels.AssessmentRunResult();

        if (articleIds == null || articleIds.isEmpty()) {
            runResult.status = 'Failed';
            return runResult;
        }

        KBAssessmentModels.AssessmentRunOptions safeOptions = options != null
            ? options
            : new KBAssessmentModels.AssessmentRunOptions();

        Set<String> assessmentTypes = normalizeAssessmentTypes(safeOptions.assessmentTypes);
        Set<String> readinessDimensions = normalizeSelectedDimensions(safeOptions.selectedDimensions);
        Map<String, Decimal> readinessWeights = renormalizeWeights(readinessDimensions, getBaseWeights());

        String executionMode = determinePipelineExecutionMode(assessmentTypes, readinessDimensions);
        RunCreationResult run = createRunRecord(
            articleIds,
            safeOptions,
            assessmentTypes,
            readinessDimensions,
            readinessWeights,
            executionMode,
            'In Progress',
            buildFilterPayload(safeOptions, articleIds, 'Readiness')
        );

        enqueueAssessmentRun(
            run.runId,
            articleIds,
            readinessDimensions,
            readinessWeights,
            run.pipelineRunId,
            executionMode
        );

        runResult.runId = run.runId;
        runResult.pipelineRunId = run.pipelineRunId != null ? String.valueOf(run.pipelineRunId) : null;
        runResult.assessmentTypesCsv = run.assessmentTypesCsv;
        runResult.requestedScope = run.requestedScope;
        runResult.selectedDimensionCount = readinessDimensions.size();

        runResult.status = 'In Progress';
        runResult.totalArticles = articleIds.size();
        runResult.status = 'Processing';
        return runResult;
    }

    public KBAssessmentModels.AssessmentRunResult runAssessment(List<String> articleIds) {
        return runAssessment(articleIds, new KBAssessmentModels.AssessmentRunOptions());
    }

    /**
 * Rerun an existing assessment IN PLACE. The user clicked
     * "Rerun RUN-0421" and must still have RUN-0421 afterward, now carrying
     * fresh results. We KEEP the same KB_Assessment_Run__c record (same Id,
     * Name, Run_Name__c, CreatedDate) and re-score the same article scope
     * against it.
     *
     * Design (Option B — replace-on-success, failure-safe):
     *   1. Recover the exact article set the original run scored — the KAV ids
     *      on its child KB_Article_Assessment__c rows (falling back to the ids
     *      frozen in Filter_DSL_JSON__c for runs with no surviving children).
     *   2. Do NOT delete the run, and do NOT blank its scores up front. The
     *      old Overall_Score__c / per-dimension averages and the existing
     *      KB_Dimension_Result__c / KB_Dimension_Analysis__c children stay
     *      VISIBLE while the new assessment runs in the background.
     *   3. Reset only the dispatch-tracking + terminal fields on the run
     *      (Status → In Progress, clear Completed_Dimensions__c, re-stamp
     *      Dispatched_Dimensions__c, clear Completed_At__c / cancellation
     *      stamps) and re-link a fresh KB_Pipeline_Run__c.
     *   4. Re-dispatch scoring against the SAME run id via enqueueAssessmentRun.
     *      preCreateParentAssessments is idempotent — it skips articles that
     *      already have a KB_Article_Assessment__c child, so the existing
     *      children (the scope) are STRUCTURALLY PRESERVED, not delete+reinserted
     *      (no need to re-resolve the article set).
     *   5. The async machinery swaps results in on completion: each
     *      KBAssessmentDimensionQueueable UPSERTS its KB_Dimension_Result__c
     *      row by (article, dim) and replaces the dim's analysis children;
     *      KBAssessmentPipelineCallback recomputes the run-level rollup. Stale
     *      rows for any dimension no longer selected are pruned up front (the
     *      one cleanup we must do eagerly — see resetRunForRerun).
     *
     * Failure-mode caveat: the swap is per-dimension, not a single atomic
     * transaction — true all-or-nothing across multiple async hops would need
     * a shadow result set (a much larger refactor, deferred). If the rerun's
     * async work fails partway, dimensions that already upserted carry fresh
     * scores and the rest keep their old values; the run flips to Failed with a
     * reason. The old results are never blanked, so the run never lands in a
     * destroyed/empty state.
     */
    public KBAssessmentModels.AssessmentRunResult rerunAssessment(Id originalRunId) {
        if (originalRunId == null) {
            throw new IllegalArgumentException('Run id is required.');
        }

        // USER_MODE read — a Viewer without access to the run object hits an
        // exception here, surfaced as a clean AuraHandledException by the
        // @AuraEnabled controller wrapper.
        //
        // Read Status__c FOR UPDATE and refuse a rerun of a non-terminal run.
        // The LWC gates Rerun behind isCompleted + a reentrancy flag, but that is
        // client-only: a stale All-Assessments row, racing clicks, or a direct
        // @AuraEnabled call all reach this method. An unguarded rerun of an
        // in-flight run flips it back to 'In Progress' and re-dispatches a SECOND
        // wave of scoring shards over the SAME KB_Article_Assessment__c rows — the
        // two waves collide on the dimension-result upsert (UNABLE_TO_LOCK_ROW at
        // KBAssessmentBatch.execute). Mirrors the deleteAssessmentRun guard; the
        // FOR UPDATE lock also serialises racing reruns so the second reader sees
        // 'In Progress' and bails.
        List<KB_Assessment_Run__c> runs = [
            SELECT Id, Name, Run_Name__c, Description__c, Requested_Scope__c,
                   Selected_Dimensions_JSON__c, Assessment_Types__c,
                   Filter_DSL_JSON__c, Total_Articles__c, Status__c,
                   Dispatch_Generation__c
            FROM KB_Assessment_Run__c
            WHERE Id = :originalRunId
            WITH USER_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (runs.isEmpty()) {
            throw new IllegalArgumentException('Assessment run not found.');
        }
        KB_Assessment_Run__c original = runs[0];

        if (
            String.isNotBlank(original.Status__c) &&
            !TERMINAL_STATUSES.contains(original.Status__c)
        ) {
            throw new RunNotRerunnableException(
                'This assessment is still running. Wait for it to finish or cancel it before rerunning.'
            );
        }

        // Scope is the set of PARENT articles this run covered. Recover them as
        // KnowledgeArticleIds (not the stale version ids that were scored).
        List<String> parentArticleIds = recoverRunArticleIds(originalRunId, original);
        if (parentArticleIds.isEmpty()) {
            throw new IllegalArgumentException(
                'This run has no recoverable article scope to re-assess.'
            );
        }

 // Re-resolve each parent to its CURRENT published version, so the
        // rerun assesses the latest content (e.g. after a fix+republish) rather
        // than the version frozen on the original run. Parents with no live
        // published version are skipped + flagged to the user.
        LatestVersionResolution resolution = resolveLatestPublishedVersions(parentArticleIds);
        List<String> articleIds = resolution.versionIds;
        if (articleIds.isEmpty()) {
            // Every parent in scope has lost its published version — there is
            // nothing meaningful to re-assess. Block rather than run empty.
            throw new IllegalArgumentException(
                'None of the articles in this assessment have a current published version to re-assess. '
                + 'They may have been archived, retired, or merged.'
            );
        }

 // Repoint existing child rows whose article was republished since
        // the original run from the OLD version id to the CURRENT published
        // version id. preCreateParentAssessments keys idempotency on Knowledge__c
        // (the version), so without this a republished article would orphan its
        // old-version row and create a second one — the article would appear
        // twice. Reusing the row (like an unchanged article does) keeps one row
        // per article, now pointing at the latest version.
        repointChildrenToCurrentVersions(originalRunId, resolution.parentToVersion);

        // Re-derive the run's dimension selection + weights from its persisted
        // config so the rerun scores exactly the dimensions it scored before.
        Set<String> readinessDimensions =
            normalizeSelectedDimensions(parseSelectedDimensions(original.Selected_Dimensions_JSON__c));
        Map<String, Decimal> readinessWeights = renormalizeWeights(readinessDimensions, getBaseWeights());
        Set<String> assessmentTypes = new Set<String>{ 'Readiness' };
        String executionMode = determinePipelineExecutionMode(assessmentTypes, readinessDimensions);

        // Reset the SAME run row for a fresh scoring pass (keeps Id/Name/scores
        // visible) and re-link a new pipeline run. Returns the new pipeline run
        // id (null when no dedup pipeline is needed).
        Id pipelineRunId = resetRunForRerun(
            original, articleIds, readinessDimensions, readinessWeights, executionMode
        );

 // Mark child rows whose parent no longer has a published version
        // as Skipped (with a reason), so the results view explains the gap
        // instead of silently dropping them. Their prior scores are preserved.
        if (!resolution.missingParentIds.isEmpty()) {
            markMissingPublishedVersions(originalRunId, resolution.missingParentIds);
        }

        // Re-dispatch scoring against the EXISTING run id. enqueueAssessmentRun
        // re-stamps Dispatched_Dimensions__c / clears Completed_Dimensions__c
        // and idempotently reuses the existing parent assessments.
        enqueueAssessmentRun(
            originalRunId,
            articleIds,
            readinessDimensions,
            readinessWeights,
            pipelineRunId,
            executionMode
        );

        KBAssessmentModels.AssessmentRunResult runResult = new KBAssessmentModels.AssessmentRunResult();
        runResult.runId = originalRunId;
        runResult.pipelineRunId = pipelineRunId != null ? String.valueOf(pipelineRunId) : null;
        runResult.runName = original.Run_Name__c;
        runResult.description = original.Description__c;
        runResult.requestedScope = String.isNotBlank(original.Requested_Scope__c)
            ? original.Requested_Scope__c : 'Selected';
        runResult.selectedDimensionCount = readinessDimensions.size();
        runResult.totalArticles = articleIds.size();
 // surface the count of articles skipped because their parent has
        // no current published version, so the LWC can warn the user.
        runResult.skippedNoPublishedVersionCount = resolution.missingParentIds.size();
        runResult.status = 'Processing';
        return runResult;
    }

    /**
 * Build the prefill payload for cloning a run. A clone is a NEW run
     * over the SAME set of articles, so history is preserved (the source run is
     * untouched). This reuses the rerun scope-recovery path verbatim:
     * recoverRunArticleIds resolves the source run's PARENT articles (from its
     * child rows), then resolveLatestPublishedVersions maps each to its CURRENT
     * Online version — so a clone always assesses live content, and parents with
     * no published version (archived / retired / merged away) are dropped and
     * counted for the user rather than silently included.
     *
     * The LWC opens the new-assessment modal prefilled with these ids + a
     * "Copy of <name>" suggestion; the user reviews/edits the basket and submits
     * as a plain 'Selected' run through the normal runner path.
     *
     * USER_MODE read — a user without access to the run object hits an exception
     * here, surfaced as a clean AuraHandledException by the controller wrapper
     * (same posture as rerunAssessment).
     */
    public KBAssessmentModels.RunSelectionForClone getRunSelectionForClone(Id runId) {
        if (runId == null) {
            throw new IllegalArgumentException('Run id is required.');
        }
        // Filter_DSL_JSON__c is required: recoverRunArticleIds falls back to
        // the article ids frozen in the filter payload for runs whose child
        // rows are gone, and articleIdsFromFilterPayload reads it off this record.
        List<KB_Assessment_Run__c> runs = [
            SELECT Id, Run_Name__c, Description__c, Total_Articles__c, Filter_DSL_JSON__c
            FROM KB_Assessment_Run__c
            WHERE Id = :runId
            WITH USER_MODE
            LIMIT 1
        ];
        if (runs.isEmpty()) {
            throw new IllegalArgumentException('Assessment run not found.');
        }
        KB_Assessment_Run__c original = runs[0];

        // Same recovery path rerun uses: child rows → parent ids → current
        // Online versions.
        List<String> parentIds = recoverRunArticleIds(runId, original);
        LatestVersionResolution resolution = resolveLatestPublishedVersions(parentIds);
        List<String> resolvedIds = resolution.versionIds;

        KBAssessmentModels.RunSelectionForClone sel = new KBAssessmentModels.RunSelectionForClone();
        String base = String.isNotBlank(original.Run_Name__c) ? original.Run_Name__c : 'Assessment';
        // Reuse sanitiseRunName (trim + truncate to the Run_Name__c 255 limit)
        // so the prefilled suggestion can't exceed the input maxlength or get
        // its tail lopped only at submit — one source of truth for the cap.
        sel.suggestedRunName = sanitiseRunName('Copy of ' + base);
        sel.description = original.Description__c;
        sel.droppedNoPublishedVersionCount = resolution.missingParentIds.size();
        // The seeded scope is bounded by the app-wide max run size (cloneArticleCap
        // = matchingFilterCap = 10k). A run can't legitimately exceed it, and the
        // Clone button is disabled in the UI above it — this trim is a defensive
        // backstop, not the primary guard. resolvedArticleCount carries the full
        // total so the LWC never silently truncates.
        sel.resolvedArticleCount = resolvedIds.size();
        Integer cap = cloneArticleCap;
        if (resolvedIds.size() > cap) {
            List<String> capped = new List<String>();
            for (Integer i = 0; i < cap; i++) {
                capped.add(resolvedIds[i]);
            }
            sel.articleIds = capped;
        } else {
            sel.articleIds = resolvedIds;
        }
        return sel;
    }

    /**
 * Prepare an existing run for an in-place rerun. Does NOT delete the
     * run and does NOT blank its rollup scores — the old scores stay visible
     * until the async swap completes. Concretely:
     *   - flips Status__c back to 'In Progress' and clears the terminal /
     *     cancellation / duration stamps so the run reads as live again;
     *   - re-stamps Total_Articles__c + Used_LLM__c intent for the recovered
     *     scope;
     *   - prunes stale KB_Dimension_Result__c rows for dimensions no longer
     *     selected (their async workers won't run, so absence is the only way
     *     they render as N/A) — analysis children cascade-delete with them;
     *   - retires the old linked KB_Pipeline_Run__c and creates a fresh one
     *     (when the selection still needs dedup), re-pointing the run at it.
     * Returns the new pipeline run id (null when no dedup pipeline is needed).
     */
    @TestVisible
    private Id resetRunForRerun(
        KB_Assessment_Run__c original,
        List<String> articleIds,
        Set<String> readinessDimensions,
        Map<String, Decimal> readinessWeights,
        String executionMode
    ) {
        Id runId = original.Id;

        // Retire any previously-linked pipeline run so the Action Center
        // doesn't keep stale candidates from the prior pass. Best-effort —
        // a failure here must not block the rerun.
        retireLinkedPipelineRun(runId);

        // Prune dimension-result rows for dims that are no longer selected.
        // For a same-config rerun the selection is unchanged and this is a
        // no-op; it only matters if a future caller reruns with a narrower
        // set. Analysis children are master-detail to the result, so they
        // cascade-delete with these rows. Scoped strictly to this run.
        pruneDeselectedDimensionResults(runId, readinessDimensions);

        Id pipelineRunId = maybeCreatePipelineRun(
            articleIds,
            buildRerunOptions(original, readinessDimensions),
            executionMode
        );

        KB_Assessment_Run__c reset = new KB_Assessment_Run__c(
            Id = runId,
            Status__c = 'In Progress',
            Status_Message__c = null,
            // Keep the rollup scores VISIBLE during the rerun — they are
            // recomputed atomically by KBAssessmentPipelineCallback on
            // completion. We only clear the lifecycle stamps here.
            Completed_At__c = null,
            Cancellation_Requested_At__c = null,
            Cancelled_By__c = null,
            Scoring_Duration_Ms__c = null,
            Pipeline_Duration_Ms__c = null,
            Total_Duration_Ms__c = null,
            Total_Articles__c = articleIds.size(),
            Used_LLM__c = DimensionRegistry.anyRequiresLLM(readinessDimensions),
            Selected_Dimensions_JSON__c = JSON.serialize(new List<String>(readinessDimensions)),
            Effective_Weights_JSON__c = JSON.serialize(readinessWeights),
            Pipeline_Run__c = pipelineRunId
        );
        // USER_MODE on the reset — a Viewer without edit access to the run
        // hits an InsufficientAccess DmlException, surfaced as a clean
        // AuraHandledException by the @AuraEnabled controller wrapper.
        Database.update(reset, true, AccessLevel.USER_MODE);

        // System-mode update for the fields the USER_MODE reset above can't touch:
        //   - Async_Job_Ids__c: system-managed (editable=false on the shipped
        //     permsets — written only by recordAsyncJobs in system mode). Cleared
        //     here so the re-dispatch's recordAsyncJobs repopulates fresh ids.
        //   - Scan_Start_Time__c: editable=false on KB_Assessment_Admin /
        //     KB_Assessment_Viewer (same shape as Async_Job_Ids__c), so a
        //     USER_MODE write trips FLS for those personas. This re-stamps the
        //     scoring-start clock to NOW — the moment the rerun's scoring begins
        //     — so Scoring_Duration_Ms__c measures the rerun, not the gap since
        //     the original run's (preserved) CreatedDate.
        //   - Dispatch_Generation__c: bumped so the new wave's workers capture a
        //     higher generation than any straggler from the prior wave. The
        //     straggler's per-chunk generation gate then sees the run at a newer
        //     generation and declines to write, instead of colliding
        //     (UNABLE_TO_LOCK_ROW) over the same rows. Read-then-increment is safe
        //     here: rerunAssessment holds the run row FOR UPDATE for this whole
        //     transaction, so two racing reruns serialise (and the second is
        //     rejected by the non-terminal guard anyway). editable=false on the
        //     runtime permsets, hence the system-mode write.
        //
        // Best-effort by design (logs and continues): the terminal-rerun guard is
        // the primary protection. If this bump throws, wave-2 re-dispatches at the
        // SAME generation wave-1 captured, so a draining straggler would NOT be
        // superseded and could still collide — i.e. a failed bump silently
        // disables the generation gate for this one rerun. A system-mode update of
        // a Number on a row already locked in this transaction is about as
        // reliable as DML gets, so this is accepted degradation, matching the
        // Scan_Start_Time__c write it rides with.
        Decimal priorGeneration = original.Dispatch_Generation__c != null
            ? original.Dispatch_Generation__c : 0;
        try {
            update new KB_Assessment_Run__c(
                Id = runId,
                Async_Job_Ids__c = null,
                Scan_Start_Time__c = Datetime.now(),
                Dispatch_Generation__c = priorGeneration + 1
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.resetRunForRerun: failed to clear Async_Job_Ids__c / stamp Scan_Start_Time__c / bump Dispatch_Generation__c for run '
                + runId + ': ' + e.getMessage());
        }

        if (pipelineRunId != null) {
            update new KB_Pipeline_Run__c(
                Id = pipelineRunId,
                Assessment_Run__c = runId
            );
        }

        publishRunQueuedEvent(runId, articleIds.size());
        return pipelineRunId;
    }

    /**
     * Build a minimal options bundle for the rerun's pipeline-run creation.
     * Mirrors the original run's name/scope so the new KB_Pipeline_Run__c
     * Scope_Details_JSON__c stays consistent with the prior pass.
     */
    private KBAssessmentModels.AssessmentRunOptions buildRerunOptions(
        KB_Assessment_Run__c original,
        Set<String> readinessDimensions
    ) {
        KBAssessmentModels.AssessmentRunOptions options = new KBAssessmentModels.AssessmentRunOptions();
        options.runName = original.Run_Name__c;
        options.description = original.Description__c;
        options.requestedScope = 'Selected';
        options.selectedDimensions = new List<String>(readinessDimensions);
        options.assessmentTypes = new List<String>{ 'Readiness' };
        return options;
    }

    /**
     * Retire the run's linked KB_Pipeline_Run__c ahead of a rerun. Best-effort.
 * Duplicate_Candidate__c.Pipeline_Run__c is a Lookup (no cascade), so
     * we DELETE the prior pass's still-'Pending' candidates first, else they
     * orphan and linger across the Action Center / dashboard. Triaged rows
     * (Rejected/Suppressed/Resolved) are left alone. Delete, not a 'Superseded'
 * flip: 'Superseded' is the "republished outside our flow" signal that
     * the Resolved-Merges tab and dashboard shelves surface — reusing it would
     * leak stale rerun rows onto those surfaces.
     */
    private void retireLinkedPipelineRun(Id runId) {
        List<KB_Assessment_Run__c> holders = [
            SELECT Pipeline_Run__c
            FROM KB_Assessment_Run__c
            WHERE Id = :runId AND Pipeline_Run__c != null
            WITH USER_MODE
        ];
        if (holders.isEmpty()) return;
        Id retiringPipelineRunId = holders[0].Pipeline_Run__c;

        deleteStalePendingCandidates(retiringPipelineRunId);

        try {
            Database.delete(
                new List<KB_Pipeline_Run__c>{
                    new KB_Pipeline_Run__c(Id = retiringPipelineRunId)
                },
                false,
                AccessLevel.USER_MODE
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.retireLinkedPipelineRun: failed for run '
                + runId + ': ' + e.getMessage());
        }
    }

    /**
 * Delete the prior pass's still-'Pending' Duplicate_Candidate__c rows
     * on a rerun so they don't linger across the Action Center, the dashboard
     * shelves, and Resolved Merges. Best-effort; scoped to one pipeline run and
     * to Pending only, so human-triaged rows (Rejected / Suppressed / Resolved)
     * are untouched. No child records hang off Duplicate_Candidate__c, so the
     * delete is clean.
     */
    private void deleteStalePendingCandidates(Id pipelineRunId) {
        if (pipelineRunId == null) return;
        try {
            List<Duplicate_Candidate__c> stale = [
                SELECT Id
                FROM Duplicate_Candidate__c
                WHERE Pipeline_Run__c = :pipelineRunId AND Status__c = 'Pending'
                WITH USER_MODE
            ];
            if (stale.isEmpty()) return;
            Database.delete(stale, false, AccessLevel.USER_MODE);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.deleteStalePendingCandidates: failed for pipeline run '
                + pipelineRunId + ': ' + e.getMessage());
        }
    }

    /**
     * Delete KB_Dimension_Result__c rows for dimensions NOT in the new
     * selection, scoped strictly to this run. Their async workers won't run on
     * the rerun, so leaving the rows would show stale scores for a dimension
     * the user dropped; absence is what makes the LWC render the dim as N/A.
     * KB_Dimension_Analysis__c is master-detail to the result, so it cascades.
     */
    private void pruneDeselectedDimensionResults(Id runId, Set<String> readinessDimensions) {
        List<KB_Dimension_Result__c> stale = [
            SELECT Id
            FROM KB_Dimension_Result__c
            WHERE Article_Assessment__r.Assessment_Run__c = :runId
              AND Dimension__c NOT IN :readinessDimensions
        ];
        if (!stale.isEmpty()) {
            Database.delete(stale, true, AccessLevel.USER_MODE);
        }
    }

    /**
     * Recover the article set an existing run was executed against, as PARENT
     * article ids (Knowledge_Article_Id__c) — NOT the specific KAV version ids
     * that were scored. The rerun must re-resolve each parent to its CURRENT
     * published version (see resolveLatestPublishedVersions), so that fixing +
     * republishing an article between runs causes the rerun to assess the new
 * version rather than the stale one frozen on the original run.
     *
     * Primary source is the run's own child KB_Article_Assessment__c rows,
     * which already carry the denormalised parent id in Knowledge_Article_Id__c.
     * For older rows where that field is blank, we fall back to resolving the
     * stored Knowledge__c (version) ids up to their parents. Last resort is the
     * article ids frozen in Filter_DSL_JSON__c (treated as parent ids).
     */
    @TestVisible
    private List<String> recoverRunArticleIds(Id runId, KB_Assessment_Run__c original) {
        List<String> parentIds = new List<String>();
        Set<String> seen = new Set<String>();
        Set<String> versionsNeedingParent = new Set<String>();

        for (KB_Article_Assessment__c a : [
            SELECT Knowledge__c, Knowledge_Article_Id__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :runId AND Knowledge__c != null
            WITH USER_MODE
        ]) {
            String parentId = a.Knowledge_Article_Id__c;
            if (String.isNotBlank(parentId)) {
                if (seen.add(parentId)) {
                    parentIds.add(parentId);
                }
            } else {
                // Older row without the denormalised parent id — resolve from
                // the version id below.
                versionsNeedingParent.add(String.valueOf(a.Knowledge__c));
            }
        }

        if (!versionsNeedingParent.isEmpty()) {
            for (String pid : resolveParentIdsFromVersions(versionsNeedingParent)) {
                if (String.isNotBlank(pid) && seen.add(pid)) {
                    parentIds.add(pid);
                }
            }
        }

        if (!parentIds.isEmpty()) {
            return parentIds;
        }
        // Fallback: the ids frozen into the filter payload at run creation.
        // These are KAV VERSION ids (the article selector and resolveMatching
        // ArticleIds both SELECT Id), not parent ids — so resolve them up to
        // their parent KnowledgeArticleIds before returning, to match what the
        // downstream latest-published-version resolver queries on.
        List<String> frozen = articleIdsFromFilterPayload(original);
        if (frozen.isEmpty()) {
            return frozen;
        }
        List<String> frozenParents = new List<String>();
        for (String pid : resolveParentIdsFromVersions(new Set<String>(frozen))) {
            if (String.isNotBlank(pid) && seen.add(pid)) {
                frozenParents.add(pid);
            }
        }
        return frozenParents;
    }

    /**
     * Resolve a set of KAV (version) ids up to their parent KnowledgeArticleIds.
     * Used only as a fallback in recoverRunArticleIds for legacy child rows that
     * predate the Knowledge_Article_Id__c denormalisation.
     */
    private List<String> resolveParentIdsFromVersions(Set<String> versionIds) {
        List<String> parents = new List<String>();
        String kavName = getKnowledgeObjectApiName();
        if (String.isBlank(kavName) || versionIds.isEmpty()) {
            return parents;
        }
        Set<Id> ids = new Set<Id>();
        for (String v : versionIds) {
            try { ids.add(Id.valueOf(v)); } catch (Exception e) { /* skip */ }
        }
        if (ids.isEmpty()) return parents;
        String q = 'SELECT KnowledgeArticleId FROM ' + kavName + ' WHERE Id IN :ids';
        // USER_MODE: id-keyed read of system fields only (no content/custom
        // fields in SELECT or WHERE), so it enforces the running user's access
        // without risking an FLS throw for a Knowledge-read-only persona. It also
        // applies data-category row visibility — a rerun/clone recovery that
        // can't see an article under the running user's categories drops it,
        // which is the intended user-scoped behaviour (cf. the USER_MODE version
        // resolve below).
        for (SObject s : Database.query(q, AccessLevel.USER_MODE)) {
            Object pid = s.get('KnowledgeArticleId');
            if (pid != null) parents.add(String.valueOf(pid));
        }
        return parents;
    }

    /**
 * Resolve each parent KnowledgeArticleId to its CURRENT online
     * (published) KAV version. Parents with no published version (e.g. the
     * article was archived/retired, or its only versions are drafts, or it was
     * merged away) are returned in `missingParentIds` so the caller can skip
     * them and flag them to the user — rather than silently re-scoring a stale
     * version or dropping the article without explanation.
     */
    @TestVisible
    private LatestVersionResolution resolveLatestPublishedVersions(List<String> parentIds) {
        LatestVersionResolution res = new LatestVersionResolution();
        if (parentIds == null || parentIds.isEmpty()) {
            return res;
        }
        String kavName = getKnowledgeObjectApiName();
        Set<String> remaining = new Set<String>(parentIds);

        if (String.isNotBlank(kavName)) {
            Set<String> parentSet = new Set<String>(parentIds);
            // Latest published version per parent. PublishStatus = 'Online'
            // identifies the live version; an article has at most one.
            String q = 'SELECT Id, KnowledgeArticleId FROM ' + kavName
                + ' WHERE KnowledgeArticleId IN :parentSet'
                + ' AND PublishStatus = \'Online\'';
            // USER_MODE: only system fields (Id/KnowledgeArticleId) and the
            // standard PublishStatus in play — no content-field FLS to trip.
            // Data-category row visibility applies too: a parent the running user
            // can't see resolves to no live version and is reported as missing,
            // which is the intended user-scoped rerun/clone behaviour.
            for (SObject s : Database.query(q, AccessLevel.USER_MODE)) {
                String pid = String.valueOf(s.get('KnowledgeArticleId'));
                String vid = String.valueOf(s.get('Id'));
                if (remaining.remove(pid)) {
                    res.versionIds.add(vid);
                    res.parentToVersion.put(pid, vid);
                }
            }
        }
        // Whatever parents we couldn't resolve to a live version are missing.
        res.missingParentIds.addAll(remaining);
        return res;
    }

    /**
     * Result of resolving parent articles to their current published versions.
     */
    public class LatestVersionResolution {
        public List<String> versionIds = new List<String>();
        public Set<String> missingParentIds = new Set<String>();
        public Map<String, String> parentToVersion = new Map<String, String>();
    }

    /**
 * Repoint a run's child rows to the current published version of
     * their parent article. For each child whose Knowledge__c (version) is no
     * longer the parent's live version, update it to the current version id so
     * the rerun reuses the SAME row (one row per article) instead of orphaning
     * the stale-version row and inserting a new one. Also clears any prior skip
     * reason on rows that now resolve to a live version (a republish "un-skips"
     * an article that was previously archived).
     *
     * The WRITES (delete + update) run in system mode; the READ keeps USER_MODE.
     * These are app-managed bookkeeping rows (a user never hand-edits an
     * assessment row's version pointer), and the rest of the rerun write path —
     * preCreateParentAssessments' insert, the per-dimension score upserts — is
     * already system mode. A USER_MODE write here silently dropped the repoint
     * for any persona without field-EDIT FLS on this object: the shipped
     * "Assessment Manager" permset grants object Create/Edit but no field-level
     * edit on KB_Article_Assessment__c, so USER_MODE rejected the version update
     * as a swallowed partial failure. The stale (archived-version) row stayed put
     * while the system-mode insert still created the new-version row — two scored
     * rows for one article. Do not restore USER_MODE on the writes; it reopens
     * that split. The read stays USER_MODE (the persona has field-READ FLS, and
     * the parent run was already gated by a USER_MODE FOR UPDATE read in the
     * caller) so we don't drop an access guard just to fix the write.
     *
     * Failures surface loudly (see below): a silently-dropped repoint produces a
     * wrong, duplicated, user-visible result, so it must not be swallowed.
     */
    private void repointChildrenToCurrentVersions(Id runId, Map<String, String> parentToVersion) {
        if (parentToVersion == null || parentToVersion.isEmpty()) {
            return;
        }
        // Group this run's children by parent article so we can keep exactly
        // one row per parent (collapsing any orphans left by a prior rerun
        // that ran before this fix) and point it at the current version.
        Map<String, List<KB_Article_Assessment__c>> byParent =
            new Map<String, List<KB_Article_Assessment__c>>();
        for (KB_Article_Assessment__c a : [
            SELECT Id, Knowledge__c, Knowledge_Article_Id__c, Pipeline_Skip_Reason__c
            FROM KB_Article_Assessment__c
            WHERE Assessment_Run__c = :runId AND Knowledge_Article_Id__c != null
            WITH USER_MODE
        ]) {
            if (!byParent.containsKey(a.Knowledge_Article_Id__c)) {
                byParent.put(a.Knowledge_Article_Id__c, new List<KB_Article_Assessment__c>());
            }
            byParent.get(a.Knowledge_Article_Id__c).add(a);
        }

        List<KB_Article_Assessment__c> toUpdate = new List<KB_Article_Assessment__c>();
        List<KB_Article_Assessment__c> toDelete = new List<KB_Article_Assessment__c>();
        for (String parentId : byParent.keySet()) {
            String currentVersionId = parentToVersion.get(parentId);
            List<KB_Article_Assessment__c> rows = byParent.get(parentId);

            // Keep exactly one row per parent. Prefer a row already at the
            // current version (idempotent on a repeat rerun); else the first.
            // Collapse any other rows for this parent — orphan duplicates a
            // prior pre-fix rerun may have left behind. This runs for missing
            // parents too, so an archived article never shows multiple rows.
            KB_Article_Assessment__c keep = rows[0];
            if (String.isNotBlank(currentVersionId)) {
                for (KB_Article_Assessment__c r : rows) {
                    if (String.valueOf(r.Knowledge__c) == currentVersionId) { keep = r; break; }
                }
            }
            for (KB_Article_Assessment__c r : rows) {
                if (r.Id != keep.Id) toDelete.add(r);
            }

            // Repoint only applies when the parent has a live version. A
            // missing parent's kept row is left for markMissingPublishedVersions.
            if (String.isNotBlank(currentVersionId)) {
                Boolean versionMoved = String.valueOf(keep.Knowledge__c) != currentVersionId;
                Boolean hadSkip = String.isNotBlank(keep.Pipeline_Skip_Reason__c);
                if (versionMoved || hadSkip) {
                    toUpdate.add(new KB_Article_Assessment__c(
                        Id = keep.Id,
                        Knowledge__c = (Id) currentVersionId,
                        // A row that now resolves to a live version is no longer
                        // skipped — clear any stale "no published version" reason.
                        Pipeline_Skip_Reason__c = null
                    ));
                }
            }
        }
        // Delete orphans first (frees the version slot), then repoint. Both are
        // allOrNone=true and any DmlException is rethrown as RepointFailedException
        // — the opposite of the former best-effort swallow. A dropped repoint
        // duplicates a scored row in the user's results, so it must BLOCK the
        // rerun, not degrade silently. rerunAssessment runs this BEFORE it resets
        // the run, so a throw here leaves the prior results fully intact — the
        // user retries against a correct run rather than a wrong, doubled set.
        // System-mode writes: see the class-doc rationale on this method.
        try {
            if (!toDelete.isEmpty()) {
                Database.delete(toDelete, true);
            }
            if (!toUpdate.isEmpty()) {
                Database.update(toUpdate, true);
            }
        } catch (DmlException e) {
            throw new RepointFailedException(
                'Could not update this assessment\'s articles to their current published '
                + 'versions, so the rerun was stopped to avoid duplicate scored rows. '
                + 'Detail: ' + e.getMessage()
            );
        }
    }

    /**
 * Stamp the run's existing child rows whose parent article no longer
     * has a current published version with a skip reason, so the results view
     * shows WHY they weren't re-assessed (rather than silently leaving stale
     * scores with no explanation). Prior scores are intentionally preserved —
     * we only write the reason. Reuses Pipeline_Skip_Reason__c (a generic skip
     * field already surfaced as a badge on kbArticleScoreCard); the badge label
     * is generalised so it reads correctly for this non-dedup skip too.
     * Best-effort: a failure here must not block the rerun.
     *
     * System-mode WRITE (USER_MODE read), matching repointChildrenToCurrentVersions:
     * this stamps the same app-managed bookkeeping field (Pipeline_Skip_Reason__c)
     * the repoint clears, and the "Assessment Manager" persona has no field-edit
     * FLS on this object — a USER_MODE write here would silently drop the skip
     * badge for exactly the persona that runs reruns. Unlike the repoint (whose
     * silent failure duplicates a scored row) this one is genuinely cosmetic — a
     * missing "no published version" note — so it stays allOrNone=false / logged,
     * not a blocking throw. The read keeps USER_MODE (the persona has field-READ
     * FLS; the parent run was already access-gated in the caller).
     */
    private void markMissingPublishedVersions(Id runId, Set<String> missingParentIds) {
        if (missingParentIds == null || missingParentIds.isEmpty()) {
            return;
        }
        try {
            List<KB_Article_Assessment__c> toFlag = new List<KB_Article_Assessment__c>();
            for (KB_Article_Assessment__c a : [
                SELECT Id
                FROM KB_Article_Assessment__c
                WHERE Assessment_Run__c = :runId
                  AND Knowledge_Article_Id__c IN :missingParentIds
                WITH USER_MODE
            ]) {
                toFlag.add(new KB_Article_Assessment__c(
                    Id = a.Id,
                    Pipeline_Skip_Reason__c =
                        'No current published version at rerun — the article may have been '
                        + 'archived, retired, or merged. Showing the prior run\'s scores.'
                ));
            }
            if (!toFlag.isEmpty()) {
                // Partial-success: a single bad row degrades to a logged warning
                // rather than aborting the whole rerun's flagging.
                Database.update(toFlag, false);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.markMissingPublishedVersions: failed for run '
                + runId + ': ' + e.getMessage());
        }
    }

    private List<String> articleIdsFromFilterPayload(KB_Assessment_Run__c original) {
        List<String> ids = new List<String>();
        if (original == null || String.isBlank(original.Filter_DSL_JSON__c)) {
            return ids;
        }
        try {
            Map<String, Object> payload =
                (Map<String, Object>) JSON.deserializeUntyped(original.Filter_DSL_JSON__c);
            Object raw = payload.get('articleIds');
            if (raw instanceof List<Object>) {
                for (Object o : (List<Object>) raw) {
                    if (o != null) ids.add(String.valueOf(o));
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.articleIdsFromFilterPayload: could not parse '
                + 'Filter_DSL_JSON__c for run ' + original.Id + ': ' + e.getMessage());
        }
        return ids;
    }

    private List<String> parseSelectedDimensions(String dimensionsJSON) {
        if (String.isBlank(dimensionsJSON)) {
            return new List<String>(DimensionRegistry.getActiveDeveloperNames());
        }
        try {
            List<Object> raw = (List<Object>) JSON.deserializeUntyped(dimensionsJSON);
            List<String> dims = new List<String>();
            for (Object o : raw) {
                if (o != null) dims.add(String.valueOf(o));
            }
            return dims.isEmpty()
                ? new List<String>(DimensionRegistry.getActiveDeveloperNames())
                : dims;
        } catch (Exception e) {
            return new List<String>(DimensionRegistry.getActiveDeveloperNames());
        }
    }

    private Integer getBatchSize() {
        KB_Scan_Config__c config = KB_Scan_Config__c.getInstance();
        if (config != null && config.Queueable_Batch_Size__c != null && config.Queueable_Batch_Size__c > 0) {
            return config.Queueable_Batch_Size__c.intValue();
        }
        return KBRuntimeConfigService.DEFAULT_BATCH_SIZE;
    }

    public KBAssessmentModels.ArticleAssessmentResult assessArticle(
        KBAssessmentModels.ArticleWrapper article
    ) {
        KBAssessmentModels.ArticleAssessmentResult result =
            scoringService.scoreDimensions(article, this.selectedDimensions, null, null, null);
        result.calculateOverallScore(this.selectedDimensions, this.effectiveWeights);
        return result;
    }

    /**
     * Bulk-aware article assessment — accepts pre-loaded pipeline data
     * (0 SOQL for duplication/conflict).
     */
    public KBAssessmentModels.ArticleAssessmentResult assessArticleBulk(
        KBAssessmentModels.ArticleWrapper article,
        Decimal dupPipelineScore, Decimal conflictPipelineScore,
        List<Duplicate_Candidate__c> candidates
    ) {
        KBAssessmentModels.ArticleAssessmentResult result = scoringService.scoreDimensions(
            article, this.selectedDimensions, dupPipelineScore, conflictPipelineScore, candidates
        );
        result.calculateOverallScore(this.selectedDimensions, this.effectiveWeights);
        return result;
    }

    public List<KBAssessmentModels.ArticleWrapper> fetchArticles(List<String> articleIds) {
        List<KBAssessmentModels.ArticleWrapper> wrappers = new List<KBAssessmentModels.ArticleWrapper>();

        if (articleIds == null || articleIds.isEmpty()) {
            return wrappers;
        }

        String knowledgeObjectName = getKnowledgeObjectApiName();
        if (String.isBlank(knowledgeObjectName)) {
            return wrappers;
        }

        ArticleProjection proj = buildArticleProjection(knowledgeObjectName);
        if (proj.contentFields.isEmpty()) {
            throw new AuraHandledException(
                'No content fields configured or discovered. Complete Step 2 (Content Scope) in the Setup Wizard '
                + 'to select which Knowledge body fields the scan should read, or ensure your Knowledge object '
                + 'has the standard Summary field (the only field auto-discovery currently checks).'
            );
        }

        String query = 'SELECT ' + proj.selectClause
            + ' FROM ' + knowledgeObjectName
            + ' WHERE Id IN :articleIds';

        // System mode (default) on purpose: selectClause pulls the admin-mapped
        // Knowledge content fields, and FLS on those fields is the customer's to
        // grant — the app's own permsets deliberately don't (see the convention
        // in CLAUDE.md / KBAssessmentController's WITH SYSTEM_MODE reads). A
        // USER_MODE read would throw "No such column" for a Knowledge-read-only
        // persona and break scoring. System mode relaxes FLS/CRUD only — it does
        // NOT bypass Knowledge data-category record visibility, which is enforced
        // at the record level regardless of access mode; so the running user
        // still only sees articles in their categories here. This is the
        // canonical rationale the other content-field reads in this class refer
        // back to.
        List<SObject> articles = Database.query(query);

        // Bulk-load data category counts (1 SOQL instead of N)
        Map<String, Integer> catCounts = getDataCategoryCounts(articleIds);

        for (SObject article : articles) {
            KBAssessmentModels.ArticleWrapper wrapper = new KBAssessmentModels.ArticleWrapper(article);
            wrapper.content = buildArticleContent(article, proj.contentFields);
            // contentFieldValues is consumed only by kbArticleSelector (picker datatable).
            // On the scoring path (fetchArticles) it is dead weight — skipping saves ~1/3
            // of per-article content heap, which matters now that there is no content cap.
            wrapper.dataCategories = catCounts.containsKey(wrapper.id) ? catCounts.get(wrapper.id) : 0;
            wrappers.add(wrapper);
        }

        return wrappers;
    }

    /**
     * Projection bundle for an article SOQL query. Pairs the SELECT clause
     * with the trimmed/validated content-field list so the SELECT and any
     * subsequent field access can never drift apart (which used to surface
     * as "SObject row was retrieved via SOQL without querying the requested
 * field"—).
     */
    @TestVisible
    private class ArticleProjection {
        String selectClause;
        List<String> contentFields;
    }

    /**
     * Build the SELECT projection for the given Knowledge object.
     * Combines BASE_KAV_QUERY_FIELDS with admin-configured content fields,
     * deduplicates, and validates each name against the live describe so
     * fields that don't exist in this org are silently dropped instead of
     * blowing up the SOQL.
     */
    private ArticleProjection buildArticleProjection(String objectName) {
        ArticleProjection proj = new ArticleProjection();
        proj.contentFields = getContentFields(objectName);

        String selectClause = 'Id, Title, ArticleNumber, KnowledgeArticleId, Summary, UrlName, LastModifiedDate, PublishStatus';
        for (String field : proj.contentFields) {
            if (!BASE_KAV_QUERY_FIELDS.contains(field.toLowerCase())) {
                selectClause += ', ' + field;
            }
        }
        proj.selectClause = selectClause;
        return proj;
    }

    /**
     * Get admin-configured content fields for the Knowledge object.
     * Source of truth is the Setup Wizard Step 1 selection, persisted to
     * KB_Scan_Config__c.Content_Field_Mapping_JSON__c. Returns an empty list
     * when unconfigured — callers must handle that case with a clear error.
     */
    public static List<String> getContentFields(String objectName) {
        List<String> contentFields = new List<String>();
        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            return contentFields;
        }
        Map<String, Schema.SObjectField> fields = objType.getDescribe().fields.getMap();

        KB_Scan_Config__c config = KB_Scan_Config__c.getInstance();
        if (config != null && String.isNotBlank(config.Content_Field_Mapping_JSON__c)) {
            for (String fieldName : config.Content_Field_Mapping_JSON__c.split(',')) {
                String f = fieldName.trim();
                if (String.isNotBlank(f) && fields.containsKey(f.toLowerCase())) {
                    contentFields.add(f);
                }
            }
        }

        // Auto-discovery fallback when no explicit mapping is configured.
        // Summary is the standard KAV body field; to fallback
        if (contentFields.isEmpty()) {
            List<String> knownFields = new List<String>{
                'Summary'
            };
            for (String f : knownFields) {
                if (fields.containsKey(f.toLowerCase())) {
                    contentFields.add(f);
                }
            }
        }

        return contentFields;
    }

    // Maximum number of admin-selected content-field columns rendered in
    // the article-selector table. Cap enforced at the Apex layer so the
    // LWC can't accidentally pull more than the table can render — beyond
    // 4 columns the picker starts horizontal-scrolling on common laptop
    // widths.
    @TestVisible
    private static final Integer CONTENT_FIELD_COLUMN_CAP = 4;

 // /— max article ids to freeze into Filter_DSL_JSON__c as the
    // recovery fallback. Above this the list is omitted (child rows recover the
    // scope) so a large Selected run — e.g. a clone of a MatchingFilter run —
    // can't overflow the 32,768-char field. 1000 ids serialize well under the
    // limit (~18 chars each ≈ 18KB) with headroom for the clauses/formula.
    @TestVisible
    private static final Integer FROZEN_ARTICLE_ID_CAP = 1000;

 // max articles a clone can seed. This is the app-wide scope ceiling
    // (matchingFilterCap, 10k): no assessment run can hold more than this — the
    // service throws MatchingFilterLimitException above it at submit time — so a
    // clone can never legitimately need more. The Clone button is disabled in
    // the UI when a run somehow exceeds it (belt-and-braces), and this backstop
    // trims defensively rather than silently overrunning. Reads the same getter
    // as the matching-filter path so there's one source of truth for "max
    // articles per run".
    @TestVisible
    private static Integer cloneArticleCap {
        get { return matchingFilterCap; }
    }

    // Public accessor for the LWC (via KBAssessmentController.getCloneArticleCap)
    // so the Clone-button gate + tooltip read the same ceiling the service caps
    // on — no hardcoded 10k in JS.
    public static Integer getCloneArticleCapStatic() {
        return cloneArticleCap;
    }

    /**
     * Return descriptors (apiName + describe label) for the admin-selected
     * content fields, used by kbArticleSelector to build dynamic columns.
     * Mirrors the validation rules of getContentFields (drop missing fields,
     * dedup against base SELECT) and additionally caps the result at
     * CONTENT_FIELD_COLUMN_CAP entries.
     */
    public static List<Map<String, String>> getSelectedContentFieldDescriptors() {
        List<Map<String, String>> descriptors = new List<Map<String, String>>();

        String objectName = getKnowledgeObjectApiNameStatic();
        if (String.isBlank(objectName)) {
            return descriptors;
        }

        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) {
            return descriptors;
        }
        Map<String, Schema.SObjectField> fields = objType.getDescribe().fields.getMap();

        KB_Scan_Config__c config = KB_Scan_Config__c.getInstance();
        if (config == null || String.isBlank(config.Content_Field_Mapping_JSON__c)) {
            return descriptors;
        }

        for (String raw : config.Content_Field_Mapping_JSON__c.split(',')) {
            if (descriptors.size() >= CONTENT_FIELD_COLUMN_CAP) {
                break;
            }
            String name = raw == null ? '' : raw.trim();
            if (String.isBlank(name)) {
                continue;
            }
            // Skip fields already covered by the BASE projection — the picker
            // already renders Title/Summary/etc. as their own columns.
            if (BASE_KAV_QUERY_FIELDS.contains(name.toLowerCase())) {
                continue;
            }
            Schema.SObjectField sof = fields.get(name.toLowerCase());
            if (sof == null) {
                continue;
            }
            String label = sof.getDescribe().getLabel();
            descriptors.add(new Map<String, String>{
                'apiName' => name,
                'label' => String.isNotBlank(label) ? label : name
            });
        }

        return descriptors;
    }

    /**
     * Build combined content from all available content fields
     * Handles both FAQ and KCS article types
     */
    public static String buildArticleContent(SObject article, List<String> contentFields) {
        if (article == null) {
            return '';
        }
        if (contentFields == null || contentFields.isEmpty()) {
            return '';
        }
        Map<String, Object> populated = article.getPopulatedFieldsAsMap();
        Schema.SObjectType objType = article.getSObjectType();
        Map<String, Schema.SObjectField> fieldMap = objType.getDescribe().fields.getMap();

        List<String> contentParts = new List<String>();
        for (String fieldName : contentFields) {
            if (!populated.containsKey(fieldName)) {
                continue;
            }
            Object raw = populated.get(fieldName);
            String value = raw == null ? null : String.valueOf(raw);
            if (String.isBlank(value)) {
                continue;
            }
            Schema.SObjectField sof = fieldMap.get(fieldName.toLowerCase());
            String label = sof != null ? sof.getDescribe().getLabel() : fieldName;
            contentParts.add('<h3>' + label + '</h3>' + value);
        }

        return String.join(contentParts, '\n\n');
    }

    /**
     * Extract raw content-field values keyed by API name for the LWC table.
     * Mirrors buildArticleContent's read pattern but returns a flat map of
     * String values rather than HTML — the picker datatable needs plain text
     * per cell. Only fields actually populated (and in the SELECT) are
     * returned; that's safe because the projection helper guarantees every
     * fieldName here was queried.
     */
    private Map<String, String> extractContentFieldValues(SObject article, List<String> contentFields) {
        Map<String, String> values = new Map<String, String>();
        if (contentFields == null || contentFields.isEmpty()) {
            return values;
        }
        Map<String, Object> populated = article.getPopulatedFieldsAsMap();
        for (String fieldName : contentFields) {
            if (!populated.containsKey(fieldName)) {
                continue;
            }
            Object raw = populated.get(fieldName);
            values.put(fieldName, raw == null ? null : String.valueOf(raw));
        }
        return values;
    }

    public List<KBAssessmentModels.ArticleWrapper> searchArticles(String searchTerm, Integer limitSize) {
        List<KBAssessmentModels.ArticleWrapper> wrappers = new List<KBAssessmentModels.ArticleWrapper>();

        String knowledgeObjectName = getKnowledgeObjectApiName();
        if (String.isBlank(knowledgeObjectName)) {
            return wrappers;
        }

        ArticleProjection proj = buildArticleProjection(knowledgeObjectName);

        KBRuntimeConfigService.RuntimeFilters runtimeFilters = KBRuntimeConfigService.getRuntimeFilters();
        String status = String.isNotBlank(runtimeFilters.publishStatus)
            ? runtimeFilters.publishStatus
            : 'Online';
        String language = String.isNotBlank(runtimeFilters.language)
            ? runtimeFilters.language
            : 'en_US';

        String query = 'SELECT ' + proj.selectClause
            + ' FROM ' + knowledgeObjectName
            + ' WHERE PublishStatus = \'' + String.escapeSingleQuotes(status) + '\''
            + ' AND Language = \'' + String.escapeSingleQuotes(language) + '\'';

        if (String.isNotBlank(searchTerm)) {
            String searchPattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';
            query += ' AND (Title LIKE \'' + searchPattern + '\'';
            query += ' OR ArticleNumber LIKE \'' + searchPattern + '\')';
        }

        query += ' ORDER BY LastModifiedDate DESC';
        query += ' LIMIT ' + limitSize;

        // System mode (default) on purpose — content-field read, same rationale
        // as fetchArticles above (FLS is customer-granted; USER_MODE would throw
        // for a Knowledge-read-only persona).
        List<SObject> articles = Database.query(query);

        for (SObject article : articles) {
            KBAssessmentModels.ArticleWrapper wrapper = new KBAssessmentModels.ArticleWrapper(article);
            wrapper.content = buildArticleContent(article, proj.contentFields);
            wrapper.contentFieldValues = extractContentFieldValues(article, proj.contentFields);
            wrappers.add(wrapper);
        }

        return wrappers;
    }

    // Maximum articles the "select all matching filter" flow will resolve.
    // Reads from KB_Scan_Config__c if configured; falls back to 10,000.
    @TestVisible
    private static Integer matchingFilterCap {
        get {
            if (matchingFilterCap == null) {
                KB_Scan_Config__c cfg = KB_Scan_Config__c.getInstance();
                // Future: add Matching_Filter_Cap__c field to KB_Scan_Config__c.
                // For now use the hardcoded default; this getter exists so the
                // field can be wired in without changing callers.
                matchingFilterCap = 10000;
            }
            return matchingFilterCap;
        }
        set;
    }

    public class MatchingFilterLimitException extends Exception {}

 // thrown by deleteAssessmentRun when the run is still in-flight, so a
    // non-terminal run can't be deleted out from under its async jobs.
    public class RunNotDeletableException extends Exception {}

    // Thrown by rerunAssessment when the run is still in-flight, so a
    // non-terminal run can't be re-dispatched into an overlapping second wave of
    // scoring shards over the same KB_Article_Assessment__c rows.
    public class RunNotRerunnableException extends Exception {}

    // Thrown by repointChildrenToCurrentVersions when a child row can't be moved
    // onto its parent's current published version. Fails the rerun loudly rather
    // than letting a dropped repoint create a duplicate scored row (one stale
    // archived-version row + one new online-version row for the same article).
    public class RepointFailedException extends Exception {}

    /**
     * Primary entry point — accepts the new `filterFormula` argument from
 * the advanced filter UI. When `filterFormula` is non-blank the
     * formula path runs; otherwise the legacy filterLogic AND/OR path runs
     * via buildDslWhereClause. Backwards compat is unconditional.
     */
    public KBAssessmentModels.ArticleFilterResult searchArticlesFiltered(
        String publishStatus, String titleSearch, String articleNumber,
        String articleType, Integer pageSize, Integer offset,
        List<KBAssessmentModels.FilterClause> filterClauses, String filterLogic,
        String filterFormula
    ) {
        KBAssessmentModels.ArticleFilterResult result = new KBAssessmentModels.ArticleFilterResult();

        String knowledgeObjectName = resolveKnowledgeObjectName(articleType);
        if (String.isBlank(knowledgeObjectName)) {
            return result;
        }

        ArticleProjection proj = buildArticleProjection(knowledgeObjectName);

        Integer safePage = (pageSize != null && pageSize > 0 && pageSize <= 200) ? pageSize : 25;
        // SOQL OFFSET max is 2000 — acceptable for MVP
        Integer safeOffset = (offset != null && offset >= 0 && offset <= 2000) ? offset : 0;

        String baseWhere = buildBaseWhere(
            publishStatus, titleSearch, articleNumber, filterClauses, filterLogic, filterFormula
        );

        // System mode (default) on purpose for both queries below — same
        // rationale as fetchArticles (the page query SELECTs content fields),
        // plus baseWhere is built from user filter clauses that can reference
        // content/custom fields, which USER_MODE would also FLS-enforce.
        String countQuery = 'SELECT COUNT() FROM ' + knowledgeObjectName + baseWhere;
        result.totalCount = Database.countQuery(countQuery);

        String query = 'SELECT ' + proj.selectClause
            + ' FROM ' + knowledgeObjectName + baseWhere
            + ' ORDER BY LastModifiedDate DESC'
            + ' LIMIT ' + safePage + ' OFFSET ' + safeOffset;

        List<SObject> articles = Database.query(query);

        for (SObject article : articles) {
            KBAssessmentModels.ArticleWrapper wrapper = new KBAssessmentModels.ArticleWrapper(article);
            wrapper.content = buildArticleContent(article, proj.contentFields);
            wrapper.contentFieldValues = extractContentFieldValues(article, proj.contentFields);
            result.articles.add(wrapper);
        }

        result.hasMore = (safeOffset + result.articles.size()) < result.totalCount;
        result.formulaFallbackApplied = this.formulaFallbackApplied;
        return result;
    }

    /**
     * Backwards-compat overload — delegates to the formula-aware variant
     * with `filterFormula = null`, which keeps the legacy AND/OR path.
     * Existing callers (Apex tests, other classes) compile unchanged.
     */
    public KBAssessmentModels.ArticleFilterResult searchArticlesFiltered(
        String publishStatus, String titleSearch, String articleNumber,
        String articleType, Integer pageSize, Integer offset,
        List<KBAssessmentModels.FilterClause> filterClauses, String filterLogic
    ) {
        return searchArticlesFiltered(
            publishStatus, titleSearch, articleNumber, articleType,
            pageSize, offset, filterClauses, filterLogic, null
        );
    }

    public KBAssessmentModels.ArticleFilterResult searchArticlesFiltered(
        String publishStatus, String titleSearch, String articleNumber,
        String articleType, Integer pageSize, Integer offset
    ) {
        return searchArticlesFiltered(
            publishStatus,
            titleSearch,
            articleNumber,
            articleType,
            pageSize,
            offset,
            new List<KBAssessmentModels.FilterClause>(),
            'AND',
            null
        );
    }

    /**
     * Formula-aware overload of resolveMatchingArticleIds. The legacy 6-arg
     * version delegates here with `filterFormula = null`.
     */
    public List<String> resolveMatchingArticleIds(
        String publishStatus, String titleSearch, String articleNumber,
        String articleType, List<KBAssessmentModels.FilterClause> filterClauses,
        String filterLogic, String filterFormula
    ) {
        List<String> ids = new List<String>();

        String knowledgeObjectName = resolveKnowledgeObjectName(articleType);
        if (String.isBlank(knowledgeObjectName)) {
            return ids;
        }

        String baseWhere = buildBaseWhere(
            publishStatus, titleSearch, articleNumber, filterClauses, filterLogic, filterFormula
        );

        // System mode (default) on purpose for both queries below: even though
        // the id-resolution query SELECTs only Id, baseWhere is built from the
        // user's filter clauses, which can reference admin-mapped Knowledge
        // content/custom fields. USER_MODE enforces FLS on WHERE fields, so it
        // would throw for a Knowledge-read-only persona lacking content-field
        // FLS (the customer's grant). System mode relaxes FLS/CRUD only, not
        // Knowledge data-category record visibility — so the running user still
        // only matches articles in their own categories here.
        String countQuery = 'SELECT COUNT() FROM ' + knowledgeObjectName + baseWhere;
        Integer total = Database.countQuery(countQuery);
        if (total > matchingFilterCap) {
            throw new MatchingFilterLimitException(
                'Filter matches ' + total + ' articles, exceeding the ' + matchingFilterCap +
                '-article limit. Refine your filter.'
            );
        }

        String query = 'SELECT Id FROM ' + knowledgeObjectName + baseWhere +
            ' ORDER BY LastModifiedDate DESC LIMIT ' + matchingFilterCap;
        for (SObject article : Database.query(query)) {
            ids.add((String) article.get('Id'));
        }
        return ids;
    }

    public List<String> resolveMatchingArticleIds(
        String publishStatus, String titleSearch, String articleNumber,
        String articleType, List<KBAssessmentModels.FilterClause> filterClauses,
        String filterLogic
    ) {
        return resolveMatchingArticleIds(
            publishStatus, titleSearch, articleNumber, articleType,
            filterClauses, filterLogic, null
        );
    }

    @TestVisible
    private String resolveKnowledgeObjectName(String articleType) {
        // articleType arrives from caller-supplied filter JSON and is concatenated
        // into the FROM clause of dynamic SOQL, so it must be validated against the
        // schema before use — never trusted verbatim. Accept it only if it names a
        // real Knowledge article-version object (exists in the global describe and
        // ends with '__kav'); otherwise fall back to the org's default Knowledge
        // object. This blocks object-name substitution in the dynamic query.
        if (!String.isBlank(articleType)) {
            String candidate = articleType.trim();
            if (candidate.endsWith('__kav')
                && Schema.getGlobalDescribe().containsKey(candidate)) {
                return candidate;
            }
        }
        return getKnowledgeObjectApiName();
    }

    private String buildBaseWhere(
        String publishStatus, String titleSearch, String articleNumber,
        List<KBAssessmentModels.FilterClause> filterClauses, String filterLogic
    ) {
        return buildBaseWhere(publishStatus, titleSearch, articleNumber, filterClauses, filterLogic, null);
    }

    private String buildBaseWhere(
        String publishStatus, String titleSearch, String articleNumber,
        List<KBAssessmentModels.FilterClause> filterClauses, String filterLogic,
        String filterFormula
    ) {
        this.formulaFallbackApplied = false;
        KBRuntimeConfigService.RuntimeFilters runtimeFilters = KBRuntimeConfigService.getRuntimeFilters();
        // 'All' is a sentinel meaning no PublishStatus filter — used when the UI needs to
        // show articles of any status (e.g. pre-selecting a Draft article from a record page).
        String status = String.isNotBlank(publishStatus)
            ? publishStatus
            : (String.isNotBlank(runtimeFilters.publishStatus) ? runtimeFilters.publishStatus : 'Online');
        String language = String.isNotBlank(runtimeFilters.language)
            ? runtimeFilters.language
            : 'en_US';

        String baseWhere = status == 'All'
            ? ' WHERE Language = \'' + String.escapeSingleQuotes(language) + '\''
            : ' WHERE PublishStatus = \'' + String.escapeSingleQuotes(status) + '\''
              + ' AND Language = \'' + String.escapeSingleQuotes(language) + '\'';

        if (String.isNotBlank(titleSearch)) {
            String searchPattern = '%' + String.escapeSingleQuotes(titleSearch) + '%';
            baseWhere += ' AND Title LIKE \'' + searchPattern + '\'';
        }

        if (String.isNotBlank(articleNumber)) {
            String numPattern = '%' + String.escapeSingleQuotes(articleNumber) + '%';
            baseWhere += ' AND ArticleNumber LIKE \'' + numPattern + '\'';
        }

        // Formula path takes precedence over legacy AND/OR logic. Both are
        // composed via KBFilterClauseCompiler so the type/operator/SOQL
        // injection guard is unconditional. An invalid formula short-circuits
        // back to the legacy path so the user's existing AND clauses still
        // narrow the result set rather than dumping the entire KB.
        if (String.isNotBlank(filterFormula)) {
            String formulaWhere = buildFormulaWhereClause(filterClauses, filterFormula);
            if (String.isNotBlank(formulaWhere)) {
                baseWhere += formulaWhere;
                return baseWhere;
            }
            // A formula was supplied but didn't compile to a usable clause —
            // we're about to fall through to the legacy AND/OR path, which
            // produces a different result set. Flag it so the caller can warn.
            this.formulaFallbackApplied = true;
        }

        baseWhere += buildDslWhereClause(filterClauses, filterLogic);
        return baseWhere;
    }

    /**
     * Compose the SOQL fragment for the formula path. Each clause is
     * compiled via KBFilterClauseCompiler; the parser substitutes the
     * resulting fragments by 1-based clause number. Throws nothing —
     * an invalid formula returns blank so the caller can fall through
     * to the legacy AND/OR path.
     */
    @TestVisible
    private String buildFormulaWhereClause(
        List<KBAssessmentModels.FilterClause> clauses, String formula
    ) {
        if (clauses == null || clauses.isEmpty()) return '';
        if (String.isBlank(formula)) return '';

        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> fields =
            KBKnowledgeFieldDescribeService.getFieldMap();
        if (fields == null || fields.isEmpty()) return '';

        Map<Integer, String> clauseSoqlByNumber = new Map<Integer, String>();
        Integer position = 0;
        for (KBAssessmentModels.FilterClause c : clauses) {
            position++;
            if (c == null) continue;
            KBFilterClauseCompiler.CompileResult cr =
                KBFilterClauseCompiler.compile(c, fields);
            if (cr.valid && String.isNotBlank(cr.soqlFragment)) {
                clauseSoqlByNumber.put(position, cr.soqlFragment);
            }
        }
        if (clauseSoqlByNumber.isEmpty()) return '';

        try {
            KBFilterFormulaParser.ParsedFormula parsed =
                KBFilterFormulaParser.parse(formula, clauses.size());
            // Every referenced clause must have produced a valid fragment —
            // otherwise the formula is unsatisfiable. Drop the clause
            // silently? No: surface the failure so the caller falls back
            // to the legacy path rather than emitting a partial WHERE that
            // returns the wrong rows.
            for (Integer ref : parsed.referencedClauses) {
                if (!clauseSoqlByNumber.containsKey(ref)) {
                    System.debug(LoggingLevel.WARN,
                        'KBAssessmentService.buildFormulaWhereClause: clause '
                        + ref + ' could not be compiled, falling back to legacy path');
                    return '';
                }
            }
            String soql = KBFilterFormulaParser.compile(parsed, clauseSoqlByNumber);
            if (String.isBlank(soql)) return '';
            return ' AND ' + soql;
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // Surface the parse error in debug logs but don't fail the
            // whole search — fall back to the legacy AND/OR path so a typo
            // in the formula doesn't dump the entire KB to the UI.
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.buildFormulaWhereClause: invalid formula \''
                + formula + '\': ' + e.getMessage());
            return '';
        }
    }

    public static Integer getPublishedArticleCount() {
        String objectName = getKnowledgeObjectApiNameStatic();
        if (String.isBlank(objectName)) {
            return 0;
        }
        KBRuntimeConfigService.RuntimeFilters runtimeFilters = KBRuntimeConfigService.getRuntimeFilters();
        String status = String.isNotBlank(runtimeFilters.publishStatus)
            ? runtimeFilters.publishStatus
            : 'Online';
        String language = String.isNotBlank(runtimeFilters.language)
            ? runtimeFilters.language
            : 'en_US';
        String query = 'SELECT COUNT() FROM ' + objectName
            + ' WHERE PublishStatus = \'' + String.escapeSingleQuotes(status) + '\''
            + ' AND Language = \'' + String.escapeSingleQuotes(language) + '\'';
        // System mode (default) on purpose: this is an org-wide count of the
        // published KB used for sizing/dashboards. USER_MODE would narrow it to
        // the running user's data-category-visible slice, understating the true
        // KB size. Fields here are standard (PublishStatus/Language) — the
        // deliberate part is the whole-KB (row-level) scope, not FLS.
        return Database.countQuery(query);
    }

    public static List<Map<String, String>> getAllKnowledgeObjectApiNames() {
        List<Map<String, String>> results = new List<Map<String, String>>();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        for (String objectName : globalDescribe.keySet()) {
            if (objectName.endsWith('__kav')) {
                Schema.DescribeSObjectResult descr = globalDescribe.get(objectName).getDescribe();
                results.add(new Map<String, String>{
                    'value' => objectName,
                    'label' => descr.getLabel()
                });
            }
        }
        if (results.isEmpty() && globalDescribe.containsKey('Knowledge__kav')) {
            Schema.DescribeSObjectResult descr = globalDescribe.get('Knowledge__kav').getDescribe();
            results.add(new Map<String, String>{
                'value' => 'Knowledge__kav',
                'label' => descr.getLabel()
            });
        }
        return results;
    }

    public static String getKnowledgeObjectApiNameStatic() {
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        for (String objectName : globalDescribe.keySet()) {
            if (objectName.endsWith('__kav')) {
                return objectName;
            }
        }
        if (globalDescribe.containsKey('Knowledge__kav')) {
            return 'Knowledge__kav';
        }
        return null;
    }

    private String getKnowledgeObjectApiName() {
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        for (String objectName : globalDescribe.keySet()) {
            if (objectName.endsWith('__kav')) {
                return objectName;
            }
        }

        if (globalDescribe.containsKey('Knowledge__kav')) {
            return 'Knowledge__kav';
        }

        return null;
    }

    @TestVisible
    private Map<String, Integer> getDataCategoryCounts(List<String> articleIds) {
        Map<String, Integer> counts = new Map<String, Integer>();
        if (articleIds == null || articleIds.isEmpty()) return counts;

        // Knowledge category assignments live on Knowledge__DataCategorySelection (a junction).
        // The bare `DataCategorySelection` name is not a queryable top-level entity.
        if (!Schema.getGlobalDescribe().containsKey('Knowledge__DataCategorySelection')) {
            return counts;
        }
        try {
            String query = 'SELECT ParentId FROM Knowledge__DataCategorySelection WHERE ParentId IN :articleIds';
            // System mode (default) on purpose: this is a scoring-signal count
            // over the articles the run already resolved in system mode, on the
            // Knowledge category junction. Keeping it system-mode matches the
            // whole-KB scan scope and avoids a USER_MODE access gap on the
            // junction silently zeroing an article's category count.
            List<SObject> categories = Database.query(query);
            for (SObject cat : categories) {
                String parentId = (String)cat.get('ParentId');
                counts.put(parentId, (counts.containsKey(parentId) ? counts.get(parentId) : 0) + 1);
            }
        } catch (Exception e) {
            // Log but don't fail the run — category data is one signal among many.
            System.debug(LoggingLevel.WARN,
                'getDataCategoryCounts: Knowledge__DataCategorySelection query failed: ' + e.getMessage());
        }
        return counts;
    }

    public List<KB_Assessment_Run__c> getRecentAssessmentRuns(Integer limitCount) {
        Integer queryLimit = (limitCount != null && limitCount > 0) ? limitCount : 10;
        return [
            SELECT Id, Name, Run_Name__c, Description__c, Status__c, Overall_Score__c, Total_Articles__c,
                   Ready_Count__c, Needs_Work_Count__c, Not_Ready_Count__c,
                   Completed_At__c, CreatedDate, Scan_Start_Time__c, Total_Duration_Ms__c,
                   Owner.Name
            FROM KB_Assessment_Run__c
            WHERE Assessment_Types__c INCLUDES ('Readiness')
            ORDER BY CreatedDate DESC
            LIMIT :queryLimit
        ];
    }

    public void deleteAssessmentRun(Id runId) {
        if (runId == null) {
            return;
        }
 // the delete gating on the LWC row (disabled while running) is
        // UI-only. Mirror cancelAssessmentRun's server-side guard so a direct
        // @AuraEnabled call (or a stale client whose row status lags the backend)
        // can't delete an in-flight run and orphan its async jobs. Read the status
        // FOR UPDATE (serialises against the dimension-fan-out / cancel writers)
        // and refuse unless the run has reached a terminal state.
        List<KB_Assessment_Run__c> runs = [
            SELECT Id, Status__c
            FROM KB_Assessment_Run__c
            WHERE Id = :runId
            WITH USER_MODE
            FOR UPDATE
        ];
        if (runs.isEmpty()) {
            return; // already gone — idempotent
        }
        if (
            String.isNotBlank(runs[0].Status__c) &&
            !TERMINAL_STATUSES.contains(runs[0].Status__c)
        ) {
            throw new RunNotDeletableException(
                'This assessment is still running. Cancel it before deleting.'
            );
        }
 // /— deleting a run removes ALL of its pipeline candidate
 // records (Duplicate + Enrichment), regardless of status. As of the
        // candidate objects are master-detail children of the run, so this is a
        // platform CASCADE delete — no explicit candidate delete needed. The
        // cascade is governed by delete access to the PARENT run (not the child),
 // which sidesteps the old problem (Manager had allowDelete=false on
        // candidates). The generated Knowledge drafts are LEFT in place — the
        // Enrichment_Candidate__c → draft link is a plain field, not a cascade.
        // The user is warned in the UI before confirming.
        //
 // KPE/pipeline-run cleanup: KB_Pipeline_Run__c and its
        // Knowledge_Pair_Evaluation__c children are LOOKUP-linked (not
        // master-detail), so they do NOT ride the run cascade. Left behind, their
        // globally-unique Composite_Version_Key__c rows would squat on the pair
        // key and block a later run's KPE upsert (the very bug this cleanup pairs
        // with the run-scoped key fix). Delete them explicitly, in system mode,
        // BEFORE the run cascade — the caller has already been authorised via the
        // USER_MODE FOR UPDATE read of the parent run above.
        deleteRunPipelineArtifacts(runId);
        Database.delete(runs, AccessLevel.USER_MODE);
    }

    /**
     * System-mode cleanup of a run's lookup-linked pipeline artifacts on delete:
     * the KB_Pipeline_Run__c rows and their Knowledge_Pair_Evaluation__c (KPE)
     * children. These are NOT master-detail children of the run, so the platform
 * cascade misses them. System mode because the Manager persona doesn't
     * need direct delete on the KPE/pipeline-run objects — authorisation is the
     * parent-run delete access already checked in deleteAssessmentRun.
     */
    @TestVisible
    private void deleteRunPipelineArtifacts(Id runId) {
        if (runId == null) return;
        List<KB_Pipeline_Run__c> pipelineRuns = [
            SELECT Id FROM KB_Pipeline_Run__c WHERE Assessment_Run__c = :runId
        ];
        if (pipelineRuns.isEmpty()) return;

        List<Knowledge_Pair_Evaluation__c> evals = [
            SELECT Id FROM Knowledge_Pair_Evaluation__c
            WHERE Pipeline_Run__c IN :pipelineRuns
        ];

 // review — do NOT swallow a KPE-delete failure. These rows are the
        // whole reason this method exists: their globally-unique
        // Composite_Version_Key__c is not cleared by the run cascade (lookup-linked),
        // so a survivor can squat on the pair key and re-trigger the DUPLICATE_VALUE
        // this cleanup prevents (esp. on the run-agnostic key fallback). Soft-fail
        // the DML (so one locked row doesn't abort the whole batch mid-way) but
        // INSPECT the results and throw if any KPE row survived — the caller runs
        // this BEFORE deleting the run, so a throw rolls the transaction back with
        // nothing half-deleted and the user simply retries the delete.
        List<String> failures = new List<String>();
        if (!evals.isEmpty()) {
            for (Database.DeleteResult r : Database.delete(evals, false, AccessLevel.SYSTEM_MODE)) {
                if (!r.isSuccess()) {
                    failures.add('KPE ' + r.getId() + ': ' + summarizeDmlErrors(r.getErrors()));
                }
            }
        }
        // Pipeline-run rows are lookup orphans if left, but not a key-collision
        // source; still surface any failure so cleanup is all-or-nothing.
        for (Database.DeleteResult r : Database.delete(pipelineRuns, false, AccessLevel.SYSTEM_MODE)) {
            if (!r.isSuccess()) {
                failures.add('PipelineRun ' + r.getId() + ': ' + summarizeDmlErrors(r.getErrors()));
            }
        }
        if (!failures.isEmpty()) {
            throw new PipelineArtifactCleanupException(
                'Could not clean up this run\'s pipeline cache before deleting it — '
                + 'retry the delete. Leftover pair-evaluation rows can block a future '
                + 'run\'s deduplication. Details: ' + String.join(failures, '; ')
            );
        }
    }

    private static String summarizeDmlErrors(List<Database.Error> errors) {
        List<String> parts = new List<String>();
        for (Database.Error e : errors) {
            parts.add(e.getStatusCode() + ' ' + e.getMessage());
        }
        return String.join(parts, ', ');
    }

    public class PipelineArtifactCleanupException extends Exception {}

    private class RunCreationResult {
        Id runId;
        Id pipelineRunId;
        String assessmentTypesCsv;
        String requestedScope;
    }

    private Map<String, Object> buildFilterPayload(
        KBAssessmentModels.AssessmentRunOptions options,
        List<String> articleIds,
        String orchestrationPhase
    ) {
        Map<String, Object> payload = new Map<String, Object>{
            'logic' => String.isNotBlank(options.filterLogic) ? options.filterLogic : 'AND',
            'clauses' => options.filterClauses,
            'orchestrationPhase' => orchestrationPhase
        };
 // /— Embed the explicit id list only for a 'Selected' scope
        // that is SMALL enough to fit. The frozen list is just a recovery
        // fallback; the run's child KB_Article_Assessment__c rows are the
        // primary scope-recovery path (see recoverRunArticleIds), so omitting
        // the list is always safe. Two cases must NOT persist it:
        //   - 'MatchingFilter' scope: the resolved set can be up to 10,000 ids,
        //     far past the 32,768-char Filter_DSL_JSON__c limit.
 // a large 'Selected' scope: assumed Selected = a small
 // hand-picked set, but clone can produce a huge Selected run
        //     (cloning a MatchingFilter run resolves its scope to explicit ids).
        //     Guarding on size prevents a STRING_TOO_LONG / serializeForJsonField
        //     throw when that list is large.
        String requestedScope = String.isNotBlank(options.requestedScope) ? options.requestedScope : 'Selected';
        if (requestedScope == 'Selected'
            && articleIds != null
            && articleIds.size() <= FROZEN_ARTICLE_ID_CAP) {
            payload.put('articleIds', articleIds);
        }
        // Persist the formula alongside the legacy logic+clauses so a
        // future re-run / regression report can rebuild the same WHERE.
        // Null on legacy payloads is fine — additive change only.
        if (String.isNotBlank(options.filterFormula)) {
            payload.put('formula', options.filterFormula);
        }
        return payload;
    }

    /**
 * Serialize a value destined for a long-text *_JSON__c field and
     * FAIL FAST (clear KnowledgeAIException naming the limit) if it would
     * overflow the field's max length, instead of letting the platform throw a
     * cryptic STRING_TOO_LONG on insert. Mirrors the Schema-resolved length
     * guard used by recordAsyncJobs for Async_Job_Ids__c — the cap is read from
     * the field describe so a future field-length change is picked up
     * automatically.
     *
     * @param value   the object to JSON-serialize (filter payload / scope map)
     * @param maxLen  the target field's max length (Schema getLength())
     * @param fieldLabel human-readable field name for the error message
     */
    private static String serializeForJsonField(Object value, Integer maxLen, String fieldLabel) {
        String serialized = JSON.serialize(value);
        if (serialized != null && maxLen != null && serialized.length() > maxLen) {
            throw new KnowledgeAIException(
                'Cannot persist ' + fieldLabel + ': the serialized value is '
                + serialized.length() + ' characters, exceeding the field maximum of '
                + maxLen + '. Reduce the scope or filter complexity and try again.'
            );
        }
        return serialized;
    }

    private RunCreationResult createRunRecord(
        List<String> articleIds,
        KBAssessmentModels.AssessmentRunOptions options,
        Set<String> assessmentTypes,
        Set<String> runSelectedDimensions,
        Map<String, Decimal> runEffectiveWeights,
        String executionMode,
        String initialStatus,
        Map<String, Object> filterPayload
    ) {
        RunCreationResult result = new RunCreationResult();
        String assessmentTypesCsv = toMultiSelectValue(new List<String>(assessmentTypes), 'Readiness');
        String requestedScope = String.isNotBlank(options.requestedScope) ? options.requestedScope : 'Selected';

 // fail fast (clear error) if the serialized filter payload would
        // overflow Filter_DSL_JSON__c, rather than a cryptic STRING_TOO_LONG on
        // insert. buildFilterPayload already omits the (large) MatchingFilter id
        // list, so this is a backstop against an unusually large clause/formula.
        String filterDslJson = serializeForJsonField(
            filterPayload,
            Schema.SObjectType.KB_Assessment_Run__c.fields.Filter_DSL_JSON__c.getLength(),
            'Filter_DSL_JSON__c'
        );

        Id pipelineRunId = maybeCreatePipelineRun(articleIds, options, executionMode);

        KB_Assessment_Run__c run = new KB_Assessment_Run__c(
            Status__c = String.isNotBlank(initialStatus) ? initialStatus : 'In Progress',
            // Stamp the scoring-start clock so the duration metrics measure
            // actual scan time, not wall-clock since CreatedDate. For a brand-new
 // run CreatedDate ≈ now, but a rerun keeps the original run's
            // CreatedDate — without this stamp its Scoring_Duration_Ms__c would
            // count all the idle time since the run was first created.
            Scan_Start_Time__c = Datetime.now(),
            Total_Articles__c = articleIds.size(),
            // Run *intent* at creation: true iff at least one selected dimension
            // is LLM-backed. The actual per-score truth (gate-skips, catch-arm
            // fallbacks) is recorded on KB_Dimension_Result__c.Scorer_Mode__c and
 // reconciled back onto this field at finalization. See.
            Used_LLM__c = DimensionRegistry.anyRequiresLLM(runSelectedDimensions),
            Assessment_Types__c = assessmentTypesCsv,
            Requested_Scope__c = requestedScope,
            Selected_Dimensions_JSON__c = JSON.serialize(new List<String>(runSelectedDimensions)),
            Effective_Weights_JSON__c = JSON.serialize(runEffectiveWeights),
            Filter_DSL_JSON__c = filterDslJson,
 // user-supplied name/description from the "Assessment details"
            // step. Defensively trimmed/truncated — the field is Text(255). Left
            // blank when the caller doesn't supply one; the All Assessments list
            // falls back to the auto-number Name for display.
            Run_Name__c = sanitiseRunName(options.runName),
            Description__c = String.isNotBlank(options.description) ? options.description.trim() : null,
            Pipeline_Run__c = pipelineRunId
        );
        insert run;

        if (pipelineRunId != null) {
            update new KB_Pipeline_Run__c(
                Id = pipelineRunId,
                Assessment_Run__c = run.Id
            );
        }

        // Front-of-pipeline progress event so the LWC has a heartbeat to
        // attach to before the dimension queueables enqueue. Without this the
        // first event the client sees comes from KBAssessmentPipelineCallback,
        // which can be tens of seconds (or never, on quality-gated paths)
        // after the run row is inserted — leaving the spinner stuck on
        // "Assessment queued".
        publishRunQueuedEvent(run.Id, articleIds.size());

        result.runId = run.Id;
        result.pipelineRunId = pipelineRunId;
        result.assessmentTypesCsv = assessmentTypesCsv;
        result.requestedScope = requestedScope;
        return result;
    }

    /**
 * normalise a user-supplied run name for persistence to the
     * Text(255) Run_Name__c. Trims whitespace, returns null when blank (so the
     * UI can fall back to the auto-number Name), and truncates over-length
     * input rather than letting the insert fail with STRING_TOO_LONG.
     */
    @TestVisible
    private static String sanitiseRunName(String rawName) {
        if (String.isBlank(rawName)) {
            return null;
        }
        String trimmed = rawName.trim();
        return trimmed.length() > 255 ? trimmed.substring(0, 255) : trimmed;
    }

    private static void publishRunQueuedEvent(Id runId, Integer totalArticles) {
        try {
            KB_Assessment_Progress__e evt = new KB_Assessment_Progress__e(
                Assessment_Id__c = runId,
                Status__c = 'Queued',
                Message__c = 'Run created. Dispatching scorers...',
                Total_Articles__c = totalArticles
            );
            EventBus.publish(evt);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Failed to publish queued event: ' + e.getMessage());
        }
    }

    /**
     * Tiered dispatch. Picks queueable fan-out or Batch Apex based on article
     * count and LLM mode. Thresholds come from KB_Scan_Config__c with safe
     * defaults. The sync tier (1–10 articles) is handled by
     * KBAssessmentFacade.assessArticlesSync; callers that reach this method
     * are already committed to async.
     *
     * Before dispatching, creates the parent KB_Article_Assessment__c rows
     * (one per article) so the dimension workers have a master to link to.
     */

    private void enqueueAssessmentRun(
        Id runId,
        List<String> articleIds,
        Set<String> runSelectedDimensions,
        Map<String, Decimal> runEffectiveWeights,
        Id pipelineRunId,
        String executionMode
    ) {
        preCreateParentAssessments(runId, articleIds);

        Integer count = articleIds == null ? 0 : articleIds.size();
        Integer queueableCap = resolveQueueableThreshold();

        if (count <= queueableCap) {
            // dispatchQueueableFanOut persists its own task tokens (it chunks
            // LLM dimensions, so the dispatched set is tokens, not dim names).
            dispatchQueueableFanOut(runId, articleIds, runSelectedDimensions);
        } else {
            persistDispatchedDimensions(runId, runSelectedDimensions);
            dispatchBatch(runId, articleIds, runSelectedDimensions);
        }
    }

    /**
     * Pre-create one KB_Article_Assessment__c per article so per-dimension
     * workers have a parent to link their child rows to. Parents get filled
     * in with aggregates after all dims complete.
     */
    private void preCreateParentAssessments(Id runId, List<String> articleIds) {
        if (articleIds == null || articleIds.isEmpty()) return;
        Set<String> existing = new Set<String>();
        for (KB_Article_Assessment__c a : [
            SELECT Knowledge__c FROM KB_Article_Assessment__c WHERE Assessment_Run__c = :runId
        ]) {
            existing.add(a.Knowledge__c);
        }

        // Resolve Id values up front so we can bulk-fetch titles.
        List<Id> validIds = new List<Id>();
        for (String artId : articleIds) {
            if (existing.contains(artId)) continue;
            Id asId;
            try { asId = Id.valueOf(artId); } catch (Exception e) { continue; }
            validIds.add(asId);
        }
        if (validIds.isEmpty()) return;

        // Fetch denormalised identifiers so parent rows are complete from insert.
        // Downstream score updates don't touch these fields, so they need to be
 // populated here OR by the record builder.
        Map<Id, String> titleById = new Map<Id, String>();
        Map<Id, String> kaIdById = new Map<Id, String>();
        Map<Id, String> articleNumberById = new Map<Id, String>();
        String kavName = getKnowledgeObjectApiName();
        if (String.isNotBlank(kavName)) {
            String q = 'SELECT Id, Title, ArticleNumber, KnowledgeArticleId FROM ' + kavName + ' WHERE Id IN :validIds';
            // System mode (default) on purpose: seeds parent assessment rows for
            // the whole run scope, which was resolved in system mode so the scan
            // covers the entire KB. Title is a standard field, but a USER_MODE
            // read would drop any article outside the running user's
            // data-category visibility, leaving the run with missing parent rows.
            for (SObject s : Database.query(q)) {
                Id sid = (Id) s.get('Id');
                titleById.put(sid, (String) s.get('Title'));
                kaIdById.put(sid, (String) s.get('KnowledgeArticleId'));
                articleNumberById.put(sid, (String) s.get('ArticleNumber'));
            }
        }

        List<KB_Article_Assessment__c> toInsert = new List<KB_Article_Assessment__c>();
        for (Id asId : validIds) {
            String title = titleById.get(asId);
            toInsert.add(new KB_Article_Assessment__c(
                Assessment_Run__c = runId,
                Knowledge__c = asId,
                Knowledge_Article_Id__c = kaIdById.get(asId),
                Article_Number__c = articleNumberById.get(asId),
                Article_Title__c = String.isNotBlank(title) && title.length() > 255
                    ? title.substring(0, 255) : title
            ));
        }
        if (!toInsert.isEmpty()) {
            Database.insert(toInsert, false);
        }
    }

    private void persistDispatchedDimensions(Id runId, Set<String> dims) {
        update new KB_Assessment_Run__c(
            Id = runId,
            Dispatched_Dimensions__c = String.join(new List<String>(dims), ','),
            Completed_Dimensions__c = null
        );
    }

    // Articles per queueable when an LLM dimension is split for parallelism (B).
    // Each LLM dim becomes ceil(N/chunk) queueables that run concurrently in the
    // flex queue instead of one queueable looping all N articles serially. 10
    // keeps each hop's wall-clock well under the queueable limit (~10 callouts ×
    // ~7s ≈ 70s) while bounding the queueable count (50-article cap × 3 LLM dims
    // / 10 = 15 LLM tasks + 3 deterministic = 18, within the 50-enqueue/tx cap).
    @TestVisible
    private static Integer llmFanOutChunkSize = 10;

    /**
     * Fan out scoring queueables for the ≤cap tier. Deterministic dimensions
     * (Freshness/Duplication/Conflict) stay as one queueable each — they do no
     * callouts and process hundreds of articles per hop cheaply. LLM dimensions
     * (Completeness/Structure/Clarity) are split into article-chunks so they run
     * in parallel rather than one serial per-article loop.
     *
     * Completion is tracked by opaque integer task tokens (0..N-1) persisted to
     * Dispatched_Dimensions__c — NOT dimension names — because one dimension can
     * now span several queueables. markCompleted() counts tokens, so the gate is
     * "all tasks done", agnostic to how many tasks a dimension contributed.
     */
    private void dispatchQueueableFanOut(Id runId, List<String> articleIds, Set<String> dims) {
        // Build the task list first so we can persist the full token set BEFORE
        // any queueable runs (avoids a fast task finishing against an empty
        // dispatched set and mis-firing finalization).
        List<KBAssessmentModels.ScoringTask> tasks = buildScoringTasks(articleIds, dims);

        List<String> tokens = new List<String>();
        for (KBAssessmentModels.ScoringTask t : tasks) tokens.add(t.token);
        update new KB_Assessment_Run__c(
            Id = runId,
            Dispatched_Dimensions__c = String.join(tokens, ','),
            Completed_Dimensions__c = null
        );

        // Capture the run's current dispatch generation so each worker can detect
        // a rerun that started a newer wave and decline to write (twin of the
        // batch-tier gate). Coalesce null to 0 so a real wave always carries a
        // non-null value — the queueable treats a null generation as "not
        // captured" (gate skipped), so passing null here would silently disable
        // the gate. Read here (not threaded from the caller) so both the new-run
        // and rerun dispatch paths pick up the right value.
        Decimal generation = 0;
        for (KB_Assessment_Run__c gr : [
            SELECT Dispatch_Generation__c FROM KB_Assessment_Run__c WHERE Id = :runId LIMIT 1
        ]) {
            generation = gr.Dispatch_Generation__c != null ? gr.Dispatch_Generation__c : 0;
        }

        List<Id> jobIds = new List<Id>();
        for (KBAssessmentModels.ScoringTask t : tasks) {
            Id qid = System.enqueueJob(new KBAssessmentDimensionQueueable(
                runId, t.articleIds, t.dimensionName, t.token, generation
            ));
            if (qid != null) jobIds.add(qid);
        }
        recordAsyncJobs(runId, jobIds);
    }

    /**
     * Decompose (dimensions × articles) into scoring tasks. LLM dims chunk by
     * llmFanOutChunkSize; deterministic dims get one task covering all articles.
     * Tokens are sequential integers so the dispatched-token CSV stays compact
     * (well under the 255-char field limit even at the 50-article cap).
     */
    @TestVisible
    private List<KBAssessmentModels.ScoringTask> buildScoringTasks(List<String> articleIds, Set<String> dims) {
        List<KBAssessmentModels.ScoringTask> tasks = new List<KBAssessmentModels.ScoringTask>();
        Integer token = 0;
        Integer total = articleIds == null ? 0 : articleIds.size();
        for (String dim : dims) {
            DimensionRegistry.DimensionDefinition def = DimensionRegistry.get(dim);
            Boolean isLLM = def != null && def.requiresLLM;
            Integer chunk = (isLLM && llmFanOutChunkSize > 0) ? llmFanOutChunkSize : total;
            if (chunk <= 0 || total == 0) {
                // No articles — still emit one task so the dimension completes.
                tasks.add(new KBAssessmentModels.ScoringTask(
                    String.valueOf(token++), dim, articleIds
                ));
                continue;
            }
            for (Integer start = 0; start < total; start += chunk) {
                Integer endIdx = Math.min(start + chunk, total);
                List<String> sub = new List<String>();
                for (Integer i = start; i < endIdx; i++) sub.add(articleIds[i]);
                tasks.add(new KBAssessmentModels.ScoringTask(
                    String.valueOf(token++), dim, sub
                ));
            }
        }
        return tasks;
    }

    // Parallel scoring shards for the >50 path. Chunks within ONE batch job run
    // serially, so we split the run into up to this many SEPARATE batch jobs
    // (distinct jobs run concurrently up to the platform's 5-job cap). 5 shards
    // → ~5x scoring throughput on large runs vs. the former single serial batch.
    //
    // Both knobs are admin-tunable via KB_Scan_Config__c (Shard_Threshold__c /
    // Max_Scoring_Shards__c), mirroring Queueable_Threshold__c. These are the
    // DEFAULTS used when the setting is blank/0, and MAX_SCORING_SHARDS_CAP is a
    // hard ceiling the resolver enforces regardless of the admin value (the
    // platform allows at most 5 concurrently-running batch jobs).
    @TestVisible
    private static Integer maxScoringShards = 5;
    private static final Integer MAX_SCORING_SHARDS_CAP = 5;
    // Default shard threshold (fallback when Shard_Threshold__c is blank/0).
    // 51 = shard any run that reaches the Batch tier at all (runs of 50 or
    // fewer take the queueable tier). The 5-job arrival overhead is negligible
    // and any batch run has >1 chunk of work, so sharding effectively always
    // wins on wall-clock; admins can raise it via the setting to keep mid-size
    // runs on a single batch slot.
    @TestVisible
    private static Integer minArticlesToShard = 51;

    // Resolve the shard threshold from KB_Scan_Config__c.Shard_Threshold__c,
    // falling back to minArticlesToShard when blank/0. No upper cap — an admin
    // can raise it to keep large runs on the single-batch path if desired.
    private Integer resolveShardThreshold() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getInstance();
        if (cfg != null && cfg.Shard_Threshold__c != null && cfg.Shard_Threshold__c > 0) {
            return cfg.Shard_Threshold__c.intValue();
        }
        return minArticlesToShard;
    }

    // Resolve the max shard count from KB_Scan_Config__c.Max_Scoring_Shards__c,
    // falling back to maxScoringShards when blank/0. Capped at
    // MAX_SCORING_SHARDS_CAP — the platform's concurrent-batch-job limit — so a
    // misconfigured high value can never exceed what the platform will run.
    private Integer resolveMaxScoringShards() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getInstance();
        Integer configured = maxScoringShards;
        if (cfg != null && cfg.Max_Scoring_Shards__c != null && cfg.Max_Scoring_Shards__c > 0) {
            configured = cfg.Max_Scoring_Shards__c.intValue();
        }
        return Math.min(configured, MAX_SCORING_SHARDS_CAP);
    }

    private void dispatchBatch(Id runId, List<String> articleIds, Set<String> dims) {
        Integer count = articleIds == null ? 0 : articleIds.size();

        // Small large-run: single batch (legacy path), no barrier.
        if (count < resolveShardThreshold()) {
            KBAssessmentBatch batch = new KBAssessmentBatch(runId, dims);
            Id bid = Database.executeBatch(batch, batch.getScopeSize());
            if (bid != null) recordAsyncJobs(runId, new List<Id>{ bid });
            return;
        }

        // Partition into round-robin shards so each gets a similar article count
        // (and a similar spread of cheap/expensive articles).
        Integer shardCount = Math.min(resolveMaxScoringShards(), count);
        List<List<String>> shards = new List<List<String>>();
        for (Integer i = 0; i < shardCount; i++) shards.add(new List<String>());
        for (Integer i = 0; i < count; i++) {
            shards[Math.mod(i, shardCount)].add(articleIds[i]);
        }

        // Seed the join barrier BEFORE launching any shard so no shard's finish()
        // can race to 0 against an unset barrier. On a rerun this overwrites the
        // -1 sentinel a prior cancel parked here — intended and safe, because an
        // aborted prior-wave shard never runs finish()/claimIfLast() (it only
        // drains its current chunk), so no straggler decrements this reseeded
        // count. The generation gate stops that straggler writing data; this
        // reseed owns the barrier for the fresh wave.
        update new KB_Assessment_Run__c(
            Id = runId,
            Scoring_Shards_Outstanding__c = shardCount
        );

        List<Id> jobIds = new List<Id>();
        Integer launched = 0;
        // 1-based shard index stamped on each shard's progress events
 // (Current_Batch__c) so the runner LWC sums shard-local counts.
        Integer shardIndex = 0;
        for (List<String> shard : shards) {
            shardIndex++;
            KBAssessmentBatch batch = new KBAssessmentBatch(runId, dims, shard, shardIndex);
            Id bid = Database.executeBatch(batch, batch.getScopeSize());
            if (bid != null) { jobIds.add(bid); launched++; }
        }
        if (!jobIds.isEmpty()) recordAsyncJobs(runId, jobIds);

        // If fewer shards launched than planned, correct the barrier so the ones
        // that DID launch can still drive it to 0 and finalize.
        if (launched != shardCount) {
            try {
                KB_Assessment_Run__c run = [
                    SELECT Id, Scoring_Shards_Outstanding__c FROM KB_Assessment_Run__c
                    WHERE Id = :runId FOR UPDATE
                ];
                run.Scoring_Shards_Outstanding__c = Math.max(0, launched);
                update run;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'dispatchBatch: barrier correction failed: ' + e.getMessage());
            }
        }
        // If NOTHING launched, finalize directly so the run doesn't hang.
        if (launched == 0) {
            KBAssessmentPipelineDispatcher.dispatchFinalization(runId);
        }
    }

    /**
     * Resolve the ceiling of the queueable tier. Admins can raise it via
     * KB_Scan_Config__c.Queueable_Threshold__c, but the cap is 50 regardless.
 * Post- Completeness is 1 callout/article so the callout governor
     * alone would allow more; the 50-cap is a wall-clock guard against the
     * ~7s/callout latency on Storm orgs (50 × 7s ≈ the queueable's practical
     * wall-clock limit).
     */
    private Integer resolveQueueableThreshold() {
        KB_Scan_Config__c cfg = KB_Scan_Config__c.getInstance();
        Integer configured = 50;
        if (cfg != null && cfg.Queueable_Threshold__c != null && cfg.Queueable_Threshold__c > 0) {
            configured = cfg.Queueable_Threshold__c.intValue();
        }
        return Math.min(configured, 50);
    }

    private Set<String> normalizeSelectedDimensions(List<String> rawSelected) {
        Set<String> activeNames = DimensionRegistry.getActiveDeveloperNames();
        Set<String> selected = new Set<String>();
        if (rawSelected != null) {
            for (String dim : rawSelected) {
                if (activeNames.contains(dim)) {
                    selected.add(dim);
                }
            }
        }
        if (selected.isEmpty()) {
            selected.addAll(activeNames);
        }
        return selected;
    }

    private Set<String> normalizeAssessmentTypes(List<String> rawTypes) {
        // Preserves Deduplication as its own type so determinePipelineExecutionMode
        // can surface it. Callers that pass ['Readiness', 'Deduplication'] get both
        // back. The old collapse to 'Readiness' here meant the dedup pipeline
        // never dispatched — removed 2026-05-01.
        Set<String> normalized = new Set<String>();
        Set<String> allowed = new Set<String>{ 'Readiness', 'Deduplication' };
        if (rawTypes != null) {
            for (String t : rawTypes) {
                if (String.isNotBlank(t) && allowed.contains(t.trim())) {
                    normalized.add(t.trim());
                }
            }
        }
        if (normalized.isEmpty()) {
            normalized.add('Readiness');
        }
        // Deduplication implies Readiness (scoring has to happen first)
        if (normalized.contains('Deduplication')) {
            normalized.add('Readiness');
        }
        return normalized;
    }

    private Map<String, Decimal> getBaseWeights() {
        return DimensionRegistry.getActiveWeights();
    }

    private Map<String, Decimal> renormalizeWeights(Set<String> selected, Map<String, Decimal> baseWeights) {
        return DimensionRegistry.renormalise(selected);
    }

    private String toMultiSelectValue(List<String> values, String fallback) {
        Set<String> cleaned = new Set<String>();
        if (values != null) {
            for (String v : values) {
                if (String.isNotBlank(v)) {
                    cleaned.add(v.trim());
                }
            }
        }
        if (cleaned.isEmpty()) {
            cleaned.add(fallback);
        }
        return String.join(new List<String>(cleaned), ';');
    }

    private String determinePipelineExecutionMode(Set<String> assessmentTypes, Set<String> selectedDims) {
        Boolean wantsReadiness = assessmentTypes != null && assessmentTypes.contains('Readiness');
        Boolean canRunDedupVerification = selectedDims != null
            && (selectedDims.contains('Duplication')
                || selectedDims.contains('Conflict'));

        if (wantsReadiness && canRunDedupVerification) {
            return KBRuntimeConfigService.MODE_DEDUPLICATION;
        }
        return null;
    }

    private Id maybeCreatePipelineRun(
        List<String> articleIds,
        KBAssessmentModels.AssessmentRunOptions options,
        String executionMode
    ) {
        if (String.isBlank(executionMode)) {
            return null;
        }

 // Scope_Details_JSON__c is informational (nothing reads it back
        // for recovery), so embed the explicit id list only for 'Selected'
        // scope where it is small. For 'MatchingFilter' the resolved set can be
        // up to 10,000 ids and would overflow the 32,768-char field — omit it
        // and persist only the filter definition.
        String requestedScope = String.isNotBlank(options.requestedScope) ? options.requestedScope : 'Selected';
        Map<String, Object> scopeDetails = new Map<String, Object>{
            'filterLogic' => options.filterLogic,
            'filterClauses' => options.filterClauses,
            'filterFormula' => options.filterFormula
        };
        if (requestedScope == 'Selected') {
            scopeDetails.put('articleIds', articleIds);
        }

        // Fail fast (clear error) if the scope details would overflow the field,
        // rather than a cryptic STRING_TOO_LONG on insert.
        String scopeDetailsJson = serializeForJsonField(
            scopeDetails,
            Schema.SObjectType.KB_Pipeline_Run__c.fields.Scope_Details_JSON__c.getLength(),
            'Scope_Details_JSON__c'
        );

        KB_Pipeline_Run__c pr = new KB_Pipeline_Run__c(
            Status__c = 'Queued',
            Execution_Modes__c = executionMode,
            Scope_Type__c = 'Selected',
            Scope_Details_JSON__c = scopeDetailsJson,
            Started_At__c = Datetime.now(),
            Total_Input_Articles__c = articleIds != null ? articleIds.size() : 0,
            Triggered_By__c = UserInfo.getUserId()
        );
        insert pr;
        return pr.Id;
    }

    /**
     * Compose a SOQL fragment for the legacy AND/OR DSL path. Delegates each
     * clause to KBFilterClauseCompiler so the operator vocabulary, type
     * checks, and SOQL injection guard are owned in one place. Invalid
     * clauses are silently skipped (matches the pre-refactor behavior).
     *
     * Cap of 10 clauses preserved from the original path. Above that the
 * formula path is the right tool.
     */
    private String buildDslWhereClause(List<KBAssessmentModels.FilterClause> clauses, String logic) {
        if (clauses == null || clauses.isEmpty()) {
            return '';
        }

        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> fields =
            KBKnowledgeFieldDescribeService.getFieldMap();
        if (fields == null || fields.isEmpty()) {
            return '';
        }

        String joiner = String.isNotBlank(logic) && logic.toUpperCase() == 'OR' ? ' OR ' : ' AND ';

        List<String> parts = new List<String>();
        Integer clauseCount = 0;
        for (KBAssessmentModels.FilterClause c : clauses) {
            if (c == null) continue;
            if (clauseCount >= 10) break;
            // null-checks are valid without a value; everything else needs one.
            Boolean isNullOp = c.operator != null
                && (c.operator == 'isNull' || c.operator == 'isNotNull');
            Boolean isMultiOp = c.operator != null
                && (c.operator == 'includes' || c.operator == 'excludes');
            if (!isNullOp && !isMultiOp && String.isBlank(c.value)) {
                continue;
            }
            KBFilterClauseCompiler.CompileResult cr = KBFilterClauseCompiler.compile(c, fields);
            if (!cr.valid || String.isBlank(cr.soqlFragment)) {
                continue;
            }
            parts.add(cr.soqlFragment);
            clauseCount++;
        }

        if (parts.isEmpty()) {
            return '';
        }
        return ' AND (' + String.join(parts, joiner) + ')';
    }

    // ---------------------------------------------------------------------
 // Cancellation
    // ---------------------------------------------------------------------

    private static final Set<String> TERMINAL_STATUSES = new Set<String>{
        'Completed', 'Failed', 'Cancelled'
    };

    /**
     * True when the run has been cancelled. Async units (queueables/batch
     * chunks) call this at the top of execute() to short-circuit. Returns
     * false on any SOQL error so a transient lookup failure can't poison the
     * pipeline — a stale execute() is preferable to a stuck run.
     */
    public static Boolean isCancelled(Id runId) {
        if (runId == null) return false;
        try {
            KB_Assessment_Run__c run = [
                SELECT Status__c FROM KB_Assessment_Run__c WHERE Id = :runId LIMIT 1
            ];
            return run.Status__c == 'Cancelled';
        } catch (Exception e) {
            // Fail-open is intentional (a stale execute() is preferable to a
            // stuck run), but log so an FLS regression on Status__c surfaces
            // in debug logs instead of silently skipping every cancel gate.
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.isCancelled: lookup failed for run ' + runId + ': ' + e.getMessage());
            return false;
        }
    }

    /**
     * Append AsyncApexJob ids to KB_Assessment_Run__c.Async_Job_Ids__c so the
     * cancel path can call System.abortJob on each. Best-effort: a failure to
     * record an id never blocks dispatch (the run just becomes harder to
     * cancel — soft-stop status check still works).
     */
    @TestVisible
    private static void recordAsyncJobs(Id runId, List<Id> jobIds) {
        if (runId == null || jobIds == null || jobIds.isEmpty()) return;
        try {
            // FOR UPDATE serialises concurrent appenders (dimension fan-out
            // racing the pipeline-tier queueables, etc.). Without the lock, the
            // second writer's read can pre-date the first writer's commit,
            // dropping that writer's job ids and leaving them un-abortable.
            // Lock auto-releases at transaction commit. Same pattern used by
            // KBAssessmentDimensionQueueable.markCompleted and cancelAssessmentRun.
            KB_Assessment_Run__c run = [
                SELECT Id, Async_Job_Ids__c FROM KB_Assessment_Run__c
                WHERE Id = :runId LIMIT 1
                FOR UPDATE
            ];
            // Split the existing CSV (rather than treating it as one opaque
            // string) so the over-cap drop-oldest below preserves whole ids
            // instead of slicing one in half — abortJob would silently swallow
 // the malformed leader, but it's noisy in logs.
            List<String> parts = new List<String>();
            if (String.isNotBlank(run.Async_Job_Ids__c)) {
                for (String existing : run.Async_Job_Ids__c.split(',')) {
                    if (String.isNotBlank(existing)) parts.add(existing.trim());
                }
            }
            for (Id jid : jobIds) {
                if (jid != null) parts.add(String.valueOf(jid));
            }
            // Drop oldest entries until under the field-length cap. Resolved
            // via Schema so a future field-length change works automatically.
            Integer cap = Schema.SObjectType.KB_Assessment_Run__c
                .fields.Async_Job_Ids__c.getLength();
            while (parts.size() > 1 && String.join(parts, ',').length() > cap) {
                parts.remove(0);
            }
            String joined = String.join(parts, ',');
            update new KB_Assessment_Run__c(Id = runId, Async_Job_Ids__c = joined);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.recordAsyncJobs: failed for run ' + runId + ': ' + e.getMessage());
        }
    }

    /**
     * Convenience overload for single-id callers (pipeline tier queueables).
     */
    public static void recordAsyncJob(Id runId, Id jobId) {
        if (jobId == null) return;
        recordAsyncJobs(runId, new List<Id>{ jobId });
    }

    /**
     * Cancel an in-flight assessment run. Idempotent on terminal states.
     *
     * Sequence:
     *   1. Lock the run row, bail on terminal status.
     *   2. Flip Status__c to 'Cancelled' and stamp audit fields under the lock.
     *   3. Best-effort System.abortJob on each captured async job id (already-
     *      finished jobs throw — expected, swallowed).
     *   4. Stamp linked KB_Pipeline_Run__c if present.
     *   5. Publish a 'Cancelled' Platform Event so any subscribed LWC flips
     *      without waiting for the safety-net poll.
     *
     * Each async unit's isCancelled() gate is the soft-stop backstop — abortJob
     * cancels queued jobs immediately but a job mid-execute() finishes its
     * current chunk; the gate prevents the next one from starting work.
     */
    public static void cancelAssessmentRun(Id runId) {
        if (runId == null) {
            throw new IllegalArgumentException('Run id is required.');
        }

        KB_Assessment_Run__c run = [
            SELECT Id, Status__c, Async_Job_Ids__c, Pipeline_Run__c
            FROM KB_Assessment_Run__c
            WHERE Id = :runId
            FOR UPDATE
        ];

        if (TERMINAL_STATUSES.contains(run.Status__c)) {
            return; // idempotent — already terminal
        }

        Datetime now = Datetime.now();
        String reason = buildCancelMessage(now);

        run.Status__c = 'Cancelled';
        run.Status_Message__c = reason;
        run.Cancellation_Requested_At__c = now;
        run.Cancelled_By__c = UserInfo.getUserId();
        run.Completed_At__c = now;
        // `as user` enforces CRUD/FLS at DML time. A Viewer (read-only on the
        // run object + cancellation fields) hits an InsufficientAccess
        // DmlException, which the @AuraEnabled wrapper turns into a clean
        // AuraHandledException for the LWC.
        update as user run;

        abortCapturedJobs(run.Async_Job_Ids__c);

        // Aborted scoring shards never run finish(), so the join barrier
        // Scoring_Shards_Outstanding__c is never decremented/claimed: the run
        // would be left stuck at its seeded shard count (e.g. 5), and a straggler
        // shard that finishes its in-flight chunk could still drive the count to
        // 0 and finalize a CANCELLED run. Park the claimed sentinel (-1, NOT 0 —
        // at 0 a late claimIfLast() decrements to -1, sees claim=true, and
        // finalizes) so any late claim reads outstanding < 0 and bails. Separate
        // system-mode DML, matching every other barrier write (dispatchBatch /
        // claimIfLast), so it doesn't depend on the running user's FLS on the
        // barrier field. Best-effort — a failure here must not fail the cancel.
        //
        // Load-bearing platform behaviour: System.abortJob on a running batch
        // does NOT invoke finish() — it only lets the current execute() chunk
        // drain to completion. That is exactly why the barrier can be left unmet
        // and cancel must resolve it here. (If finish() ever did run for an
        // aborted shard, claimIfLast() would decrement a reseeded barrier and the
        // finalize arithmetic would be off — so this assumption is worth
        // re-checking on a platform upgrade.)
        //
        // Written unconditionally, even for runs that never sharded (≤50 queueable
        // runs, single-batch runs) whose barrier was null and never consulted.
        // Harmless: the single-batch path skips the barrier (isShard=false) and no
        // LWC/report reads Scoring_Shards_Outstanding__c — a later rerun+shard
        // reseeds it. Not worth a conditional.
        try {
            update new KB_Assessment_Run__c(
                Id = runId,
                Scoring_Shards_Outstanding__c = KBAssessmentBatch.BARRIER_CLAIMED
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.cancelAssessmentRun: failed to park scoring barrier for run '
                + runId + ': ' + e.getMessage());
        }

        if (run.Pipeline_Run__c != null) {
            try {
                update as user new KB_Pipeline_Run__c(
                    Id = run.Pipeline_Run__c,
                    Status__c = 'Cancelled'
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'KBAssessmentService.cancelAssessmentRun: failed to flip pipeline run '
                    + run.Pipeline_Run__c + ': ' + e.getMessage());
            }
        }

        publishCancelledEvent(runId, reason);
    }

    private static String buildCancelMessage(Datetime stampedAt) {
        String userName;
        try { userName = UserInfo.getName(); } catch (Exception e) { userName = 'a user'; }
        String stamp = stampedAt.format('yyyy-MM-dd HH:mm');
        String msg = 'Cancelled by ' + userName + ' at ' + stamp;
        Integer cap = Schema.SObjectType.KB_Assessment_Run__c
            .fields.Status_Message__c.getLength();
        if (msg.length() > cap) msg = msg.substring(0, cap);
        return msg;
    }

    private static void abortCapturedJobs(String jobIdsCsv) {
        if (String.isBlank(jobIdsCsv)) return;
        for (String raw : jobIdsCsv.split(',')) {
            String trimmed = raw == null ? '' : raw.trim();
            if (String.isBlank(trimmed)) continue;
            try {
                System.abortJob(Id.valueOf(trimmed));
            } catch (Exception ignore) {
                // Already finished, doesn't exist, or in a state that can't be
                // aborted. Expected — the soft-stop gate handles the rest.
            }
        }
    }

    private static void publishCancelledEvent(Id runId, String message) {
        try {
            KB_Assessment_Progress__e evt = new KB_Assessment_Progress__e(
                Assessment_Id__c = runId,
                Status__c = 'Cancelled',
                Message__c = message
            );
            EventBus.publish(evt);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'KBAssessmentService.publishCancelledEvent: failed for run ' + runId + ': ' + e.getMessage());
        }
    }

}