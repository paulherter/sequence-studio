import Foundation
import Testing
@testable import SQCore

private func t(_ n: Int64) -> Time { Time(n, 1) }
private func r(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: t(a), end: t(b)) }

/// Unsure words: the recognizer's confidence rides on each caption word, is cleared by a hand edit and gates the file at v75.
@Suite struct CaptionWordConfidenceTests {
    private static func item() -> CaptionItem {
        CaptionItem(lines: ["one two three"], range: r(10, 16), styleRef: "style", animationRef: "anim",
                    words: [CaptionWord(text: "one", range: r(0, 1), confidence: 0.9),
                            CaptionWord(text: "two", range: r(1, 2), confidence: 0.2),
                            CaptionWord(text: "three", range: r(3, 4))])
    }

    private static func timeline(_ i: CaptionItem) throws -> Timeline {
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        try tl.replaceCaptions([i])
        return tl
    }

    private static func conf(_ tl: Timeline) -> [Float?] { tl.captionTracks[0].items.flatMap { $0.words.map(\.confidence) } }

    // MARK: Value and file

    @Test func unsureIsBelowTheThresholdAndNilIsNeverUnsure() {
        #expect(CaptionWord.unsureBelow == 0.5)
        #expect(CaptionWord(text: "a", range: r(0, 1), confidence: 0.49).isUnsure)
        #expect(!CaptionWord(text: "a", range: r(0, 1), confidence: 0.5).isUnsure)
        #expect(!CaptionWord(text: "a", range: r(0, 1)).isUnsure)
        #expect(CaptionWord.isUnsure(confidence: 0.1))
        #expect(!CaptionWord.isUnsure(confidence: nil))
    }

    @Test func nilConfidenceIsNotEncodedAndOldWordsDecode() throws {
        let w = CaptionWord(text: "a", range: r(0, 1))
        #expect(!String(decoding: try JSONEncoder().encode(w), as: UTF8.self).contains("confidence"))
        let back = try JSONDecoder().decode(CaptionWord.self, from: JSONEncoder().encode(w))
        #expect(back == w && back.confidence == nil)
        let with = CaptionWord(text: "a", range: r(0, 1), confidence: 0.25)
        #expect(try JSONDecoder().decode(CaptionWord.self, from: JSONEncoder().encode(with)).confidence == 0.25)
    }

    @Test func aConfidenceSurvivesTheFileAndGatesV75() throws {
        let tl = try Self.timeline(Self.item())
        let p = Project(name: "P", timelines: [tl])
        #expect(p.containsV75Content)
        #expect(ProjectFile.writtenVersion(for: p) == 75)
        #expect(ProjectFile.currentVersion >= 75)
        let back = try ProjectFile.decode(ProjectFile.encode(p), migrations: nil)
        #expect(Self.conf(back.timelines[0]) == [0.9, 0.2, nil])
    }

    @Test func aProjectWithoutConfidenceKeepsTheOldVersion() throws {
        var i = Self.item()
        i.words = i.words.map { CaptionWord(text: $0.text, range: $0.range) }
        let p = Project(name: "P", timelines: [try Self.timeline(i)])
        #expect(!p.containsV75Content)
        #expect(ProjectFile.writtenVersion(for: p) < 75)
    }

    @Test func aV74FileDecodesWithoutConfidence() throws {
        var i = Self.item()
        i.words = i.words.map { CaptionWord(text: $0.text, range: $0.range) }
        let p = Project(name: "P", timelines: [try Self.timeline(i)])
        var obj = try #require(JSONSerialization.jsonObject(with: ProjectFile.encode(p)) as? [String: Any])
        obj["formatVersion"] = 74
        let old = try JSONSerialization.data(withJSONObject: obj)
        let back = try ProjectFile.decode(old, migrations: nil)
        #expect(Self.conf(back.timelines[0]) == [nil, nil, nil])
    }

    // MARK: Editing

    @Test func editingAWordClearsOnlyItsConfidence() throws {
        var tl = try Self.timeline(Self.item())
        let id = tl.captionTracks[0].items[0].id
        _ = try tl.setCaptionWord(id, index: 1, text: "too")
        #expect(Self.conf(tl) == [0.9, nil, nil])
        _ = try tl.setCaptionWord(id, index: 0, text: "one")           // same text: nothing was changed
        #expect(Self.conf(tl) == [0.9, nil, nil])
    }

    @Test func splittingAndJoiningKeepEachWordsValue() throws {
        var tl = try Self.timeline(Self.item())
        let (a, b) = try tl.splitCaption(tl.captionTracks[0].items[0].id, beforeWord: 1)
        #expect(Self.conf(tl) == [0.9, 0.2, nil])
        #expect(try tl.joinCaption(a, with: .next) == a)
        #expect(Self.conf(tl) == [0.9, 0.2, nil])
        _ = b
    }

    @Test func aHeadTrimShiftKeepsConfidence() {
        var i = Self.item()
        i.shiftWordOrigin(by: Time(1, 2))
        #expect(i.words.map(\.confidence) == [0.9, 0.2, nil])
        #expect(i.effectiveWords.map(\.confidence) == [0.9, 0.2, nil])
    }
}
