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
import { LightningElement, api } from 'lwc';
import HELP_MAX_FINALISTS from '@salesforce/label/c.KB_Helptext_Pipeline_MaxFinalists';
import HELP_TOP_K from '@salesforce/label/c.KB_Helptext_Pipeline_TopK';
import HELP_SIM_THRESHOLD from '@salesforce/label/c.KB_Helptext_Pipeline_SimThreshold';
import HELP_LANGUAGES from '@salesforce/label/c.KB_Helptext_Pipeline_Languages';

// this "Duplicate Detection" screen exposes only the knobs a Knowledge
// Manager tunes — how many similar articles to scan, the match-confidence
// floor, and how many matches to deep-compare. The retired knobs:
//   - Auto-Merge / Manual Review thresholds — the auto-merge band gate was
//     removed from Tier 4 (merges are now always user-approved). Auto_Merge_
//     Threshold__c is dropped from the schema; Manual_Review_Threshold__c stays
//     (Tier 4 reads it to decide what to flag) but is an internal cutoff, not a
//     setup knob — it lives in the custom setting only now.
//   - Max Sub-Agent Callouts / Max Callout Limit — governor-budget internals
//     (Tier 4 / Tier 3). Still live, set via the KB_Pipeline_Config__c custom
//     setting and documented in the README; off the setup screen.
// Input Scope / Frequency — never read by any runtime caller.
const DEFAULTS = {
    maxFinalists: 3,
    tier2TopK: 20,
    tier2SimilarityThreshold: 0.75,
    supportedLanguages: 'en_US'
};

export default class KbSetupPipelineConfig extends LightningElement {
    _config = {};

    helpMaxFinalists = HELP_MAX_FINALISTS;
    helpTopK = HELP_TOP_K;
    helpSimThreshold = HELP_SIM_THRESHOLD;
    helpLanguages = HELP_LANGUAGES;

    @api
    get config() { return this._config; }
    set config(value) {
        this._config = value ? { ...value } : { ...DEFAULTS };
    }

    get maxFinalists() { return this._config.maxFinalists ?? DEFAULTS.maxFinalists; }
    get tier2TopK() { return this._config.tier2TopK ?? DEFAULTS.tier2TopK; }
    get tier2SimilarityThreshold() {
        return this._config.tier2SimilarityThreshold ?? DEFAULTS.tier2SimilarityThreshold;
    }
    get supportedLanguages() { return this._config.supportedLanguages || DEFAULTS.supportedLanguages; }

    handleChange(event) {
        const field = event.target.dataset.field;
        let value = event.detail.value !== undefined ? event.detail.value : event.target.value;
        if (event.target.type === 'number') {
            value = parseFloat(value);
        }
        this._config = { ...this._config, [field]: value };
        this.dispatchEvent(new CustomEvent('configchange', { detail: this._config }));
    }

    handleResetDefaults() {
        // Merge over the incoming config so persisted-but-off-screen fields
        // (e.g. Manual_Review_Threshold, callout budgets) are preserved.
        this._config = { ...this._config, ...DEFAULTS };
        this.dispatchEvent(new CustomEvent('configchange', { detail: this._config }));
    }
}
