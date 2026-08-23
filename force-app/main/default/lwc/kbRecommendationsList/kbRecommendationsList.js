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
 * Presentational list of open recommendations for a single article, split
 * into an AI-fixable group (with the "Fix issues with AI" button) and a
 * "Needs human review" group (manual-only Duplication / Conflict / Freshness
 * rows with per-row Resolve / Edit-as-Draft actions).
 *
 * Extracted from knowledgeConsistencyChecker so the same markup renders from
 * both the tabset and the no-tabset (beta-off) host branches without the
 * markup drifting out of sync. The host owns decoration, filtering and the
 * Fix modal; this child is pure render + event dispatch.
 *
 * Inputs are the host's already-decorated + filtered rows. Each row carries:
 *   key, recId, dimension, recommendation, impact, impactBadgeClass,
 *   impactLabel, isDedup, isFreshness.
 *
 * Events (all bubble + composed so the host catches them regardless of which
 * branch slotted this child):
 *   - openfixmodal      → host opens the Fix-with-AI modal
 *   - resolvecandidate  → { detail: { recId } } host deep-links to Action Center
 *   - editasdraft       → host opens the raw Knowledge edit
 */
export default class KbRecommendationsList extends LightningElement {
    @api aiFixableIssues = [];
    @api manualOnlyIssues = [];
    // Fix-with-AI rewrites the article's CURRENT content, so it only makes
 // sense on the latest run. When a past run is selected the host sets
    // readOnly=true and the list renders read-only (status pills, no Fix button).
    // (LWC requires boolean public props to default to false, hence the
    // read-only framing rather than can-fix.)
    @api readOnly = false;

    get showFixButton() {
        return this.hasAiFixableIssues && !this.readOnly;
    }

    get hasAiFixableIssues() {
        return this.aiFixableIssues && this.aiFixableIssues.length > 0;
    }

    get hasManualOnlyIssues() {
        return this.manualOnlyIssues && this.manualOnlyIssues.length > 0;
    }

    handleOpenFixModal() {
        this.dispatchEvent(new CustomEvent('openfixmodal', { bubbles: true, composed: true }));
    }

    handleResolveCandidate(event) {
        const recId = event?.currentTarget?.dataset?.recId;
        this.dispatchEvent(
            new CustomEvent('resolvecandidate', {
                detail: { recId },
                bubbles: true,
                composed: true
            })
        );
    }

    handleEditAsDraft() {
        this.dispatchEvent(new CustomEvent('editasdraft', { bubbles: true, composed: true }));
    }
}
