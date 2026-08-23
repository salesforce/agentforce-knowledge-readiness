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
import { NavigationMixin } from 'lightning/navigation';
import hasAnyRuns from '@salesforce/apex/KBAssessmentController.hasAnyRuns';
// isSetupCompleted is intentionally not cacheable so the wizard flip is
// visible immediately. Call imperatively in connectedCallback rather than
// @wire — wire requires cacheable=true and would defeat the freshness goal.
import isSetupCompleted from '@salesforce/apex/KBSetupOrchestratorController.isSetupCompleted';
import TITLE from '@salesforce/label/c.KB_Coach_FirstRun_Title';
import BODY from '@salesforce/label/c.KB_Coach_FirstRun_Body';
import CTA from '@salesforce/label/c.KB_Coach_FirstRun_CTA';

// localStorage key namespacing avoids clashes with other installed packages
// and makes this easy to reset during testing via browser devtools.
const DISMISS_KEY = 'kb-readiness.first-run-coach.dismissed';

/**
 * Dismissible banner shown on main KB tabs when:
 *   - Setup is complete, AND
 *   - There are zero assessment runs in the org, AND
 *   - The user hasn't dismissed the banner in this browser.
 *
 * The "has any runs" check doubles as an invalidation — once a run exists
 * (even if not started by this user), the coach disappears automatically.
 *
 * Dismissal is per-user-per-browser. We intentionally use localStorage
 * (not a server-side preference) to keep this item UI-only and to avoid
 * round-trips on every tab load. If the user clears localStorage they
 * see the coach again — acceptable: the banner has a clear Dismiss affordance.
 */
export default class KbFirstRunCoach extends NavigationMixin(LightningElement) {
    @track _setupCompleted = null;
    @track _hasRuns = null;
    @track _dismissed = false;

    titleLabel = TITLE;
    bodyLabel = BODY;
    ctaLabel = CTA;

    async connectedCallback() {
        try {
            this._dismissed = window.localStorage.getItem(DISMISS_KEY) === '1';
        } catch {
            // localStorage can throw in some sandboxed contexts. Fail open: show the banner.
            this._dismissed = false;
        }
        try {
            this._setupCompleted = !!(await isSetupCompleted());
        } catch {
            // If the call fails, default to "not completed" so the banner
            // doesn't appear pretending setup is fine when we can't tell.
            this._setupCompleted = false;
        }
    }

    @wire(hasAnyRuns)
    wiredRuns({ data }) {
        if (data !== undefined) {
            this._hasRuns = !!data;
        }
    }

    get shouldShow() {
        return this._setupCompleted === true
            && this._hasRuns === false
            && !this._dismissed;
    }

    handlePrimary() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: { apiName: 'KB_Assessment_Console' }
        });
    }

    handleDismiss() {
        this._dismissed = true;
        try {
            window.localStorage.setItem(DISMISS_KEY, '1');
        } catch {
            // Best-effort persistence; banner hides for this page load regardless.
        }
    }
}
