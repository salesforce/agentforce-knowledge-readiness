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
import { LightningElement, api, wire, track } from 'lwc';
import getRecentRuns from '@salesforce/apex/KBAssessmentController.getRecentRuns';
import getRecentRunsLive from '@salesforce/apex/KBAssessmentController.getRecentRunsLive';

/**
 * searchable per-assessment run filter (variant B, the bake-off winner).
 *
 * A combobox-style trigger that opens a panel with a search field pinned at the
 * top and the filtered run list below. Each run renders a rich label
 * ({name} (RUN-####) · {date} — {N} articles ({score})); "All assessments" is
 * pinned at the top and resets the filter. Selecting a run emits
 * `runselect` ({ runId }) so the host can scope its sub-screens; runId is null
 * for "All assessments".
 *
 * Reusable across surfaces — the Assessments page (kbAssessmentHistory) and the
 * Action Center (kbCandidateInbox) both host it and wire `runselect` to their
 * own run-scoping state. `selected-run-id` lets a host seed/control the
 * selection (e.g. the Action Center's c__runId deep-link).
 */
// key is a stable non-null string for the for:each (LWC keys must be string/
// number); value stays null so handlePick resolves it to the "All" reset.
const ALL_OPTION = { key: '__all__', value: null, label: 'All assessments' };

export default class KbRunFilter extends LightningElement {
    @track runs = [];
    @track search = '';
    @track open = false;
    @track activeIndex = -1; // keyboard-focused option index into `options`

    _selectedRunId = null;

    // Host-controlled selection (optional). Lets a parent seed the filter —
    // e.g. the Action Center's "View Actions" deep-link (c__runId) — or reset it.
    @api
    get selectedRunId() {
        return this._selectedRunId;
    }
    set selectedRunId(value) {
        const next = value || null;
        const changed = next !== this._selectedRunId;
        this._selectedRunId = next;
        // A host can seed a run via deep-link (the Action Center's c__runId
        // "View Actions" path) that was created after our cacheable wire's LDS
        // snapshot. If the seeded id isn't in the cached list, triggerLabel
        // would silently fall back to "All assessments" — so pull a fresh,
 // cache-bypassing list to make the selection resolve. See.
        if (changed && next && !this.runs.some((r) => r.runId === next)) {
            this.refreshLive();
        }
    }

    // How many recent runs to offer. Default 30 mirrors both former hosts.
    @api limitSize = 30;

    // The cacheable wire gives a fast first paint on cold load. Its LDS cache
    // can go stale across tab navigation (a run created on another tab is
 // absent until a browser refresh—); refreshLive bypasses it on the
    // moments freshness matters (panel open, deep-link miss).
    @wire(getRecentRuns, { limitSize: '$limitSize' })
    wiredRuns({ data }) {
        if (data) {
            this.runs = data.map((r) => this._toOption(r));
        }
    }

    _toOption(r) {
        return {
            key: r.runId,
            value: r.runId,
            runId: r.runId,
            label: this._runLabel(r),
            // Searchable text: user name (Run_Name__c) + auto-number Name +
 // who ran it, so a user can filter by the person too.
            searchText: `${r.userRunName || ''} ${r.runName || ''} ${r.ranBy || ''}`.toLowerCase()
        };
    }

    // Non-cacheable read that bypasses the LDS cache the @wire shares. A
    // non-cacheable Apex method can't be wired, so it's called imperatively —
 // mirroring kbAssessmentHistory's getRecentRunsLive layer.
    async refreshLive() {
        try {
            const fresh = await getRecentRunsLive({ limitSize: this.limitSize });
            if (Array.isArray(fresh)) {
                this.runs = fresh.map((r) => this._toOption(r));
            }
        } catch {
            // Non-fatal: the cacheable wire still backs the list. A stale
            // dropdown is better than a thrown error in the host.
        }
    }

    _runLabel(r) {
        const score = Math.round(r.overallScore ?? 0);
        // Anchor the label on when the run STARTED — that's what users remember
        // (a run can take days; the finish time is rarely the mental handle).
 // scanStartTime is the true scoring-start stamp; fall back to
 // createdDate for pre- runs. Old behaviour keyed off completedAt and
        // showed "Unknown date" for the whole time a run was in flight.
        const started = r.scanStartTime || r.createdDate;
        const date = started ? this._fmtDate(started) : 'Unknown date';
        // Show BOTH the user-given name (Run_Name__c) and the auto-number Name
        // (RUN-####) when present; fall back gracefully when either is blank.
        const userName = (r.userRunName && r.userRunName.trim()) || '';
        const autoNum = r.runName || '';
        let namePart;
        if (userName && autoNum) {
            namePart = `${userName} (${autoNum})`;
        } else {
            namePart = userName || autoNum;
        }
        const prefix = namePart ? `${namePart} · ` : '';
 // append "· by <who ran it>" to match the record-page run picker
        // and the All Assessments list. Omitted when the owner name is absent.
        const ranBy = (r.ranBy && r.ranBy.trim()) || '';
        const bySuffix = ranBy ? ` · by ${ranBy}` : '';
        return `${prefix}${date} — ${r.totalArticles ?? 0} articles (${score})${bySuffix}`;
    }

    _fmtDate(value) {
        return new Date(value).toLocaleDateString(undefined, {
            month: 'short',
            day: 'numeric',
            year: 'numeric'
        });
    }

    // Filter the run list by the search term; always pin "All assessments".
    // Stamps a11y/keyboard state per option (active highlight + aria-selected).
    get options() {
        const t = (this.search || '').trim().toLowerCase();
        const matches = t
            ? this.runs.filter((r) => r.searchText.includes(t))
            : this.runs;
        const all = [ALL_OPTION, ...matches];
        return all.map((o, i) => ({
            ...o,
            active: i === this.activeIndex,
            ariaSelected: i === this.activeIndex ? 'true' : 'false',
            optionClass:
                'slds-media slds-listbox__option slds-listbox__option_plain slds-media_small' +
                (i === this.activeIndex ? ' slds-has-focus' : '')
        }));
    }

    get triggerLabel() {
        if (!this._selectedRunId) return ALL_OPTION.label;
        const hit = this.runs.find((r) => r.runId === this._selectedRunId);
        return hit ? hit.label : ALL_OPTION.label;
    }

    toggle() {
        this.open = !this.open;
        if (this.open) {
            this.search = '';
            this.activeIndex = -1;
            // Opening the panel is the user's intent to pick a run — fetch a
            // cache-bypassing list so a run created on another tab shows up
 // without a browser refresh. The existing list stays
            // rendered until the fresh one resolves, so there's no flicker.
            this.refreshLive();
        }
    }

    handleSearch(event) {
        this.search = event.target.value;
        this.activeIndex = -1; // reset highlight as the filtered list changes
    }

 // Keyboard nav over the option list (a11y — review). Arrow up/down move
    // the highlight, Enter selects the active option, Escape closes the panel.
    handleKeydown(event) {
        if (!this.open) return;
        const opts = this.options;
        switch (event.key) {
            case 'ArrowDown':
                event.preventDefault();
                this.activeIndex = Math.min(this.activeIndex + 1, opts.length - 1);
                break;
            case 'ArrowUp':
                event.preventDefault();
                this.activeIndex = Math.max(this.activeIndex - 1, 0);
                break;
            case 'Enter':
                if (this.activeIndex >= 0 && this.activeIndex < opts.length) {
                    event.preventDefault();
                    this.selectOption(opts[this.activeIndex].value);
                }
                break;
            case 'Escape':
                this.open = false;
                break;
            default:
                break;
        }
    }

    // Close the panel when focus leaves the component entirely. relatedTarget
    // is the element gaining focus; if it's still inside this component (e.g.
    // tabbing from the search field to an option) we keep the panel open.
    // handlePick uses onmousedown so a click-select fires before this blur.
    handleBlur(event) {
        const next = event.relatedTarget;
        if (next && this.template.contains(next)) {
            return;
        }
        this.open = false;
    }

    handlePick(event) {
        this.selectOption(event.currentTarget.dataset.runid || null);
    }

    // Shared select path for both mouse (handlePick) and keyboard (Enter).
    selectOption(runId) {
        this._selectedRunId = runId || null;
        this.open = false;
        this.dispatchEvent(
            new CustomEvent('runselect', { detail: { runId: this._selectedRunId } })
        );
    }
}
