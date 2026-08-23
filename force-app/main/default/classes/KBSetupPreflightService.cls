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
 * Setup-wizard postflight checks. Surfaced on Step 5 (Final Validation) of
 * the wizard — they answer "is the org configured to actually run scans"
 * across the dimensions an installer can fix:
 *   - Data Cloud provisioning (informational; SOQL fallback covers the gap)
 *   - Search index configuration (Step 4)
 *   - Content field selection (Step 2)
 *   - Published Knowledge articles existing
 *   - Bypass custom permission for the consistency checker
 *
 * Step 1 of the wizard does NOT show these — gating install on a checklist
 * that mostly mirrors "the app is installed" was redundant. Items the install
 * itself enforces (Knowledge enabled, Einstein available, the permset that
 * lets you reach the wizard) are not re-checked here.
 *
 * Each check returns a Map<String, Object> with keys: key, label, passed,
 * required, details, severity, actionKey, helptext.
 */
public with sharing class KBSetupPreflightService {

    private KBSetupPreflightService() {}

    /**
     * Runs every check in the order Step 5 renders them. Pure read-only.
     */
    public static List<Map<String, Object>> runChecks() {
        List<Map<String, Object>> checks = new List<Map<String, Object>>();

        // Warning: Data Cloud
        Boolean dcAvailable = Type.forName('ConnectApi', 'CdpQuery') != null;
        checks.add(buildCheck(
            'dataCloudAvailable',
            'Data Cloud is provisioned',
            dcAvailable,
            false,
            dcAvailable
                ? 'Semantic vector search available for high-quality deduplication.'
                : 'Data Cloud not provisioned — deduplication will use SOQL keyword matching (lower quality). Provision Data Cloud for semantic vector search.',
            'warning', null
        ));

        // Info: Search index name configured (only relevant if Data Cloud is available and setup is complete).
        // Reuses dcAvailable from the previous check — no need to call Type.forName twice.
        KB_Vector_Search_Config__c vectorCfg = KB_Vector_Search_Config__c.getOrgDefaults();
        Boolean searchIndexConfigured = vectorCfg != null && String.isNotBlank(vectorCfg.Search_Index_Name__c);
        KB_Setup_Wizard_State__c wizState = KB_Setup_Wizard_State__c.getInstance();
        Boolean setupDone = wizState != null && wizState.Setup_Completed__c;
        Boolean searchIndexPassed = searchIndexConfigured || !dcAvailable || !setupDone;
        checks.add(buildCheck(
            'searchIndexConfigured',
            'Vector Search index name is configured',
            searchIndexPassed,
            false,
            !dcAvailable
                ? 'Not applicable — Data Cloud is not provisioned. SOQL fallback will be used.'
                : searchIndexConfigured
                    ? 'Index: ' + vectorCfg.Search_Index_Name__c
                    : 'You will configure this on the Essentials step.',
            'warning',
 // the search index moved onto the Essentials step (step 2) in
            // the setup redesign; the former Runtime & Retrieval step (4) is gone.
            (searchIndexPassed || !dcAvailable) ? null : 'step:2'
        ));

        // WARNING: content fields. Fixable in Step 2 (Content Scope) — so this
        // is a warning with a step:2 action key, NOT a blocker.
        KB_Scan_Config__c scanCfg = KB_Scan_Config__c.getInstance();
        Boolean contentFieldsSelected = scanCfg != null
            && String.isNotBlank(scanCfg.Content_Field_Mapping_JSON__c);
        Integer contentFieldCount = 0;
        if (contentFieldsSelected) {
            for (String f : scanCfg.Content_Field_Mapping_JSON__c.split(',')) {
                if (String.isNotBlank(f)) contentFieldCount++;
            }
            contentFieldsSelected = contentFieldCount > 0;
        }
        checks.add(buildCheck(
            'contentFieldsSelected',
            'Knowledge content fields are selected for assessment',
            contentFieldsSelected,
            false,
            contentFieldsSelected
                ? contentFieldCount + ' content field(s) selected for assessment.'
                : 'Select at least one Knowledge content field in Content Scope (Step 2). The assessment engine reads body text from these fields.',
            'warning', 'step:2'
        ));

        // Warning: Articles exist
        Integer publishedArticles = [SELECT COUNT() FROM Knowledge__kav WHERE PublishStatus = 'Online'];
        checks.add(buildCheck(
            'knowledgeArticlesExist',
            'Published Knowledge articles exist in this org',
            publishedArticles > 0,
            false,
            publishedArticles > 0
                ? publishedArticles + ' published article(s) found.'
                : 'No published articles found. Publish at least one article before running an assessment.',
            'warning', null
        ));

        // Warning: Bypass permission
        List<CustomPermission> bypassPerms = [
            SELECT Id FROM CustomPermission
            WHERE DeveloperName = 'Bypass_AI_Knowledge_Check'
            LIMIT 1
        ];
        Boolean bypassExists = !bypassPerms.isEmpty();
        checks.add(buildCheck(
            'bypassPermissionExists',
            'Bypass_AI_Knowledge_Check custom permission is available',
            bypassExists,
            false,
            bypassExists
                ? 'Custom permission is deployed and available.'
                : 'The Bypass_AI_Knowledge_Check custom permission is missing. Required only for Knowledge Consistency Checker bypass.',
            'warning', null
        ));

        return checks;
    }

    @TestVisible
    private static Map<String, Object> buildCheck(String key, String label, Boolean passed, Boolean required, String details) {
        return buildCheck(key, label, passed, required, details, null, null);
    }

    /**
     * `actionKey` is a deep-link DSL the LWC renders as a CTA on failed checks:
     *   - 'step:<n>'          → navigate the wizard to step n (e.g. 'step:2')
     *   - 'setup:<SetupNode>' → open the named Salesforce Setup page
     *   - null                → no CTA
     *
     * Rule: a severity='blocker' check MUST be either genuinely unfixable
     * from within the wizard (Knowledge off, Einstein unreachable) OR carry
     * a non-null actionKey.
     */
    @TestVisible
    private static Map<String, Object> buildCheck(String key, String label, Boolean passed, Boolean required, String details, String severity, String actionKey) {
        String resolvedSeverity = severity != null ? severity : (required ? 'blocker' : 'warning');
        return new Map<String, Object>{
            'key' => key,
            'label' => label,
            'passed' => passed,
            'required' => required,
            'details' => details,
            'severity' => resolvedSeverity,
            'actionKey' => actionKey,
            'helptext' => HELPTEXT_BY_KEY.get(key)
        };
    }

    // Short explainers shown as lightning-helptext next to each check in the
    // wizard. Keys must match those emitted by runChecks() above. The
    // 'prefiltersValid' and 'contentFieldsMatchIndex' checks are owned by
    // KBSetupOrchestratorController.runFinalValidation (which keeps its own
    // copy of this map) — no entry here.
    private static final Map<String, String> HELPTEXT_BY_KEY = new Map<String, String>{
        'dataCloudAvailable' => System.Label.KB_Helptext_Preflight_DataCloud,
        'searchIndexConfigured' => System.Label.KB_Helptext_Preflight_SearchIndex,
        'contentFieldsSelected' => System.Label.KB_Helptext_Preflight_ContentFields,
        'knowledgeArticlesExist' => System.Label.KB_Helptext_Preflight_ArticlesExist,
        'bypassPermissionExists' => System.Label.KB_Helptext_Preflight_BypassPermission
    };
}
