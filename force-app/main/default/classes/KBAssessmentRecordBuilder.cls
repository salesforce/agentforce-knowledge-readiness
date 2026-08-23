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
 * Builds KB_Article_Assessment__c (parent) and KB_Dimension_Result__c
 * (children) records for a scored article.
 *
 * The parent/child split is two separate DML operations — the builder
 * returns a ParentWithChildren wrapper so callers can insert parents first,
 * then stamp parent Ids onto children before inserting them. Batch helpers
 * (buildAll / linkAndFlatten) handle the plumbing.
 */
public with sharing class KBAssessmentRecordBuilder {

    private static final Integer TITLE_MAX = 255;
    private static final Integer NUMBER_MAX = 50;
    private static final Integer KAID_MAX = 18;
    private static final Integer LONGTEXT_MAX = 32000;
    private static final Integer REASONING_MAX = 32000;
    private static final Integer DIM_NAME_MAX = 80;

    /**
     * Bundle of records produced by build(): one parent, zero-or-more children.
     * Children's Article_Assessment__c lookup is unset until the parent is
     * inserted and linkChildren() is called.
     */
    public class ParentWithChildren {
        public KB_Article_Assessment__c parent;
        public List<KB_Dimension_Result__c> children;
        // Score wrapper retained per dimension so that KB_Dimension_Analysis__c
        // rows (issues + strengths) can be built once children carry Ids.
        public Map<String, KBAssessmentModels.DimensionScore> scoreByDimension;

        public ParentWithChildren() {
            this.children = new List<KB_Dimension_Result__c>();
            this.scoreByDimension = new Map<String, KBAssessmentModels.DimensionScore>();
        }
    }

    /**
     * Build parent + children from a single scored result. Children are
     * created for every entry in result.scoresByDim — unscored dimensions
     * are represented by absence (no child row), not by a null-score child.
     */
    public static ParentWithChildren build(
        Id runId,
        KBAssessmentModels.ArticleAssessmentResult result
    ) {
        ParentWithChildren out = new ParentWithChildren();
        if (result == null) {
            out.parent = new KB_Article_Assessment__c();
            return out;
        }

        out.parent = new KB_Article_Assessment__c(
            Assessment_Run__c = runId,
            Knowledge__c = result.articleId,
            Article_Title__c = truncate(result.articleTitle, TITLE_MAX),
            Article_Number__c = truncate(result.articleNumber, NUMBER_MAX),
            Knowledge_Article_Id__c = truncate(result.knowledgeArticleId, KAID_MAX),
            Overall_Score__c = result.overallScore,
            Readiness_Status__c = result.readinessStatus,
            Has_Conflicts__c = result.hasConflicts == true,
            Conflict_Details__c = truncate(result.conflictDetails, LONGTEXT_MAX)
        );

        if (result.scoresByDim != null) {
            for (String dim : result.scoresByDim.keySet()) {
                KBAssessmentModels.DimensionScore s = result.scoresByDim.get(dim);
                if (s == null) continue;
                out.children.add(buildChild(dim, s));
                out.scoreByDimension.put(dim, s);
            }
        }

        return out;
    }

    /**
     * Build one child dimension-result row. Parent link is set later by
     * linkChildren() after the parent record is inserted.
     */
    public static KB_Dimension_Result__c buildChild(
        String dimensionName,
        KBAssessmentModels.DimensionScore score
    ) {
        KB_Dimension_Result__c child = new KB_Dimension_Result__c();
        child.Dimension__c = truncate(dimensionName, DIM_NAME_MAX);
        child.Score__c = score == null ? null : score.score;
        child.Reasoning__c = score == null ? null : truncate(score.reasoning, REASONING_MAX);
        child.Is_Unassessable__c = score != null && score.isUnassessable == true;
        child.Scorer_Mode__c = score == null ? null : score.scorerMode;
        child.Execution_Ms__c = score == null ? null : score.executionMs;
        return child;
    }

    /**
     * Build a bundle for a batch of results. Caller is responsible for:
     *   1. Insert all parents (order-preserved against the input list).
     *   2. Call linkChildren(bundles) with the now-Id-bearing parents.
     *   3. Insert flattened children list.
     */
    public static List<ParentWithChildren> buildAll(
        Id runId,
        List<KBAssessmentModels.ArticleAssessmentResult> results
    ) {
        List<ParentWithChildren> out = new List<ParentWithChildren>();
        if (results == null) return out;
        for (KBAssessmentModels.ArticleAssessmentResult r : results) {
            out.add(build(runId, r));
        }
        return out;
    }

    /**
     * After the parent records have been inserted (and now carry Ids),
     * stamp those Ids onto their child rows so the master-detail is ready
     * for insert.
     */
    public static void linkChildren(List<ParentWithChildren> bundles) {
        if (bundles == null) return;
        for (ParentWithChildren b : bundles) {
            if (b == null || b.parent == null || b.parent.Id == null) continue;
            for (KB_Dimension_Result__c c : b.children) {
                c.Article_Assessment__c = b.parent.Id;
            }
        }
    }

    /**
     * Flatten children across bundles into a single list for DML.
     * Call after linkChildren().
     */
    public static List<KB_Dimension_Result__c> flattenChildren(List<ParentWithChildren> bundles) {
        List<KB_Dimension_Result__c> out = new List<KB_Dimension_Result__c>();
        if (bundles == null) return out;
        for (ParentWithChildren b : bundles) {
            if (b == null || b.children == null) continue;
            out.addAll(b.children);
        }
        return out;
    }

    /**
     * After parent + child dimension results are inserted, build
     * KB_Dimension_Analysis__c rows (one per issue, one per strength).
     * Children must already carry Ids when this is called.
     */
    public static List<KB_Dimension_Analysis__c> buildAnalyses(List<ParentWithChildren> bundles) {
        List<KB_Dimension_Analysis__c> out = new List<KB_Dimension_Analysis__c>();
        if (bundles == null) return out;
        for (ParentWithChildren b : bundles) {
            if (b == null || b.parent == null || b.parent.Id == null) continue;
            if (b.children == null || b.children.isEmpty()) continue;
            if (b.scoreByDimension == null || b.scoreByDimension.isEmpty()) continue;
            for (KB_Dimension_Result__c child : b.children) {
                if (child.Id == null) continue;
                KBAssessmentModels.DimensionScore s = b.scoreByDimension.get(child.Dimension__c);
                if (s == null) continue;
                out.addAll(KBDimensionAnalysisService.buildForDimension(
                    child.Id, b.parent.Id, child.Dimension__c, s
                ));
            }
        }
        return out;
    }

    /**
     * Extract the parent records for bulk DML.
     */
    public static List<KB_Article_Assessment__c> parentsOf(List<ParentWithChildren> bundles) {
        List<KB_Article_Assessment__c> out = new List<KB_Article_Assessment__c>();
        if (bundles == null) return out;
        for (ParentWithChildren b : bundles) {
            if (b == null || b.parent == null) continue;
            out.add(b.parent);
        }
        return out;
    }

    private static String truncate(String text, Integer maxLength) {
        if (text == null) return null;
        if (text.length() <= maxLength) return text;
        return text.substring(0, maxLength);
    }
}