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
import { LightningElement, track, wire, api } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getEnrichmentInbox from '@salesforce/apex/KBEnrichmentController.getEnrichmentInbox';
import publishCandidate from '@salesforce/apex/KBEnrichmentController.publishCandidate';
import publishCandidatesBulk from '@salesforce/apex/KBEnrichmentController.publishCandidatesBulk';
import rejectCandidate from '@salesforce/apex/KBEnrichmentController.rejectCandidate';
import rejectCandidatesBulk from '@salesforce/apex/KBEnrichmentController.rejectCandidatesBulk';
import KbEnrichmentRejectModal from 'c/kbEnrichmentRejectModal';
import { openInNewTab } from 'c/kbNav';

const ACTIONS = [
    { label: 'Approve', name: 'approve' },
    { label: 'Reject', name: 'reject' },
    { label: 'Open Draft', name: 'openDraft' }
];

const COLUMNS = [
    { label: 'Source Article', fieldName: 'sourceArticleUrl', type: 'url',
      typeAttributes: { label: { fieldName: 'sourceArticleTitle' }, target: '_blank' } },
    { label: 'Draft', fieldName: 'draftArticleUrl', type: 'url',
      typeAttributes: { label: { fieldName: 'draftTitle' }, target: '_blank' } },
 // sourceRunName: the assessment run whose recommendations triggered this AI Fix
    { label: 'Assessment Run', fieldName: 'sourceRunName', type: 'text', initialWidth: 150 },
    { label: 'Status', fieldName: 'status', type: 'text', initialWidth: 100 },
    { label: 'Reason', fieldName: 'reason', type: 'text', wrapText: true },
    { label: 'Created', fieldName: 'createdDate', type: 'date',
      typeAttributes: { month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }, initialWidth: 160 },
    { type: 'action', typeAttributes: { rowActions: ACTIONS } }
];

export default class KbEnrichmentInbox extends LightningElement {
    @api runId;
    @track inboxData;
    @track error;
    @track isLoading = true;
    @track selectedCandidateIds = [];
    @track failedResults = [];

    columns = COLUMNS;
    wiredInboxResult;

    @wire(getEnrichmentInbox, { limitSize: 200, runId: '$runId' })
    wiredInbox(result) {
        this.wiredInboxResult = result;
        this.isLoading = false;
        if (result.data) {
            this.inboxData = result.data;
            this.error = undefined;
            this.dispatchEvent(new CustomEvent('countchange', {
                detail: { count: result.data.pendingCount || 0 },
                bubbles: true, composed: true
            }));
 // no reconcile-on-load DML. getEnrichmentInbox already filters
            // out candidates whose linked draft is no longer a Draft, so the list
            // is correct on arrival. The durable close is event-driven (the
            // Knowledge publish trigger), not triggered by opening this view.
        } else if (result.error) {
            this.error = this.reduceErrors(result.error);
            this.inboxData = undefined;
        }
    }

    get hasData() {
        return this.inboxData && this.inboxData.candidates && this.inboxData.candidates.length > 0;
    }

    get isEmpty() {
        return this.inboxData && (!this.inboxData.candidates || this.inboxData.candidates.length === 0);
    }

    get summaryCards() {
        if (!this.inboxData) return [];
        return [
            { label: 'Pending', value: this.inboxData.pendingCount || 0 },
            { label: 'Approved', value: this.inboxData.approvedCount || 0 },
            { label: 'Drafts', value: this.inboxData.totalDrafts || 0 }
        ];
    }

    get hasSelectedRows() {
        return this.selectedCandidateIds.length > 0;
    }

    get bulkDisabled() {
        return this.isLoading || !this.hasSelectedRows;
    }

    get hasFailedResults() {
        return this.failedResults.length > 0;
    }

    get failedResultsSummary() {
        const count = this.failedResults.length;
        return `${count} item${count > 1 ? 's' : ''} could not be processed:`;
    }

    handleRowSelection(event) {
        this.selectedCandidateIds = event.detail.selectedRows.map(row => row.proposalId);
    }

    handleRowAction(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;

        if (action === 'openDraft' && row.draftArticleUrl) {
 // native-anchor helper, not window.open — LWS blocks
            // window.open on a same-origin URL but permits a browser-driven click.
            openInNewTab(row.draftArticleUrl);
            return;
        }

        if (action === 'approve') {
            this.handleApprove(row);
        } else if (action === 'reject') {
            this.openRejectModal({ isBulk: false, targetId: row.proposalId });
        }
    }

    async handleApprove(row) {
        this.isLoading = true;
        this.failedResults = [];
        try {
            await publishCandidate({ candidateId: row.proposalId });
            this.showToast('Success', 'Candidate approved.', 'success');
            await refreshApex(this.wiredInboxResult);
        } catch (e) {
            this.showToast('Error', this.reduceErrors(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleApproveSelected() {
        this.isLoading = true;
        this.failedResults = [];
        const candidates = this.inboxData.candidates.filter(c => this.selectedCandidateIds.includes(c.proposalId));
        const candidateIds = candidates.map(c => c.proposalId);
        const failures = [];

        try {
            if (candidateIds.length > 0) {
                const results = await publishCandidatesBulk({ candidateIds });
                for (const r of results.filter(res => !res.success)) {
                    const match = candidates.find(c => c.proposalId === r.candidateId);
                    failures.push({
                        candidateId: r.candidateId,
                        title: match ? match.sourceArticleTitle : r.candidateId,
                        message: r.message
                    });
                }
            }

            const successCount = this.selectedCandidateIds.length - failures.length;
            if (failures.length > 0) {
                this.failedResults = failures;
                const variant = successCount === 0 ? 'error' : 'warning';
                const msg = failures.length <= 3
                    ? `${successCount} approved. Failed: ${failures.map(f => f.title).join(', ')}`
                    : `${successCount} approved, ${failures.length} failed — see details below.`;
                this.showToast('Bulk Approve', msg, variant);
            } else {
                this.showToast('Bulk Approve', `${successCount} candidate(s) approved.`, 'success');
            }
            this.selectedCandidateIds = [];
            await refreshApex(this.wiredInboxResult);
        } catch (e) {
            this.showToast('Error', this.reduceErrors(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleRejectSelected() {
        this.openRejectModal({ isBulk: true, targetId: null });
    }

    async openRejectModal({ isBulk, targetId }) {
        const result = await KbEnrichmentRejectModal.open({ size: 'small' });
        // Dismissing via header X / Escape / Cancel resolves to undefined —
        // treat that as a no-op cancel.
        if (!result || !result.reason) {
            return;
        }
        await this.performReject(isBulk, targetId, result.reason);
    }

    async performReject(isBulk, targetId, reason) {
        this.isLoading = true;
        this.failedResults = [];

        try {
            if (isBulk) {
                const results = await rejectCandidatesBulk({
                    candidateIds: this.selectedCandidateIds,
                    rejectionReason: reason
                });
                const failures = [];
                for (const r of results.filter(res => !res.success)) {
                    const match = this.inboxData.candidates.find(c => c.proposalId === r.candidateId);
                    failures.push({
                        candidateId: r.candidateId,
                        title: match ? match.sourceArticleTitle : r.candidateId,
                        message: r.message
                    });
                }
                const successCount = this.selectedCandidateIds.length - failures.length;
                if (failures.length > 0) {
                    this.failedResults = failures;
                    const variant = successCount === 0 ? 'error' : 'warning';
                    const msg = failures.length <= 3
                        ? `${successCount} rejected. Failed: ${failures.map(f => f.title).join(', ')}`
                        : `${successCount} rejected, ${failures.length} failed — see details below.`;
                    this.showToast('Bulk Reject', msg, variant);
                } else {
                    this.showToast('Bulk Reject', `${successCount} candidate(s) rejected.`, 'success');
                }
                this.selectedCandidateIds = [];
            } else {
                await rejectCandidate({
                    candidateId: targetId,
                    rejectionReason: reason
                });
                this.showToast('Success', 'Candidate rejected.', 'success');
            }
            await refreshApex(this.wiredInboxResult);
        } catch (e) {
            this.showToast('Error', this.reduceErrors(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    dismissErrors() {
        this.failedResults = [];
    }

    @api
    refresh() {
        return refreshApex(this.wiredInboxResult);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceErrors(errors) {
        if (!Array.isArray(errors)) errors = [errors];
        return errors.map(e => e.body?.message || e.message || String(e)).join(', ');
    }
}
