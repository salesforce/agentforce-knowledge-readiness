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
 * @IsTest stub for KBKavDraftWriter. Records the Knowledge__kav rows passed to
 * writeDraft (without DML) so tests can assert which articles a flow attempted
 * to write — and, crucially, that the keep-survivor flow writes ONLY the
 * survivor draft and never the loser article (the merge link lives on the
 * Duplicate_Candidate__c junction, not on the loser — see Tier4ConsolidationAction).
 *
 * Install via: Tier4ConsolidationAction.draftWriter = new MockKavDraftWriter();
 */
@IsTest
public class MockKavDraftWriter extends KBKavDraftWriter {

    public Integer writeCallCount = 0;
    public List<Knowledge__kav> writtenDrafts = new List<Knowledge__kav>();

    public override void writeDraft(Knowledge__kav kav) {
        writeCallCount++;
        writtenDrafts.add(kav);
    }
}
