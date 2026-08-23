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
import { LightningElement, api, track, wire } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import getRecentRuns from '@salesforce/apex/KBAssessmentController.getRecentRuns';
import getRecentRunsLive from '@salesforce/apex/KBAssessmentController.getRecentRunsLive';
import deleteAssessmentRun from '@salesforce/apex/KBAssessmentController.deleteAssessmentRun';
import cancelAssessmentRun from '@salesforce/apex/KBAssessmentController.cancelAssessmentRun';
import getRunDeletionImpact from '@salesforce/apex/KBAssessmentController.getRunDeletionImpact';
import rerunAssessment from '@salesforce/apex/KBAssessmentController.rerunAssessment';
import getCloneArticleCap from '@salesforce/apex/KBAssessmentController.getCloneArticleCap';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';

// Lifecycle (per CLAUDE.md): Pending → Queued → In Progress → Scoring Complete
// → Pipeline Running → Completed / Failed. 'Scoring Complete' is an
// intermediate state where scoring is done but the dedup pipeline is still
// running — the run is NOT terminal yet, so it must stay in the running set
// to keep the watch alive. The previous value 'Scoring' did not exist
// in the picklist; 'Scoring Complete' is what's actually emitted.
const RUNNING_STATUSES = new Set(['Pending', 'In Progress', 'Pipeline Running', 'Queued', 'Scoring Complete']);
const TERMINAL_STATUSES = new Set(['Completed', 'Failed', 'Cancelled']);

// A running row's badge advances primarily off the same KB_Assessment_Progress__e
// stream the live-run viewer (kbAssessmentRunProgress) consumes — the backend
// already publishes terminal Completed/Failed/Cancelled events, so attaching a
// second subscriber adds no publishes. The backed-off poll below is a
// self-terminating fallback for orgs where empApi delivery is gated; it stops
// the instant no row is still running, so an idle list makes zero calls.
const PE_CHANNEL = '/event/KB_Assessment_Progress__e';
const POLL_INTERVAL_MS = 5000;
const MAX_POLL_MS = 30000;

export default class KbAssessmentHistory extends LightningElement {
    @track runs = [];
    @track isLoading = true;
    @track error = null;
 // the searchable run filter narrows the displayed list to one run
    // (null = "All assessments"). The wire still loads the full recent set; we
    // filter in the getter so clearing the filter is instant (no re-query).
    @track selectedRunId = null;

 // max articles a run (and therefore a clone) can hold, from the
    // server (matchingFilterCap, 10k). A run above it can't be cloned into the
    // per-row basket, so the Clone button is disabled with an explanatory
    // tooltip. Held reactively so decorate() re-runs once the cap resolves.
    @track cloneArticleCap = null;

    wiredRunsResult;
    pollTimer;
    subscription;
 // the trigger element (New Assessment / a Clone button) that opened
    // the new-assessment wizard. Captured on click so the host (kbAssessmentApp)
    // can return focus to it when the wizard closes, satisfying WCAG 2.4.3. Held
    // here because these buttons live in THIS component's shadow root — the host
    // can't reach them across the boundary, so it delegates via restoreFocus().
    _wizardTrigger = null;
    // Reentrancy guard for the destructive rerun. LightningConfirm.open() has no
    // singleton behaviour of its own — the old hand-rolled modal was a single
    // boolean, so repeated Rerun clicks just re-set one flag; the confirm now
    // stacks one dialog per click, and each resolved dialog fires rerunAssessment
    // (three clicks → three runs). This guard makes the confirm at-most-one
 // in flight, mirroring the double-submit pattern.
    _rerunInFlight = false;
    _pollInterval = POLL_INTERVAL_MS;
    // Cleared in disconnectedCallback so an in-flight poll tick's finally
    // doesn't re-arm a timer (or apply results) on an unmounted component.
    _connected = true;

    // Subscribe to the progress stream for instant badge advances. We don't
    // need the subscribe-first one-shot-poll ordering kbAssessmentRunProgress
 // uses: the cacheable wire paints the initial list, and the
    // self-arming fallback poll (scheduleFallbackPoll, via getRecentRunsLive)
    // reconciles any terminal event missed during the subscribe window within
    // one interval — so a dropped event self-heals rather than freezing.
    connectedCallback() {
        this.subscribeToProgress();
    }

    @wire(getCloneArticleCap)
    wiredCloneCap({ data }) {
        if (data) {
            this.cloneArticleCap = data;
            // Re-decorate any rows already painted before the cap resolved so
            // their Clone-button gate reflects it.
            if (this.runs.length) {
                this.runs = this.runs.map((r) => this.decorate(r));
            }
        }
    }

    @wire(getRecentRuns, { limitSize: 20 })
    wiredRuns(result) {
        this.wiredRunsResult = result;
        this.isLoading = false;
        if (result.data) {
            this.runs = result.data.map((run) => this.decorate(run));
            this.error = null;
            this.scheduleFallbackPoll();
        } else if (result.error) {
            this.error = this.reduceErrors(result.error);
            this.runs = [];
        }
    }

    disconnectedCallback() {
        this._connected = false;
        this.clearPollTimer();
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = null;
        }
    }

    async subscribeToProgress() {
        onError((err) =>
            console.error('kbAssessmentHistory empApi error', JSON.stringify(err))
        );
        try {
            this.subscription = await subscribe(PE_CHANNEL, -1, (evt) =>
                this.handleProgressEvent(evt)
            );
        } catch (e) {
            // Non-fatal: scheduleFallbackPoll() keeps the list current via the
            // backed-off getRecentRunsLive poll when empApi is unavailable.
            console.warn('kbAssessmentHistory subscribe failed', e);
        }
    }

    // Push path: the backend publishes KB_Assessment_Progress__e as a run moves
    // through its lifecycle (incl. terminal Completed/Failed/Cancelled). Match
    // the event to a visible row and advance its badge in place — no server
    // call for intermediate transitions. The event payload omits Overall_Score__c,
    // so a terminal event triggers one live read to repaint the row with its
    // final score. Events for runs not on this list are ignored.
    handleProgressEvent(evt) {
        const p = evt && evt.data && evt.data.payload;
        if (!p || !p.Assessment_Id__c || !p.Status__c) return;
        const row = this.runs.find((r) => r.runId === p.Assessment_Id__c);
        if (!row) return;
        // Monotonic guard: events can arrive out of order (a heartbeat published
        // before, but delivered after, the terminal event). Once a row is
        // terminal it never goes back to a running badge — ignore any later
 // non-terminal event for it.
        if (!RUNNING_STATUSES.has(row.status)) return;
        if (TERMINAL_STATUSES.has(p.Status__c)) {
            this.refresh();
        } else {
            this.runs = this.runs.map((r) => {
                if (r.runId !== p.Assessment_Id__c) return r;
                return this.decorate({ ...r, status: p.Status__c });
            });
        }
    }

    /**
     * Imperative refresh — used by `kbAssessmentApp` right after a run is
     * submitted so the new row appears immediately, and as the post-subscribe
     * safety net + terminal-event repaint. Layers a non-cacheable
     * `getRecentRunsLive` call on top of the wired payload to bypass the LDS
 * cache the `cacheable=true` wire holds.
     */
    @api
    async refresh() {
        if (this.wiredRunsResult) {
            await refreshApex(this.wiredRunsResult);
        }
        try {
            const fresh = await getRecentRunsLive({ limitSize: 20 });
            if (Array.isArray(fresh)) {
                this.runs = fresh.map((run) => this.decorate(run));
                this.error = null;
                this.scheduleFallbackPoll();
            }
        } catch (err) {
            // Non-fatal — the platform-event subscription keeps the list in sync.
            console.warn('getRecentRunsLive refresh failed', err);
        }
    }

    decorate(run) {
        const isRunning = RUNNING_STATUSES.has(run.status);
 // prefer the user-supplied name; fall back to the auto-number
        // Name (RUN-####) for historical or unnamed runs.
        const displayName =
            run.userRunName && run.userRunName.trim() ? run.userRunName : run.runName;
        return {
            ...run,
            displayName,
            formattedDate: this.formatDate(run.scanStartTime || run.createdDate),
            // Final wall-clock for completed runs ("took 2h 13m"). Null while
            // running / on failed runs → the template hides the segment.
            durationDisplay: this.formatDuration(run.totalDurationMs),
 // "by <who ran it>" byline, matching the record-page run
            // picker. Null on legacy rows with no owner name → template hides it.
            ranByDisplay:
                run.ranBy && run.ranBy.trim() ? run.ranBy.trim() : null,
 // Clone is disabled while running (nothing stable to copy)
            // AND when the run's article count exceeds the clone cap (the per-row
            // basket can't hold more than the app-wide max run size). The tooltip
            // explains the cap. cloneArticleCap is null until the wire resolves —
            // treat unknown as "not over cap" so the button isn't wrongly blocked.
            cloneDisabled:
                isRunning ||
                (this.cloneArticleCap != null &&
                    run.totalArticles > this.cloneArticleCap),
            cloneTitle:
                this.cloneArticleCap != null &&
                run.totalArticles > this.cloneArticleCap
                    ? `This run has ${run.totalArticles} articles — too many to clone. ` +
                      `The maximum is ${this.cloneArticleCap}. Use New Assessment with ` +
                      `"select all matching" for larger sets.`
                    : 'Clone this assessment into a new run',
            statusClass: this.getStatusClass(run.overallScore, run.status),
            displayScore: run.overallScore ? Math.round(run.overallScore) : 0,
            isRunning,
 // "View Actions" deep-links to the run-filtered Action Center.
            // Only completed runs have recommendations to act on, so gate the
            // button on Completed (a running/failed run has nothing to show).
            isCompleted: run.status === 'Completed',
            statusBadge: this.getStatusBadge(run.status),
 // accessible name for the role="button" run row. A bare
            // "button" announcement is useless to screen-reader users, so name
            // the action and the run; append the score/status when the run is
            // scored so the row is self-describing without sighted context.
            openRunLabel: this.buildOpenRunLabel(run, displayName, isRunning)
        };
    }

 // compose the run row's aria-label. Completed & scored → include the
    // score; running/failed → state only, since there's no meaningful score yet.
    buildOpenRunLabel(run, displayName, isRunning) {
        if (isRunning) {
            return `Open assessment: ${displayName}, in progress`;
        }
        if (run.status === 'Completed' && run.overallScore) {
            return `Open assessment: ${displayName}, score ${Math.round(run.overallScore)}`;
        }
        return `Open assessment: ${displayName}, ${run.status}`;
    }

 // the rows actually rendered — narrowed to the selected run when the
    // filter is active, else the full recent set.
    get filteredRuns() {
        if (!this.selectedRunId) return this.runs;
        return this.runs.filter((r) => r.runId === this.selectedRunId);
    }

 // show the run filter whenever the org has any runs to filter
    // keyed off the full set (not the filtered view) so the control stays
    // available to clear an active filter even when it narrows to zero rows.
    get showRunFilter() {
        return !this.isLoading && this.runs && this.runs.length > 0;
    }

    get hasRuns() {
        return this.filteredRuns && this.filteredRuns.length > 0;
    }

    get noRuns() {
        return !this.isLoading && (!this.filteredRuns || this.filteredRuns.length === 0);
    }

 // run-filter selection. runId is null for "All assessments".
    handleRunSelect(event) {
        this.selectedRunId = event.detail.runId;
    }

    // Human-readable run duration from a millisecond span, scaled by magnitude
    // so a long run never reads as "1000m". Returns '' when absent (in-flight or
    // failed runs have no stamped Total_Duration_Ms__c).
    formatDuration(ms) {
        if (ms === null || ms === undefined || ms <= 0) return '';
        const secs = Math.floor(ms / 1000);
        const days = Math.floor(secs / 86400);
        const hours = Math.floor((secs % 86400) / 3600);
        const minutes = Math.floor((secs % 3600) / 60);
        const seconds = secs % 60;
        if (days > 0) return `${days}d ${hours}h`;
        if (hours > 0) return `${hours}h ${minutes}m`;
        if (minutes > 0) return `${minutes}m ${seconds}s`;
        return `${seconds}s`;
    }

    formatDate(dateString) {
        if (!dateString) return '';
        const date = new Date(dateString);
        return date.toLocaleDateString('en-US', {
            year: 'numeric',
            month: 'short',
            day: 'numeric',
            hour: '2-digit',
            minute: '2-digit'
        });
    }

    getStatusClass(score, status) {
        if (RUNNING_STATUSES.has(status)) return 'status-running';
        if (status === 'Failed') return 'status-failed';
        if (!score && score !== 0) return 'status-needs-work';
        if (score >= 80) return 'status-ready';
        if (score >= 50) return 'status-needs-work';
        return 'status-not-ready';
    }

    getStatusBadge(status) {
        if (status === 'In Progress' || status === 'Queued' || status === 'Scoring Complete') {
            return { label: 'Scoring…', cssClass: 'status-pill pill-running' };
        }
        if (status === 'Pipeline Running') {
            return { label: 'Checking…', cssClass: 'status-pill pill-pipeline' };
        }
        if (status === 'Failed') {
            return { label: 'Failed', cssClass: 'status-pill pill-failed' };
        }
        return null;
    }

    // Fallback poll for orgs where empApi delivery is gated — and the durable
 // path off the cacheable wire's stale snapshot: each tick reads the
    // non-cacheable getRecentRunsLive, so a row's badge advances even with no
    // event. Self-terminating (stops once no row is running) and self-arming
    // in finally (a one-off error can't freeze the loop). Backed off 5s→30s so
    // a long pipeline run doesn't hammer the server. An idle list = no timer.
    scheduleFallbackPoll() {
        this.clearPollTimer();
        if (!this._connected || !this.runs.some((r) => r.isRunning)) {
            this._pollInterval = POLL_INTERVAL_MS;
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setTimeout(async () => {
            try {
                const fresh = await getRecentRunsLive({ limitSize: 20 });
                // The await can resolve after the component unmounts — don't
                // touch reactive state or re-arm on a dead component.
                if (this._connected && Array.isArray(fresh)) {
                    this.runs = fresh.map((run) => this.decorate(run));
                    this.error = null;
                }
            } catch (err) {
                // Keep the last-known list; the next tick (or an event) recovers.
                console.warn('kbAssessmentHistory poll failed', err);
            } finally {
                this._pollInterval = Math.min(this._pollInterval * 1.5, MAX_POLL_MS);
                this.scheduleFallbackPoll();
            }
        }, this._pollInterval);
    }

    clearPollTimer() {
        if (this.pollTimer) {
            clearTimeout(this.pollTimer);
            this.pollTimer = null;
        }
    }

    handleViewRun(event) {
        const runId = event.currentTarget.dataset.runId;
        const status = event.currentTarget.dataset.status;
        const runName = event.currentTarget.dataset.runName;
 // user-supplied description, for the live-progress header's
        // first paint (the progress LWC re-stamps it from its own poll).
        // Empty string (no dataset value) normalised to null.
        const description = event.currentTarget.dataset.description || null;
        const createdDate = event.currentTarget.dataset.createdDate;
 // the run's scan-start time, re-stamped fresh on a destructive
        // rerun. The shell prefers this over createdDate for the live
        // elapsed-time timer so a rerun counts from when scoring actually
        // restarted, not the original creation. Empty string (no dataset value)
        // is normalised to null so the shell's `|| createdDate` fallback fires.
        const scanStartTime = event.currentTarget.dataset.scanStartTime || null;
        this.dispatchEvent(
            new CustomEvent('viewrun', {
                detail: { runId, status, runName, description, createdDate, scanStartTime, isRunning: RUNNING_STATUSES.has(status) }
            })
        );
    }

 // the run row is a role="button" (see template), so it must be
    // operable by keyboard — Enter/Space activate it, mirroring a native
    // button. Guard on target === currentTarget so a key press forwarded from
    // a nested button (View Actions / Rerun / Delete) doesn't also open the
    // run. Space is prevented from scrolling the page.
    handleRowKeydown(event) {
        if (event.target !== event.currentTarget) {
            return;
        }
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleViewRun(event);
        }
    }

 // "View Actions" on a run card. stopPropagation so the card's own
    // click (handleViewRun → results view) doesn't also fire.
    handleViewActions(event) {
        event.stopPropagation();
        const runId = event.currentTarget.dataset.runId;
        this.dispatchEvent(new CustomEvent('viewactions', { detail: { runId } }));
    }

    async handleDeleteRun(event) {
        event.stopPropagation();
        const runId = event.currentTarget.dataset.runId;

 // warn before deleting, with the REAL counts of what will be
        // removed so the user knows exactly what they lose. The run's duplicate
        // & enrichment candidates are deleted with it (the Suggested Article
        // Drafts and Duplicates queues lose these rows). Any AI-Fix Knowledge
        // drafts themselves are NOT deleted, but the link back to this run is
 // lost. delivers this warning through LightningConfirm (not the
        // native confirm()).
        let ecCount = 0;
        let dcCount = 0;
        try {
            const impact = await getRunDeletionImpact({ runId });
            ecCount = impact?.enrichmentCandidateCount || 0;
            dcCount = impact?.duplicateCandidateCount || 0;
        } catch {
            // Count lookup is best-effort — fall back to the generic warning.
        }

        const impactLine =
            ecCount === 0 && dcCount === 0
                ? 'This cannot be undone.'
                : `This will also delete ${ecCount} enrichment candidate(s) and ` +
                  `${dcCount} duplicate candidate(s). Any AI-Fix drafts will no longer ` +
                  `be linked back to this run (the Knowledge drafts themselves are not ` +
                  `deleted). This cannot be undone.`;

        const confirmed = await LightningConfirm.open({
            message: `Delete this assessment run?\n\n${impactLine}`,
            label: 'Delete run',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }

        try {
            await deleteAssessmentRun({ runId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: 'Assessment run deleted',
                    variant: 'success'
                })
            );
            await refreshApex(this.wiredRunsResult);
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: this.reduceErrors(error),
                    variant: 'error'
                })
            );
        }
    }

    async handleCancelRun(event) {
        event.stopPropagation();
        const runId = event.currentTarget.dataset.runId;

        const confirmed = await LightningConfirm.open({
            message: 'Cancel this assessment? In-flight jobs will be aborted; partial results will be saved.',
            label: 'Cancel run',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }

        try {
            await cancelAssessmentRun({ runId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: 'Assessment run cancelled',
                    variant: 'success'
                })
            );
            await this.refresh();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: this.reduceErrors(error),
                    variant: 'error'
                })
            );
        }
    }

    handleNewAssessment(event) {
 // remember the trigger so focus returns here when the wizard
        // closes. currentTarget is the lightning-button host in our shadow root.
        this._wizardTrigger = event.currentTarget;
        this.dispatchEvent(new CustomEvent('newassessment'));
    }

    /**
 * return focus to whichever button opened the new-assessment wizard
     * (New Assessment, or a per-row Clone). Called by the host on every close
     * path. Guarded: if the trigger row has since been re-rendered away (e.g. a
     * clone that started a run and repainted the list), the stale reference is a
     * no-op rather than a throw.
     */
    @api
    restoreFocus() {
        const trigger = this._wizardTrigger;
        this._wizardTrigger = null;
        if (trigger && typeof trigger.focus === 'function') {
            trigger.focus();
        }
    }

 // ──: Clone ───────────────────────────────────────────────────────
    // Pure delegate — the parent (kbAssessmentApp) owns the server call and
    // modal hydration. Only the source run id is passed; the "Copy of …" name,
    // description, and article scope all come back authoritatively from
    // getRunSelectionForClone. stopPropagation so the card's own click
    // (handleViewRun → results view) doesn't also fire.
    handleCloneRun(event) {
        event.stopPropagation();
 // remember the Clone button so focus returns to it on close.
        this._wizardTrigger = event.currentTarget;
        this.dispatchEvent(
            new CustomEvent('clonerun', {
                detail: { sourceRunId: event.currentTarget.dataset.runId }
            })
        );
    }

 // ── /: Rerun (destructive) ──────────────────────────────────
    // A pure destructive yes/no confirm, so it routes through the platform
    // lightning/confirm (focus-trapped, Escape-dismissable) rather than a
    // hand-rolled alertdialog — mirroring the delete/cancel pattern above.
    // stopPropagation so the card's own click (handleViewRun → results view)
    // doesn't also fire.
    async handleRerunClick(event) {
        event.stopPropagation();
        // At-most-one confirm + rerun in flight — repeated clicks would otherwise
        // stack confirm dialogs and kick off a run per dialog.
        if (this._rerunInFlight) {
            return;
        }
        this._rerunInFlight = true;
        const runId = event.currentTarget.dataset.runId;
        const runName = event.currentTarget.dataset.runName;

        try {
            const confirmed = await LightningConfirm.open({
                message: this.buildRerunMessage(runName),
                label: 'Rerun assessment?',
                theme: 'warning'
            });
            if (!confirmed) {
                return;
            }

            const result = await rerunAssessment({ runId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Rerun started',
                    message: 'Re-assessing the same articles. Current scores stay visible until the new results are ready…',
                    variant: 'success'
                })
            );
 // some in-scope articles may have no current published
            // version (archived / retired / merged). The rerun proceeds for the
            // rest; warn the user, and the skipped ones are flagged in-results.
            const skipped = result && result.skippedNoPublishedVersionCount;
            if (skipped > 0) {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: `${skipped} article${skipped === 1 ? '' : 's'} skipped`,
                        message:
                            `${skipped} article${skipped === 1 ? ' has' : 's have'} no current published version ` +
                            `and ${skipped === 1 ? 'was' : 'were'} skipped (see the run's results for details). ` +
                            `They may have been archived, retired, or merged.`,
                        variant: 'warning',
                        mode: 'sticky'
                    })
                );
            }
            // Tell the shell to refresh so the fresh in-progress run appears.
            this.dispatchEvent(new CustomEvent('rerunstarted'));
            await this.refresh();
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not rerun assessment',
                    message: this.reduceErrors(error),
                    variant: 'error'
                })
            );
        } finally {
            // Cleared on every exit — cancelled confirm, success, or error — so
            // a later legitimate rerun isn't permanently blocked.
            this._rerunInFlight = false;
        }
    }

    buildRerunMessage(runName) {
        const name = runName ? `"${runName}"` : 'this assessment';
        return (
            `Rerunning ${name} re-assesses the same articles in place. Its ` +
            `current scores and improvement recommendations stay visible until ` +
            `the new results are ready, then they are replaced. This cannot be undone.`
        );
    }

    reduceErrors(errors) {
        if (!Array.isArray(errors)) {
            errors = [errors];
        }
        return errors
            .filter((error) => !!error)
            .map((error) => {
                if (typeof error === 'string') return error;
                if (error.body && error.body.message) return error.body.message;
                if (error.message) return error.message;
                return 'Unknown error';
            })
            .join(', ');
    }
}
