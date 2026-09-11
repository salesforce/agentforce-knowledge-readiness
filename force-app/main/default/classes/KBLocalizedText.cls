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
 * Resolves prompt/LLM-input strings localized by article language from the
 * KB_Localized_Prompt_Text__mdt catalog.
 *
 * Lookup order for get(key, languageCode):
 *   1. exact (key, base-language) — e.g. ('FIX_LANGUAGE_DIRECTIVE', 'pl')
 *   2. (key, raw languageCode) — in case a full locale row was seeded
 *   3. (key, 'en') — English fallback when the article's language is unseeded
 *   4. null — the key does not exist at all; the caller supplies its own default
 *
 * The {LANG} token in a Value__c is replaced with the resolved base language
 * code, so the English fallback record can name the target language.
 *
 * Custom Labels resolve to the *running user's* language, which is wrong here:
 * AI-Fix must localize to the *article's* language. A language-keyed CMDT is
 * the correct primitive — hence this class rather than Label plumbing.
 */
public with sharing class KBLocalizedText {
    @TestVisible
    private static final String DEFAULT_LANG = 'en';

    // key: "TEXTKEY|lang" (upper|lower) -> Value__c
    @TestVisible
    private static Map<String, String> cache;

    @TestVisible
    private static Map<String, String> load() {
        if (cache != null) {
            return cache;
        }
        cache = new Map<String, String>();
        // SOQL, not getAll(): getAll()/getInstance() truncate Long Text Area
        // fields to 255 chars, which would silently clip the localized directive
        // (the shipped Value__c rows are 400+ chars, so the tail — e.g. the
        // "keep English acronyms as-is" clause — would be lost). SOQL returns
        // the full Value__c.
        for (KB_Localized_Prompt_Text__mdt row : [
            SELECT Text_Key__c, Language_Code__c, Value__c
            FROM KB_Localized_Prompt_Text__mdt
        ]) {
            if (String.isBlank(row.Text_Key__c) || String.isBlank(row.Language_Code__c)) {
                continue;
            }
            cache.put(mapKey(row.Text_Key__c, row.Language_Code__c), row.Value__c);
        }
        return cache;
    }

    private static String mapKey(String key, String lang) {
        return key.trim().toUpperCase() + '|' + lang.trim().toLowerCase();
    }

    /** Base language of a locale — 'en_US' / 'pt-BR' -> 'en' / 'pt'. */
    private static String baseLanguage(String languageCode) {
        String lang = String.isBlank(languageCode) ? DEFAULT_LANG : languageCode.trim();
        return lang.replace('-', '_').split('_')[0];
    }

    /**
     * @return the localized value for (key, languageCode), falling back to the
     *         English record for the key, or null if the key is absent entirely.
     */
    public static String get(String key, String languageCode) {
        if (String.isBlank(key)) {
            return null;
        }
        Map<String, String> m = load();
        String base = baseLanguage(languageCode);

        String val = m.get(mapKey(key, base));
        if (val == null && String.isNotBlank(languageCode)) {
            val = m.get(mapKey(key, languageCode)); // full locale row, if any
        }
        if (val == null) {
            val = m.get(mapKey(key, DEFAULT_LANG)); // English fallback
        }
        if (val == null) {
            return null; // key does not exist at all
        }
        return val.replace('{LANG}', base);
    }
}
