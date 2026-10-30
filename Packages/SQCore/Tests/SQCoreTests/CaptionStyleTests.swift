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

    @Test func ownAnimationTouchesOnlyTheChosenCaptions() throws {
        var (t, id) = try timeline([cap("a", 0, 1), cap("b", 2, 3)])
        try t.setCaptionStyle(styleRef: "tiktok", animationRef: "pop", track: id)
        let b = t.captionTracks[0].items[1].id
        try t.setCaptionItemAnimation([b], animationRef: "fade")
        #expect(t.captionTracks[0].items.map(\.animationRef) == ["pop", "fade"])
        // The caption keeps its animation when the track look changes.
        try t.setCaptionStyle(styleRef: "youtube", animationRef: "slide", track: id)
        #expect(t.captionTracks[0].items.map(\.animationRef) == ["slide", "fade"])
        #expect(t.captionTracks[0].items.map(\.styleRef) == ["youtube", "tiktok"])
    }

    @Test func clearingTheOwnAnimationFollowsTheTrackAgain() throws {
        var (t, id) = try timeline([cap("a", 0, 1)])
        let a = t.captionTracks[0].items[0].id
        try t.setCaptionStyle(styleRef: "tiktok", animationRef: "pop", track: id)
        try t.setCaptionItemAnimation([a], animationRef: "fade")
        try t.setCaptionItemAnimation([a], animationRef: nil)
        #expect(t.captionTracks[0].items[0].animationRef == "pop")
        #expect(!t.captionTracks[0].items[0].styleOverridden)
    }

    @Test func ownAnimationOnALockedTrackThrows() throws {
        var (t, _) = try timeline([cap("a", 0, 1)])
        t.captionTracks[0].isLocked = true
        let a = t.captionTracks[0].items[0].id
        #expect(throws: EditError.self) { try t.setCaptionItemAnimation([a], animationRef: "fade") }
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

    // MARK: Review finding 9: sub-frame neighbor overlap

    @Test func trimHeadNeverGoesBeforeThePreviousCaption() {
        let f = Time(1, 30)
        var track = CaptionTrack()
        let a = CaptionItem(lines: ["a"], range: TimeRange(start: .zero, end: Time(10, 30)))
        // b is shorter than one frame (a neighbor squeezed it).
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

    // MARK: Word times follow edits (relative to the caption start)

    /// "a b" at 10..14 s, a = first second, b = third second of the caption.
    private func timed(_ start: Int64 = 10) -> (Timeline, CaptionItem.ID) {
        var it = cap("a b", start, start + 4)
        it.words = [CaptionWord(text: "a", range: TimeRange(start: .zero, end: s(1))),
                    CaptionWord(text: "b", range: TimeRange(start: s(2), end: s(3)))]
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try? t.replaceCaptions([it])
        return (t, it.id)
    }
    private func lit(_ t: Timeline, _ id: CaptionItem.ID, at sec: Time) -> Int? {
        t.captionTracks[0].item(id)?.activeWord(at: sec)
    }

    @Test func movingACaptionMovesItsWords() throws {
        var (t, id) = timed()
        try t.moveCaption(id, to: s(20))
        #expect(lit(t, id, at: Time(41, 2)) == 0 && lit(t, id, at: Time(45, 2)) == 1)   // 20.5 s, 22.5 s
    }

    @Test func aRippleKeepsTheWordsInPlaceRelativeToTheCaption() {
        var (t, id) = timed()
        t.openCaptionGap(at: s(2), by: s(5))                      // caption moves 10 -> 15
        #expect(t.captionTracks[0].item(id)?.range.start == s(15))
        #expect(lit(t, id, at: Time(31, 2)) == 0 && lit(t, id, at: Time(35, 2)) == 1)   // 15.5, 17.5
        t.closeCaptionSpan(TimeRange(start: s(0), end: s(5)))     // and back to 10
        #expect(lit(t, id, at: Time(21, 2)) == 0 && lit(t, id, at: Time(25, 2)) == 1)   // 10.5, 12.5
    }

    @Test func aHeadTrimKeepsTheSpeechWhereItWas() throws {
        var (t, id) = timed()
        try t.trimCaption(id, edge: .head, to: s(12))             // the first word (10..11) is cut off
        #expect(t.captionTracks[0].item(id)?.range.start == s(12))
        #expect(lit(t, id, at: Time(25, 2)) == 1)                 // 12.5 s: still the word b
        #expect(lit(t, id, at: Time(27, 2)) == nil)               // 13.5 s: word b ended at 13
        let w = t.captionTracks[0].items[0].effectiveWords
        #expect(w.allSatisfy { $0.range.start >= s(12) && $0.range.end <= s(14) })   // clamped into the caption
    }

    @Test func aTailTrimClampsAndKeepsTheStart() throws {
        var (t, id) = timed()
        try t.trimCaption(id, edge: .tail, to: Time(25, 2))        // ends at 12.5, inside word b
        #expect(lit(t, id, at: Time(21, 2)) == 0 && lit(t, id, at: Time(49, 4)) == 1)   // 10.5; 12.25
        #expect(lit(t, id, at: s(13)) == nil)
        #expect(t.captionTracks[0].items[0].effectiveWords[1].range.end == Time(25, 2))
    }

    @Test func splitCutsWhereTheSpeechIs() throws {
        var it = cap("a b c d", 0, 8)
        it.words = [("a", 0, 1), ("b", 1, 2), ("c", 2, 3), ("d", 7, 8)].map {
            CaptionWord(text: $0.0, range: TimeRange(start: s(Int64($0.1)), end: s(Int64($0.2))))
        }
        var (t, _) = try timeline([it])
        _ = try t.splitCaption(it.id, at: s(4))      // by proportion this would be 2 + 2; three words end before 4 s
        let items = t.captionTracks[0].items
        #expect(items.map(\.text) == ["a b c", "d"])
        #expect(items[1].effectiveWords.map(\.range.start) == [s(7)])
        #expect(items[1].words[0].range.start == s(3))   // relative to the new start at 4 s
        #expect(items[1].activeWord(at: Time(15, 2)) == 0)
    }

    @Test func matchesAreOrderedByTimeAcrossTracks() throws {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([cap("cat", 5, 6)])
        let second = CaptionTrack(items: [cap("cat", 1, 2), cap("cat", 8, 9)])
        t.captionTracks.append(second)
        let order = t.captionMatches(find: "cat", caseSensitive: false)
        let starts = order.compactMap { id in t.captionTracks.flatMap(\.items).first { $0.id == id }?.range.start }
        #expect(starts == [s(1), s(5), s(8)])
    }
}
