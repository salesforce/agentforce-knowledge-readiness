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

/**
 * Sticky footer for wizard-style flows.
 * Owns only layout + event dispatch. The parent decides label / variant / icon
 * based on its own state (dirty, last-step, validation-passed) and passes them in.
 *
 * Events dispatched:
 *   - `previous` — user clicked Previous
 *   - `primary`  — user clicked the primary CTA (Save & Next / Next / Validate / Complete Setup)
 */
export default class KbStickyWizardFooter extends LightningElement {
    @api primaryLabel = 'Next';
    @api primaryVariant = 'brand';
    @api primaryIconName;
    @api isPrimaryDisabled = false;
    @api isPreviousDisabled = false;
    @api showDirtyBadge = false;

    handlePrevious() {
        this.dispatchEvent(new CustomEvent('previous'));
    }

    handlePrimary() {
        this.dispatchEvent(new CustomEvent('primary'));
    }
}
