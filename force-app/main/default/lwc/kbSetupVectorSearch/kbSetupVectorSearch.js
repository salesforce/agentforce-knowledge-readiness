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
import getAvailableSearchIndexes from '@salesforce/apex/KBSetupOrchestratorController.getAvailableSearchIndexes';

export default class KbSetupVectorSearch extends LightningElement {
    _config = {};
    @track _discoveredIndexes = [];
    @track _indexesLoading = true;
    @track _indexesError;

    @wire(getAvailableSearchIndexes)
    wiredIndexes({ data, error }) {
        if (data === undefined && error === undefined) return;
        this._indexesLoading = false;
        if (data) {
            this._discoveredIndexes = data;
        } else if (error) {
            this._indexesError = error?.body?.message || 'Could not load search indexes.';
        }
    }

    @api
    get config() { return this._config; }
    set config(value) {
        this._config = value ? { ...value } : {};
    }

 // the redesigned wizard moves the Max Results tuning knob out of the
    // mandatory search-index section and into its Advanced accordion, so it hides
    // the inline field here. Defaults false → the legacy admin wizard keeps Max
    // Results inline. maxResults itself still lives on the shared config either
    // way; this only controls whether THIS component renders the input.
    @api hideMaxResults = false;
    get showMaxResults() { return !this.hideMaxResults; }

 // when the redesigned wizard embeds this component under its own
    // "Search index" section heading, the component's internal "Search Index
    // Configuration" title + intro are a redundant second heading directly
    // beneath the section title (the information-hierarchy defect the reviewer
    // flagged). `embedded` suppresses them so the host owns the section header.
    // Defaults false → the standalone legacy admin wizard keeps its own title.
    @api embedded = false;
    get showComponentTitle() { return !this.embedded; }

    get searchIndexName() { return this._config.searchIndexName || ''; }
    get maxResults() { return this._config.maxResults; }
    get dataSpaceName() { return this._config.dataSpaceName || ''; }
    get isActive(){ return this._config.isActive !== false; }
    get isVectorDisabled() { return !this.isActive; }
    get showFallbackNotice() { return !this.isActive; }

 // whether the configured search index is an Agentforce Data Library.
    // An ADL ingests every article version (Published, Draft, Archived), so the
    // dedup query must filter to currently-published content (handled in Apex).
    // Defaults to false (treated as a custom Data Cloud index).
    get isAdl() { return this._config.isAdl === true; }

    // ADL=no path: the admin must acknowledge they scoped their custom index to
    // published articles only (there's no auto-filter on this branch). Only
    // relevant when vector search is active and the index is NOT an ADL.
    //
    // Intentionally transient (not persisted): unlike isAdl, this ack lives only
    // in the in-memory config and is used purely as a per-session validate() gate.
    // On wizard reload / Previous-nav it resets to unchecked, so the admin re-ticks
    // it to advance past this step again. That's deliberate for alpha — the ack is a
    // "confirm you've done this now" affordance, not a stored setting. (If it should
    // persist, add it to the KBSetupWizardController save/load alongside isAdl.)
    get isCustomIndex() { return this.isActive && !this.isAdl; }
    get customIndexPublishedAck() { return this._config.customIndexPublishedAck === true; }

    get indexComboOptions() {
        const options = this._discoveredIndexes.map(idx => ({
            label: idx.label,
            value: idx.value
        }));
        // If current value is not in discovered list, add it so the combobox shows it correctly
        const current = this.searchIndexName;
        if (current && !options.some(o => o.value === current)) {
            options.push({ label: current + ' (custom)', value: current });
        }
        return options;
    }

    get selectedIndexComboValue() {
        return this.searchIndexName || '';
    }

    get isIndexesLoading() { return this._indexesLoading; }
    get hasIndexesError() { return !!this._indexesError; }
    get hasNoIndexes() { return !this._indexesLoading && !this._indexesError && this._discoveredIndexes.length === 0; }
    get hasIndexes() { return this._discoveredIndexes.length > 0; }

    handleChange(event) {
        const field = event.target.dataset.field;
        let value;
        if (event.target.type === 'number') {
            value = parseFloat(event.target.value);
        } else if (event.target.type === 'toggle' || event.target.type === 'checkbox') {
            value = event.target.checked;
        } else {
            value = event.target.value;
        }

        const next = { ...this._config, [field]: value };

        // The toggle is the single source of truth for which Tier 2 implementation
        // is in use. Keep implementationClass in lockstep so the orchestrator's
        // validation (which gates on impl class) doesn't reject saves the toggle UI
        // thinks are valid. Mirrors KBSetupWizardController.saveVectorSearchConfig.
        if (field === 'isActive') {
            next.implementationClass = value
                ? 'ConnectApiVectorSearchService'
                : 'Tier1SOQLFallbackService';
        }

        this._config = next;
        this.dispatchEvent(new CustomEvent('configchange', { detail: this._config }));
    }

    handleIndexComboChange(event) {
        this._config = { ...this._config, searchIndexName: event.detail.value };
        this.dispatchEvent(new CustomEvent('configchange', { detail: this._config }));
    }

    handleDisableVectorSearch() {
        this._config = {
            ...this._config,
            isActive: false,
            implementationClass: 'Tier1SOQLFallbackService'
        };
        this.dispatchEvent(new CustomEvent('configchange', { detail: this._config }));
    }

    /**
     * Public validity hook called by the wizard parent before save. When the
     * vector-search toggle is on, the search index is mandatory. Surfaces the
     * inline combobox error (via reportValidity) and returns false so the
     * parent can short-circuit the save with a toast. When the toggle is off
     * or no combobox is rendered (loading / no-indexes branches), validation
     * is a no-op success.
     */
    @api
    validate() {
        if (!this.isActive) return true;

 // custom (non-ADL) index: the admin must confirm they scoped the
        // index to published articles only. No auto publish-status filter runs on
        // this branch, so an unacknowledged custom index is a config gap.
        if (this.isCustomIndex && !this.customIndexPublishedAck) {
            const ack = this.template.querySelector('lightning-input.custom-index-ack');
            if (ack) {
                ack.reportValidity();
            }
            return false;
        }

        const combobox = this.template.querySelector('lightning-combobox.search-index-combobox');
        if (!combobox) return true;
        return combobox.reportValidity();
    }
}
