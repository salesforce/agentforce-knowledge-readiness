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
private class KBFilterClauseCompilerTest {

    /** Build a fixture FieldDescriptor for the given type. */
    private static KBKnowledgeFieldDescribeService.FieldDescriptor fd(String apiName, String type) {
        KBKnowledgeFieldDescribeService.FieldDescriptor f = new KBKnowledgeFieldDescribeService.FieldDescriptor();
        f.apiName = apiName;
        f.label = apiName;
        f.type = type;
        f.nillable = true;
        return f;
    }

    private static KBKnowledgeFieldDescribeService.FieldDescriptor fdPicklist(String apiName, List<String> active) {
        KBKnowledgeFieldDescribeService.FieldDescriptor f = fd(apiName, 'PICKLIST');
        for (String v : active) {
            f.picklistValues.add(new KBKnowledgeFieldDescribeService.PicklistValue(v, v, true));
        }
        return f;
    }

    private static KBKnowledgeFieldDescribeService.FieldDescriptor fdMultipicklist(String apiName, List<String> active) {
        KBKnowledgeFieldDescribeService.FieldDescriptor f = fd(apiName, 'MULTIPICKLIST');
        for (String v : active) {
            f.picklistValues.add(new KBKnowledgeFieldDescribeService.PicklistValue(v, v, true));
        }
        return f;
    }

    private static Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> standardFields() {
        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> fields =
            new Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor>();
        fields.put('Title', fd('Title', 'STRING'));
        fields.put('Summary', fd('Summary', 'STRING'));
        fields.put('ArticleNumber', fd('ArticleNumber', 'STRING'));
        fields.put('PublishStatus', fdPicklist('PublishStatus', new List<String>{'Online', 'Draft', 'Archived'}));
        fields.put('Language', fdPicklist('Language', new List<String>{'en_US', 'fr'}));
        fields.put('LastModifiedDate', fd('LastModifiedDate', 'DATETIME'));
        fields.put('CreatedDate', fd('CreatedDate', 'DATE'));
        fields.put('IsLatestVersion', fd('IsLatestVersion', 'BOOLEAN'));
        fields.put('VersionNumber', fd('VersionNumber', 'INTEGER'));
        fields.put('OwnerId', fd('OwnerId', 'REFERENCE'));
        fields.put('Categories__c', fdMultipicklist('Categories__c', new List<String>{'A', 'B', 'C'}));
        return fields;
    }

    private static KBAssessmentModels.FilterClause clause(String field, String operator, String value) {
        KBAssessmentModels.FilterClause c = new KBAssessmentModels.FilterClause();
        c.field = field;
        c.operator = operator;
        c.value = value;
        return c;
    }

    @IsTest
    static void compile_String_Contains_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('Title', 'contains', 'router'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('Title LIKE \'%router%\'', r.soqlFragment);
    }

    @IsTest
    static void compile_String_Contains_EscapesSingleQuote() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('Title', 'contains', 'O\'Brien'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        // String.escapeSingleQuotes turns ' into \'
        Assert.isTrue(r.soqlFragment.contains('O\\\'Brien'),
            'Expected escaped quote in fragment: ' + r.soqlFragment);
    }

    @IsTest
    static void compile_String_StartsWith_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('Title', 'startsWith', 'How'), standardFields());
        Assert.isTrue(r.valid);
        Assert.areEqual('Title LIKE \'How%\'', r.soqlFragment);
    }

    @IsTest
    static void compile_String_Eq_And_Ne() {
        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> fields = standardFields();
        Assert.areEqual('Title = \'X\'',
            KBFilterClauseCompiler.compile(clause('Title', 'eq', 'X'), fields).soqlFragment);
        Assert.areEqual('Title != \'X\'',
            KBFilterClauseCompiler.compile(clause('Title', 'ne', 'X'), fields).soqlFragment);
    }

    @IsTest
    static void compile_Number_Gt_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('VersionNumber', 'gt', '5'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('VersionNumber > 5', r.soqlFragment);
    }

    @IsTest
    static void compile_Number_NonNumeric_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('VersionNumber', 'gt', 'foo'), standardFields());
        Assert.isFalse(r.valid);
        Assert.isTrue(r.errorMessage.contains('Non-numeric'), 'Expected non-numeric error: ' + r.errorMessage);
    }

    @IsTest
    static void compile_Number_All_Operators() {
        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> fields = standardFields();
        Assert.areEqual('VersionNumber = 1',
            KBFilterClauseCompiler.compile(clause('VersionNumber', 'eq', '1'), fields).soqlFragment);
        Assert.areEqual('VersionNumber != 1',
            KBFilterClauseCompiler.compile(clause('VersionNumber', 'ne', '1'), fields).soqlFragment);
        Assert.areEqual('VersionNumber >= 1',
            KBFilterClauseCompiler.compile(clause('VersionNumber', 'gte', '1'), fields).soqlFragment);
        Assert.areEqual('VersionNumber < 1',
            KBFilterClauseCompiler.compile(clause('VersionNumber', 'lt', '1'), fields).soqlFragment);
        Assert.areEqual('VersionNumber <= 1',
            KBFilterClauseCompiler.compile(clause('VersionNumber', 'lte', '1'), fields).soqlFragment);
    }

    @IsTest
    static void compile_Date_LastNDays_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('CreatedDate', 'lastNDays', '30'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('CreatedDate = LAST_N_DAYS:30', r.soqlFragment);
    }

    @IsTest
    static void compile_Date_LastNDays_NonInteger_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('CreatedDate', 'lastNDays', '30.5'), standardFields());
        Assert.isFalse(r.valid);
        Assert.isTrue(r.errorMessage.contains('integer'), 'Expected integer error: ' + r.errorMessage);
    }

    @IsTest
    static void compile_Date_LastNDays_Negative_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('CreatedDate', 'lastNDays', '-1'), standardFields());
        Assert.isFalse(r.valid);
        Assert.isTrue(r.errorMessage.contains('non-negative'), 'Expected non-negative error: ' + r.errorMessage);
    }

    @IsTest
    static void compile_Date_Gte_PlainDate_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('CreatedDate', 'gte', '2026-01-15'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('CreatedDate >= 2026-01-15', r.soqlFragment);
    }

    @IsTest
    static void compile_Datetime_Gte_PlainDate_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('LastModifiedDate', 'gte', '2026-01-15'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('LastModifiedDate >= 2026-01-15T00:00:00Z', r.soqlFragment);
    }

    @IsTest
    static void compile_Datetime_Iso8601Z_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('LastModifiedDate', 'gte', '2026-01-15T08:30:00Z'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('LastModifiedDate >= 2026-01-15T08:30:00Z', r.soqlFragment);
    }

    @IsTest
    static void compile_Date_Invalid_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('CreatedDate', 'gte', 'not-a-date'), standardFields());
        Assert.isFalse(r.valid);
    }

    @IsTest
    static void compile_Reference_Eq_ValidId_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('OwnerId', 'eq', '005000000000000AAA'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('OwnerId = \'005000000000000AAA\'', r.soqlFragment);
    }

    @IsTest
    static void compile_Reference_InvalidId_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('OwnerId', 'eq', 'not-an-id'), standardFields());
        Assert.isFalse(r.valid);
        Assert.isTrue(r.errorMessage.contains('Salesforce id'), 'Expected id-format error: ' + r.errorMessage);
    }

    @IsTest
    static void compile_Reference_Contains_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('OwnerId', 'contains', '005000000000000AAA'), standardFields());
        Assert.isFalse(r.valid);
    }

    @IsTest
    static void compile_Multipicklist_Includes_OK() {
        KBAssessmentModels.FilterClause c = new KBAssessmentModels.FilterClause();
        c.field = 'Categories__c';
        c.operator = 'includes';
        c.values = new List<String>{ 'A', 'B' };
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(c, standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('Categories__c INCLUDES (\'A\', \'B\')', r.soqlFragment);
    }

    @IsTest
    static void compile_Multipicklist_Excludes_OK() {
        KBAssessmentModels.FilterClause c = new KBAssessmentModels.FilterClause();
        c.field = 'Categories__c';
        c.operator = 'excludes';
        c.values = new List<String>{ 'C' };
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(c, standardFields());
        Assert.isTrue(r.valid);
        Assert.areEqual('Categories__c EXCLUDES (\'C\')', r.soqlFragment);
    }

    @IsTest
    static void compile_Multipicklist_UnknownValue_Rejects() {
        KBAssessmentModels.FilterClause c = new KBAssessmentModels.FilterClause();
        c.field = 'Categories__c';
        c.operator = 'includes';
        c.values = new List<String>{ 'NotAValue' };
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(c, standardFields());
        Assert.isFalse(r.valid);
        Assert.isTrue(r.errorMessage.contains('Unknown picklist value'),
            'Expected unknown-value error: ' + r.errorMessage);
    }

    @IsTest
    static void compile_Multipicklist_FromSemicolonValue_OK() {
        KBAssessmentModels.FilterClause c = new KBAssessmentModels.FilterClause();
        c.field = 'Categories__c';
        c.operator = 'includes';
        c.value = 'A;B';
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(c, standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('Categories__c INCLUDES (\'A\', \'B\')', r.soqlFragment);
    }

    @IsTest
    static void compile_Multipicklist_NoValues_Rejects() {
        KBAssessmentModels.FilterClause c = new KBAssessmentModels.FilterClause();
        c.field = 'Categories__c';
        c.operator = 'includes';
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(c, standardFields());
        Assert.isFalse(r.valid);
    }

    @IsTest
    static void compile_IsNull_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('Title', 'isNull', null), standardFields());
        Assert.isTrue(r.valid);
        Assert.areEqual('Title = null', r.soqlFragment);
    }

    @IsTest
    static void compile_IsNotNull_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('Title', 'isNotNull', null), standardFields());
        Assert.isTrue(r.valid);
        Assert.areEqual('Title != null', r.soqlFragment);
    }

    @IsTest
    static void compile_Boolean_Eq_True_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('IsLatestVersion', 'eq', 'true'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('IsLatestVersion = true', r.soqlFragment);
    }

    @IsTest
    static void compile_Boolean_Eq_BadValue_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('IsLatestVersion', 'eq', 'maybe'), standardFields());
        Assert.isFalse(r.valid);
    }

    @IsTest
    static void compile_UnknownField_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('Bogus__c', 'eq', 'X'), standardFields());
        Assert.isFalse(r.valid);
        Assert.isTrue(r.errorMessage.contains('Unknown'), 'Expected unknown-field error: ' + r.errorMessage);
    }

    @IsTest
    static void compile_TypeOperatorMismatch_Rejects() {
        // gt is not allowed on STRING
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('Title', 'gt', 'X'), standardFields());
        Assert.isFalse(r.valid);
        Assert.isTrue(r.errorMessage.contains('not allowed for type'),
            'Expected operator-mismatch error: ' + r.errorMessage);
    }

    @IsTest
    static void compile_LegacyAlias_RoundTrips() {
        // 'title' (lowercase) should resolve to 'Title' via the legacy alias map.
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('title', 'contains', 'foo'), standardFields());
        Assert.isTrue(r.valid, 'Expected legacy alias to resolve: ' + r.errorMessage);
        Assert.areEqual('Title LIKE \'%foo%\'', r.soqlFragment);
    }

    @IsTest
    static void compile_NullClause_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(null, standardFields());
        Assert.isFalse(r.valid);
    }

    @IsTest
    static void compile_BlankFieldOrOperator_Rejects() {
        KBFilterClauseCompiler.CompileResult r1 =
            KBFilterClauseCompiler.compile(clause(null, 'eq', 'X'), standardFields());
        Assert.isFalse(r1.valid);
        KBFilterClauseCompiler.CompileResult r2 =
            KBFilterClauseCompiler.compile(clause('Title', null, 'X'), standardFields());
        Assert.isFalse(r2.valid);
    }

    @IsTest
    static void compile_EmptyFieldsMap_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('Title', 'eq', 'X'),
                new Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor>());
        Assert.isFalse(r.valid);
    }

    @IsTest
    static void compile_Picklist_UnknownValue_Rejects() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('PublishStatus', 'eq', 'NotAStatus'), standardFields());
        Assert.isFalse(r.valid);
        Assert.isTrue(r.errorMessage.contains('Unknown picklist value'),
            'Expected picklist-rejection: ' + r.errorMessage);
    }

    @IsTest
    static void compile_Picklist_KnownValue_OK() {
        KBFilterClauseCompiler.CompileResult r =
            KBFilterClauseCompiler.compile(clause('PublishStatus', 'eq', 'Online'), standardFields());
        Assert.isTrue(r.valid, 'Expected valid: ' + r.errorMessage);
        Assert.areEqual('PublishStatus = \'Online\'', r.soqlFragment);
    }
}
