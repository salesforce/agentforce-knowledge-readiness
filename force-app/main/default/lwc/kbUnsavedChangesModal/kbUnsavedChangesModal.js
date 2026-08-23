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
 * Save / Discard / Cancel modal shown when the user tries to navigate away
 * from a step with unsaved changes. Pure UI shell — the parent owns the
 * follow-up action (navigate, stay, re-run save flow).
 *
 * Migrated to lightning/modal. Instead of the parent slotting this
 * component's markup behind an `is-open` flag and listening for `save` /
 * `discard` / `cancel` events, the parent now imports this class and calls
 * `KbUnsavedChangesModal.open({ size: 'small' })`, which returns a promise that
 * resolves to one of the string results 'save' | 'discard' | 'cancel' (or
 * undefined when dismissed via the header X / Escape — the parent treats that
 * as 'cancel').
 */
export default class KbUnsavedChangesModal extends LightningModal {
    handleSave() {
        this.close('save');
    }

    handleDiscard() {
        this.close('discard');
    }

    handleCancel() {
        this.close('cancel');
    }
}
