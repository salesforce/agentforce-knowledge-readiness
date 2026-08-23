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
 * DimensionRegistry — single source of truth for scoring dimensions.
 *
 * Reads KB_Scoring_Dimension__mdt once per transaction and caches the result.
 * Weights are resolved from KB_Score_Weight__c.Weights_JSON__c (admin-editable
 * at runtime) with fallback to the CMDT Default_Weight__c.
 *
 * Adding a new dimension:
 *   1. Deploy a new KB_Scoring_Dimension.<Name>.md-meta.xml record.
 *   2. Deploy a new scorer class referenced by Scorer_Class__c.
 *   No other code change required.
 */
public with sharing class DimensionRegistry {

    private static Map<String, DimensionDefinition> cachedAll;
    private static Map<String, Decimal> cachedWeights;

    /**
     * Runtime view of one dimension. Backed by KB_Scoring_Dimension__mdt +
     * KB_Score_Weight__c.Weights_JSON__c for the effective weight.
     */
    public class DimensionDefinition {
        public String developerName;
        public String label;
        public String scorerClass;
        public Boolean isActive;
        public Integer displayOrder;
        public Boolean requiresLLM;
        public Integer calloutsPerArticle;
        public Boolean requiresPipelineData;
        public Decimal defaultWeight;
    }

    /**
     * Returns all dimension definitions keyed by DeveloperName, active and inactive.
     */
    public static Map<String, DimensionDefinition> getAll() {
        if (cachedAll != null) return cachedAll;

        Map<String, DimensionDefinition> out = new Map<String, DimensionDefinition>();
        for (KB_Scoring_Dimension__mdt m : [
            SELECT DeveloperName, MasterLabel, Scorer_Class__c, Is_Active__c,
                   Display_Order__c, Requires_LLM__c, Callouts_Per_Article__c,
                   Requires_Pipeline_Data__c, Default_Weight__c
            FROM KB_Scoring_Dimension__mdt
            ORDER BY Display_Order__c ASC
        ]) {
            DimensionDefinition d = new DimensionDefinition();
            d.developerName = m.DeveloperName;
            d.label = m.MasterLabel;
            d.scorerClass = m.Scorer_Class__c;
            d.isActive = m.Is_Active__c == true;
            d.displayOrder = m.Display_Order__c == null ? 0 : m.Display_Order__c.intValue();
            d.requiresLLM = m.Requires_LLM__c == true;
            d.calloutsPerArticle = m.Callouts_Per_Article__c == null ? 0 : m.Callouts_Per_Article__c.intValue();
            d.requiresPipelineData = m.Requires_Pipeline_Data__c == true;
            d.defaultWeight = m.Default_Weight__c == null ? 0 : m.Default_Weight__c;
            out.put(d.developerName, d);
        }
        cachedAll = out;
        return out;
    }

    /**
     * Only Is_Active__c = true dimensions.
     */
    public static Map<String, DimensionDefinition> getActive() {
        Map<String, DimensionDefinition> out = new Map<String, DimensionDefinition>();
        for (DimensionDefinition d : getAll().values()) {
            if (d.isActive) out.put(d.developerName, d);
        }
        return out;
    }

    /**
     * Lookup a single dimension by DeveloperName. Returns null if not registered.
     */
    public static DimensionDefinition get(String developerName) {
        if (String.isBlank(developerName)) return null;
        return getAll().get(developerName);
    }

    /**
     * Set of active DeveloperNames. Replaces the old hardcoded
     * KBAssessmentModels.ALL_DIMENSIONS constant.
     */
    public static Set<String> getActiveDeveloperNames() {
        return getActive().keySet();
    }

    /**
     * Validates that every active dimension's Scorer_Class__c resolves to a
     * real Apex class that implements KBScorable. Call once at orchestrator boot
     * (e.g. in KBScoringService constructor) to surface CMDT typos early rather
     * than mid-batch via NullPointerException.
     *
     * @return List of error messages (empty = all valid).
     */
    public static List<String> validate() {
        List<String> errors = new List<String>();
        for (DimensionDefinition d : getActive().values()) {
            if (String.isBlank(d.scorerClass)) {
                errors.add(d.developerName + ': Scorer_Class__c is blank.');
                continue;
            }
            Type t = Type.forName(d.scorerClass);
            if (t == null) {
                errors.add(d.developerName + ': class "' + d.scorerClass + '" not found.');
                continue;
            }
            Object instance;
            try {
                instance = t.newInstance();
            } catch (Exception e) {
                errors.add(d.developerName + ': "' + d.scorerClass + '" cannot be instantiated: ' + e.getMessage());
                continue;
            }
            if (!(instance instanceof KBScorable)) {
                errors.add(d.developerName + ': "' + d.scorerClass + '" does not implement KBScorable.');
            }
        }
        return errors;
    }

    /**
     * Effective weight for a dimension. Reads KB_Score_Weight__c.Weights_JSON__c
     * first; falls back to CMDT Default_Weight__c if missing.
     */
    public static Decimal getWeight(String developerName) {
        Map<String, Decimal> weights = getActiveWeights();
        if (weights.containsKey(developerName)) {
            return weights.get(developerName);
        }
        DimensionDefinition d = get(developerName);
        return d == null ? 0 : d.defaultWeight;
    }

    /**
     * Effective weights for every active dimension, merging admin overrides
     * from Weights_JSON__c on top of CMDT defaults.
     */
    public static Map<String, Decimal> getActiveWeights() {
        if (cachedWeights != null) return new Map<String, Decimal>(cachedWeights);

        Map<String, Decimal> out = new Map<String, Decimal>();
        for (DimensionDefinition d : getActive().values()) {
            out.put(d.developerName, d.defaultWeight);
        }

        KB_Score_Weight__c cfg = KB_Score_Weight__c.getInstance();
        if (cfg != null && String.isNotBlank(cfg.Weights_JSON__c)) {
            try {
                Map<String, Object> raw = (Map<String, Object>) JSON.deserializeUntyped(cfg.Weights_JSON__c);
                for (String key : raw.keySet()) {
                    if (!out.containsKey(key)) continue; // ignore orphan keys
                    Object val = raw.get(key);
                    if (val instanceof Decimal) {
                        out.put(key, (Decimal) val);
                    } else if (val instanceof Double) {
                        out.put(key, Decimal.valueOf((Double) val));
                    } else if (val instanceof Integer) {
                        out.put(key, Decimal.valueOf((Integer) val));
                    } else if (val instanceof String) {
                        try {
                            out.put(key, Decimal.valueOf((String) val));
                        } catch (Exception e) {
                            // leave default
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'DimensionRegistry: Weights_JSON__c parse failed — using defaults. ' + e.getMessage());
            }
        }

        cachedWeights = out;
        return out;
    }

    /**
     * Renormalise a subset of weights to sum to 1.0. Used when a run assesses
     * only some dimensions and we want those to carry the full scoring weight.
     */
    public static Map<String, Decimal> renormalise(Set<String> selected) {
        Map<String, Decimal> full = getActiveWeights();
        // Null / empty selection → fall back to all active dimensions at their
        // configured weights. Callers that pass empty sets rely on this safety
        // net; otherwise an empty selection would silently zero out scoring.
        if (selected == null || selected.isEmpty()) {
            return full;
        }
        Map<String, Decimal> scoped = new Map<String, Decimal>();
        Decimal total = 0;
        for (String dim : selected) {
            if (full.containsKey(dim)) {
                Decimal w = full.get(dim);
                scoped.put(dim, w);
                total += (w == null ? 0 : w);
            }
        }
        if (total == 0) return scoped;
        Map<String, Decimal> out = new Map<String, Decimal>();
        for (String dim : scoped.keySet()) {
            out.put(dim, (scoped.get(dim) / total).setScale(4));
        }
        return out;
    }

    /**
     * True if any of the given dimensions is LLM-backed (Requires_LLM__c=true).
     * Used to stamp KB_Assessment_Run__c.Used_LLM__c with run *intent* at
     * creation time, before scoring has run. The actual per-score truth is
     * recorded on KB_Dimension_Result__c.Scorer_Mode__c and reconciled back
     * onto Used_LLM__c at finalization (presence of a 'Hybrid' row).
     */
    public static Boolean anyRequiresLLM(Set<String> dims) {
        if (dims == null || dims.isEmpty()) return false;
        for (String dim : dims) {
            DimensionDefinition d = get(dim);
            if (d != null && d.requiresLLM) return true;
        }
        return false;
    }

    /**
     * Estimate total Einstein callouts for a set of dimensions × article count.
     * Pipeline dims (Requires_Pipeline_Data__c=true) and deterministic dims
     * (Requires_LLM__c=false) contribute 0. LLM-off runs contribute 0 even for
     * Requires_LLM__c dims.
     *
     * Used by the facade router to pick sync/queueable/batch tier.
     */
    public static Integer estimateCallouts(Set<String> dims, Integer articleCount, Boolean llmEnabled) {
        if (articleCount == null || articleCount <= 0) return 0;
        if (dims == null || dims.isEmpty()) return 0;
        if (llmEnabled != true) return 0;
        Integer total = 0;
        for (String dim : dims) {
            DimensionDefinition d = get(dim);
            if (d == null || !d.requiresLLM) continue;
            total += d.calloutsPerArticle * articleCount;
        }
        return total;
    }

    /**
     * Test-only reset. Required because @TestVisible cached state survives
     * across test methods in the same execution context.
     */
    @TestVisible
    private static void resetCache() {
        cachedAll = null;
        cachedWeights = null;
    }
}
