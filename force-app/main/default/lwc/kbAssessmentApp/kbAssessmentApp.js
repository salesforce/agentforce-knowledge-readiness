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
import { LightningElement, wire, track } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
// use the non-cacheable Live variant so the post-Completion view from
// the All Assessments list shows real scores instead of the cached zero-payload
// from a mid-run poll.
import getAssessmentResults from '@salesforce/apex/KBAssessmentController.getAssessmentResultsLive';
import isSetupCompleted from '@salesforce/apex/KBSetupOrchestratorController.isSetupCompleted';
// clone prefill: recover a run's name/description + article scope
// (re-resolved to current published versions) to seed the new-assessment modal.
import getRunSelectionForClone from '@salesforce/apex/KBAssessmentController.getRunSelectionForClone';

// body scroll-lock, ref-counted at MODULE scope so it survives multiple
// component instances sharing the one document.body. A per-instance save/restore
// corrupts when two modals overlap: the first to close would restore the
// pre-lock value and unlock the page while the second modal is still open, and
// the second to close would then re-apply the (already-locked) value it saved,
// leaking a permanent lock. The counter makes the FIRST lock save the prior
// overflow and the LAST unlock restore it; locks/unlocks in between just move
// the count. Each instance calls lock at most once and unlock at most once
// (guarded by _scrollLocked), so the count can't drift from a single instance.
let _scrollLockCount = 0;
let _scrollLockPriorOverflow = '';

function acquireBodyScrollLock() {
    if (typeof document === 'undefined' || !document.body) {
        return;
    }
    if (_scrollLockCount === 0) {
        _scrollLockPriorOverflow = document.body.style.overflow || '';
        document.body.style.overflow = 'hidden';
    }
    _scrollLockCount += 1;
}

function releaseBodyScrollLock() {
    if (typeof document === 'undefined' || !document.body) {
        return;
    }
    if (_scrollLockCount === 0) {
        return;
    }
    _scrollLockCount -= 1;
    if (_scrollLockCount === 0) {
        document.body.style.overflow = _scrollLockPriorOverflow;
    }
}

/**
 * KB Readiness Assessment container.
 *
 * The All Assessments list is the home. "New Assessment" opens a single large
 * modal with a 3-step path inside it (details → select → preview); on Start the
 * run is submitted and the modal closes, returning to the list. The modal
 * approach was adopted in the 2026-06-04 "Review changes" review (it reads well
 * even on small screens and matches the standard Salesforce create pattern).
 */
export default class KbAssessmentApp extends NavigationMixin(LightningElement) {
    @track _setupCompleted = null;
    @track preselectedArticleId = null;
 // plural preselection for the clone flow (seeds the whole basket).
    @track preselectedArticleIds = null;

    @wire(CurrentPageReference)
    pageRefChanged(pageRef) {
        this.checkSetupStatus();
        if (pageRef?.state?.c__articleId) {
            // Deep-link from an article record: open the modal straight at the
            // select step (the user already knows which article they want).
            // openModal() resets the path first, so set the preselection AFTER.
            this.openModal('select');
            this.preselectedArticleId = pageRef.state.c__articleId;
        }
    }

    async checkSetupStatus() {
        try { this._setupCompleted = !!(await isSetupCompleted()); }
        catch { this._setupCompleted = true; }
    }

    get isSetupComplete() { return this._setupCompleted === true; }
    get isSetupLoading() { return this._setupCompleted === null; }

    handleGoToSetup() {
        this[NavigationMixin.Navigate]({ type: 'standard__navItemPage', attributes: { apiName: 'KB_Assessment_Setup' } });
    }

    // ── Modal + path state ────────────────────────────────────────────────
    @track isModalOpen = false;
 // tracks whether the open/close side-effects (scroll-lock, initial
    // focus, focus-return) have been applied for the CURRENT open, so
    // renderedCallback runs them exactly once per open and once per close
    // regardless of which close path fired (X, Cancel, Escape, run-started,
    // clone error). isModalOpen is the single source of truth it keys off.
    _modalSideEffectsApplied = false;
 // whether THIS instance currently holds a body scroll-lock, so it
    // acquires/releases the ref-counted module lock at most once each. Prevents
    // a re-render from double-counting and keeps the module counter honest.
    _scrollLocked = false;
 // last step the modal rendered at, so renderedCallback can re-pull
    // focus into the dialog when the step (and thus the footer) changes. Clicking
    // a footer button unmounts it, dropping focus to <body> outside the trap;
    // re-focusing the close button on each step change keeps focus inside.
    _lastRenderedStep = null;
    // Path steps inside the modal: 'details' | 'select' | 'preview'.
    @track currentStep = 'details';
    // True once the select step has been reached — keeps the article-selector
    // mounted (hidden, not destroyed) across step nav so the selection survives.
    @track _reachedSelect = false;
    @track runName = '';
    @track description = '';
    @track detailsValid = false;
    @track selectedArticleIds = [];
    @track selectedArticleRows = []; // (c) — rows for the Preview confirm list
    @track selectionFilterContext = null;
    @track selectAllMatchingFilter = false;
    @track filterSnapshot = null;
    @track matchingFilterCount = 0;
    @track excludedIds = [];
 // double-submit guard. Set true the instant "Start Assessment" is
    // pressed and cleared on every exit path (run started, submit error, modal
    // close). Disables the Start button so rapid presses can't kick off
    // duplicate runs.
    @track isSubmitting = false;
    // Large-run typed-RUN gate, mirrored from the embedded kbRunCostPreview's
    // confirmationchange event. The preview hides its own Proceed button in
    // embedded mode, so the Start button gates on these instead.
    @track _runNeedsConfirmation = false;
    @track _runConfirmed = false;

    // History (All Assessments) state
    @track historySubView = 'list'; // 'list' | 'detail' | 'running'
    @track historicalResult = null;
    @track isLoadingHistorical = false;
    @track runningRunId = null;
    @track runningRunName = null;
    @track runningRunDescription = null;
    @track runningRunStartedAt = null;

    // ── Step getters ──────────────────────────────────────────────────────
    get isDetailsStep() { return this.currentStep === 'details'; }
    get isSelectStep() { return this.currentStep === 'select'; }
    get isPreviewStep() { return this.currentStep === 'preview'; }

    // The article-selector is kept MOUNTED once the user first reaches the
    // select step, and merely hidden (not destroyed) when they navigate to
    // preview and back. Re-creating it under lwc:if dropped the in-component
    // selection + row cache, so the basket came back empty on Back. Hiding it
    // preserves selectedIds, the row cache, and filter state across step nav.
    get hasReachedSelect() {
        return this._reachedSelect;
    }
    get selectStepClass() {
        return this.isSelectStep ? '' : 'slds-hide';
    }

    get isSelectionEmpty() {
        return this.selectedArticleIds.length === 0 && !this.selectAllMatchingFilter;
    }

 // the Start Assessment button is disabled when there's nothing to
    // submit OR a submit is already in flight (defence-in-depth against
    // double-submit; the runner has its own in-flight guard as a second layer).
    // Also gated on the preview's large-run typed-RUN confirmation: the embedded
    // kbRunCostPreview hides its own Proceed button, so its gate reaches us via
    // the confirmationchange event and blocks Start until RUN is typed.
    get startDisabled() {
        return (
            this.isSelectionEmpty ||
            this.isSubmitting ||
            (this._runNeedsConfirmation && !this._runConfirmed)
        );
    }

    get startButtonLabel() {
        return this.isSubmitting ? 'Starting…' : 'Start Assessment';
    }

    get selectedArticleCount() {
        if (this.selectAllMatchingFilter) {
            return Math.max(this.matchingFilterCount - this.excludedIds.length, 0);
        }
        return this.selectedArticleIds.length;
    }

 // Single static title: the in-modal progress path + its
    // "Stage: <step>" label already tell the user which step they're on, so
    // repeating the step in the title ("New assessment — preview" alongside a
    // "Preview" path step and a "Stage: Preview" label) was the same word three
    // times. Keep just the modal identity here.
    get modalStepTitle() {
        return 'New Assessment';
    }

 // Modal width is step-dependent: the details step only holds a
    // name + description so it reads better compact; Select Articles needs the
    // full-size table it had before; Preview is a lean summary, so medium.
    get modalSizeClass() {
        const base = 'slds-modal slds-fade-in-open ';
        if (this.isSelectStep) return base + 'slds-modal_large';
        if (this.isPreviewStep) return base + 'slds-modal_medium';
        return base + 'slds-modal_small';
    }

    // ── History getters ───────────────────────────────────────────────────
    get isHistoryView() {
        return this.historySubView === 'list' && !this.isLoadingHistorical;
    }
    get isHistoricalResultView() {
        return this.historySubView === 'detail' && !this.isLoadingHistorical;
    }
    get isHistoricalRunningView() {
        return this.historySubView === 'running';
    }

    // ── Modal lifecycle ───────────────────────────────────────────────────
    openModal(step = 'details') {
        this.resetNewAssessmentPath();
        this.currentStep = step;
        if (step === 'select') {
            this._reachedSelect = true;
        }
        this.isModalOpen = true;
    }

    handleCloseModal() {
        this.isModalOpen = false;
        this.resetNewAssessmentPath();
    }

    resetNewAssessmentPath() {
        this.runName = '';
        this.description = '';
        this.detailsValid = false;
        this.selectedArticleIds = [];
        this.selectionFilterContext = null;
        this.selectAllMatchingFilter = false;
        this.filterSnapshot = null;
        this.matchingFilterCount = 0;
        this.excludedIds = [];
        this.preselectedArticleId = null;
        this.preselectedArticleIds = null;
        this.currentStep = 'details';
        this._reachedSelect = false;
 // always reopen the modal with a fresh (enabled) Start button.
        // Clear BOTH guards: the shell flag here, and the runner's in-flight
        // flag via its public reset. The runner persists across modal
        // close/reopen, so without this its `_submitting` could strand `true`
        // from a still-resolving prior submit and silently swallow the next
        // Start click (close → reopen → resubmit before the first resolves).
        this.isSubmitting = false;
        // Reset the large-run gate; the preview re-emits confirmationchange when
        // it reloads on the preview step, so this is just a clean starting state.
        this._runNeedsConfirmation = false;
        this._runConfirmed = false;
        const runner = this.template.querySelector('c-kb-assessment-runner');
        if (runner) {
            runner.resetSubmitState();
        }
    }

    // Mirror the embedded preview's large-run typed-RUN gate so the Start button
    // stays disabled until the user types RUN on a flagged run (the embedded
    // preview hides its own Proceed button).
    handleConfirmationChange(event) {
        this._runNeedsConfirmation = !!event.detail.needsConfirmation;
        this._runConfirmed = !!event.detail.confirmed;
    }

 // ── Modal a11y ─────────────────────────────────────────────────
    // The wizard is a hand-rolled per-step slds-modal (lightning/modal can't
    // resize per step). These handlers re-create the focus management that
    // lightning/modal provides natively: focus trap, Escape-to-close, initial
    // focus, focus-return, and body scroll-lock.

    // Whether the modal is actually in the DOM. The modal markup lives inside
    // `lwc:elseif={isSetupComplete}`, so isModalOpen alone isn't enough — if the
    // setup gate regresses to incomplete while a modal is open, the whole
    // subtree (modal included) is torn down and replaced by the setup guard, yet
    // the component itself is NOT disconnected. Keying teardown off this getter
    // (not isModalOpen) means that subtree removal still unlocks scroll + returns
 // focus, instead of stranding the page permanently scroll-locked.
    get _modalShown() {
        return this.isModalOpen && this.isSetupComplete;
    }

    // Open/close side-effects are driven off _modalShown here (not from the
    // various openModal/close callers) so every close path — X, Cancel, Escape,
    // run-started, clone-error, AND a setup-gate regression — gets the same
    // teardown exactly once.
    renderedCallback() {
        if (this._modalShown && !this._modalSideEffectsApplied) {
            this._modalSideEffectsApplied = true;
            this._lastRenderedStep = this.currentStep;
            this._lockBodyScroll();
            // Move focus INTO the dialog on open (AC: "opening moves focus into
            // the dialog"). Defer to let the dialog paint first.
            Promise.resolve().then(() => this._focusDialog());
        } else if (this._modalShown && this.currentStep !== this._lastRenderedStep) {
            // Step changed via a footer button (Continue / Back). That button
            // just unmounted, so the browser has dropped focus to <body> —
            // outside the trap. Pull it back to the close button so the next
            // Tab/Shift+Tab is bounded by the sentinels again.
            this._lastRenderedStep = this.currentStep;
            Promise.resolve().then(() => this._focusDialog());
        } else if (!this._modalShown && this._modalSideEffectsApplied) {
            this._modalSideEffectsApplied = false;
            this._lastRenderedStep = null;
            this._unlockBodyScroll();
            this._restoreTriggerFocus();
        }
    }

    disconnectedCallback() {
        // Never strand the page scroll-locked if the component is torn down
        // while the modal is open.
        if (this._modalSideEffectsApplied) {
            this._unlockBodyScroll();
            this._modalSideEffectsApplied = false;
        }
    }

    // Escape closes the wizard (AC). Escape bubbles up from the child LWCs, which
    // is what we want — Escape anywhere inside the wizard dismisses it. But if a
    // nested control already handled the key for its own dismiss (e.g. a combobox
    // closing its dropdown calls preventDefault), don't ALSO close the whole
    // wizard on the same press — defer to the inner handler.
    handleModalKeyDown(event) {
        if ((event.key === 'Escape' || event.key === 'Esc') && !event.defaultPrevented) {
            event.stopPropagation();
            this.handleCloseModal();
        }
    }

    // Focus-trap sentinels. Tabbing forward past the last control lands on the
    // END sentinel → wrap to the first focusable (the close button, top of the
    // dialog). Shift+Tabbing before the first control lands on the START
    // sentinel → wrap to the last focusable (bottom of the dialog). This bounces
    // focus across the three child shadow roots without ever enumerating them —
    // the two anchors we grab both live in THIS template.
    handleSentinelStart() {
        this._focusLastInDialog();
    }

    handleSentinelEnd() {
        this._focusFirstInDialog();
    }

    _focusDialog() {
        // Prefer the close button (a real, always-present control) over the
        // section[tabindex=-1] so the first Tab moves predictably to the next
        // control rather than off a programmatically-focused container.
        const closeBtn = this.template.querySelector('[data-id="modal-close-btn"]');
        if (closeBtn) {
            closeBtn.focus();
            return;
        }
        const dialog = this.template.querySelector('[data-id="wizard-dialog"]');
        if (dialog) {
            dialog.focus();
        }
    }

    _focusFirstInDialog() {
        const closeBtn = this.template.querySelector('[data-id="modal-close-btn"]');
        if (closeBtn) {
            closeBtn.focus();
        }
    }

    // Wrap to the bottom of the dialog: focus the LAST ENABLED footer button.
    // The rightmost footer button is the last thing in tab order, but it can be
    // disabled (Continue-to-Preview before any article is picked; Start before
    // the typed-RUN gate), and .focus() on a disabled control is a no-op that
    // would strand focus on the sentinel and let the next Shift+Tab leak to the
    // page behind. So walk the footer buttons back-to-front and focus the first
    // enabled one; every step always has an enabled Back/Cancel as a floor.
    // Delegating .focus() to the lightning-button lets IT focus its inner
    // <button> across its own shadow boundary (delegatesFocus).
    _focusLastInDialog() {
        const footerButtons = Array.from(
            this.template.querySelectorAll('footer.slds-modal__footer lightning-button')
        );
        for (let i = footerButtons.length - 1; i >= 0; i--) {
            if (!footerButtons[i].disabled) {
                footerButtons[i].focus();
                return;
            }
        }
        // No enabled footer button (shouldn't happen on any step) — fall back to
        // the close button rather than letting focus escape the dialog.
        this._focusFirstInDialog();
    }

    // Acquire/release the ref-counted module-level lock at most once per
    // instance (the _scrollLocked guard), so a re-render can't double-count and
    // two overlapping modals can't corrupt each other's save/restore.
    _lockBodyScroll() {
        if (this._scrollLocked) {
            return;
        }
        this._scrollLocked = true;
        acquireBodyScrollLock();
    }

    _unlockBodyScroll() {
        if (!this._scrollLocked) {
            return;
        }
        this._scrollLocked = false;
        releaseBodyScrollLock();
    }

    // Return focus to the trigger that opened the wizard. The "New Assessment" /
    // Clone buttons live in kbAssessmentHistory's shadow root, so it captured
    // the element and restores it via its @api restoreFocus(). We only call this
    // when the list is the visible surface — a run-started close swaps to the
    // list, and the deep-link / clone-error paths also land there.
    _restoreTriggerFocus() {
        const history = this.template.querySelector('c-kb-assessment-history');
        if (history && typeof history.restoreFocus === 'function') {
            history.restoreFocus();
        }
    }

    // ── Path handlers ─────────────────────────────────────────────────────
    handleDetailsChange(event) {
        this.runName = event.detail.runName || '';
        this.description = event.detail.description || '';
        this.detailsValid = !!event.detail.isValid;
    }

    handleContinueToSelect() {
        const form = this.template.querySelector('c-kb-assessment-details-form');
        const valid = form ? form.reportValidity() : this.detailsValid;
        if (!valid) {
            return;
        }
        this.currentStep = 'select';
        this._reachedSelect = true;
    }

    handleSelectionChange(event) {
        this.selectedArticleIds = event.detail.selectedIds;
        this.selectedArticleRows = event.detail.selectedRows || [];
        this.selectionFilterContext = event.detail.filterContext || null;
        this.selectAllMatchingFilter = !!event.detail.selectAllMatchingFilter;
        this.filterSnapshot = event.detail.filterSnapshot || null;
        this.matchingFilterCount = event.detail.totalCount || 0;
        this.excludedIds = event.detail.excludedIds || [];
    }

    handleContinueToPreview() {
        if (this.selectedArticleIds.length > 0 || this.selectAllMatchingFilter) {
            this.currentStep = 'preview';
        }
    }

    handleBackToDetails() {
        this.currentStep = 'details';
    }

    handleBackToSelect() {
        this.currentStep = 'select';
    }

    /**
     * "Start Assessment" on the preview step. The preview consumption panel is
     * rendered inline (embedded kbRunCostPreview), so we submit directly via the
     * runner's public submitRun() rather than opening the runner's own modal.
     */
    handleStartFromPreview() {
 // double-submit guard. Ignore re-presses while a submit is in
        // flight; the flag is cleared on the runstarted / submiterror / close
        // paths so the button never strands permanently disabled.
        if (this.isSubmitting) {
            return;
        }
        // Defence-in-depth for the large-run gate (the button is already
        // disabled via startDisabled): never submit a flagged run before the
        // typed-RUN confirmation is entered.
        if (this._runNeedsConfirmation && !this._runConfirmed) {
            return;
        }
        const runner = this.template.querySelector('c-kb-assessment-runner');
        if (runner) {
            this.isSubmitting = true;
            runner.submitRun();
        }
    }

    /**
     * Run submitted from the preview step. Close the modal and return to the
     * All Assessments list, which auto-refreshes and shows the run in-progress.
     */
    handleRunStarted() {
        this.isModalOpen = false;
        this.resetNewAssessmentPath();
        this.historySubView = 'list';
        this.refreshHistory();
    }

    handleSubmitError(event) {
 // the submit failed and the modal stays open; re-enable the
        // Start button so the user can correct the issue and retry.
        this.isSubmitting = false;
        this.dispatchEvent(new ShowToastEvent({
            title: 'Could not start assessment',
            message: (event.detail && event.detail.message) || 'Unknown error',
            variant: 'error'
        }));
    }

    refreshHistory() {
        const history = this.template.querySelector('c-kb-assessment-history');
        if (history && typeof history.refresh === 'function') {
            history.refresh();
        }
    }

    // ── History handlers ──────────────────────────────────────────────────
    async handleViewHistoricalRun(event) {
        const { runId, isRunning } = event.detail;

        if (isRunning) {
            this.runningRunId = runId;
            this.runningRunName = event.detail.runName || 'Run in progress';
 // first-paint description for the progress header; the
            // progress LWC re-stamps the authoritative value from its poll.
            this.runningRunDescription = event.detail.description || null;
 // prefer the run's scan-start time (re-stamped fresh on a
            // destructive rerun) so the live elapsed-time timer counts from
            // when scoring actually started, not the original creation. Fall
            // back to createdDate for first-runs / pre-fix runs where
            // scanStartTime is null.
            this.runningRunStartedAt =
                event.detail.scanStartTime || event.detail.createdDate || null;
            this.historySubView = 'running';
            return;
        }

        this.isLoadingHistorical = true;
        this.historySubView = 'detail';

        try {
            this.historicalResult = await getAssessmentResults({ runId });
        } catch (error) {
            console.error('Error loading assessment:', error);
            this.historicalResult = null;
            this.historySubView = 'list';
        } finally {
            this.isLoadingHistorical = false;
        }
    }

    handleBackToHistory() {
        this.historySubView = 'list';
        this.historicalResult = null;
        this.runningRunId = null;
        this.runningRunName = null;
        this.runningRunDescription = null;
    }

    /**
 * "View Actions" on a run card. Deep-link to the Action Center
     * scoped to this run; the run id rides in page state as c__runId, which
     * the Action Center's per-assessment filter reads to pre-select the run
     * (the c__ prefix is required for namespaced state, harmless unmanaged).
     */
    handleViewRunActions(event) {
        const { runId } = event.detail;
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Candidate_Inbox' },
            state: { c__runId: runId }
        });
    }

    /**
 * "View Actions" on a single article card. Deep-link to the Action
     * Center scoped to the run AND targeted at the article: c__articleId makes
     * kbCandidateInbox select the Issues tab and auto-expand/scroll that
 * article's section (the existing deep-link path); c__runId keeps the
     * per-assessment run filter aligned with the results view we came from.
     */
    handleViewArticleActions(event) {
        const { articleId, runId } = event.detail;
        const state = { c__articleId: articleId };
        if (runId) {
            state.c__runId = runId;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Candidate_Inbox' },
            state
        });
    }

    async handleRunFinished(event) {
        const { runId, status } = event.detail;
        this.runningRunId = null;
        this.runningRunName = null;
        this.runningRunDescription = null;
        if (status === 'Completed') {
            this.isLoadingHistorical = true;
            this.historySubView = 'detail';
            try {
                this.historicalResult = await getAssessmentResults({ runId });
            } catch {
                this.historicalResult = null;
                this.historySubView = 'list';
            } finally {
                this.isLoadingHistorical = false;
            }
        } else {
            this.historySubView = 'list';
        }
    }

    // "New Assessment" pressed from the All Assessments list → open the modal.
    handleStartNewFromHistory() {
        this.historySubView = 'list';
        this.historicalResult = null;
        this.openModal('details');
    }

    /**
 * a destructive rerun was kicked off from a run card. The history
     * child already refreshes itself; we stay on the list view so the fresh
     * in-progress run is visible, and refresh once more here for parity with
     * the new-assessment flow (covers the rare case the child's own refresh
     * raced the delete commit).
     */
    handleRerunStarted() {
        this.historySubView = 'list';
        this.historicalResult = null;
        this.refreshHistory();
    }

    /**
 * Clone was clicked on a run card. Open the new-assessment modal
     * prefilled with the source run's "Copy of …" name, description, and its
     * article scope (re-resolved to CURRENT published versions). A clone creates
     * a brand-new run, so the source is untouched and history is preserved.
     *
     * Follows the same ordering contract as the c__articleId deep-link:
     * openModal() resets the path FIRST, so every prefill is set AFTER the
     * server call resolves.
     */
    async handleCloneFromHistory(event) {
        const { sourceRunId } = event.detail;
        this.historySubView = 'list';
        this.historicalResult = null;
        this.openModal('details');

        try {
            const sel = await getRunSelectionForClone({ runId: sourceRunId });

            if (!sel.articleIds || sel.articleIds.length === 0) {
                // Nothing recoverable (e.g. every article archived/merged, or a
                // run that failed before children were created). Don't drop the
                // user into an empty basket with no explanation.
                this.handleCloseModal();
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Nothing to clone',
                        message:
                            'This run has no current published articles to re-assess ' +
                            '(they may have been archived, merged, or retired).',
                        variant: 'warning'
                    })
                );
                return;
            }

            // Set AFTER openModal — resetNewAssessmentPath() ran inside it.
            this.runName = sel.suggestedRunName;
            this.description = sel.description || '';
            this.detailsValid = !!(this.runName && this.runName.trim());
            this._reachedSelect = true;
            this.preselectedArticleIds = sel.articleIds;

            // Surface membership churn — never silently shrink the set.
            if (sel.droppedNoPublishedVersionCount > 0) {
                const n = sel.droppedNoPublishedVersionCount;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: `${n} article${n === 1 ? '' : 's'} not carried over`,
                        message:
                            'They have no current published version (archived, retired, ' +
                            'or merged) and were left out of the copy. Review the ' +
                            'selection before running.',
                        variant: 'warning',
                        mode: 'sticky'
                    })
                );
            }

 // (review) — the server caps a very large cloned scope so the
            // selector isn't overloaded. Warn when that happened so the cap is
            // never a silent truncation.
            const capped = sel.resolvedArticleCount - sel.articleIds.length;
            if (capped > 0) {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Clone limited to the first ' + sel.articleIds.length + ' articles',
                        message:
                            `The source run covered ${sel.resolvedArticleCount} articles — too ` +
                            'many to preview at once. Add more articles manually if you need them, ' +
                            'or run separate assessments.',
                        variant: 'warning',
                        mode: 'sticky'
                    })
                );
            }
        } catch (error) {
            this.handleCloseModal();
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not clone assessment',
                    message: this._extractError(error),
                    variant: 'error'
                })
            );
        }
    }

    /**
 * (review) — the article selector couldn't hydrate the cloned rows
     * (typically an FLS gap on a Knowledge field). The ids are still selected
     * so the run is submittable, but the basket shows stub titles — tell the
     * user why rather than leaving an unexplained empty-looking modal.
     */
    handlePreselectionError(event) {
        const n = (event.detail && event.detail.count) || 0;
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Some article details could not be loaded',
                message:
                    `The ${n} cloned article${n === 1 ? ' is' : 's are'} still selected and the run ` +
                    'will assess them, but their details need Knowledge field access to display. ' +
                    'Ask your admin to grant read access to the Knowledge content fields.',
                variant: 'warning',
                mode: 'sticky'
            })
        );
    }

    // kbAssessmentApp has no reduceErrors helper of its own — small local
    // extractor for the clone catch (mirrors the shape used elsewhere).
    _extractError(error) {
        return (
            (error && error.body && error.body.message) ||
            (error && error.message) ||
            'Unknown error'
        );
    }
}
