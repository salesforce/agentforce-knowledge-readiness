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
import DIM_COMPLETENESS from '@salesforce/label/c.KB_Helptext_Dim_Completeness';
import DIM_STRUCTURE from '@salesforce/label/c.KB_Helptext_Dim_Structure';
import DIM_CLARITY from '@salesforce/label/c.KB_Helptext_Dim_Clarity';
import DIM_FRESHNESS from '@salesforce/label/c.KB_Helptext_Dim_Freshness';
import DIM_DUPLICATION from '@salesforce/label/c.KB_Helptext_Dim_Duplication';
import DIM_CONFLICT from '@salesforce/label/c.KB_Helptext_Dim_Conflict';

// Stable display order for the 6 registered dimensions, mirroring
// KB_Scoring_Dimension__mdt.Display_Order__c. Keeping a static list here
// (instead of pulling from Apex) avoids a roundtrip per score card; the values
// are deploy-time stable. If a 7th dim is added this list needs one more entry.
// Weight is intentionally not shown — it read as a failing score next to
// the actual dimension score.
const DIMENSION_DISPLAY = [
    { key: 'Completeness', label: 'Completeness', help: DIM_COMPLETENESS },
    { key: 'Structure',    label: 'Structure',    help: DIM_STRUCTURE },
    { key: 'Clarity',      label: 'Language Clarity', help: DIM_CLARITY },
    { key: 'Freshness',    label: 'Freshness',    help: DIM_FRESHNESS },
    { key: 'Duplication',  label: 'Duplication',  help: DIM_DUPLICATION },
    { key: 'Conflict',     label: 'Conflict',     help: DIM_CONFLICT }
];

export default class KbArticleScoreCard extends LightningElement {
    @api articleResult;
    @track isExpanded = false;

 // the assessed article is unreachable (deleted, or the user lost
    // access via data category / FLS). Treat a missing flag as reachable so
    // older payloads / other callers keep today's behaviour.
    get isReachable() {
        return this.articleResult?.isReachable !== false;
    }

    get isUnreachable() {
        return !this.isReachable;
    }

    get cardClass() {
        let baseClass = 'slds-box article-card';
        if (this.articleResult.readinessStatus === 'Ready') {
            baseClass += ' card-ready';
        } else if (this.articleResult.readinessStatus === 'Needs Work') {
            baseClass += ' card-needs-work';
        } else {
            baseClass += ' card-not-ready';
        }
 // grey out the row when the article can't be opened; the snapshot
        // score/title still render so the row stays informative.
        if (this.isUnreachable) {
            baseClass += ' card-unreachable';
        }
        return baseClass;
    }

    get expandIcon() {
        return this.isExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

 // string-typed mirror of isExpanded for the header's aria-expanded
    // attribute, so assistive tech announces collapsed/expanded state.
    get isExpandedStr() {
        return this.isExpanded ? 'true' : 'false';
    }

 // accessible name for the role="button" card header.
    get expandLabel() {
        const title = this.articleResult ? this.articleResult.articleTitle : 'article';
        return `${this.isExpanded ? 'Collapse' : 'Expand'} details for ${title}`;
    }

    get displayScore() {
        return Math.round(this.articleResult.overallScore || 0);
    }

    get articleUrl() {
        if (this.articleResult?.articleId) {
            return `/lightning/r/${this.articleResult.articleId}/view`;
        }
        return '#';
    }

    handleLinkClick(event) {
        event.stopPropagation();
    }

    // "View Actions" jumps to this article's issues in the Action Center. The
    // ONLY thing that disables it is reachability: can the running user open
    // this article version at all (not deleted, and visible to them)? If yes,
    // the deep-link is always useful.
    //
 // (revised) — we deliberately do NOT gate on open-issue presence. The
 // earlier gate ("disable when no Open/Error rec") was wrong going
    // forward: the Action Center is moving toward showing BOTH open and closed
    // recommendations behind a toggle, so "has an open issue right now" is not
    // a discriminant for whether the deep-link is worth following. An article
    // with only resolved recs still has a meaningful Action-Center view. The
    // one genuine dead-end is an article the user can't open — that's the gate.
    get viewActionsDisabled() {
        return this.isUnreachable;
    }

    get viewActionsTooltip() {
        return this.isUnreachable
            ? 'This article can no longer be opened — it was deleted, or you don’t have access to it.'
            : 'View this article’s issues in the Action Center';
    }

    handleViewActions(event) {
        // Stop the header's expand/collapse toggle from also firing.
        event.stopPropagation();
        // Defensive: the button is disabled when unreachable, but guard the
        // handler too so a programmatic dispatch can't deep-link to a version
        // the user can't open.
        if (this.isUnreachable) {
            return;
        }
        this.dispatchEvent(
            new CustomEvent('viewarticleactions', {
                detail: { articleId: this.articleResult?.articleId }
            })
        );
    }

    get statusLabel() {
        return this.articleResult.readinessStatus;
    }

    get statusBadgeClass() {
        const status = this.articleResult.readinessStatus;
        if (status === 'Ready') return 'status-badge badge-ready';
        if (status === 'Needs Work') return 'status-badge badge-needs-work';
        return 'status-badge badge-not-ready';
    }

    get hasSkipReason() {
        const reason = this.articleResult?.pipelineSkipReason;
        return typeof reason === 'string' && reason.trim().length > 0;
    }

 // Pipeline_Skip_Reason__c now carries two kinds of skip: the
    // original dedup quality-gate exclusion, and (on a rerun) "no current
    // published version". Pick the badge label that matches the reason text so
    // it doesn't mislabel a missing-version skip as a dedup exclusion.
    get isNoPublishedVersionSkip() {
        const reason = this.articleResult?.pipelineSkipReason || '';
        return reason.indexOf('No current published version') === 0;
    }

    get skipReasonLabel() {
        return this.isNoPublishedVersionSkip ? 'Skipped — no published version' : 'Excluded from dedup';
    }

    get skipReasonTitle() {
        if (!this.hasSkipReason) {
            return '';
        }
        const prefix = this.isNoPublishedVersionSkip ? 'Skipped' : 'Excluded from dedup';
        return `${prefix} — ${this.articleResult.pipelineSkipReason}`;
    }

    /**
 * Per-dimension score view for template iteration.
     * Reads from articleResult.scoresByDim (map keyed by DeveloperName). Dims
     * not in the map (or null in the map) render as "N/A" with scored=false.
     */
    get dimensions() {
        const map = this.articleResult?.scoresByDim || {};
        return DIMENSION_DISPLAY.map((d) => {
            const dim = map[d.key];
            const scored = this.isScored(dim);
            const numeric = scored ? Math.round(dim.score) : 0;
            return {
                key: d.key,
                label: d.label,
                help: d.help,
                score: scored ? numeric : 'N/A',
                scored,
                progress: numeric,
                variant: this.getVariant(numeric)
            };
        });
    }

    isScored(dimensionScore) {
        return dimensionScore && dimensionScore.score !== null && dimensionScore.score !== undefined;
    }

    getVariant(numericScore) {
        if (numericScore >= 80) return 'success';
        if (numericScore >= 50) return 'warning';
        return 'error';
    }

    toggleExpand() {
        this.isExpanded = !this.isExpanded;
    }

 // the header is a role="button" (see template), so Enter/Space must
    // toggle it like a native button. Space is prevented from scrolling the page.
    handleHeaderKeydown(event) {
 // the header hosts interactive children (the article link and the
        // "View Actions" button). Keydown events bubble, so an Enter/Space on a
        // focused child would otherwise reach here and preventDefault() would
        // cancel that child's own activation. Only act when the header itself is
        // the key target.
        if (event.target !== event.currentTarget) {
            return;
        }
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.toggleExpand();
        }
    }
}
