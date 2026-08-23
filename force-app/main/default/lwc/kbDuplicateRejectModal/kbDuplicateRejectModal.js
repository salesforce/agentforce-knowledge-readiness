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

/**
 * "Not a Duplicate" modal shown when the user dismisses a duplicate candidate in
 * the Action Center. Collects an OPTIONAL free-text reason (used to improve
 * future detection). Pure UI shell — the host owns the markNotADuplicate Apex
 * call.
 *
 * 'Reject' + 'Suppress Pair' were consolidated into a single soft "Not a
 * Duplicate" action. The pair re-surfaces on the next assessment regardless, so
 * the reason is optional — Confirm is never gated on it.
 *
 * Migrated to lightning/modal. The host imports this class and calls
 * `KbDuplicateRejectModal.open({ size: 'small' })`, which returns a promise that
 * resolves to { reason: string } on confirm, or undefined when dismissed via the
 * header X / Escape / Cancel (the host treats that as cancel).
 */
export default class KbDuplicateRejectModal extends LightningModal {
    rejectionReason = '';

    handleReasonChange(event) {
        this.rejectionReason = event.detail.value;
    }

    handleCancel() {
        this.close();
    }

    handleConfirm() {
        this.close({ reason: this.rejectionReason });
    }
}
