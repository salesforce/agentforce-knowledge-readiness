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
 * Recursive-descent parser for Salesforce-style boolean filter formulas.
 *
 * Grammar:
 *   formula  := orExpr
 *   orExpr   := andExpr ( OR andExpr )*
 *   andExpr  := notExpr ( AND notExpr )*
 *   notExpr  := NOT notExpr | atom
 *   atom     := INTEGER | '(' orExpr ')'
 *
 * Pure logic: no SOQL, no DML. The parser never carries field names or
 * values — only positional clause references. Compilation reads back the
 * AST and substitutes the per-clause SOQL fragments produced by
 * KBFilterClauseCompiler. This is the §3 invariant: the formula tokens
 * never reach Database.query, only the structural AND/OR/NOT/parens do.
 *
 * Hard limits (plan §2):
 *   - max formula length: 500 chars
 *   - max clause references: 20
 *   - max parenthesis nesting depth: 10
 */
public with sharing class KBFilterFormulaParser {

    public static final Integer MAX_FORMULA_LENGTH = 500;
    public static final Integer MAX_CLAUSE_REFS = 20;
    public static final Integer MAX_NESTING_DEPTH = 10;

    public class InvalidFormulaException extends Exception {}

    // NUM rather than NUMBER — NUMBER is a reserved identifier in Apex.
    public enum TokenType { LPAREN, RPAREN, AND_OP, OR_OP, NOT_OP, NUM, EOF }

    public class Token {
        public TokenType type;
        public String text;
        public Integer value;     // populated for NUMBER tokens
        public Integer position;  // 0-based char offset for error messages

        public Token(TokenType type, String text, Integer position) {
            this.type = type;
            this.text = text;
            this.position = position;
        }
    }

    /**
     * AST node — represents either a clause reference or an internal node
     * with a boolean operator. Kept as a single shape (no inheritance) to
     * keep serialization trivial. `clauseNumber` is populated for leaf
     * nodes; `operator` and `children` for internal ones.
     */
    public class AstNode {
        public Integer clauseNumber;      // 1-based, populated for leaves
        public String operator;            // 'AND' | 'OR' | 'NOT' for internal nodes
        public List<AstNode> children;     // populated for internal nodes

        public AstNode() {
            this.children = new List<AstNode>();
        }

        public Boolean isLeaf() {
            return clauseNumber != null;
        }
    }

    public class ParsedFormula {
        public List<Token> tokens;
        public AstNode root;
        public Set<Integer> referencedClauses;

        public ParsedFormula() {
            this.tokens = new List<Token>();
            this.referencedClauses = new Set<Integer>();
        }
    }

    /**
     * Parse a formula and validate it against the supplied clause count.
     * Throws InvalidFormulaException on any syntax error or out-of-range
     * clause reference.
     *
     * @param formula           raw user-supplied formula
     * @param maxClauseNumber   highest valid clause reference (1-based)
     */
    public static ParsedFormula parse(String formula, Integer maxClauseNumber) {
        if (formula == null) {
            throw new InvalidFormulaException('Formula is required');
        }
        String trimmed = formula.trim();
        if (String.isBlank(trimmed)) {
            throw new InvalidFormulaException('Formula is empty');
        }
        if (trimmed.length() > MAX_FORMULA_LENGTH) {
            throw new InvalidFormulaException('Formula exceeds ' + MAX_FORMULA_LENGTH + '-character limit');
        }
        if (maxClauseNumber == null || maxClauseNumber <= 0) {
            throw new InvalidFormulaException('At least one clause is required to use a formula');
        }

        ParsedFormula result = new ParsedFormula();
        result.tokens = tokenize(trimmed);
        if (result.tokens.size() - 1 > MAX_CLAUSE_REFS * 4) {
            // 4x is a generous slack to cover NOT / parens / operators around
            // each ref. The real cap is MAX_CLAUSE_REFS distinct numbers,
            // enforced below.
            throw new InvalidFormulaException('Formula has too many tokens');
        }

        // Single mutable cursor walked by the recursive-descent parser.
        ParserState state = new ParserState();
        state.tokens = result.tokens;
        state.cursor = 0;
        state.depth = 0;
        state.referenced = new Set<Integer>();
        state.maxClauseNumber = maxClauseNumber;

        AstNode root = parseOr(state);

        // The parser must have consumed every token aside from EOF.
        Token tail = state.tokens[state.cursor];
        if (tail.type != TokenType.EOF) {
            throw new InvalidFormulaException(
                'Unexpected token \'' + tail.text + '\' at position ' + tail.position
            );
        }

        if (state.referenced.size() > MAX_CLAUSE_REFS) {
            throw new InvalidFormulaException(
                'Formula references more than ' + MAX_CLAUSE_REFS + ' clauses'
            );
        }

        result.root = root;
        result.referencedClauses = state.referenced;
        return result;
    }

    /**
     * Compile the parsed AST into a SOQL fragment by substituting each
     * leaf's clause-number with the supplied per-clause SOQL fragment.
     * Returns the parenthesised top-level expression.
     *
     * @param parsed                parsed formula (from parse())
     * @param clauseSoqlByNumber    1-based map of clause-number -> SOQL fragment
     */
    public static String compile(ParsedFormula parsed, Map<Integer, String> clauseSoqlByNumber) {
        if (parsed == null || parsed.root == null) {
            throw new InvalidFormulaException('Cannot compile a null AST');
        }
        if (clauseSoqlByNumber == null) {
            throw new InvalidFormulaException('Clause-fragment map is required');
        }
        return emit(parsed.root, clauseSoqlByNumber);
    }

    @TestVisible
    private static String emit(AstNode node, Map<Integer, String> clauseSoqlByNumber) {
        if (node == null) return '';
        if (node.isLeaf()) {
            String fragment = clauseSoqlByNumber.get(node.clauseNumber);
            if (String.isBlank(fragment)) {
                throw new InvalidFormulaException(
                    'No SOQL fragment for clause ' + node.clauseNumber
                );
            }
            return '(' + fragment + ')';
        }
        if (node.operator == 'NOT') {
            return 'NOT ' + emit(node.children[0], clauseSoqlByNumber);
        }
        List<String> parts = new List<String>();
        for (AstNode child : node.children) {
            parts.add(emit(child, clauseSoqlByNumber));
        }
        String joiner = node.operator == 'AND' ? ' AND ' : ' OR ';
        return '(' + String.join(parts, joiner) + ')';
    }

    /**
     * Convenience: build the AND-of-all-clauses fallback used when the user
     * supplies no formula but does supply clauses.
     */
    public static String compileAndOfAll(List<String> clauseFragments) {
        if (clauseFragments == null || clauseFragments.isEmpty()) return '';
        List<String> wrapped = new List<String>();
        for (String f : clauseFragments) {
            if (String.isBlank(f)) continue;
            wrapped.add('(' + f + ')');
        }
        if (wrapped.isEmpty()) return '';
        if (wrapped.size() == 1) return wrapped[0];
        return '(' + String.join(wrapped, ' AND ') + ')';
    }

    // --------------------------------------------------------------------
    // Tokenizer
    // --------------------------------------------------------------------

    @TestVisible
    private static List<Token> tokenize(String input) {
        List<Token> tokens = new List<Token>();
        Integer i = 0;
        Integer n = input.length();
        while (i < n) {
            String ch = input.substring(i, i + 1);
            // skip whitespace
            if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
                i++;
                continue;
            }
            if (ch == '(') {
                tokens.add(new Token(TokenType.LPAREN, '(', i));
                i++;
                continue;
            }
            if (ch == ')') {
                tokens.add(new Token(TokenType.RPAREN, ')', i));
                i++;
                continue;
            }
            // Number — one or more digits.
            if (isDigit(ch)) {
                Integer start = i;
                while (i < n && isDigit(input.substring(i, i + 1))) {
                    i++;
                }
                String text = input.substring(start, i);
                Token t = new Token(TokenType.NUM, text, start);
                t.value = Integer.valueOf(text);
                tokens.add(t);
                continue;
            }
            // Word — a run of letters. Only AND/OR/NOT (case-insensitive) are valid.
            if (isLetter(ch)) {
                Integer start = i;
                while (i < n && isLetter(input.substring(i, i + 1))) {
                    i++;
                }
                String word = input.substring(start, i).toUpperCase();
                if (word == 'AND') {
                    tokens.add(new Token(TokenType.AND_OP, word, start));
                } else if (word == 'OR') {
                    tokens.add(new Token(TokenType.OR_OP, word, start));
                } else if (word == 'NOT') {
                    tokens.add(new Token(TokenType.NOT_OP, word, start));
                } else {
                    throw new InvalidFormulaException(
                        'Unknown keyword \'' + word + '\' at position ' + start
                    );
                }
                continue;
            }
            // Anything else is a hard reject — covers '&&', '||', '!', '=', etc.
            throw new InvalidFormulaException(
                'Unexpected character \'' + ch + '\' at position ' + i
            );
        }
        tokens.add(new Token(TokenType.EOF, '', n));
        return tokens;
    }

    private static Boolean isDigit(String ch) {
        return ch >= '0' && ch <= '9';
    }

    private static Boolean isLetter(String ch) {
        return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');
    }

    // --------------------------------------------------------------------
    // Parser
    // --------------------------------------------------------------------

    private class ParserState {
        List<Token> tokens;
        Integer cursor;
        Integer depth;
        Set<Integer> referenced;
        Integer maxClauseNumber;
    }

    private static AstNode parseOr(ParserState state) {
        AstNode left = parseAnd(state);
        while (state.tokens[state.cursor].type == TokenType.OR_OP) {
            state.cursor++;
            AstNode right = parseAnd(state);
            // Flatten chains (a OR b OR c) into a single node so emit can
            // produce '(a OR b OR c)' rather than '((a OR b) OR c)'. Same
            // for AND below.
            if (left.operator == 'OR' && !left.isLeaf()) {
                left.children.add(right);
            } else {
                AstNode merged = new AstNode();
                merged.operator = 'OR';
                merged.children.add(left);
                merged.children.add(right);
                left = merged;
            }
        }
        return left;
    }

    private static AstNode parseAnd(ParserState state) {
        AstNode left = parseNot(state);
        while (state.tokens[state.cursor].type == TokenType.AND_OP) {
            state.cursor++;
            AstNode right = parseNot(state);
            if (left.operator == 'AND' && !left.isLeaf()) {
                left.children.add(right);
            } else {
                AstNode merged = new AstNode();
                merged.operator = 'AND';
                merged.children.add(left);
                merged.children.add(right);
                left = merged;
            }
        }
        return left;
    }

    private static AstNode parseNot(ParserState state) {
        if (state.tokens[state.cursor].type == TokenType.NOT_OP) {
            state.cursor++;
            AstNode child = parseNot(state); // double-NOT is fine
            AstNode node = new AstNode();
            node.operator = 'NOT';
            node.children.add(child);
            return node;
        }
        return parseAtom(state);
    }

    private static AstNode parseAtom(ParserState state) {
        Token tok = state.tokens[state.cursor];
        if (tok.type == TokenType.LPAREN) {
            state.depth++;
            if (state.depth > MAX_NESTING_DEPTH) {
                throw new InvalidFormulaException(
                    'Formula exceeds maximum nesting depth of ' + MAX_NESTING_DEPTH
                );
            }
            state.cursor++;
            AstNode innerNode = parseOr(state);
            Token close = state.tokens[state.cursor];
            if (close.type != TokenType.RPAREN) {
                throw new InvalidFormulaException(
                    'Expected \')\' at position ' + close.position
                );
            }
            state.cursor++;
            state.depth--;
            return innerNode;
        }
        if (tok.type == TokenType.NUM) {
            if (tok.value <= 0 || tok.value > state.maxClauseNumber) {
                throw new InvalidFormulaException(
                    'Clause reference ' + tok.value + ' is out of range '
                    + '(1..' + state.maxClauseNumber + ')'
                );
            }
            state.referenced.add(tok.value);
            state.cursor++;
            AstNode leaf = new AstNode();
            leaf.clauseNumber = tok.value;
            return leaf;
        }
        // EOF / RPAREN / operator-where-an-atom-belongs all land here.
        throw new InvalidFormulaException(
            'Expected clause number or \'(\', got \'' + tok.text + '\' at position ' + tok.position
        );
    }
}
