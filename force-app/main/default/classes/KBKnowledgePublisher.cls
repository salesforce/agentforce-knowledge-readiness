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
 * Indirection over `KbManagement.PublishingService` so the publish/edit calls
 * can be stubbed in test context — `Knowledge__kav` rows inserted in tests
 * cannot reach `PublishStatus='Online'`, so the real APIs throw.
 *
 * Production callers hold `KBKnowledgePublisher.IPublisher publisher = new
 * KBKnowledgePublisher.RealPublisher()` (default); tests swap the field.
 */
public with sharing class KBKnowledgePublisher {

    public interface IPublisher {
        void publishArticle(Id knowledgeArticleId, Boolean keepAsNewVersion);
        String editOnlineArticle(Id knowledgeArticleId, Boolean unpublish);
 // retire a merged "loser" article from Online once its survivor
        // (the enriched merge target) has been published.
        void archiveOnlineArticle(Id knowledgeArticleId);
    }

    public class RealPublisher implements IPublisher {
        public void publishArticle(Id knowledgeArticleId, Boolean keepAsNewVersion) {
            KbManagement.PublishingService.publishArticle(knowledgeArticleId, keepAsNewVersion);
        }
        public String editOnlineArticle(Id knowledgeArticleId, Boolean unpublish) {
            return KbManagement.PublishingService.editOnlineArticle(knowledgeArticleId, unpublish);
        }
        public void archiveOnlineArticle(Id knowledgeArticleId) {
            // scheduledDate = null → archive immediately.
            KbManagement.PublishingService.archiveOnlineArticle(knowledgeArticleId, null);
        }
    }
}
