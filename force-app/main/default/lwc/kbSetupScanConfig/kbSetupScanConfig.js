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
    freshnessThresholdMonths: 12,
    freshnessCriticalMonths: 24,
    usesDataCategories: false
};

export default class KbSetupScanConfig extends LightningElement {
    @api
    get config() {
        return this._config;
    }
    set config(value) {
        this._config = value ? { ...value } : { ...DEFAULTS };
    }

    @track _config = { ...DEFAULTS };

    handleChange(event) {
        const field = event.target.dataset.field;
        let value;

        if (event.target.type === 'checkbox' || event.target.type === 'toggle') {
            value = event.target.checked;
        } else if (event.target.type === 'number') {
            const raw = event.target.value;
            value = raw === '' ? null : Number(raw);
        } else {
            value = event.target.value;
        }

        this._config = { ...this._config, [field]: value };
        this.notifyChange();
    }

    handleResetDefaults() {
        this._config = { ...DEFAULTS };
        this.notifyChange();
    }

    notifyChange() {
        this.dispatchEvent(new CustomEvent('configchange', {
            detail: { ...this._config }
        }));
    }

    @api
    getConfig() {
        return { ...this._config };
    }
}
