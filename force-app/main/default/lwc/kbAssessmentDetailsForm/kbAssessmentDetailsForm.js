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

/**
 * Step 1 ("Assessment details") of the new-assessment full-page flow.
 *
 * Collects a mandatory run name and an optional description. This component
 * owns only the form fields + validation — the parent shell owns path
 * navigation, so there are deliberately no Continue/Back buttons here.
 *
 * The public `runName` / `description` props are reactive so the parent can
 * restore previously entered values on back-navigation. On every keystroke we
 * emit a `detailschange` event carrying the current values plus an `isValid`
 * flag (true only when the trimmed name is non-blank), letting the parent
 * gate the "Continue" affordance it owns.
 *
 * Public API:
 *   @api runName        — string, current run name (default '')
 *   @api description    — string, current description (default '')
 *   @api reportValidity() → boolean — force the required-field error to show
 *                          and return whether the name is valid
 *   @api focusName()    — best-effort focus of the name input
 *   event `detailschange` — detail: { runName, description, isValid }
 */
export default class KbAssessmentDetailsForm extends LightningElement {
    // Private reactive backing fields. The @api accessors below front these so
    // the parent can both read and restore values without us reassigning a
    // public property (forbidden by @lwc/lwc/no-api-reassignments).
    @track _runName = '';
    @track _description = '';

    /** @returns {string} the current (raw, untrimmed) run name */
    @api
    get runName() {
        return this._runName;
    }
    set runName(value) {
        this._runName = value || '';
    }

    /** @returns {string} the current description */
    @api
    get description() {
        return this._description;
    }
    set description(value) {
        this._description = value || '';
    }

    /** Handles edits to the assessment name input. */
    handleNameChange(event) {
        this._runName = event.target.value || '';
        this._emitChange();
    }

    /** Handles edits to the optional description textarea. */
    handleDescriptionChange(event) {
        this._description = event.target.value || '';
        this._emitChange();
    }

    /**
     * Forces the inner name input to surface its required-field error and
     * returns whether the form is currently valid. The parent calls this
     * before advancing the path.
     *
     * @returns {boolean} true when the trimmed name is non-blank
     */
    @api
    reportValidity() {
        const input = this.template.querySelector('lightning-input[data-id="name"]');
        if (input) {
            input.reportValidity();
        }
        return this._isValid;
    }

    /** Best-effort focus of the name input (guards for an absent node). */
    @api
    focusName() {
        const input = this.template.querySelector('lightning-input[data-id="name"]');
        if (input) {
            input.focus();
        }
    }

    // ─── Getters ────────────────────────────────────────────────────────────

    /** True only when the name has a non-blank value after trimming. */
    get _isValid() {
        return (this._runName || '').trim().length > 0;
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    /**
     * Emits `detailschange` with the raw (untrimmed) values and a freshly
     * computed validity flag. Fired on every change of either field so the
     * parent always has the live state.
     */
    _emitChange() {
        this.dispatchEvent(
            new CustomEvent('detailschange', {
                detail: {
                    runName: this._runName,
                    description: this._description,
                    isValid: this._isValid
                }
            })
        );
    }
}
