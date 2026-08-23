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
import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import isSetupCompleted from '@salesforce/apex/KBSetupOrchestratorController.isSetupCompleted';
// tab badges share the SAME Apex methods the sub-tabs render from,
// scoped to the selected run. Using the global counters here meant the badge
// never agreed with the list inside the tab (different run filter, different
// status whitelist, different cap/dedup), and switched values the moment the
// user opened the Issues sub-tab. Both wires share LDS cache with the child
// since the args are identical, so this isn't a duplicate query.
import getActiveCandidates from '@salesforce/apex/DuplicateCandidateController.getActiveCandidates';
import getEnrichmentInbox from '@salesforce/apex/KBEnrichmentController.getEnrichmentInbox';
import getImprovementsInbox from '@salesforce/apex/KBEnrichmentController.getImprovementsInbox';
import hasAnyRuns from '@salesforce/apex/KBAssessmentController.hasAnyRuns';
import EMPTY_INBOX_TITLE from '@salesforce/label/c.KB_Empty_Inbox_NoRuns_Title';
import EMPTY_INBOX_BODY from '@salesforce/label/c.KB_Empty_Inbox_NoRuns_Body';
import EMPTY_INBOX_CTA from '@salesforce/label/c.KB_Empty_Action_Run_Assessment';

export default class KbCandidateInbox extends NavigationMixin(LightningElement) {
    @track _setupCompleted = null;
    @track _hasRuns = null;
    @track duplicateCount = 0;
    @track enrichmentCount = 0;
    @track improvementsCount = 0;
    @track selectedRunId = null;

 // Deep-link state from sidebar's "Resolve in Action Center" flow.
    // The sidebar's `c-knowledge-consistency-checker` navigates here with
    // `c__articleId` + `c__recId` query params; we forward them as @api props
    // to the Improvements Inbox so it can scroll/highlight the target row.
    @track _deepLinkArticleId = null;
    @track _deepLinkRecId = null;
    @track _deepLinkResolved = false;
    @track _activeTabValue = null;

    emptyInboxTitle = EMPTY_INBOX_TITLE;
    emptyInboxBody = EMPTY_INBOX_BODY;
    emptyInboxCta = EMPTY_INBOX_CTA;

    @wire(CurrentPageReference)
    pageRefChanged(pageRef) {
        this.checkSetupStatus();
        // c__-prefixed query params are the only ones Lightning navigation
        // exposes on `pageRef.state` (an unprefixed `?articleId=` is dropped).
        const state = pageRef?.state || {};
 // Sidebar's "Resolve in Action Center" flow: jump to the
        // right tab and target the article.
        //  - AI-fixable / Freshness recs → Improvements tab, highlight the rec.
        //  - Duplication / Conflict findings (c__tab='duplicates') → Duplicates &
        //    Conflicts tab, scoped to the article version so the queue lands on
 // the exact pair(s), not the whole run. The Conflict analysis
        //    row has no candidate FK, so the article version is how we select the
        //    candidate.
 // the standalone "Resolved Duplicates" tab was folded into the
        //    unified Duplicates queue, so a legacy c__tab='resolved' deep-link is
        //    redirected here to 'duplicates' (the queue's "Show resolved" toggle
        //    surfaces the resolved rows).
        if (state.c__articleId) {
            this._deepLinkArticleId = state.c__articleId;
            this._deepLinkRecId = state.c__recId || null;
            const dupTabValues = new Set(['duplicates', 'resolved']);
            this._activeTabValue = dupTabValues.has(state.c__tab) ? 'duplicates' : 'improvements';
 // a legacy c__tab='resolved' link intended the
            // resolved slice, so pre-enable the queue's "Show resolved" toggle;
            // otherwise the redirect lands on the Pending-only view and hides
            // the very rows the link pointed at.
            this._deepLinkResolved = state.c__tab === 'resolved';
        } else {
            this._deepLinkArticleId = null;
            this._deepLinkRecId = null;
            this._deepLinkResolved = false;
        }
 // run card's "View Actions": pre-select that run in the
        // per-assessment filter so every tab opens scoped to it. Same state
        // the dropdown sets (selectedRunId), so the tabs react for free;
        // absent c__runId we leave the default "All assessments".
        if (state.c__runId) {
            this.selectedRunId = state.c__runId;
        }
    }

    async checkSetupStatus() {
        try { this._setupCompleted = !!(await isSetupCompleted()); }
        catch { this._setupCompleted = true; }
    }

    get isSetupComplete() { return this._setupCompleted === true; }
    get isLoading() { return this._setupCompleted === null; }

 // only narrow the Duplicates queue by article when the deep-link
    // actually targeted that tab. A plain Improvements deep-link (or a normal
    // visit) must leave the queue showing the full run list.
    get duplicatesDeepLinkArticleId() {
        return this._activeTabValue === 'duplicates' ? this._deepLinkArticleId : null;
    }

 // only pre-enable "Show resolved" when a legacy
    // c__tab='resolved' link actually routed to the Duplicates tab.
    get duplicatesPreselectResolved() {
        return this._activeTabValue === 'duplicates' && this._deepLinkResolved;
    }

    handleGoToSetup() {
        this[NavigationMixin.Navigate]({ type: 'standard__navItemPage', attributes: { apiName: 'KB_Assessment_Setup' } });
    }

    @wire(hasAnyRuns)
    wiredRuns({ data }) {
        if (data !== undefined) {
            this._hasRuns = !!data;
        }
    }

    get showNoRunsZeroState() {
        return this._hasRuns === false;
    }

 // the searchable run filter (c-kb-run-filter) owns the run list +
    // labels now; we just take the chosen runId and let the $selectedRunId
    // sub-tab wires re-scope. runId is null for "All assessments".
    handleRunSelect(event) {
        this.selectedRunId = event.detail.runId;
    }

    handleNewAssessment() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Assessment_Console' }
        });
    }

    // The sub-tabs are lazy-mounted: until the user clicks one, its inner wire
    // never fires and it can't tell us its count via oncountchange. The wires
    // below run from page-load so the badges agree with what the tab will show
    // before it's opened, and they re-fire whenever selectedRunId changes
    // (dropdown, or c__runId from "View Actions"). Once a sub-tab is open, its
    // own count event takes over via the handlers below.
    @wire(getActiveCandidates, { runId: '$selectedRunId' })
    wiredDuplicateCount({ data }) {
        if (data !== undefined) {
            this.duplicateCount = data.length;
        }
    }

    // Keep the whole wire result so a single-article fix can refreshApex it (the
    // badge shares an LDS cache key with the enrichment child's identical wire,
    // so this one refresh updates both — even if the drafts tab was never opened).
    _wiredEnrichmentCount;

    @wire(getEnrichmentInbox, { limitSize: 200, runId: '$selectedRunId' })
    wiredEnrichmentCount(result) {
        this._wiredEnrichmentCount = result;
        if (result.data !== undefined) {
            this.enrichmentCount = result.data.pendingCount || 0;
        }
    }

    // The Issues badge is the count of recommendations across the article-capped
    // inbox (INBOX_ARTICLE_LIMIT = 50 in KBEnrichmentController). Intentional:
    // badge == list. Don't "fix" this back to a global count — that's the bug
 // fixed.
    @wire(getImprovementsInbox, { runId: '$selectedRunId' })
    wiredImprovementsCount({ data }) {
        if (data !== undefined) {
            this.improvementsCount = data.reduce(
                (sum, g) => sum + (g.recommendations?.length || 0),
                0
            );
        }
    }

    get duplicateTabLabel() {
        return `Duplicates (${this.duplicateCount})`;
    }

    get enrichmentTabLabel() {
        return `Suggested Article Drafts (${this.enrichmentCount})`;
    }

    get improvementsTabLabel() {
        return `Issues (${this.improvementsCount})`;
    }

    handleDuplicateCountChange(event) {
        this.duplicateCount = event.detail.count || 0;
    }

    handleEnrichmentCountChange(event) {
        this.enrichmentCount = event.detail.count || 0;
    }

    handleImprovementsCountChange(event) {
        this.improvementsCount = event.detail.count || 0;
    }

    // A single-article "Fix with AI" in the Improvements tab runs synchronously, so
    // the draft already exists when it resolves. Refresh the enrichment count wire
    // (updates the "Suggested Article Drafts (N)" badge) and, if that tab is mounted,
    // its list — so the new draft appears without the user hitting Refresh. No
    // tab-jump: the user may be fixing articles one at a time and shouldn't be
    // yanked off the Improvements list. (Bulk fix keeps its own View Drafts flow.)
    handleFixApplied() {
        if (this._wiredEnrichmentCount) {
            refreshApex(this._wiredEnrichmentCount);
        }
        const enrichmentInbox = this.template.querySelector('c-kb-enrichment-inbox');
        if (enrichmentInbox && typeof enrichmentInbox.refresh === 'function') {
            enrichmentInbox.refresh();
        }
    }

 // after a bulk AI-fix in the Improvements tab, jump to the Suggested
    // Drafts (Enrichment) tab so the user lands on the drafts they just created.
    // Both tabs already share selectedRunId, so the drafts are run-scoped without
    // any extra plumbing; refresh the enrichment child so brand-new drafts show.
    handleViewDrafts() {
        this._activeTabValue = 'enrichment';
        const enrichmentInbox = this.template.querySelector('c-kb-enrichment-inbox');
        if (enrichmentInbox && typeof enrichmentInbox.refresh === 'function') {
            enrichmentInbox.refresh();
        }
    }

    handleRefresh() {
        const auditQueue = this.template.querySelector('c-knowledge-audit-queue');
        if (auditQueue && typeof auditQueue.refresh === 'function') {
            auditQueue.refresh();
        }
        const enrichmentInbox = this.template.querySelector('c-kb-enrichment-inbox');
        if (enrichmentInbox && typeof enrichmentInbox.refresh === 'function') {
            enrichmentInbox.refresh();
        }
    }
}