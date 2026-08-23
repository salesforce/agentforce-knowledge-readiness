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
public with sharing class KBAssessmentUtils {

    private static final Set<String> AMBIGUOUS_WORDS = new Set<String>{
        'soon', 'later', 'sometimes', 'often', 'usually', 'might', 'could',
        'possibly', 'perhaps', 'maybe', 'etc', 'and so on', 'various', 'several',
        'many', 'few', 'some', 'approximately', 'around', 'about'
    };

    private static final Set<String> ACTION_INDICATORS = new Set<String>{
        'click', 'select', 'enter', 'type', 'choose', 'navigate', 'open',
        'save', 'submit', 'confirm', 'press', 'tap', 'drag', 'drop', 'scroll',
        'step', 'follow', 'complete', 'verify', 'ensure', 'check'
    };

    public static String stripHtml(String htmlContent) {
        if (String.isBlank(htmlContent)) {
            return '';
        }
        return htmlContent
            .replaceAll('<[^>]+>', ' ')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', '\'')
            .replaceAll('\\s+', ' ')
            .trim();
    }

    public static Integer countWords(String text) {
        if (String.isBlank(text)) {
            return 0;
        }
        String cleanText = stripHtml(text);
        List<String> words = cleanText.split('\\s+');
        Integer count = 0;
        for (String word : words) {
            if (String.isNotBlank(word) && word.length() > 0) {
                count++;
            }
        }
        return count;
    }

    public static List<String> getSentences(String text) {
        List<String> sentences = new List<String>();
        if (String.isBlank(text)) {
            return sentences;
        }

        String cleanText = stripHtml(text);
        List<String> rawSentences = cleanText.split('[.!?]+');

        for (String sentence : rawSentences) {
            String trimmed = sentence.trim();
            if (String.isNotBlank(trimmed) && trimmed.length() > 2) {
                sentences.add(trimmed);
            }
        }
        return sentences;
    }

    public static Decimal calculateAverageSentenceLength(String text) {
        List<String> sentences = getSentences(text);
        if (sentences.isEmpty()) {
            return 0;
        }

        Integer totalWords = 0;
        for (String sentence : sentences) {
            totalWords += countWords(sentence);
        }

        return Decimal.valueOf(totalWords) / sentences.size();
    }

    public static Integer countHeadings(String htmlContent) {
        if (String.isBlank(htmlContent)) {
            return 0;
        }

        Integer count = 0;
        Pattern headingPattern = Pattern.compile('<h[1-6][^>]*>');
        Matcher m = headingPattern.matcher(htmlContent.toLowerCase());
        while (m.find()) {
            count++;
        }
        return count;
    }

    public static Integer countLists(String htmlContent) {
        if (String.isBlank(htmlContent)) {
            return 0;
        }

        Integer count = 0;
        String lowerContent = htmlContent.toLowerCase();

        Pattern ulPattern = Pattern.compile('<ul[^>]*>');
        Pattern olPattern = Pattern.compile('<ol[^>]*>');

        Matcher ulMatcher = ulPattern.matcher(lowerContent);
        while (ulMatcher.find()) {
            count++;
        }

        Matcher olMatcher = olPattern.matcher(lowerContent);
        while (olMatcher.find()) {
            count++;
        }

        return count;
    }

    public static List<String> extractHeadings(String htmlContent) {
        List<String> headings = new List<String>();
        if (String.isBlank(htmlContent)) {
            return headings;
        }

        // Match h1-h6 tags and extract their content
        Pattern headingPattern = Pattern.compile('<h[1-6][^>]*>([^<]*)</h[1-6]>');
        Matcher m = headingPattern.matcher(htmlContent.toLowerCase());

        while (m.find()) {
            String headingText = m.group(1).trim();
            if (String.isNotBlank(headingText)) {
                headings.add(headingText);
            }
        }

        return headings;
    }

    public static Boolean hasQAFormat(String htmlContent) {
        if (String.isBlank(htmlContent)) {
            return false;
        }

        String lowerContent = htmlContent.toLowerCase();

        Boolean hasQuestion = lowerContent.contains('question') ||
                             lowerContent.contains('q:') ||
                             lowerContent.contains('q.') ||
                             Pattern.compile('\\bwhat\\b|\\bhow\\b|\\bwhy\\b|\\bwhen\\b|\\bwhere\\b|\\bcan\\s+i\\b').matcher(lowerContent).find();

        Boolean hasAnswer = lowerContent.contains('answer') ||
                           lowerContent.contains('a:') ||
                           lowerContent.contains('a.') ||
                           lowerContent.contains('solution') ||
                           lowerContent.contains('resolution');

        return hasQuestion && hasAnswer;
    }

    public static Integer countAmbiguousWords(String text) {
        if (String.isBlank(text)) {
            return 0;
        }

        String lowerText = stripHtml(text).toLowerCase();
        Integer count = 0;

        for (String ambiguous : AMBIGUOUS_WORDS) {
            Pattern p = Pattern.compile('\\b' + Pattern.quote(ambiguous) + '\\b');
            Matcher m = p.matcher(lowerText);
            while (m.find()) {
                count++;
            }
        }
        return count;
    }

    public static Decimal calculateReadabilityScore(String text) {
        if (String.isBlank(text)) {
            return 0;
        }

        String cleanText = stripHtml(text);
        Integer wordCount = countWords(cleanText);
        List<String> sentences = getSentences(cleanText);

        if (wordCount == 0 || sentences.isEmpty()) {
            return 0;
        }

        Integer syllableCount = countSyllables(cleanText);

        Decimal avgSentenceLength = Decimal.valueOf(wordCount) / sentences.size();
        Decimal avgSyllablesPerWord = Decimal.valueOf(syllableCount) / wordCount;

        Decimal fleschScore = 206.835 - (1.015 * avgSentenceLength) - (84.6 * avgSyllablesPerWord);

        return Math.max(0, Math.min(100, fleschScore));
    }

    public static Integer countSyllables(String text) {
        if (String.isBlank(text)) {
            return 0;
        }

        String cleanText = stripHtml(text).toLowerCase();
        List<String> words = cleanText.split('\\s+');
        Integer totalSyllables = 0;

        for (String word : words) {
            totalSyllables += countWordSyllables(word);
        }

        return totalSyllables;
    }

    private static Integer countWordSyllables(String word) {
        if (String.isBlank(word)) {
            return 0;
        }

        word = word.replaceAll('[^a-zA-Z]', '').toLowerCase();
        if (word.length() <= 2) {
            return 1;
        }

        Integer count = 0;
        Boolean prevVowel = false;
        String vowels = 'aeiouy';

        for (Integer i = 0; i < word.length(); i++) {
            String ch = word.substring(i, i + 1);
            Boolean isVowel = vowels.contains(ch);

            if (isVowel && !prevVowel) {
                count++;
            }
            prevVowel = isVowel;
        }

        if (word.endsWith('e') && count > 1) {
            count--;
        }

        return Math.max(1, count);
    }

    public static Boolean hasActionableContent(String text) {
        if (String.isBlank(text)) {
            return false;
        }

        String lowerText = stripHtml(text).toLowerCase();

        for (String action : ACTION_INDICATORS) {
            if (lowerText.contains(action)) {
                return true;
            }
        }
        return false;
    }

    public static Integer countActionSteps(String htmlContent) {
        if (String.isBlank(htmlContent)) {
            return 0;
        }

        Integer count = 0;
        String lowerContent = htmlContent.toLowerCase();

        Pattern liPattern = Pattern.compile('<li[^>]*>');
        Matcher m = liPattern.matcher(lowerContent);
        while (m.find()) {
            count++;
        }

        Pattern stepPattern = Pattern.compile('step\\s*\\d+|\\d+\\.');
        Matcher stepMatcher = stepPattern.matcher(lowerContent);
        while (stepMatcher.find()) {
            count++;
        }

        return count;
    }

    public static Decimal calculateTitleQualityScore(String title) {
        if (String.isBlank(title)) {
            return 0;
        }

        Decimal score = 100;
        List<String> issues = new List<String>();

        Integer wordCount = countWords(title);
        if (wordCount < 3) {
            score -= 30;
        } else if (wordCount > 15) {
            score -= 20;
        }

        if (title.length() < 10) {
            score -= 20;
        } else if (title.length() > 100) {
            score -= 15;
        }

        if (title == title.toUpperCase() && title.length() > 5) {
            score -= 15;
        }

        String lowerTitle = title.toLowerCase();
        List<String> vagueStarts = new List<String>{'info', 'about', 'the', 'a ', 'an '};
        for (String vague : vagueStarts) {
            if (lowerTitle.startsWith(vague)) {
                score -= 10;
                break;
            }
        }

        Pattern questionPattern = Pattern.compile('\\bwhat\\b|\\bhow\\b|\\bwhy\\b|\\bwhen\\b|\\bcan\\b');
        if (questionPattern.matcher(lowerTitle).find()) {
            score += 10;
        }

        return Math.max(0, Math.min(100, score));
    }

    public static Decimal calculateSimilarity(String text1, String text2) {
        if (String.isBlank(text1) || String.isBlank(text2)) {
            return 0;
        }

        Set<String> words1 = new Set<String>(stripHtml(text1).toLowerCase().split('\\s+'));
        Set<String> words2 = new Set<String>(stripHtml(text2).toLowerCase().split('\\s+'));

        Set<String> intersection = new Set<String>(words1);
        intersection.retainAll(words2);

        Set<String> union = new Set<String>(words1);
        union.addAll(words2);

        if (union.isEmpty()) {
            return 0;
        }

        return (Decimal.valueOf(intersection.size()) / union.size() * 100).setScale(2);
    }

    public static List<String> extractKeyPhrases(String text, Integer maxPhrases) {
        List<String> phrases = new List<String>();
        if (String.isBlank(text)) {
            return phrases;
        }

        String cleanText = stripHtml(text).toLowerCase();
        List<String> words = cleanText.split('\\s+');

        Map<String, Integer> wordFreq = new Map<String, Integer>();
        Set<String> stopWords = new Set<String>{
            'the', 'a', 'an', 'and', 'or', 'but', 'is', 'are', 'was', 'were',
            'be', 'been', 'being', 'have', 'has', 'had', 'do', 'does', 'did',
            'will', 'would', 'could', 'should', 'may', 'might', 'must', 'can',
            'to', 'of', 'in', 'for', 'on', 'with', 'at', 'by', 'from', 'as',
            'into', 'through', 'during', 'before', 'after', 'above', 'below',
            'it', 'this', 'that', 'these', 'those', 'i', 'you', 'he', 'she',
            'we', 'they', 'what', 'which', 'who', 'when', 'where', 'why', 'how'
        };

        for (String word : words) {
            String cleanWord = word.replaceAll('[^a-zA-Z0-9]', '');
            if (cleanWord.length() > 3 && !stopWords.contains(cleanWord)) {
                Integer count = wordFreq.containsKey(cleanWord) ? wordFreq.get(cleanWord) : 0;
                wordFreq.put(cleanWord, count + 1);
            }
        }

        List<WordFrequency> sortedWords = new List<WordFrequency>();
        for (String word : wordFreq.keySet()) {
            sortedWords.add(new WordFrequency(word, wordFreq.get(word)));
        }
        sortedWords.sort();

        for (Integer i = 0; i < Math.min(maxPhrases, sortedWords.size()); i++) {
            phrases.add(sortedWords[i].word);
        }

        return phrases;
    }

    private class WordFrequency implements Comparable {
        public String word;
        public Integer frequency;

        public WordFrequency(String word, Integer frequency) {
            this.word = word;
            this.frequency = frequency;
        }

        public Integer compareTo(Object other) {
            WordFrequency otherWf = (WordFrequency)other;
            return otherWf.frequency - this.frequency;
        }
    }
}