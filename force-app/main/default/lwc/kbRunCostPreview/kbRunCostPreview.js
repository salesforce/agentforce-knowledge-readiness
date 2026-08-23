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
import { LightningElement, api, track, wire } from 'lwc';
import estimateRunCost from '@salesforce/apex/KnowledgeAIGovernanceService.estimateRunCost';
import getQualityGateThresholds from '@salesforce/apex/KBAssessmentController.getQualityGateThresholds';

import TITLE from '@salesforce/label/c.KB_Cost_Title';
import SUBTITLE from '@salesforce/label/c.KB_Cost_Subtitle';
import SCOPE_SECTION from '@salesforce/label/c.KB_Cost_Section_Scope';
import LIMITS_SECTION from '@salesforce/label/c.KB_Cost_Section_Limits';
import ARTICLES from '@salesforce/label/c.KB_Cost_Label_Articles';
import CREDITS_NOTICE from '@salesforce/label/c.KB_Cost_Credits_Notice';
import WARN_TITLE from '@salesforce/label/c.KB_Cost_Warn_Title';
import WARN_BODY from '@salesforce/label/c.KB_Cost_Warn_Body';
import WARN_PLACEHOLDER from '@salesforce/label/c.KB_Cost_Warn_Placeholder';
import PROCEED from '@salesforce/label/c.KB_Cost_Action_Proceed';
import CANCEL from '@salesforce/label/c.KB_Cost_Action_Cancel';

const TYPED_CONFIRMATION_REQUIRED = 'RUN';

/**
 * Modal shown before submitting an assessment run. Computes a consumption
 * preview + current org-limit snapshot via KnowledgeAIGovernanceService.
 * The parent LWC decides when to open by setting `is-open`; on "Start run"
 * we dispatch `proceed`, on Cancel / backdrop click we dispatch `cancel`.
 *
 * Modal is deliberately stateless across opens: every `connectedCallback`
 * that finds isOpen=true re-calls estimateRunCost. Stale data (run submit
 * after a 30-minute wait) would be actively misleading — worth the extra
 * round-trip to be live.
 */
export default class KbRunCostPreview extends LightningElement {
    @api isOpen = false;
    @api articleCount = 0;
    @api selectedDimensions = [];
 // assessment name + description from the details step, shown at the
    // top of the preview modal so the user confirms what they're about to run.
    @api assessmentName;
    @api assessmentDescription;
 // variant B: render inline (no modal dialog chrome / backdrop / footer)
    // as a panel within the modal flow's preview step. The parent owns the
    // Back / Start Assessment buttons in that mode.
    @api embedded = false;
 // (c): the selected articles (id/number/title) for the confirmation list.
    // Empty in select-all-matching mode — we show a filter summary + count there.
    @api selectedRows = [];
    @api selectAllMatching = false;

    @track estimate;
    @track error;
    @track isLoading = false;
    @track typedConfirmation = '';
 // (b): live quality-gate thresholds for the Dup/Conflict explainer.
    @track thresholds;
    @track _articlePage = 1;

    titleLabel = TITLE;
    subtitleLabel = SUBTITLE;
    scopeSectionLabel = SCOPE_SECTION;
    limitsSectionLabel = LIMITS_SECTION;
    articlesLabel = ARTICLES;
    creditsNoticeLabel = CREDITS_NOTICE;
    warnTitleLabel = WARN_TITLE;
    warnBodyLabel = WARN_BODY;
    warnPlaceholderLabel = WARN_PLACEHOLDER;
    proceedLabel = PROCEED;
    cancelLabel = CANCEL;

    // Track the previous isOpen state so we only re-estimate on an open edge.
    // Without this, any parent re-render would re-fire the server call.
    _previousIsOpen = false;

 // (b) — live quality-gate thresholds (Min Completeness/Structure/Clarity).
    // cacheable wire: read-only, fine to cache across opens.
    @wire(getQualityGateThresholds)
    wiredThresholds({ data }) {
        if (data) {
            this.thresholds = data;
        }
    }

 // ── (c) — paged selected-article confirmation list ───────────────────
    ARTICLE_PAGE_SIZE = 25;

    get hasSelectedRows() {
        return !this.selectAllMatching && Array.isArray(this.selectedRows) && this.selectedRows.length > 0;
    }

    get isMatchingFilterMode() {
        return !!this.selectAllMatching;
    }

    get visibleArticleRows() {
        if (!this.hasSelectedRows) return [];
        return this.selectedRows.slice(0, this._articlePage * this.ARTICLE_PAGE_SIZE);
    }

    get hasMoreArticles() {
        return this.hasSelectedRows && this.visibleArticleRows.length < this.selectedRows.length;
    }

    get articleListCountLabel() {
        const shown = this.visibleArticleRows.length;
        const total = this.hasSelectedRows ? this.selectedRows.length : 0;
        return shown < total ? `Showing ${shown} of ${total}` : `${total} selected`;
    }

    handleShowMoreArticles() {
        this._articlePage += 1;
    }

 // ── (b) — Dup/Conflict quality-gate explainer ────────────────────────
    get gateWarningText() {
        const t = this.thresholds;
        // Live values when available; otherwise the documented default (60).
        const c = t && t.minCompleteness != null ? t.minCompleteness : 60;
        const s = t && t.minStructure != null ? t.minStructure : 60;
        const cl = t && t.minClarity != null ? t.minClarity : 60;
        return (
            `Duplication and Conflict analyses run only for articles that clear the quality gate — ` +
            `Completeness ≥ ${c}, Structure ≥ ${s}, and Clarity ≥ ${cl}. ` +
            `Articles below any of these thresholds are scored on the other dimensions but skipped for ` +
            `duplicate/conflict detection. Thresholds are configured in KB Setup.`
        );
    }

    renderedCallback() {
        if (this.isOpen && !this._previousIsOpen) {
            this._previousIsOpen = true;
            this._load();
        } else if (!this.isOpen && this._previousIsOpen) {
            // Modal closed; reset transient state so the next open starts fresh.
            this._previousIsOpen = false;
            this.estimate = null;
            this.error = null;
            this.typedConfirmation = '';
            this._articlePage = 1;
        }
    }

    async _load() {
        this.isLoading = true;
        this.error = null;
        this.estimate = null;
        try {
            const data = await estimateRunCost({
                articleCount: this.articleCount,
                selectedDimensions: this.selectedDimensions || []
            });
            this.estimate = data;
            // A fresh estimate resets the typed input — tell an embedded host
            // (kbAssessmentApp) whether this run needs the typed-RUN confirmation
            // so its own Start button can gate on it. In standalone/chrome mode
            // this is harmless (the host isn't listening; the Proceed button
            // uses isProceedDisabled directly).
            this.typedConfirmation = '';
            this._emitConfirmation();
        } catch (err) {
            this.error = this._extractError(err);
        } finally {
            this.isLoading = false;
        }
    }

    handleTypedChange(event) {
        this.typedConfirmation = event.target.value || '';
        this._emitConfirmation();
    }

    // The typed value satisfies the gate — case-insensitive ("run" / "Run" /
    // "RUN" all pass), trimmed. Single source of truth for both the standalone
    // Proceed button (isProceedDisabled) and the embedded confirmationchange.
    get _typedConfirmed() {
        return this.typedConfirmation.trim().toUpperCase() === TYPED_CONFIRMATION_REQUIRED;
    }

    // Report the large-run gate state to an embedded host. The standalone modal
    // gates its own Proceed button via isProceedDisabled; the embedded wizard
    // hides that button, so the host's Start button must gate on this instead.
    // `confirmed` = the gate is satisfied: no confirmation needed, or RUN typed.
    _emitConfirmation() {
        const needsConfirmation = !!(this.estimate && this.estimate.warn);
        const confirmed = !needsConfirmation || this._typedConfirmed;
        this.dispatchEvent(
            new CustomEvent('confirmationchange', { detail: { needsConfirmation, confirmed } })
        );
    }

    handleProceed() {
        if (this.isProceedDisabled) return;
        this.dispatchEvent(new CustomEvent('proceed', { detail: { estimate: this.estimate } }));
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    // ─── Getters ────────────────────────────────────────────────────────────

    get hasEstimate() {
        return !!this.estimate;
    }

 // ── Embedded vs modal presentation ──────────────────────
    // In embedded mode the modal chrome (dialog section, header, footer,
    // backdrop) is dropped so the content renders as an inline panel; the
    // parent owns the surrounding modal + action buttons.
    get showChrome() {
        return !this.embedded;
    }

    get sectionClass() {
        return this.embedded
            ? 'kb-embedded-preview'
            : 'slds-modal slds-fade-in-open slds-modal_medium';
    }

    get containerClass() {
        return this.embedded ? '' : 'slds-modal__container';
    }

    get contentClass() {
        return this.embedded ? '' : 'slds-modal__content slds-p-around_medium';
    }

    get dialogRole() {
        return this.embedded ? null : 'dialog';
    }

    get ariaModalValue() {
        return this.embedded ? null : 'true';
    }

    get hasAssessmentName() {
        return !!(this.assessmentName && this.assessmentName.trim());
    }

    get hasAssessmentDescription() {
        return !!(this.assessmentDescription && this.assessmentDescription.trim());
    }

    get limitRows() {
        if (!this.estimate?.orgLimits) return [];
        return this.estimate.orgLimits.map(r => ({
            ...r,
            usedFormatted: this._formatNum(r.usedValue),
            limitFormatted: this._formatNum(r.limitValue),
            projectedAddFormatted: this._formatNum(r.projectedAdd),
            variant: this._limitVariant(r.projectedUsedPct)
        }));
    }

    /**
     * Proceed is disabled when:
     *  - we're still loading
     *  - we have no estimate (error state)
     *  - warn mode is on AND typed confirmation is not exactly 'RUN'
     */
    get isProceedDisabled() {
        if (this.isLoading) return true;
        if (!this.estimate) return true;
        if (this.estimate.warn && !this._typedConfirmed) return true;
        return false;
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    _formatNum(n) {
        if (n === null || n === undefined) return '—';
        return Number(n).toLocaleString();
    }

    _limitVariant(pct) {
        if (pct >= 80) return 'expired';
        if (pct >= 60) return 'warning';
        return 'base-autocomplete';
    }

    _extractError(error) {
        if (typeof error === 'string') return error;
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return 'Unknown error';
    }
}
