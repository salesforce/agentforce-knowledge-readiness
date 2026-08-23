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
 * Scoring contract — any class that scores an article for a dimension.
 *
 * Implemented by KBScorerBase (which all concrete scorers extend).
 * Every scorer exposes its dimension name (e.g. 'Structure', 'Clarity') so
 * the orchestrator can dispatch polymorphically.
 *
 * Facades and invocable actions can work with List<KBScorable> without
 * needing to know about KBScorerBase's utility methods.
 */
public interface KBScorable {
    /**
     * Score a single article for this dimension.
     * @param article The article data (content, title, summary, metadata)
     * @return DimensionScore with score (0-100), reasoning, issues, strengths
     */
    KBAssessmentModels.DimensionScore score(KBAssessmentModels.ArticleWrapper article);

    /**
     * The name of the dimension this scorer evaluates (e.g. 'Completeness', 'Structure').
     */
    String getDimensionName();
}
