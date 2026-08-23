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
import getOrgHealthData from '@salesforce/apex/KBAssessmentController.getOrgHealthData';
import isSetupCompleted from '@salesforce/apex/KBSetupOrchestratorController.isSetupCompleted';

export default class KbHealthDashboard extends NavigationMixin(LightningElement) {
    orgHealth;
    error;
    isLoading = true;
    @track _setupCompleted = null;

    @wire(CurrentPageReference)
    pageRefChanged() {
        this.checkSetupStatus();
    }

    async checkSetupStatus() {
        try {
            this._setupCompleted = !!(await isSetupCompleted());
        } catch {
            this._setupCompleted = true;
        }
    }

    get isSetupCheckPending() { return this._setupCompleted === null; }
    get isSetupComplete() { return this._setupCompleted === true; }
    get isSetupIncomplete() { return this._setupCompleted === false; }

    @wire(getOrgHealthData)
    wiredOrgHealth({ error, data }) {
        this.isLoading = false;
        if (data) {
            this.orgHealth = data;
            this.error = null;
        } else if (error) {
            this.error = this.reduceErrors(error);
            this.orgHealth = null;
        }
    }

    // ─── Top-level state ───────────────────────────────────────────────────────

    get hasCompletedRun() {
        return this.orgHealth?.hasCompletedRun;
    }

    get showEmptyState() {
        return !this.isLoading && !this.error && !this.hasCompletedRun;
    }

    get showConfigBanner() {
        return this.orgHealth && (!this.orgHealth.hasScanConfig || !this.orgHealth.hasScoreWeights);
    }

    // ─── KPI row ───────────────────────────────────────────────────────────────

    get totalPublishedArticles() {
        return this.orgHealth?.totalPublishedArticles ?? 0;
    }

    get totalAssessedArticles() {
        return this.orgHealth?.totalAssessedArticles ?? 0;
    }

    get coveragePct() {
        return this.orgHealth?.coveragePct ?? 0;
    }

    get pendingDuplicates() {
        return this.orgHealth?.pendingDuplicates ?? 0;
    }

    get pendingEnrichments() {
        return this.orgHealth?.pendingEnrichments ?? 0;
    }

    get hasPendingActions() {
        return this.pendingDuplicates > 0 || this.pendingEnrichments > 0;
    }

    get pendingDuplicatesClass() {
        const base = 'kpi-value';
        return this.pendingDuplicates > 0 ? base + ' kpi-value--warn' : base;
    }

    get pendingEnrichmentsClass() {
        const base = 'kpi-value';
        return this.pendingEnrichments > 0 ? base + ' kpi-value--info' : base;
    }

    // ─── Latest run panel ──────────────────────────────────────────────────────

    get latestRun() {
        return this.orgHealth?.runHistory?.[0];
    }

    get latestScore() {
        return this.latestRun?.overallScore ?? 0;
    }

    get lastScanDate() {
        if (!this.orgHealth?.lastScanDate) return 'Never';
        return new Date(this.orgHealth.lastScanDate).toLocaleDateString(undefined, {
            year: 'numeric', month: 'short', day: 'numeric',
            hour: '2-digit', minute: '2-digit'
        });
    }

    get latestScopeLabel() {
        const run = this.latestRun;
        if (!run) return '';
        return run.totalArticles + ' articles · ' + (run.requestedScope || 'All');
    }

    get latestComparabilityWarning() {
        const run = this.latestRun;
        if (!run || run.comparableToPrevious === true || run.comparableToPrevious === null) return null;
        return run.incompatibilityReason;
    }

    // ─── Dimension trends ──────────────────────────────────────────────────────

    get dimensionTrendRows() {
        const trends = this.orgHealth?.dimensionTrends;
        if (!trends || trends.length === 0) return [];
        return trends.map(t => {
            const avg = t.averageScore ?? 0;
            const latest = t.latestScore ?? 0;
            let variant = 'expired';
            if (avg >= 80) variant = 'base-autocomplete';
            else if (avg >= 50) variant = 'warning';
            let latestScoreClass = 'dim-score';
            if (latest >= 80) latestScoreClass += ' score-good';
            else if (latest >= 50) latestScoreClass += ' score-warn';
            else latestScoreClass += ' score-bad';
            return {
                dimension: t.dimension,
                averageScore: Math.round(avg),
                latestScore: Math.round(latest),
                avgProgressValue: Math.round(avg),
                variant,
                latestScoreClass,
                isPersistentWeakSpot: t.isPersistentWeakSpot
            };
        });
    }

    // ─── Run history ───────────────────────────────────────────────────────────

    get runHistoryRows() {
        const history = this.orgHealth?.runHistory;
        if (!history || history.length === 0) return [];
        return history.map(r => {
            const score = Math.round(r.overallScore ?? 0);
            let scoreClass = 'run-score';
            if (score >= 80) scoreClass += ' score-good';
            else if (score >= 50) scoreClass += ' score-warn';
            else scoreClass += ' score-bad';
            // Compact headline for the chip + richer detail for the popover.
            // Server-side incompatibilityReason often already reads "Different
            // scope · Different dimensions". We split to show a short chip and
            // a fuller explainer in lightning-helptext.
            const reason = r.incompatibilityReason || '';
            const headline = this._compatHeadline(reason);
            const detail = this._compatDetail(reason);
            return {
                runId: r.runId,
                overallScore: score,
                scoreClass,
                totalArticles: r.totalArticles ?? 0,
                scopeLabel: r.requestedScope || 'All',
                usedLLM: r.usedLLM,
                comparableToPrevious: r.comparableToPrevious,
                incompatibilityReason: reason,
                incompatibilityHeadline: headline,
                incompatibilityDetail: detail,
                completedAtFormatted: r.completedAt
                    ? new Date(r.completedAt).toLocaleDateString(undefined, {
                        month: 'short', day: 'numeric', year: 'numeric'
                      })
                    : '—'
            };
        });
    }

    get hasNextScheduledRun() {
        return !!this.orgHealth?.nextScheduledRun;
    }

    get nextScheduledRun() {
        return this.orgHealth?.nextScheduledRun;
    }

    // ─── Navigation ────────────────────────────────────────────────────────────

    handleStartAssessment() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Assessment_Console' }
        });
    }

    handleGoToSetup() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Assessment_Setup' }
        });
    }

    handleGoToOperations() {
 // KB_Operations was dropped from the simplified app nav.
        // Route users to the Assessment Console — the new homepage where
        // run-related action lives.
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Assessment_Console' }
        });
    }

    // ─── Comparability chip helpers (1.0.J) ────────────────────────────────

    // Short chip text — truncates at the first separator so the chip stays
    // one-line in the narrow run-history column. Popover carries the rest.
    _compatHeadline(reason) {
        if (!reason) return 'Not comparable';
        const first = reason.split(/[·|]/)[0];
        const trimmed = first ? first.trim() : reason.trim();
        return trimmed.length > 40 ? trimmed.substring(0, 37) + '…' : trimmed;
    }

    // Richer detail shown on hover/focus. Expands the server-generated
    // reason string into a multi-line explanation where a '·' or '|' is
    // used as a separator. We keep the original text if no separator is
    // present — trust the server over our parsing heuristic.
    _compatDetail(reason) {
        if (!reason) return 'This run\'s scope, dimensions, or weights differ from the reference run, so scores are not directly comparable.';
        const parts = reason.split(/[·|]/).map(p => p.trim()).filter(Boolean);
        if (parts.length <= 1) return reason;
        return parts.map(p => '• ' + p).join('\n');
    }

    // ─── Utilities ─────────────────────────────────────────────────────────────

    reduceErrors(errors) {
        if (!Array.isArray(errors)) errors = [errors];
        return errors
            .filter(e => !!e)
            .map(e => {
                if (typeof e === 'string') return e;
                if (e.body?.message) return e.body.message;
                if (e.message) return e.message;
                return 'Unknown error';
            })
            .join(', ');
    }
}
