import Foundation
import Testing
@testable import SQCore

private func t(_ n: Int64) -> Time { Time(n, 1000) }

@Suite struct CaptionTranslationTests {
    private func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
        CaptionItem(lines: [text], range: TimeRange(start: t(a), end: t(b)), styleRef: "bold", animationRef: "pop",
                    styleOverridden: true, words: [CaptionWord(text: "x", range: TimeRange(start: .zero, end: t(100)))],
                    position: CaptionPosition(vertical: .top))
    }

    @Test func timingsAndLookStayTextChanges() throws {
        let src = [item("Hello world", 0, 1000), item("Bye", 1500, 2000)]
        let out = try #require(CaptionTranslation.translatedItems(from: src, texts: ["Hallo Welt", "Tschüss"]))
        #expect(out.map(\.text) == ["Hallo Welt", "Tschüss"])
        #expect(out.map(\.range) == src.map(\.range))
        #expect(out.allSatisfy { $0.styleRef == "bold" && $0.animationRef == "pop" && $0.styleOverridden })
        #expect(out.map(\.position) == src.map(\.position))
        #expect(out.allSatisfy { $0.words.isEmpty })
        #expect(Set(out.map(\.id)).isDisjoint(with: src.map(\.id)))
    }

    @Test func countMismatchIsRefused() {
        #expect(CaptionTranslation.translatedItems(from: [item("a", 0, 1)], texts: []) == nil)
    }

    @Test func emptyTranslationKeepsTheSourceText() throws {
        let out = try #require(CaptionTranslation.translatedItems(from: [item("keep", 0, 500)], texts: ["  "]))
        #expect(out[0].text == "keep")
    }

    @Test func longTextBreaksIntoTwoBalancedLines() throws {
        let out = try #require(CaptionTranslation.translatedItems(from: [item("x", 0, 500)],
                                                                  texts: ["Das ist ein ziemlich langer Untertitel mit vielen Wörtern"], maxCharsPerLine: 30))
        #expect(out[0].lines == ["Das ist ein ziemlich langer", "Untertitel mit vielen Wörtern"])
    }

    @Test func trackNameCarriesTheLanguage() {
        #expect(CaptionTranslation.trackName(source: "Captions 1", language: "de") == "Captions 1 (de)")
        #expect(CaptionTranslation.trackName(source: "", language: "fr") == "Captions (fr)")
    }
}
