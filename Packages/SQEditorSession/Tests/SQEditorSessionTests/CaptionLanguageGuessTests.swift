import Testing
@testable import SQEditorSession

@Suite struct CaptionLanguageGuessTests {
    let supported = ["de-DE", "en-US", "en-GB", "fr-FR"]
    let german = "Heute zeigen wir euch, wie man einen Film schneidet und dabei viel Zeit spart."
    let english = "Today we show you how to cut a film and save a lot of time while doing it."

    @Test func germanTextAfterEnglishRunPicksGerman() {
        #expect(CaptionLanguageGuess.retryLanguage(text: german, used: "en-US", supported: supported, preferred: []) == "de-DE")
    }
    @Test func sameLanguageNeedsNoRetry() {
        #expect(CaptionLanguageGuess.retryLanguage(text: english, used: "en-GB", supported: supported, preferred: []) == nil)
    }
    @Test func regionFollowsSystemLanguage() {
        #expect(CaptionLanguageGuess.retryLanguage(text: english, used: "de-DE", supported: supported, preferred: ["en-GB"]) == "en-GB")
    }
    @Test func shortTextIsNotTrusted() {
        #expect(CaptionLanguageGuess.retryLanguage(text: "Hallo Welt", used: "en-US", supported: supported, preferred: []) == nil)
    }
    @Test func unsupportedLanguageIsSkipped() {
        #expect(CaptionLanguageGuess.retryLanguage(text: german, used: "en-US", supported: ["en-US", "fr-FR"], preferred: []) == nil)
    }
}
