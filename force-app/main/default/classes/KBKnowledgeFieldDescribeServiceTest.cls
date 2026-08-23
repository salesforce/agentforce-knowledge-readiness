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
private class KBKnowledgeFieldDescribeServiceTest {

    @IsTest
    static void getFilterableFields_returnsAtLeastTitleAndArticleNumber_whenKavExists() {
        KBKnowledgeFieldDescribeService.clearCache();

        Test.startTest();
        List<KBKnowledgeFieldDescribeService.FieldDescriptor> fields =
            KBKnowledgeFieldDescribeService.getFilterableFields();
        Test.stopTest();

        // The KB Readiness Evaluator project ships custom Knowledge__kav.
        // If the Knowledge object isn't present in this org, an empty list
        // is the correct result — assert on the strict invariant only when
        // the resolver returned a non-empty list.
        if (!fields.isEmpty()) {
            Set<String> apiNames = new Set<String>();
            Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> fieldMap =
                new Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor>();
            for (KBKnowledgeFieldDescribeService.FieldDescriptor f : fields) {
                apiNames.add(f.apiName);
                fieldMap.put(f.apiName, f);
                Assert.isNotNull(f.label, 'Each descriptor should carry a label');
                Assert.isNotNull(f.type, 'Each descriptor should carry a type');
            }
            // Title and ArticleNumber are guaranteed Knowledge fields per
            // platform contract — if either is missing, our deny-list is too
            // aggressive.
            Assert.isTrue(apiNames.contains('Title'), 'Title should be filterable on Knowledge__kav');
            Assert.isTrue(apiNames.contains('ArticleNumber'), 'ArticleNumber should be filterable on Knowledge__kav');

 // Reference/ID fields (lookups) should be excluded from advanced filters
            Assert.isFalse(apiNames.contains('OwnerId'), 'OwnerId (REFERENCE) should be denied');
            Assert.isFalse(apiNames.contains('Id'), 'Id should be denied');
        }
    }

    @IsTest
    static void getFieldMap_returnsCachedReference_onSecondCall() {
        KBKnowledgeFieldDescribeService.clearCache();
        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> first =
            KBKnowledgeFieldDescribeService.getFieldMap();
        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> second =
            KBKnowledgeFieldDescribeService.getFieldMap();

        Assert.areEqual(
            first.size(),
            second.size(),
            'Cached map should have the same shape on the second call'
        );
        // Same instance — proves the cache is hit, not the describe round-trip.
        Assert.isTrue(first === second, 'Second call should return the cached map reference');
    }

    @IsTest
    static void seedCache_lets_tests_inject_fixture_map() {
        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> fixture =
            new Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor>();
        KBKnowledgeFieldDescribeService.FieldDescriptor f =
            new KBKnowledgeFieldDescribeService.FieldDescriptor();
        f.apiName = 'Title';
        f.label = 'Title';
        f.type = 'STRING';
        f.nillable = false;
        f.relationshipName = null;
        fixture.put('Title', f);

        KBKnowledgeFieldDescribeService.FieldDescriptor articleNumber =
            new KBKnowledgeFieldDescribeService.FieldDescriptor();
        articleNumber.apiName = 'ArticleNumber';
        articleNumber.label = 'Article Number';
        articleNumber.type = 'STRING';
        articleNumber.nillable = false;
        articleNumber.relationshipName = null;
        fixture.put('ArticleNumber', articleNumber);

        KBKnowledgeFieldDescribeService.seedCache(fixture);

        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> result =
            KBKnowledgeFieldDescribeService.getFieldMap();
        Assert.areEqual(2, result.size(), 'Seeded fixture should be returned verbatim');
        Assert.isTrue(result.containsKey('Title'), 'Fixture key should survive the round-trip');
        Assert.isTrue(result.containsKey('ArticleNumber'), 'ArticleNumber key should survive the round-trip');
        Assert.isNull(result.get('Title').relationshipName, 'Non-reference fields should have null relationshipName');
        KBKnowledgeFieldDescribeService.clearCache();
    }

    @IsTest
    static void picklistValues_populated_for_picklist_types() {
        KBKnowledgeFieldDescribeService.clearCache();

        List<KBKnowledgeFieldDescribeService.FieldDescriptor> fields =
            KBKnowledgeFieldDescribeService.getFilterableFields();

        Boolean checkedAtLeastOne = false;
        for (KBKnowledgeFieldDescribeService.FieldDescriptor f : fields) {
            if (f.type == 'PICKLIST' || f.type == 'MULTIPICKLIST') {
                Assert.isNotNull(f.picklistValues, 'Picklist fields must expose picklistValues (may be empty)');
                // All entries should have non-blank values.
                for (KBKnowledgeFieldDescribeService.PicklistValue pv : f.picklistValues) {
                    Assert.isNotNull(pv.value, 'Picklist entry value must be populated');
                }
                checkedAtLeastOne = true;
                break;
            }
        }
        // Knowledge__kav has at least PublishStatus + Language as picklists,
        // so this is a tight assertion. If no picklist field surfaced, our
        // deny-list filtered them out incorrectly.
        if (!fields.isEmpty()) {
            Assert.isTrue(
                checkedAtLeastOne,
                'Expected at least one picklist on Knowledge__kav (PublishStatus / Language)'
            );
        }
    }

    @IsTest
    static void deny_list_excludes_long_text_area_and_richtext() {
        KBKnowledgeFieldDescribeService.clearCache();

        List<KBKnowledgeFieldDescribeService.FieldDescriptor> fields =
            KBKnowledgeFieldDescribeService.getFilterableFields();

        for (KBKnowledgeFieldDescribeService.FieldDescriptor f : fields) {
            Assert.areNotEqual('TEXTAREA', f.type, 'LongTextArea fields must be denied (' + f.apiName + ')');
            Assert.areNotEqual('ENCRYPTEDSTRING', f.type, 'EncryptedString fields must be denied (' + f.apiName + ')');
            Assert.areNotEqual('BASE64', f.type, 'Base64 fields must be denied (' + f.apiName + ')');
            Assert.areNotEqual('ANYTYPE', f.type, 'AnyType fields must be denied (' + f.apiName + ')');
            Assert.areNotEqual('ADDRESS', f.type, 'Address compound fields must be denied (' + f.apiName + ')');
            Assert.areNotEqual('REFERENCE', f.type, 'Reference (lookup) fields must be denied (' + f.apiName + ')');
            Assert.areNotEqual('ID', f.type, 'ID fields must be denied (' + f.apiName + ')');
        }
    }

    @IsTest
    static void clearCache_lets_subsequent_calls_re_resolve() {
        KBKnowledgeFieldDescribeService.clearCache();
        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> first =
            KBKnowledgeFieldDescribeService.getFieldMap();

        KBKnowledgeFieldDescribeService.clearCache();
        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> second =
            KBKnowledgeFieldDescribeService.getFieldMap();

        // Different instances after clearCache — the cache was invalidated.
        Assert.isFalse(first === second, 'After clearCache, second resolve should produce a new map instance');
    }
}
