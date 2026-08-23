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
public with sharing class KBSetupOrchestratorController {

    // Templates surfaced on the Advanced Scoring Config screen (status check +
    // Prompt Builder deep-links). The LWC (kbSetupPromptEditor) groups these into
 // "Scoring" (the three LLM-scored dimensions) and "Other" tabs.
 // Two dead templates were dropped from this list in — Generic_Evaluator
    // and Evaluate_Chunk_Self_Containment (both had zero production callers). Their
    // .genAiPromptTemplate files and PromptTemplateService wrappers are removed in
    // the same change (see the postdemo-scoring-templates destructive manifest).
    private static final List<String> SCORING_TEMPLATE_NAMES = new List<String>{
        'Evaluate_Completeness',
        'Evaluate_Structure',
        'Evaluate_Clarity'
    };

    // Whitelist of permission set API names this controller is allowed to
    // assign. Security boundary: reject anything outside this list — prevents
    // a malicious LWC call from granting System Administrator via this method.
    //
    // Values are sourced from Custom Labels (with our package names as defaults)
    // so customers with pre-existing collisions can override the names. The
    // defaults match the deployed permset files. If a customer renames a label,
    // they must also deploy matching permset files — this controller protects
    // the assignment boundary but cannot rename the underlying metadata.
    private static Set<String> getAssignablePermsets() {
        return new Set<String>{
            System.Label.KB_Permset_SetupAdmin_ApiName,
            System.Label.KB_Permset_Admin_ApiName,
            System.Label.KB_Permset_Viewer_ApiName
        };
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getAvailableSearchIndexes() {
        List<Map<String, Object>> results = new List<Map<String, Object>>();
        try {
            for (DataSemanticSearch dss : [
                SELECT Name, SemanticSearchApiName, VectorDmo, ChunkDmo, RuntimeStatus
                FROM DataSemanticSearch
                ORDER BY Name
            ]) {
                Map<String, Object> entry = new Map<String, Object>();
                String indexBase = dss.VectorDmo != null ? dss.VectorDmo.removeEnd('__dlm') : dss.SemanticSearchApiName;
                entry.put('value', indexBase);
                entry.put('label', dss.Name + (dss.RuntimeStatus != 'READY' ? ' (' + dss.RuntimeStatus.toLowerCase() + ')' : ''));
                entry.put('status', dss.RuntimeStatus);
                entry.put('vectorDmo', dss.VectorDmo);
                entry.put('chunkDmo', dss.ChunkDmo);
                results.add(entry);
            }
        } catch (Exception e) {
            // DataSemanticSearch not available (Data Cloud not provisioned) — return empty list
        }
        return results;
    }

    @AuraEnabled(cacheable=false)
    public static List<String> checkPromptTemplateStatus() {
        if (!PromptTemplateService.isEinsteinAvailable()) {
            return new List<String>();
        }
        return new List<String>(SCORING_TEMPLATE_NAMES);
    }

    /**
     * Test seam wrapping ConnectApi.EinsteinLlm.getPromptTemplates so unit
     * tests can inject a deterministic template list without depending on
     * Einstein being provisioned in the test org. Mirrors the
     * KBKnowledgePublisher.IPublisher / PromptTemplateService.setMock pattern.
     *
     * @TestVisible private — sibling test classes can implement this in the
     * test context, but the type is hidden from production callers and other
     * packages so the seam can never be swapped at runtime by accident.
     */
    @TestVisible
    private interface IPromptTemplateLister {
        ConnectApi.EinsteinPromptRecordCollectionOutputRepresentation fetchTemplates();
    }

    private class RealPromptTemplateLister implements IPromptTemplateLister {
        public ConnectApi.EinsteinPromptRecordCollectionOutputRepresentation fetchTemplates() {
            return ConnectApi.EinsteinLlm.getPromptTemplates(null, null, null, 50, null, null, null, true);
        }
    }

    @TestVisible
    private static IPromptTemplateLister templateLister;

    private static IPromptTemplateLister resolveTemplateLister() {
        return templateLister == null ? new RealPromptTemplateLister() : templateLister;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getPromptTemplateLinks() {
        List<Map<String, String>> results = new List<Map<String, String>>();
        try {
            Set<String> scoringNames = new Set<String>(SCORING_TEMPLATE_NAMES);
            ConnectApi.EinsteinPromptRecordCollectionOutputRepresentation templateList =
                resolveTemplateLister().fetchTemplates();

            if (templateList != null && templateList.promptRecords != null) {
                for (ConnectApi.EinsteinPromptRecordRepresentation t : templateList.promptRecords) {
                    String name = t.fields.containsKey('DeveloperName')
                        ? String.valueOf(t.fields.get('DeveloperName').value)
                        : '';
                    if (scoringNames.contains(name)) {
                        Map<String, String> entry = new Map<String, String>();
                        entry.put('name', name);
                        entry.put('templateId', t.id);
                        String versionId = t.fields.containsKey('ActiveVersionId')
                            ? String.valueOf(t.fields.get('ActiveVersionId').value)
                            : '';
                        entry.put('versionId', versionId != null ? versionId : '');
                        results.add(entry);
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'getPromptTemplateLinks failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AuraHandledException(
                'Unable to resolve Prompt Builder links: ' + e.getMessage()
            );
        }
        return results;
    }

    // Intentionally NOT cacheable: reads KB_Scan_Config__c, KB_Score_Weight__c,
    // KB_Pipeline_Config__c, KB_Vector_Search_Config__c, and wizard state — all
    // of which change after Setup Wizard saves. A cached result would show stale
    // content-field selections, weights, etc. until the LDS TTL expires.
    @AuraEnabled
    public static Map<String, Object> getBootstrapData() {
        Map<String, Object> result = new Map<String, Object>();
        result.put('scanConfig', KBSetupWizardController.getScanConfig());
        result.put('scoreWeights', KBSetupWizardController.getScoreWeights());
        result.put('pipelineConfig', KBSetupWizardController.getPipelineConfig());
        result.put('vectorConfig', KBSetupWizardController.getVectorSearchConfig());
        result.put('wizardState', getWizardState());
        result.put('manualTasks', buildManualTaskChecklist());
        return result;
    }

    @AuraEnabled
    public static Map<String, Object> saveWizardState(String stateJSON) {
        try {
            KB_Setup_Wizard_State__c state = getOrCreateStateRecord();
            state.Wizard_State_JSON__c = fitTextField(String.isBlank(stateJSON) ? '{}' : stateJSON);
            upsert state;
            return getWizardState();
        } catch (Exception e) {
            throw new AuraHandledException('Failed to save wizard state: ' + e.getMessage());
        }
    }

    // Intentionally NOT cacheable: the Setup Wizard flips Setup_Completed__c
    // and consumers must see the fresh state immediately afterwards. The
    // query is single-row + single-field so the round-trip cost (~50ms) is
    // negligible compared to the UX cost of a stale 'setup incomplete'
    // banner persisting through Lightning's wire cache TTL.
    // All current consumers call this imperatively in connectedCallback.
    @AuraEnabled
    public static Boolean isSetupCompleted() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getInstance();
        return state != null && state.Setup_Completed__c;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getWizardState() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getInstance();
        Map<String, Object> result = new Map<String, Object>();
        result.put('wizardStateJSON', state != null && String.isNotBlank(state.Wizard_State_JSON__c) ? state.Wizard_State_JSON__c : '{}');
        result.put('setupCompleted', state != null && state.Setup_Completed__c);
        result.put('lastValidatedAt', state != null ? state.Last_Validated_At__c : null);
        result.put('lastValidationJSON', state != null && String.isNotBlank(state.Last_Validation_JSON__c) ? state.Last_Validation_JSON__c : '[]');
        return result;
    }

    /**
     * Per-section save. Any null (or blank) JSON param is treated as "skip this
     * section" — the LWC sends only the blobs the current wizard step owns so
     * saving Step 2 doesn't silently validate (and reject) Step 3's weights.
     *
     * `vectorConfigJSON` is kept in the signature for API stability, but writes
     * go through saveVectorConfiguration(...) elsewhere; pass null here to
     * preserve historical behaviour.
     */
    @AuraEnabled
    public static void saveCoreConfiguration(
        String scanConfigJSON,
        String scoreWeightsJSON,
        String pipelineConfigJSON,
        String vectorConfigJSON
    ) {
        try {
            if (String.isNotBlank(scanConfigJSON)) {
                // Scan config has no cross-field word-count validation — there
                // are no Article Length / Title word-count fields.
                Map<String, Object> scanConfig = parseJsonMap(scanConfigJSON);
                KBSetupWizardController.saveScanConfig(JSON.serialize(scanConfig));
            }
            if (String.isNotBlank(scoreWeightsJSON)) {
                Map<String, Object> scoreWeights = parseJsonMap(scoreWeightsJSON);
                validateScoreWeights(scoreWeights);
                KBSetupWizardController.saveScoreWeights(JSON.serialize(scoreWeights));
            }
            if (String.isNotBlank(pipelineConfigJSON)) {
                Map<String, Object> pipelineConfig = parseJsonMap(pipelineConfigJSON);
                validatePipelineConfig(pipelineConfig);
                KBSetupWizardController.savePipelineConfig(JSON.serialize(pipelineConfig));
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to save core configuration: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static void saveVectorConfiguration(String configJSON) {
        try {
            Map<String, Object> vectorConfig = parseJsonMap(configJSON);
            validateVectorConfig(vectorConfig);
            KBSetupWizardController.saveVectorSearchConfig(JSON.serialize(vectorConfig));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to save vector configuration: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Map<String, Object>> runPreflightChecks() {
        return KBSetupPreflightService.runChecks();
    }

    @AuraEnabled
    public static Map<String, Object> executeAutomationActions(String actionsJSON) {
        Map<String, Object> response = new Map<String, Object>();
        List<Map<String, Object>> results = new List<Map<String, Object>>();
        response.put('results', results);

        try {
            Map<String, Object> actions = parseJsonMap(actionsJSON);


            response.put('manualTasks', buildManualTaskChecklist());
            return response;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to execute automation actions: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Map<String, Object>> runFinalValidation() {
        List<Map<String, Object>> validations = new List<Map<String, Object>>();
        validations.addAll(runPreflightChecks());

 // non-blocking warning when content fields selected for
        // assessment differ from the fields embedded in the search index.
        // Mismatch means dimension analysis and dedup are reading different
        // surfaces. Soft warning (`required=false`) so admins who deliberately
        // scoped the index narrower than the scoring fields aren't blocked.
        // Returns null on the indeterminate branch — we deliberately suppress
        // the row when we can't introspect (Data Cloud unprovisioned, index
        // not built yet) so the UI doesn't show a green check next to a
        // "we couldn't tell" message.
        Map<String, Object> contentFieldCheck = buildContentFieldIndexCheck();
        if (contentFieldCheck != null) {
            validations.add(contentFieldCheck);
        }

        Boolean allRequiredPassed = true;
        for (Map<String, Object> item : validations) {
            Boolean required = (Boolean) item.get('required');
            Boolean passed = (Boolean) item.get('passed');
            if (required && !passed) {
                allRequiredPassed = false;
                break;
            }
        }

        KB_Setup_Wizard_State__c setupState = getOrCreateStateRecord();
        setupState.Setup_Completed__c = allRequiredPassed;
        setupState.Last_Validated_At__c = System.now();
        setupState.Last_Validation_JSON__c = fitTextField(buildValidationSummaryJson(validations));
        upsert setupState;

        return validations;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getKnowledgeFieldOptions() {
        try {
            List<Map<String, Object>> options = new List<Map<String, Object>>();
            Schema.SObjectType knowledgeType = Schema.getGlobalDescribe().get('Knowledge__kav');
            if (knowledgeType == null) return options;
            Map<String, Schema.SObjectField> fields = knowledgeType.getDescribe().fields.getMap();
            // Standard fields already read separately by the assessment engine — exclude them.
            // Title and Summary are sent to the scoring prompts as their OWN independent
 // inputs (standup 2026-06-11,) — NOT folded into the body-field-mapping
            // concatenation that buildArticleContent() assembles. Offering Summary here
            // would let an admin double-count it into the body text, so it is excluded from
            // the content-scope picker. (Title was already excluded.)
            Set<String> excluded = new Set<String>{
                'id', 'title', 'summary', 'articlenumber', 'urlname', 'language',
                'publishstatus', 'islatestversion', 'knowledgearticleid',
                'createddate', 'lastmodifieddate', 'systemmodstamp',
                'createdbyid', 'lastmodifiedbyid', 'ownerid', 'name'
            };
            List<Map<String, Object>> textAreas = new List<Map<String, Object>>();
            List<Map<String, Object>> shortTexts = new List<Map<String, Object>>();
            for (String apiName : fields.keySet()) {
                if (excluded.contains(apiName.toLowerCase())) continue;
                Schema.DescribeFieldResult f = fields.get(apiName).getDescribe();
                Schema.DisplayType dt = f.getType();
                Map<String, Object> opt = new Map<String, Object>{
                    'label' => f.getLabel() + ' (' + f.getName() + ')',
                    'value' => f.getName()
                };
                if (dt == Schema.DisplayType.TEXTAREA) {
                    textAreas.add(opt);
                } else if (dt == Schema.DisplayType.STRING) {
                    shortTexts.add(opt);
                }
            }
            // Return as two groups: textArea fields first, then short text fields
            // Each option carries a 'group' key so the LWC can render them in sections
            List<String> taLabels = new List<String>();
            Map<String, Map<String, Object>> taByLabel = new Map<String, Map<String, Object>>();
            for (Map<String, Object> o : textAreas) {
                String lbl = (String) o.get('label');
                taLabels.add(lbl);
                taByLabel.put(lbl, o);
            }
            taLabels.sort();
            for (String lbl : taLabels) {
                Map<String, Object> o = taByLabel.get(lbl);
                o.put('group', 'Long Text / Rich Text');
                options.add(o);
            }
            List<String> stLabels = new List<String>();
            Map<String, Map<String, Object>> stByLabel = new Map<String, Map<String, Object>>();
            for (Map<String, Object> o : shortTexts) {
                String lbl = (String) o.get('label');
                stLabels.add(lbl);
                stByLabel.put(lbl, o);
            }
            stLabels.sort();
            for (String lbl : stLabels) {
                Map<String, Object> o = stByLabel.get(lbl);
                o.put('group', 'Short Text');
                options.add(o);
            }
            return options;
        } catch (Exception e) {
            throw new AuraHandledException('Could not load Knowledge field options: ' + e.getMessage());
        }
    }

    private static Map<String, Object> buildCheck(String key, String label, Boolean passed, Boolean required, String details) {
        return buildCheck(key, label, passed, required, details, null, null);
    }

    /**
     * Builds the content-field / search-index alignment check used by
     * runFinalValidation. Always non-blocking. Statuses:
     *   - ok            → passed=true, no surfaced issue
     *   - mismatch      → passed=false, warning + step:2 deep-link CTA
     *   - indeterminate → null (suppressed — see below)
     *   - noConfig      → passed=false, warning + step:2 deep-link CTA
     *
     * Indeterminate returns null so the wizard does not render a row at
     * all. A green check next to "search index is not visible in this
     * org's schema yet" reads as broken; suppressing the row keeps the
     * UI honest. runFinalValidation filters nulls out of its result.
     */
    @TestVisible
    private static Map<String, Object> buildContentFieldIndexCheck() {
        Map<String, Object> result;
        try {
            result = KBContentFieldIndexValidator.getMismatch();
        } catch (Exception e) {
            // Defence-in-depth: a describe failure should never block validation.
            // Treat as indeterminate → suppress the row.
            return null;
        }
        String status = (String) result.get('status');
        if (status == KBContentFieldIndexValidator.STATUS_INDETERMINATE) {
            return null;
        }
        Boolean passed = status == KBContentFieldIndexValidator.STATUS_OK;
        String details = KBContentFieldIndexValidator.formatWarningDetails(result);
        // Mismatches and the no-config path point users back to Step 2 where
        // they choose content fields. The OK path doesn't need a CTA — green
        // is the only signal needed.
        String actionKey = (status == KBContentFieldIndexValidator.STATUS_MISMATCH
            || status == KBContentFieldIndexValidator.STATUS_NO_CONFIG)
            ? 'step:2' : null;
        return buildCheck(
            'contentFieldsMatchIndex',
            'Content fields align with search index',
            passed,
            false,
            details,
            'warning',
            actionKey
        );
    }

    /**
     * `actionKey` is a deep-link DSL the LWC renders as a CTA on failed checks:
     *   - 'step:<n>'          → navigate the wizard to step n (e.g. 'step:2')
     *   - 'setup:<SetupNode>' → open the named Salesforce Setup page
     *   - null                → no CTA (current behavior for passing checks,
     *                           warnings without a clear fix surface, etc.)
     *
     * Rule: a severity='blocker' check MUST be either genuinely unfixable
     * from within the wizard (Knowledge off, Einstein unreachable) OR carry
     * a non-null actionKey. Anything a user can fix by advancing through the
     * wizard is a 'warning' with a 'step:<n>' action.
     */
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

    // Short explainers shown as lightning-helptext next to each Step 5 check
    // in the wizard. Keep under ~200 chars; sourced from Custom Labels so
    // they're translatable.
    private static final Map<String, String> HELPTEXT_BY_KEY = new Map<String, String>{
        'dataCloudAvailable' => System.Label.KB_Helptext_Preflight_DataCloud,
        'searchIndexConfigured' => System.Label.KB_Helptext_Preflight_SearchIndex,
        'contentFieldsSelected' => System.Label.KB_Helptext_Preflight_ContentFields,
        'knowledgeArticlesExist' => System.Label.KB_Helptext_Preflight_ArticlesExist,
        'bypassPermissionExists' => System.Label.KB_Helptext_Preflight_BypassPermission,
        'contentFieldsMatchIndex' => System.Label.KB_Helptext_Preflight_ContentFieldsMatchIndex
    };

    private static Map<String, Object> buildActionResult(String actionKey, Boolean success, String message) {
        return new Map<String, Object>{
            'actionKey' => actionKey,
            'success' => success,
            'message' => message
        };
    }

    private static Map<String, Object> parseJsonMap(String jsonString) {
        if (String.isBlank(jsonString)) {
            return new Map<String, Object>();
        }
        return (Map<String, Object>) JSON.deserializeUntyped(jsonString);
    }

    private static KB_Setup_Wizard_State__c getOrCreateStateRecord() {
        KB_Setup_Wizard_State__c state = KB_Setup_Wizard_State__c.getOrgDefaults();
        if (state == null || state.Id == null) {
            state = new KB_Setup_Wizard_State__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        return state;
    }

    /**
     * Returns the running user's assignment state for the three KB permission
     * sets. Drives Wizard Step 0 (self-assign page) and any "am I missing
     * anything?" affordance elsewhere.
     *
     * Shape: list of { apiName, label, assigned } — deliberately simple so
     * the UI is a straight render. Label is hardcoded rather than fetched
     * from the permset record to avoid an extra SOQL per call; the three
     * names are stable.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getPermsetAssignmentStatus() {
        // Map API name → display label. Paired with the overridable Custom Label
        // names above so the display stays coherent even if a customer renames.
        Map<String, String> labels = new Map<String, String>{
            System.Label.KB_Permset_SetupAdmin_ApiName => System.Label.KB_Permset_SetupAdmin_Label,
            System.Label.KB_Permset_Admin_ApiName => System.Label.KB_Permset_Admin_Label,
            System.Label.KB_Permset_Viewer_ApiName => System.Label.KB_Permset_Viewer_Label
        };
        Set<String> assignable = getAssignablePermsets();
        Set<String> assignedNames = new Set<String>();
        for (PermissionSetAssignment psa : [
            SELECT PermissionSet.Name
            FROM PermissionSetAssignment
            WHERE AssigneeId = :UserInfo.getUserId()
              AND PermissionSet.Name IN :assignable
        ]) {
            assignedNames.add(psa.PermissionSet.Name);
        }
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (String apiName : assignable) {
            rows.add(new Map<String, Object>{
                'apiName' => apiName,
                'label' => labels.get(apiName),
                'assigned' => assignedNames.contains(apiName)
            });
        }
        return rows;
    }

    /**
 * can the running user actually reach the Assessments console?
     *
     * The Setup Wizard's completion CTA navigates to the KB_Assessment_Console
     * tab, which is only visible to the Viewer / Manager personas — a
     * Setup-Admin-only user has no visibility to it, so the nav dead-ends.
     * The wizard uses this to swap that CTA for a plain "Done" when the user
     * can't get there.
     *
     * Gated on OBJECT accessibility, not permset-name membership: read on
     * KB_Assessment_Run__c is the real precondition for the console being
     * usable and (in this app's permset model) is granted together with the
     * tab. Checking accessibility reflects the actual runtime grant regardless
     * of how it was assigned (permset, permset group, or profile), so it can't
     * drift the way a hardcoded permset-name check would.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean canAccessAssessments() {
        return Schema.SObjectType.KB_Assessment_Run__c.isAccessible();
    }

    private static void validateScoreWeights(Map<String, Object> scoreWeights) {
        Decimal total = 0;
        for (Object val : scoreWeights.values()) {
            total += toDecimal(val);
        }
        if (Math.abs(total - 1) > 0.01) {
            throw new AuraHandledException('Score weights invalid: all dimensions must sum to 1.0.');
        }
    }

    private static void validatePipelineConfig(Map<String, Object> pipelineConfig) {
 // the Auto-Merge / Manual-Review band comparison is gone — the
        // auto-merge threshold was retired (merges are user-approved). Only the
        // Tier 2 detection knobs are validated here now.
        Decimal tier2TopK = toDecimal(pipelineConfig.get('tier2TopK'));
        Decimal similarityThreshold = toDecimal(pipelineConfig.get('tier2SimilarityThreshold'));

        if (tier2TopK != null && tier2TopK <= 0) {
            throw new AuraHandledException('Pipeline config invalid: Tier 2 TopK must be greater than zero.');
        }
        if (similarityThreshold != null && (similarityThreshold <= 0 || similarityThreshold > 1)) {
            throw new AuraHandledException('Pipeline config invalid: Tier 2 similarity threshold must be between 0 and 1.');
        }
    }

    private static void validateVectorConfig(Map<String, Object> vectorConfig) {
        String issue = getVectorConfigIssue(vectorConfig);
        if (String.isNotBlank(issue)) {
            throw new AuraHandledException('Vector config invalid: ' + issue);
        }
    }

    private static String getVectorConfigIssue(Map<String, Object> vectorConfig) {
        String implClass = asString(vectorConfig.get('implementationClass'));
        String dataSpace = asString(vectorConfig.get('dataSpaceName'));
        String searchIndexName = asString(vectorConfig.get('searchIndexName'));
        Decimal similarity = toDecimal(vectorConfig.get('similarityThreshold'));
        Decimal maxResults = toDecimal(vectorConfig.get('maxResults'));

        // Treat a missing isActive as true (back-compat with payloads that
        // don't carry the field — they're implicitly enabling vector search).
        Object rawActive = vectorConfig.get('isActive');
        Boolean isActive = rawActive == null ? true : Boolean.valueOf(rawActive);

        if (String.isBlank(implClass)) {
            return 'Implementation class is required.';
        }
        // Search index + data space are only required when vector search is
        // actually going to run. The user can opt out via the toggle, in which
        // case we accept whatever (possibly blank) values the form still
        // carries — the SOQL fallback doesn't read them. Gating on isActive in
        // addition to implClass closes the trap where the LWC ships
        // implClass='ConnectApiVectorSearchService' with isActive=false.
        if (isActive && implClass == 'ConnectApiVectorSearchService') {
            if (String.isBlank(searchIndexName)) {
                return 'Search index name is required when vector search is enabled.';
            }
            if (String.isBlank(dataSpace)) {
                return 'Data space name is required for ConnectApi vector search.';
            }
        }
        if (similarity != null && (similarity <= 0 || similarity > 1)) {
            return 'Similarity threshold must be > 0 and <= 1.';
        }
        if (maxResults != null && maxResults <= 0) {
            return 'Max results must be greater than zero.';
        }
        return '';
    }

    private static List<Map<String, Object>> buildManualTaskChecklist() {
        List<Map<String, Object>> tasks = new List<Map<String, Object>>();
        tasks.add(new Map<String, Object>{
            'key' => 'promptBuilder',
            'title' => 'Review Prompt Builder templates',
            'details' => 'Confirm scoring prompt templates are activated and available to Setup Admin users.',
            'required' => false
        });
 // this task was jargony ("Map Knowledge index and retrieval source").
        // Reworded in plain English — it's asking the admin to confirm the Data
        // Cloud search index actually points at Knowledge articles.
        tasks.add(new Map<String, Object>{
            'key' => 'dataCloudStream',
            'title' => 'Confirm the search index points at your Knowledge articles',
            'details' => 'Open your Data Cloud search index (or Agentforce Data Library) and verify it indexes Knowledge__kav content. Tier 2 deduplication searches whatever this index contains, so it must point at your Knowledge articles.',
            'required' => true
        });
 // per-article results are invisible until the knowledgeConsistencyChecker
        // LWC is on the Knowledge record page. Required pre-setup task so testers
        // actually see article-level output.
        tasks.add(new Map<String, Object>{
            'key' => 'activateRecordPage',
            'title' => 'Activate the Knowledge record page with the assessment component',
            'details' => 'In the Lightning App Builder, add the Knowledge Assessment component to your Knowledge record page and activate it. Per-article scores, issues, and the Fix-with-AI action only appear once the component is on the record page.',
            'required' => true
        });
 // platform prerequisites the running user must already hold. NOT part
        // of this package and NOT granted by the shipped permission sets — surfaced
        // here and on the Step 1 Assign Permissions panel because missing them
        // blocked the golden-org build.
        tasks.add(new Map<String, Object>{
            'key' => 'platformPrereqPerms',
            'title' => 'Assign platform prerequisite permissions (Data Cloud user, Prompt Template user)',
            'details' => 'These Salesforce platform permissions are not shipped with this app. The user running assessments needs Data Cloud access (for Tier 2 dedup) and Prompt (Template) user access (for LLM scoring and AI Fix). Assign them in Setup.',
            'required' => true
        });
        return tasks;
    }

    private static String asString(Object value) {
        return value == null ? '' : String.valueOf(value).trim();
    }

    private static Boolean toBoolean(Object value) {
        if (value == null) {
            return false;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        return String.valueOf(value).toLowerCase() == 'true';
    }

    private static Decimal toDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf((Integer) value);
        }
        if (value instanceof Long) {
            return Decimal.valueOf((Long) value);
        }
        if (value instanceof Double) {
            return Decimal.valueOf((Double) value);
        }
        return Decimal.valueOf(String.valueOf(value));
    }

    private static String fitTextField(String value) {
        if (String.isBlank(value)) {
            return value;
        }
        return value.length() > 255 ? value.substring(0, 255) : value;
    }

    private static String buildValidationSummaryJson(List<Map<String, Object>> validations) {
        Integer requiredFailures = 0;
        Integer optionalFailures = 0;
        List<String> failedRequiredKeys = new List<String>();

        for (Map<String, Object> item : validations) {
            Boolean required = (Boolean) item.get('required');
            Boolean passed = (Boolean) item.get('passed');
            String key = (String) item.get('key');
            if (passed) {
                continue;
            }
            if (required) {
                requiredFailures++;
                failedRequiredKeys.add(key);
            } else {
                optionalFailures++;
            }
        }

        Map<String, Object> summary = new Map<String, Object>{
            'requiredFailures' => requiredFailures,
            'optionalFailures' => optionalFailures,
            'failedRequiredKeys' => failedRequiredKeys
        };
        return JSON.serialize(summary);
    }
}
