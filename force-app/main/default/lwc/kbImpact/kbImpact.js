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
/**
 * Shared issue/impact helpers for the KB readiness LWCs.
 *
 * Two concerns live here so consumers share one source of truth:
 *  1. Impact severity (rank / badge / comparators) — see below.
 *  2. The "actionable issue" predicate (status + dimension) the Improvements
 *     Inbox uses, so UI that gates on it can't drift from the inbox query.
 *
 * Impact is the single LLM-emitted severity picklist on KB_Dimension_Analysis__c
 * (High / Medium / Low). It is surfaced as a badge and used to order issue rows.
 *
 * CANONICAL RANK CONVENTION: higher number = more severe.
 *   High = 3, Medium = 2, Low = 1, unknown/null = 0.
 * NULLS (and any off-list value) rank 0 and therefore sort LAST under the
 * default "most severe first" ordering — use compareImpactDesc / compareImpactAsc
 * which keep rank-0 rows pinned to the bottom regardless of sort direction.
 *
 * This module is a plain ES module (isExposed=false) — import it, don't place
 * it on a page. It is the single source of truth: do not redeclare IMPACT_RANK
 * or IMPACT_BADGE in any consumer.
 */

// Higher = more severe. Unknown / null impact falls through to 0 (sorts last).
export const IMPACT_RANK = { High: 3, Medium: 2, Low: 1 };

// SLDS badge class per impact level. Unknown / null → plain badge.
export const IMPACT_BADGE = {
    High: 'slds-badge slds-theme_error',
    Medium: 'slds-badge slds-theme_warning',
    Low: 'slds-badge'
};

/**
 * Numeric severity rank for an impact value. Unknown / null → 0.
 * @param {string} impact - 'High' | 'Medium' | 'Low' | null
 * @returns {number}
 */
export function impactRank(impact) {
    return IMPACT_RANK[impact] ?? 0;
}

/**
 * SLDS badge class for an impact value. Unknown / null → plain badge.
 * @param {string} impact - 'High' | 'Medium' | 'Low' | null
 * @returns {string}
 */
export function impactBadgeClass(impact) {
    return IMPACT_BADGE[impact] || 'slds-badge';
}

/**
 * Comparator: most severe first (High → Medium → Low), with unknown/null rows
 * pinned to the bottom. Pass impact strings.
 */
export function compareImpactDesc(a, b) {
    const ra = impactRank(a);
    const rb = impactRank(b);
    if (ra === rb) return 0;
    // Rank-0 (unknown/null) rows always sink to the bottom, both directions.
    if (ra === 0) return 1;
    if (rb === 0) return -1;
    return rb - ra;
}

/**
 * Comparator: least severe first (Low → Medium → High), with unknown/null rows
 * still pinned to the bottom. Pass impact strings.
 */
export function compareImpactAsc(a, b) {
    const ra = impactRank(a);
    const rb = impactRank(b);
    if (ra === rb) return 0;
    if (ra === 0) return 1;
    if (rb === 0) return -1;
    return ra - rb;
}

// ── "actionable issue" predicate ───────────────────────────────────────────
// Single source of truth for which recommendations the Improvements Inbox
// treats as actionable, so consumers that gate UI on it (e.g. the score card's
// "View Actions" button,) can't drift from the inbox's own definition.
// These MUST mirror KBEnrichmentController.getImprovementsInbox:
//   WHERE Status__c IN ('Open','Error') AND Dimension__c NOT IN ('Duplication','Conflict')
// Duplication / Conflict are pipeline-only and live on the Duplicates tab, not
// the Issues inbox. If the inbox query changes, change it here too.

// Dimensions handled by the dedup pipeline, excluded from the Issues inbox.
export const PIPELINE_DIMENSIONS = ['Duplication', 'Conflict'];

// Statuses the inbox surfaces as still-actionable (Error is kept for retry).
export const OPEN_ISSUE_STATUSES = ['Open', 'Error'];

/**
 * True when a recommendation is an open, non-pipeline issue — i.e. something the
 * Improvements Inbox would show and let the user act on.
 * @param {{status?: string, dimension?: string}} rec
 * @returns {boolean}
 */
export function isActionableIssue(rec) {
    if (!rec) return false;
    return (
        OPEN_ISSUE_STATUSES.includes(rec.status) &&
        !PIPELINE_DIMENSIONS.includes(rec.dimension)
    );
}

/**
 * True when a non-pipeline recommendation is mid-fix (Queued) — disabled in the
 * UI, but distinct from "resolved/dismissed" so callers can message it as
 * in-progress rather than done.
 * @param {{status?: string, dimension?: string}} rec
 * @returns {boolean}
 */
export function isInProgressIssue(rec) {
    if (!rec) return false;
    return rec.status === 'Queued' && !PIPELINE_DIMENSIONS.includes(rec.dimension);
}
