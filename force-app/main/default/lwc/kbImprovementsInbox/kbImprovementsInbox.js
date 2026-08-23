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
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import KbBulkFixModal from 'c/kbBulkFixModal';
import KbFixIssuesModal from 'c/kbFixIssuesModal';
import getImprovementsInboxPage from '@salesforce/apex/KBEnrichmentController.getImprovementsInboxPage';
import countArticlesWithOpenIssues from '@salesforce/apex/KBEnrichmentController.countArticlesWithOpenIssues';
import updateRecommendationStatus from '@salesforce/apex/KBEnrichmentController.updateRecommendationStatus';
import requeueErroredRecommendations from '@salesforce/apex/KBEnrichmentController.requeueErroredRecommendations';
import dispatchArticleFixesBulk from '@salesforce/apex/KBImprovementFixFacade.dispatchArticleFixesBulk';
import { impactBadgeClass, compareImpactDesc } from 'c/kbImpact';
import { openInNewTab } from 'c/kbNav';

const DIMENSION_OPTIONS = [
    { label: 'All dimensions', value: '' },
    { label: 'Completeness', value: 'Completeness' },
    { label: 'Structure', value: 'Structure' },
    { label: 'Clarity', value: 'Clarity' },
    { label: 'Freshness', value: 'Freshness' }
];

const SORT_OPTIONS = [
    { label: 'Highest impact first', value: 'impact' },
    { label: 'Lowest impact first', value: 'impactAsc' },
    { label: 'Article name (A–Z)', value: 'name' }
];

// Impact is the only severity surfaced: an LLM-emitted picklist
// (High/Medium/Low). Priority and Effort are no longer part of the model.
// Rank + badge + comparators live in the shared c/kbImpact module.

// Adaptive polling: target ~10 polls over the expected duration
const MIN_POLL_MS   = 30_000;   // 30s minimum
const MAX_POLL_MS   = 60_000;   // 60s cap
const AVG_ARTICLE_S = 15;       // conservative avg LLM seconds per article
const POLL_TIMEOUT  = 30 * 60 * 1000; // 30 min hard timeout

const PE_CHANNEL = '/event/KB_Assessment_Progress__e';

// articles per page in the paginated inbox (matches the Apex default).
const INBOX_PAGE_SIZE = 25;
// review — SOQL caps OFFSET at 2000; mirror the Apex clamp so the pager and
// the fetch-all loop never request a page the backend can't serve.
const INBOX_MAX_OFFSET = 2000;

export default class KbImprovementsInbox extends LightningElement {
    _runId = null;

 // review — reset pagination + selection whenever the run scope changes.
    // Without this, switching the run selector on a later page kept a stale
    // offset (false "No open improvements") and, worse, a stale
    // _selectAllMatching could mass-dispatch AI fixes for the NEW run.
    @api
    get runId() { return this._runId; }
    set runId(v) {
        const next = v || null;
        if (next !== this._runId) {
            this._pageOffset        = 0;
            this._selectedIds       = {};
            this._selectAllMatching = false;
        }
        this._runId = next;
    }

 // Deep-link state from sidebar's "Resolve in Action Center" flow.
    _articleId = null;
    _recId = null;
    _hasScrolledToRec = false;
    _hasNotifiedDeepLinkMissing = false;
    _hasLoadedData = false;

    @api
    get articleId() { return this._articleId; }
    set articleId(v) {
        const next = v || null;
        // Re-arm the one-shot "missing" toast whenever the TARGET changes. The
        // Action Center tab is long-lived: successive "View Actions" clicks push
        // a new c__articleId into this setter without a remount, so a latched
        // flag would suppress the toast for every article after the first
 // Reset only on a genuine change so repeated
        // polls with the same id don't re-toast.
        if (next !== this._articleId) {
            this._hasNotifiedDeepLinkMissing = false;
            // Same latching class as the toast guard: the scroll/highlight is a
            // one-shot too, so re-arm it when the target article changes or a
            // second deep-link on this long-lived tab won't scroll to the new
 // target.
            this._hasScrolledToRec = false;
        }
        this._articleId = next;
        this._expandDeepLinkSection();
        // If real wire data already arrived (deep-link set after load), check
        // now; otherwise wiredGroups runs the check when data returns. Gated on
        // _hasLoadedData — not isLoading — because the wire's initial undefined
        // callback clears isLoading before any rows exist, which would fire a
        // false "missing" toast.
        if (this._hasLoadedData) {
            this._notifyIfDeepLinkArticleMissing();
        }
    }

    @api
    get recId() { return this._recId; }
    set recId(v) {
        const next = v || null;
        // Re-arm the scroll/highlight one-shot when the target rec changes too —
        // a deep-link to a different rec on the SAME article (articleId setter
 // wouldn't fire) still needs to scroll to the new row.
        if (next !== this._recId) {
            this._hasScrolledToRec = false;
        }
        this._recId = next;
    }

    _expandDeepLinkSection() {
        if (this._articleId && !this.activeSections.includes(this._articleId)) {
            this.activeSections = [...this.activeSections, this._articleId];
        }
    }

 // a deep-link (c__articleId) can target an article that isn't in the
    // loaded inbox — either because its issues are all resolved/dismissed, or
    // because it fell outside the per-article cap (INBOX_ARTICLE_LIMIT = 50 in
    // KBEnrichmentController). Without feedback the tab just looks empty/wrong,
    // so surface a one-shot info toast. Guarded so repeated polls don't re-toast
    // and so we only speak once the wire has actually returned rows to check
    // against (an empty groups list from a still-loading state stays silent).
    _notifyIfDeepLinkArticleMissing() {
        if (!this._articleId || this._hasNotifiedDeepLinkMissing) {
            return;
        }
        const present = this.groups.some(g => g.articleId === this._articleId);
        if (present) {
            return;
        }
        this._hasNotifiedDeepLinkMissing = true;
 // A deep-link carrying a recId (the sidebar flow) is proof a
        // specific open rec exists, so "no open issues" would be wrong — the
        // only reason it's absent is the INBOX_ARTICLE_LIMIT (50) cap. Without a
        // recId the article is genuinely either all-resolved or past the cap, so
 // we can't assert which. Word each case honestly.
        const toast = this._recId
            ? {
                  title: 'Article not shown here',
                  message:
                      'This article isn’t in the top 50 articles listed here — it’s further down the list. Narrow by assessment run or resolve higher-priority articles to surface it.',
                  variant: 'info'
              }
            : {
                  title: 'Article not shown here',
                  message:
                      'This article has no open issues in the top 50 shown here — they may have been resolved or fixed, or it falls outside that list.',
                  variant: 'info'
              };
        this.dispatchEvent(new ShowToastEvent(toast));
    }

    @track dimensionFilter = '';
    @track sortBy          = 'impact';
    @track activeSections  = [];
    @track error;

    // Bulk state
    @track _selectedIds    = {};   // plain object map — LWC reacts to property reassignment
    @track isBulkRunning   = false;
    @track showBulkComplete = false;   // post-bulk "drafts ready — View Drafts" banner

 // pagination state. The wire pages by ARTICLE; totalArticles is the
    // REAL count (not the old 50 cap) so the UI can show "X of N" and a pager.
    // _selectAllMatching = the user explicitly chose "select all N" (incl.
    // articles not on the current page), distinct from ticking the visible page.
    @track _pageOffset       = 0;
    @track totalArticles     = 0;
    @track _selectAllMatching = false;
    _pageSize = INBOX_PAGE_SIZE;

    _wiredResult;
    groups    = [];
    isLoading = true;

    _pollTimer        = null;
    _timeoutTimer     = null;
    _pollInterval     = MIN_POLL_MS;
    _bulkCount        = 0;
    _bulkArticleIds   = new Set();
    _isDispatching    = false;       // C1: in-flight guard against double dispatch
    _activeRunId      = null;        // AR2: track current dispatch run for empApi filtering
    _peSubscription   = null;        // AR2: empApi subscription handle

    dimensionOptions = DIMENSION_OPTIONS;
    sortOptions      = SORT_OPTIONS;

    disconnectedCallback() {
        this._stopPolling();
        this._unsubscribeProgress();
    }

    renderedCallback() {
        if (this._articleId && this._recId && !this._hasScrolledToRec) {
            const targetRow = this.template.querySelector(`[data-rec-id="${this._recId}"]`);
            if (targetRow) {
                this._hasScrolledToRec = true;
                const reduceMotion = typeof window !== 'undefined'
                    && window.matchMedia
                    && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
                if (typeof targetRow.scrollIntoView === 'function') {
                    targetRow.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'center' });
                }
                if (typeof targetRow.focus === 'function') {
                    targetRow.focus({ preventScroll: true });
                }
                targetRow.classList.add('kb-highlight-row');
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => targetRow.classList.remove('kb-highlight-row'), 2000);
            }
        }
    }

    @wire(getImprovementsInboxPage, {
        runId: '$_runId',
        pageSize: '$_pageSize',
        offset: '$_pageOffset',
        dimension: '$dimensionFilter'
    })
    wiredGroups(result) {
        this._wiredResult = result;
        this.isLoading = false;
        if (result.data) {
            this._hasLoadedData = true;
            this.totalArticles = result.data.totalArticles || 0;
            this.groups = (result.data.groups || []).map(g => ({
                ...g,
                recommendations: (g.recommendations || []).map(r => ({
                    ...r,
                    // Impact is an LLM-emitted picklist (High/Medium/Low) for the
                    // scored dimensions; Freshness issues are deliberately stored
                    // with null Impact (calendar age isn't a severity judgement),
                    // so render the label as-is (blank when null) rather than
                    // fabricating a 'Low' — matches the record-page panel.
                    impactLabel:      r.impact,
                    impactBadgeClass: impactBadgeClass(r.impact),
                    // C6: surface Error recs with a Failed badge + Retry button.
                    isErrored:        r.status === 'Error'
                }))
            }));
            this.error = undefined;
            this.dispatchEvent(new CustomEvent('improvementscount', {
                detail: { count: this.groups.reduce((sum, g) => sum + (g.recommendations?.length || 0), 0) }
            }));
            this._notifyIfDeepLinkArticleMissing();
 // review (blocker 3) — poll-fallback completion is decided by a
            // LEDGER query over the dispatched article ids, NOT the visible page.
            // The visible page shrinks when the user pages or changes the dimension
            // filter mid-run, which used to fire a false "all processed" and tear
            // down the run monitor. countArticlesWithOpenIssues is page/filter
            // agnostic, so it can't be fooled that way.
            if (this.isBulkRunning && this._bulkArticleIds.size > 0) {
                this._checkBulkCompletionViaLedger();
            }
        } else if (result.error) {
            this.error = result.error?.body?.message || result.error?.message || 'Could not load improvements';
            this.groups = [];
        }
    }

    // ── computed ──────────────────────────────────────────────────────────────

    get filteredGroups() {
        const filtered = this.groups
            .map(g => ({
                ...g,
                recommendations: g.recommendations.filter(r =>
                    (!this.dimensionFilter || r.dimension === this.dimensionFilter)
                )
            }))
            .filter(g => g.recommendations.length > 0)
            .map(g => {
                // Within a group, surface the most severe issues first
                // (unknown/null impact sinks to the bottom).
                const recommendations = [...g.recommendations].sort(
                    (a, b) => compareImpactDesc(a.impact, b.impact)
                );
                return {
                    ...g,
                    recommendations,
                    highImpactCount: recommendations.filter(r => r.impact === 'High').length,
 // /: lead the section title with the article number
                    // (when present), then the title, then the open-issue count:
                    // "000012345 · How to reset · 3 open". Number is display-only —
                    // no link. Articles with no Article_Number__c just omit it.
                    sectionLabel: g.articleNumber
                        ? `${g.articleNumber} · ${g.articleTitle} · ${recommendations.length} open`
                        : `${g.articleTitle} · ${recommendations.length} open`,
                    isSelected: !!this._selectedIds[g.articleId]
                };
            });

        const sorted = [...filtered];
        if (this.sortBy === 'impact') {
            // Lead with the articles carrying the most High-impact issues, then
            // break ties on total open-issue count.
            sorted.sort((a, b) =>
                (b.highImpactCount - a.highImpactCount) ||
                (b.recommendations.length - a.recommendations.length)
            );
        } else if (this.sortBy === 'impactAsc') {
            // Reverse: fewest High-impact issues first (lightest-touch articles),
            // then fewest open issues.
            sorted.sort((a, b) =>
                (a.highImpactCount - b.highImpactCount) ||
                (a.recommendations.length - b.recommendations.length)
            );
        } else if (this.sortBy === 'name') {
            sorted.sort((a, b) => (a.articleTitle || '').localeCompare(b.articleTitle || ''));
        }
        return sorted;
    }

    get filteredArticleCount() { return this.filteredGroups.length; }
    get filteredRecCount()     { return this.filteredGroups.reduce((sum, g) => sum + g.recommendations.length, 0); }

 // REAL totals so scope is patently obvious. "Showing X of N articles"
    // where N is the true distinct-article count (server-side), not the page cap.
    // (A dimension filter is applied client-side to the current page only, so we
    // show the page's filtered slice against the server total honestly.)
    get pageArticleCount() { return this.filteredGroups.length; }
    get hasMultiplePages() { return this.totalArticles > this._pageSize; }
    get pageStart() { return this.totalArticles === 0 ? 0 : this._pageOffset + 1; }
    get pageEnd()   { return Math.min(this._pageOffset + this._pageSize, this.totalArticles); }
    get pageSummary() {
        // e.g. "Showing 1–25 of 402 articles"
        return `Showing ${this.pageStart}–${this.pageEnd} of ${this.totalArticles} article(s)`;
    }
    get isFirstPage() { return this._pageOffset <= 0 || this.isBulkRunning; }
    get isLastPage()  {
        // Stop at the real end OR at the SOQL OFFSET ceiling (a deeper page
        // can't be served). Above the ceiling the filter is the way forward.
        // Also frozen while a bulk run is active (see handleNextPage note).
        return this.isBulkRunning
            || this._pageOffset + this._pageSize >= this.totalArticles
            || this._pageOffset + this._pageSize > INBOX_MAX_OFFSET;
    }

 // "select all N matching" is only offered when the total exceeds the
    // visible page, so the user can distinguish "the 25 I see" from "all 402".
 // review (blocker 1) — AND only when the whole set is reachable within
    // the SOQL OFFSET window. Above INBOX_MAX_OFFSET the fetch-all can't page the
    // full set, so we HIDE the offer (and show the narrow-scope hint below)
    // rather than silently dispatching a truncated subset while the banner
    // claims "all N".
    get canSelectAllMatching() {
        return this.totalArticles > this.pageArticleCount
            && this.totalArticles <= INBOX_MAX_OFFSET;
    }
    // Shown in place of the select-all offer when the set is too large to action
    // as a whole — directs the user to narrow the scope instead of truncating.
    get selectAllTooLarge() {
        return this.totalArticles > this.pageArticleCount
            && this.totalArticles > INBOX_MAX_OFFSET;
    }
    get selectAllTooLargeLabel() {
        return `This filter matches ${this.totalArticles} articles — too many to fix in one action. Narrow by dimension (or run) to fix them in batches.`;
    }
    // The banner text mirrors the article-selector pattern.
    get selectAllMatchingLabel() {
        return `Select all ${this.totalArticles} article(s)`;
    }

    get showControls()   { return !this.isLoading && !this.error && this.groups.length > 0; }
    get showEmpty()      { return this.filteredGroups.length === 0; }
    get showEmptyState() { return !this.isLoading && !this.error && this.groups.length === 0; }

    // Multi-select chrome (Select All / Deselect All + per-row checkboxes) only
 // makes sense when there's more than one article to choose between.
    // With a single group the user fixes/dismisses it directly via its own
    // section actions, so the selection affordances are just noise.
    get isMultiSelect() { return this.filteredGroups.length > 1; }

    get selectedGroups() {
        return this.filteredGroups.filter(g => this._selectedIds[g.articleId]);
    }
    get hasSelection()   { return Object.keys(this._selectedIds).length > 0; }
    get selectionCount() { return Object.keys(this._selectedIds).length; }
    get selectionLabel() { return `${this.selectionCount} article(s) selected`; }

    get hasBulkPendingDraft() {
        return (this.bulkGroups || []).some(g => !!g.pendingDraftId);
    }

    // C1: Disable Fix buttons when a dispatch is mid-flight or a bulk run is active.
    get isFixDisabled() {
        return this.isBulkRunning || this._isDispatching;
    }

    get bulkRunningLabel() {
        return `Fixing ${this._bulkCount} article(s) in background… Check the Suggested Article Drafts tab for drafts.`;
    }

    // ── filter / sort handlers ────────────────────────────────────────────────

 // review — the dimension filter is now SERVER-SIDE (it scopes the wire's
    // count/page/recs), so changing it changes the matching set. Reset the page
    // offset and invalidate any selection — especially "select all N matching",
    // which would otherwise dispatch cross-dimension rewrites for the OLD scope.
    //
 // review (blocker 3) — the filter is FROZEN while a bulk run is active.
    // Because dimension is a live wire param, changing it mid-run re-queries and
    // shrinks this.groups; the completion check now reads a dispatched-id ledger
    // (page/filter agnostic) so that can't cause a false completion, but freezing
    // the control keeps the UI honest (the dispatched set is what's running) and
    // is belt-and-braces for the empApi-gated poll path.
    handleDimensionChange(e) {
        if (this.isFilterFrozen) return;
        this.dimensionFilter = e.detail.value;
        this._resetPageAndSelection();
    }
    handleSortChange(e)      { this.sortBy = e.detail.value; }
    handleClearFilters()     {
        if (this.isFilterFrozen) return;
        this.dimensionFilter = '';
        this._resetPageAndSelection();
    }

    // Filters are frozen during a bulk run so the running scope can't drift.
    get isFilterFrozen() { return this.isBulkRunning; }

    _resetPageAndSelection() {
        this._pageOffset        = 0;
        this._selectedIds       = {};
        this._selectAllMatching = false;
    }

    handleExpandAll()   { this.activeSections = this.filteredGroups.map(g => g.articleId); }
    handleCollapseAll() { this.activeSections = []; }

    // ── selection handlers ────────────────────────────────────────────────────

    handleSelectArticle(e) {
        const articleId = e.target.dataset.articleId;
        const updated = { ...this._selectedIds };
        if (updated[articleId]) {
            delete updated[articleId];
        } else {
            updated[articleId] = true;
        }
        this._selectedIds = updated;
    }

 // "Select page": tick every article on the CURRENT page. Distinct
    // from "Select all N matching" (below), which spans pages.
    handleSelectAll() {
        const updated = {};
        this.filteredGroups.forEach(g => { updated[g.articleId] = true; });
        this._selectedIds = updated;
        this._selectAllMatching = false;
    }

    handleDeselectAll() {
        this._selectedIds = {};
        this._selectAllMatching = false;
    }

 // explicit "select all N" across every page (not just the visible
    // slice). Fix Selected then dispatches for ALL matching articles, which
 // routes to Batch Apex above the 50 threshold. The banner
    // makes this distinct + obvious per the design decision.
    handleSelectAllMatching() {
 // review (blocker 1) — never enter select-all for a set that can't
        // be fully paged (the button is hidden in that case, but guard anyway so
        // a stale click can't start a truncated whole-set dispatch).
        if (!this.canSelectAllMatching) return;
        this._selectAllMatching = true;
        // Also tick the visible page so the checkboxes reflect the selection.
        const updated = {};
        this.filteredGroups.forEach(g => { updated[g.articleId] = true; });
        this._selectedIds = updated;
    }

    // ── pagination ────────────────────────────────────────────────────────────

    handleNextPage() {
 // review — the pager is frozen during a bulk run: the poll-fallback
        // completion check reads the VISIBLE page (this.groups), so paging away
        // mid-run would drop the dispatched articles from view, fire a premature
        // "all processed" toast and tear down the empApi subscription while the
        // fix is still running. isLastPage/isFirstPage already gate on
        // isBulkRunning; re-check here in case a handler is invoked directly.
        if (this.isBulkRunning || this.isLastPage) return;
        this._pageOffset += this._pageSize;
        this._resetSelectionOnPageChange();
    }

    handlePrevPage() {
        if (this.isBulkRunning || this.isFirstPage) return;
        this._pageOffset = Math.max(0, this._pageOffset - this._pageSize);
        this._resetSelectionOnPageChange();
    }

    // Page-scoped selections don't carry across pages (the user can't see what
    // they'd be acting on). A "select all N matching" choice DOES persist — it's
    // an explicit whole-set intent.
    _resetSelectionOnPageChange() {
        if (!this._selectAllMatching) {
            this._selectedIds = {};
        }
    }

    // ── per-row actions (unchanged) ───────────────────────────────────────────

    async handleFixIssues(e) {
        const articleId = e.currentTarget.dataset.articleId;
        const group = this.filteredGroups.find(g => g.articleId === articleId);
        if (!group) return;
        const result = await KbFixIssuesModal.open({ size: 'large', articleGroup: group, mode: 'fix' });
        if (result?.outcome === 'fixed') {
            // A single-article fix runs synchronously — the draft already exists.
            // Refresh our own list (the resolved rec drops out) AND tell the host
            // so the Suggested Article Drafts tab + its count badge pick up the new
            // draft without the user having to hit Refresh. (Dismiss doesn't create
            // a draft, so only 'fixed' raises it.)
            refreshApex(this._wiredResult);
            this.dispatchEvent(new CustomEvent('fixapplied', { bubbles: true, composed: true }));
        } else if (result) {
            refreshApex(this._wiredResult);
        }
    }

 // per-recommendation dismiss. Open the same multi-select modal as
    // Fix so the user can dismiss individual recommendations instead of the
    // old all-or-nothing article-level dismiss.
    async handleDismissIssues(e) {
        const articleId = e.currentTarget.dataset.articleId;
        const group = this.filteredGroups.find(g => g.articleId === articleId);
        if (!group) return;
        const result = await KbFixIssuesModal.open({ size: 'large', articleGroup: group, mode: 'dismiss' });
        if (result) { refreshApex(this._wiredResult); }
    }

 // open the article's Knowledge record page in a NEW tab, synchronously
    // from the click gesture so it isn't popup-blocked. The relative record URL
    // mirrors the proven kbArticleScoreCard pattern. NavigationMixin.Navigate was
 // same-tab, which regressed when the rework replaced the native
 // anchor.: routed through the shared native-anchor helper — LWS blocks
    // window.open on a same-origin URL, but permits a browser-driven click.
    handleViewArticle(e) {
        const articleId = e.currentTarget.dataset.articleId;
        if (!articleId) return;
        openInNewTab(`/lightning/r/${articleId}/view`);
    }

    // C6: retry an errored recommendation
    handleRetry(e) {
        const recId = e.currentTarget.dataset.recId;
        if (!recId) return;
        requeueErroredRecommendations({ recIds: [recId] })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Retry queued',
                    message: 'The failed fix has been requeued.',
                    variant: 'success'
                }));
                return refreshApex(this._wiredResult);
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Could not retry',
                    message: err?.body?.message || 'Retry failed',
                    variant: 'error'
                }));
            });
    }


    // ── bulk actions ──────────────────────────────────────────────────────────

 // "Fix All" was removed. It only ever fixed the visible page and read
    // as a false "fix everything" promise. Fixing is now always an explicit
    // selection: tick articles (or "select all N matching"), then Fix Selected.
    async handleFixSelected() {
        if (this._isDispatching) return; // C1: ignore re-entrant click
        // "Select all N matching" spans pages — the current page's groups are
        // only a slice, so fetch every matching article's group before dispatch.
        // Otherwise a paged selection is exactly what's on screen.
        let targetGroups;
        if (this._selectAllMatching) {
            targetGroups = await this._fetchAllMatchingGroups();
 // review — the fetch-all can fail (e.g. OFFSET ceiling). Surface
            // it rather than silently no-op'ing "select all N" + Fix Selected.
            if (targetGroups === null) {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Could not load all matching articles',
                    message:
                        'This selection is too large to fix in one go. Fix a filtered subset (e.g. by dimension) or a single page instead.',
                    variant: 'error'
                }));
                return;
            }
        } else {
            targetGroups = this.selectedGroups;
        }
        this._openBulkModal(targetGroups);
    }

    // Fetch EVERY matching article group (all pages) for a "select all N" fix.
    // Reuses the paged Apex with a page size at the batch-safe ceiling; the
    // backend caps page size at 100, so walk pages until we have the total.
    // Threads the ACTIVE dimension filter so a filtered "select all N" fetches
    // only that dimension's recs (server-side) — never a cross-dimension rewrite
 // Returns null on failure so the caller can warn
    // instead of dispatching an empty/partial set silently (blocker 1).
    async _fetchAllMatchingGroups() {
        const all = [];
        let offset = 0;
        const size = 100;
        try {
            // Bounded by totalArticles AND the SOQL OFFSET ceiling (2000). The
            // backend clamps too; stop here so we don't spin past the last page.
            while (offset < this.totalArticles && offset <= INBOX_MAX_OFFSET) {
                // eslint-disable-next-line no-await-in-loop
                const page = await getImprovementsInboxPage({
                    runId: this._runId,
                    pageSize: size,
                    offset,
                    dimension: this.dimensionFilter || null
                });
                const groups = page?.groups || [];
                all.push(...groups);
                if (groups.length === 0) break;
                offset += size;
            }
        } catch (err) {
            console.error('fetch-all-matching failed in kbImprovementsInbox:', err);
            return null;
        }
        return all;
    }

    handleDismissSelected() {
        const ids = this.selectedGroups.flatMap(g => g.recommendations.map(r => r.recId));
        if (!ids.length) return;
        updateRecommendationStatus({ recIds: ids, status: 'Rejected' })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Dismissed',
                    message: `${ids.length} recommendation(s) dismissed for ${this.selectionCount} article(s)`,
                    variant: 'success'
                }));
                this._selectedIds = {};
                return refreshApex(this._wiredResult);
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Error',
                    message: err?.body?.message || 'Could not dismiss recommendations',
                    variant: 'error'
                }));
            });
    }

    async _openBulkModal(targetGroups) {
        if (!targetGroups.length) return;
        if (this._isDispatching) return; // C1: ignore re-entrant clicks

        // Set the lock immediately so rapid double-clicks before modal.open()
        // resolves are ignored (C1).
        this._isDispatching = true;

        try {
            const hasPendingDraft = targetGroups.some(g => !!g.pendingDraftId);
            const result = await KbBulkFixModal.open({
                size: 'medium',
                groups: targetGroups,
                hasPendingDraft
            });

            // result is undefined when dismissed via header X / Escape
            if (!result) return;

            const { fixSource } = result;
            const requests = targetGroups.map(g => {
                const useDraft = fixSource === 'smart' && !!g.pendingDraftId;
                return {
                    articleVersionId: useDraft ? g.pendingDraftId : g.articleId,
                    useCurrentOnline: !useDraft,
                    recIds:            g.recommendations.map(r => r.recId),
                    issueDescriptions: g.recommendations.map(r => r.recommendation)
                };
            });

            this._bulkCount      = requests.length;
            this._bulkArticleIds = new Set(targetGroups.map(g => g.articleId));

            const response = await dispatchArticleFixesBulk({ requests });
            // AR2: BulkDispatchResult exposes pipelineRunId (camelCase via
            // @AuraEnabled JSON serialization — the only field on the wire).
            const runId = response?.pipelineRunId ?? null;
            this._activeRunId = runId;

            this.dispatchEvent(new ShowToastEvent({
                title: 'Fix queued',
                message: `Fix queued for ${this._bulkCount} article(s). Drafts will appear in the Suggested Article Drafts tab.`,
                variant: 'info'
            }));
            this._selectedIds  = {};
            this.isBulkRunning = true;
 // review — clear any prior completion banner so a new run doesn't
            // show a stale "drafts are ready" banner next to the running banner.
            this.showBulkComplete = false;

            if (runId) {
                this._subscribeProgress();
            }
            // Polling stays on as a fallback (orgs where empApi is gated).
            this._startPolling(this._bulkCount);
            await refreshApex(this._wiredResult);
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Bulk fix failed',
                message: err?.body?.message || 'Could not queue bulk fix',
                variant: 'error'
            }));
        } finally {
            this._isDispatching = false; // C1: release the in-flight lock
        }
    }

    // ── polling ───────────────────────────────────────────────────────────────

    _startPolling(articleCount) {
        this._stopPolling();
        // Adaptive base interval: ~total_expected_seconds / 10 polls, clamped [30s, 60s]
        const estimatedMs = articleCount * AVG_ARTICLE_S * 1000;
        this._pollInterval = Math.min(Math.max(estimatedMs / 10, MIN_POLL_MS), MAX_POLL_MS);
        this._schedulePoll();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._timeoutTimer = setTimeout(() => {
            if (this.isBulkRunning) {
                this._stopPolling();
                this.isBulkRunning = false;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Still processing',
                    message: 'Some fixes may still be running. Check the Suggested Article Drafts tab in a few minutes.',
                    variant: 'warning',
                    mode: 'sticky'
                }));
            }
        }, POLL_TIMEOUT);
    }

    _schedulePoll() {
        // C4: clear any pending timer before scheduling a new one to prevent
        // stacked timers when wire emits rapidly during a bulk run.
        clearTimeout(this._pollTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollTimer = setTimeout(() => {
            if (this.isBulkRunning) {
                refreshApex(this._wiredResult);
            }
        }, this._pollInterval);
    }

    _stopPolling() {
        if (this._pollTimer)    { clearTimeout(this._pollTimer);    this._pollTimer    = null; }
        if (this._timeoutTimer) { clearTimeout(this._timeoutTimer); this._timeoutTimer = null; }
    }

 // review (blocker 3) — decide completion from the dispatched-id ledger,
    // page/filter agnostic. Only completes when NONE of the dispatched articles
    // still carry an open/errored issue. On an inconclusive check, back off and
    // reschedule the poll (same cadence as before).
    async _checkBulkCompletionViaLedger() {
        const dispatched = [...this._bulkArticleIds];
        try {
            const remaining = await countArticlesWithOpenIssues({ articleIds: dispatched });
            if (!this.isBulkRunning) return; // a PE event may have completed it meanwhile
            if (remaining === 0) {
                this._completeBulk();
            } else {
                this._pollInterval = Math.min(this._pollInterval * 1.2, MAX_POLL_MS);
                this._schedulePoll();
            }
        } catch (err) {
            console.error('bulk completion ledger check failed in kbImprovementsInbox:', err);
            // Keep polling — a transient failure shouldn't strand the run monitor.
            this._pollInterval = Math.min(this._pollInterval * 1.2, MAX_POLL_MS);
            this._schedulePoll();
        }
    }

    _completeBulk() {
        this._stopPolling();
        this._unsubscribeProgress();
        this.isBulkRunning   = false;
        this._bulkArticleIds = new Set();
        this._activeRunId    = null;
 // raise a persistent "drafts are ready" banner (with a View
        // Drafts action) so the user has a one-click path to the drafts they
        // just produced, instead of a dead-end toast telling them to go find
        // them. The banner survives after the toast auto-dismisses.
        this.showBulkComplete = true;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Bulk fix complete',
            message: `All ${this._bulkCount} article(s) have been processed. Review them in the Suggested Article Drafts tab.`,
            variant: 'success'
        }));
    }

 // ask the host inbox to switch to the Suggested Article Drafts tab, which is
    // already scoped to this run (shared run-id), so the fixed drafts are right
    // there. Dismisses the completion banner.
    handleViewDrafts() {
        this.showBulkComplete = false;
        this.dispatchEvent(new CustomEvent('viewdrafts', {
            detail: { runId: this.runId },
            bubbles: true,
            composed: true
        }));
    }

    handleDismissBulkComplete() {
        this.showBulkComplete = false;
    }

    // ── platform events (AR2) ────────────────────────────────────────────────

    async _subscribeProgress() {
        if (this._peSubscription) return;
        try {
            onError((err) => {
                // empApi may be gated in some orgs — fall back silently to polling.
                 
                console.error('empApi error in kbImprovementsInbox:', JSON.stringify(err));
            });
            this._peSubscription = await subscribe(PE_CHANNEL, -1, (evt) => {
                this._handleProgressEvent(evt);
            });
        } catch (e) {
            // Subscription failed — polling continues to work.
             
            console.error('subscribe failed in kbImprovementsInbox:', e);
            this._peSubscription = null;
        }
    }

    _handleProgressEvent(evt) {
        const payload = evt?.data?.payload || {};
        // KB_Assessment_Progress__e only carries Assessment_Id__c — filter to
        // events for this dispatch's run only.
        const eventRunId = payload.Assessment_Id__c;
        if (!this._activeRunId || !eventRunId || eventRunId !== this._activeRunId) return;

        // Finding 2: drive completion off the PE Status field. The wire-driven
        // path in wiredGroups stays live as a polling-only fallback for orgs
        // where empApi is gated, but it can't reliably fire when errored recs
        // remain visible — only the terminal PE event can.
        const status = payload.Status__c;
        if (status === 'Completed' || status === 'Partial') {
            this._completeBulk();
        }
        // Always refresh: lets resolved recs drop out of the inbox and feeds
        // the wire-driven _completeBulk fallback when no PE Status is set.
        refreshApex(this._wiredResult);
    }

    _unsubscribeProgress() {
        if (this._peSubscription) {
            try {
                unsubscribe(this._peSubscription);
            } catch {
                // ignore — disconnect is best-effort
            }
            this._peSubscription = null;
        }
    }
}
