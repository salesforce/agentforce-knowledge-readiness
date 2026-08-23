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
import resolveContradiction from '@salesforce/apex/DuplicateCandidateController.resolveContradiction';
import getArticleComparison from '@salesforce/apex/DuplicateCandidateController.getArticleComparison';

/**
 * Resolve contradiction modal shown when the user selects "Resolve" on a
 * contradiction row in the Action Center. Lets the user choose Article A correct,
 * Article B correct, or both valid (different scope). Each outcome calls the Apex
 * controller to create a KB_Dimension_Analysis__c row on the incorrect article(s),
 * then close() with the resolution string so the parent can show a toast and refresh.
 *
 * Migrated to lightning/modal. Instead of the parent slotting this
 * component's markup behind a showContradictionModal flag and listening for
 * `close` / `resolved` events, the parent now imports this class and calls
 * `KbResolveContradictionModal.open({ size: 'large', candidateId, ... })`, which
 * returns a promise that resolves to { resolution: string } on success or
 * undefined when dismissed via the header X / Escape (the parent treats that as
 * cancel/no-op).
 */
export default class KbResolveContradictionModal extends LightningModal {
    @api candidateId;
    @api article1Id;
    @api article2Id;
    @api reasoning = '';

    comparison;
    isLoading = true;
    isSubmitting = false;
    error;

    async connectedCallback() {
        try {
            this.comparison = await getArticleComparison({
                articleVersionIdA: this.article1Id,
                articleVersionIdB: this.article2Id
            });
        } catch (e) {
            this.error = e.body?.message || 'Failed to load article comparison.';
        } finally {
            this.isLoading = false;
        }
    }

    get articleA() {
        return this.comparison?.articleA;
    }

    get articleB() {
        return this.comparison?.articleB;
    }

    get submitDisabled() {
        return this.isSubmitting;
    }

    async handleChooseA() {
        await this.resolve(this.article1Id, 'article_a_correct');
    }

    async handleChooseB() {
        await this.resolve(this.article2Id, 'article_b_correct');
    }

    async handleBothValid() {
        await this.resolve(null, 'both_valid_different_scope');
    }

 // "Needs SME review" was retired — it produced no recommendation/
    // routing, so it behaved exactly like a dismiss. Reintroduce when there's a
    // real routing target. The button is removed from the template.

    async resolve(correctArticleId, resolution) {
        this.isSubmitting = true;
        this.error = null;
        try {
            await resolveContradiction({
                candidateId: this.candidateId,
                correctArticleId,
                resolution
            });
            this.close({ resolution, candidateId: this.candidateId });
        } catch (e) {
            this.error = e.body?.message || 'Failed to resolve contradiction.';
        } finally {
            this.isSubmitting = false;
        }
    }

    handleCancel() {
        this.close();
    }
}
