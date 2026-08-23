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
 * Reject-reason modal shown when the user selects "Reject" on an enrichment
 * candidate (single-row or bulk) in the Action Center. Captures a free-text
 * rejection reason, then close()s with { reason } on confirm so the host can
 * call the appropriate reject Apex action. Dismissing via the header X /
 * Escape resolves open() to undefined, which the host treats as cancel.
 *
 * Migrated to lightning/modal. Instead of the host slotting this
 * markup behind a showRejectModal flag and owning the reason field, the host
 * now imports this class and calls
 * `KbEnrichmentRejectModal.open({ size: 'small' })`, awaiting the { reason }
 * result.
 */
export default class KbEnrichmentRejectModal extends LightningModal {
    rejectionReason = '';

    get isConfirmDisabled() {
        return !this.rejectionReason || !this.rejectionReason.trim();
    }

    handleReasonChange(event) {
        this.rejectionReason = event.target.value;
    }

    handleConfirm() {
        if (this.isConfirmDisabled) {
            return;
        }
        this.close({ reason: this.rejectionReason.trim() });
    }

    handleCancel() {
        this.close();
    }
}
