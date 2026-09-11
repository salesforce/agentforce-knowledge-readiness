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
private class KBLocalizedTextTest {
    // Seed the @TestVisible cache directly so the tests don't depend on which
    // KB_Localized_Prompt_Text__mdt records happen to be deployed.
    private static void seed() {
        KBLocalizedText.cache = new Map<String, String>{
            'FIX_LANGUAGE_DIRECTIVE|en' => 'Write everything in {LANG}. Do not translate to English.',
            'FIX_LANGUAGE_DIRECTIVE|pl' => 'Napisz wszystko po polsku.',
            'FIX_LANGUAGE_DIRECTIVE|de' => 'Schreibe alles auf Deutsch.'
        };
    }

    @IsTest
    static void returnsExactLanguageMatch() {
        seed();
        Test.startTest();
        String v = KBLocalizedText.get('FIX_LANGUAGE_DIRECTIVE', 'pl');
        Test.stopTest();
        System.assertEquals('Napisz wszystko po polsku.', v, 'Should return the Polish record verbatim');
    }

    @IsTest
    static void matchesCaseAndLocaleInsensitively() {
        seed();
        System.assertEquals(
            'Schreibe alles auf Deutsch.',
            KBLocalizedText.get('fix_language_directive', 'de_DE'),
            'Key should match case-insensitively and locale should collapse to base language'
        );
    }

    @IsTest
    static void unseededLanguageFallsBackToEnglishWithLangToken() {
        seed();
        // Spanish is not seeded -> English record, with {LANG} filled with 'es'
        String v = KBLocalizedText.get('FIX_LANGUAGE_DIRECTIVE', 'es');
        System.assertEquals('Write everything in es. Do not translate to English.', v,
            'Unseeded language should use the English record with {LANG} -> es');
    }

    @IsTest
    static void blankLanguageDefaultsToEnglish() {
        seed();
        String v = KBLocalizedText.get('FIX_LANGUAGE_DIRECTIVE', null);
        System.assertEquals('Write everything in en. Do not translate to English.', v,
            'Blank language should resolve to the English record');
    }

    @IsTest
    static void absentKeyReturnsNull() {
        seed();
        System.assertEquals(null, KBLocalizedText.get('NO_SUCH_KEY', 'pl'),
            'A key with no records at all should return null');
        System.assertEquals(null, KBLocalizedText.get(null, 'pl'),
            'A blank key should return null');
    }

    @IsTest
    static void loadReadsDeployedCatalogUntruncated() {
        // Exercise the real load() path against deployed metadata. Regression
        // guard for the getAll()/getInstance() Long Text Area 255-char
        // truncation: load() must use SOQL, so its cached value must be
        // byte-identical to a direct SOQL read of the same row — NOT a 255-char
        // prefix. A non-null-only assertion would pass even under truncation
        // (255 chars is still non-null), which is exactly the trap the shipped
        // 400+ char directives fell into.
        List<KB_Localized_Prompt_Text__mdt> rows = [
            SELECT Value__c
            FROM KB_Localized_Prompt_Text__mdt
            WHERE Text_Key__c = 'FIX_LANGUAGE_DIRECTIVE' AND Language_Code__c = 'en'
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return; // catalog not deployed in this org — nothing to assert against
        }
        String fullSoqlValue = rows[0].Value__c;

        KBLocalizedText.cache = null;
        Test.startTest();
        String v = KBLocalizedText.get('FIX_LANGUAGE_DIRECTIVE', 'en');
        Test.stopTest();

        System.assertNotEquals(null, v, 'FIX_LANGUAGE_DIRECTIVE|en should be deployed');
        // The en record's {LANG} token resolves to 'en'; apply the same
        // substitution to the raw SOQL value so we compare like with like.
        String expected = fullSoqlValue.replace('{LANG}', 'en');
        System.assertEquals(expected, v,
            'load() must return the full Value__c via SOQL, not a getAll()-truncated 255-char prefix');
    }
}
