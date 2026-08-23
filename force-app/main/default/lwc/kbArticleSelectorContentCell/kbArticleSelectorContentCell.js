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

export default class KbArticleSelectorContentCell extends LightningElement {
    @api value;

    expanded = false;

    get textClass() {
        return this.expanded
            ? 'slds-text-body_regular cell-text cell-text_expanded'
            : 'slds-text-body_regular cell-text cell-text_clamped';
    }

    get toggleLabel() {
        return this.expanded ? 'Show less' : 'Show more';
    }

    // Only show the toggle if the cell content actually overflows the clamp.
    // We approximate "overflows" as "longer than ~250 characters or contains
    // 5+ explicit line breaks". A perfectly accurate measurement would
    // require post-render measurement of the rendered DOM; this heuristic
    // is good enough to suppress the button on short cells.
    get showToggle() {
        if (!this.value) return false;
        const str = String(this.value);
        if (str.length > 250) return true;
        const lineBreaks = (str.match(/\n/g) || []).length;
        return lineBreaks >= 5;
    }

    handleToggle(event) {
        // Stop the click from bubbling up into lightning-datatable's row
        // selection handler — without this, clicking the button toggles
        // the row's checkbox.
        event.stopPropagation();
        event.preventDefault();
        this.expanded = !this.expanded;
    }
}
