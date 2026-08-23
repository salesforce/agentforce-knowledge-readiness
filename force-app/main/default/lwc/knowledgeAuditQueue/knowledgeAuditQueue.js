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
import { LightningElement, wire, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
// the queue now sources through one status-aware wire so the same list can
// show Pending (default), Resolved, and Discarded rows via the two toggles.
import getCandidatesByStatus from '@salesforce/apex/DuplicateCandidateController.getCandidatesByStatus';
import reconcileActiveCandidates from '@salesforce/apex/DuplicateCandidateController.reconcileActiveCandidates';
import getArticleComparison from '@salesforce/apex/DuplicateCandidateController.getArticleComparison';
import KbResolveContradictionModal from 'c/kbResolveContradictionModal';
import KbClusterMergeModal from 'c/kbClusterMergeModal';
import KbAuditCompareModal from 'c/kbAuditCompareModal';
import KbDuplicateRejectModal from 'c/kbDuplicateRejectModal';
// reject + suppress consolidated into a single "not a duplicate" action.
import markNotADuplicate from '@salesforce/apex/DuplicateCandidateController.markNotADuplicate';
// Publishes a merged Golden Record draft and archives the losers in one tx —
// the reliable in-app path (native publish doesn't fire the archiving trigger).
import publishGoldenRecord from '@salesforce/apex/DuplicateCandidateController.publishGoldenRecord';

// status buckets, mirrored from Apex (KBAssessmentModels). Pending is the
// always-on baseline; the two toggles widen the set. RESOLVED = terminal merges;
// DISCARDED = the soft/legacy-permanent discards.
const RESOLVED_STATUSES = ['Resolved', 'Superseded'];

// per-row actions are STATUS-DEPENDENT (dynamic rowActions callback):
//  - Pending  → the full actionable set (Compare / Resolve / Not a Duplicate).
//  - Error    → a FAILED merge the user can RETRY: Compare + Resolve (re-runs the
//    merge; the controller includes Error in the retryable seed set). NOT "Not a
// Duplicate"— markNotADuplicate throws unless Status='Pending', so
// offering it on an Error row is a broken affordance.
//  - Resolved / Superseded → Compare (read-only view) + "View Golden Record"
//    when a merged draft exists (the affordance folded in from the retired
//    kbResolvedCandidates tab). No Resolve/Not-a-Duplicate — the pair is closed.
//  - Discarded → Compare only (inspect why it was discarded). No re-open action.
// "Force Re-evaluate" was RETIRED: it hard-deleted the candidate so the
// next run re-compared, but composite keys are version-id-based and we only
// compare Online versions — fixing an article already yields a fresh pair the
// next run compares, and auto-Supersedes the stale one. The action was
// vestigial. (DuplicateCandidateController.forceReEvaluate remains, unsurfaced.)
const ACTIONS_PENDING = [
    { label: 'Compare Articles', name: 'compare' },
    { label: 'Resolve', name: 'resolve' },
    { label: 'Not a Duplicate', name: 'not_a_duplicate' }
];
// review — an Error (failed-merge) row is retryable but NOT discardable:
// Resolve re-runs the merge; Compare inspects. "Not a Duplicate" is omitted
// because markNotADuplicate rejects any non-Pending status.
const ACTIONS_ERROR = [
    { label: 'Compare Articles', name: 'compare' },
    { label: 'Resolve', name: 'resolve' }
];
const ACTION_COMPARE = { label: 'Compare Articles', name: 'compare' };
const ACTION_VIEW_GOLDEN = { label: 'View Golden Record', name: 'view_golden' };
// Publishing the Golden Record from here (vs. natively) is what makes
// loser-archiving deterministic — see publishGoldenRecord in the controller.
const ACTION_PUBLISH_GOLDEN = { label: 'Publish Golden Record', name: 'publish_golden' };

// Columns for the lightning-datatable.: default `fitDomWidth` mode so
// columns fluidly fill the table width and stay user-resizable. Article A/B use
// the custom 'articleCell' type with allow-wrap so long titles wrap; the
// wrapping is driven by the cell's own CSS, not the column's wrapText. They
// carry a compact initialWidth so Reasoning (left unconstrained) absorbs the
// remaining width.: added a narrow Status column so resolved/discarded rows
// are legible once a toggle reveals them (on the default Pending-only view every
// row reads "Pending", harmless). The action column is appended in the
// constructor so its rowActions callback can be bound per-instance (dynamic
// per-row actions).
const COLUMNS = [
    {
        label: 'Article A',
        fieldName: 'Article_1_Title__c',
        type: 'articleCell',
        wrapText: true,
        initialWidth: 200,
        typeAttributes: { articleId: { fieldName: 'Knowledge_Article_1__c' } }
    },
    {
        label: 'Article B',
        fieldName: 'Article_2_Title__c',
        type: 'articleCell',
        wrapText: true,
        initialWidth: 200,
        typeAttributes: { articleId: { fieldName: 'Knowledge_Article_2__c' } }
    },
    { label: 'Type', fieldName: 'Flag_Type__c', fixedWidth: 120 },
 // Status shows a decorated label (statusLabel): a failed merge reads
    // "⚠ Failed" (red via statusCellClass) instead of the raw "Error", so the
    // outcome of an async merge is legible on the queue; other statuses pass through.
    {
        label: 'Status',
        fieldName: 'statusLabel',
        fixedWidth: 120,
        cellAttributes: { class: { fieldName: 'statusCellClass' } }
    },
    {
        label: 'Score',
        fieldName: 'scoreRounded',
        type: 'text',
        fixedWidth: 70,
        cellAttributes: { alignment: 'center' }
    },
 // Reasoning shows the merge-failure reason (Merge_Error__c) for an Error
    // row, else the AI dedup reasoning. Decorated into rowReasoning.
    { label: 'Reasoning', fieldName: 'rowReasoning', wrapText: true }
    // NOTE: the action column is appended in the constructor so its rowActions
 // callback can be bound to this instance (dynamic per-row actions,).
];

export default class KnowledgeAuditQueue extends NavigationMixin(LightningElement) {
    @api runId;
 // optional article-version narrowing. When the "Resolve in Action
    // Center" deep-link from the record-page Duplicates & Conflicts tab lands
    // here, this scopes the queue to the pair(s) touching that article version
    // in the selected run. Blank/undefined → full run list (default).
    @api articleVersionId;
 // when embedded in kbCandidateInbox the parent card already exposes a
    // refresh that delegates to this component's @api refresh(), so the queue's
    // own header refresh is a visible duplicate. Set hide-refresh in that
    // context. A standalone host leaves it false.
    @api hideRefresh = false;
 // a legacy `c__tab=resolved` deep-link now redirects
    // to this queue; the host sets this so the queue opens with "Show resolved"
    // already on (otherwise the redirect lands on the Pending-only view and the
    // resolved rows the link intended stay hidden). The setter only flips the
    // toggle ON — it never forces it off, so a later user toggle is preserved.
    @api
    get preselectResolved() {
        return this._preselectResolved;
    }
    set preselectResolved(value) {
        this._preselectResolved = value;
        if (value) {
            this.showResolved = true;
        }
    }
    _preselectResolved = false;
    // columns is assigned in the constructor (action column needs a bound
    // rowActions callback — see constructor).
    columns;
    candidates;
    errorMessage;
    wiredCandidatesResult;

 // the two status toggles. Default off → Pending-only (the actionable
    // set). The wire re-fires when these change (they're wire params).
    showResolved = false;
    showDiscarded = false;

    _reconcileScheduled = false;
    _mergeRefreshTimer;

    disconnectedCallback() {
 // cancel the post-merge delayed refresh if the queue tears down first.
        if (this._mergeRefreshTimer) {
            clearTimeout(this._mergeRefreshTimer);
            this._mergeRefreshTimer = undefined;
        }
    }

    constructor() {
        super();
        // Append the action column with a dynamic rowActions callback bound to
 // this instance, so each row's menu reflects its status. Building
        // it here (not in the module-level COLUMNS constant) is what lets the
        // callback close over `this`.
        this.columns = [
            ...COLUMNS,
            {
                type: 'action',
                typeAttributes: { rowActions: this.getRowActions.bind(this) }
            }
        ];
    }

    @wire(getCandidatesByStatus, {
        runId: '$runId',
        articleVersionId: '$articleVersionId',
        includeResolved: '$showResolved',
        includeDiscarded: '$showDiscarded'
    })
    wiredCandidates(result) {
        this.wiredCandidatesResult = result;
        if (result.data) {
            this.candidates = result.data;
            this.errorMessage = undefined;
 // the count badge tracks the ACTIONABLE (Pending) set only,
            // so it doesn't inflate when a toggle reveals resolved/discarded
            // rows. Count Pending rows here rather than result.data.length.
            const pendingCount = result.data.filter(
                (c) => c.Status__c === 'Pending'
            ).length;
            this.dispatchEvent(new CustomEvent('countchange', {
                detail: { count: pendingCount },
                bubbles: true, composed: true
            }));
 // Layer 3: lazy reconciliation — closes DCs whose source
            // article has been republished outside our flow. Cacheable wire
            // can't do DML, so we call the non-cacheable hook here and
            // refreshApex if anything was reconciled. Guard prevents loops.
            if (!this._reconcileScheduled && result.data.length > 0) {
                this._reconcileScheduled = true;
                reconcileActiveCandidates()
                    .then(closedIds => {
                        if (Array.isArray(closedIds) && closedIds.length > 0) {
                            return refreshApex(this.wiredCandidatesResult);
                        }
                        return null;
                    })
                    .catch(() => {
                        // Backstop layer; failure is non-fatal — the trigger
                        // covers live cases. Swallow the error silently.
                    })
                    .finally(() => {
                        this._reconcileScheduled = false;
                    });
            }
        } else if (result.error) {
            this.errorMessage = result.error.body?.message || 'Failed to load duplicate candidates.';
            this.candidates = undefined;
        }
    }

    @api
    refresh() {
        return refreshApex(this.wiredCandidatesResult);
    }

    get showRefresh() {
        return !this.hideRefresh;
    }

    get isLoading() {
        return !this.candidates && !this.errorMessage;
    }

 // the status toggles show once the wire has resolved without error,
    // even when the (Pending) list is empty — so a user can still widen the view
    // to inspect resolved/discarded history. Hidden only while loading or errored.
    get showStatusToggles() {
        return !this.isLoading && !this.hasError;
    }

    get hasCandidates() {
        return this.candidates && this.candidates.length > 0;
    }

    get isEmpty() {
        return this.candidates && this.candidates.length === 0;
    }

 // empty-state copy adapts to the toggles so it doesn't claim "all
    // reviewed" when the user has simply filtered to an empty resolved/discarded
    // slice.
    get emptyHeading() {
        return this.showResolved || this.showDiscarded
            ? 'Nothing to show for the selected filters'
            : 'No pending duplicate candidates';
    }

    get emptyBody() {
        return this.showResolved || this.showDiscarded
            ? 'No candidates match the current status toggles for this run.'
            : 'All detected duplicates have been reviewed.';
    }

    get hasError() {
        return !!this.errorMessage;
    }

    get candidateRows() {
        if (!this.candidates) return [];
        return this.candidates.map((c) => {
            const errored = c.Status__c === 'Error';
            return {
                ...c,
                scoreRounded: c.Confidence_Score__c != null ? Math.round(c.Confidence_Score__c) : '-',
 // a failed merge (Status='Error') reads "⚠ Failed" in red and
                // surfaces its Merge_Error__c reason in the Reasoning column; every
                // other status shows as-is with the AI dedup reasoning.
                statusLabel: errored ? '⚠ Failed' : c.Status__c,
                statusCellClass: errored ? 'slds-text-color_error slds-text-title_bold' : '',
                rowReasoning: errored && c.Merge_Error__c ? c.Merge_Error__c : c.AI_Reasoning__c
            };
        });
    }

 // datatable dynamic row-action provider. Returns the action set that
    // matches the row's status (see the ACTIONS_* constants). The datatable
    // calls this per row when its action menu opens.
    getRowActions(row, doneCallback) {
        const status = row.Status__c;
        let actions;
        if (status === 'Pending') {
            actions = [...ACTIONS_PENDING];
        } else if (status === 'Error') {
 // /— a failed merge is RETRYABLE (Resolve re-runs it; the
            // controller includes Error in the retryable seed set) but NOT
            // discardable: "Not a Duplicate" would throw (markNotADuplicate is
            // Pending-only), so the Error set is Compare + Resolve.
            actions = [...ACTIONS_ERROR];
        } else if (RESOLVED_STATUSES.includes(status)) {
            actions = [ACTION_COMPARE];
            if (row.Merged_Article__c) {
                actions.push(ACTION_VIEW_GOLDEN);
                // The merge only drafted the Golden Record; publishing it here
                // archives the source articles in the same transaction. Offered
                // on every resolved row with a merged draft — the endpoint is
                // idempotent (a no-op publish if it's already Online) so it also
                // repairs a merge that was published natively without archiving.
                actions.push(ACTION_PUBLISH_GOLDEN);
            }
        } else {
            // Discarded (or any other terminal) — inspect only.
            actions = [ACTION_COMPARE];
        }
        doneCallback(actions);
    }

    handleToggleResolved(event) {
        this.showResolved = event.target.checked;
    }

    handleToggleDiscarded(event) {
        this.showDiscarded = event.target.checked;
    }

    findCandidateById(candidateId) {
        return (this.candidates || []).find((c) => c.Id === candidateId);
    }

    handleRowAction(event) {
        const value = event.detail.action.name;
        // The datatable row carries the derived scoreRounded; resolve back to
        // the source candidate so downstream handlers see the original shape.
        const row = this.findCandidateById(event.detail.row.Id);
        if (!row) return;

        switch (value) {
            case 'compare':
                this.openComparison(row);
                break;
            case 'resolve':
                this.openResolveModal(row);
                break;
            case 'not_a_duplicate':
 // semantics (soft, reason-optional) via the extracted modal.
                this.openNotADuplicateModal(row.Id);
                break;
            case 'view_golden':
                this.openGoldenRecord(row);
                break;
            case 'publish_golden':
                this.handlePublishGolden(row);
                break;
            default:
                break;
        }
    }

 // golden-record "View Draft" affordance, lifted from the retired
    // kbResolvedCandidates tab. Navigates to the merged Knowledge__kav draft.
    openGoldenRecord(row) {
        if (!row.Merged_Article__c) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: row.Merged_Article__c,
                objectApiName: 'Knowledge__kav',
                actionName: 'view'
            }
        });
    }

    // Publishes the merged Golden Record draft and archives the source articles
    // in one server transaction, then refreshes so the row reflects the outcome.
    async handlePublishGolden(row) {
        if (!row.Merged_Article__c) return;
        try {
            await publishGoldenRecord({ candidateId: row.Id });
            this.showToast(
                'Success',
                'Golden Record published and the duplicate articles archived.',
                'success'
            );
            refreshApex(this.wiredCandidatesResult);
        } catch (error) {
            const message =
                error?.body?.message ||
                'Could not publish the Golden Record. Check your Knowledge permissions and try again.';
            this.showToast('Publish failed', message, 'error');
        }
    }

    async openResolveModal(row) {
        if (row.Flag_Type__c === 'Contradiction') {
            const result = await KbResolveContradictionModal.open({
                size: 'large',
                candidateId: row.Id,
                article1Id: row.Knowledge_Article_1__c,
                article2Id: row.Knowledge_Article_2__c,
                reasoning: row.AI_Reasoning__c
            });
            if (result) {
                const resolution = result.resolution;
 // the "Needs SME review" outcome was retired (it was a no-op ==
                // dismiss) — the modal no longer emits 'needs_sme'.
                let msg;
                if (resolution === 'both_valid_different_scope') {
                    msg = 'Both articles flagged to clarify their scope.';
                } else {
                    msg = 'Contradiction resolved. A recommendation has been created on the incorrect article.';
                }
                this.showToast('Success', msg, 'success');
                refreshApex(this.wiredCandidatesResult);
            }
        } else {
            const result = await KbClusterMergeModal.open({
                size: 'medium',
                seedCandidateId: row.Id,
                seedArticle1Title: row.Article_1_Title__c || '',
                seedArticle2Title: row.Article_2_Title__c || '',
                seedArticle1Number: '',
                seedArticle2Number: '',
                seedArticle1Id: row.Knowledge_Article_1__c || null,
                seedArticle2Id: row.Knowledge_Article_2__c || null
            });
            if (result) {
                const mode = result.mode || 'pair';
 // the merge runs in the background (LLM draft), so set
                // expectations + point the user where the outcome lands: success
                // shows under "Show resolved" (View Golden Record); a failure comes
                // back HERE as a "⚠ Failed" row with the reason (Status = Error).
                // A short delayed refresh surfaces a fast outcome without a manual
                // refresh (guarded + cleared in disconnectedCallback).
                const toastMsg = (mode === 'cluster'
                    ? 'Cluster merge started in the background. '
                    : 'Merge started in the background. ')
                    + 'When it finishes, the merged draft appears under "Show resolved". '
                    + 'If it can\'t complete, the pair stays here marked "Failed" with the reason.';
                this.showToast('Merge started', toastMsg, 'info');
                refreshApex(this.wiredCandidatesResult);
                if (this._mergeRefreshTimer) clearTimeout(this._mergeRefreshTimer);
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                this._mergeRefreshTimer = setTimeout(() => refreshApex(this.wiredCandidatesResult), 8000);
            }
        }
    }

    handleRefresh() {
        refreshApex(this.wiredCandidatesResult);
    }

    async openComparison(row) {
        let comparisonData;
        try {
            comparisonData = await getArticleComparison({
                articleVersionIdA: row.Knowledge_Article_1__c,
                articleVersionIdB: row.Knowledge_Article_2__c
            });
        } catch (error) {
            this.showToast('Error', error.body?.message || 'Failed to load comparison.', 'error');
            return;
        }

 // Compare is reachable from terminal
        // (Resolved/Superseded/discarded) rows as an "inspect only" view. Only a
        // Pending row may mutate the candidate, so open the modal read-only for
        // everything else (hides its Resolve / Not-a-Duplicate footer buttons)
        // and hard-guard the action handoff below in case the flag is ever
        // bypassed. Prevents a completed merge being silently un-resolved.
        const isPending = row.Status__c === 'Pending';
        const result = await KbAuditCompareModal.open({
            size: 'large',
            comparisonData,
            reasoning: row.AI_Reasoning__c,
            candidateId: row.Id,
            readOnly: !isPending
        });

        // Header X / Escape / Close resolve to undefined — treat as no-op.
        if (!result) {
            return;
        }
        // Defense-in-depth: never route a terminal row into a mutating flow.
        if (!isPending) {
            return;
        }
        if (result.action === 'resolve') {
            this.openResolveModal(row);
        } else if (result.action === 'reject') {
 // the comparison modal has no reason field, so hand off to the
 // "Not a Duplicate" reason modal instead of acting
            // with no reason.
            this.openNotADuplicateModal(row.Id);
        }
    }

 // (soft "Not a Duplicate") delivered through the extracted modal.
    // The reason is OPTIONAL — the pair re-surfaces on the next assessment
    // regardless — so we do NOT gate on it; we only treat a modal dismiss
    // (undefined result) as cancel. On confirm, markNotADuplicate with whatever
    // reason the user typed (may be blank).
    async openNotADuplicateModal(candidateId) {
        const result = await KbDuplicateRejectModal.open({ size: 'small' });
        // Header X / Escape / Cancel resolve to undefined — treat as cancel.
        if (!result) {
            return;
        }
        try {
            await markNotADuplicate({
                candidateId,
                reason: result.reason
            });
            this.showToast('Success', 'Marked as not a duplicate. It may re-surface on the next assessment.', 'success');
            refreshApex(this.wiredCandidatesResult);
        } catch (error) {
            this.showToast('Error', error.body?.message || 'Failed to update.', 'error');
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
