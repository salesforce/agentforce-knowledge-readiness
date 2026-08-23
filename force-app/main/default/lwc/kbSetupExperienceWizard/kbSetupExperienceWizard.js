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
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import KbUnsavedChangesModal from 'c/kbUnsavedChangesModal';
import hasPrePublishCheckBeta from '@salesforce/customPermission/KB_PrePublishCheck_Beta';
import canAccessAssessments from '@salesforce/apex/KBSetupOrchestratorController.canAccessAssessments';
import getBootstrapData from '@salesforce/apex/KBSetupOrchestratorController.getBootstrapData';
import saveWizardState from '@salesforce/apex/KBSetupOrchestratorController.saveWizardState';
import saveCoreConfiguration from '@salesforce/apex/KBSetupOrchestratorController.saveCoreConfiguration';
import runFinalValidation from '@salesforce/apex/KBSetupOrchestratorController.runFinalValidation';
import saveVectorConfiguration from '@salesforce/apex/KBSetupOrchestratorController.saveVectorConfiguration';

import STEP_WELCOME from '@salesforce/label/c.KB_Wizard_Step_Welcome';
import STEP_ESSENTIALS from '@salesforce/label/c.KB_Wizard_Step_Essentials';
import STEP_VALIDATE_SAVE from '@salesforce/label/c.KB_Wizard_Step_ValidateSave';

import CTA_SAVE_AND_NEXT from '@salesforce/label/c.KB_Wizard_Cta_SaveAndNext';
import CTA_NEXT from '@salesforce/label/c.KB_Wizard_Cta_Next';
import CTA_RUN_VALIDATION from '@salesforce/label/c.KB_Wizard_Cta_RunValidation';
import CTA_COMPLETE_SETUP from '@salesforce/label/c.KB_Wizard_Cta_CompleteSetup';
// Label fullName is still KB_Wizard_Cta_GoToDashboard (renaming a label is a
// metadata migration); its value now reads "Go to Assessments" since the
// dashboard was retired. Aliased to match what it renders.
import CTA_GO_TO_ASSESSMENTS from '@salesforce/label/c.KB_Wizard_Cta_GoToDashboard';
import CTA_DONE from '@salesforce/label/c.KB_Wizard_Cta_Done';
import CTA_RERUN_VALIDATION from '@salesforce/label/c.KB_Wizard_Cta_RerunValidation';

import CHECK_CTA_GO_TO_STEP from '@salesforce/label/c.KB_Wizard_Check_Cta_GoToStep';
import CHECK_CTA_OPEN_SETUP from '@salesforce/label/c.KB_Wizard_Check_Cta_OpenSetup';
import TOAST_ESSENTIALS_SAVED from '@salesforce/label/c.KB_Wizard_Toast_EssentialsSaved';
import TOAST_VALIDATION_PASSED from '@salesforce/label/c.KB_Wizard_Toast_ValidationPassed';
import TOAST_VALIDATION_FAILED from '@salesforce/label/c.KB_Wizard_Toast_ValidationFailed';
import TOAST_SETUP_COMPLETE from '@salesforce/label/c.KB_Wizard_Toast_SetupComplete';
import TOAST_SETUP_COMPLETE_TITLE from '@salesforce/label/c.KB_Wizard_Toast_SetupComplete_Title';

// Permset api names — referenced by the final "Next Steps" guidance on the
// Validate & Save step. Sourced from Custom Labels so a renamed permset stays
// coherent with what the admin sees in the page copy.
import PERMSET_ADMIN_API_NAME from '@salesforce/label/c.KB_Permset_Admin_ApiName';
import PERMSET_VIEWER_API_NAME from '@salesforce/label/c.KB_Permset_Viewer_ApiName';

// Setup redesign: the wizard is collapsed from 5 steps to 3
// Welcome → Essentials → Validate & Save. Essentials is the single mandatory
// screen (content fields, data categories, search index + ADL flag); everything
// that was on the former Assessment Rules / Runtime & Retrieval steps (scan
// config, score weights, pipeline/Duplicate-Detection knobs incl. the
// similarity threshold) now lives in a collapsible Advanced accordion on the
// SAME screen, collapsed by default. Save & finish is reachable without ever
// opening Advanced.
const STEPS = [
    { label: STEP_WELCOME, value: '1' },
    { label: STEP_ESSENTIALS, value: '2' },
    { label: STEP_VALIDATE_SAVE, value: '3' }
];

// Baseline the wizard falls back to when bootstrap returns no vectorConfig
// (fresh install). Values here must be either Salesforce defaults (implementation
// class, dataSpaceName = 'default' is the Data Cloud convention, 0.75 and 20
// are the scorer's proven defaults) or truly customer-agnostic. The search
// index name is customer-specific — leave it blank so the user MUST pick one
// from the combobox populated by getAvailableSearchIndexes() in Step 4.
const DEFAULT_VECTOR_CONFIG = {
    implementationClass: 'ConnectApiVectorSearchService',
    searchIndexName: '',
    similarityThreshold: 0.75,
    maxResults: 20,
    dataSpaceName: 'default',
    isActive: true,
 // treat the index as a custom Data Cloud index by default; the admin
    // checks the ADL box when it's an Agentforce Data Library (all-versions ingest).
    isAdl: false
};

export default class KbSetupExperienceWizard extends NavigationMixin(LightningElement) {
    @track currentStep = '1';
    @track isLoading = true;

    @track scanConfig = {};
    @track scoreWeights = {};
    @track pipelineConfig = {};
    @track vectorConfig = {};
    @track finalValidations = [];
    @track manualTasks = [];
 // single Advanced accordion on the Essentials screen (was the former
    // Step 3 "Advanced Scoring Configuration" drawer). Collapsed by default.
    @track isAdvancedOpen = false;
    @track manualTaskState = {};
    @track isSetupComplete = false;
    @track contentFieldMapping = [];

 // whether the running user can reach the Assessments console. A
    // Setup-Admin-only user cannot, so the completion CTA becomes a plain
    // "Done" instead of a navigation that dead-ends. Defaults to true so the
    // CTA reads "Go to Assessments" until the wire resolves (the common case);
    // errors also leave it true (the nav is a no-worse fallback than a
    // wrongly-hidden button).
    @track _canAccessAssessments = true;

    @wire(canAccessAssessments)
    wiredCanAccessAssessments({ data }) {
        if (data !== undefined && data !== null) {
            this._canAccessAssessments = data;
        }
    }

    // Per-step dirty flags. A step is clean on load; any change handler
    // flips its step to dirty; a successful save of that step clears it.
    // Using @track so the template re-renders the dirty badge / CTA label.
 // only step '2' (Essentials) persists config now — Welcome ('1') and
    // Validate & Save ('3') have no persisted state. Extra keys are kept
    // defensively so a stray _markDirty never writes to undefined.
    @track _dirtyByStep = { 1: false, 2: false, 3: false };

    // Section-level dirty flags WITHIN the Essentials step. The step-level flag
    // above drives the unsaved-changes navigation prompt; these two decide which
    // of the two backend saves (core config vs. vector config) actually runs on
    // Save & finish. We save — and, crucially, validate — a section ONLY when it
    // changed. This is what keeps the vector-search validate() gate (and its
    // transient custom-index "published-only" ack, which resets on every load)
    // from re-firing every time the user passes through Essentials without
    // having touched the search index. Both reset on save-success and on reload.
    _coreDirty = false;
    _vectorDirty = false;
    // Distinct from _vectorDirty: tracks whether the search INDEX itself changed
    // (the search-index / ADL component). The vector-search validate() gate — and
    // its transient custom-index "published-only" ack, reset on every load — is
    // about the index, NOT the pre-publish top-K (maxResults). Editing maxResults
    // flips _vectorDirty (so it still persists via the vector save) but NOT this
    // flag, so an unrelated top-K bump never re-fires the index ack gate.
    _vectorIndexDirty = false;
    // The step we were trying to navigate to when we intercepted dirty state.
    // null → no pending navigation; number → target step.
    _pendingStep = null;

    steps = STEPS;

    // Label exposed to template — used by the always-on Re-run Validation
    // affordance on the Validate & Save step.
    rerunValidationLabel = CTA_RERUN_VALIDATION;

    // Surfaced in the final "Next Steps" copy on the Validate & Save step.
    permsetAdminName = PERMSET_ADMIN_API_NAME;
    permsetViewerName = PERMSET_VIEWER_API_NAME;

    get isFirstStep() {
        return this.currentStep === '1';
    }

    get isLastStep() {
        return this.currentStep === '3';
    }

    get isStep1() { return this.currentStep === '1'; }
    get isStep2() { return this.currentStep === '2'; }
    get isStep3() { return this.currentStep === '3'; }
    get hasFinalValidations() { return this.finalValidations.length > 0; }
    get hasManualTasks() { return this.manualTasks.length > 0; }

    get canCompleteSetup() {
        return this.hasFinalValidations && !this.finalValidations.some(v => !v.passed && v.required);
    }

    get hasValidationFailures() {
        return this.hasFinalValidations && this.finalValidations.some(v => !v.passed && v.required);
    }

    get advancedIcon() {
        return this.isAdvancedOpen ? 'utility:chevrondown' : 'utility:chevronright';
    }

    // Convenience getter for the data-categories toggle surfaced directly on
    // Essentials (mirrors KB_Scan_Config__c.usesDataCategories, which the
    // kbSetupScanConfig child also edits under Advanced — both write the same
    // shared scanConfig).
    get usesDataCategories() { return this.scanConfig.usesDataCategories === true; }

    get isCurrentStepDirty() {
        return !!this._dirtyByStep[this.currentStep];
    }

    /**
     * Single source of truth for the sticky footer's primary CTA.
     * Returns { label, variant, iconName, disabled } driven by the current
     * step + dirty flag + final-validation state. The last step morphs
     * through 3 states: Run Final Validation → Complete Setup (on pass) →
     * Run Final Validation (on fail).
     */
    get primaryCta() {
        // Last step is special — it morphs through validation states.
        if (this.isLastStep) {
            if (this.isSetupComplete) {
 // a Setup-Admin-only user can't reach the Assessments
                // console, so a "Go to Assessments" CTA would dead-end. Show a
                // plain "Done" that just dismisses instead.
                if (!this._canAccessAssessments) {
                    return { label: CTA_DONE, variant: 'brand', iconName: 'utility:check', disabled: false, action: 'dismiss' };
                }
                return { label: CTA_GO_TO_ASSESSMENTS, variant: 'brand', iconName: 'utility:forward', disabled: false, action: 'gotoAssessments' };
            }
            if (this.canCompleteSetup) {
                return { label: CTA_COMPLETE_SETUP, variant: 'brand', iconName: 'utility:check', disabled: false, action: 'completeSetup' };
            }
            return { label: CTA_RUN_VALIDATION, variant: 'brand', iconName: null, disabled: false, action: 'runFinalValidation' };
        }

        // Non-last steps: save-aware Next.
        if (this.isCurrentStepDirty) {
            return { label: CTA_SAVE_AND_NEXT, variant: 'brand', iconName: null, disabled: false, action: 'saveAndAdvance' };
        }
        return { label: CTA_NEXT, variant: 'brand', iconName: null, disabled: false, action: 'advance' };
    }

    async connectedCallback() {
        await this.loadBootstrap();
    }

    async loadBootstrap() {
        this.isLoading = true;
        try {
            const data = await getBootstrapData();
            const sc = data.scanConfig || {};
            this.contentFieldMapping = sc.contentFieldMapping || [];
            this.scanConfig = sc;
            this.scoreWeights = data.scoreWeights || {};
            this.pipelineConfig = data.pipelineConfig || {};
            this.vectorConfig = { ...DEFAULT_VECTOR_CONFIG, ...(data.vectorConfig || {}) };
            // Fresh load / discard-refetch: nothing is user-dirty yet. Reset the
            // section flags so Save & finish is a clean no-op until the user
            // actually edits something.
            this._coreDirty = false;
            this._vectorDirty = false;
            this._vectorIndexDirty = false;
            this.manualTasks = (data.manualTasks || []).map((task) => ({
                ...task,
                checked: this.manualTaskState[task.key] || false
            }));

            const wizardState = data.wizardState || {};
            if (wizardState.setupCompleted) {
                this.isSetupComplete = true;
            }
            if (wizardState.wizardStateJSON) {
                const parsedState = JSON.parse(wizardState.wizardStateJSON);
                if (parsedState.manualTaskState) {
                    this.manualTaskState = parsedState.manualTaskState;
                    this.manualTasks = this.manualTasks.map((task) => ({
                        ...task,
                        checked: this.manualTaskState[task.key] || false
                    }));
                }
            }
            this.currentStep = this._computeResumeStep(data);
        } catch (error) {
            this.showToast('Error', `Failed to initialize wizard: ${this.extractError(error)}`, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handlePreviousClicked() {
        if (this.isFirstStep) return;
        this._tryNavigateTo(String(Number(this.currentStep) - 1));
    }

    handlePrimaryCtaClicked() {
        const action = this.primaryCta.action;
        if (action === 'advance') {
            this._advance();
        } else if (action === 'saveAndAdvance') {
            this._saveAndAdvance();
        } else if (action === 'runFinalValidation') {
            this.handleRunFinalValidation();
        } else if (action === 'completeSetup') {
            this.handleCompleteSetup();
        } else if (action === 'gotoAssessments') {
            this.handleGoToAssessments();
        } else if (action === 'dismiss') {
            this.handleDismiss();
        }
    }

    /**
     * Navigate to `targetStep`. If the current step has unsaved changes,
     * open the Save/Discard/Cancel modal and park the target until the
     * user resolves it.
     */
    async _tryNavigateTo(targetStep) {
        if (this.isCurrentStepDirty) {
            this._pendingStep = targetStep;
 // lightning/modal — open resolves to the string result the
            // modal closes with ('save' | 'discard' | 'cancel'), or undefined
            // when dismissed via the header X / Escape (treated as 'cancel').
            const result = await KbUnsavedChangesModal.open({ size: 'small' });
            if (result === 'save') {
                await this.handleUnsavedSave();
            } else if (result === 'discard') {
                await this.handleUnsavedDiscard();
            } else {
                this.handleUnsavedCancel();
            }
            return;
        }
        this._navigateNow(targetStep);
    }

    _navigateNow(targetStep) {
        this.currentStep = targetStep;
        this.persistStep();
    }

    async _advance() {
        if (!this._confirmAdvance()) return;
        await this._saveCurrentStep();
        this._dirtyByStep = { ...this._dirtyByStep, [this.currentStep]: false };
        this._navigateNow(String(Number(this.currentStep) + 1));
    }

    /**
     * Save the current step's data, then advance. If save fails we stay
     * on the step and surface the error — the user can retry or discard
     * via Previous.
     */
    async _saveAndAdvance() {
        if (!this._confirmAdvance()) return;
        const saved = await this._saveCurrentStep();
        if (!saved) return;
        this._dirtyByStep = { ...this._dirtyByStep, [this.currentStep]: false };
        this._navigateNow(String(Number(this.currentStep) + 1));
    }

    /**
     * Soft proceed-time confirmations before advancing off a step. Returns
     * false to abort the advance (user cancelled), true to proceed.
     *
     * Step 2 (Content Scope): advancing with NO content fields selected
     * silently degrades scoring to the Summary field only, so we ask the user
     * to confirm. Not blocking — Summary-only is a legitimate (if narrow)
     * choice; the inline warning box already explains the consequence.
     */
    _confirmAdvance() {
        if (this.currentStep === '2' && (this.contentFieldMapping || []).length === 0) {
            // eslint-disable-next-line no-alert
            return window.confirm(
                'No content fields selected — are you sure you want to proceed?'
            );
        }
        return true;
    }

    /**
     * Save whichever step the user is on. Returns true on success.
     * Steps 1 (Welcome) and 3 (Validate & Save) have no persisted state — Step
     * 1 is the welcome card and Step 3 runs the always-on final-validation
     * check — so they're always "saved". Step 2 (Essentials) is the single
 * config-persisting step now.
     */
    async _saveCurrentStep() {
        try {
            if (this.currentStep === '2') {
                await this._saveEssentials();
            }
            return true;
        } catch (error) {
            this.showToast('Error', `Failed to save: ${this.extractError(error)}`, 'error');
            return false;
        }
    }

    /**
 * merged Essentials save. This one action persists the union of what
     * the old Steps 2 (content scope), 3 (scan config + score weights) and 4
     * (pipeline config + vector config) each saved, so the mandatory Essentials
     * path AND anything the user edited under the Advanced accordion both land
     * in a single Save & finish — WITHOUT requiring the user to open Advanced.
     *
     * The vector-search config still goes through saveVectorConfiguration
     * (per the KBSetupOrchestratorController.saveCoreConfiguration contract:
     * vectorConfigJSON is a no-op passthrough there — writes route through the
     * dedicated method). c-kb-setup-vector-search is always rendered on
     * Essentials (not behind Advanced), so its validate() gate resolves here.
     */
    async _saveEssentials() {
        // Only validate + persist a section that actually changed. Vector-search
        // in particular carries a transient validate() gate (the custom-index
        // "published-only" ack resets on every load), so re-running it when the
        // search index is untouched would block Save & finish on a field the
        // user never went near. Same principle for core config: an unchanged
        // section is a no-op, not a re-save.
        if (this._vectorIndexDirty) {
            // Vector-search validity check first, so the search-index-required
            // rule surfaces as an inline form-field error rather than a
            // server-side toast. Gated on _vectorIndexDirty (not _vectorDirty):
            // validate() enforces the search-INDEX ack, so an unrelated maxResults
            // (top-K) edit must not re-fire it.
            const vectorComp = this.template.querySelector('c-kb-setup-vector-search');
            if (vectorComp && typeof vectorComp.validate === 'function' && !vectorComp.validate()) {
                throw new Error('Resolve the highlighted fields before saving.');
            }
        }

        const savedSomething = this._coreDirty || this._vectorDirty;

        if (this._coreDirty) {
            await saveCoreConfiguration({
                scanConfigJSON: JSON.stringify({ ...this.scanConfig, contentFieldMapping: this.contentFieldMapping }),
                // Only send weights when populated. Bootstrap normally seeds the 6
                // active dimension weights (summing to 1.0); an empty {} would fail
                // the server-side sum-to-1 validation, so skip it and let the server
                // keep its existing values.
                scoreWeightsJSON: Object.keys(this.scoreWeights || {}).length ? JSON.stringify(this.scoreWeights) : null,
 // Always send pipelineConfig so the similarity threshold (and
                // the other Duplicate-Detection knobs) persist even when the user
                // never opened Advanced. saveCoreConfiguration skips blank args and
                // savePipelineConfig only writes keys present via containsKey, so an
                // untouched {} pipelineConfig is a safe no-op that keeps existing /
                // CMDT-default values.
                pipelineConfigJSON: JSON.stringify(this.pipelineConfig),
                // vector goes through saveVectorConfiguration — pass null per the
                // saveCoreConfiguration API contract.
                vectorConfigJSON: null
            });
        }

        if (this._vectorDirty) {
            await saveVectorConfiguration({ configJSON: JSON.stringify(this.vectorConfig) });
        }

        this._coreDirty = false;
        this._vectorDirty = false;
        this._vectorIndexDirty = false;
        // Only announce a save when something was actually persisted. Pressing
        // Next on a clean Essentials step still routes through here (the CTA is
        // save-aware but harmless when nothing changed) — without this guard it
        // would toast "saved" having written nothing.
        if (savedSomething) {
            this.showToast('Success', TOAST_ESSENTIALS_SAVED, 'success');
        }
    }

    // --- Unsaved-changes modal handlers ---

    async handleUnsavedSave() {
        const saved = await this._saveCurrentStep();
        if (!saved) {
            this._pendingStep = null;
            return;
        }
        this._dirtyByStep = { ...this._dirtyByStep, [this.currentStep]: false };
        if (this._pendingStep) {
            const target = this._pendingStep;
            this._pendingStep = null;
            this._navigateNow(target);
        }
    }

    async handleUnsavedDiscard() {
        // Discard truly means "throw away in-memory edits and refetch from the
        // server." Without this round-trip, the edits linger in this.scoreWeights
        // et al. and leak into the NEXT step's save — which is a bug we burned
        // on before (step 2 rejecting step 3's unsaved weights). One extra SOQL
        // via getBootstrapData is cheap on a user-initiated click.
        this._dirtyByStep = { ...this._dirtyByStep, [this.currentStep]: false };
        await this.loadBootstrap();
        if (this._pendingStep) {
            const target = this._pendingStep;
            this._pendingStep = null;
            this._navigateNow(target);
        }
    }

    handleUnsavedCancel() {
        this._pendingStep = null;
    }

    async persistStep() {
        try {
            await saveWizardState({
                stateJSON: JSON.stringify({
                    currentStep: this.currentStep,
                    manualTaskState: this.manualTaskState
                })
            });
        } catch (error) {
            this.showToast('Warning', `Step state was not persisted: ${this.extractError(error)}`, 'warning');
        }
    }

 // every config change on the Essentials screen (mandatory controls
    // AND the Advanced accordion tenants) marks the single Essentials step ('2')
    // dirty. The { ...event.detail } spread is load-bearing — dirty-tracking and
    // the child @api setters rely on new object identity.
    handleScanConfigChange(event) {
        this.scanConfig = { ...event.detail };
        this._markDirty('2');
        this._coreDirty = true;
    }

    handleWeightsChange(event) {
        this.scoreWeights = { ...event.detail };
        this._markDirty('2');
        this._coreDirty = true;
    }

    handlePipelineConfigChange(event) {
        this.pipelineConfig = { ...event.detail };
        this._markDirty('2');
        this._coreDirty = true;
    }

    handleVectorConfigChange(event) {
        this.vectorConfig = { ...event.detail };
        this._markDirty('2');
        this._vectorDirty = true;
        // The search INDEX itself changed here (not just maxResults), so the
        // index ack gate must re-validate on save.
        this._vectorIndexDirty = true;
    }

 // Max Results lives on the shared vectorConfig but is rendered in the
    // Advanced accordion (out of the mandatory search-index section). Editing it
    // marks the vector section dirty so it persists via the vector save path.
    get vectorMaxResults() {
        return this.vectorConfig ? this.vectorConfig.maxResults : undefined;
    }

    // Max Results (KB_Vector_Search_Config__c.Max_Results__c) tunes ONE runtime
    // path only: KnowledgeAIGovernanceService.verifyDraft, i.e. the single-article
    // Pre-publish duplicate check on the Knowledge record page. That tab is itself
    // gated by the KB_PrePublishCheck_Beta custom permission, so surfacing its
    // tuning knob for admins who can't see the feature is just noise (and reads as
    // a near-duplicate of the batch "Similar articles to scan" knob). Gate the
    // field on the same permission that gates the feature it configures.
    get showMaxResults() {
        return hasPrePublishCheckBeta === true;
    }

    // Help text for the pre-publish top-K, passed into the Duplicate Detection
    // child's subsection. Plain string (not a Custom Label) — one-off copy, and
    // avoids a labels metadata deploy for a single beta-gated field.
    get helpPrepublishTopK() {
        return 'How many similar articles the single-article Pre-publish duplicate check scans on the Knowledge record page. Separate from the batch dedup pipeline’s Matching setting above.';
    }

    // Fired by kbSetupPipelineConfig's Pre-publish subsection. event.detail is the
    // already-parsed number (or null) — the child owns the parse. Writes to
    // vectorConfig.maxResults and marks the vector section dirty so it persists
    // via saveVectorConfiguration, keeping it off the pipeline save.
    handleMaxResultsChange(event) {
        const value = event.detail;
        this.vectorConfig = {
            ...this.vectorConfig,
            maxResults: value === null || value === undefined ? undefined : value
        };
        this._markDirty('2');
        this._vectorDirty = true;
    }

    // Data-categories toggle surfaced directly on Essentials. Writes the same
    // KB_Scan_Config__c.usesDataCategories the kbSetupScanConfig child edits
    // under Advanced — both mutate the shared scanConfig object.
    handleUsesDataCategoriesChange(event) {
        this.scanConfig = { ...this.scanConfig, usesDataCategories: event.target.checked };
        this._markDirty('2');
        this._coreDirty = true;
    }

    _markDirty(stepKey) {
        if (!this._dirtyByStep[stepKey]) {
            this._dirtyByStep = { ...this._dirtyByStep, [stepKey]: true };
        }
    }


    async handleRunFinalValidation() {
        try {
            const validations = await runFinalValidation();
            this.finalValidations = (validations || []).map((item) => this.withCheckUiState(item));
            if (this.canCompleteSetup) {
                this.showToast('Validation passed', TOAST_VALIDATION_PASSED, 'success');
            } else {
                this.showToast('Validation complete', TOAST_VALIDATION_FAILED, 'warning');
            }
        } catch (error) {
            this.showToast('Error', `Final validation failed: ${this.extractError(error)}`, 'error');
        }
    }

    handleCompleteSetup() {
        this.isSetupComplete = true;
        this.showToast(TOAST_SETUP_COMPLETE_TITLE, TOAST_SETUP_COMPLETE, 'success');
    }

    handleGoToAssessments() {
 // The KB Health Dashboard is being retired — setup now lands the
        // user on the Assessments tab (KB_Assessment_Console) so they can run
        // their first assessment straight away. Only offered when the user can
 // actually reach it.
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Assessment_Console' }
        });
    }

 // the "Done" path for a user who can't reach the Assessments tab
    // (e.g. Setup-Admin-only). Nothing to navigate to, so just acknowledge the
    // completed setup and let them stay on the wizard.
    handleDismiss() {
        this.showToast(TOAST_SETUP_COMPLETE_TITLE, TOAST_SETUP_COMPLETE, 'success');
    }

    toggleAdvanced() {
        this.isAdvancedOpen = !this.isAdvancedOpen;
    }

    handleManualTaskToggle(event) {
        const taskKey = event.target.dataset.taskKey;
        const checked = event.target.checked;
        this.manualTaskState = { ...this.manualTaskState, [taskKey]: checked };
        this.manualTasks = this.manualTasks.map((task) => (
            task.key === taskKey ? { ...task, checked } : task
        ));
        this.persistStep();
    }

    withCheckUiState(check) {
        let icon, iconClass;
        if (check.passed) {
            icon = 'utility:success';
            iconClass = 'check-icon_success';
        } else if (check.severity === 'blocker') {
            icon = 'utility:error';
            iconClass = 'check-icon_error';
        } else {
            icon = 'utility:warning';
            iconClass = 'check-icon_warning';
        }
        // Decode the `actionKey` DSL from Apex into render-ready fields.
        // Passing checks never render a CTA even when the key is set — the
        // check's own green state is the signal.
        const decoded = (!check.passed && check.actionKey)
            ? this._decodeActionKey(check.actionKey)
            : null;
        return {
            ...check,
            icon,
            iconClass,
            ctaLabel: decoded ? decoded.label : null,
            ctaTarget: decoded ? decoded.target : null,
            hasCta: !!decoded
        };
    }

    /**
     * Parse a check actionKey ('step:N' / 'setup:NodeName' / null) into a
     * { label, target } tuple the template binds to a single CTA. The LWC
     * treats these two targets differently at click time (see handleCheckCta).
     */
    _decodeActionKey(actionKey) {
        if (!actionKey) return null;
        if (actionKey.startsWith('step:')) {
            const n = actionKey.slice(5);
            return { label: CHECK_CTA_GO_TO_STEP.replace('{0}', n), target: actionKey };
        }
        if (actionKey.startsWith('setup:')) {
            return { label: CHECK_CTA_OPEN_SETUP, target: actionKey };
        }
        return null;
    }

    handleCheckCta(event) {
        const target = event.currentTarget.dataset.target;
        if (!target) return;
        if (target.startsWith('step:')) {
            const targetStep = target.slice(5);
            this._tryNavigateTo(targetStep);
            return;
        }
        if (target.startsWith('setup:')) {
            // Deep-link to the Salesforce Setup node. The DSL names map 1:1 to
            // standard__namedPage targets; if the org doesn't recognize the name,
            // the platform silently drops the user on the Setup home — acceptable
            // fallback for this CTA.
            const node = target.slice(6);
            this[NavigationMixin.Navigate]({
                type: 'standard__namedPage',
                attributes: { pageName: 'setup' },
                state: { address: '/lightning/setup/' + encodeURIComponent(node) + '/home' }
            });
        }
    }

    handleFieldMappingChange(event) {
        this.contentFieldMapping = event.detail || [];
        this.scanConfig = { ...this.scanConfig, contentFieldMapping: this.contentFieldMapping };
        this._markDirty('2');
        this._coreDirty = true;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    _computeResumeStep(data) {
        const sc = data.scanConfig || {};
        const vc = data.vectorConfig || {};

 // the wizard is now Welcome → Essentials → Validate & Save.
        // Essentials is the single mandatory config screen; the only "have they
        // been past it?" signals guaranteed to be set on that path are the
        // content-field mapping and the search-index name. We deliberately no
        // longer key resume off pipelineConfig.tier2SimilarityThreshold — that
        // knob moved into the optional Advanced accordion and may be null on an
        // Essentials-only save, which would falsely bounce a returning admin
        // back into the flow.
        const cfm = sc.contentFieldMapping;
        const hasContentScope = Array.isArray(cfm)
            ? cfm.length > 0
            : (typeof cfm === 'string' && cfm.trim().length > 0);
        // An org that deliberately disabled vector search (SOQL fallback) has no
        // search index name by design — treat that as satisfying the search-index
        // requirement so a completed disabled-vector org still resumes on the
        // final step rather than getting stuck on Essentials.
        const vectorDisabled = vc.isActive === false;
        const hasSearchIndex = vectorDisabled
            || (typeof vc.searchIndexName === 'string' && vc.searchIndexName.trim().length > 0);

        // Fresh install (no content fields chosen) lands on Step 1 (Welcome).
        // If content scope is set but the search index isn't, resume on
        // Essentials so the admin finishes the mandatory set. Otherwise the
        // mandatory set is complete — land on Validate & Save.
        if (!hasContentScope) return '1';
        if (!hasSearchIndex) return '2';
        return '3';
    }

    extractError(error) {
        if (typeof error === 'string') return error;
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        return JSON.stringify(error);
    }
}
