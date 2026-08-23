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
private class KBPublishStatusHelperTest {

    @IsTest
    static void classifiesOnline() {
        Assert.isTrue(KBPublishStatusHelper.isOnline('Online'));
        Assert.isTrue(KBPublishStatusHelper.isOnline('online'), 'case-insensitive');
        Assert.isFalse(KBPublishStatusHelper.isOnline('Draft'));
        Assert.isTrue(KBPublishStatusHelper.isFixable('Online'));
    }

    @IsTest
    static void classifiesDraft() {
        Assert.isTrue(KBPublishStatusHelper.isDraft('Draft'));
        Assert.isTrue(KBPublishStatusHelper.isDraft('  draft  '), 'trims + case-insensitive');
        Assert.isFalse(KBPublishStatusHelper.isDraft('Online'));
        Assert.isTrue(KBPublishStatusHelper.isFixable('Draft'));
    }

    @IsTest
    static void classifiesArchivedAsNotFixable() {
        Assert.isTrue(KBPublishStatusHelper.isArchived('Archived'));
        Assert.isTrue(KBPublishStatusHelper.isArchived('OutdatedArchived'));
        Assert.isFalse(KBPublishStatusHelper.isFixable('Archived'));
        Assert.isFalse(KBPublishStatusHelper.isFixable('OutdatedArchived'));
    }

    @IsTest
    static void nullAndUnknownAreNotFixable() {
        Assert.isFalse(KBPublishStatusHelper.isFixable(null));
        Assert.isFalse(KBPublishStatusHelper.isFixable(''));
        Assert.isFalse(KBPublishStatusHelper.isFixable('SomethingElse'));
        Assert.isFalse(KBPublishStatusHelper.isOnline(null));
        Assert.isFalse(KBPublishStatusHelper.isArchived(null));
    }
}
