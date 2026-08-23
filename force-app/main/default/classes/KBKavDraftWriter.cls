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
 * Sharing-respecting writer for AI-generated `Knowledge__kav` drafts.
 *
 * Writes go through `Database.update(record, AccessLevel.USER_MODE)` in a
 * `with sharing` class, so the running user's **object CRUD, field-level
 * security, and record sharing** are all enforced. This is the write half of
 * both the AI Fix flow (`KBImprovementFixService.persistDraft`) and the merge
 * survivor-enrichment path (`Tier4ConsolidationAction`).
 *
 * Why enforce (reversed in): a user must hold Knowledge write access
 * shipped via the `KB_Knowledge_Author` permission set — to push a Draft. An
 * analysis-only user (`KB_Assessment_Manager` without the author set) is
 * blocked here rather than silently writing past the org's access model. The
 * caller catches the resulting `System.NoAccessException` / DML exception and
 * surfaces the friendly "assign KB Knowledge Author" message. Running the write
 * in `with sharing` / user mode (rather than elevating past the org's access
 * model) is intentional: a user without Knowledge write access must be blocked,
 * not silently allowed to write.
 */
public with sharing virtual class KBKavDraftWriter {

    public virtual void writeDraft(Knowledge__kav kav) {
        Database.update(kav, AccessLevel.USER_MODE);
    }
}
