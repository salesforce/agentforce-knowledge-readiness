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
import LightningModal from 'lightning/modal';
import { api } from 'lwc';

/**
 * Article Comparison modal shown when the user selects "Compare Articles" on a
 * duplicate-candidate row in the Action Center. Displays the two candidate
 * articles' fields side-by-side plus the AI reasoning, and offers Resolve /
 * Reject. Pure UI shell — the host fetches the comparison data and owns the
 * follow-up action.
 *
 * Migrated to lightning/modal. Instead of the host slotting this
 * component's markup behind a showComparisonModal flag, the host now imports
 * this class and calls
 * `KbAuditCompareModal.open({ size: 'large', comparisonData, reasoning, candidateId })`,
 * which returns a promise that resolves to { action: 'resolve' | 'reject' } when
 * the user picks an action, or undefined when dismissed via the header X /
 * Escape / Close (the host treats that as a no-op).
 *
 * `readOnly` gates the mutating footer actions. The
 * unified queue reaches this modal from Resolved/Superseded/discarded rows
 * ("inspect only"), where a Resolve / Not-a-Duplicate click would silently
 * re-open a closed candidate. Pass `readOnly: true` for those rows so the
 * footer collapses to a single Close button; Pending rows leave it false and
 * keep the action buttons.
 */
export default class KbAuditCompareModal extends LightningModal {
    @api comparisonData;
    @api reasoning = '';
    @api candidateId;
    @api readOnly = false;

    get showActions() {
        return !this.readOnly;
    }

    get articleA() {
        return this.comparisonData?.articleA;
    }

    get articleB() {
        return this.comparisonData?.articleB;
    }

    handleClose() {
        this.close();
    }

    handleResolve() {
        this.close({ action: 'resolve', candidateId: this.candidateId });
    }

    handleReject() {
        this.close({ action: 'reject', candidateId: this.candidateId });
    }
}
