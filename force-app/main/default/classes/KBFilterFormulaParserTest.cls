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
private class KBFilterFormulaParserTest {

    private static Map<Integer, String> stubFragments(Integer maxN) {
        Map<Integer, String> m = new Map<Integer, String>();
        for (Integer i = 1; i <= maxN; i++) {
            m.put(i, 'C' + i);
        }
        return m;
    }

    @IsTest
    static void parse_AndOnly_OK() {
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('1 AND 2 AND 3', 3);
        Assert.isNotNull(p.root);
        String soql = KBFilterFormulaParser.compile(p, stubFragments(3));
        // Flattened AND chain: ((C1) AND (C2) AND (C3))
        Assert.areEqual('((C1) AND (C2) AND (C3))', soql);
    }

    @IsTest
    static void parse_OrOnly_OK() {
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('1 OR 2', 2);
        String soql = KBFilterFormulaParser.compile(p, stubFragments(2));
        Assert.areEqual('((C1) OR (C2))', soql);
    }

    @IsTest
    static void parse_NestedParens_OK() {
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('((1 OR 2) AND (3 OR 4))', 4);
        String soql = KBFilterFormulaParser.compile(p, stubFragments(4));
        Assert.areEqual('(((C1) OR (C2)) AND ((C3) OR (C4)))', soql);
    }

    @IsTest
    static void parse_DeeplyNested_OK_at_max_depth() {
        // Build exactly 10 levels — '((((((((((1))))))))))'
        String formula = '';
        for (Integer i = 0; i < 10; i++) formula += '(';
        formula += '1';
        for (Integer i = 0; i < 10; i++) formula += ')';
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse(formula, 1);
        Assert.isNotNull(p.root);
        Assert.areEqual('(C1)', KBFilterFormulaParser.compile(p, stubFragments(1)));
    }

    @IsTest
    static void parse_DeeplyNested_FailsBeyondMax() {
        String formula = '';
        for (Integer i = 0; i < 11; i++) formula += '(';
        formula += '1';
        for (Integer i = 0; i < 11; i++) formula += ')';
        try {
            KBFilterFormulaParser.parse(formula, 1);
            Assert.fail('Expected nesting-depth error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            Assert.isTrue(e.getMessage().contains('nesting'),
                'Expected nesting-depth message: ' + e.getMessage());
        }
    }

    @IsTest
    static void parse_NotOperator_OK() {
        KBFilterFormulaParser.ParsedFormula p1 = KBFilterFormulaParser.parse('NOT 1', 1);
        Assert.areEqual('NOT (C1)', KBFilterFormulaParser.compile(p1, stubFragments(1)));

        KBFilterFormulaParser.ParsedFormula p2 = KBFilterFormulaParser.parse('NOT (1 AND 2)', 2);
        Assert.areEqual('NOT ((C1) AND (C2))', KBFilterFormulaParser.compile(p2, stubFragments(2)));

        KBFilterFormulaParser.ParsedFormula p3 = KBFilterFormulaParser.parse('1 AND NOT 2', 2);
        Assert.areEqual('((C1) AND NOT (C2))', KBFilterFormulaParser.compile(p3, stubFragments(2)));
    }

    @IsTest
    static void parse_DoubleNot_OK() {
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('NOT NOT 1', 1);
        Assert.areEqual('NOT NOT (C1)', KBFilterFormulaParser.compile(p, stubFragments(1)));
    }

    @IsTest
    static void parse_DanglingClauseNumber_Rejects() {
        try {
            KBFilterFormulaParser.parse('1 AND 99', 3);
            Assert.fail('Expected out-of-range error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            Assert.isTrue(e.getMessage().contains('out of range'),
                'Expected out-of-range message: ' + e.getMessage());
        }
    }

    @IsTest
    static void parse_ClauseZero_Rejects() {
        try {
            KBFilterFormulaParser.parse('0 AND 1', 3);
            Assert.fail('Expected zero-rejected');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
    }

    @IsTest
    static void parse_UnbalancedParens_RejectsLeft() {
        try {
            KBFilterFormulaParser.parse('(1 AND 2', 2);
            Assert.fail('Expected unbalanced-parens error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            Assert.isTrue(e.getMessage().contains('\')\''),
                'Expected close-paren error: ' + e.getMessage());
        }
    }

    @IsTest
    static void parse_UnbalancedParens_RejectsRight() {
        try {
            KBFilterFormulaParser.parse('1 AND 2)', 2);
            Assert.fail('Expected trailing-token error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            Assert.isTrue(e.getMessage().contains('Unexpected'),
                'Expected unexpected-token error: ' + e.getMessage());
        }
    }

    @IsTest
    static void parse_BadKeyword_Rejects_Xor() {
        try {
            KBFilterFormulaParser.parse('1 XOR 2', 2);
            Assert.fail('Expected unknown-keyword error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            Assert.isTrue(e.getMessage().contains('Unknown keyword'),
                'Expected unknown-keyword: ' + e.getMessage());
        }
    }

    @IsTest
    static void parse_BadCharacter_Rejects_Ampersand() {
        try {
            KBFilterFormulaParser.parse('1 && 2', 2);
            Assert.fail('Expected bad-character error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            Assert.isTrue(e.getMessage().contains('Unexpected character'),
                'Expected unexpected-character: ' + e.getMessage());
        }
    }

    @IsTest
    static void parse_DropTable_Rejects() {
        try {
            KBFilterFormulaParser.parse('1 AND DROP TABLE Knowledge__kav', 2);
            Assert.fail('Expected reject of DROP keyword');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            Assert.isTrue(e.getMessage().contains('Unknown keyword'),
                'Expected unknown-keyword for DROP: ' + e.getMessage());
        }
    }

    @IsTest
    static void parse_DanglingOperator_Rejects() {
        try {
            KBFilterFormulaParser.parse('1 AND', 2);
            Assert.fail('Expected dangling-operator error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
        try {
            KBFilterFormulaParser.parse('AND 2', 2);
            Assert.fail('Expected leading-operator error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
        try {
            KBFilterFormulaParser.parse('1 OR OR 2', 2);
            Assert.fail('Expected double-operator error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
    }

    @IsTest
    static void parse_AdjacentClauses_Rejects() {
        try {
            KBFilterFormulaParser.parse('1 2', 2);
            Assert.fail('Expected adjacent-clauses error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
        try {
            KBFilterFormulaParser.parse('(1)(2)', 2);
            Assert.fail('Expected adjacent-paren-groups error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
    }

    @IsTest
    static void parse_LowercaseOperators_OK() {
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('1 and 2 or not 3', 3);
        Assert.isNotNull(p.root);
        // Operator precedence: AND binds tighter than OR, so: (1 AND 2) OR NOT 3
        Assert.areEqual('(((C1) AND (C2)) OR NOT (C3))',
            KBFilterFormulaParser.compile(p, stubFragments(3)));
    }

    @IsTest
    static void parse_MixedCase_OK() {
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('1 And 2', 2);
        Assert.areEqual('((C1) AND (C2))', KBFilterFormulaParser.compile(p, stubFragments(2)));
    }

    @IsTest
    static void parse_OverLengthLimit_Rejects() {
        // 501 chars
        String big = '';
        for (Integer i = 0; i < 250; i++) big += '1 ';
        big += '1';
        Assert.isTrue(big.length() > 500, 'Setup expected length > 500');
        try {
            KBFilterFormulaParser.parse(big, 1);
            Assert.fail('Expected length-cap error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            Assert.isTrue(e.getMessage().contains('character limit'),
                'Expected length error: ' + e.getMessage());
        }
    }

    @IsTest
    static void parse_BlankFormula_Rejects() {
        try {
            KBFilterFormulaParser.parse('   ', 1);
            Assert.fail('Expected empty-formula error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
        try {
            KBFilterFormulaParser.parse(null, 1);
            Assert.fail('Expected null-formula error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
    }

    @IsTest
    static void parse_ZeroClauseCount_Rejects() {
        try {
            KBFilterFormulaParser.parse('1', 0);
            Assert.fail('Expected zero-clause-count error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
    }

    @IsTest
    static void parse_AndOrPrecedence_OK() {
        // AND binds tighter than OR — Salesforce convention.
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('1 OR 2 AND 3', 3);
        Assert.areEqual('((C1) OR ((C2) AND (C3)))',
            KBFilterFormulaParser.compile(p, stubFragments(3)));
    }

    @IsTest
    static void compile_AndOfAll_NoFormula() {
        List<String> fragments = new List<String>{'A', 'B', 'C'};
        Assert.areEqual('((A) AND (B) AND (C))', KBFilterFormulaParser.compileAndOfAll(fragments));
    }

    @IsTest
    static void compile_AndOfAll_SingleClause() {
        Assert.areEqual('(A)', KBFilterFormulaParser.compileAndOfAll(new List<String>{'A'}));
    }

    @IsTest
    static void compile_AndOfAll_Empty_ReturnsEmpty() {
        Assert.areEqual('', KBFilterFormulaParser.compileAndOfAll(new List<String>()));
        Assert.areEqual('', KBFilterFormulaParser.compileAndOfAll(null));
    }

    @IsTest
    static void compile_AndOfAll_SkipsBlanks() {
        Assert.areEqual('(A)',
            KBFilterFormulaParser.compileAndOfAll(new List<String>{ 'A', null, '' }));
    }

    @IsTest
    static void compile_MissingFragment_Throws() {
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('1 AND 2', 2);
        Map<Integer, String> partial = new Map<Integer, String>{ 1 => 'C1' };
        try {
            KBFilterFormulaParser.compile(p, partial);
            Assert.fail('Expected missing-fragment error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            Assert.isTrue(e.getMessage().contains('No SOQL fragment'),
                'Expected missing-fragment message: ' + e.getMessage());
        }
    }

    @IsTest
    static void compile_NullArgs_Throws() {
        try {
            KBFilterFormulaParser.compile(null, new Map<Integer, String>());
            Assert.fail('Expected null-AST error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('1', 1);
        try {
            KBFilterFormulaParser.compile(p, null);
            Assert.fail('Expected null-map error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
    }

    @IsTest
    static void parse_OnlyParens_Rejects() {
        try {
            KBFilterFormulaParser.parse('()', 1);
            Assert.fail('Expected empty-paren-group error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
    }

    @IsTest
    static void parse_CombinedNot_Eval() {
        // (1 OR 2) AND NOT (3 OR 4)
        KBFilterFormulaParser.ParsedFormula p =
            KBFilterFormulaParser.parse('(1 OR 2) AND NOT (3 OR 4)', 4);
        Assert.areEqual('(((C1) OR (C2)) AND NOT ((C3) OR (C4)))',
            KBFilterFormulaParser.compile(p, stubFragments(4)));
    }

    @IsTest
    static void parse_TrailingOperator_Rejects() {
        try {
            KBFilterFormulaParser.parse('1 OR', 2);
            Assert.fail('Expected trailing-operator error');
        } catch (KBFilterFormulaParser.InvalidFormulaException e) {
            // ok
        }
    }

    @IsTest
    static void parse_ReferencedClauses_Tracked() {
        KBFilterFormulaParser.ParsedFormula p = KBFilterFormulaParser.parse('(1 OR 2) AND 1', 2);
        Assert.isNotNull(p.referencedClauses);
        Assert.isTrue(p.referencedClauses.contains(1));
        Assert.isTrue(p.referencedClauses.contains(2));
        Assert.areEqual(2, p.referencedClauses.size(),
            'Distinct refs should be deduplicated');
    }
}
