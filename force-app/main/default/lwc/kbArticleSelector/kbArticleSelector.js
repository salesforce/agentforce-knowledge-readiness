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
import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getFilteredArticles from '@salesforce/apex/KBAssessmentController.getFilteredArticles';
import getArticleById from '@salesforce/apex/KBAssessmentController.getArticleById';
import getArticlesByIds from '@salesforce/apex/KBAssessmentController.getArticlesByIds';
import getArticleTypeOptions from '@salesforce/apex/KBAssessmentController.getArticleTypeOptions';
import getSelectedContentFieldColumns from '@salesforce/apex/KBAssessmentController.getSelectedContentFieldColumns';
import getFilterableFields from '@salesforce/apex/KBKnowledgeFieldDescribeService.getFilterableFields';
import getRunArticleCap from '@salesforce/apex/KBAssessmentController.getCloneArticleCap';

// Per-type operator vocabulary mirroring KBFilterClauseCompiler. Stable wire
// constants — same strings server-side. isNull / isNotNull intentionally not
// surfaced via picklist labels yet (cuts UX scope; user can add later by
// typing the operator). Keep in sync with KBFilterClauseCompiler.STRING_OPS
// etc.
const OPERATORS_BY_TYPE_GROUP = {
    string: [
        { label: 'Equals', value: 'eq' },
        { label: 'Not Equals', value: 'ne' },
        { label: 'Contains', value: 'contains' },
        { label: 'Starts With', value: 'startsWith' },
        { label: 'Is Null', value: 'isNull' },
        { label: 'Is Not Null', value: 'isNotNull' }
    ],
    number: [
        { label: '=', value: 'eq' },
        { label: '!=', value: 'ne' },
        { label: '>', value: 'gt' },
        { label: '>=', value: 'gte' },
        { label: '<', value: 'lt' },
        { label: '<=', value: 'lte' },
        { label: 'Is Null', value: 'isNull' },
        { label: 'Is Not Null', value: 'isNotNull' }
    ],
    date: [
        { label: '=', value: 'eq' },
        { label: '!=', value: 'ne' },
        { label: '>=', value: 'gte' },
        { label: '<=', value: 'lte' },
        { label: 'Last N Days', value: 'lastNDays' },
        { label: 'Is Null', value: 'isNull' },
        { label: 'Is Not Null', value: 'isNotNull' }
    ],
    boolean: [
        { label: 'Equals', value: 'eq' },
        { label: 'Is Null', value: 'isNull' },
        { label: 'Is Not Null', value: 'isNotNull' }
    ],
    multipicklist: [
        { label: 'Includes', value: 'includes' },
        { label: 'Excludes', value: 'excludes' },
        { label: 'Is Null', value: 'isNull' },
        { label: 'Is Not Null', value: 'isNotNull' }
    ]
};

const STRING_TYPES = new Set(['STRING', 'PICKLIST', 'EMAIL', 'PHONE', 'URL', 'COMBOBOX']);
const NUMBER_TYPES = new Set(['INTEGER', 'DOUBLE', 'CURRENCY', 'PERCENT', 'LONG']);
const DATE_TYPES = new Set(['DATE', 'DATETIME', 'TIME']);

function typeGroup(displayType) {
    if (!displayType) return 'string';
    const t = displayType.toUpperCase();
    if (STRING_TYPES.has(t)) return 'string';
    if (NUMBER_TYPES.has(t)) return 'number';
    if (DATE_TYPES.has(t)) return 'date';
    if (t === 'BOOLEAN') return 'boolean';
    if (t === 'MULTIPICKLIST') return 'multipicklist';
    return 'string';
}

const NULL_OPERATORS = new Set(['isNull', 'isNotNull']);
const LIST_OPERATORS = new Set(['includes', 'excludes']);

// every text column (base or dynamic) goes through the
// 'contentCell' custom type, which clamps long values to ~5 lines and
// shows a "Show more" toggle when the cell overflows. Short cells render
// identically to a plain text cell — the toggle is suppressed at runtime
// based on the actual value length, so this is safe to apply blindly.
// Title stays 'url' (clickable link) and Last Modified stays 'date'.
const BASE_COLUMNS = [
    { label: 'Article Number', fieldName: 'articleNumber', type: 'contentCell', sortable: true },
    { label: 'Title', fieldName: 'articleUrl', type: 'url', sortable: true, wrapText: true,
      typeAttributes: { label: { fieldName: 'title' }, target: '_blank', tooltip: { fieldName: 'title' } } },
    { label: 'Summary', fieldName: 'summary', type: 'contentCell', wrapText: true },
    { label: 'Last Modified', fieldName: 'lastModifiedDate', type: 'date', sortable: true,
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    { label: 'Status', fieldName: 'publishStatus', type: 'contentCell' }
];

// Prefix used to flatten ArticleWrapper.contentFieldValues into top-level
// row keys for lightning-datatable, which can't drill into nested maps via
// `fieldName`. Picked to be safe across Salesforce field naming rules
// (no field can start with "cf_").
const CONTENT_COL_PREFIX = 'cf_';

const PAGE_SIZE = 25;
const DEBOUNCE_MS = 300;

const BASKET_COLUMNS = [
    { label: 'Article Number', fieldName: 'articleNumber', type: 'text' },
    { label: 'Title', fieldName: 'title', type: 'text', wrapText: true },
    {
        type: 'button-icon',
        fixedWidth: 50,
        typeAttributes: {
            iconName: 'utility:close',
            name: 'remove',
            alternativeText: 'Remove',
            title: 'Remove from selection',
            variant: 'bare'
        }
    }
];

const BASKET_EMPTY_DEFAULT =
    'No articles selected yet. Pick rows from the table to add them here.';
const BASKET_EMPTY_MATCHING =
    'All matching articles selected. Use the banner above to clear or refine.';

export default class KbArticleSelector extends LightningElement {
    _preselectedArticleId = null;
    _pinnedArticle = null;
    _connected = false;

 // plural sibling of the single-scalar preselection above, used by the
    // clone flow to seed the basket with a whole run's worth of articles. The
    // rows are pinned to the top, added to _rowCache (so the preview list can
    // resolve their titles), and one selectionchange is fired. _multiPreselDone
    // guards against a double fetch: both this setter and connectedCallback's
    // microtask can fire for the same value when the parent sets it just after
    // openModal mounts the (hidden) selector.
    _preselectedArticleIds = null;
    _pinnedArticles = [];
    _multiPreselDone = false;

    // Session-lifetime cache of every row we've ever seen, keyed by article id.
    // Lets the basket pane render rows that have fallen out of the active
    // filter view. Not @track — only the derived getters touch it, and
    // they're recomputed when the underlying tracked state changes.
    _rowCache = new Map();

 // (round 2): guard against lightning-datatable's programmatic
    // `rowselection` echo. When we swap `this.articles`, the datatable
    // re-renders and re-applies `selected-rows`, which makes it fire a
    // SPURIOUS rowselection reflecting only the new page's checked rows
    // (frequently empty). handleRowSelection can't tell that echo from a real
    // user click, so without this flag it treats the previous picks as
    // "visible-and-now-unchecked" and drops them — the inconsistent
    // "sometimes keeps, sometimes replaces" behaviour. We set the flag before
    // every articles reassignment and clear it once the re-render has settled
    // (see renderedCallback), so only genuine user clicks mutate the
    // selection. Not @track — purely an internal event gate, never rendered.
    _suppressRowSelection = false;

    @api
    get preselectedArticleId() {
        return this._preselectedArticleId;
    }
    set preselectedArticleId(value) {
        const isNewValue = value !== this._preselectedArticleId;
        this._preselectedArticleId = value;
        // Reset pin state when the value changes (e.g., user navigates from
        // article A to KB Assessment, back, then from article B). Without this,
        // a stale _pinnedArticle would block the new article from pinning.
        if (isNewValue) {
            this._pinnedArticle = null;
        }
        if (value && this._connected) {
            this.triggerPreselection();
        }
    }

    triggerPreselection() {
 // the user-facing publish-status filter was removed and
        // the server now always queries Online articles. A preselected Draft
        // / Archived article won't pin in the selector — that's the
        // accepted trade-off documented on the issue.
        this.offset = 0;
        return this.loadPreselectedArticle().then(() => this.loadArticles());
    }

 // plural preselection (clone flow). Mirrors preselectedArticleId.
    @api
    get preselectedArticleIds() {
        return this._preselectedArticleIds;
    }
    set preselectedArticleIds(value) {
        const isNewValue =
            JSON.stringify(value) !== JSON.stringify(this._preselectedArticleIds);
        this._preselectedArticleIds = value;
        if (isNewValue) {
            this._pinnedArticles = [];
            this._multiPreselDone = false;
        }
        if (value && value.length && this._connected && !this._multiPreselDone) {
            this.triggerMultiPreselection();
        }
    }

    triggerMultiPreselection() {
        this.offset = 0;
        return this.loadPreselectedArticles().then(() => this.loadArticles());
    }

    async loadPreselectedArticles() {
        const ids = this._preselectedArticleIds || [];
        try {
            const rows = await getArticlesByIds({ articleVersionIds: ids });
            const flat = (rows || []).map((r) => this.flattenRow(r));
            this._pinnedArticles = flat;
            // Reassigning articles re-renders the datatable → spurious
            // rowselection echo. Suppress it (see _suppressRowSelection).
            this._suppressRowSelection = true;
            const pinnedIds = new Set(flat.map((r) => r.id));
            this.articles = [
                ...flat,
                ...this.articles.filter((a) => !pinnedIds.has(a.id))
            ];
            // Seed the row cache so the basket / preview list can resolve titles
            // for rows that fall out of the active filter page.
            flat.forEach((r) => this._rowCache.set(r.id, r));
            // Select the FULL requested id set, not just the rows that hydrated:
            // the ids drive the run, and getArticlesByIds may return fewer rows
            // than requested (a since-deleted version, or FLS hiding a field).
            // Preview rows the cache can't resolve fall back to an "Article <id>"
            // stub (see dispatchSelectionChange) rather than dropping the pick.
            this.selectedIds = [...ids];
            this._multiPreselDone = true;
            this.dispatchSelectionChange();
        } catch (e) {
 // (review) — getArticlesByIds throws if the running user lacks
            // FLS on ANY selected field. Do NOT silently empty the basket: the
            // ids still drive a valid run, so select them (unhydrated → stub
            // titles) and tell the host so it can surface a warning rather than
            // opening an empty, unexplained modal.
            this._pinnedArticles = [];
            this.selectedIds = [...ids];
            this._multiPreselDone = true;
            this.dispatchSelectionChange();
            this.dispatchEvent(
                new CustomEvent('preselectionerror', {
                    detail: { count: ids.length }
                })
            );
            // eslint-disable-next-line no-console
            console.warn('getArticlesByIds failed:', e);
        }
    }

 // assessment name from the details step. Shown as an all-caps
    // "ASSESSMENT · <name>" eyebrow above the heading — the golden-thread
    // reminder, styled so it clearly reads as a user-set name, not a topic.
    @api assessmentName;

    get hasAssessmentName() {
        return !!(this.assessmentName && this.assessmentName.trim());
    }

    get assessmentEyebrow() {
        return this.hasAssessmentName ? `Assessment · ${this.assessmentName.trim()}` : '';
    }

    @track articles = [];
    @track selectedIds = [];
    @track isLoading = false;
    @track error = null;

 // collapsible split-view. The basket (right pane) can be collapsed
    // to a thin rail via a control on the separator, reclaiming horizontal
    // space for the results table — valuable in the tight modal variant
 // Default expanded; mirrors the standard Salesforce split-view.
    @track basketCollapsed = false;

    // Filters
    @track titleSearch = '';
    @track articleNumber = '';
    @track articleType = '';
    @track filterLogic = 'AND';   // legacy fallback when filterFormula is blank
    @track filterClauses = [];
    @track filterFormula = '';     // user-entered formula
    @track formulaError = null;    // inline validation message

    // Draft clause being composed in the "add clause" row. Reset after each
    // successful Add Filter click. Field/operator/value/values shape mirrors
    // the persisted FilterClause; type is local-only state.
    @track draftField = '';
    @track draftFieldType = '';
    @track draftOperator = '';
    @track draftValue = '';
    @track draftValues = [];
    @track availableFields = [];   // populated from getFilterableFields wire

    // Pagination
    @track totalCount = 0;
    @track offset = 0;
    @track hasMore = false;

    // Max articles a single assessment run can cover (server-enforced; a
    // select-all above this is rejected at submit). Wired so the banner can warn
    // upfront instead of letting the user submit and hit the error.
    runArticleCap = 10000;
    @wire(getRunArticleCap)
    wiredRunCap({ data }) {
        if (data) {
            this.runArticleCap = data;
        }
    }

    // Matching-filter (select-all) mode
    @track selectAllMatchingFilter = false;
    @track filterSnapshot = null;
    @track excludedIds = [];

    // Filter options
    @track articleTypeOptions = [];

    @track columns = BASE_COLUMNS;
    _debounceTimer;
    _contentFieldDescriptors = [];

    dslLogicOptions = [
        { label: 'AND', value: 'AND' },
        { label: 'OR', value: 'OR' }
    ];

    /**
     * Field display list: alphabetically sorted, with colliding labels
     * disambiguated by their apiName. Salesforce labels several fields
     * identically ("User ID"); only the colliding ones get a suffix —
 * unique labels are left clean.
     */
    get decoratedFields() {
        const fields = this.availableFields || [];
        const counts = {};
        fields.forEach(f => {
            const l = f.label || f.apiName;
            counts[l] = (counts[l] || 0) + 1;
        });
        return fields
            .map(f => {
                const base = f.label || f.apiName;
                const suffix = f.apiName;
                return {
                    apiName: f.apiName,
                    displayLabel: counts[base] > 1 ? `${base} (${suffix})` : base
                };
            })
            .sort((a, b) => a.displayLabel.localeCompare(b.displayLabel));
    }

    /**
     * Field combobox options derived from the describe-driven wire. Falls
     * back to the legacy hardcoded list if the wire returns nothing — so
     * orgs without the new Apex deployed (or tests that haven't seeded the
     * wire) still see a usable picker.
     */
    get dslFieldOptions() {
        const decorated = this.decoratedFields;
        if (decorated.length > 0) {
            return decorated.map(f => ({ label: f.displayLabel, value: f.apiName }));
        }
        return [
            { label: 'Article Number', value: 'ArticleNumber' },
            { label: 'Language', value: 'Language' },
            { label: 'Last Modified Date', value: 'LastModifiedDate' },
            { label: 'Summary', value: 'Summary' },
            { label: 'Title', value: 'Title' }
        ];
    }

    /**
     * Operator options for the draft clause, scoped to the chosen field's
     * type group. Empty when no field is chosen yet.
     */
    get dslOperatorOptions() {
        if (!this.draftFieldType) return [];
        const group = typeGroup(this.draftFieldType);
        return OPERATORS_BY_TYPE_GROUP[group] || OPERATORS_BY_TYPE_GROUP.string;
    }

    /**
     * Per-type input rendering hints — the template uses these to pick
     * between text / number / date / checkbox / dual-listbox.
     */
    get isNullOperator() { return NULL_OPERATORS.has(this.draftOperator); }
    get isListOperator() { return LIST_OPERATORS.has(this.draftOperator); }
    get isDateField() { return typeGroup(this.draftFieldType) === 'date'; }
    get isNumberField() { return typeGroup(this.draftFieldType) === 'number'; }
    get isBooleanField() { return typeGroup(this.draftFieldType) === 'boolean'; }
    get isLastNDays() { return this.draftOperator === 'lastNDays'; }
    get isMultipicklistField() { return typeGroup(this.draftFieldType) === 'multipicklist'; }
    get isPicklistField() {
        return (this.draftFieldType || '').toUpperCase() === 'PICKLIST';
    }

    get draftFieldDescriptor() {
        return this.availableFields.find(f => f.apiName === this.draftField);
    }

    /**
     * Picklist value options for the draft clause's value combobox.
     * Multipicklist uses dual-listbox via this same list. Empty for
     * non-picklist fields.
     */
    get draftPicklistOptions() {
        const fd = this.draftFieldDescriptor;
        if (!fd || !Array.isArray(fd.picklistValues)) return [];
        return fd.picklistValues
            .filter(p => p.active !== false)
            .map(p => ({ label: p.label || p.value, value: p.value }));
    }

    /**
     * Numbered, render-friendly view of filterClauses. The template loops
     * over this — the number is 1-based to match the formula references.
     */
    get numberedClauses() {
        const labelByApi = new Map(this.decoratedFields.map(f => [f.apiName, f.displayLabel]));
        return this.filterClauses.map((c, i) => {
            const fieldLabel = labelByApi.get(c.field) || c.field;
            const valueDisplay = NULL_OPERATORS.has(c.operator)
                ? ''
                : (Array.isArray(c.values) && c.values.length > 0 ? c.values.join(', ') : (c.value || ''));
            return {
                id: c.id,
                number: i + 1,
                summary: `${fieldLabel} ${c.operator}${valueDisplay ? ' ' + valueDisplay : ''}`
            };
        });
    }

    get hasDraftClause() {
        if (!this.draftField || !this.draftOperator) return false;
        if (this.isNullOperator) return true;
        if (this.isListOperator) return Array.isArray(this.draftValues) && this.draftValues.length > 0;
        return this.draftValue != null && this.draftValue !== '';
    }

    /**
     * Show the legacy AND/OR combobox only when the user hasn't typed a
     * formula. Once they type one, the formula owns clause logic.
     */
    get showLegacyLogicCombobox() {
        return this.filterClauses.length > 1 && !(this.filterFormula && this.filterFormula.trim());
    }

    /**
     * Live placeholder for the formula input — shows the implicit default
     * (`1 AND 2 AND 3`) so users understand what they're overriding.
     */
    get formulaPlaceholder() {
        const n = this.filterClauses.length;
        if (n <= 1) return 'e.g. 1';
        return Array.from({ length: n }, (_, i) => i + 1).join(' AND ');
    }

    booleanValueOptions = [
        { label: 'True', value: 'true' },
        { label: 'False', value: 'false' }
    ];

    get addFilterDisabled() {
        return !this.hasDraftClause;
    }

    get applyFiltersDisabled() {
        return !!this.formulaError;
    }

    get isNullOperatorDisabledByMissingField() {
        return !this.draftField;
    }

    @wire(getFilterableFields)
    wiredFilterableFields({ data, error }) {
        // Failure branch leaves availableFields empty — the hardcoded fallback
        // in dslFieldOptions keeps the picker usable. We log the error so an
        // Apex-class access denial (e.g. a user whose permission set is missing
 // class access to KBKnowledgeFieldDescribeService,) leaves a trace
        // instead of failing invisibly — the symptom there is empty operators
        // and no value-type input because field types never load.
        if (Array.isArray(data) && data.length > 0) {
            this.availableFields = data;
        } else if (error) {
            // eslint-disable-next-line no-console
            console.error('kbArticleSelector: getFilterableFields failed', error);
        }
    }

    @wire(getSelectedContentFieldColumns)
    wiredContentFieldColumns({ data }) {
        // No error branch: failure to load dynamic columns just leaves
        // the table at the BASE 5 columns. The picker still works.
        if (Array.isArray(data) && data.length > 0) {
            this._contentFieldDescriptors = data;
            this.columns = [
                ...BASE_COLUMNS,
                ...data.map((d) => ({
                    label: d.label,
                    fieldName: CONTENT_COL_PREFIX + d.apiName,
                    // Custom type registered by c-kb-article-selector-datatable;
 // clamps long values to ~5 lines with a Show more toggle.
                    type: 'contentCell',
                    wrapText: true
                }))
            ];
            // Re-flatten any rows already loaded so the new columns light up
            // even if the wire resolves after the first article fetch.
            if (this.articles && this.articles.length > 0) {
                this.articles = this.articles.map((row) => this.flattenRow(row));
            }
        }
    }

    /**
 * (round 2): clear the rowselection suppression once the datatable
     * has re-rendered with the new data and re-applied `selected-rows`.
     *
     * Timing rationale — why this ignores the spurious echo but NOT the next
     * genuine click:
     *  - The datatable's programmatic `rowselection` echo fires as a direct
     *    consequence of the data/selected-rows swap, i.e. synchronously during
     *    (or in a microtask enqueued from) the child's render. Both land
     *    BEFORE the clear we schedule here: a synchronous echo runs before this
     *    parent renderedCallback executes at all, and a microtask echo was
     *    enqueued during the child's render — earlier than the microtask we
     *    enqueue below — so it drains first. Either way handleRowSelection sees
     *    the flag still set and bails out.
     *  - A genuine user click is a later, separate macrotask. Microtasks always
     *    drain before the next macrotask, so the flag is back to false by the
     *    time the user actually checks/unchecks a row — that click reconciles
     *    normally. The microtask defer (not a synchronous clear) is what buys
     *    the safety margin for the microtask-deferred echo.
     *
     * renderedCallback fires on every render; we only schedule a clear when the
     * flag is set, and the set→false write is idempotent, so repeated fires in
     * the same tick are harmless. A new load can only re-arm the flag from a
     * macrotask, which never interleaves with this synchronous render + its
     * trailing microtask — so we never clear a freshly-armed flag.
     */
    renderedCallback() {
        if (this._suppressRowSelection) {
            Promise.resolve().then(() => {
                this._suppressRowSelection = false;
            });
        }
    }

    connectedCallback() {
        this._connected = true;
        this.loadArticleTypes();
        // Wait one microtask so @api setters from the parent fire first —
        // otherwise we'd skip the preselection branch entirely.
        queueMicrotask(() => {
            if (this._preselectedArticleIds && this._preselectedArticleIds.length) {
                this.triggerMultiPreselection();
            } else if (this._preselectedArticleId) {
                this.triggerPreselection();
            } else {
                this.loadArticles();
            }
        });
    }

    async loadPreselectedArticle() {
        try {
            const article = await getArticleById({ articleVersionId: this._preselectedArticleId });
            if (!article || !article.id) {
                // Article not found or not accessible — load proceeds without pin
                return;
            }
            // flattenRow sets articleUrl from row.id — no need to re-set here
            const row = this.flattenRow(article);
            this._pinnedArticle = row;
            // Reassigning articles re-renders the datatable → spurious
            // rowselection echo. Suppress it (see _suppressRowSelection).
            this._suppressRowSelection = true;
            this.articles = [row, ...this.articles.filter(a => a.id !== row.id)];
            this._rowCache.set(row.id, row);
            this.selectedIds = [this._preselectedArticleId];
            this.dispatchSelectionChange();
        } catch (e) {
            // Pin failed but we still proceed — loadArticles will run via .then()
            // eslint-disable-next-line no-console
            console.warn('getArticleById failed:', e);
        }
    }

    /**
     * Copy each entry of ArticleWrapper.contentFieldValues into a top-level
     * `cf_<apiName>` key so lightning-datatable can render it via fieldName.
     * No-op when the wrapper has no contentFieldValues map.
     */
    flattenRow(row) {
        if (!row) return row;
        const flat = { ...row };
        if (row.contentFieldValues) {
            for (const apiName of Object.keys(row.contentFieldValues)) {
                flat[CONTENT_COL_PREFIX + apiName] = row.contentFieldValues[apiName];
            }
        }
        flat.articleUrl = row.id ? `/lightning/r/Knowledge__kav/${row.id}/view` : null;
        return flat;
    }

    async loadArticleTypes() {
        try {
            const types = await getArticleTypeOptions();
            this.articleTypeOptions = [
                { label: 'All Types', value: '' },
                ...types.map(t => ({ label: t.label, value: t.value }))
            ];
        } catch {
            // Non-critical — filter will just be hidden
            this.articleTypeOptions = [];
        }
    }

    async loadArticles() {
        this.isLoading = true;
        this.error = null;
        // Every articles reassignment below (offset-0 page replace, load-more
        // append, or the error-branch reset) re-renders the datatable and
        // provokes its spurious rowselection echo. Arm the suppression now so
        // handleRowSelection ignores that echo; renderedCallback clears the
        // flag once the new data has settled, restoring genuine-click handling.
        this._suppressRowSelection = true;
        try {
 // publishStatus omitted from the payload — Apex
            // buildBaseWhere defaults to 'Online' when no value is passed.
 // filterFormula sent through; server falls back to
            // filterLogic when it's blank/null.
            const filterJSON = JSON.stringify({
                titleSearch: this.titleSearch || null,
                articleNumber: this.articleNumber || null,
                articleType: this.articleType || null,
                filterLogic: this.filterLogic,
                filterFormula: (this.filterFormula || '').trim() || null,
                filterClauses: this.filterClauses,
                pageSize: PAGE_SIZE,
                offset: this.offset
            });

            const result = await getFilteredArticles({ filterJSON });
 // exclude any pinned rows (single-scalar or plural clone
            // preselection) from the fetched page so they aren't duplicated.
            const pinnedIdSet = new Set(this._pinnedArticles.map((p) => p.id));
            if (this._preselectedArticleId) {
                pinnedIdSet.add(this._preselectedArticleId);
            }
            const flattened = (result.articles || [])
                .map((row) => this.flattenRow(row))
                .filter((row) => !pinnedIdSet.has(row.id));
            if (this.offset === 0) {
                const pins = this._pinnedArticles.length
                    ? this._pinnedArticles
                    : this._pinnedArticle
                    ? [this._pinnedArticle]
                    : [];
                this.articles = pins.length ? [...pins, ...flattened] : flattened;
            } else {
                this.articles = [...this.articles, ...flattened];
            }
            // Populate the row cache so the basket pane can render rows that
 // have fallen out of the active filter view.
            for (const row of flattened) {
                if (row && row.id) {
                    this._rowCache.set(row.id, row);
                }
            }
            if (this._pinnedArticle && this._pinnedArticle.id) {
                this._rowCache.set(this._pinnedArticle.id, this._pinnedArticle);
            }
            for (const p of this._pinnedArticles) {
                if (p && p.id) {
                    this._rowCache.set(p.id, p);
                }
            }
            this.totalCount = result.totalCount;
            this.hasMore = result.hasMore;
 // the formula couldn't be applied and the server fell back to
            // AND-of-all-clauses — a different result set. Warn once per search
            // (offset 0), not on every "load more" page.
            if (this.offset === 0 && result.formulaFallbackApplied) {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Filter formula not applied',
                        message:
                            'Your filter formula was invalid, so all clauses were combined with AND instead. Showing those results.',
                        variant: 'warning',
                        mode: 'sticky'
                    })
                );
            }
        } catch (e) {
            this.error = this.reduceErrors(e);
            if (this.offset === 0) {
                this.articles = [];
            }
        } finally {
            this.isLoading = false;
        }
    }

    get hasArticles() {
        return !this.isLoading && !this.error && this.articles.length > 0;
    }

    get showNoArticles() {
        return !this.isLoading && !this.error && this.articles.length === 0;
    }

    get effectiveSelectedCount() {
        if (!this.selectAllMatchingFilter) {
            return this.selectedIds.length;
        }
        return Math.max(this.totalCount - this.excludedIds.length, 0);
    }

    get effectiveSelectedRowIds() {
        if (!this.selectAllMatchingFilter) {
            return this.selectedIds;
        }
        if (this.excludedIds.length === 0) {
            return this.articles.map(a => a.id);
        }
        const excluded = new Set(this.excludedIds);
        return this.articles.map(a => a.id).filter(id => !excluded.has(id));
    }

    get isSelectionEmpty() {
        return this.effectiveSelectedCount === 0;
    }

    get selectionLabel() {
        const count = this.effectiveSelectedCount;
        return count === 0 ? 'No articles selected' : `${count} article${count !== 1 ? 's' : ''} selected`;
    }

    get articleCountLabel() {
        return `Showing ${this.articles.length} of ${this.totalCount} articles`;
    }

    get basketColumns() {
        return BASKET_COLUMNS;
    }

    /**
     * Selected rows projected through the session-lifetime row cache so
     * articles that have fallen out of the active filter still render in
     * the basket. Selected ids without a cache entry are surfaced as
     * title-only stubs — defensive fallback for deep-link / preselection
     * paths that haven't fetched the row yet.
     *
     * In matching-filter mode the basket stays empty: resolving the full id
     * list is a server roundtrip, and the active "all N matching" banner
     * already conveys the selection summary.
     */
    get basketRows() {
        if (this.selectAllMatchingFilter) {
            return [];
        }
        return this.selectedIds.map((id) => {
            const cached = this._rowCache.get(id);
            if (cached) {
                return cached;
            }
            return { id, title: `Article ${id}`, articleNumber: '' };
        });
    }

    get hasBasketRows() {
        return this.basketRows.length > 0;
    }

    get selectedBasketLabel() {
        return `Selected (${this.effectiveSelectedCount})`;
    }

    get basketEmptyMessage() {
        return this.selectAllMatchingFilter ? BASKET_EMPTY_MATCHING : BASKET_EMPTY_DEFAULT;
    }

 // ──: collapsible split-view derived state ───────────────────────────

    /**
     * Grid modifier class — collapsed swaps the 320px basket track for a thin
     * rail (just wide enough for the re-open control), handing the freed width
     * to the results table.
     */
    get selectorGridClass() {
        return this.basketCollapsed ? 'selector-grid selector-grid_collapsed' : 'selector-grid';
    }

    get isBasketExpanded() {
        return !this.basketCollapsed;
    }

    get basketToggleIcon() {
        // Chevron points "out" (right) to collapse, "in" (left) to expand —
        // matches the standard Salesforce split-view affordance.
        return this.basketCollapsed ? 'utility:chevronleft' : 'utility:chevronright';
    }

    get basketToggleLabel() {
        return this.basketCollapsed ? 'Expand selected articles panel' : 'Collapse selected articles panel';
    }

    // String, not boolean — aria-expanded is a DOM attribute and must
    // serialize to "true"/"false".
    get basketToggleAriaExpanded() {
        return this.basketCollapsed ? 'false' : 'true';
    }

    handleToggleBasket() {
        this.basketCollapsed = !this.basketCollapsed;
    }

    get hasArticleTypeOptions() {
        return this.articleTypeOptions.length > 1;
    }

    get hasActiveFilters() {
        return this.titleSearch !== '' ||
            this.articleNumber !== '' ||
            this.articleType !== '' ||
            this.filterClauses.length > 0;
    }

    get hasDslClauses() {
        return this.filterClauses.length > 0;
    }

    // True when the filter matches more articles than one run can cover. A
    // select-all in this state is rejected server-side, so we surface it here
    // rather than letting the user submit and hit the error.
    get overRunCap() {
        return this.totalCount > this.runArticleCap;
    }

    get showSelectAllOfferBanner() {
        return !this.selectAllMatchingFilter
            && !this.overRunCap
            && this.totalCount > this.articles.length;
    }

    // Over-cap warning replaces the select-all offer: no clickable "select all",
    // just an explanation of the per-run limit and how to proceed.
    get showOverCapBanner() {
        return !this.selectAllMatchingFilter && this.overRunCap;
    }

    get overCapBannerMessage() {
        const scope = this.hasActiveFilters
            ? 'match this filter'
            : 'are in your Knowledge Base';
        return `${this.totalCount.toLocaleString()} articles ${scope} — more than the `
            + `${this.runArticleCap.toLocaleString()}-article limit for a single assessment. `
            + `Narrow your filter to select all, or run multiple assessments to cover them.`;
    }

    get showAllMatchingBanner() {
        return this.selectAllMatchingFilter;
    }

    get selectAllMatchingLinkLabel() {
        const scope = this.hasActiveFilters ? 'matching this filter' : 'in your Knowledge Base';
        return `Select all ${this.totalCount} articles ${scope}`;
    }

    get allMatchingBannerMessage() {
        const scope = this.hasActiveFilters ? 'matching this filter' : 'in your Knowledge Base';
        if (this.excludedIds.length > 0) {
            const remaining = Math.max(this.totalCount - this.excludedIds.length, 0);
            return `${remaining} of ${this.totalCount} articles ${scope} selected (${this.excludedIds.length} excluded).`;
        }
        return `All ${this.totalCount} articles ${scope} are selected.`;
    }

    // Filter handlers
    handleTitleSearchChange(event) {
        this.titleSearch = event.target.value;
        this.debounceLoad();
    }

    handleArticleNumberChange(event) {
        this.articleNumber = event.target.value;
        this.debounceLoad();
    }

    handleArticleTypeChange(event) {
        this.articleType = event.detail.value;
        this.resetAndLoad();
    }

    handleClearFilters() {
        this.titleSearch = '';
        this.articleNumber = '';
        this.articleType = '';
        this.filterLogic = 'AND';
        this.filterClauses = [];
        this.filterFormula = '';
        this.formulaError = null;
        this.draftField = '';
        this.draftFieldType = '';
        this.draftOperator = '';
        this.draftValue = '';
        this.draftValues = [];
        this.resetAndLoad();
    }

    handleDraftFieldChange(event) {
        const apiName = event.detail.value;
        this.draftField = apiName;
        const fd = this.availableFields.find(f => f.apiName === apiName);
        this.draftFieldType = fd ? (fd.type || 'STRING') : 'STRING';
        // Operator and value reset on field change — different field types
        // expose different operators, and values are likely incompatible.
        this.draftOperator = '';
        this.draftValue = '';
        this.draftValues = [];
    }

    handleDraftOperatorChange(event) {
        this.draftOperator = event.detail.value;
        // Switching to/from a null/list operator changes which value field
        // is even rendered — clear stale values to avoid sending data that
        // the server-side compiler would reject.
        if (NULL_OPERATORS.has(this.draftOperator)) {
            this.draftValue = '';
            this.draftValues = [];
        } else if (LIST_OPERATORS.has(this.draftOperator)) {
            this.draftValue = '';
        } else {
            this.draftValues = [];
        }
    }

    handleDraftValueChange(event) {
        // lightning-input dispatches detail.value for combobox/checkbox-toggle
        // and target.value for plain text/number/date inputs. Coalesce.
        const v = event.detail && event.detail.value !== undefined
            ? event.detail.value
            : event.target.value;
        this.draftValue = v == null ? '' : String(v);
    }

    handleDraftValuesChange(event) {
        // dual-listbox emits Array<String>
        const v = event.detail && event.detail.value;
        this.draftValues = Array.isArray(v) ? v : [];
    }

    handleDslLogicChange(event) {
        this.filterLogic = event.detail.value;
        this.resetAndLoad();
    }

    handleFormulaChange(event) {
        const raw = event.target.value || '';
        this.filterFormula = raw;
        // Validate inline only — do NOT auto-search on each keystroke. A
        // half-typed formula is transiently "valid" (e.g. "1" before "1 OR 2"),
        // which would fire a search and, on a bad partial, a spurious fallback
        // toast while the user is still typing. The search runs only on an
        // explicit commit: Apply Filters button or Enter (handleFormulaCommit).
        this.formulaError = this.validateFormula(raw, this.filterClauses.length);
    }

    handleFormulaKeyup(event) {
        // Enter in the formula field — treat as Apply. Other keys are no-ops
        // here; validation already happened in handleFormulaChange.
        if (event.key !== 'Enter') return;
        if (this.formulaError) return;
        this.resetAndLoad();
    }

    /**
     * Pure client-side syntactic validation. Mirrors the server's parser so
     * users see errors before a SOQL roundtrip. Server is still authoritative
     * — this is UX, not security.
     */
    validateFormula(formula, clauseCount) {
        const trimmed = (formula || '').trim();
        if (!trimmed) return null; // empty falls back to AND-of-all
        if (trimmed.length > 500) return 'Formula exceeds 500-character limit';
        if (clauseCount < 1) return 'Add at least one filter to use a formula';

        // Tokenize: digits, AND, OR, NOT, parens. Anything else rejects.
        const tokens = [];
        let i = 0;
        while (i < trimmed.length) {
            const ch = trimmed[i];
            if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') { i++; continue; }
            if (ch === '(' || ch === ')') { tokens.push({ type: ch, position: i }); i++; continue; }
            if (ch >= '0' && ch <= '9') {
                const start = i;
                while (i < trimmed.length && trimmed[i] >= '0' && trimmed[i] <= '9') i++;
                const value = parseInt(trimmed.substring(start, i), 10);
                if (value < 1 || value > clauseCount) {
                    return `Clause ${value} doesn't exist (you have ${clauseCount})`;
                }
                tokens.push({ type: 'NUM', value, position: start });
                continue;
            }
            if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) {
                const start = i;
                while (i < trimmed.length && /[A-Za-z]/.test(trimmed[i])) i++;
                const word = trimmed.substring(start, i).toUpperCase();
                if (word === 'AND' || word === 'OR' || word === 'NOT') {
                    tokens.push({ type: word, position: start });
                    continue;
                }
                return `Unknown keyword "${word}" at position ${start}`;
            }
            return `Unexpected character "${ch}" at position ${i}`;
        }
        // Balance parens + atom-after-operator check.
        let depth = 0;
        let expectAtom = true;
        for (const t of tokens) {
            if (t.type === '(') { depth++; expectAtom = true; continue; }
            if (t.type === ')') {
                depth--;
                if (depth < 0) return `Unmatched ')' at position ${t.position}`;
                expectAtom = false;
                continue;
            }
            if (t.type === 'NOT') {
                if (!expectAtom) return `Unexpected NOT at position ${t.position}`;
                continue;
            }
            if (t.type === 'AND' || t.type === 'OR') {
                if (expectAtom) return `${t.type} must follow a clause (position ${t.position})`;
                expectAtom = true;
                continue;
            }
            if (t.type === 'NUM') {
                if (!expectAtom) return `Adjacent clause references at position ${t.position}`;
                expectAtom = false;
                continue;
            }
        }
        if (depth !== 0) return 'Unbalanced parentheses';
        if (expectAtom) return 'Formula ends mid-expression';
        return null;
    }

    handleAddDslClause() {
        if (!this.hasDraftClause) {
            return;
        }
        const newClause = {
            id: `c${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
            field: this.draftField,
            fieldType: this.draftFieldType,
            operator: this.draftOperator,
            value: this.isListOperator ? null : (this.isNullOperator ? null : this.draftValue),
            values: this.isListOperator ? [...this.draftValues] : null
        };
        this.filterClauses = [...this.filterClauses, newClause];
        // Reset draft only — DON'T reset the article list. The user can
        // stage multiple clauses and the formula before triggering a search.
        this.draftValue = '';
        this.draftValues = [];
        // Re-validate any existing formula now that the clause count grew.
        this.formulaError = this.validateFormula(this.filterFormula, this.filterClauses.length);
    }

    handleRemoveDslClause(event) {
        const id = event.currentTarget.dataset.id;
        this.filterClauses = this.filterClauses.filter(c => c.id !== id);
        // After removal, surviving clauses renumber to stay 1..N. Any formula
        // referencing the removed (or now-nonexistent) number is flagged.
        this.formulaError = this.validateFormula(this.filterFormula, this.filterClauses.length);
        this.resetAndLoad();
    }

    handleApplyFilters() {
        // Explicit "Apply" — re-runs the search with the current draft.
        // Decoupled from individual draft handlers so users compose freely.
        if (this.formulaError) return;
        this.resetAndLoad();
    }

    handleLoadMore() {
        this.offset += PAGE_SIZE;
        this.loadArticles();
    }

    debounceLoad() {
        clearTimeout(this._debounceTimer);
        this._debounceTimer = setTimeout(() => {
            this.resetAndLoad();
        }, DEBOUNCE_MS);
    }

    resetAndLoad() {
        // Only drop the matching-filter snapshot here, not the hand-picked
        // selectedIds. Exclusions are filter-scoped (they would silently
        // drift past a subsequent edit), but per-id selections must survive
 // filter changes so the basket pane keeps them visible.
        this.dropMatchingFilterSnapshot();
        this.offset = 0;
        this.loadArticles();
    }

    handleRowSelection(event) {
 // (round 2): ignore the datatable's programmatic rowselection echo
        // that fires when we swap `this.articles` and it re-applies
        // `selected-rows`. That echo reports only the new page's checked rows
        // (often empty), and the reconcile logic below would read it as the
        // user unchecking the now-visible prior picks — silently dropping them.
        // The flag is set before every articles reassignment and cleared in a
        // trailing microtask by renderedCallback, so only genuine user clicks
        // (a later macrotask) get past here. Don't mutate state or dispatch.
        if (this._suppressRowSelection) {
            return;
        }
        const reportedIds = event.detail.selectedRows.map(row => row.id);
        if (this.selectAllMatchingFilter) {
            // Datatable reporting zero selected rows while we're in matching
            // mode is the master-uncheck gesture (or the equivalent end-state
            // of unchecking every visible row). Treat it as Clear Selection —
            // drop matching mode and clear exclusions — instead of flagging
            // every visible row as excluded.
            if (reportedIds.length === 0) {
                this.clearAllSelection();
                return;
            }
            // In matching mode the datatable's selection only reflects the
            // currently-loaded page. Translate page-level checks/unchecks into
            // mutations on the excludedIds set, leaving matching mode intact.
            const visibleIds = this.articles.map(a => a.id);
            const reportedSet = new Set(reportedIds);
            const excluded = new Set(this.excludedIds);
            for (const id of visibleIds) {
                if (reportedSet.has(id)) {
                    excluded.delete(id);
                } else {
                    excluded.add(id);
                }
            }
            this.excludedIds = Array.from(excluded);
        } else {
            // Non-matching mode: the datatable only reports rows on the
            // currently-loaded page, so a wholesale `selectedIds = reportedIds`
            // would wipe any selection that scrolled or filtered out of view —
            // e.g. tick an article, change the title search, the datatable
            // re-fires rowselection with an empty/reduced set, and the earlier
 // pick vanishes. Mirror the matching-mode branch:
            // reconcile only the VISIBLE rows against selectedIds — add the
            // ones now checked, remove the visible ones now unchecked — leaving
            // off-page selections (which the _rowCache keeps renderable in the
            // basket) untouched.
            const visibleIds = this.articles.map(a => a.id);
            const reportedSet = new Set(reportedIds);
            const selected = new Set(this.selectedIds);
            for (const id of visibleIds) {
                if (reportedSet.has(id)) {
                    selected.add(id);
                } else {
                    selected.delete(id);
                }
            }
            this.selectedIds = Array.from(selected);
        }
        this.dispatchSelectionChange();
    }

    handleClearSelection() {
        this.clearAllSelection();
    }

    handleSelectAllMatching() {
        this.selectAllMatchingFilter = true;
        this.filterSnapshot = this.snapshotFilterContext();
        this.excludedIds = [];
        this.dispatchSelectionChange();
    }

    handleClearMatching() {
        this.clearAllSelection();
    }

    /**
     * Basket "Remove" row action. Pulls the article id off the standard
     * lightning-datatable row-action event and drops it from the selection.
     * No-op when the article was selected via matching-filter mode — that
     * path never populates `basketRows` so we shouldn't be called there,
     * but guard defensively.
     */
    handleRemoveFromBasket(event) {
        if (this.selectAllMatchingFilter) {
            return;
        }
        const action = event.detail?.action?.name;
        const removedId = event.detail?.row?.id;
        if (action !== 'remove' || !removedId) {
            return;
        }
        const before = this.selectedIds.length;
        this.selectedIds = this.selectedIds.filter((id) => id !== removedId);
        if (this.selectedIds.length === before) {
            return;
        }
        this.dispatchSelectionChange();
    }

    /**
     * Drop the matching-filter snapshot + exclusions only, leaving the
     * hand-picked `selectedIds` intact. Called whenever a filter changes:
     * the snapshot can't survive a filter edit (it would silently drift),
     * and exclusions are filter-scoped, but per-id selections must persist
     * across filter edits so the basket still shows them.
     *
     * No-op when no snapshot is active so we don't fire spurious
     * selectionchange events on every filter keystroke.
     */
    dropMatchingFilterSnapshot() {
        if (!this.selectAllMatchingFilter && this.excludedIds.length === 0) {
            return;
        }
        this.selectAllMatchingFilter = false;
        this.filterSnapshot = null;
        this.excludedIds = [];
        this.dispatchSelectionChange();
    }

    /**
     * Wipe both the snapshot and the per-id selections. Triggered only by
     * explicit user gestures: the Clear Selection button, the Clear
     * matching-mode banner, or the master-uncheck while in matching mode.
     */
    clearAllSelection() {
        this.selectAllMatchingFilter = false;
        this.filterSnapshot = null;
        this.selectedIds = [];
        this.excludedIds = [];
        this.dispatchSelectionChange();
    }

    snapshotFilterContext() {
        return {
            titleSearch: this.titleSearch,
            articleNumber: this.articleNumber,
            articleType: this.articleType,
            filterLogic: this.filterLogic,
            filterFormula: (this.filterFormula || '').trim() || null,
            filterClauses: this.filterClauses.map(c => ({
                id: c.id,
                field: c.field,
                fieldType: c.fieldType || null,
                operator: c.operator,
                value: c.value || null,
                values: Array.isArray(c.values) ? [...c.values] : null
            }))
        };
    }

    dispatchSelectionChange() {
        this.dispatchEvent(new CustomEvent('selectionchange', {
            detail: {
                selectedIds: this.selectedIds,
 // (c) — lightweight rows (id/number/title) for the Preview
                // step's confirmation list. Empty in select-all-matching mode
                // (individual rows aren't cached); the host shows a filter
                // summary + count there instead.
                selectedRows: this.selectAllMatchingFilter
                    ? []
                    : this.selectedIds.map((id) => {
                          const r = this._rowCache.get(id);
                          return {
                              id,
                              title: r && r.title ? r.title : `Article ${id}`,
                              articleNumber: r && r.articleNumber ? r.articleNumber : ''
                          };
                      }),
                selectAllMatchingFilter: this.selectAllMatchingFilter,
                filterSnapshot: this.filterSnapshot,
                excludedIds: [...this.excludedIds],
                totalCount: this.totalCount,
                filterContext: {
                    titleSearch: this.titleSearch,
                    articleNumber: this.articleNumber,
                    articleType: this.articleType,
                    filterLogic: this.filterLogic,
                    filterFormula: (this.filterFormula || '').trim() || null,
                    filterClauses: this.filterClauses
                }
            }
        }));
    }

    reduceErrors(errors) {
        if (!Array.isArray(errors)) {
            errors = [errors];
        }

        return errors
            .filter(error => !!error)
            .map(error => {
                if (typeof error === 'string') {
                    return error;
                }
                if (error.body && error.body.message) {
                    return error.body.message;
                }
                if (error.message) {
                    return error.message;
                }
                return 'Unknown error';
            })
            .join(', ');
    }
}
