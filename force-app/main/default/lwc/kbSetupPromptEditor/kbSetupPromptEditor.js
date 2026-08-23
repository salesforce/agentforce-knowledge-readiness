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
import checkPromptTemplates from '@salesforce/apex/KBSetupOrchestratorController.checkPromptTemplateStatus';
import getPromptTemplateLinks from '@salesforce/apex/KBSetupOrchestratorController.getPromptTemplateLinks';
import { openInNewTab } from 'c/kbNav';

// GenAI Prompt Templates surfaced on the Advanced Scoring Config screen,
// grouped into tabs so the list is no longer a flat, misleading subset.
//
//  - "Scoring" → the three LLM-scored readiness dimensions an admin tunes to
//    change *scoring* behaviour (Completeness, Structure, Clarity).
//  - "Other"   → reserved for pipeline templates that are NOT a single readiness
//    dimension but are still worth surfacing here. Currently empty; the tab is
//    hidden (see `hasOtherTemplates`) until such a template is added, so admins
//    don't mistake non-scoring templates for scoring dimensions.
//
// Freshness is deterministic. Duplication/Conflict come from the 5-tier pipeline
// (no prompt). The dead `Generic_Evaluator` template was dropped from this list
// in, and `Evaluate_Chunk_Self_Containment` in /— both had zero
// production callers.
const SCORING_TEMPLATES = [
    {
        name: 'Evaluate_Completeness',
        description: 'Per-field substance and summary breadcrumb evaluation for the Completeness dimension.',
        dimension: 'Completeness'
    },
    {
        name: 'Evaluate_Structure',
        description: 'Evaluates structural coherence and topic focus for the Structure dimension.',
        dimension: 'Structure'
    },
    {
        name: 'Evaluate_Clarity',
        description: 'Evaluates semantic clarity, jargon, and language complexity for the Clarity dimension.',
        dimension: 'Clarity'
    }
];

// No non-dimension pipeline templates are surfaced today. Kept as an explicit
// (empty) list so the Scoring/Other tab grouping stays in place for future use.
const OTHER_TEMPLATES = [];

export default class KbSetupPromptEditor extends LightningElement {
    @track scoringStatuses = [];
    @track otherStatuses = [];
    @track isLoading = true;

    connectedCallback() {
        this.loadStatuses();
    }

    get hasOtherTemplates() {
        return this.otherStatuses.length > 0;
    }

    async loadStatuses() {
        this.isLoading = true;
        try {
            const [deployedNames, links] = await Promise.all([
                checkPromptTemplates(),
                getPromptTemplateLinks()
            ]);
            const deployedSet = new Set(deployedNames || []);
            const linkMap = new Map();
            (links || []).forEach((l) => linkMap.set(l.name, l));

            this.scoringStatuses = SCORING_TEMPLATES.map((t) => this._decorate(t, deployedSet, linkMap));
            this.otherStatuses = OTHER_TEMPLATES.map((t) => this._decorate(t, deployedSet, linkMap));
        } catch (error) {
            this.scoringStatuses = SCORING_TEMPLATES.map((t) => this._decorateFailed(t));
            this.otherStatuses = OTHER_TEMPLATES.map((t) => this._decorateFailed(t));
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error',
                message: 'Could not load prompt templates: ' + this._err(error),
                variant: 'error'
            }));
        } finally {
            this.isLoading = false;
        }
    }

    _decorate(t, deployedSet, linkMap) {
        const link = linkMap.get(t.name);
        let editUrl = '';
        if (link && link.templateId) {
            editUrl = this.buildPromptBuilderUrl(link.templateId);
        }
        return {
            ...t,
            isDeployed: deployedSet.has(t.name),
            editUrl,
            hasEditUrl: !!editUrl,
            noEditUrl: !editUrl
        };
    }

    _decorateFailed(t) {
        return {
            ...t,
            isDeployed: false,
            editUrl: '',
            hasEditUrl: false,
            noEditUrl: true
        };
    }

    /**
     * Builds the Lightning Setup deep-link that opens a specific GenAI Prompt
     * Template (id prefix `0hf`) in Prompt Builder.
     *
     * The setup node is `EinsteinGPTPromptTemplate` — the registered Setup node
     * for Prompt Builder. The previous `EinsteinPromptStudio/<id>/edit` path is
     * not a real Setup node, so the button landed on a "page doesn't exist in
 * Setup" error. Setup pages that host a record view deep-link via the
     * `address` query param (URL-encoded `/<recordId>`), so we pass the template
     * id there rather than as a path segment.
     *
     * Intentionally drops the old `c__versionId` routing: this Setup node opens
     * the template's active version, which is what an admin tuning prompts wants.
     * Deep-linking a specific draft version isn't supported by this node.
     */
    buildPromptBuilderUrl(templateId) {
        return `/lightning/setup/EinsteinGPTPromptTemplate/page?address=${encodeURIComponent('/' + templateId)}`;
    }

    handleOpenPromptBuilder(event) {
        const templateName = event.currentTarget.dataset.name;
        const template = this.scoringStatuses
            .concat(this.otherStatuses)
            .find((t) => t.name === templateName);
        if (template && template.editUrl) {
 // native-anchor helper, not window.open — LWS blocks
            // window.open on a same-origin URL but permits a browser-driven click.
            // (The helper sets rel="noopener noreferrer" to block reverse-tabnabbing.)
            openInNewTab(template.editUrl);
        }
    }

    handleRefresh() {
        this.loadStatuses();
    }

    _err(error) {
        if (typeof error === 'string') return error;
        return error?.body?.message || error?.message || 'Unknown error';
    }
}
