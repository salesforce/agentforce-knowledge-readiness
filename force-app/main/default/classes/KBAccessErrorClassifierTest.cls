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
@IsTest
private class KBAccessErrorClassifierTest {

    @IsTest
    static void objectCrudDenial_isAccessDenial() {
 // VERBATIM string captured from kb-stress-test debug logs: a
        // Manager without KB_Knowledge_Author running Fix-with-AI throws this
        // System.TypeException from the USER_MODE update in KBKavDraftWriter.
        // Pinned here so the classifier is anchored to the REAL message, not an
 // assumption (addresses the Finding 1).
        Assert.isTrue(
            KBAccessErrorClassifier.isAccessDenial(
                'DML operation UPDATE not allowed on Knowledge__kav'),
            'Object-CRUD denial must classify as an access denial');
        Assert.isTrue(
            KBAccessErrorClassifier.isAccessDenial(
                'DML operation INSERT not allowed on Knowledge__kav'),
            'Insert CRUD denial (create-new merge path) must classify as an access denial');
    }

    @IsTest
    static void flsAndSharingDenials_isAccessDenial() {
        for (String raw : new List<String>{
            'insufficient access rights on cross-reference id',
            'INSUFFICIENT_PRIVILEGES: Insufficient Privileges',
            'No edit permission on field',
 // VERBATIM from kb-stress-test: the USER_MODE `update as user`
            // in resolveContradiction threw this before the narrowed-update fix.
            'Operation failed due to fields being inaccessible on Sobject Duplicate_Candidate__c, check errors on Exception or Result!'
        }) {
            Assert.isTrue(KBAccessErrorClassifier.isAccessDenial(raw),
                'Should classify as access denial: ' + raw);
        }
    }

    @IsTest
    static void governorLimit_isNotAccessDenial() {
        // Regression guard for the Finding #1 over-match: the DML governor-limit
        // message contains the words "DML operation" but is NOT an access denial.
        // Matching `not allowed on` (not the bare `DML operation`) keeps it out.
        Assert.isFalse(
            KBAccessErrorClassifier.isAccessDenial('Too many DML operations: 151'),
            'DML governor-limit must NOT be mistaken for an access denial');
    }

    @IsTest
    static void unrelatedAndBlank_isNotAccessDenial() {
        Assert.isFalse(KBAccessErrorClassifier.isAccessDenial(
            'URLName collides with an existing draft'),
            'A functional failure is not an access denial');
        Assert.isFalse(KBAccessErrorClassifier.isAccessDenial(null),
            'Null is not an access denial');
        Assert.isFalse(KBAccessErrorClassifier.isAccessDenial(''),
            'Blank is not an access denial');
    }
}
