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
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRunDiagnostics from '@salesforce/apex/KBAssessmentController.getRunDiagnostics';

// Mirrors KB_Scoring_Dimension__mdt order. Deploy-time stable; kept inline to
// avoid a roundtrip per dashboard render. Update alongside the CMDT if a
// dimension is added. Weight is intentionally not shown — it read as a
// failing score next to the actual dimension score.
const DIMENSIONS = [
    { key: 'Completeness', label: 'Completeness' },
    { key: 'Structure',    label: 'Structure' },
    { key: 'Clarity',      label: 'Clarity' },
    { key: 'Freshness',    label: 'Freshness' },
    { key: 'Duplication',  label: 'Duplication' },
    { key: 'Conflict',     label: 'Conflict' }
];

export default class KbAssessmentDashboard extends LightningElement {
    @api assessmentResult;

    @track _diag;
    @track _diagError;
    @track _isDiagExpanded = false;

    // Read diagnostics for the current run. Only active when assessmentResult
    // carries a runId. Wires are auto-invalidated when runId changes.
    @wire(getRunDiagnostics, { runId: '$runIdForDiag' })
    wiredDiagnostics({ data, error }) {
        if (data !== undefined) {
            this._diag = data;
            this._diagError = null;
        } else if (error) {
            this._diagError = error?.body?.message || error?.message || 'Could not load run diagnostics';
            this._diag = null;
        }
    }

    get runIdForDiag() {
        return this.assessmentResult?.runId || null;
    }

 // gate "View Actions" on a completed run — a Failed run can reach
    // the dashboard (only running runs divert to the progress view), and it
    // has no recommendations to act on. Mirrors the run-card's isCompleted gate.
    get isCompleted() {
        return this.assessmentResult?.status === 'Completed';
    }

 // the run-level counterpart to the per-card isUnreachable gate
    // (kbArticleScoreCard). The article cards already disable their own
    // "View Actions" deep-link when the target version is unreachable (deleted
    // or access-lost), but the run-level "View Actions" button was gated on
    // isCompleted ALONE — so a run whose articles are ALL unreachable still
    // rendered an enabled button that deep-links into a run-scoped Action
    // Center where every target dead-ends. Disable (with an explanatory
    // tooltip) once every article in the run is unreachable.
    //
    // Threshold is deliberately "ALL unreachable", not "no open issues": if
    // even one article is still reachable the run-scoped Action Center remains
    // useful, and gating on issue presence would wrongly hide the button for a
    // dedup-only run (candidate findings live on Duplicate_Candidate__c, not on
    // article recommendations). isReachable defaults to true when the flag is
    // absent (older payloads), so this only trips on a genuinely-flagged set.
    get allArticlesUnreachable() {
        const articles = this.assessmentResult?.articleResults;
        if (!articles || articles.length === 0) {
            return false;
        }
        return articles.every((a) => a.isReachable === false);
    }

    get viewActionsDisabled() {
        return this.allArticlesUnreachable;
    }

    get viewActionsTooltip() {
        return this.allArticlesUnreachable
            ? 'Every article in this run has been deleted or is no longer accessible, so there’s nothing to open in the Action Center.'
            : 'Act on this run’s recommendations in the Action Center';
    }

    // Only show the error panel when the run is not Completed. Users who
    // landed on a successful run don't need diagnostics noise.
    get showErrorPanel() {
        if (!this._diag) return false;
        const s = this._diag.status;
        return s && s !== 'Completed';
    }

    get hasFailures() {
        return (this._diag?.failures?.length || 0) > 0;
    }

    get diagStatus() {
        return this._diag?.status || '';
    }

    get failureRows() {
        return this._diag?.failures || [];
    }

    get diagExpandedIcon() {
        return this._isDiagExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get isDiagExpanded() {
        return this._isDiagExpanded;
    }

    get isDiagExpandedStr() {
        return this._isDiagExpanded ? 'true' : 'false';
    }

    toggleDiagPanel() {
        this._isDiagExpanded = !this._isDiagExpanded;
    }

    handleDiagKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.toggleDiagPanel();
        }
    }

    handleCopyFailedArticleIds() {
        // Failed-article list is not directly exposed today (no Status__c on
        // KB_Article_Assessment__c in this phase). This button copies the
        // run's AsyncApexJob failure list as JSON — the best actionable
        // output we can offer without schema changes.
        const text = JSON.stringify(this.failureRows, null, 2);
        try {
            navigator.clipboard.writeText(text);
            this.dispatchEvent(new ShowToastEvent({
                title: 'Copied',
                message: 'Failure diagnostics copied to clipboard.',
                variant: 'success'
            }));
        } catch {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Clipboard blocked',
                message: 'Select the JSON manually to copy.',
                variant: 'warning'
            }));
        }
    }

    get hasResult() {
        return this.assessmentResult != null;
    }

    get noResult() {
        return !this.hasResult;
    }

 // Highlights header ---
    // Salesforce-highlights-panel-style identity block so the user can tell
    // which assessment they're looking at without going back. Run name is the
    // visual anchor; status + description are supporting context. All three
    // ride on the AssessmentRunResult DTO — no extra Apex.

    // Prefer the user-supplied name (userRunName / Run_Name__c), falling back to
    // the auto-number (runName / Name) — the same display convention as
    // kbAssessmentHistory and kbRunFilter. Showing the auto-number here would
    // defeat the purpose: the panel exists so the user recognises *their*
    // assessment, not "RUN-0001".
    get assessmentName() {
        const userName = this.assessmentResult?.userRunName;
        if (userName && userName.trim()) {
            return userName;
        }
        const autoNum = this.assessmentResult?.runName;
        return autoNum && autoNum.trim() ? autoNum : 'Assessment';
    }

    get assessmentStatus() {
        return this.assessmentResult?.status || '';
    }

    get hasAssessmentStatus() {
        return !!this.assessmentStatus;
    }

    get assessmentDescription() {
        const desc = this.assessmentResult?.description;
        return desc && desc.trim() ? desc : 'No description provided';
    }

    get hasArticleResults() {
        return this.hasResult &&
               this.assessmentResult.articleResults &&
               this.assessmentResult.articleResults.length > 0;
    }

    get noArticleResults() {
        return this.hasResult && !this.hasArticleResults;
    }

    // --- Dimension overview (run-level aggregate scores) ---

    get hasDimensionScores() {
        const scores = this.assessmentResult?.dimensionScores;
        return this.hasResult && scores && Object.keys(scores).length > 0;
    }

    get dimensionRows() {
        if (!this.hasDimensionScores) return [];
        const scores = this.assessmentResult.dimensionScores || {};
        return DIMENSIONS.map((dim, index) => {
            const raw = scores[dim.key];
            const scored = raw !== null && raw !== undefined;
            const score = scored ? Math.round(raw) : 0;
            return {
                id: `dim-${index}`,
                label: dim.label,
                scored,
                score,
                displayScore: scored ? score : 'N/A',
                variant: !scored ? 'base' : score >= 80 ? 'success' : score >= 50 ? 'warning' : 'error',
                scoreClass: !scored ? 'dim-score score-na'
                    : score >= 80 ? 'dim-score score-good'
                    : score >= 50 ? 'dim-score score-warn'
                    : 'dim-score score-bad'
            };
        });
    }

    // --- Maturity & deployment tier ---

    get maturityTier() {
        return this.assessmentResult?.maturityTier || null;
    }

    get deploymentTier() {
        return this.assessmentResult?.deploymentTier || null;
    }

    get hasTiers() {
        return this.hasResult && (this.maturityTier || this.deploymentTier);
    }

    get deploymentTierClass() {
        const tier = this.deploymentTier;
        if (tier === 'Easy') return 'tier-badge tier-easy';
        if (tier === 'Medium') return 'tier-badge tier-medium';
        if (tier === 'Hard') return 'tier-badge tier-hard';
        return 'tier-badge';
    }

    get maturityTierClass() {
        return 'tier-badge tier-maturity';
    }

    get usedLLMLabel() {
        return this.assessmentResult?.usedLLM ? 'AI-Enhanced' : 'Deterministic';
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('back'));
    }

 // bubble the run id up so the app can deep-link to the run-filtered
    // Action Center — same destination as the run card's View Actions.
    handleViewActions() {
 // defensive: the button is disabled when all articles are
        // unreachable, but guard the handler too so a programmatic dispatch
        // can't deep-link into a dead-end Action Center.
        if (this.allArticlesUnreachable) {
            return;
        }
        this.dispatchEvent(
            new CustomEvent('viewactions', { detail: { runId: this.assessmentResult?.runId } })
        );
    }

 // a per-article score card asked to jump to that article's actions.
    // Bubble both the article id and the run id up so the app can deep-link the
    // Action Center to the article's Issues (and keep the run filter scoped).
    handleViewArticleActions(event) {
        this.dispatchEvent(
            new CustomEvent('viewarticleactions', {
                detail: {
                    articleId: event.detail?.articleId,
                    runId: this.assessmentResult?.runId
                }
            })
        );
    }
}
