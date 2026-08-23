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

const DEFAULTS = {
    completeness: 0.30,
    structure: 0.20,
    clarity: 0.10,
    freshness: 0.10,
    duplication: 0.15,
    conflict: 0.15
};

const DIMENSION_LABELS = {
    completeness: 'Completeness',
    structure: 'Structure',
    clarity: 'Clarity',
    freshness: 'Freshness',
    duplication: 'Duplication',
    conflict: 'Conflict'
};

const DIMENSION_DESCRIPTIONS = {
    completeness: 'Whether each field gives a substantive, citable answer (values, codes, timeframes) instead of vague or redirecting text, and whether the title and summary help an agent find and use the article.',
    structure: 'Whether the article is organised so it splits into clean, self-contained passages for AI retrieval — clear headings and lists, no orphaned "see above" cross-references, a single focused topic, and formatting suited to its length.',
    clarity: 'Whether the wording matches how customers ask — pronouns with clear referents, acronyms and jargon explained (including your configured customer-term preferences), sentences whose actor and action are easy to follow, and no passages that contradict each other within the article.',
    freshness: 'How recently the article was reviewed or updated.',
    duplication: 'Similarity overlap with other articles. Requires the deduplication pipeline to have run.',
    conflict: 'Factual contradictions with other articles. Requires the deduplication pipeline to have run.'
};

export default class KbSetupScoreWeights extends LightningElement {
    @api
    get weights() {
        return this._weights;
    }
    set weights(value) {
        // Apex `DimensionRegistry` emits CMDT DeveloperNames (capitalized:
        // 'Completeness', 'Structure', ...). This component keeps lowercase
        // keys internally so template bindings and CSS stay stable. Normalize
        // incoming keys to lowercase and drop any key not in DEFAULTS.
        if (!value) {
            this._weights = { ...DEFAULTS };
            return;
        }
        const next = { ...DEFAULTS };
        Object.keys(value).forEach((k) => {
            const lc = k.toLowerCase();
            if (lc in DEFAULTS) {
                const num = Number(value[k]);
                if (!Number.isNaN(num)) next[lc] = num;
            }
        });
        this._weights = next;
    }

    @track _weights = { ...DEFAULTS };

    get dimensionList() {
        return Object.keys(DIMENSION_LABELS).map(key => ({
            key,
            label: DIMENSION_LABELS[key],
            description: DIMENSION_DESCRIPTIONS[key],
            value: this._weights[key] || 0,
            percentage: Math.round((this._weights[key] || 0) * 100)
        }));
    }

    get totalWeight() {
        return Object.keys(DIMENSION_LABELS).reduce((sum, key) => {
            return sum + (this._weights[key] || 0);
        }, 0);
    }

    get totalPercentage() {
        return Math.round(this.totalWeight * 100);
    }

    get isValidTotal() {
        return Math.abs(this.totalWeight - 1.0) <= 0.01;
    }

    get totalClass() {
        return this.isValidTotal
            ? 'slds-text-color_success slds-text-heading_small'
            : 'slds-text-color_error slds-text-heading_small';
    }

    get totalLabel() {
        return `Total: ${this.totalPercentage}%`;
    }

    handleWeightChange(event) {
        const field = event.target.dataset.field;
        const percentage = Number(event.target.value);
        const decimal = percentage / 100;

        this._weights = { ...this._weights, [field]: Math.round(decimal * 100) / 100 };
        this.notifyChange();
    }

    handleResetDefaults() {
        this._weights = { ...DEFAULTS };
        this.notifyChange();
    }

    notifyChange() {
        this.dispatchEvent(new CustomEvent('weightschange', {
            detail: { ...this._weights }
        }));
    }

    @api
    getWeights() {
        return { ...this._weights };
    }

    @api
    validate() {
        return this.isValidTotal;
    }
}
