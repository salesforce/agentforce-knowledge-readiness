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
 * Compiles a single FilterClause into a SOQL fragment, with full per-type
 * operator vocabulary + SOQL injection guard. Single source of truth for
 * legacy buildDslWhereClause and the new formula path (KBFilterFormulaParser).
 *
 * Pure logic: no SOQL, no DML. Field validation goes through the describe-
 * derived map (KBKnowledgeFieldDescribeService) so no client-supplied field
 * name reaches Database.query without first appearing as a key in that map.
 *
 * Operator vocabulary by type group (plan §2):
 *   - String / Picklist / Email / Phone / URL / Reference: eq, ne, contains,
 *     startsWith, isNull, isNotNull
 *   - Number / Currency / Percent / Double: eq, ne, gt, gte, lt, lte,
 *     isNull, isNotNull
 *   - Date / DateTime: eq, ne, gte, lte, lastNDays, isNull, isNotNull
 *   - Boolean: eq, isNull, isNotNull
 *   - Multipicklist: includes, excludes, isNull, isNotNull
 */
public with sharing class KBFilterClauseCompiler {

    public class CompileResult {
        @AuraEnabled public Boolean valid { get; set; }
        @AuraEnabled public String soqlFragment { get; set; }
        @AuraEnabled public String errorMessage { get; set; }

        public CompileResult() {
            this.valid = false;
            this.soqlFragment = null;
            this.errorMessage = null;
        }
    }

    // Apex disallows `static` on inner-class methods, so the result helpers
    // live on the outer class. Same call sites: success(...)
    // → KBFilterClauseCompiler.success(...).
    @TestVisible
    private static CompileResult success(String soqlFragment) {
        CompileResult r = new CompileResult();
        r.valid = true;
        r.soqlFragment = soqlFragment;
        return r;
    }

    @TestVisible
    private static CompileResult fail(String message) {
        CompileResult r = new CompileResult();
        r.valid = false;
        r.errorMessage = message;
        return r;
    }

    /**
     * Legacy alias map — preserves backwards compat with the original
 * lowercase UI aliases shipped before. Both forms (`title` and
     * `Title`) round-trip during the transition window.
     */
    @TestVisible
    private static final Map<String, String> LEGACY_FIELD_ALIASES = new Map<String, String>{
        'title' => 'Title',
        'summary' => 'Summary',
        'articleNumber' => 'ArticleNumber',
        'publishStatus' => 'PublishStatus',
        'language' => 'Language',
        'lastModifiedDate' => 'LastModifiedDate'
    };

    private static final Set<String> STRING_TYPES = new Set<String>{
        'STRING', 'PICKLIST', 'EMAIL', 'PHONE', 'URL', 'REFERENCE', 'ID', 'COMBOBOX'
    };
    private static final Set<String> NUMBER_TYPES = new Set<String>{
        'INTEGER', 'DOUBLE', 'CURRENCY', 'PERCENT', 'LONG'
    };
    private static final Set<String> DATE_TYPES = new Set<String>{
        'DATE', 'DATETIME', 'TIME'
    };

    private static final Set<String> STRING_OPS = new Set<String>{
        'eq', 'ne', 'contains', 'startsWith', 'isNull', 'isNotNull'
    };
    private static final Set<String> NUMBER_OPS = new Set<String>{
        'eq', 'ne', 'gt', 'gte', 'lt', 'lte', 'isNull', 'isNotNull'
    };
    private static final Set<String> DATE_OPS = new Set<String>{
        'eq', 'ne', 'gte', 'lte', 'lastNDays', 'isNull', 'isNotNull'
    };
    private static final Set<String> BOOLEAN_OPS = new Set<String>{
        'eq', 'isNull', 'isNotNull'
    };
    private static final Set<String> MULTIPICKLIST_OPS = new Set<String>{
        'includes', 'excludes', 'isNull', 'isNotNull'
    };

    private static final Pattern SF_ID_PATTERN = Pattern.compile('^[a-zA-Z0-9]{15,18}$');
    private static final Pattern INTEGER_PATTERN = Pattern.compile('^-?\\d+$');

    /**
     * Compile a single clause to a SOQL fragment. Returns CompileResult.error
     * when the clause is invalid (unknown field, wrong operator for type,
     * malformed value). Caller decides whether to drop the clause silently,
     * surface to the user, or short-circuit the whole filter.
     *
     * @param clause   client-supplied clause (untrusted)
     * @param fields   describe-derived field map (allowlist)
     */
    public static CompileResult compile(
        KBAssessmentModels.FilterClause clause,
        Map<String, KBKnowledgeFieldDescribeService.FieldDescriptor> fields
    ) {
        if (clause == null) {
            return fail('Clause is null');
        }
        if (String.isBlank(clause.field) || String.isBlank(clause.operator)) {
            return fail('Field and operator are required');
        }
        if (fields == null || fields.isEmpty()) {
            return fail('No filterable fields available');
        }

        // Resolve API name through the legacy alias map first, then fall
        // through to the describe-derived allowlist. Anything that isn't
        // a key in that final map is rejected — never concatenate a
        // client-supplied name into SOQL without describe verification.
        String fieldKey = clause.field.trim();
        String apiName = LEGACY_FIELD_ALIASES.containsKey(fieldKey)
            ? LEGACY_FIELD_ALIASES.get(fieldKey)
            : fieldKey;

        if (!fields.containsKey(apiName)) {
            return fail('Unknown or non-filterable field: ' + clause.field);
        }
        KBKnowledgeFieldDescribeService.FieldDescriptor fd = fields.get(apiName);
        String type = String.isNotBlank(fd.type) ? fd.type.toUpperCase() : '';
        String op = clause.operator.trim();

        // null-checks short-circuit the value validation since they don't
        // carry one.
        if (op == 'isNull') {
            if (!operatorAllowedForType(op, type)) {
                return fail('Operator isNull not allowed for type ' + type);
            }
            return success(apiName + ' = null');
        }
        if (op == 'isNotNull') {
            if (!operatorAllowedForType(op, type)) {
                return fail('Operator isNotNull not allowed for type ' + type);
            }
            return success(apiName + ' != null');
        }

        if (!operatorAllowedForType(op, type)) {
            return fail('Operator ' + op + ' not allowed for type ' + type);
        }

        if (STRING_TYPES.contains(type)) {
            return compileStringOp(apiName, type, op, clause, fd);
        }
        if (NUMBER_TYPES.contains(type)) {
            return compileNumberOp(apiName, op, clause);
        }
        if (DATE_TYPES.contains(type)) {
            return compileDateOp(apiName, type, op, clause);
        }
        if (type == 'BOOLEAN') {
            return compileBooleanOp(apiName, op, clause);
        }
        if (type == 'MULTIPICKLIST') {
            return compileMultipicklistOp(apiName, op, clause, fd);
        }

        return fail('Unsupported field type: ' + type);
    }

    @TestVisible
    private static Boolean operatorAllowedForType(String op, String type) {
        if (STRING_TYPES.contains(type)) return STRING_OPS.contains(op);
        if (NUMBER_TYPES.contains(type)) return NUMBER_OPS.contains(op);
        if (DATE_TYPES.contains(type)) return DATE_OPS.contains(op);
        if (type == 'BOOLEAN') return BOOLEAN_OPS.contains(op);
        if (type == 'MULTIPICKLIST') return MULTIPICKLIST_OPS.contains(op);
        return false;
    }

    private static CompileResult compileStringOp(
        String apiName, String type, String op,
        KBAssessmentModels.FilterClause clause,
        KBKnowledgeFieldDescribeService.FieldDescriptor fd
    ) {
        if (clause.value == null) {
            return fail('Value required for operator ' + op);
        }
        String raw = clause.value.trim();

        // Reference: 15/18-char SF id pattern. Anything else gets rejected
        // before the value reaches SOQL.
        if (type == 'REFERENCE' || type == 'ID') {
            if (!SF_ID_PATTERN.matcher(raw).matches()) {
                return fail('Invalid Salesforce id format: ' + raw);
            }
            // Ids are alphanumeric — escapeSingleQuotes is overkill but
            // cheap defense in depth.
            String escaped = String.escapeSingleQuotes(raw);
            if (op == 'eq') return success(apiName + ' = \'' + escaped + '\'');
            if (op == 'ne') return success(apiName + ' != \'' + escaped + '\'');
            // contains/startsWith on ids isn't useful — reject for clarity.
            return fail('Operator ' + op + ' is not supported on Reference fields');
        }

        // Picklist: validate against active values from describe.
        if (type == 'PICKLIST') {
            CompileResult picklistCheck = validatePicklistValue(raw, fd);
            if (picklistCheck != null) return picklistCheck;
        }

        String escaped = String.escapeSingleQuotes(raw);
        if (op == 'eq') {
            return success(apiName + ' = \'' + escaped + '\'');
        }
        if (op == 'ne') {
            return success(apiName + ' != \'' + escaped + '\'');
        }
        if (op == 'contains') {
            return success(apiName + ' LIKE \'%' + escaped + '%\'');
        }
        if (op == 'startsWith') {
            return success(apiName + ' LIKE \'' + escaped + '%\'');
        }
        return fail('Unhandled string operator: ' + op);
    }

    private static CompileResult compileNumberOp(
        String apiName, String op,
        KBAssessmentModels.FilterClause clause
    ) {
        if (clause.value == null) {
            return fail('Value required for operator ' + op);
        }
        Decimal d;
        try {
            d = Decimal.valueOf(clause.value.trim());
        } catch (Exception e) {
            return fail('Non-numeric value: ' + clause.value);
        }
        Map<String, String> opToSql = new Map<String, String>{
            'eq' => '=', 'ne' => '!=', 'gt' => '>', 'gte' => '>=', 'lt' => '<', 'lte' => '<='
        };
        if (!opToSql.containsKey(op)) {
            return fail('Unhandled number operator: ' + op);
        }
        return success(apiName + ' ' + opToSql.get(op) + ' ' + String.valueOf(d));
    }

    private static CompileResult compileDateOp(
        String apiName, String type, String op,
        KBAssessmentModels.FilterClause clause
    ) {
        if (op == 'lastNDays') {
            // Single integer, no Date.valueOf needed. SOQL accepts the LAST_N_DAYS:N
            // date literal directly — no escaping needed because we re-stringify
            // an already-typed Integer.
            String raw = clause.value != null ? clause.value.trim() : '';
            if (!INTEGER_PATTERN.matcher(raw).matches()) {
                return fail('lastNDays expects an integer, got: ' + raw);
            }
            Integer days;
            try {
                days = Integer.valueOf(raw);
            } catch (Exception e) {
                return fail('lastNDays expects an integer, got: ' + raw);
            }
            if (days < 0) {
                return fail('lastNDays expects a non-negative integer');
            }
            return success(apiName + ' = LAST_N_DAYS:' + String.valueOf(days));
        }

        String raw = clause.value != null ? clause.value.trim() : '';
        String literal;
        try {
            // Accept both yyyy-MM-dd and yyyy-MM-ddTHH:mm:ssZ. Date.valueOf
            // handles the date form; for datetime we trust the ISO8601 from
            // the LWC's lightning-input[type=datetime].
            if (type == 'DATE') {
                Date d = Date.valueOf(raw);
                literal = d.year() + '-'
                    + leftPad(d.month()) + '-'
                    + leftPad(d.day());
            } else {
                // DateTime / Time: parse to a Datetime then re-format as
                // SOQL ISO8601. We avoid Datetime.parse (locale-aware) and
                // use Datetime.valueOfGmt with the form yyyy-MM-dd HH:mm:ss
                // when the input matches the SOQL expectation.
                literal = toDateTimeLiteral(raw);
                if (literal == null) {
                    return fail('Invalid date/datetime: ' + raw);
                }
            }
        } catch (Exception e) {
            return fail('Invalid date value: ' + raw);
        }
        Map<String, String> opToSql = new Map<String, String>{
            'eq' => '=', 'ne' => '!=', 'gte' => '>=', 'lte' => '<='
        };
        if (!opToSql.containsKey(op)) {
            return fail('Unhandled date operator: ' + op);
        }
        return success(apiName + ' ' + opToSql.get(op) + ' ' + literal);
    }

    private static String leftPad(Integer n) {
        return n < 10 ? '0' + String.valueOf(n) : String.valueOf(n);
    }

    @TestVisible
    private static String toDateTimeLiteral(String raw) {
        if (String.isBlank(raw)) return null;
        // ISO datetime first — Apex Date.valueOf is permissive and silently
        // drops the time component on `2026-01-15T08:30:00Z`, so we MUST
        // check for the 'T' separator before attempting the plain-date path.
        if (raw.contains('T') || raw.contains(':')) {
            try {
                String normalised = raw.replace('T', ' ').replace('Z', '');
                Integer dot = normalised.indexOf('.');
                if (dot > 0) {
                    normalised = normalised.substring(0, dot);
                }
                DateTime dt = DateTime.valueOfGmt(normalised);
                return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            } catch (Exception e) {
                return null;
            }
        }
        try {
            // Plain date — promotes to midnight UTC.
            Date d = Date.valueOf(raw);
            DateTime dt = DateTime.newInstanceGmt(d, Time.newInstance(0, 0, 0, 0));
            return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        } catch (Exception e) {
            return null;
        }
    }

    private static CompileResult compileBooleanOp(
        String apiName, String op,
        KBAssessmentModels.FilterClause clause
    ) {
        if (op != 'eq') {
            return fail('Unhandled boolean operator: ' + op);
        }
        if (clause.value == null) {
            return fail('Boolean clause requires a value');
        }
        String v = clause.value.trim().toLowerCase();
        if (v != 'true' && v != 'false') {
            return fail('Boolean value must be true or false: ' + clause.value);
        }
        return success(apiName + ' = ' + v);
    }

    private static CompileResult compileMultipicklistOp(
        String apiName, String op,
        KBAssessmentModels.FilterClause clause,
        KBKnowledgeFieldDescribeService.FieldDescriptor fd
    ) {
        List<String> values = clause.values;
        if (values == null || values.isEmpty()) {
            // Allow comma-separated `value` as a fallback for clients that
            // serialise multipicklist payloads as a single string.
            if (String.isNotBlank(clause.value)) {
                values = clause.value.split(';');
            }
        }
        if (values == null || values.isEmpty()) {
            return fail('Multipicklist operator ' + op + ' requires at least one value');
        }

        // Build the active-value allowlist from describe so a user can't
        // smuggle a SOQL fragment through the values list.
        Set<String> active = new Set<String>();
        if (fd.picklistValues != null) {
            for (KBKnowledgeFieldDescribeService.PicklistValue pv : fd.picklistValues) {
                if (pv.active != null && pv.active && pv.value != null) {
                    active.add(pv.value);
                }
            }
        }

        List<String> escaped = new List<String>();
        for (String v : values) {
            if (v == null) continue;
            String trimmed = v.trim();
            if (String.isBlank(trimmed)) continue;
            if (!active.isEmpty() && !active.contains(trimmed)) {
                return fail('Unknown picklist value for ' + apiName + ': ' + trimmed);
            }
            escaped.add('\'' + String.escapeSingleQuotes(trimmed) + '\'');
        }
        if (escaped.isEmpty()) {
            return fail('Multipicklist operator ' + op + ' requires at least one non-blank value');
        }
        String valueList = '(' + String.join(escaped, ', ') + ')';
        if (op == 'includes') {
            return success(apiName + ' INCLUDES ' + valueList);
        }
        if (op == 'excludes') {
            return success(apiName + ' EXCLUDES ' + valueList);
        }
        return fail('Unhandled multipicklist operator: ' + op);
    }

    private static CompileResult validatePicklistValue(
        String raw,
        KBKnowledgeFieldDescribeService.FieldDescriptor fd
    ) {
        if (fd == null || fd.picklistValues == null || fd.picklistValues.isEmpty()) {
            return null; // describe didn't expose values — fall through to escape-and-bind
        }
        Set<String> active = new Set<String>();
        for (KBKnowledgeFieldDescribeService.PicklistValue pv : fd.picklistValues) {
            if (pv.active != null && pv.active && pv.value != null) {
                active.add(pv.value);
            }
        }
        if (active.isEmpty()) return null;
        if (!active.contains(raw)) {
            return fail('Unknown picklist value: ' + raw);
        }
        return null;
    }
}
