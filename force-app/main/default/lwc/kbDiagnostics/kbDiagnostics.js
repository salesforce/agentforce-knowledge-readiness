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
import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSnapshot from '@salesforce/apex/KBDiagnosticsController.getSnapshot';
import getDiagnosticBundle from '@salesforce/apex/KBDiagnosticsController.getDiagnosticBundle';

import TITLE from '@salesforce/label/c.KB_Diag_Tab_Title';
import SUBTITLE from '@salesforce/label/c.KB_Diag_Subtitle';
import REFRESH from '@salesforce/label/c.KB_Diag_Action_Refresh';
import COPY_BUNDLE from '@salesforce/label/c.KB_Diag_Action_CopyBundle';
import COPY_SUCCESS from '@salesforce/label/c.KB_Diag_Toast_CopySuccess';
import COPY_FAIL from '@salesforce/label/c.KB_Diag_Toast_CopyFail';
import SECTION_PREFLIGHT from '@salesforce/label/c.KB_Diag_Section_Preflight';
import SECTION_LIMITS from '@salesforce/label/c.KB_Diag_Section_Limits';
import SECTION_FAILURES from '@salesforce/label/c.KB_Diag_Section_Failures';
import SECTION_RUNTIME from '@salesforce/label/c.KB_Diag_Section_Runtime';
import NO_FAILURES from '@salesforce/label/c.KB_Diag_NoFailures';

const FAILURE_COLUMNS = [
    { label: 'Class', fieldName: 'className', type: 'text' },
    { label: 'Method', fieldName: 'methodName', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text', initialWidth: 90 },
    { label: 'Job Type', fieldName: 'jobType', type: 'text', initialWidth: 120 },
    { label: 'Created', fieldName: 'createdAt', type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    { label: 'Error', fieldName: 'extendedStatus', type: 'text', wrapText: true }
];

/**
 * Diagnostics tab body. Single snapshot call on load + on Refresh; no wires
 * (snapshot data must be live, not cached). Copy-bundle uses the browser's
 * async Clipboard API; on rejection we surface a textarea fallback.
 */
export default class KbDiagnostics extends LightningElement {
    @track snapshot;
    @track error;
    @track isLoading = true;

    // Fallback-textarea state. showFallbackTextarea is only true when the
    // async clipboard write rejected — the textarea holds the JSON bundle
    // so the user can select + copy manually.
    @track bundleJson = '';
    @track showFallbackTextarea = false;

    titleLabel = TITLE;
    subtitleLabel = SUBTITLE;
    refreshLabel = REFRESH;
    copyBundleLabel = COPY_BUNDLE;
    sectionPreflightLabel = SECTION_PREFLIGHT;
    sectionLimitsLabel = SECTION_LIMITS;
    sectionFailuresLabel = SECTION_FAILURES;
    sectionRuntimeLabel = SECTION_RUNTIME;
    noFailuresLabel = NO_FAILURES;

    failureColumns = FAILURE_COLUMNS;

    async connectedCallback() {
        await this.loadSnapshot();
    }

    async loadSnapshot() {
        this.isLoading = true;
        this.error = null;
        try {
            this.snapshot = await getSnapshot();
        } catch (err) {
            this.error = this.extractError(err);
            this.snapshot = null;
        } finally {
            this.isLoading = false;
        }
    }

    async handleRefresh() {
        await this.loadSnapshot();
    }

    /**
     * User-gesture handler — required for navigator.clipboard.writeText().
     * Fetch the server-serialized bundle and write it. On rejection show a
     * fallback textarea so the user can copy manually.
     */
    async handleCopyBundle() {
        try {
            const bundle = await getDiagnosticBundle();
            this.bundleJson = bundle;
            try {
                await navigator.clipboard.writeText(bundle);
                this.showFallbackTextarea = false;
                this.showToast('Copied', COPY_SUCCESS, 'success');
            } catch {
                this.showFallbackTextarea = true;
                this.showToast('Clipboard blocked', COPY_FAIL, 'warning');
            }
        } catch (err) {
            this.showToast('Error', this.extractError(err), 'error');
        }
    }

    // ─── Getters for template ──────────────────────────────────────────────

    get capturedAtLabel() {
        if (!this.snapshot?.capturedAt) return '';
        return new Date(this.snapshot.capturedAt).toLocaleString();
    }

    get preflightRows() {
        const checks = this.snapshot?.preflightChecks || [];
        return checks.map(c => ({ ...c, ...this.severityUi(c) }));
    }

    get limitRows() {
        const rows = this.snapshot?.orgLimits || [];
        return rows.map(r => ({
            ...r,
            usedFormatted: this.formatNum(r.usedValue),
            limitFormatted: this.formatNum(r.limitValue),
            variant: this.limitVariant(r.usedPct)
        }));
    }

    get failureRows() {
        return this.snapshot?.recentFailures || [];
    }

    get hasFailures() {
        return this.failureRows.length > 0;
    }

    get runtimeRows() {
        const vp = this.snapshot?.vectorProvider || {};
        const lr = this.snapshot?.lastRun || {};
        const ws = this.snapshot?.wizardState || {};
        return {
            vectorProvider: vp.implementationClass || '(not configured)',
            searchIndex: vp.searchIndexName || '(not configured)',
            dataCloudLabel: vp.dataCloudAvailable ? 'Yes' : 'No',
            lastRunLabel: lr.runId
                ? `${lr.name || lr.runId} · ${lr.status || 'Unknown'} · ${this.formatDate(lr.createdAt)}`
                : 'No runs yet',
            setupLabel: ws.setupCompleted ? 'Yes' : 'No'
        };
    }

    // ─── Helpers ───────────────────────────────────────────────────────────

    severityUi(check) {
        if (check.passed) {
            return { icon: 'utility:success', iconClass: 'check-icon_success' };
        }
        if (check.severity === 'blocker') {
            return { icon: 'utility:error', iconClass: 'check-icon_error' };
        }
        return { icon: 'utility:warning', iconClass: 'check-icon_warning' };
    }

    limitVariant(pct) {
        if (pct >= 80) return 'expired';
        if (pct >= 60) return 'warning';
        return 'base-autocomplete';
    }

    formatNum(n) {
        if (n === null || n === undefined) return '—';
        return n.toLocaleString();
    }

    formatDate(iso) {
        if (!iso) return '';
        try {
            return new Date(iso).toLocaleString();
        } catch {
            return iso;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractError(error) {
        if (typeof error === 'string') return error;
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return 'Unknown error';
    }
}
