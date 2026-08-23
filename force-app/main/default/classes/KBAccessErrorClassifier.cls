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
 * Shared classification of raw platform exception messages for the
 * user-facing "translate to a friendly message" paths.
 *
 * When a USER_MODE DML write is denied because the running user lacks object
 * CRUD or field-level security, the platform throws messages the end user
 * shouldn't see raw — e.g. `DML operation UPDATE not allowed on Knowledge__kav`,
 * `insufficient access rights on cross-reference id`, `No edit permission`.
 * Three surfaces translate these into actionable guidance:
 *   - `KBImprovementFixFacade.toFriendly` (AI Fix)
 *   - `Tier4ConsolidationAction.friendlyMergeError` (merge / Golden Record)
 *   - `DuplicateCandidateController.resolveContradiction` (contradiction resolve)
 * Centralising the substring set here keeps them from drifting apart.
 *
 * Deliberately does NOT match the governor-limit message
 * `Too many DML operations: N` — that contains the words "DML operation" but is
 * a limit failure, not an access denial. We match `not allowed on` (the CRUD
 * denial) rather than the bare `DML operation` to avoid that false positive.
 */
public with sharing class KBAccessErrorClassifier {

    // Substrings the platform uses for a CRUD / FLS / sharing denial on DML.
    // Lower-cased; matched case-insensitively. `not allowed on` catches the
    // object-CRUD `TypeException` ("DML operation UPDATE not allowed on X")
    // without matching the "Too many DML operations" governor limit.
    private static final List<String> DENIAL_TOKENS = new List<String>{
        'insufficient access',
        'insufficient privileges',
        'you can\'t perform this action',
        'no create permission',
        'no edit permission',
        'not permitted to',
        'not allowed on',
        'inaccessible'
    };

    /**
     * True when the raw exception message looks like an access denial (missing
     * object CRUD, FLS, or record sharing) rather than a functional failure.
     */
    public static Boolean isAccessDenial(String rawMessage) {
        if (String.isBlank(rawMessage)) {
            return false;
        }
        String lower = rawMessage.toLowerCase();
        for (String token : DENIAL_TOKENS) {
            if (lower.contains(token)) {
                return true;
            }
        }
        return false;
    }
}
