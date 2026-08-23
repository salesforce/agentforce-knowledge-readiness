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
import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import hasBypassPermission from '@salesforce/customPermission/Bypass_AI_Knowledge_Check';
import hasPrePublishCheckBeta from '@salesforce/customPermission/KB_PrePublishCheck_Beta';
import verifyDraft from '@salesforce/apex/KnowledgeAIGovernanceService.verifyDraft';
import publishArticleWithAudit from '@salesforce/apex/KnowledgeAIGovernanceService.publishArticleWithAudit';
import createDraftVersion from '@salesforce/apex/KnowledgeAIGovernanceService.createDraftVersion';
import getArticleStatus from '@salesforce/apex/KnowledgeAIGovernanceService.getArticleStatus';
import getLatestAssessmentForArticle from '@salesforce/apex/KBAssessmentController.getLatestAssessmentForArticle';
import getRunsAndAnalysesForArticle from '@salesforce/apex/KBAssessmentController.getRunsAndAnalysesForArticle';
import getImprovementsForArticle from '@salesforce/apex/KBEnrichmentController.getImprovementsForArticle';
import previewArticleScore from '@salesforce/apex/KBAssessmentController.previewArticleScore';
import getSnapshot from '@salesforce/apex/KBDiagnosticsController.getSnapshot';
import TAB_CHECK_PUBLISH from '@salesforce/label/c.KB_Sidebar_Tab_CheckPublish';
import TAB_CHECK_CONFLICTS from '@salesforce/label/c.KB_Sidebar_Tab_CheckConflicts';
import TITLE_FIELD from '@salesforce/schema/Knowledge__kav.Title';
import KNOWLEDGE_ARTICLE_ID_FIELD from '@salesforce/schema/Knowledge__kav.KnowledgeArticleId';
import READINESS_NO_TITLE from '@salesforce/label/c.KB_Sidebar_Readiness_NoAssessment_Title';
import READINESS_NO_BODY from '@salesforce/label/c.KB_Sidebar_Readiness_NoAssessment_Body';
import READINESS_NO_CTA from '@salesforce/label/c.KB_Sidebar_Readiness_NoAssessment_CTA';
import READINESS_SCORE_LABEL from '@salesforce/label/c.KB_Sidebar_Readiness_Score_Label';
import { impactBadgeClass, compareImpactDesc, compareImpactAsc } from 'c/kbImpact';
import KbFixIssuesModal from 'c/kbFixIssuesModal';
import LightningConfirm from 'lightning/confirm';

const FIELDS = [TITLE_FIELD, KNOWLEDGE_ARTICLE_ID_FIELD];

// Severity model reduced to Impact only (High/Medium/Low) — Priority and
// Effort were dropped from the analysis row. Impact is the single badge.
// Rank + badge + comparators live in the shared c/kbImpact module.

// AI Fix only knows how to rewrite content — Duplication, Conflict, and
// Freshness recommendations are out of its scope. The list classifies them
// so the LWC can group rows into AI-fixable (with a checkbox in the Fix
// modal) and Manual-only (with a per-row Resolve / Edit-as-Draft action).
const MANUAL_ONLY_DIMENSIONS = new Set(['Duplication', 'Conflict', 'Freshness']);

// Duplication and Conflict are surfaced on their own "Duplicates & Conflicts"
// tab, not the Issues tab — so the Issues-tab Dimension filter only offers the
// dimensions that actually appear there.
const DIMENSION_OPTIONS = [
    { label: 'All dimensions', value: 'all' },
    { label: 'Completeness', value: 'Completeness' },
    { label: 'Structure', value: 'Structure' },
    { label: 'Clarity', value: 'Clarity' },
    { label: 'Freshness', value: 'Freshness' }
];
const SORT_OPTIONS = [
    { label: 'Highest impact first', value: 'impact' },
    { label: 'Lowest impact first', value: 'impactAsc' }
];

// Preview-results tab: stable display order + labels for the
// self-contained dimensions a preview can return. The Apex side (registry-
// driven, skipPipelineDimensions=true) decides WHICH dimensions are actually
// scored — we render whatever scoresByDim contains, in this order, so a future
// 7th self-contained dimension just needs a label entry here. Duplication/
// Conflict never appear (pipeline-only; the preview never scores them).
const PREVIEW_DIMENSION_LABELS = {
    Completeness: 'Completeness',
    Structure: 'Structure',
    Clarity: 'Language Clarity',
    Freshness: 'Freshness'
};
const PREVIEW_DIMENSION_ORDER = ['Completeness', 'Structure', 'Clarity', 'Freshness'];

// Score → variant, matching c/kbArticleScoreCard.getVariant (80/50 bands) so
// the same article shows the same colour here and in the batch results card.
function previewScoreVariant(score) {
    if (score >= 80) return 'slds-text-color_success';
    if (score >= 50) return 'slds-text-color_warning';
    return 'slds-text-color_error';
}

// Readiness status → SLDS theme. Shared by the latest-run header and the
// preview panel (was duplicated — review note,).
function readinessBadgeClass(status) {
    if (status === 'Ready') return 'slds-theme_success';
    if (status === 'Needs Work') return 'slds-theme_warning';
    if (status === 'Not Ready') return 'slds-theme_error';
    return '';
}

export default class KnowledgeConsistencyChecker extends NavigationMixin(LightningElement) {
 // recordId is the KAV VERSION being viewed. In default LEX
    // same-object record-to-record navigation (v1 → v2), LEX REUSES this
    // component instance and only updates recordId; the runs wire re-fires with
    // the SAME canonical run set (getRunsAndAnalysesForArticle resolves to the
    // shared KnowledgeArticleId), so the `stillPresent` guard in wiredRuns would
    // keep the old selection pinned and render an actively-false version label.
    // Reset the selection whenever the viewed version changes so wiredRuns
    // recomputes the version-match default for the new version. @track backs the
    // reactive `$recordId` wires.
    @track _recordId;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        const changed = value !== this._recordId;
        this._recordId = value;
        if (changed) {
            // Drop the pinned run so wiredRuns re-defaults to the run that
            // assessed the newly-viewed version (or the latest as fallback).
            this.selectedRunId = null;
        }
    }

    // Pre-publish check tab state — verifyDraft lifecycle.
    isProcessing = false;
    isClean = false;
    hasConflicts = false;
    hasError = false;
    errorMessage = '';
    conflicts = [];
    bypassReason = '';
    articleStatus;

    // Issues tab — latest assessment + open recs feeding the Fix modal.
    latestAssessment = null;
    readinessError = null;
    improvementGroup = null;

    // Strengths / history — runs across all versions of this article. The
    // run selector drives which run's strengths render; the score header and
    // Issues/Duplicates stay on the latest run (pre-alpha — no time-travel).
    runs = [];
    runsError = null;
    selectedRunId = null;
    _wiredRuns; // provisioned wire value, retained for refreshApex

 // Preview-results tab state. On-demand, no run created. Scoring runs
    // live LLM scorers (~4 callouts) so it's gated behind an explicit button,
    // never auto-run on tab open — a record-page view must not silently spend
    // Einstein credits.
    previewLoading = false;
    previewResult = null;   // ArticleAssessmentResult (in-memory; nothing persisted)
    previewError = null;
    _previewRan = false;

    // Filter state (Issues tab)
    dimensionFilter = 'all';
    sortBy = 'impact';

 // status toggles for the Issues tab, default off → actionable-only
 // (Open / Error / Queued). Mirrors the Action Center's toggles for
    // cross-surface consistency. "Show resolved" reveals Resolved rows; "Show
    // discarded" reveals Dismissed / Rejected rows. Queued (a fix mid-flight) is
    // ALWAYS shown with an "in progress" pill — it's not behind a toggle.
    showResolvedRecs = false;
    showDiscardedRecs = false;

    // Vector search status — drives the SOQL-fallback advisory banner.
    _vectorSearchActive = false;
    _usingSoqlFallback = false;

    // Tab + filter labels
    tabIssuesLabel = 'Issues';
    tabStrengthsLabel = 'Strengths';
    tabDuplicatesLabel = 'Duplicates & Conflicts';
    tabPreviewLabel = 'Preview results';
    tabPrePublishLabel = 'Pre-publish check';
    previewIssuesTabLabel = 'Issues';
    previewStrengthsTabLabel = 'Strengths';
    readinessNoTitle = READINESS_NO_TITLE;
    readinessNoBody = READINESS_NO_BODY;
    readinessNoCta = READINESS_NO_CTA;
    readinessScoreLabel = READINESS_SCORE_LABEL;

    dimensionOptions = DIMENSION_OPTIONS;
    sortOptions = SORT_OPTIONS;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    article;

    @wire(getArticleStatus, { articleVersionId: '$recordId' })
    wiredStatus({ data, error }) {
        if (data) {
            this.articleStatus = data;
        } else if (error) {
            this.articleStatus = null;
        }
    }

    @wire(getLatestAssessmentForArticle, { articleVersionId: '$recordId' })
    wiredReadiness({ data, error }) {
        if (data !== undefined) {
            this.latestAssessment = data;
            this.readinessError = null;
        } else if (error) {
            this.readinessError = error?.body?.message || error?.message || 'Could not load assessment';
            this.latestAssessment = null;
        }
    }

    @wire(getImprovementsForArticle, { articleVersionId: '$recordId' })
    wiredImprovements({ data, error }) {
        if (data !== undefined) {
            this.improvementGroup = data;
        } else if (error) {
            this.improvementGroup = null;
        }
    }

    // Runs across ALL versions of this article (canonical KnowledgeArticleId).
    // Drives the Strengths tab + run selector. Filtering by canonical id means
    // a fresh "Fix with AI" draft inherits the parent article's history.
    @wire(getRunsAndAnalysesForArticle, { articleId: '$recordId' })
    wiredRuns(value) {
 // review — retain the provisioned wire value so a successful
        // AI-Fix can refreshApex() it; the Issues tab now sources from this
        // wire (via _selectedRun.issues), so nulling improvementGroup alone
        // no longer drops the just-fixed row.
        this._wiredRuns = value;
        const { data, error } = value;
        if (data) {
            this.runs = data;
            this.runsError = null;
            // Preserve the user's explicit choice across re-wires if it survives.
            const stillPresent =
                this.selectedRunId && data.some((r) => r.assessmentId === this.selectedRunId);
            if (!stillPresent) {
 // default to the run that assessed THIS EXACT version
                // (recordId is the KAV version being viewed). If NO run assessed
                // this version — e.g. a fresh AI-Fix draft that was never scored —
                // default to null (NOT the latest run): we must not present some
                // other version's score/issues/strengths as if they were this
                // version's. The header then shows the honest "not assessed;
                // most recent assessment was version N (legacy)" state, and the
                // Issues/Strengths tabs show a "not assessed" empty state. The
                // user can still pick a past run from the selector to browse it.
                const versionMatch = data.find(
                    (r) => r.assessedVersionId === this.recordId
                );
                this.selectedRunId = versionMatch ? versionMatch.assessmentId : null;
            }
        } else if (error) {
            this.runs = [];
            this.runsError = error?.body?.message || error?.message || 'Could not load runs';
            this.selectedRunId = null;
        }
    }

    connectedCallback() {
        getSnapshot()
            .then((data) => {
                const vp = data?.vectorProvider;
                this._vectorSearchActive = !!(vp && vp.isActive && vp.searchIndexName);
                this._usingSoqlFallback = !this._vectorSearchActive
                    || vp?.implementationClass === 'Tier1SOQLFallbackService';
            })
            .catch(() => {});
    }

    // ── Issues tab ─────────────────────────────────────────────────────
    //
    // The header, Issues tab and Duplicates tab all follow the run picked in
 // the "Assessment run" selector — every surface re-scopes together,
    // so the control no longer looks like a no-op. The selected run's data
    // (score, readiness, issues, strengths) comes from getRunsAndAnalysesForArticle.
    // The latest-only improvementGroup wire is retained solely to feed the
    // Fix-with-AI modal (open recs + pending draft) and is only actioned when
    // the latest run is selected.

    get hasLatestAssessment() {
        return !!this._selectedRun || !!this.latestAssessment;
    }

 // has THIS EXACT version ever been assessed? A run whose
    // assessedVersionId matches the viewed version, or a version-exact
    // latestAssessment. False for a fresh AI-Fix draft that was never scored.
    get isViewedVersionAssessed() {
        if (this.latestAssessment) return true;
        return this.runs.some((r) => r.assessedVersionId === this.recordId);
    }

 // the viewed version is NOT assessed, but the ARTICLE has been
    // assessed on another version (there are runs, none for this version). This
    // is the fresh-AI-Fix-draft case: show an honest "not assessed here; the
    // most recent assessment was version N (legacy)" state instead of passing
    // off another version's score/issues/strengths as this version's.
    //
 // review nit — gated on `!selectedRunId` so this is the DEFAULT
    // (no run actively picked) state only. If the user manually selects a past
    // run on an otherwise-unassessed version, we show that run's issues/strengths
    // instead — otherwise the recommendations list and this "not assessed" box
    // would render at the same time.
    get isUnassessedVersionWithHistory() {
        return !this.isViewedVersionAssessed && this.runs.length > 0 && !this.selectedRunId;
    }

    // Legacy reference: the most recent run across the article (runs are
    // CreatedDate DESC) + what it scored, phrased so the user knows it belongs
    // to a DIFFERENT version than the one they're viewing.
    get legacyAssessmentLabel() {
        const latest = this._latestRun;
        if (!latest) return '';
        const score = latest.overallScore != null ? Math.round(latest.overallScore) : '—';
        const ver = latest.versionNumber != null ? ` (version ${latest.versionNumber})` : '';
        return `This version hasn’t been assessed yet. The most recent assessment${ver} scored ${score} — a legacy score from a different version, not this one.`;
    }

    // Score header reflects the SELECTED run. Falls back to the latest-version
    // assessment only when there are no run rows at all (defensive).
    get latestOverallScore() {
        const score = this._selectedRun
            ? this._selectedRun.overallScore
            : this.latestAssessment?.overallScore;
        return Math.round(score || 0);
    }

    get latestReadinessStatus() {
        return (this._selectedRun
            ? this._selectedRun.readinessStatus
            : this.latestAssessment?.readinessStatus) || '';
    }

    get latestReadinessBadgeClass() {
        return readinessBadgeClass(this.latestReadinessStatus);
    }

    // Is the selected run the most recent one? The wire returns runs ordered
    // CreatedDate DESC, so runs[0] is latest. Fix-with-AI only acts on the
    // latest run (it rewrites the article's CURRENT content) — older runs are
    // a read-only snapshot.
    get isLatestRun() {
        if (!this.selectedRunId || this.runs.length === 0) return true;
        return this.runs[0].assessmentId === this.selectedRunId;
    }

    // Show a "viewing a past run" note whenever a non-latest run is selected.
    get isViewingPastRun() {
        return !this.isLatestRun && this.runs.length > 1;
    }

    _decorateRow(r, i) {
        const isManualOnly = MANUAL_ONLY_DIMENSIONS.has(r.dimension);
        const isDedup = r.dimension === 'Duplication' || r.dimension === 'Conflict';
        // Run-row issues carry status (Open / Error / Queued / Resolved /
        // Dismissed / Rejected) and expose the recommendation via fixSuggestion
        // (Recommendation__c).
        const status = r.status || 'Open';
 // status buckets. Actionable (always shown): Open / Error /
        // Queued. Resolved bucket: Resolved. Discarded bucket: Dismissed /
        // Rejected. Queued rides in the actionable set (a fix mid-flight) but
        // gets its own "in progress" pill.
        const isActionable = status === 'Open' || status === 'Error' || status === 'Queued';
        const isResolved = status === 'Resolved';
        const isDiscarded = status === 'Dismissed' || status === 'Rejected';
        const isInProgress = status === 'Queued';
        return {
            key: `issue-${r.recId || i}`,
            recId: r.recId,
            dimension: r.dimension,
            impact: r.impact,
            recommendation: r.recommendation,
            // Impact badge is rendered when impact is set; manual-only rows
            // whose severity hasn't settled yet have a null impact and show
            // no badge (the template guards on issue.impact).
            impactBadgeClass: impactBadgeClass(r.impact),
            impactLabel: r.impact,
            status,
            isActionable,
            isResolved,
            isDiscarded,
            isInProgress,
            // Surface a status pill for any non-actionable-Open row (resolved,
            // discarded, or the in-progress Queued) so it reads as historical /
            // in-flight, not a fresh to-do. Open/Error show no pill.
            showStatus: status !== 'Open' && status !== 'Error',
            isManualOnly,
            isDedup,           // routes Resolve action to dup/conflict modal
            isFreshness: r.dimension === 'Freshness'
        };
    }

 // the status filter driven by the two toggles. Actionable rows
    // (Open/Error/Queued) always pass; Resolved passes only when Show resolved
    // is on; Dismissed/Rejected pass only when Show discarded is on.
    _passesStatusToggles(row) {
        if (row.isActionable) return true;
        if (row.isResolved) return this.showResolvedRecs;
        if (row.isDiscarded) return this.showDiscardedRecs;
        return true; // unknown status → don't hide it
    }

    _applyFilters(rows) {
 // status toggles first (actionable-only by default), then the
        // dimension filter, then impact sort.
        let out = rows.filter((r) => this._passesStatusToggles(r));
        if (this.dimensionFilter !== 'all') {
            out = out.filter((r) => r.dimension === this.dimensionFilter);
        }
        // Sort by impact rank. 'impact' = highest first (High > Medium > Low);
        // 'impactAsc' = lowest first. Rows with no impact always sort last
        // (both comparators pin rank-0 rows to the bottom).
        const compare = this.sortBy === 'impactAsc' ? compareImpactAsc : compareImpactDesc;
        out = [...out].sort((a, b) => compare(a.impact, b.impact));
        return out;
    }

 // Issues/Duplicates rows for the SELECTED run.
    //
    // Sourced from the selected run's analysis rows (getRunsAndAnalysesForArticle),
 // which carry EVERY status — so the status toggles can reveal
    // resolved/discarded rows regardless of which run is selected. The status
    // toggles + dimension filter + sort are applied downstream in _applyFilters;
    // the default (both toggles off) shows the actionable Open/Error/Queued set,
    // preserving the established "open issues only" default view.
    //
    // (Fix-with-AI still feeds from improvementGroup — latest-run actionable
    // recs — and is gated on isLatestRun; see handleOpenFixModal / canFixWithAI.)
    get _allDecoratedIssues() {
        const recs = (this._selectedRun?.issues || []).map((r) => ({
            recId: r.id,
            dimension: r.dimension,
            impact: r.impact,
            recommendation: r.fixSuggestion || r.analysisText,
            status: r.status
        }));
        return recs.map((r, i) => this._decorateRow(r, i));
    }

    get aiFixableIssues() {
        return this._applyFilters(this._allDecoratedIssues.filter((r) => !r.isManualOnly));
    }

    // The Issues tab's "needs human review" group is Freshness-only. Dedup
    // rows (Duplication / Conflict) live on the Duplicates tab instead.
    get freshnessIssues() {
        return this._applyFilters(this._allDecoratedIssues.filter((r) => r.isFreshness));
    }

    // Dedup rows for the Duplicates tab — Duplication / Conflict findings with
    // the Resolve-in-Action-Center deep link.
    get dedupIssues() {
        return this._applyFilters(this._allDecoratedIssues.filter((r) => r.isDedup));
    }

    get hasAiFixableIssues() {
        return this.aiFixableIssues.length > 0;
    }

    get hasDedupIssues() {
        return this.dedupIssues.length > 0;
    }

    // Unfiltered Issues-tab rows of ANY status (AI-fixable + Freshness; dedup
    // rows live on the Duplicates & Conflicts tab). Used to decide whether the
    // article has ANY history at all — independent of dimension/sort/status
    // filters.
    get _unfilteredIssuesTabRows() {
        return this._allDecoratedIssues.filter((r) => !r.isDedup);
    }

    // Does this article have any Issues-tab history (any status)? Drives whether
    // the filter/toggle controls render — they stay visible whenever the article
    // has been assessed and produced recs, so the user can always toggle
    // resolved/discarded and is never stuck.
    get hasIssuesOnArticle() {
        return this._unfilteredIssuesTabRows.length > 0;
    }

 // rows for the Issues tab AFTER all filters (status toggles +
    // dimension + sort) = AI-fixable + Freshness that survived. Drives whether
    // the list renders vs. the neutral "nothing matches" hint. There is NO
    // "success / all clear" state — the tab just shows recommendations, and the
    // toggles/filter decide which are visible.
    get hasVisibleIssues() {
        return this.aiFixableIssues.length + this.freshnessIssues.length > 0;
    }

    // Article has issues, but the active filter hid them all — show a
    // "no matches" hint with the filters still present (so Clear works).
 // the article has recs but the current toggles/filter hide them all.
    // Neutral hint (not a success state): tells the user to adjust the toggles
    // or clear the filter. Covers the all-resolved-but-toggles-off case too.
    get hasNoMatchingIssues() {
        return this.hasIssuesOnArticle && !this.hasVisibleIssues;
    }

 // the viewed version WAS assessed (a run is selected) but produced no
    // Issues-tab recs at all (any status). Neutral empty-state — NOT a "success"
    // (per the decision to drop the success framing). Distinct from the
    // never-assessed state (isUnassessedVersionWithHistory).
    get hasNoRecsAtAll() {
        return this.isViewedVersionAssessed
            && !!this.selectedRunId
            && !this.hasIssuesOnArticle;
    }

    get filteredOpenIssueCount() {
        return this.aiFixableIssues.length + this.freshnessIssues.length;
    }

    handleDimensionChange(e) { this.dimensionFilter = e.detail.value; }
    handleSortChange(e) { this.sortBy = e.detail.value; }
    handleClearFilters() {
        this.dimensionFilter = 'all';
        this.sortBy = 'impact';
 // Clear also resets the status toggles back to actionable-only.
        this.showResolvedRecs = false;
        this.showDiscardedRecs = false;
    }

 // status toggles.
    handleToggleResolvedRecs(e) { this.showResolvedRecs = e.target.checked; }
    handleToggleDiscardedRecs(e) { this.showDiscardedRecs = e.target.checked; }

 // Fix-with-AI is valid ONLY against the latest run's unresolved
    // findings (it rewrites the article's CURRENT content). When a past run is
    // selected the Fix affordance is disabled and a scope note explains why.
    get canFixWithAI() {
        return this.isLatestRun && this.hasAiFixableIssues;
    }

    // Scope note shown by the Issues tab when viewing a past run — makes the
    // "AI Fix only acts on the latest assessment" constraint explicit rather
    // than silently disabling the button.
    get showPastRunFixNote() {
        return this.isViewingPastRun;
    }

    // ── Fix-with-AI modal ──────────────────────────────────────────────

    async handleOpenFixModal() {
 // hard guard: never fix against a past run's findings, even if a
        // caller reaches this handler while a non-latest run is selected.
        if (!this.isLatestRun) return;
        // Pass only AI-fixable rows into the modal — manual-only rows
        // (Duplication / Conflict / Freshness) are surfaced separately with
        // per-row Resolve / Edit actions. This filter is the single
        // safeguard: kbFixIssuesModal feeds whatever it receives into
        // KBImprovementFixFacade.dispatchArticleFix, which would call the
        // LLM with manual-only rec ids and produce a meaningless rewrite.
        // Don't trust callers to pre-filter — re-filter here even though
        // the UI doesn't render checkboxes for manual-only rows.
        const aiOnly = (this.improvementGroup?.recommendations || [])
            .filter((r) => !MANUAL_ONLY_DIMENSIONS.has(r.dimension));
        // The button enables off the run wire (hasAiFixableIssues) but the modal
        // feeds from the getImprovementsForArticle wire (improvementGroup). Those
        // can disagree — e.g. after dismissing/rejecting every open issue, the
        // run row may still look fixable while the improvements wire has emptied.
        // Rather than silently no-op (button clicks, nothing happens — a reported
        // confusion), tell the user why there's nothing to fix.
        if (aiOnly.length === 0) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Nothing to fix',
                message:
                    'No open AI-fixable issues remain for this article on the latest assessment. Re-run the assessment to refresh recommendations.',
                variant: 'info'
            }));
            return;
        }
        const modalGroup = { ...this.improvementGroup, recommendations: aiOnly };
        const result = await KbFixIssuesModal.open({ size: 'large', articleGroup: modalGroup, mode: 'fix' });
        if (result) {
 // review — the Issues list now sources from the runs wire
            // (_selectedRun.issues), so nulling improvementGroup alone leaves the
            // just-fixed row on screen. refreshApex the runs wire so the resolved
            // recs actually drop; also clear the modal-feed group.
            this.improvementGroup = null;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Fix ready',
                message: 'Refreshing recommendations…',
                variant: 'info'
            }));
            if (this._wiredRuns) {
                refreshApex(this._wiredRuns);
            }
        }
    }

    // ── Manual-only row actions ────────────────────────────────────────

    handleResolveCandidate(event) {
        // Action Center's kbCandidateInbox reads c__articleId / c__recId / c__tab
        // / c__runId. recId arrives via event.detail (kbRecommendationsList child,
        // Issues tab) or via the button's data-rec-id when rendered directly on
        // the Duplicates & Conflicts tab.
        const recId = event?.detail?.recId || event?.currentTarget?.dataset?.recId;

 // route to the RIGHT tab. Duplication/Conflict findings live in
        // the Duplicates & Conflicts queue, not the Improvements Inbox; sending
        // them to Improvements (the old default) is why a reported conflict
        // "wasn't there". The Duplicates-tab button carries data-is-dedup="true";
        // the Improvements child's resolvecandidate event does not. Scope to the
        // currently-selected run so the queue lands on this run's pair(s).
        const isDedup = event?.currentTarget?.dataset?.isDedup === 'true';
        const state = {
            c__articleId: this.recordId,
            c__recId: recId || ''
        };
        if (isDedup) {
            state.c__tab = 'duplicates';
            // NB: selectedRunId is the ASSESSMENT id (r.assessmentId), not the
            // KB_Assessment_Run__c id the candidate queue filters on. The queue
            // filters Duplicate_Candidate__c.Assessment_Run__c, so pass the
            // selected row's runId (a.Assessment_Run__c on the DTO).
            const runId = this._selectedRun?.runId;
            if (runId) {
                state.c__runId = runId;
            }
            // Join on the ASSESSED version, not this.recordId (the current KAV
            // version). The candidate queue matches on the candidate's version
            // fields, which hold the version that was assessed; for a
            // re-published article the current version differs from the assessed
            // one, so this.recordId would filter to an empty queue. The DTO
            // carries assessedVersionId (KB_Article_Assessment__c.Knowledge__c).
            const assessedVersionId = this._selectedRun?.assessedVersionId;
            if (assessedVersionId) {
                state.c__articleId = assessedVersionId;
            }
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Candidate_Inbox' },
            state
        });
    }

    handleEditAsDraft() {
        // Freshness has no AI fix path — surface the raw Knowledge edit.
        // Draft articles open in edit mode directly; published ones open
        // in view mode (the user creates a draft via the standard UI).
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.recordId,
                objectApiName: 'Knowledge__kav',
                actionName: this.isDraft ? 'edit' : 'view'
            }
        });
    }

    handleGoToAssessment() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Assessment_Console' },
            state: { c__articleId: this.recordId }
        });
    }

    // ── Strengths tab + run selector ───────────────────────────────────

    // Whether a run picker is worth showing — only when there's more than one
    // assessment to choose between. A single run renders its strengths with no
    // selector chrome.
    get hasMultipleRuns() {
        return this.runs.length > 1;
    }

    // Run picker options — newest first (the wire returns CreatedDate DESC).
 // the label leads with the ASSESSMENT identity (name · date · who
    // ran it), not a raw score: this is a run selector, so users should pick by
    // which assessment it was, and multi-user orgs need to tell whose run it is.
    // The score is demoted to a trailing detail. Falls back gracefully when a
    // field is missing (legacy runs with no name/owner).
    get runOptions() {
        return this.runs.map((r) => {
            const name = r.runName || 'Assessment';
            const dateLabel = r.runDate
                ? new Date(r.runDate).toLocaleDateString()
                : '';
            const version = r.versionNumber != null ? `v${r.versionNumber}` : '';
            const score = r.overallScore != null ? Math.round(r.overallScore) : '—';
            const parts = [name];
            if (dateLabel) parts.push(dateLabel);
            if (r.ranBy) parts.push(r.ranBy);
            if (version) parts.push(version);
            parts.push(`score ${score}`);
            return {
                label: parts.join(' · '),
                value: r.assessmentId
            };
        });
    }

    get _selectedRun() {
        if (!this.selectedRunId) return null;
        return this.runs.find((r) => r.assessmentId === this.selectedRunId) || null;
    }

 // the most RECENT assessment run (runs are CreatedDate DESC, so the
    // first row). NB this is the newest *run*, whose assessed version isn't
    // necessarily the article's newest published version (e.g. a live-but-
    // unassessed v3 exists) — the component has no data source for an unassessed
    // version, so the label speaks in terms of "most recent assessment", which
    // the score/version pairing it prints is always accurate for.
    get _latestRun() {
        return this.runs.length > 0 ? this.runs[0] : null;
    }

 // reference line shown under the header score when the selected run
    // is NOT the most recent run: makes clear the header reflects the version
    // this assessment ran on (e.g. v2), and what the most recent assessment
    // scored, so an older score never reads as the article's current state.
    // Returns '' when the selected run already IS the most recent (nothing to
    // disambiguate).
    get versionContextLabel() {
        const sel = this._selectedRun;
        const latest = this._latestRun;
        if (!sel || !latest || sel.assessmentId === latest.assessmentId) {
            return '';
        }
        const latestScore =
            latest.overallScore != null ? Math.round(latest.overallScore) : '—';
        const latestVer =
            latest.versionNumber != null ? ` (version ${latest.versionNumber})` : '';
        const selVer =
            sel.versionNumber != null ? `version ${sel.versionNumber}` : 'an earlier version';
        return `Showing ${selVer} — the version this assessment ran on. The most recent assessment${latestVer} scored ${latestScore}.`;
    }

    get hasVersionContext() {
        return this.versionContextLabel !== '';
    }

    // Strengths for the selected run. Decorated lightly — strengths carry a
    // dimension + analysisText (no impact/recommendation/fix). Keyed for the
    // template iterator.
    get selectedRunStrengths() {
        const strengths = this._selectedRun?.strengths || [];
        return strengths.map((s, i) => ({
            key: `strength-${s.id || i}`,
            dimension: s.dimension,
            analysisText: s.analysisText
        }));
    }

    get hasStrengths() {
        return this.selectedRunStrengths.length > 0;
    }

    get strengthCount() {
        return this.selectedRunStrengths.length;
    }

    handleRunChange(event) {
        this.selectedRunId = event.detail.value;
    }

 // ── Preview results tab ─────────────────────────────────────
    //
    // On-demand "how would this article score if I published and assessed it?"
    // Scores Completeness/Structure/Clarity/Freshness against the article's
    // CURRENT content — no run created, nothing persisted. Works on any KAV
    // version, including an AI-Fix-generated Draft (open the draft → preview).
    // Duplication/Conflict are intentionally absent (pipeline-only).

    handleRunPreview() {
        if (!this.recordId || this.previewLoading) {
            return;
        }
        this.previewLoading = true;
        this.previewError = null;
        previewArticleScore({ articleId: this.recordId })
            .then((result) => {
                this.previewResult = result;
                this._previewRan = true;
            })
            .catch((error) => {
                this.previewResult = null;
                this._previewRan = true;
                this.previewError =
                    error?.body?.message || error?.message || 'Could not score this article.';
            })
            .finally(() => {
                this.previewLoading = false;
            });
    }

    // A finished preview with at least one dimension actually scored. The
    // "scored something" guard avoids the degenerate panel (overall 0, blank
    // badge, no rows) when every dimension came back unassessable / empty —
 // that surfaces as the empty-result hint instead (review note,).
    get hasPreviewResult() {
        return (
            this._previewRan &&
            !this.previewError &&
            this.previewResult != null &&
            this.previewDimensionScores.some((d) => d.scored)
        );
    }

    // Finished, no error, but nothing scorable (e.g. empty/no-body article).
    get previewHasNoScorableContent() {
        return (
            this._previewRan &&
            !this.previewError &&
            this.previewResult != null &&
            !this.previewDimensionScores.some((d) => d.scored)
        );
    }

    get previewHasError() {
        return this._previewRan && !!this.previewError;
    }

    // Idle = never run + not loading: show the explanatory empty state + button.
    get previewIdle() {
        return !this._previewRan && !this.previewLoading;
    }

    get previewOverallScore() {
        return Math.round(this.previewResult?.overallScore || 0);
    }

    get previewReadinessStatus() {
        return this.previewResult?.readinessStatus || '';
    }

    get previewReadinessBadgeClass() {
        return readinessBadgeClass(this.previewReadinessStatus);
    }

    // Per-dimension rows in a stable order. Renders whatever scoresByDim
    // returns; an unassessable dimension (score null, isUnassessable true —
    // e.g. no-body article) shows "N/A" rather than a misleading red 0, and is
    // not counted as "scored" (mirrors c/kbArticleScoreCard).
    get previewDimensionScores() {
        const byDim = this.previewResult?.scoresByDim || {};
        return PREVIEW_DIMENSION_ORDER.filter((d) => byDim[d] != null).map((d) => {
            const dim = byDim[d];
            const scored = dim.score !== null && dim.score !== undefined && !dim.isUnassessable;
            const numeric = scored ? Math.round(dim.score) : 0;
            return {
                key: d,
                label: PREVIEW_DIMENSION_LABELS[d] || d,
                scored,
                score: scored ? numeric : 'N/A',
                scoreClass: scored ? previewScoreVariant(numeric) : 'slds-text-color_weak'
            };
        });
    }

    // Preview Issues: flatten issueAnalyses from all dimensions into a single
    // list formatted for kbRecommendationsList. Preview issues are read-only
    // (no Fix button) since there's no run / no persisted KB_Dimension_Analysis__c
    // rows to feed the Fix flow.
    get previewIssues() {
        const byDim = this.previewResult?.scoresByDim || {};
        const issues = [];
        let index = 0;
        PREVIEW_DIMENSION_ORDER.forEach((dimKey) => {
            // Freshness is manual-only (deterministic, no AI fix path) — it must
            // not land in the AI-fixable list the Fix flow consumes, mirroring
            // the record-page Issues tab (aiFixableIssues filters !isManualOnly).
            if (MANUAL_ONLY_DIMENSIONS.has(dimKey)) return;
            const dim = byDim[dimKey];
            if (!dim || !dim.issueAnalyses) return;
            dim.issueAnalyses.forEach((issue) => {
                issues.push({
                    key: `preview-issue-${dimKey}-${index++}`,
                    recId: null,  // no persisted rec
                    dimension: PREVIEW_DIMENSION_LABELS[dimKey] || dimKey,
                    impact: issue.impact,
                    recommendation: issue.text,
                    impactBadgeClass: impactBadgeClass(issue.impact),
                    impactLabel: issue.impact,
                    status: null,
                    isOpen: true,
                    showStatus: false,
                    isManualOnly: false,
                    isDedup: false,
                    isFreshness: false
                });
            });
        });
        return issues;
    }

    get hasPreviewIssues() {
        return this.previewIssues.length > 0;
    }

    get previewIssueCount() {
        return this.previewIssues.length;
    }

    // Preview Notes: a dimension can come back with ONLY a reasoning string and
    // no structured issues/strengths — most importantly the Einstein-failure
    // fallback, which stamps Reasoning__c with "Einstein evaluation unavailable
    // … score 60 is a fallback baseline, not a quality assertion" and emits no
    // issues/strengths. Without surfacing it the dimension reads as a genuine
    // 60 with empty tabs. Show the reasoning as an informational note (clearly
 // not a detected issue) so the caveat is visible again.
    get previewNotes() {
        const byDim = this.previewResult?.scoresByDim || {};
        const notes = [];
        PREVIEW_DIMENSION_ORDER.forEach((dimKey) => {
            const dim = byDim[dimKey];
            if (!dim) return;
            const reasoning = typeof dim.reasoning === 'string' ? dim.reasoning.trim() : '';
            if (!reasoning) return;
            const hasIssues = Array.isArray(dim.issueAnalyses) && dim.issueAnalyses.length > 0;
            const hasStrengths = Array.isArray(dim.strengths) && dim.strengths.length > 0;
            if (hasIssues || hasStrengths) return;
            notes.push({
                key: `preview-note-${dimKey}`,
                dimension: PREVIEW_DIMENSION_LABELS[dimKey] || dimKey,
                text: reasoning
            });
        });
        return notes;
    }

    get hasPreviewNotes() {
        return this.previewNotes.length > 0;
    }

    // Success empty-state only when there are neither structured issues nor
    // informational notes — otherwise the notes carry the message.
    get previewIssuesTabEmpty() {
        return !this.hasPreviewIssues && !this.hasPreviewNotes;
    }

    // Preview Strengths: flatten strengths (string list) from all dimensions
    // into a single list matching the Strengths tab structure.
    get previewStrengths() {
        const byDim = this.previewResult?.scoresByDim || {};
        const strengths = [];
        let index = 0;
        PREVIEW_DIMENSION_ORDER.forEach((dimKey) => {
            const dim = byDim[dimKey];
            if (!dim || !dim.strengths) return;
            dim.strengths.forEach((strengthText) => {
                strengths.push({
                    key: `preview-strength-${dimKey}-${index++}`,
                    dimension: PREVIEW_DIMENSION_LABELS[dimKey] || dimKey,
                    analysisText: strengthText
                });
            });
        });
        return strengths;
    }

    get hasPreviewStrengths() {
        return this.previewStrengths.length > 0;
    }

    get previewStrengthCount() {
        return this.previewStrengths.length;
    }

    // ── Pre-publish check tab — existing flow preserved ───────────────

    get canBypass() {
        return hasBypassPermission;
    }

    // Beta gate for the Pre-publish check tab. The Issues / Strengths /
    // Duplicates tabs always render; this controls only whether a fourth
    // Pre-publish tab is added. No special single-tab wrapper handling is
    // needed — the tabset is never reduced to one tab.
    get showPrePublishTab() {
        return hasPrePublishCheckBeta === true;
    }

    get isPublished() {
        return this.articleStatus === 'Online';
    }

    get isDraft() {
        return this.articleStatus === 'Draft';
    }

    get conflictCount() {
        return this.conflicts.length;
    }

    get reviewedCount() {
        return this.conflicts.filter((c) => c.reviewed).length;
    }

    get allReviewed() {
        return this.conflicts.length > 0 && this.conflicts.every((c) => c.reviewed);
    }

    get reviewProgress() {
        if (this.conflicts.length === 0) return 0;
        return Math.round((this.reviewedCount / this.conflicts.length) * 100);
    }

    get bypassReasonEmpty() {
        return !this.bypassReason || this.bypassReason.trim() === '';
    }

    get showIdleState() {
        return !this.isProcessing && !this.isClean && !this.hasConflicts && !this.hasError;
    }

    get knowledgeArticleId() {
        return this.article?.data
            ? getFieldValue(this.article.data, KNOWLEDGE_ARTICLE_ID_FIELD)
            : null;
    }

    get checkButtonLabel() {
        return this.isDraft ? TAB_CHECK_PUBLISH : TAB_CHECK_CONFLICTS;
    }

    get checkButtonDescription() {
        return this.isDraft
            ? 'Run an AI check against the published knowledge base before publishing this draft. Catches duplicates and contradictions.'
            : 'Run an AI check to find duplicates or contradictions with other published articles.';
    }

    get isCheckButtonDisabled() {
        return this.isProcessing;
    }

    get usingSoqlFallback() {
        return this._usingSoqlFallback;
    }

    async handleVerifyDraft() {
        this.resetState();
        this.isProcessing = true;

        try {
            const result = await verifyDraft({ articleVersionId: this.recordId });

            if (result.hasConflict && result.conflicts && result.conflicts.length > 0) {
                this.hasConflicts = true;
                this.conflicts = result.conflicts.map((c, index) => ({
                    ...c,
                    id: c.conflictingArticleId || `conflict-${index}`,
                    reviewed: false,
                    badgeClass: this.getBadgeClass(c.conflictType)
                }));
            } else {
                this.isClean = true;
            }
        } catch (error) {
            this.hasError = true;
            this.errorMessage =
                error.body?.message || 'AI consistency check failed. You may retry or publish with caution.';
        } finally {
            this.isProcessing = false;
        }
    }

    handleConflictReviewToggle(event) {
        const index = parseInt(event.target.dataset.index, 10);
        this.conflicts = this.conflicts.map((c, i) => {
            if (i === index) {
                return { ...c, reviewed: event.target.checked };
            }
            return c;
        });
    }

    async handlePublish() {
        await this.doPublish(null);
    }

    async handleBypassPublish() {
        const bypassJson = JSON.stringify({
            reason: this.bypassReason,
            conflictsFound: this.conflicts.length,
            conflictsReviewed: this.conflicts.map((c) => ({
                articleId: c.conflictingArticleId,
                articleTitle: c.conflictingArticleTitle,
                type: c.conflictType,
                reasoning: c.reasoning,
                managerReviewed: c.reviewed
            }))
        });
        await this.doPublish(bypassJson);
    }

    async handlePublishWithoutCheck() {
        const bypassJson = JSON.stringify({
            reason: 'Published without AI check due to system error',
            checkSkipped: true
        });
        await this.doPublish(bypassJson);
    }

    async doPublish(bypassReasonJson) {
        this.isProcessing = true;

        try {
            await publishArticleWithAudit({
                knowledgeArticleId: this.knowledgeArticleId,
                articleVersionId: this.recordId,
                bypassReasonJson: bypassReasonJson
            });

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: 'Article published successfully.',
                    variant: 'success'
                })
            );

            this.resetState();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Publish Failed',
                    message: error.body?.message || 'Failed to publish article.',
                    variant: 'error'
                })
            );
        } finally {
            this.isProcessing = false;
        }
    }

    // Create Draft Version confirm — platform lightning/confirm (focus-trapped,
    // Escape-dismissable) replaces the hand-rolled section[role="dialog"]. A
    // dismissed / declined confirm resolves falsy and is treated as cancel.
    async handleCreateDraft() {
        const confirmed = await LightningConfirm.open({
            label: 'Create Draft Version?',
            message:
                'This creates a new draft version of the published article so you can address the detected conflicts. The current published version stays live until the draft is published.',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }

        this.isProcessing = true;

        try {
            const draftId = await createDraftVersion({
                knowledgeArticleId: this.knowledgeArticleId
            });

            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Draft Created',
                    message: 'A new draft version has been created. Redirecting...',
                    variant: 'success'
                })
            );

            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: draftId,
                    objectApiName: 'Knowledge__kav',
                    actionName: 'view'
                }
            });
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: error.body?.message || 'Failed to create draft version.',
                    variant: 'error'
                })
            );
        } finally {
            this.isProcessing = false;
        }
    }

    handleBypassReasonChange(event) {
        this.bypassReason = event.detail.value;
    }

    handleCancel() {
        this.resetState();
    }

    resetState() {
        this.isProcessing = false;
        this.isClean = false;
        this.hasConflicts = false;
        this.hasError = false;
        this.errorMessage = '';
        this.conflicts = [];
        this.bypassReason = '';
    }

    getBadgeClass(conflictType) {
        switch (conflictType) {
            case 'Duplicate':
                return 'slds-badge_inverse';
            case 'Contradiction':
                return 'slds-badge_error';
            default:
                return 'slds-badge_warning';
        }
    }
}
