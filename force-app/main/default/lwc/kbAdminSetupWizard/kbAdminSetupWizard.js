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
import KbUnsavedChangesModal from 'c/kbUnsavedChangesModal';
import getScanConfig from '@salesforce/apex/KBSetupWizardController.getScanConfig';
import saveScanConfig from '@salesforce/apex/KBSetupWizardController.saveScanConfig';
import getScoreWeights from '@salesforce/apex/KBSetupWizardController.getScoreWeights';
import saveScoreWeights from '@salesforce/apex/KBSetupWizardController.saveScoreWeights';
import getPipelineConfig from '@salesforce/apex/KBSetupWizardController.getPipelineConfig';
import savePipelineConfig from '@salesforce/apex/KBSetupWizardController.savePipelineConfig';
import getVectorSearchConfig from '@salesforce/apex/KBSetupWizardController.getVectorSearchConfig';
import saveVectorSearchConfig from '@salesforce/apex/KBSetupWizardController.saveVectorSearchConfig';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const STEPS = [
    { label: 'Scan', value: '1' },
    { label: 'Weights', value: '2' },
    { label: 'Prompts', value: '3' },
    { label: 'Jargon', value: '4' },
    { label: 'Pipeline', value: '5' },
    { label: 'Vector', value: '6' },
    { label: 'Schedule', value: '7' }
];

// Steps that persist state via a save handler. Prompts/Jargon/Schedule are
// managed by their own sub-components and have no parent-level save op.
const SAVEABLE_STEPS = new Set(['1', '2', '5', '6']);

export default class KbAdminSetupWizard extends LightningElement {
    @track currentStep = '1';
    @track scanConfig = {};
    @track scoreWeights = {};
    @track pipelineConfig = {};
    @track vectorSearchConfig = {};
    @track isLoading = true;
    @track isSaving = false;

    // Per-step dirty flags. Flipped in each change handler; cleared on save.
    @track _dirtyByStep = { 1: false, 2: false, 3: false, 4: false, 5: false, 6: false, 7: false };

    _pendingStep = null;

    steps = STEPS;

    async connectedCallback() {
        await this.loadData();
    }

    async loadData() {
        this.isLoading = true;
        try {
            const [config, weights, pipeline, vector] = await Promise.all([
                getScanConfig(),
                getScoreWeights(),
                getPipelineConfig(),
                getVectorSearchConfig()
            ]);
            this.scanConfig = config;
            this.scoreWeights = weights;
            this.pipelineConfig = pipeline;
            this.vectorSearchConfig = vector;
        } catch (error) {
            this.showToast('Error', 'Failed to load configuration: ' + this.extractError(error), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // Step Navigation
    get currentStepNumber() {
        return parseInt(this.currentStep, 10);
    }

    get isFirstStep() {
        return this.currentStep === '1';
    }

    get isLastStep() {
        return this.currentStep === '7';
    }

    get stepsWithState() {
        return STEPS.map((step, i) => ({
            ...step,
            index: i + 1,
            labelClass: 'step-label' + (step.value === this.currentStep ? ' step-label_active' : '')
        }));
    }

    get isStep1() { return this.currentStep === '1'; }
    get isStep2() { return this.currentStep === '2'; }
    get isStep3() { return this.currentStep === '3'; }
    get isStep4() { return this.currentStep === '4'; }
    get isStep5() { return this.currentStep === '5'; }
    get isStep6() { return this.currentStep === '6'; }

    get currentStepTitle() {
        const step = this.steps.find(s => s.value === this.currentStep);
        return step ? step.label : '';
    }

    get isCurrentStepDirty() {
        return !!this._dirtyByStep[this.currentStep];
    }

    /**
     * Morphing primary CTA for the sticky footer.
     * - Saveable step + dirty → Save & Next (or Save if last)
     * - Saveable step + clean → Next (or nothing if last — handled by isLastStep)
     * - Non-saveable step → Next (no save op)
     * - Last step → Save (if dirty + saveable) or Done
     */
    get primaryCta() {
        const isSaveable = SAVEABLE_STEPS.has(this.currentStep);
        const dirty = this.isCurrentStepDirty;

        if (this.isLastStep) {
            if (isSaveable && dirty) {
                return { label: 'Save', variant: 'brand', iconName: null, disabled: this.isSaving, action: 'saveOnly' };
            }
            return { label: 'Done', variant: 'brand', iconName: 'utility:check', disabled: false, action: 'done' };
        }

        if (isSaveable && dirty) {
            return { label: 'Save & Next', variant: 'brand', iconName: null, disabled: this.isSaving, action: 'saveAndAdvance' };
        }
        return { label: 'Next', variant: 'brand', iconName: null, disabled: false, action: 'advance' };
    }

    handleStepClick(event) {
        const stepValue = event.target.value || event.currentTarget.dataset.step;
        if (!stepValue || stepValue === this.currentStep) return;
        this._tryNavigateTo(stepValue);
    }

    handlePreviousClicked() {
        if (this.isFirstStep) return;
        this._tryNavigateTo(String(this.currentStepNumber - 1));
    }

    async handlePrimaryCtaClicked() {
        const action = this.primaryCta.action;
        if (action === 'advance') {
            this._navigateNow(String(this.currentStepNumber + 1));
        } else if (action === 'saveAndAdvance') {
            const saved = await this._saveCurrentStep();
            if (!saved) return;
            this._clearDirty(this.currentStep);
            this._navigateNow(String(this.currentStepNumber + 1));
        } else if (action === 'saveOnly') {
            const saved = await this._saveCurrentStep();
            if (!saved) return;
            this._clearDirty(this.currentStep);
        } else if (action === 'done') {
            // Last step reached with no pending work — nothing to do but
            // acknowledge. Users exit via the app nav.
            this.showToast('Done', 'All configuration steps complete.', 'success');
        }
    }

    async _tryNavigateTo(targetStep) {
        if (this.isCurrentStepDirty) {
            this._pendingStep = targetStep;
 // lightning/modal — open resolves to the string result the
            // modal closes with ('save' | 'discard' | 'cancel'), or undefined
            // when dismissed via the header X / Escape (treated as 'cancel').
            const result = await KbUnsavedChangesModal.open({ size: 'small' });
            await this._handleUnsavedResult(result);
            return;
        }
        this._navigateNow(targetStep);
    }

    async _handleUnsavedResult(result) {
        if (result === 'save') {
            await this.handleUnsavedSave();
        } else if (result === 'discard') {
            this.handleUnsavedDiscard();
        } else {
            this.handleUnsavedCancel();
        }
    }

    _navigateNow(targetStep) {
        this.currentStep = targetStep;
    }

    _clearDirty(stepKey) {
        this._dirtyByStep = { ...this._dirtyByStep, [stepKey]: false };
    }

    _markDirty(stepKey) {
        if (!this._dirtyByStep[stepKey]) {
            this._dirtyByStep = { ...this._dirtyByStep, [stepKey]: true };
        }
    }

 // Unsaved-changes modal result handlers ---

    async handleUnsavedSave() {
        const saved = await this._saveCurrentStep();
        if (!saved) {
            this._pendingStep = null;
            return;
        }
        this._clearDirty(this.currentStep);
        if (this._pendingStep) {
            const target = this._pendingStep;
            this._pendingStep = null;
            this._navigateNow(target);
        }
    }

    handleUnsavedDiscard() {
        this._clearDirty(this.currentStep);
        if (this._pendingStep) {
            const target = this._pendingStep;
            this._pendingStep = null;
            this._navigateNow(target);
        }
    }

    handleUnsavedCancel() {
        this._pendingStep = null;
    }

    // Config change handlers
    handleConfigChange(event) {
        this.scanConfig = { ...event.detail };
        this._markDirty('1');
    }

    handleWeightsChange(event) {
        this.scoreWeights = { ...event.detail };
        this._markDirty('2');
    }

    handlePipelineConfigChange(event) {
        this.pipelineConfig = { ...event.detail };
        this._markDirty('5');
    }

    handleVectorConfigChange(event) {
        this.vectorSearchConfig = { ...event.detail };
        this._markDirty('6');
    }

    /**
     * Save whichever saveable step the user is on. Returns true on success.
     * Non-saveable steps are treated as saved (nothing to persist at this
     * layer — prompt/jargon/schedule own their own persistence).
     */
    async _saveCurrentStep() {
        if (!SAVEABLE_STEPS.has(this.currentStep)) {
            return true;
        }
        this.isSaving = true;
        try {
            if (this.currentStep === '1') {
                await saveScanConfig({ configJSON: JSON.stringify(this.scanConfig) });
                this.showToast('Success', 'Scan configuration saved.', 'success');
            } else if (this.currentStep === '2') {
                const weightsComp = this.template.querySelector('c-kb-setup-score-weights');
                if (weightsComp && !weightsComp.validate()) {
                    this.showToast('Error', 'Weights must sum to 100%. Please fix before saving.', 'error');
                    return false;
                }
                await saveScoreWeights({ weightsJSON: JSON.stringify(this.scoreWeights) });
                this.showToast('Success', 'Score weights saved.', 'success');
            } else if (this.currentStep === '5') {
                await savePipelineConfig({ configJSON: JSON.stringify(this.pipelineConfig) });
                this.showToast('Success', 'Pipeline configuration saved.', 'success');
            } else if (this.currentStep === '6') {
                await saveVectorSearchConfig({ configJSON: JSON.stringify(this.vectorSearchConfig) });
                this.showToast('Success', 'Vector search configuration saved.', 'success');
            }
            return true;
        } catch (error) {
            this.showToast('Error', 'Save failed: ' + this.extractError(error), 'error');
            return false;
        } finally {
            this.isSaving = false;
        }
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    extractError(error) {
        if (typeof error === 'string') return error;
        if (error.body?.message) return error.body.message;
        if (error.message) return error.message;
        return JSON.stringify(error);
    }
}
