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
import getPermsetAssignmentStatus from '@salesforce/apex/KBSetupOrchestratorController.getPermsetAssignmentStatus';

// Short, human-readable purpose blurbs keyed by the *default* package permset
// API names. The controller sources the actual names from Custom Labels (so a
// customer can rename), so we fall back to a generic blurb if a returned name
// isn't one we recognise — the row still renders.
const PERMSET_PURPOSE = {
    KB_Assessment_Setup_Admin:
        'Configures the app — runs the Setup Wizard only. No assessment or candidate data access. Assign alongside Manager to whoever both configures and runs the app.',
    KB_Assessment_Admin:
        'Manager — runs assessments, reviews results, and works the Action Center. Owns and manages the runs it creates. Assign to Knowledge Managers.',
    KB_Assessment_Viewer:
        'Read-only oversight across all assessments. Assign to executives and stakeholders who just need to see scores.'
};

// Platform prerequisites. These are Salesforce platform permissions the running
// user must hold for Data Cloud vector search and GenAI prompt templates to
// work. Missing these blocked the golden-org build, so they are surfaced
// explicitly here.
const PLATFORM_PREREQS = [
    {
        key: 'dataCloud',
        name: 'Data Cloud User',
        why: 'Required for semantic deduplication, which queries Data Cloud. Without it, dedup falls back to SOQL keyword matching.'
    },
    {
        key: 'promptTemplate',
        name: 'Prompt Template User',
        why: 'Required for the LLM scoring dimensions (Completeness / Structure / Clarity) and the AI Fix flow. Without it, those calls fail and scoring falls back to a baseline.'
    }
];

export default class KbSetupPermissions extends LightningElement {
    @track permsets = [];
    @track isLoading = true;
    @track error;

    @wire(getPermsetAssignmentStatus)
    wiredStatus(result) {
        const { data, error } = result;
        if (data === undefined && error === undefined) return;
        this.isLoading = false;
        if (data) {
            this.permsets = data.map((row) => this._decorate(row));
        } else if (error) {
            this.error = error?.body?.message || 'Could not load permission set status.';
        }
    }

    get platformPrereqs() {
        return PLATFORM_PREREQS;
    }

    get hasError() {
        return !!this.error;
    }

    _decorate(row) {
        const purpose = PERMSET_PURPOSE[row.apiName] || 'KB Readiness access for this persona.';
        return {
            apiName: row.apiName,
            label: row.label || row.apiName,
            purpose
        };
    }
}
