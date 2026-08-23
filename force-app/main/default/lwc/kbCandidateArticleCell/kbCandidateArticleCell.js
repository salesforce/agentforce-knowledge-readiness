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
import { LightningElement, api, track } from 'lwc';
import getArticleDetail from '@salesforce/apex/DuplicateCandidateController.getArticleDetail';

export default class KbCandidateArticleCell extends LightningElement {
    @api articleId;
    @api title;
 // inside lightning-datatable, cells clip overflow so the absolutely-
    // positioned hover popover gets cut off and never shows. Callers embedding
    // this cell in a datatable set disable-popover so we fall back to the link's
    // native title tooltip. Plain-table callers leave it false and keep the rich
    // popover.
    @api disablePopover = false;
 // opt-in multi-line title. Default keeps the single-line ellipsis
    // truncation; the Duplicates queue sets
    // allow-wrap so long article titles wrap across lines in the narrower
    // Article A/B columns instead of being clipped.
    @api allowWrap = false;

    get linkClass() {
        return this.allowWrap ? 'article-link article-link_wrap' : 'article-link';
    }

 // review — native title tooltip only when the text is actually clipped
    // (single-line ellipsis mode). When allowWrap is on the full title is already
    // visible in the cell, so a title attribute duplicates it and some screen
    // readers (JAWS) announce the link twice. Independent of disablePopover: the
    // datatable callers still rely on the title as their popover substitute when
    // NOT wrapping, so only the wrapping case drops it.
    get titleTooltip() {
        return this.allowWrap ? null : this.title;
    }

    @track detail;
    @track isLoading = false;
    @track showPopover = false;
    _loaded = false;

    get recordUrl() {
        return this.articleId ? `/lightning/r/Knowledge__kav/${this.articleId}/view` : '#';
    }

    get popoverLabel() {
        return `Article details for ${this.title || 'this article'}`;
    }

    get formattedDate() {
        if (!this.detail || !this.detail.lastModifiedDate) {
            return '';
        }
        try {
            return new Date(this.detail.lastModifiedDate).toLocaleString();
        } catch {
            return this.detail.lastModifiedDate;
        }
    }

    async handleMouseEnter() {
        if (this.disablePopover) {
            return;
        }
        this.showPopover = true;
        if (this._loaded || !this.articleId) {
            return;
        }
        this.isLoading = true;
        try {
            this.detail = await getArticleDetail({ articleVersionId: this.articleId });
            this._loaded = true;
        } catch {
            this.detail = null;
        } finally {
            this.isLoading = false;
        }
    }

    handleMouseLeave() {
        this.showPopover = false;
    }

    handleLinkClick(event) {
        // Prevent the surrounding row click from intercepting (if any).
        event.stopPropagation();
    }
}
