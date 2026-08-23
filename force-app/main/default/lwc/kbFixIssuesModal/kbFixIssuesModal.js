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
import { api, track } from 'lwc';
import LightningModal from 'lightning/modal';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import updateRecommendationStatus from '@salesforce/apex/KBEnrichmentController.updateRecommendationStatus';
import dispatchArticleFix from '@salesforce/apex/KBImprovementFixFacade.dispatchArticleFix';

export default class KbFixIssuesModal extends LightningModal {
    @api articleGroup;
 // 'fix' (default) or 'dismiss'— controls which action is the
    // primary (brand) button and the modal heading. Both actions remain
    // available in either mode; mode just sets the emphasis.
    @api mode = 'fix';
    @track rows         = [];
    @track isProcessing = false;
    @track error;
    @track fixSource    = 'published';

    connectedCallback() {
        this.rows = (this.articleGroup?.recommendations || []).map(r => ({
            ...r,
            checked: true
        }));
    }

    get articleTitle() {
        return this.articleGroup?.articleTitle || '';
    }

    get headerLabel() {
        return `Fix Issues — ${this.articleTitle}`;
    }

    get isDismissMode() {
        return this.mode === 'dismiss';
    }

    // Emphasise the action matching the mode the modal was opened in.
    get fixVariant() {
        return this.isDismissMode ? 'neutral' : 'brand';
    }

    get dismissVariant() {
        return this.isDismissMode ? 'brand' : 'neutral';
    }

    get checkedCount() {
        return this.rows.filter(r => r.checked).length;
    }

    get checkedIds() {
        return this.rows.filter(r => r.checked).map(r => r.recId);
    }

    get hasPendingDraft() {
        return !!this.articleGroup?.pendingDraftId;
    }

    get fixSourceOptions() {
        return [
            { label: 'Apply fixes on the existing draft (preserves enrichment work)', value: 'draft' },
            { label: 'Start fresh from the published version (overwrites the draft)', value: 'published' }
        ];
    }

    handleFixSourceChange(e) {
        this.fixSource = e.detail.value;
    }

    handleCheckChange(e) {
        const recId = e.currentTarget.dataset.recId;
        this.rows = this.rows.map(r => (
            r.recId === recId ? { ...r, checked: e.detail.checked } : r
        ));
    }

    handleClose() {
        this.close();   // resolves the open() promise to undefined = cancel
    }

    handleDismissSelected() {
 // symmetry: guard against re-entrant double-clicks like handleFixWithAI.
        if (this.isProcessing) return;
        const ids = this.checkedIds;
        if (!ids.length) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Nothing selected',
                message: 'Select at least one recommendation to dismiss.',
                variant: 'warning'
            }));
            return;
        }
        this.isProcessing = true;
        updateRecommendationStatus({ recIds: ids, status: 'Rejected' })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Dismissed',
                    message: `${ids.length} recommendation(s) dismissed.`,
                    variant: 'success'
                }));
                this.close({ outcome: 'dismissed', count: ids.length });
            })
            .catch(err => {
                // Surface as a toast too — an inline-only banner is easy to miss
 // (see handleFixWithAI).
                this.error = err?.body?.message || 'Could not dismiss recommendations';
                this.isProcessing = false;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Dismiss failed',
                    message: this.error,
                    variant: 'error'
                }));
            });
    }

    handleFixWithAI() {
 // guard against re-entrant clicks. Without this, a user clicking
        // again while a request is in flight (or right after an error toast)
        // re-enters and re-sets isProcessing, which reads as "the spinner just
        // loops". One in-flight request at a time.
        if (this.isProcessing) return;
        const ids = this.checkedIds;
        if (!ids.length) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Nothing selected',
                message: 'Select at least one issue to fix.',
                variant: 'warning'
            }));
            return;
        }
        this.isProcessing = true;
        this.error = undefined;

        const selectedIssues = this.rows
            .filter(r => r.checked)
            .map(r => `[${r.dimension}] ${r.recommendation}`);

        const useDraft = this.fixSource === 'draft' && this.articleGroup?.pendingDraftId;
        dispatchArticleFix({
            articleVersionId:  useDraft ? this.articleGroup.pendingDraftId : this.articleGroup.articleId,
            useCurrentOnline:  !useDraft,
            recIds:            ids,
            issueDescriptions: selectedIssues
        })
            .then(() => {
                // Single-article fix runs synchronously (KBImprovementFixFacade.
                // dispatchArticleFix), so by the time this resolves the draft
                // already exists — say "ready", not "queued". (The bulk path in
                // kbImprovementsInbox stays "queued" — it's genuinely async.)
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Fix ready',
                    message: 'The AI has rewritten the article. A draft is ready for review in the Suggested Article Drafts tab.',
                    variant: 'success'
                }));
                this.close({ outcome: 'fixed', count: ids.length });
            })
            .catch(err => {
                // Surface the failure as BOTH an inline banner AND a toast. The
                // inline {error} lives inside the lwc:else block and is easy to
                // miss (it can render below the rec list / off-screen on a long
                // list) — which read as "the button does nothing" when the real
                // cause was a clear server error (e.g. the FLS-gap message from
                // KBImprovementFixFacade.toFriendly). The toast guarantees the
 // user sees why the fix didn't run.
                this.error = err?.body?.message || 'Could not queue article fix';
                this.isProcessing = false;
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Fix could not run',
                    message: this.error,
                    variant: 'error',
                    mode: 'sticky'
                }));
            });
    }
}