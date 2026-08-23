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
private class KBAssessmentUtilsTest {

    @IsTest
    static void testStripHtml_BasicHtml() {
        String html = '<p>This is a <strong>test</strong> paragraph.</p>';

        Test.startTest();
        String result = KBAssessmentUtils.stripHtml(html);
        Test.stopTest();

        Assert.areEqual('This is a test paragraph.', result, 'HTML tags should be stripped');
    }

    @IsTest
    static void testStripHtml_HtmlEntities() {
        String html = 'Test&nbsp;&amp;&lt;&gt;&quot;&#39;content';

        Test.startTest();
        String result = KBAssessmentUtils.stripHtml(html);
        Test.stopTest();

        Assert.areEqual('Test &<>"\'content', result, 'HTML entities should be decoded');
    }

    @IsTest
    static void testStripHtml_MultipleSpaces() {
        String html = '<p>Multiple    spaces   should    collapse</p>';

        Test.startTest();
        String result = KBAssessmentUtils.stripHtml(html);
        Test.stopTest();

        Assert.areEqual('Multiple spaces should collapse', result, 'Multiple spaces should collapse to single');
    }

    @IsTest
    static void testStripHtml_EmptyAndNull() {
        Test.startTest();
        String resultNull = KBAssessmentUtils.stripHtml(null);
        String resultEmpty = KBAssessmentUtils.stripHtml('');
        String resultBlank = KBAssessmentUtils.stripHtml('   ');
        Test.stopTest();

        Assert.areEqual('', resultNull, 'Null should return empty string');
        Assert.areEqual('', resultEmpty, 'Empty should return empty string');
        Assert.areEqual('', resultBlank, 'Blank should return empty string');
    }

    @IsTest
    static void testCountWords_BasicText() {
        String text = 'This is a simple test sentence';

        Test.startTest();
        Integer count = KBAssessmentUtils.countWords(text);
        Test.stopTest();

        Assert.areEqual(6, count, 'Should count 6 words');
    }

    @IsTest
    static void testCountWords_WithHtml() {
        String html = '<p>This <strong>is</strong> a <em>test</em></p>';

        Test.startTest();
        Integer count = KBAssessmentUtils.countWords(html);
        Test.stopTest();

        Assert.areEqual(4, count, 'Should count 4 words after stripping HTML');
    }

    @IsTest
    static void testCountWords_EmptyAndNull() {
        Test.startTest();
        Integer countNull = KBAssessmentUtils.countWords(null);
        Integer countEmpty = KBAssessmentUtils.countWords('');
        Integer countBlank = KBAssessmentUtils.countWords('   ');
        Test.stopTest();

        Assert.areEqual(0, countNull, 'Null should return 0');
        Assert.areEqual(0, countEmpty, 'Empty should return 0');
        Assert.areEqual(0, countBlank, 'Blank should return 0');
    }

    @IsTest
    static void testGetSentences_MultipleSentences() {
        String text = 'First sentence. Second sentence! Third sentence? Fourth sentence.';

        Test.startTest();
        List<String> sentences = KBAssessmentUtils.getSentences(text);
        Test.stopTest();

        Assert.areEqual(4, sentences.size(), 'Should return 4 sentences');
        Assert.areEqual('First sentence', sentences[0], 'First sentence should be correct');
        Assert.areEqual('Second sentence', sentences[1], 'Second sentence should be correct');
    }

    @IsTest
    static void testGetSentences_WithHtml() {
        String html = '<p>Sentence one.</p><p>Sentence two!</p>';

        Test.startTest();
        List<String> sentences = KBAssessmentUtils.getSentences(html);
        Test.stopTest();

        Assert.areEqual(2, sentences.size(), 'Should return 2 sentences after stripping HTML');
    }

    @IsTest
    static void testGetSentences_EmptyAndShort() {
        Test.startTest();
        List<String> sentencesNull = KBAssessmentUtils.getSentences(null);
        List<String> sentencesEmpty = KBAssessmentUtils.getSentences('');
        List<String> sentencesShort = KBAssessmentUtils.getSentences('Hi.');
        Test.stopTest();

        Assert.areEqual(0, sentencesNull.size(), 'Null should return empty list');
        Assert.areEqual(0, sentencesEmpty.size(), 'Empty should return empty list');
        Assert.areEqual(0, sentencesShort.size(), 'Very short sentences should be filtered');
    }

    @IsTest
    static void testCalculateAverageSentenceLength() {
        String text = 'Short sentence. This is a longer sentence with more words.';

        Test.startTest();
        Decimal avgLength = KBAssessmentUtils.calculateAverageSentenceLength(text);
        Test.stopTest();

        // First sentence: 2 words, Second sentence: 8 words. Average = 5.
        Assert.areEqual(5, avgLength, 'Average sentence length should be calculated correctly');
    }

    @IsTest
    static void testCalculateAverageSentenceLength_EmptyText() {
        Test.startTest();
        Decimal avgLength = KBAssessmentUtils.calculateAverageSentenceLength('');
        Test.stopTest();

        Assert.areEqual(0, avgLength, 'Empty text should return 0');
    }

    @IsTest
    static void testCountHeadings_MultipleHeadings() {
        String html = '<h1>Title</h1><h2>Subtitle</h2><p>Content</p><h3>Section</h3>';

        Test.startTest();
        Integer count = KBAssessmentUtils.countHeadings(html);
        Test.stopTest();

        Assert.areEqual(3, count, 'Should count 3 headings');
    }

    @IsTest
    static void testCountHeadings_NoHeadings() {
        String html = '<p>Just a paragraph</p><div>No headings here</div>';

        Test.startTest();
        Integer count = KBAssessmentUtils.countHeadings(html);
        Test.stopTest();

        Assert.areEqual(0, count, 'Should return 0 for no headings');
    }

    @IsTest
    static void testCountHeadings_EmptyAndNull() {
        Test.startTest();
        Integer countNull = KBAssessmentUtils.countHeadings(null);
        Integer countEmpty = KBAssessmentUtils.countHeadings('');
        Test.stopTest();

        Assert.areEqual(0, countNull, 'Null should return 0');
        Assert.areEqual(0, countEmpty, 'Empty should return 0');
    }

    @IsTest
    static void testCountLists() {
        String html = '<ul><li>Item 1</li><li>Item 2</li></ul><ol><li>Step 1</li></ol>';

        Test.startTest();
        Integer count = KBAssessmentUtils.countLists(html);
        Test.stopTest();

        Assert.areEqual(2, count, 'Should count 2 lists (1 ul, 1 ol)');
    }

    @IsTest
    static void testCountLists_NoLists() {
        String html = '<p>No lists here</p>';

        Test.startTest();
        Integer count = KBAssessmentUtils.countLists(html);
        Test.stopTest();

        Assert.areEqual(0, count, 'Should return 0 for no lists');
    }

    @IsTest
    static void testExtractHeadings() {
        String html = '<h1>Main Title</h1><h2>Subtitle</h2><h3>Section</h3>';

        Test.startTest();
        List<String> headings = KBAssessmentUtils.extractHeadings(html);
        Test.stopTest();

        Assert.areEqual(3, headings.size(), 'Should extract 3 headings');
        Assert.areEqual('main title', headings[0], 'First heading should be extracted');
        Assert.areEqual('subtitle', headings[1], 'Second heading should be extracted');
    }

    @IsTest
    static void testExtractHeadings_EmptyAndNull() {
        Test.startTest();
        List<String> headingsNull = KBAssessmentUtils.extractHeadings(null);
        List<String> headingsEmpty = KBAssessmentUtils.extractHeadings('');
        Test.stopTest();

        Assert.areEqual(0, headingsNull.size(), 'Null should return empty list');
        Assert.areEqual(0, headingsEmpty.size(), 'Empty should return empty list');
    }

    @IsTest
    static void testHasQAFormat_QuestionAndAnswer() {
        String html = '<p>Question: How do I reset my password?</p><p>Answer: Click on forgot password.</p>';

        Test.startTest();
        Boolean hasQA = KBAssessmentUtils.hasQAFormat(html);
        Test.stopTest();

        Assert.isTrue(hasQA, 'Should detect Q&A format');
    }

    @IsTest
    static void testHasQAFormat_QuestionWords() {
        String html = '<p>What is the best way to configure this?</p><p>Solution: Follow these steps.</p>';

        Test.startTest();
        Boolean hasQA = KBAssessmentUtils.hasQAFormat(html);
        Test.stopTest();

        Assert.isTrue(hasQA, 'Should detect Q&A format with question words');
    }

    @IsTest
    static void testHasQAFormat_NoQA() {
        String html = '<p>This is just a regular article with instructions.</p>';

        Test.startTest();
        Boolean hasQA = KBAssessmentUtils.hasQAFormat(html);
        Test.stopTest();

        Assert.isFalse(hasQA, 'Should not detect Q&A format');
    }

    @IsTest
    static void testCountAmbiguousWords() {
        String text = 'This might work soon, but maybe later. Sometimes it could possibly help.';

        Test.startTest();
        Integer count = KBAssessmentUtils.countAmbiguousWords(text);
        Test.stopTest();

        Assert.isTrue(count > 0, 'Should detect ambiguous words');
    }

    @IsTest
    static void testCountAmbiguousWords_NonePresent() {
        String text = 'Click the button now to complete the action immediately.';

        Test.startTest();
        Integer count = KBAssessmentUtils.countAmbiguousWords(text);
        Test.stopTest();

        Assert.areEqual(0, count, 'Should return 0 for text without ambiguous words');
    }

    @IsTest
    static void testCalculateReadabilityScore_SimpleText() {
        String text = 'This is easy to read. Short sentences work well. They are clear.';

        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateReadabilityScore(text);
        Test.stopTest();

        Assert.isTrue(score >= 0 && score <= 100, 'Score should be between 0 and 100');
        Assert.isTrue(score > 50, 'Simple text should have high readability');
    }

    @IsTest
    static void testCalculateReadabilityScore_ComplexText() {
        String text = 'The implementation of sophisticated algorithmic methodologies necessitates comprehensive understanding.';

        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateReadabilityScore(text);
        Test.stopTest();

        Assert.isTrue(score >= 0 && score <= 100, 'Score should be between 0 and 100');
    }

    @IsTest
    static void testCalculateReadabilityScore_EmptyText() {
        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateReadabilityScore('');
        Test.stopTest();

        Assert.areEqual(0, score, 'Empty text should return 0');
    }

    @IsTest
    static void testCountSyllables_SimpleWords() {
        Test.startTest();
        Integer syllables = KBAssessmentUtils.countSyllables('cat dog run jump');
        Test.stopTest();

        Assert.areEqual(4, syllables, 'Simple one-syllable words should be counted correctly');
    }

    @IsTest
    static void testCountSyllables_ComplexWords() {
        Test.startTest();
        Integer syllables = KBAssessmentUtils.countSyllables('beautiful elephant dictionary');
        Test.stopTest();

        Assert.isTrue(syllables > 5, 'Complex words should have more syllables');
    }

    @IsTest
    static void testCountSyllables_EmptyText() {
        Test.startTest();
        Integer syllables = KBAssessmentUtils.countSyllables('');
        Test.stopTest();

        Assert.areEqual(0, syllables, 'Empty text should return 0');
    }

    @IsTest
    static void testHasActionableContent_WithActions() {
        String text = 'Click the button and select the option from the dropdown menu.';

        Test.startTest();
        Boolean hasAction = KBAssessmentUtils.hasActionableContent(text);
        Test.stopTest();

        Assert.isTrue(hasAction, 'Should detect actionable content');
    }

    @IsTest
    static void testHasActionableContent_NoActions() {
        String text = 'This is just descriptive information about the product.';

        Test.startTest();
        Boolean hasAction = KBAssessmentUtils.hasActionableContent(text);
        Test.stopTest();

        Assert.isFalse(hasAction, 'Should not detect actionable content');
    }

    @IsTest
    static void testCountActionSteps_WithLists() {
        String html = '<ol><li>First step</li><li>Second step</li><li>Third step</li></ol>';

        Test.startTest();
        Integer count = KBAssessmentUtils.countActionSteps(html);
        Test.stopTest();

        Assert.areEqual(3, count, 'Should count 3 list items');
    }

    @IsTest
    static void testCountActionSteps_WithNumberedSteps() {
        String html = '<p>Step 1: Do this</p><p>Step 2: Do that</p><p>1. First thing</p>';

        Test.startTest();
        Integer count = KBAssessmentUtils.countActionSteps(html);
        Test.stopTest();

        Assert.isTrue(count > 0, 'Should detect numbered steps');
    }

    @IsTest
    static void testCalculateTitleQualityScore_GoodTitle() {
        String title = 'How to Reset Your Password in Salesforce';

        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateTitleQualityScore(title);
        Test.stopTest();

        Assert.isTrue(score > 70, 'Good title should have high score');
    }

    @IsTest
    static void testCalculateTitleQualityScore_TooShort() {
        String title = 'Help';

        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateTitleQualityScore(title);
        Test.stopTest();

        Assert.isTrue(score < 70, 'Too short title should have lower score');
    }

    @IsTest
    static void testCalculateTitleQualityScore_TooLong() {
        String title = 'This is an extremely long title that contains way too many words and should be shortened for better readability and user experience';

        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateTitleQualityScore(title);
        Test.stopTest();

        Assert.isTrue(score < 100, 'Too long title should have penalty');
    }

    @IsTest
    static void testCalculateTitleQualityScore_AllCaps() {
        String title = 'HOW TO RESET PASSWORD';

        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateTitleQualityScore(title);
        Test.stopTest();

        Assert.isTrue(score < 100, 'All caps title should have penalty');
    }

    @IsTest
    static void testCalculateTitleQualityScore_VagueStart() {
        String title = 'Info about passwords';

        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateTitleQualityScore(title);
        Test.stopTest();

        Assert.isTrue(score < 100, 'Vague start should have penalty');
    }

    @IsTest
    static void testCalculateTitleQualityScore_QuestionFormat() {
        String title = 'How can I reset my password?';

        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateTitleQualityScore(title);
        Test.stopTest();

        Assert.isTrue(score > 50, 'Question format should get bonus points');
    }

    @IsTest
    static void testCalculateTitleQualityScore_EmptyTitle() {
        Test.startTest();
        Decimal score = KBAssessmentUtils.calculateTitleQualityScore('');
        Test.stopTest();

        Assert.areEqual(0, score, 'Empty title should return 0');
    }

    @IsTest
    static void testCalculateSimilarity_IdenticalText() {
        String text1 = 'This is a test sentence';
        String text2 = 'This is a test sentence';

        Test.startTest();
        Decimal similarity = KBAssessmentUtils.calculateSimilarity(text1, text2);
        Test.stopTest();

        Assert.areEqual(100.00, similarity, 'Identical text should have 100% similarity');
    }

    @IsTest
    static void testCalculateSimilarity_NoOverlap() {
        String text1 = 'Completely different content';
        String text2 = 'Entirely unrelated material';

        Test.startTest();
        Decimal similarity = KBAssessmentUtils.calculateSimilarity(text1, text2);
        Test.stopTest();

        Assert.isTrue(similarity < 50, 'Unrelated text should have low similarity');
    }

    @IsTest
    static void testCalculateSimilarity_PartialOverlap() {
        String text1 = 'This is a test sentence about testing';
        String text2 = 'This is another test sentence about validation';

        Test.startTest();
        Decimal similarity = KBAssessmentUtils.calculateSimilarity(text1, text2);
        Test.stopTest();

        Assert.isTrue(similarity > 0 && similarity < 100, 'Partial overlap should give mid-range similarity');
    }

    @IsTest
    static void testCalculateSimilarity_EmptyAndNull() {
        Test.startTest();
        Decimal simNull = KBAssessmentUtils.calculateSimilarity(null, 'test');
        Decimal simEmpty = KBAssessmentUtils.calculateSimilarity('', 'test');
        Decimal simBoth = KBAssessmentUtils.calculateSimilarity(null, null);
        Test.stopTest();

        Assert.areEqual(0, simNull, 'Null should return 0');
        Assert.areEqual(0, simEmpty, 'Empty should return 0');
        Assert.areEqual(0, simBoth, 'Both null should return 0');
    }

    @IsTest
    static void testExtractKeyPhrases_BasicText() {
        String text = 'The quick brown fox jumps over the lazy dog. The fox is very quick and brown.';

        Test.startTest();
        List<String> phrases = KBAssessmentUtils.extractKeyPhrases(text, 3);
        Test.stopTest();

        Assert.areEqual(3, phrases.size(), 'Should return 3 key phrases');
        Assert.isTrue(phrases.contains('quick') || phrases.contains('brown') || phrases.contains('fox'),
                     'Should contain frequent words');
    }

    @IsTest
    static void testExtractKeyPhrases_StopWordsFiltered() {
        String text = 'The the the and and or but is are';

        Test.startTest();
        List<String> phrases = KBAssessmentUtils.extractKeyPhrases(text, 5);
        Test.stopTest();

        Assert.areEqual(0, phrases.size(), 'Stop words should be filtered out');
    }

    @IsTest
    static void testExtractKeyPhrases_ShortWords() {
        String text = 'a an to of in is';

        Test.startTest();
        List<String> phrases = KBAssessmentUtils.extractKeyPhrases(text, 5);
        Test.stopTest();

        Assert.areEqual(0, phrases.size(), 'Short words should be filtered out');
    }

    @IsTest
    static void testExtractKeyPhrases_EmptyText() {
        Test.startTest();
        List<String> phrases = KBAssessmentUtils.extractKeyPhrases('', 5);
        Test.stopTest();

        Assert.areEqual(0, phrases.size(), 'Empty text should return empty list');
    }

    @IsTest
    static void testExtractKeyPhrases_LimitMoreThanAvailable() {
        String text = 'testing keyword extraction';

        Test.startTest();
        List<String> phrases = KBAssessmentUtils.extractKeyPhrases(text, 10);
        Test.stopTest();

        Assert.isTrue(phrases.size() <= 10, 'Should not exceed requested limit');
        Assert.isTrue(phrases.size() > 0, 'Should return available phrases');
    }
}
