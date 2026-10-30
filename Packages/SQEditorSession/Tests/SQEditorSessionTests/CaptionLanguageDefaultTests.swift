import Foundation
import Testing
@testable import SQEditorSession

@Suite struct CaptionLanguageDefaultTests {
    @Test func exactRegionWins() {
        #expect(AppSettings.derivedCaptionLanguage(preferred: ["en-GB", "de-DE"]) == "en-GB")
    }

    @Test func sameLanguageOtherRegionMapsToSupported() {
        #expect(AppSettings.derivedCaptionLanguage(preferred: ["de-AT"]) == "de-DE")
        #expect(AppSettings.derivedCaptionLanguage(preferred: ["fr_CA"]) == "fr-FR")
    }

    @Test func unsupportedFallsBackToEnglishOrNextPreferred() {
        #expect(AppSettings.derivedCaptionLanguage(preferred: ["ja-JP"]) == "en-US")
        #expect(AppSettings.derivedCaptionLanguage(preferred: ["ja-JP", "es-MX"]) == "es-ES")
        #expect(AppSettings.derivedCaptionLanguage(preferred: []) == "en-US")
    }

    @Test func projectLanguageFallsBackToTheSetting() {
        let d = UserDefaults(suiteName: "sq.test.captionlang.\(UUID().uuidString)")!
        let id = UUID()
        #expect(AppSettings.captionLanguage(forProject: id, from: d) == AppSettings.defaultCaptionLanguage)
        AppSettings.setCaptionLanguage("fr-FR", forProject: id, to: d)
        #expect(AppSettings.captionLanguage(forProject: id, from: d) == "fr-FR")
    }
}
