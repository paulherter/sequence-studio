import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func cap(_ text: String, _ a: Int64, _ b: Int64, style: String = "default") -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)), styleRef: style, animationRef: "none")
}
private func timeline(_ items: [CaptionItem]) throws -> (Timeline, CaptionTrack.ID) {
    var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
    let id = try t.replaceCaptions(items)
    return (t, id)
}

@Suite struct CaptionStyleTests {
    // MARK: Track style with per-item overrides

    @Test func trackStyleChangesEveryItemWithoutAnOverride() throws {
        var (t, id) = try timeline([cap("a", 0, 1), cap("b", 2, 3), cap("c", 4, 5)])
        let b = t.captionTracks[0].items[1].id
        try t.setCaptionItemStyle([b], styleRef: "outline")
        try t.setCaptionStyle(styleRef: "tiktok", track: id)
        let it = t.captionTracks[0].items
        #expect(it.map(\.styleRef) == ["tiktok", "outline", "tiktok"])
        #expect(t.captionTracks[0].styleRef == "tiktok")
        #expect(it[1].styleOverridden && !it[0].styleOverridden)
    }

    @Test func clearingTheOverrideFollowsTheTrackAgain() throws {
        var (t, id) = try timeline([cap("a", 0, 1), cap("b", 2, 3)])
        let b = t.captionTracks[0].items[1].id
        try t.setCaptionStyle(styleRef: "tiktok", track: id)
        try t.setCaptionItemStyle([b], styleRef: "outline")
        try t.setCaptionItemStyle([b], styleRef: nil)
        #expect(t.captionTracks[0].items[1].styleRef == "tiktok")
        #expect(!t.captionTracks[0].items[1].styleOverridden)
    }

    @Test func newCaptionsTakeTheTrackStyle() throws {
        var (t, id) = try timeline([cap("a", 0, 1)])
        try t.setCaptionStyle(styleRef: "youtube", track: id)
        let n = try t.addCaption(at: s(5), duration: s(1))
        #expect(t.captionTracks[0].item(n)?.styleRef == "youtube")
        #expect(t.captionTracks[0].item(n)?.styleOverridden == false)
    }

    @Test func oldFilesDecodeWithoutOverridesWordsOrKaraoke() throws {
        let json = #"{"id":"7B2E2F1A-0000-4000-8000-000000000001","lines":["x"],"range":{"start":{"value":0,"timescale":1},"duration":{"value":1,"timescale":1}},"styleRef":"default","animationRef":"none"}"#
        let it = try JSONDecoder().decode(CaptionItem.self, from: Data(json.utf8))
        #expect(!it.styleOverridden && it.words.isEmpty)
        let tj = #"{"id":"7B2E2F1A-0000-4000-8000-000000000002","items":[]}"#
        let tr = try JSONDecoder().decode(CaptionTrack.self, from: Data(tj.utf8))
        #expect(tr.karaoke == nil && tr.styleRef == "")
    }

    @Test func styleFieldsRoundTrip() throws {
        var (t, id) = try timeline([cap("a b", 0, 2)])
        try t.setCaptionStyle(styleRef: "tiktok", track: id)
        try t.setCaptionKaraoke(KaraokeStyle(), track: id)
        let d = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(t))
        #expect(d.captionTracks[0].karaoke == KaraokeStyle() && d.captionTracks[0].styleRef == "tiktok")
    }

    // MARK: Karaoke keys

    private func words(_ spec: [(String, Int64, Int64)]) -> [CaptionWord] {
        spec.map { CaptionWord(text: $0.0, range: TimeRange(start: Time($0.1, 10), end: Time($0.2, 10))) }
    }

    @Test func wordTimingsBecomePerWordKeys() {
        var it = cap("one two three", 0, 4)
        it.words = words([("one", 0, 10), ("two", 12, 20), ("three", 20, 31)])
        let keys = it.karaokeKeys
        #expect(keys.map(\.activeWord) == [0, 1, 2, nil])
        #expect(keys.map(\.time) == [Time(0, 10), Time(12, 10), Time(20, 10), Time(31, 10)])
    }

    @Test func activeWordHoldsUntilTheNextWordStarts() {
        var it = cap("one two", 0, 4)
        it.words = words([("one", 0, 5), ("two", 12, 20)])
        #expect(it.activeWord(at: Time(0, 10)) == 0)
        #expect(it.activeWord(at: Time(8, 10)) == 0)     // the pause: the spoken word stays lit
        #expect(it.activeWord(at: Time(12, 10)) == 1)
        #expect(it.activeWord(at: Time(19, 10)) == 1)
        #expect(it.activeWord(at: Time(20, 10)) == nil)  // after the last word ended
    }

    @Test func wordsWithoutTimingsAreSpreadByLength() {
        let it = cap("aa bbbb", 0, 6)     // 2 + 4 characters over 6 s
        let w = it.effectiveWords
        #expect(w.map(\.text) == ["aa", "bbbb"])
        #expect(w[0].range == TimeRange(start: s(0), end: s(2)) && w[1].range == TimeRange(start: s(2), end: s(6)))
    }

    @Test func editedTextKeepsTimingsWhileTheWordCountMatches() {
        var it = cap("one two", 0, 4)
        it.words = words([("one", 0, 10), ("two", 12, 20)])
        it.lines = ["uno dos"]
        #expect(it.effectiveWords.map(\.text) == ["uno", "dos"])
        #expect(it.effectiveWords[1].range.start == Time(12, 10))
        it.lines = ["uno dos tres"]   // count changed: spread again
        #expect(it.effectiveWords.count == 3 && it.effectiveWords[0].range.start == s(0))
    }

    @Test func splitAndMergeKeepWordTimings() throws {
        var (t, _) = try timeline([cap("a b c d", 0, 8)])
        var it = t.captionTracks[0].items[0]
        it.words = (0..<4).map { CaptionWord(text: ["a", "b", "c", "d"][$0], range: TimeRange(start: s(Int64($0) * 2), end: s(Int64($0) * 2 + 1))) }
        var tr = t.captionTracks[0]
        try tr.replaceAll([it])
        t.captionTracks[0] = tr
        let (l, r) = try t.splitCaption(it.id, at: s(4))
        let items = t.captionTracks[0].items
        #expect(items[0].effectiveWords.map(\.range.start) == [s(0), s(2)])
        #expect(items[1].effectiveWords.map(\.range.start) == [s(4), s(6)])
        _ = try t.mergeCaptions([l, r])
        #expect(t.captionTracks[0].items[0].effectiveWords.map(\.text) == ["a", "b", "c", "d"])
        #expect(t.captionTracks[0].items[0].effectiveWords.map(\.range.start) == [s(0), s(2), s(4), s(6)])
    }

    // MARK: Review finding 9: sub-frame neighbour overlap

    @Test func trimHeadNeverGoesBeforeThePreviousCaption() {
        let f = Time(1, 30)
        var track = CaptionTrack()
        let a = CaptionItem(lines: ["a"], range: TimeRange(start: .zero, end: Time(10, 30)))
        // b is shorter than one frame (a neighbour squeezed it).
        let b = CaptionItem(lines: ["b"], range: TimeRange(start: Time(10, 30), end: Time(10, 30) + Time(1, 60)))
        try? track.replaceAll([a, b])
        _ = track.trim(b.id, edge: .head, to: Time(100, 30), minDuration: f)
        let items = track.items
        #expect(items[0].range.end <= items[1].range.start)
        #expect(items[1].range.start >= Time(10, 30))
    }

    @Test func trimTailNeverGoesPastTheNextCaption() {
        let f = Time(1, 30)
        var track = CaptionTrack()
        let a = CaptionItem(lines: ["a"], range: TimeRange(start: .zero, end: Time(1, 60)))
        let b = CaptionItem(lines: ["b"], range: TimeRange(start: Time(1, 60), end: Time(1, 60) + f))
        try? track.replaceAll([a, b])
        _ = track.trim(a.id, edge: .tail, to: Time(50, 30), minDuration: f)
        #expect(track.items[0].range.end <= track.items[1].range.start)
    }

    @Test func trimNeverOverlapsProperty() {
        var rng = SystemRandomNumberGenerator()
        let f = Time(1, 30)
        for _ in 0..<300 {
            var items: [CaptionItem] = []
            var cursor = Int64(0)
            for _ in 0..<5 {
                cursor += Int64.random(in: 0...3, using: &rng)
                let len = Int64.random(in: 1...6, using: &rng)   // in 1/60 s: from half a frame up
                items.append(CaptionItem(lines: ["x"], range: TimeRange(start: Time(cursor, 60), end: Time(cursor + len, 60))))
                cursor += len
            }
            var track = CaptionTrack()
            try? track.replaceAll(items)
            for _ in 0..<6 {
                let it = track.items[Int.random(in: 0..<track.items.count, using: &rng)]
                _ = track.trim(it.id, edge: Bool.random(using: &rng) ? .head : .tail,
                               to: Time(Int64.random(in: -5...80, using: &rng), 60), minDuration: f)
                for (x, y) in zip(track.items, track.items.dropFirst()) { #expect(x.range.end <= y.range.start) }
                #expect(track.items.allSatisfy { $0.range.start >= .zero && !$0.range.isEmpty })
            }
        }
    }
}
