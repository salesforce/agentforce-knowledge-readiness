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
 * Canonical `@AuraEnabled` entry point for the AI-powered article fix flow.
 *
 * Layer: Facade (presentation ↔ service boundary — see CLAUDE.md "5-layer
 * service stack"). All LWC bundles import their fix-flow Apex calls from
 * this class.
 *
 * This class is intentionally thin — every method delegates to
 * `KBImprovementFixService` (orchestration). No business logic lives here.
 *
 * **Error routing.** `KBImprovementFixService`
 * re-throws the original exception (after marking recs Error) instead of
 * wrapping in `AuraHandledException` itself, so the queueable/batch wrappers
 * can log the actual cause via `System.debug(LoggingLevel.ERROR, …)`. The
 * facade is the layer that translates non-AHE exceptions into AHE for the
 * LWC, calling `ahe.setMessage(...)` so the friendly text survives Aura's
 * client-side stripping. Pattern matches `KBEnrichmentController.publishCandidate`.
 *
 * Surfaces:
 *   - `dispatchArticleFix(...)`       — single-article, synchronous
 *   - `dispatchArticleFixesBulk(...)` — bulk, async (queueable ≤500, batch >500)
 */
public with sharing class KBImprovementFixFacade {

    @AuraEnabled
    public static void dispatchArticleFix(
        String       articleVersionId,
        Boolean      useCurrentOnline,
        List<Id>     recIds,
        List<String> issueDescriptions
    ) {
        try {
            KBImprovementFixService.dispatchArticleFixInternal(
                articleVersionId, useCurrentOnline, recIds, issueDescriptions
            );
        } catch (AuraHandledException ahe) {
            // Already friendly (e.g. input-validation throw at top of service);
            // preserve as-is.
            throw ahe;
        } catch (Exception e) {
            throw toFriendly(e);
        }
    }

    @AuraEnabled
    public static KBImprovementFixService.BulkDispatchResult dispatchArticleFixesBulk(
        List<KBImprovementFixService.BulkFixRequest> requests
    ) {
        try {
            return KBImprovementFixService.dispatchArticleFixesBulkInternal(requests);
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            throw toFriendly(e);
        }
    }

    /**
     * Translate a service-layer exception into a friendly `AuraHandledException`
     * for the LWC. Three access-related signatures get actionable text:
     *   - Missing FLS surfaces (in USER_MODE SOQL) as `No such column 'X' on
     *     entity 'Knowledge__kav'` — reads like a schema bug to admins;
 * translate to an FLS message naming the Content Scope fields.
 * All content fields non-editable (object write allowed but no
     *     content field FLS-editable) is thrown by persistDraft as a complete,
     *     actionable sentence; surface it verbatim (checked BEFORE the broad
     *     access-denial classifier below, so it isn't swallowed by it).
 * Missing Knowledge object CRUD (USER_MODE DML in KBKavDraftWriter,)
     *     surfaces as an insufficient-access / no-create-or-edit-permission
     *     error — translate to a message naming the KB Knowledge Author permset.
     * All other errors keep the existing `Fix failed: …` wrapper.
     */
    @TestVisible
    private static AuraHandledException toFriendly(Exception e) {
        String raw = e.getMessage();
        String friendly;
        if (raw != null && raw.containsIgnoreCase('No such column')) {
            String fieldList;
            try {
                fieldList = String.join(KBAssessmentService.getContentFields('Knowledge__kav'), ', ');
            } catch (Exception ignored) {
                fieldList = 'the fields configured in your Content Scope';
            }
            friendly = 'Field-level security on Knowledge fields is missing. '
                + 'Grant the running user FLS Read and Edit on the fields configured in your '
                + 'Content Scope (Setup Wizard, Step 2): ' + fieldList + '.';
        } else if (raw != null && raw.containsIgnoreCase('the AI rewrite was not saved')) {
 // persistDraft's all-content-fields-non-editable message is
 // already user-ready — surface it as-is. Kept ABOVE the
            // access-denial classifier so this specific case wins (the object
            // write itself succeeded here — only field-level FLS was missing).
            friendly = raw;
        } else if (KBAccessErrorClassifier.isAccessDenial(raw)) {
            // USER_MODE object-CRUD/FLS denial (e.g. "DML operation UPDATE not
            // allowed on Knowledge__kav") — the string a user hits without the
 // KB_Knowledge_Author permset.
            friendly = 'You do not have permission to write Knowledge articles. '
                + 'Ask an admin to assign the KB Knowledge Author permission set '
                + '(Knowledge Create/Edit), plus Manage Articles + Publish Articles '
                + 'and the Knowledge User license.';
        } else {
            friendly = 'Fix failed: ' + raw;
        }
        AuraHandledException ahe = new AuraHandledException(friendly);
        ahe.setMessage(friendly); // survives Aura's client-side stripping
        return ahe;
    }
}
