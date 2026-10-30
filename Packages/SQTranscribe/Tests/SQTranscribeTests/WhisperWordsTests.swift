import Foundation
import SQCore
import Testing
@testable import SQTranscribe

@Suite struct WhisperWordsTests {
    private func tok(_ s: String, _ t0: Int64, _ t1: Int64, p: Float = 0.9, special: Bool = false) -> WhisperToken {
        WhisperToken(bytes: Array(s.utf8), isSpecial: special, startCs: t0, endCs: t1, probability: p)
    }

    @Test func leadingSpaceStartsAWordAndPunctuationAttachesToTheWordBefore() {
        let words = WhisperWords.words(from: [
            tok(" Hallo", 10, 40), tok(",", 40, 45), tok(" Welt", 50, 90), tok("!", 90, 95),
        ])
        #expect(words.map(\.text) == ["Hallo,", "Welt!"])
        #expect(words[0].range == TimeRange(start: Time(10, 100), end: Time(45, 100)))
        #expect(words[1].range == TimeRange(start: Time(50, 100), end: Time(95, 100)))
    }

    @Test func specialTokensAreDroppedAndTheLowestProbabilityBecomesTheConfidence() {
        let words = WhisperWords.words(from: [
            tok("[_BEG_]", 0, 0, special: true), tok(" Na", 0, 20, p: 0.8), tok("ja", 20, 40, p: 0.4),
            tok("<|endoftext|>", 40, 40, special: true),
        ])
        #expect(words.map(\.text) == ["Naja"])
        #expect(words[0].confidence == 0.4)
    }

    @Test func aCharacterSplitAcrossTokensIsJoinedBeforeDecoding() {
        let bytes = Array(" Grüße".utf8)               // ü is two bytes: the second token starts mid-character
        let cut = bytes.firstIndex(of: 0xC3)! + 1
        let a = WhisperToken(bytes: Array(bytes[..<cut]), isSpecial: false, startCs: 0, endCs: 10, probability: 0.9)
        let b = WhisperToken(bytes: Array(bytes[cut...]), isSpecial: false, startCs: 10, endCs: 30, probability: 0.9)
        #expect(WhisperWords.words(from: [a, b]).map(\.text) == ["Grüße"])
    }

    @Test func timesNeverGoBackwardsAndAWordEndsNotBeforeItStarts() {
        let words = WhisperWords.words(from: [tok(" a", 50, 40), tok(" b", 30, 35)])
        #expect(words[0].range.end >= words[0].range.start)
        #expect(words[1].range.start >= words[0].range.start)
        #expect(words[1].range.end >= words[1].range.start)
    }

    @Test func whitespaceOnlyTokensMakeNoWord() {
        #expect(WhisperWords.words(from: [tok(" ", 0, 5), tok("\n", 5, 9)]).isEmpty)
    }
}

@Suite struct WhisperLanguagesTests {
    @Test func regionAndScriptAreDroppedAndUnknownCodesAreRefused() {
        #expect(WhisperLanguages.code(for: Locale(identifier: "de-DE")) == "de")
        #expect(WhisperLanguages.code(for: Locale(identifier: "en_GB")) == "en")
        #expect(WhisperLanguages.code(for: Locale(identifier: "zh-Hans-CN")) == "zh")
        #expect(WhisperLanguages.code(for: Locale(identifier: "tlh")) == nil)
    }

    @Test func theSupportedListKeepsTheRegionsOfTheUIDefaults() {
        let list = WhisperLanguages.supported
        for d in ["de-DE", "en-US", "en-GB", "fr-FR", "es-ES", "it-IT"] { #expect(list.contains(d)) }
        #expect(!list.contains("de") && !list.contains("en"))
        #expect(list.contains("ja"))
        #expect(Set(list).count == list.count)
    }
}
