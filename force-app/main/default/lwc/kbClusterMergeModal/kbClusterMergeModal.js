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
import getNeighborCandidates from '@salesforce/apex/DuplicateCandidateController.getNeighborCandidates';
import approveMergeWithChoice from '@salesforce/apex/DuplicateCandidateController.approveMergeWithChoice';
import approveClusterMergeWithChoice from '@salesforce/apex/DuplicateCandidateController.approveClusterMergeWithChoice';

const DEFAULT_DEPTH = 1;
const MAX_DEPTH = 10;

// keep-choice (mirrors the Apex constants).
const KEEP_CREATE_NEW = 'create_new';
const KEEP_SURVIVOR = 'keep_survivor';

export default class KbClusterMergeModal extends LightningModal {
    @api seedCandidateId;
    @api seedArticle1Title = '';
    @api seedArticle2Title = '';
    @api seedArticle1Number = '';
    @api seedArticle2Number = '';
    @api seedArticle1Id;   // survivor picker needs version ids
    @api seedArticle2Id;

    @track neighbors = [];
    @track selectedIds = new Set();
    @track isLoading = false;
    @track currentDepth = DEFAULT_DEPTH;
    @track error = null;
    @track isSubmitting = false;

 // keep-choice state. Default to KEEP_SURVIVOR ("keep one article,
    // enriched with the others") — merging duplicates should normally collapse
    // them into one of the existing articles (retiring the rest), not spawn a
    // brand-new third record. Create-new remains available as an explicit choice.
    @track keepChoice = KEEP_SURVIVOR;
    @track survivorId = null;

    connectedCallback() {
        this.loadNeighbors(DEFAULT_DEPTH);
    }

    async loadNeighbors(depth) {
        this.isLoading = true;
        this.error = null;
        try {
            const data = await getNeighborCandidates({
                seedCandidateId: this.seedCandidateId,
                depth
            });
            this.neighbors = (data || []).map((n) => ({
                ...n,
                isSelected: this.selectedIds.has(n.candidateId),
                rowClass: this.selectedIds.has(n.candidateId) ? 'neighbor-row selected' : 'neighbor-row',
                hopLabel: `Hop ${n.hopDistance}`,
                scoreRounded: n.confidenceScore != null ? Math.round(n.confidenceScore) : '-'
            }));
            this.currentDepth = depth;
        } catch (e) {
            this.error = this.reduceError(e);
            this.neighbors = [];
        } finally {
            this.isLoading = false;
        }
    }

    get hasNeighbors() {
        return !this.isLoading && this.neighbors.length > 0;
    }

    get noNeighbors() {
        return !this.isLoading && !this.error && this.neighbors.length === 0;
    }

    get canExpandFurther() {
        return this.currentDepth < MAX_DEPTH;
    }

    get nextDepth() {
        return Math.min(this.currentDepth + 1, MAX_DEPTH);
    }

    get expandLabel() {
        return `Expand one more hop (depth ${this.nextDepth})`;
    }

    get selectedCount() {
        return this.selectedIds.size;
    }

    get clusterButtonLabel() {
        const n = this.selectedCount;
        return n === 0
            ? 'Merge Selected Cluster'
            : `Merge Selected Cluster (${n + 1})`; // +1 for the seed pair
    }

    get pairOnlyDisabled() {
        return this.isSubmitting || this.keepChoiceIncomplete;
    }

    get clusterMergeDisabled() {
        return this.isSubmitting || this.selectedIds.size === 0 || this.keepChoiceIncomplete;
    }

 // ── keep-choice ──────────────────────────────────────────────────────

    get keepChoiceOptions() {
        return [
            { label: 'Create a new merged article (Golden Record)', value: KEEP_CREATE_NEW },
            { label: 'Keep one article, enriched with the others', value: KEEP_SURVIVOR }
        ];
    }

    get isKeepSurvivor() {
        return this.keepChoice === KEEP_SURVIVOR;
    }

    // The articles the user can choose to keep: the seed pair + both articles of
    // every SELECTED neighbor, deduped by version id. (Unselected neighbors
    // aren't part of the merge, so they aren't eligible survivors.)
    get survivorOptions() {
        const seen = new Set();
        const opts = [];
        const add = (id, title, number) => {
            if (!id || seen.has(id)) return;
            seen.add(id);
            const label = (title || '(untitled)') + (number ? ` (${number})` : '');
            opts.push({
                id,
                label,
                selected: id === this.survivorId,
                rowClass: id === this.survivorId ? 'survivor-row selected' : 'survivor-row'
            });
        };
        add(this.seedArticle1Id, this.seedArticle1Title, this.seedArticle1Number);
        add(this.seedArticle2Id, this.seedArticle2Title, this.seedArticle2Number);
        for (const n of this.neighbors) {
            if (!this.selectedIds.has(n.candidateId)) continue;
            add(n.article1Id, n.article1Title, n.article1Number);
            add(n.article2Id, n.article2Title, n.article2Number);
        }
        return opts;
    }

    // Block submit until a survivor is chosen (keep-survivor mode only).
    get keepChoiceIncomplete() {
        return this.keepChoice === KEEP_SURVIVOR && !this.survivorId;
    }

    handleKeepChoiceChange(event) {
        this.keepChoice = event.detail.value;
        if (this.keepChoice !== KEEP_SURVIVOR) {
            this.survivorId = null;
        }
    }

    handleSurvivorPick(event) {
        this.survivorId = event.currentTarget.dataset.id;
    }

    handleToggle(event) {
        const id = event.currentTarget.dataset.id;
        if (this.selectedIds.has(id)) {
            this.selectedIds.delete(id);
        } else {
            this.selectedIds.add(id);
        }
        // Force re-render with updated rowClass / isSelected
        this.neighbors = this.neighbors.map((n) => ({
            ...n,
            isSelected: this.selectedIds.has(n.candidateId),
            rowClass: this.selectedIds.has(n.candidateId) ? 'neighbor-row selected' : 'neighbor-row'
        }));
    }

    handleExpand() {
        this.loadNeighbors(this.nextDepth);
    }

    handleCancel() {
        this.close(undefined);
    }

    async handleMergePairOnly() {
        this.isSubmitting = true;
        try {
            await approveMergeWithChoice({
                candidateId: this.seedCandidateId,
                keepChoice: this.keepChoice,
                survivorVersionId: this.isKeepSurvivor ? this.survivorId : null
            });
            this.close({ mode: 'pair', candidateIds: [this.seedCandidateId], keepChoice: this.keepChoice });
        } catch (e) {
            this.error = this.reduceError(e);
        } finally {
            this.isSubmitting = false;
        }
    }

    async handleMergeCluster() {
        if (this.selectedIds.size === 0) {
            return;
        }
        const candidateIds = [this.seedCandidateId, ...Array.from(this.selectedIds)];
        this.isSubmitting = true;
        try {
            await approveClusterMergeWithChoice({
                candidateIds,
                keepChoice: this.keepChoice,
                survivorVersionId: this.isKeepSurvivor ? this.survivorId : null
            });
            this.close({ mode: 'cluster', candidateIds, keepChoice: this.keepChoice });
        } catch (e) {
            this.error = this.reduceError(e);
        } finally {
            this.isSubmitting = false;
        }
    }

    reduceError(e) {
        if (!e) return 'Unknown error';
        if (typeof e === 'string') return e;
        if (e.body && e.body.message) return e.body.message;
        return e.message || 'Unknown error';
    }
}
