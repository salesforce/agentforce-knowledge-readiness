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
import { api, track } from 'lwc';

const FIX_SOURCE_OPTIONS = [
    {
        label: 'Use existing draft where available, start fresh for others',
        value: 'smart'
    },
    {
        label: 'Always start fresh from published version',
        value: 'published'
    }
];

/**
 * Bulk AI Fix modal shown from the Improvements Inbox. Takes selected article
 * groups as @api input; on confirm returns the chosen fixSource to the parent.
 *
 * Migrated to lightning/modal. Instead of the parent slotting this
 * component's markup behind a `showBulkModal` flag and listening for `confirm` /
 * `cancel` events, the parent now imports this class and calls
 * `KbBulkFixModal.open({ size: 'medium', groups, hasPendingDraft })`, which
 * returns a promise that resolves to `{ fixSource: 'smart' | 'published' }`
 * (or undefined when dismissed via the header X / Escape).
 */
export default class KbBulkFixModal extends LightningModal {
    @api groups = [];
    @api hasPendingDraft = false;

    @track fixSource    = 'smart';
    @track isProcessing = false;

    fixSourceOptions = FIX_SOURCE_OPTIONS;

    get articleCount() {
        return this.groups?.length || 0;
    }

    get recCount() {
        return (this.groups || []).reduce(
            (sum, g) => sum + (g.recommendations?.length || 0), 0
        );
    }

    get confirmLabel() {
        return `Fix ${this.articleCount} Article(s)`;
    }

    handleFixSourceChange(e) {
        this.fixSource = e.detail.value;
    }

    handleConfirm() {
        this.isProcessing = true;
        this.close({ fixSource: this.fixSource });
    }

    handleCancel() {
        this.close(undefined);
    }
}
