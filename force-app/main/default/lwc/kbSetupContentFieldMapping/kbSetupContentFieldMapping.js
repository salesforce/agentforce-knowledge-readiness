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
import getKnowledgeFieldOptions from '@salesforce/apex/KBSetupOrchestratorController.getKnowledgeFieldOptions';

export default class KbSetupContentFieldMapping extends LightningElement {
    @track allFields = [];
    @track isLoading = true;
    @track _wireResolved = false;
    @track error;

    _selectedFields = [];

    @api
    get selectedFields() {
        return this._selectedFields;
    }
    set selectedFields(value) {
        this._selectedFields = Array.isArray(value) ? [...value] : [];
        this._syncCheckboxes();
    }

    @wire(getKnowledgeFieldOptions)
    wiredFields({ data, error }) {
        if (data === undefined && error === undefined) return; // initial tick, not yet resolved
        this.isLoading = false;
        this._wireResolved = true;
        if (data) {
            this.allFields = data.map(f => ({
                label: f.label,
                value: f.value,
                group: f.group,
                checked: this._selectedFields.includes(f.value)
            }));
        } else if (error) {
            this.error = error?.body?.message || 'Could not load Knowledge fields.';
        }
    }

    get textAreaFields() {
        return this.allFields.filter(f => f.group === 'Long Text / Rich Text');
    }

    get shortTextFields() {
        return this.allFields.filter(f => f.group === 'Short Text');
    }

    get hasTextAreaFields() { return this.textAreaFields.length > 0; }
    get hasShortTextFields() { return this.shortTextFields.length > 0; }
    get hasFields() { return this.allFields.length > 0; }
    get isEmpty() { return this._wireResolved && !this.error && this.allFields.length === 0; }
    get hasError() { return !!this.error; }
    get hasSelection() { return this._selectedFields.length > 0; }

    get selectionSummary() {
        const count = this._selectedFields.length;
        return `${count} field${count === 1 ? '' : 's'} selected for content scoring and deduplication.`;
    }

    handleFieldToggle(event) {
        const fieldValue = event.target.dataset.value;
        const checked = event.target.checked;
        if (checked) {
            if (!this._selectedFields.includes(fieldValue)) {
                this._selectedFields = [...this._selectedFields, fieldValue];
            }
        } else {
            this._selectedFields = this._selectedFields.filter(f => f !== fieldValue);
        }
        this.allFields = this.allFields.map(f => ({
            ...f,
            checked: this._selectedFields.includes(f.value)
        }));
        this.dispatchEvent(new CustomEvent('fieldmappingchange', {
            detail: [...this._selectedFields]
        }));
    }

    _syncCheckboxes() {
        if (this.allFields.length > 0) {
            this.allFields = this.allFields.map(f => ({
                ...f,
                checked: this._selectedFields.includes(f.value)
            }));
        }
    }
}
