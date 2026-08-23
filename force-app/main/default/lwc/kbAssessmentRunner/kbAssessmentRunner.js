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
import runAssessmentAdvanced from '@salesforce/apex/KBAssessmentController.runAssessmentAdvanced';
import getMatchingArticleIds from '@salesforce/apex/KBAssessmentController.getMatchingArticleIds';

const ALL_DIMENSION_VALUES = [
    'completeness',
    'structure',
    'clarity',
    'freshness',
    'duplication',
    'conflict'
];

/**
 * preview-and-submit host for the new-assessment flow.
 *
 * There is no longer a dedicated "Preview" page — the preview is the
 * kbRunCostPreview *modal*, opened directly from the Select Articles step via
 * the public `openPreview()` method. This component owns no visible page chrome
 * of its own; it just hosts the modal and performs the run submit. On submit it
 * dispatches `runstarted` (the shell navigates to All Assessments) or
 * `submiterror` (the shell surfaces the message). Progress is tracked on the
 * All Assessments tab (via kbAssessmentRunProgress), not here.
 */
export default class KbAssessmentRunner extends LightningElement {
    @api runName;
    @api description;
    @api selectedArticleIds = [];
    @api selectedArticleCount = 0;
    @api selectionFilterContext;
    @api selectAllMatchingFilter = false;
    @api filterSnapshot;
    @api excludedIds = [];

 // selectedDimensions is no longer user-selectable. Every run
    // uses all 6 dimensions. The field stays as state so the cost preview's
    // @api contract and the runAssessmentAdvanced payload continue to receive
    // the value without further changes downstream.
    @track selectedDimensions = [...ALL_DIMENSION_VALUES];

    // Cost preview modal state. The parent opens it via openPreview(); the modal
    // runs its own estimate call, and we resume via handleCostPreviewProceed /
    // handleCostPreviewCancel.
    @track showCostPreview = false;

 // in-flight guard. Second layer of the double-submit defence (the
    // shell's UI flag is the first): a programmatic double-call to submitRun()
    // /_startRun() while a submit is already running is a no-op. Cleared in a
    // finally so it never strands.
    _submitting = false;

    /**
     * Public entry point — opens the preview modal. Called by the shell when
     * the user clicks "Continue to Preview" on the Select Articles step
     * (version A, full-page flow).
     */
    @api
    openPreview() {
        this.showCostPreview = true;
    }

    /**
     * Public entry point — submits the run directly, no preview modal. Used by
     * version B (modal flow), where the preview consumption panel is rendered
     * inline as its own step, so the user has already seen it before clicking
     * "Start Assessment". Same submit + runstarted/submiterror contract.
     */
    @api
    submitRun() {
        return this._startRun();
    }

    /**
 * public reset for the in-flight guard. The runner is rendered
     * outside the shell's modal block, so its instance (and `_submitting`)
     * survives a modal close/reopen. The shell calls this whenever it resets
     * the new-assessment path so the runner's guard can't strand `true` from a
     * still-resolving prior submit and silently swallow the next one. Safe to
     * call mid-flight: a stale in-flight call's own `finally` is a no-op once
     * the flag is already cleared, and its result is discarded by the shell
     * (the modal has moved on).
     */
    @api
    resetSubmitState() {
        this._submitting = false;
    }

    /**
     * Article count to pass to the cost preview. For "select all matching
     * filter" mode the actual id resolution only happens inside _startRun
     * (SOQL roundtrip); at preview time we fall back to the visible count,
     * which may undercount. Acceptable trade-off — the preview is indicative,
     * not contractual, and the alternative is a pre-flight roundtrip the user
     * may never confirm through.
     */
    get costPreviewArticleCount() {
        return this.selectedArticleCount || 0;
    }

    handleCostPreviewCancel() {
        this.showCostPreview = false;
    }

    async handleCostPreviewProceed() {
        this.showCostPreview = false;
        await this._startRun();
    }

    async _startRun() {
 // second-layer in-flight guard: a programmatic double-call is a
        // no-op while the first submit is still resolving.
        if (this._submitting) {
            return;
        }
        this._submitting = true;
        try {
            let articleIds = this.selectedArticleIds;
            let requestedScope = 'Selected';

            if (this.selectAllMatchingFilter && this.filterSnapshot) {
                articleIds = await getMatchingArticleIds({
                    filterJSON: JSON.stringify(this.filterSnapshot)
                });
                if (this.excludedIds && this.excludedIds.length > 0 && articleIds) {
                    const excluded = new Set(this.excludedIds);
                    articleIds = articleIds.filter(id => !excluded.has(id));
                }
                if (!articleIds || articleIds.length === 0) {
                    this._emitError('No articles match the selected filter.');
                    return;
                }
                requestedScope = 'MatchingFilter';
            }

            const snapshot = this.selectAllMatchingFilter && this.filterSnapshot
                ? this.filterSnapshot
                : this.selectionFilterContext;

            const options = {
                assessmentTypes: ['Readiness'],
                selectedDimensions: this.selectedDimensions,
                requestedScope,
                runName: this.runName,
                description: this.description,
                filterLogic: snapshot?.filterLogic || 'AND',
                filterClauses: snapshot?.filterClauses || []
            };

            const result = await runAssessmentAdvanced({
                articleIds,
                optionsJSON: JSON.stringify(options)
            });

            // Run submitted. Progress is tracked on the All Assessments tab —
            // hand control back to the shell, which navigates there.
            this.dispatchEvent(new CustomEvent('runstarted', {
                detail: { runId: result && result.runId, status: result && result.status }
            }));
        } catch (err) {
            this._emitError(this.reduceErrors(err));
        } finally {
 // clear the in-flight guard on every exit path (success,
            // empty-match early return, error) so a subsequent submit is allowed.
            this._submitting = false;
        }
    }

    _emitError(message) {
        this.dispatchEvent(new CustomEvent('submiterror', { detail: { message } }));
    }

    reduceErrors(errors) {
        if (!Array.isArray(errors)) {
            errors = [errors];
        }

        return errors
            .filter(error => !!error)
            .map(error => {
                if (typeof error === 'string') {
                    return error;
                }
                if (error.body && error.body.message) {
                    return error.body.message;
                }
                if (error.message) {
                    return error.message;
                }
                return 'Unknown error';
            })
            .join(', ');
    }
}
