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
import { LightningElement, wire, track } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import getRecentPipelineRuns from '@salesforce/apex/KBAssessmentController.getRecentPipelineRuns';
import isSetupCompleted from '@salesforce/apex/KBSetupOrchestratorController.isSetupCompleted';

const COLUMNS = [
    { label: 'Run', fieldName: 'runName' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Modes', fieldName: 'executionModes' },
    { label: 'Scope', fieldName: 'scopeType' },
    { label: 'Input', fieldName: 'totalInputArticles', type: 'number' },
    { label: 'Processed', fieldName: 'processedCount', type: 'number' },
    { label: 'Evaluations', fieldName: 'pairEvaluationsCreated', type: 'number' },
    { label: 'Started', fieldName: 'startedAt', type: 'date' },
    { label: 'Completed', fieldName: 'completedAt', type: 'date' }
];

export default class KbPipelineOperations extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    runs = [];
    error;
    @track _setupCompleted = null;

    @wire(CurrentPageReference)
    pageRefChanged() {
        this.checkSetupStatus();
    }

    async checkSetupStatus() {
        try { this._setupCompleted = !!(await isSetupCompleted()); }
        catch { this._setupCompleted = true; }
    }

    get isSetupComplete() { return this._setupCompleted === true; }
    get isSetupLoading() { return this._setupCompleted === null; }

    handleGoToSetup() {
        this[NavigationMixin.Navigate]({ type: 'standard__navItemPage', attributes: { apiName: 'KB_Assessment_Setup' } });
    }

    @wire(getRecentPipelineRuns, { limitSize: 30 })
    wiredRuns({ data, error }) {
        if (data) {
            this.runs = data;
            this.error = undefined;
        } else if (error) {
            this.error = this.reduceErrors(error);
            this.runs = [];
        }
    }

    get hasRuns() {
        return this.runs.length > 0;
    }

    reduceErrors(errors) {
        if (!Array.isArray(errors)) {
            errors = [errors];
        }
        return errors
            .filter(error => !!error)
            .map(error => {
                if (typeof error === 'string') return error;
                if (error.body && error.body.message) return error.body.message;
                if (error.message) return error.message;
                return 'Unknown error';
            })
            .join(', ');
    }
}
