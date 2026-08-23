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
 * Issue → recommendation/effort mapping helpers for the Freshness dimension.
 *
 * Originally this class served every dimension and also wrote KB_Recommendation__c
 * records. After absorbed that object into KB_Dimension_Analysis__c the
 * writer paths were removed, and after / the LLM emits per-issue
 * effort / priority / recommendation directly for every other dimension.
 * Freshness is the lone holdout — it's deterministic, all its issues collapse
 * to "calendar age" advice, so a tiny mapper still earns its keep here.
 */
public with sharing class KBRecommendationService {

    private static final Integer HIGH_PRIORITY_THRESHOLD   = 40;
    private static final Integer MEDIUM_PRIORITY_THRESHOLD = 70;

    @TestVisible
    private static String getPriority(Decimal score) {
        if (score == null) {
            return 'Medium';
        }
        if (score < HIGH_PRIORITY_THRESHOLD) {
            return 'High';
        }
        if (score < MEDIUM_PRIORITY_THRESHOLD) {
            return 'Medium';
        }
        return 'Low';
    }

    /**
     * Effort estimate for a Freshness issue. Calendar age always lands at
     * Medium — the user has to read the article, decide what's still true,
     * and rewrite anything stale. We accept the dimension argument so the
     * call site at KBDimensionAnalysisService stays generic, but ignore it
     * because every other dimension now sources effort from the LLM.
     */
    public static String mapIssueToEffort(String dimension, String issue) {
        return 'Medium';
    }

    /**
     * Recommendation text for a Freshness issue. Two tiers (critically old
     * vs stale) plus a generic fallback — same shape as the original mapper
     * once every non-Freshness branch was retired. As with mapIssueToEffort,
     * the dimension arg is accepted but ignored.
     */
    public static String mapIssueToRecommendation(String dimension, String issue) {
        String issueLower = issue == null ? '' : issue.toLowerCase();

        if (issueLower.contains('critical') || issueLower.contains('2 year') || issueLower.contains('24 month')) {
            return 'This article is critically outdated (2+ years since last update). Assign to a subject matter expert for immediate review. Outdated articles are a leading cause of hallucinations in Agentforce responses.';
        }
        if (issueLower.contains('stale') || issueLower.contains('12 month') || issueLower.contains('1 year') || issueLower.contains('old')) {
            return 'Review and update this article. Content not reviewed in 12+ months may contain outdated product information, deprecated procedures, or stale screenshots that mislead AI agents.';
        }
        return 'Schedule a content review for this article to ensure accuracy and currency.';
    }
}
