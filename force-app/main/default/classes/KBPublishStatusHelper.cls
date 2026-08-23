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
 * Shared classification of `Knowledge__kav.PublishStatus` values.
 *
 * Salesforce KAV publish statuses are: `Online`, `Draft`, `Archived`. The
 * platform also surfaces transient/derived states (`OutdatedArchived`) on some
 * orgs. The AI Fix write-path needs to answer "is this version writable?
 * / is it archived?" in one place rather than re-deriving (and drifting) at each
 * call site. Intentionally generic so other publish-status consumers — e.g. a
 * future dedup-candidate filter — can reuse it; today the sole caller is
 * KBImprovementFixService.
 *
 * Why a helper and not an enum: PublishStatus comes back as a String from SOQL
 * and from the publishing API, and orgs can carry values we don't enumerate.
 * Comparing case-insensitively against a small whitelist is the safe pattern.
 */
public with sharing class KBPublishStatusHelper {

    public static final String ONLINE  = 'Online';
    public static final String DRAFT   = 'Draft';
    public static final String ARCHIVED = 'Archived';

    /** Any archived-family status — neither editable nor a fixable source. */
    private static final Set<String> ARCHIVED_STATUSES = new Set<String>{
        'archived', 'outdatedarchived'
    };

    private static String norm(String status) {
        return status == null ? '' : status.trim().toLowerCase();
    }

    public static Boolean isOnline(String status) {
        return norm(status) == 'online';
    }

    public static Boolean isDraft(String status) {
        return norm(status) == 'draft';
    }

    public static Boolean isArchived(String status) {
        return ARCHIVED_STATUSES.contains(norm(status));
    }

    /**
     * True when a version can participate in the AI Fix flow — either it's the
     * live Online version (we create a fresh draft off it) or it's already a
     * Draft (we write into it directly). Archived/unknown statuses are not
     * fixable and must be rejected with a friendly message rather than letting
 * the platform throw FIELD_INTEGRITY_EXCEPTION on update.
     */
    public static Boolean isFixable(String status) {
        return isOnline(status) || isDraft(status);
    }
}
