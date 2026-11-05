import Testing
@testable import Critique

struct DictationStartedOverTests {
    @Test func longerTextIsARevisionNotARestart() {
        #expect(!Dictation.startedOver(from: "the button is too", to: "the button is too big"))
        #expect(!Dictation.startedOver(from: "the button is too big", to: "the button is too big"))
    }

    @Test func mostlyTheSameWordsIsACorrection() {
        // The recognizer dropped a word while fixing itself.
        #expect(!Dictation.startedOver(from: "the header looks fine but this", to: "the header looks fine"))
        #expect(!Dictation.startedOver(from: "the sign up button is way too big", to: "the sign-up button is too big"))
    }

    @Test func aFreshSentenceIsARestart() {
        #expect(Dictation.startedOver(from: "the header looks fine but this button", to: "and the text"))
        #expect(Dictation.startedOver(from: "This button is way too big.", to: "Also the"))
    }

    @Test func aRestartThatBeginsWithTheSameWordIsNot() {
        // Same first word: more likely the recognizer re-heard the same sentence.
        #expect(!Dictation.startedOver(from: "the header looks fine", to: "the"))
        #expect(!Dictation.startedOver(from: "the header looks fine", to: "the text"))
    }

    @Test func shortTexts() {
        // Too little before to tell.
        #expect(!Dictation.startedOver(from: "", to: "hello"))
        #expect(!Dictation.startedOver(from: "hello", to: "x"))
        // Nothing after.
        #expect(!Dictation.startedOver(from: "hello world", to: ""))
        #expect(!Dictation.startedOver(from: "hello world", to: "..."))
        // One new word that was not there before.
        #expect(Dictation.startedOver(from: "hello world", to: "hi"))
    }

    @Test func punctuationAndCaseDoNotCount() {
        #expect(!Dictation.startedOver(from: "The header, looks fine!", to: "the header looks"))
        #expect(!Dictation.startedOver(from: "don't click that button", to: "Don't click that"))
    }
}
