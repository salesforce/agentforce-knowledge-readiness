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
import { LightningElement, api, track } from 'lwc';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import LightningConfirm from 'lightning/confirm';
import checkRunStatus from '@salesforce/apex/KBAssessmentController.checkRunStatus';
import cancelAssessmentRun from '@salesforce/apex/KBAssessmentController.cancelAssessmentRun';

const PE_CHANNEL = '/event/KB_Assessment_Progress__e';
const INITIAL_POLL_MS = 5000;
const MAX_POLL_MS = 30000;
const MAX_POLL_DURATION_MS = 30 * 60 * 1000; // stop polling after 30 min
const RUNNING_STATUSES = new Set(['Pending', 'In Progress', 'Pipeline Running', 'Queued', 'Scoring Complete']);
const TERMINAL_STATUSES = new Set(['Completed', 'Failed', 'Cancelled']);

// ETA tuning. SEED_SECONDS_PER_ARTICLE is only used to size the *initial*
// estimate before any progress has been reported — once the run publishes its
// first completion fraction, ETA switches to an observed-velocity model
// (elapsed ÷ fractionDone) which self-corrects for the org's real throughput
// and the platform's ~5-chunk concurrency. ~7s/article-callout is the
// post- single-callout-per-article wall-clock cited in CLAUDE.md.
const SEED_SECONDS_PER_ARTICLE = 7;
// The dedup pipeline (Pipeline Running) is an opaque tail we can't size from
// scoring counts; treat it as a flat fraction of total work for ETA purposes.
const PIPELINE_TAIL_FRACTION = 0.2;

export default class KbAssessmentRunProgress extends LightningElement {
    @api runId;
    @api runName;
    @api runStartedAt;
 // user-supplied description from the "Assessment details" step,
    // shown under the run name instead of the raw record id. Passed in by the
    // shell for instant paint; the first checkRunStatus poll re-stamps the
    // authoritative value (see poll()). Blank → friendly placeholder.
    @api runDescription;

    @track _description;

    @track status = 'In Progress';
    @track statusMessage = 'Loading run status…';
    // True once the backend has pushed a real Message__c via Platform Event —
    // lets progressCopy prefer live backend copy over its status-derived hints.
    @track _hasLiveMessage = false;
    @track articlesProcessed = 0;
    @track totalArticles = 0;
    @track currentBatch = 0;
    @track totalBatches = 0;
 // parallel scoring shards each publish a shard-LOCAL cumulative count
    // tagged with a 1-based shard index (Current_Batch__c). We keep the latest
    // count per shard here and sum them into articlesProcessed so the bar
    // reflects whole-run progress — concurrent shards no longer clobber each
    // other's counts. Plain object (not @track): we reassign articlesProcessed
    // after each mutation, which is what the reactive getters read.
    _shardCounts = {};
    // Dedup-phase pair counts (Tier 4) — drive the 80→100% band.
    @track pipelinePairsDone = 0;
    @track pipelinePairsTotal = 0;
    @track elapsedSeconds = 0;
    @track startTime;
    // Monotonic floor for the completion fraction. The dedup pipeline tail
    // publishes no counts and Tier4 can re-emit 'In Progress' (which would
    // otherwise recompute the fraction from the now-stale scoring counts) —
    // latching forward guarantees the bar/percent never move backward.
    @track _fractionFloor = 0;
    @track error = null;
    @track isCancelling = false;
 // server-stamped flag from AssessmentRunResult.canCancel.
    // Default true so the button stays optimistic until the first poll
    // returns the authoritative value; if checkRunStatus stamps false, the
    // showCancelButton getter hides the button entirely.
    @track _canCancel = true;

    subscription;
    pollTimer;
    elapsedTimer;
    _pollInterval = INITIAL_POLL_MS;
    _pollStartTime;

    async connectedCallback() {
        this.startTime = this.runStartedAt ? new Date(this.runStartedAt).getTime() : Date.now();
        this._pollStartTime = Date.now();
        this.tick();
        this.elapsedTimer = setInterval(() => this.tick(), 1000);
        // Await subscribe before the first poll so the live-event channel is
        // armed when poll() returns. Mirrors the subscribe-first ordering in
 // kbAssessmentRunner: the first poll iteration acts as
        // the safety net for the case where the run finished before subscribe
        // returned, and live events take over from there.
        await this.subscribeToPlatformEvents();
        this.poll();
    }

    disconnectedCallback() {
        this.cleanup();
    }

    async subscribeToPlatformEvents() {
        onError((err) => console.error('EmpApi error:', JSON.stringify(err)));
        try {
            this.subscription = await subscribe(PE_CHANNEL, -1, (evt) => {
                this.handlePlatformEvent(evt);
            });
        } catch (e) {
            // Subscribe failure is non-fatal here — poll() is the durable
            // fallback (exponential backoff via checkRunStatus). The runner
            // LWC has only the one-shot post-subscribe poll, so it deliberately
            // lets subscribe errors propagate. Don't symmetrize without keeping
            // a polling fallback there too.
            console.error('Subscribe failed:', e);
        }
    }

    handlePlatformEvent(evt) {
        const p = evt.data.payload;
        if (!this.runId || p.Assessment_Id__c !== this.runId) return;

        this.status = p.Status__c || this.status;
        if (p.Message__c) {
            this.statusMessage = p.Message__c;
            this._hasLiveMessage = true;
        }
        this.totalArticles = p.Total_Articles__c || this.totalArticles;
        // During the dedup phase Current/Total_Batches carry PAIR counts (Tier 4),
        // not scoring-dimension counts. Route them to the pipeline-pair fields so
        // the 80→100% band animates without colliding with stale scoring values.
        if (this.status === 'Pipeline Running') {
            if (p.Total_Batches__c) this.pipelinePairsTotal = p.Total_Batches__c;
            if (p.Current_Batch__c != null) this.pipelinePairsDone = p.Current_Batch__c;
        } else if (p.Articles_Processed__c != null && p.Current_Batch__c != null) {
 // parallel scoring shard. Articles_Processed__c is shard-LOCAL;
            // Current_Batch__c is the 1-based shard index. Keep the latest count
            // per shard (events can arrive out of order / be redelivered — take
            // the max so a stale lower count can't rewind a shard) then sum all
            // shards into the whole-run articlesProcessed.
            const shardKey = String(p.Current_Batch__c);
            const prev = this._shardCounts[shardKey] || 0;
            this._shardCounts[shardKey] = Math.max(prev, p.Articles_Processed__c);
            this.articlesProcessed = Object.values(this._shardCounts).reduce(
                (sum, n) => sum + n,
                0
            );
        } else {
            // Legacy single-batch scoring path (Articles_Processed__c, no shard
            // index) or the queueable dimension path (Current_Batch__c /
            // Total_Batches__c, no article count).
            this.articlesProcessed = p.Articles_Processed__c || this.articlesProcessed;
            this.currentBatch = p.Current_Batch__c || this.currentBatch;
            this.totalBatches = p.Total_Batches__c || this.totalBatches;
        }
        this.latchFraction();

        if (TERMINAL_STATUSES.has(this.status)) {
            this.cleanup();
            this.dispatchEvent(new CustomEvent('runfinished', {
                detail: { runId: this.runId, status: this.status }
            }));
        }
    }

    async poll() {
        try {
            const result = await checkRunStatus({ runId: this.runId });
            if (result) {
                this.status = result.status || this.status;
 // the poll carries the authoritative description (the
                // shell's @api prop is only a first-paint hint). Stamp it even
                // when blank so a cleared description is reflected.
                this._description = result.description ?? null;
                if (!this.totalArticles && result.totalArticles) {
                    this.totalArticles = result.totalArticles;
                }
                this.latchFraction();
 // stamp the server's canCancel verdict so the
                // button hides for users without FLS edit on Status__c.
                if (result.canCancel === false) {
                    this._canCancel = false;
                }
                if (!RUNNING_STATUSES.has(this.status)) {
                    this.cleanup();
                    this.dispatchEvent(new CustomEvent('runfinished', {
                        detail: { runId: this.runId, status: this.status }
                    }));
                    return;
                }
            }
        } catch (e) {
            this.error = this.reduceErrors(e);
        }
        // Exponential backoff: double interval every cycle, cap at MAX_POLL_MS.
        // Stop polling entirely after MAX_POLL_DURATION_MS — Platform Events
        // subscription is the primary update mechanism; polling is belt-and-suspenders.
        if (Date.now() - this._pollStartTime > MAX_POLL_DURATION_MS) {
            return;
        }
        this._pollInterval = Math.min(this._pollInterval * 1.5, MAX_POLL_MS);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setTimeout(() => this.poll(), this._pollInterval);
    }

    tick() {
        this.elapsedSeconds = Math.floor((Date.now() - this.startTime) / 1000);
    }

    cleanup() {
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = null;
        }
        if (this.pollTimer) {
            clearTimeout(this.pollTimer);
            this.pollTimer = null;
        }
        if (this.elapsedTimer) {
            clearInterval(this.elapsedTimer);
            this.elapsedTimer = null;
        }
    }

    get descriptionDisplay() {
 // before the first poll, _description is undefined — fall back to
        // the @api first-paint hint. After a poll it's the authoritative value
        // (possibly blank, hence the placeholder). Mirrors the
        // "No description provided" convention in kbAssessmentDashboard.
        const desc = this._description !== undefined ? this._description : this.runDescription;
        return desc?.trim() || 'No description provided';
    }

    get elapsedDisplay() {
        return this.formatDuration(this.elapsedSeconds);
    }

    /**
     * Human-readable duration that scales by magnitude so a long-running scan
     * never reads as "1000m 00s":
     *   < 1 min  → "Xm YYs"  (keeps the familiar minute:second form)
     *   < 1 day  → "Xh Ym"   (e.g. "2h 13m")
     *   ≥ 1 day  → "Xd Yh"   (e.g. "1d 4h")
     */
    formatDuration(totalSeconds) {
        const secs = Math.max(0, Math.floor(totalSeconds || 0));
        const days = Math.floor(secs / 86400);
        const hours = Math.floor((secs % 86400) / 3600);
        const minutes = Math.floor((secs % 3600) / 60);
        const seconds = secs % 60;
        if (days > 0) return `${days}d ${hours}h`;
        if (hours > 0) return `${hours}h ${minutes}m`;
        return `${minutes}m ${String(seconds).padStart(2, '0')}s`;
    }

    // The display bar and the numeric label share one source (the latched
    // completion fraction) so they can never disagree. Floor at 15% while the
    // run is live but nothing measurable has been reported yet (optimistic
    // "queued" state), matching the prior UX.
    get progressPercent() {
        const pct = Math.round(this.completionFraction * 100);
        if (!this.isTerminal && pct < 15) return 15;
        return pct;
    }

    /**
     * True fraction of work done (0–1). Scoring (dimension or article counts)
     * is treated as the leading (1 - PIPELINE_TAIL_FRACTION) of the run; the
     * dedup pipeline is the trailing PIPELINE_TAIL_FRACTION. Latched forward so
     * it never moves backward. Drives both the bar and the ETA.
     */
    get completionFraction() {
        // Latch forward: never report less than the high-water mark. _rawFraction
        // is updated into _fractionFloor in handlePlatformEvent / poll.
        return Math.max(this._fractionFloor, this._rawFraction);
    }

    get _rawFraction() {
        if (this.isTerminal) return 1;
        const scoringDone = 1 - PIPELINE_TAIL_FRACTION;
        if (this.status === 'Pipeline Running' || this.status === 'Scoring Complete') {
            // Animate across the trailing PIPELINE_TAIL_FRACTION using Tier 4's
            // "X of Y pairs". Cap just below 1 so the bar reaches 100% only on
            // the terminal 'Completed' event, not on the last pair (the callback
            // still has finalization work after the last comparison).
            if (this.pipelinePairsTotal > 0) {
                const frac = Math.min(1, this.pipelinePairsDone / this.pipelinePairsTotal);
                return Math.min(0.99, scoringDone + frac * PIPELINE_TAIL_FRACTION);
            }
            return scoringDone;
        }
        const scoringSpan = 1 - PIPELINE_TAIL_FRACTION;
        if (this.totalBatches > 0) {
            return Math.min(scoringSpan, (this.currentBatch / this.totalBatches) * scoringSpan);
        }
        if (this.totalArticles > 0 && this.articlesProcessed > 0) {
            return Math.min(scoringSpan, (this.articlesProcessed / this.totalArticles) * scoringSpan);
        }
        return 0;
    }

    // Bump the monotonic floor to the latest raw reading. Call after any state
    // update that can change _rawFraction.
    latchFraction() {
        const raw = this._rawFraction;
        if (raw > this._fractionFloor) this._fractionFloor = raw;
    }

    get progressPercentLabel() {
        return `${this.progressPercent}%`;
    }

    /**
     * Estimated time remaining. Before any progress is reported we seed from
     * SEED_SECONDS_PER_ARTICLE × totalArticles (best-effort, only if we know
     * the scope); once a measurable fraction is done we switch to the
     * observed-velocity model: remaining = elapsed × (1 - f) / f. Hidden while
     * the value would be meaningless (no scope known and no progress yet).
     */
    get etaSeconds() {
        const f = this.completionFraction;
        if (f >= 1) return 0;
        if (f > 0 && this.elapsedSeconds > 0) {
            return Math.round((this.elapsedSeconds * (1 - f)) / f);
        }
        // No measurable progress yet — fall back to the static seed if we at
        // least know how many articles are in scope.
        if (this.totalArticles > 0) {
            return Math.round(this.totalArticles * SEED_SECONDS_PER_ARTICLE);
        }
        return null;
    }

    get showEta() {
        return !this.isTerminal && this.etaSeconds !== null && this.etaSeconds > 0;
    }

    get etaDisplay() {
        const secs = this.etaSeconds;
        if (secs === null || secs <= 0) return '';
        if (secs < 60) return 'about a minute';
        const m = Math.round(secs / 60);
        if (m < 60) return `~${m} min`;
        const h = Math.floor(m / 60);
        const remM = m % 60;
        if (h < 24) return remM ? `~${h}h ${remM}m` : `~${h}h`;
        const d = Math.floor(h / 24);
        const remH = h % 24;
        return remH ? `~${d}d ${remH}h` : `~${d}d`;
    }

    get phaseLabel() {
        if (this.status === 'Pipeline Running') return 'Duplicate & conflict check';
        if (this.status === 'Failed') return 'Failed';
        if (this.status === 'Cancelled') return 'Cancelled';
        if (this.isCancelling) return 'Cancelling…';
        return 'Scoring';
    }

    get isTerminal() {
        return TERMINAL_STATUSES.has(this.status);
    }

    get cancelButtonDisabled() {
        return this.isCancelling || this.isTerminal;
    }

    get cancelButtonLabel() {
        return this.isCancelling ? 'Cancelling…' : 'Cancel';
    }

    get showCancelButton() {
 // hide for read-only users (Viewer permset). The server
        // stamps canCancel=false on AssessmentRunResult when the running
        // user lacks FLS edit on KB_Assessment_Run__c.Status__c.
        return !this.isTerminal && this._canCancel !== false;
    }

    get progressCopy() {
        if (this.status === 'Pipeline Running') {
            // Prefer a real backend message (e.g. pair-progress) when one has
            // arrived; otherwise a plain-language hint (no internal tier jargon).
            return this._hasLiveMessage
                ? this.statusMessage
                : 'Checking for duplicates and conflicts…';
        }
        if (this.currentBatch && this.totalBatches) {
            return `Batch ${this.currentBatch} of ${this.totalBatches}`;
        }
        if (this.articlesProcessed && this.totalArticles) {
            return `${this.articlesProcessed} of ${this.totalArticles} articles scored`;
        }
        // No counts yet (e.g. batch path before chunk 1 completes). Prefer a
        // live backend message; otherwise a status-derived hint instead of the
        // stuck "Loading run status…" default.
        if (this._hasLiveMessage) return this.statusMessage;
        if (this.status === 'Queued' || this.status === 'Pending') {
            return 'Queued — dispatching scorers…';
        }
        if (this.status === 'Scoring Complete') {
            return 'Scoring complete — checking for duplicates and conflicts…';
        }
        if (this.status === 'In Progress') {
            return 'Scoring articles…';
        }
        return this.statusMessage;
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('back'));
    }

    /**
 * Cancel button handler. Confirms with the user, then asks
     * Apex to flip the run to Cancelled and abortJob each captured async
     * job. We don't optimistically flip status here — let the next poll or
     * 'Cancelled' Platform Event drive the UI to its terminal state. That
     * way a rejected Apex call doesn't leave the UI in a stuck "cancelled"
     * state while jobs continue server-side.
     */
    async handleCancel() {
        if (!this.runId || this.isCancelling || this.isTerminal) return;

        const confirmed = await LightningConfirm.open({
            message: 'Cancel this assessment? In-flight jobs will be aborted; partial results will be saved.',
            label: 'Cancel run',
            theme: 'warning'
        });
        if (!confirmed) return;

        this.isCancelling = true;
        try {
            await cancelAssessmentRun({ runId: this.runId });
        } catch (e) {
            this.isCancelling = false;
            this.error = this.reduceErrors(e);
        }
    }

    reduceErrors(err) {
        if (!err) return 'Unknown error';
        if (typeof err === 'string') return err;
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return 'Unknown error';
    }
}
