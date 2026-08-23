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
 * @IsTest stub for KBKnowledgePublisher.IPublisher. Records call counts and
 * argument lists so tests can assert that production code dispatched the
 * expected number of publish/edit calls.
 *
 * Tests install via:
 *   MockKnowledgePublisher mock = new MockKnowledgePublisher();
 *   KBEnrichmentController.publisher = mock;
 *   // (or Tier3AgenticQueueable.publisher = mock;)
 */
@IsTest
public class MockKnowledgePublisher implements KBKnowledgePublisher.IPublisher {

    public Integer publishCallCount = 0;
    public Integer editCallCount = 0;
    public Integer archiveCallCount = 0;

    public Boolean throwOnPublish = false;
    public Boolean throwOnEdit = false;
    public Boolean throwOnArchive = false;

    /** When non-null, returned by editOnlineArticle so callers see a draft id. */
    public String returnDraftId;

    public List<Id> publishedArticleIds = new List<Id>();
    public List<Id> editedArticleIds = new List<Id>();
    public List<Id> archivedArticleIds = new List<Id>();

    public void publishArticle(Id knowledgeArticleId, Boolean keepAsNewVersion) {
        publishCallCount++;
        if (throwOnPublish) {
            throw new IllegalArgumentException('Mock publish failure');
        }
        publishedArticleIds.add(knowledgeArticleId);
    }

    public String editOnlineArticle(Id knowledgeArticleId, Boolean unpublish) {
        editCallCount++;
        if (throwOnEdit) {
            throw new IllegalArgumentException('Mock edit failure');
        }
        editedArticleIds.add(knowledgeArticleId);
        return returnDraftId;
    }

    public void archiveOnlineArticle(Id knowledgeArticleId) {
        archiveCallCount++;
        if (throwOnArchive) {
            throw new IllegalArgumentException('Mock archive failure');
        }
        archivedArticleIds.add(knowledgeArticleId);
    }
}

