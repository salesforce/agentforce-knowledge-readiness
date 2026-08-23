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
 * Read-only diagnostics snapshot for the KB Diagnostics tab.
 *
 * Intentionally no DML, no new objects, no pipeline wiring — reads existing
 * preflight checks, OrgLimits, AsyncApexJob history, KB_Vector_Search_Config__c,
 * and KB_Setup_Wizard_State__c, and composes a UI-friendly DTO.
 *
 * All methods are `@AuraEnabled` (NOT cacheable) because the snapshot must
 * reflect live state at the moment the user opens Diagnostics. A copy-bundle
 * of stale data is worse than a slightly slower tab.
 */
public with sharing class KBDiagnosticsController {

    // Apex class name prefix used to filter AsyncApexJob results to KB work only.
    // Prevents the tab from showing unrelated org async activity (and from
    // leaking class names users aren't permitted to see).
    private static final String KB_CLASS_PREFIX = 'KB';

    // Limit recent failures surfaced in the UI. Anything older is out of scope —
    // we point users at Setup → Apex Jobs for deeper history.
    private static final Integer RECENT_FAILURE_LIMIT = 20;

    @AuraEnabled
    public static DiagnosticSnapshot getSnapshot() {
        try {
            DiagnosticSnapshot snap = new DiagnosticSnapshot();
            snap.capturedAt = System.now();
            snap.preflightChecks = KBSetupOrchestratorController.runPreflightChecks();
            snap.orgLimits = readOrgLimits();
            snap.recentFailures = readRecentKbFailures();
            snap.vectorProvider = readVectorProvider();
            snap.lastRun = readLastRun();
            snap.wizardState = readWizardState();
            return snap;
        } catch (Exception e) {
            throw new AuraHandledException('Failed to load diagnostics: ' + e.getMessage());
        }
    }

    /**
     * Returns the same snapshot serialized to JSON. Used by the "Copy Bundle"
     * button in the LWC — we do the stringify server-side so the output is
     * stable across browsers and easy to paste into a forum thread.
     */
    @AuraEnabled
    public static String getDiagnosticBundle() {
        try {
            DiagnosticSnapshot snap = getSnapshot();
            return JSON.serializePretty(snap);
        } catch (Exception e) {
            throw new AuraHandledException('Failed to build diagnostic bundle: ' + e.getMessage());
        }
    }

    private static List<OrgLimitEntry> readOrgLimits() {
        List<OrgLimitEntry> entries = new List<OrgLimitEntry>();
        // Shared source of truth for which limits matter to this app.
        // Listing all 70+ org limits would bury the signal; KnowledgeAIGovernanceService
        // owns the authoritative list so Diagnostics and Cost Preview agree.
        Map<String, System.OrgLimit> all = OrgLimits.getMap();
        for (KnowledgeAIGovernanceService.TrackedOrgLimit t : KnowledgeAIGovernanceService.getTrackedOrgLimits()) {
            addLimit(entries, all, t.apiName, t.label);
        }
        return entries;
    }

    private static void addLimit(List<OrgLimitEntry> entries, Map<String, System.OrgLimit> all, String apiName, String label) {
        System.OrgLimit ol = all.get(apiName);
        if (ol == null) return;
        OrgLimitEntry e = new OrgLimitEntry();
        e.apiName = apiName;
        e.label = label;
        e.limitValue = ol.getLimit();
        e.usedValue = ol.getValue();
        e.remainingValue = e.limitValue - e.usedValue;
        e.usedPct = e.limitValue > 0 ? (e.usedValue * 100) / e.limitValue : 0;
        entries.add(e);
    }

    /**
     * Sanitise an AsyncApexJob.ExtendedStatus before exposing to the LWC.
     *
     * Returns the input with Salesforce-id-shaped tokens (15- and 18-char
     * base62 sequences) replaced by `[id]`, then capped to 4000 chars. The
     * "Copy Bundle" button on the Diagnostics tab encourages users to paste
     * this output to forums for help — without scrubbing, a stack trace
     * could leak record ids the user wouldn't otherwise be able to read,
     * or other org-internal pointers.
     *
     * Public so KBAssessmentController.getRunDiagnostics shares the same
     * behaviour. Single source of truth.
     */
    public static String sanitiseExtendedStatus(String raw) {
        if (String.isBlank(raw)) return '';
        // 15- or 18-char alphanumerics with at least one digit and one letter.
        // Anchored with \\b to avoid matching inside longer tokens (e.g. URLs).
        // Conservative: false positives (an unrelated 18-char alphanumeric)
        // are acceptable; false negatives (a real id surviving) are not.
        String scrubbed = raw.replaceAll('\\b(?=[a-zA-Z0-9]*[a-zA-Z])(?=[a-zA-Z0-9]*[0-9])[a-zA-Z0-9]{15,18}\\b', '[id]');
        return scrubbed.length() > 4000
            ? scrubbed.substring(0, 4000) + '… (truncated)'
            : scrubbed;
    }

    private static List<AsyncFailureEntry> readRecentKbFailures() {
        // LIKE filter ensures we only surface KB-prefixed classes. We also
        // guard against null extendedStatus (which happens on successful
        // aborts) by coalescing to empty string server-side; easier for the UI.
        List<AsyncApexJob> jobs = [
            SELECT Id, ApexClass.Name, Status, ExtendedStatus, CreatedDate,
                   CompletedDate, JobType, MethodName
            FROM AsyncApexJob
            WHERE Status IN ('Failed', 'Aborted')
              AND ApexClass.Name LIKE :(KB_CLASS_PREFIX + '%')
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT :RECENT_FAILURE_LIMIT
        ];
        List<AsyncFailureEntry> entries = new List<AsyncFailureEntry>();
        for (AsyncApexJob j : jobs) {
            AsyncFailureEntry e = new AsyncFailureEntry();
            e.jobId = j.Id;
            e.className = j.ApexClass != null ? j.ApexClass.Name : '(unknown)';
            e.methodName = j.MethodName;
            e.status = j.Status;
            e.extendedStatus = sanitiseExtendedStatus(j.ExtendedStatus);
            e.jobType = j.JobType;
            e.createdAt = j.CreatedDate;
            e.completedAt = j.CompletedDate;
            entries.add(e);
        }
        return entries;
    }

    private static VectorProviderInfo readVectorProvider() {
        VectorProviderInfo info = new VectorProviderInfo();
        try {
            KB_Vector_Search_Config__c cfg = KB_Vector_Search_Config__c.getOrgDefaults();
            if (cfg != null) {
                info.implementationClass = cfg.Implementation_Class__c;
                info.searchIndexName = cfg.Search_Index_Name__c;
                info.dataSpaceName = cfg.Data_Space_Name__c;
                info.isActive = cfg.Is_Active__c;
            }
            // Independent flag: is Data Cloud CdpQuery reachable in this org?
            // Useful even when cfg.Implementation_Class__c == SOQL fallback.
            info.dataCloudAvailable = Type.forName('ConnectApi', 'CdpQuery') != null;
        } catch (Exception e) {
            info.errorMessage = e.getMessage();
        }
        return info;
    }

    private static LastRunInfo readLastRun() {
        LastRunInfo info = new LastRunInfo();
        try {
            List<KB_Assessment_Run__c> runs = [
                SELECT Id, Name, Status__c, CreatedDate,
                       Total_Articles__c, Overall_Score__c
                FROM KB_Assessment_Run__c
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!runs.isEmpty()) {
                KB_Assessment_Run__c r = runs[0];
                info.runId = r.Id;
                info.name = r.Name;
                info.status = r.Status__c;
                info.createdAt = r.CreatedDate;
                info.totalArticles = r.Total_Articles__c != null ? (Integer) r.Total_Articles__c : 0;
                info.overallScore = r.Overall_Score__c;
            }
        } catch (Exception e) {
            info.errorMessage = e.getMessage();
        }
        return info;
    }

    private static WizardStateInfo readWizardState() {
        WizardStateInfo info = new WizardStateInfo();
        try {
            KB_Setup_Wizard_State__c st = KB_Setup_Wizard_State__c.getInstance();
            if (st != null) {
                info.setupCompleted = st.Setup_Completed__c;
                info.lastValidatedAt = st.Last_Validated_At__c;
            }
        } catch (Exception e) {
            info.errorMessage = e.getMessage();
        }
        return info;
    }

    // ─── DTOs ──────────────────────────────────────────────────────────────

    public class DiagnosticSnapshot {
        @AuraEnabled public Datetime capturedAt { get; set; }
        @AuraEnabled public List<Map<String, Object>> preflightChecks { get; set; }
        @AuraEnabled public List<OrgLimitEntry> orgLimits { get; set; }
        @AuraEnabled public List<AsyncFailureEntry> recentFailures { get; set; }
        @AuraEnabled public VectorProviderInfo vectorProvider { get; set; }
        @AuraEnabled public LastRunInfo lastRun { get; set; }
        @AuraEnabled public WizardStateInfo wizardState { get; set; }
    }

    public class OrgLimitEntry {
        @AuraEnabled public String apiName { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Integer limitValue { get; set; }
        @AuraEnabled public Integer usedValue { get; set; }
        @AuraEnabled public Integer remainingValue { get; set; }
        @AuraEnabled public Integer usedPct { get; set; }
    }

    public class AsyncFailureEntry {
        @AuraEnabled public Id jobId { get; set; }
        @AuraEnabled public String className { get; set; }
        @AuraEnabled public String methodName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String extendedStatus { get; set; }
        @AuraEnabled public String jobType { get; set; }
        @AuraEnabled public Datetime createdAt { get; set; }
        @AuraEnabled public Datetime completedAt { get; set; }
    }

    public class VectorProviderInfo {
        @AuraEnabled public String implementationClass { get; set; }
        @AuraEnabled public String searchIndexName { get; set; }
        @AuraEnabled public String dataSpaceName { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
        @AuraEnabled public Boolean dataCloudAvailable { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
    }

    public class LastRunInfo {
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Datetime createdAt { get; set; }
        @AuraEnabled public Integer totalArticles { get; set; }
        @AuraEnabled public Decimal overallScore { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
    }

    public class WizardStateInfo {
        @AuraEnabled public Boolean setupCompleted { get; set; }
        @AuraEnabled public Datetime lastValidatedAt { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
    }
}
