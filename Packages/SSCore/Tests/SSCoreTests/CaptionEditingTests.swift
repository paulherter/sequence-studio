import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func cap(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)), styleRef: "style", animationRef: "anim")
}
private func timeline(_ items: [CaptionItem]) throws -> (Timeline, CaptionTrack.ID) {
    var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
    let id = try t.replaceCaptions(items)
    return (t, id)
}

@Suite struct CaptionEditingTests {
    @Test func splitDividesTimeAndWordsByProportion() throws {
        let (t0, _) = try timeline([cap("one two three four", 0, 8)])
        var t = t0
        let id = t.captionTracks[0].items[0].id
        let (a, b) = try t.splitCaption(id, at: s(4))
        let items = t.captionTracks[0].items
        #expect(items.count == 2)
        #expect(items[0].range == TimeRange(start: s(0), end: s(4)) && items[1].range == TimeRange(start: s(4), end: s(8)))
        #expect(items[0].text == "one two" && items[1].text == "three four")
        #expect(items[0].id == a && items[1].id == b && a != b)
        #expect(items[1].styleRef == "style" && items[1].animationRef == "anim")   // style carries over
    }

    @Test func splitAtOneThirdKeepsAtLeastOneWordEachSide() throws {
        var (t, _) = try timeline([cap("a b c", 0, 9)])
        let id = t.captionTracks[0].items[0].id
        _ = try t.splitCaption(id, at: s(1))
        #expect(t.captionTracks[0].items.map(\.text) == ["a", "b c"])
    }

    @Test func splitOutsideOrAtEdgesIsRefused() throws {
        var (t, _) = try timeline([cap("a b", 2, 6)])
        let id = t.captionTracks[0].items[0].id
        let before = t
        #expect(throws: EditError.self) { try t.splitCaption(id, at: s(2)) }   // at the start
        #expect(throws: EditError.self) { try t.splitCaption(id, at: s(6)) }   // end is exclusive
        #expect(throws: EditError.self) { try t.splitCaption(id, at: s(9)) }
        #expect(t == before)
    }

    @Test func splitOfASingleWordKeepsTheWordInTheFirstHalf() throws {
        var (t, _) = try timeline([cap("Hello", 0, 4)])
        let id = t.captionTracks[0].items[0].id
        _ = try t.splitCaption(id, at: s(2))
        #expect(t.captionTracks[0].items.map(\.text) == ["Hello", ""])
    }

    @Test func splitIsFrameExactForRationalTimes() throws {
        var t = Timeline(name: "t", frameDuration: Time(1001, 30000), tracks: [Track(kind: .video)])
        let f = Time(1001, 30000)
        _ = try t.replaceCaptions([CaptionItem(lines: ["a b"], range: TimeRange(start: .zero, duration: f * 10))])
        let id = t.captionTracks[0].items[0].id
        _ = try t.splitCaption(id, at: f * 3)
        let it = t.captionTracks[0].items
        #expect(it[0].range.end == f * 3 && it[1].range.start == f * 3 && it[1].range.end == f * 10)
    }

    @Test func mergeJoinsTextAndSpansTheGap() throws {
        var (t, _) = try timeline([cap("one", 0, 2), cap("two", 3, 5), cap("three", 6, 8)])
        let ids = t.captionTracks[0].items.map(\.id)
        let merged = try t.mergeCaptions([ids[1], ids[0]])       // order of the argument does not matter
        let items = t.captionTracks[0].items
        #expect(items.count == 2)
        #expect(items[0].id == merged && items[0].text == "one two")
        #expect(items[0].range == TimeRange(start: s(0), end: s(5)))
        #expect(items[1].text == "three")
    }

    @Test func mergeNeedsTwoCaptionsOfOneTrackAndNoneInBetween() throws {
        var (t, _) = try timeline([cap("a", 0, 1), cap("b", 2, 3), cap("c", 4, 5)])
        let ids = t.captionTracks[0].items.map(\.id)
        let before = t
        #expect(throws: EditError.self) { try t.mergeCaptions([ids[0]]) }
        // a and c with b between: merging would swallow b, so the selection is completed to a, b, c.
        let m = try t.mergeCaptions([ids[0], ids[2]])
        #expect(t.captionTracks[0].items.count == 1 && t.captionTracks[0].items[0].id == m)
        #expect(t.captionTracks[0].items[0].text == "a b c")
        #expect(before.captionTracks[0].items.count == 3)
    }

    @Test func mergeOfTwoLineCaptionsBecomesOneLine() throws {
        var (t, _) = try timeline([CaptionItem(lines: ["a", "b"], range: TimeRange(start: s(0), end: s(1))),
                                   CaptionItem(lines: ["c", "d"], range: TimeRange(start: s(1), end: s(2)))])
        let ids = t.captionTracks[0].items.map(\.id)
        _ = try t.mergeCaptions(Set(ids))
        #expect(t.captionTracks[0].items[0].lines == ["a b c d"])
    }

    @Test func searchReplaceChangesTextOnly() throws {
        var (t, _) = try timeline([cap("Hello world", 0, 2), cap("hello again", 2, 4), cap("bye", 4, 5)])
        let before = t.captionTracks[0].items.map(\.range)
        let n = try t.replaceCaptionText(find: "hello", with: "Hi", caseSensitive: false)
        #expect(n == 2)
        #expect(t.captionTracks[0].items.map(\.text) == ["Hi world", "Hi again", "bye"])
        #expect(t.captionTracks[0].items.map(\.range) == before)
        #expect(try t.replaceCaptionText(find: "Hi", with: "Yo", caseSensitive: true) == 2)
        #expect(try t.replaceCaptionText(find: "hi", with: "x", caseSensitive: true) == 0)
        #expect(try t.replaceCaptionText(find: "", with: "x", caseSensitive: false) == 0)
    }

    @Test func searchReplaceKeepsLineBreaks() throws {
        var (t, _) = try timeline([CaptionItem(lines: ["foo bar", "foo baz"], range: TimeRange(start: s(0), end: s(1)))])
        #expect(try t.replaceCaptionText(find: "foo", with: "x", caseSensitive: false) == 2)
        #expect(t.captionTracks[0].items[0].lines == ["x bar", "x baz"])
    }

    @Test func matchesCountsAcrossCaptions() throws {
        let (t, _) = try timeline([cap("a a", 0, 1), cap("b a", 1, 2)])
        #expect(t.captionMatches(find: "a", caseSensitive: false) == [t.captionTracks[0].items[0].id, t.captionTracks[0].items[1].id])
        #expect(t.captionMatches(find: "b", caseSensitive: false) == [t.captionTracks[0].items[1].id])
    }

    @Test func styleAppliesToEveryCaptionOfTheTrack() throws {
        var (t, id) = try timeline([cap("a", 0, 1), cap("b", 1, 2)])
        try t.setCaptionStyle(styleRef: "tiktok", track: id)
        #expect(t.captionTracks[0].items.allSatisfy { $0.styleRef == "tiktok" && $0.animationRef == "anim" })
        try t.setCaptionStyle(styleRef: "tiktok", animationRef: "pop-in", track: id)
        #expect(t.captionTracks[0].items.allSatisfy { $0.animationRef == "pop-in" })
    }

    @Test func lockedTrackRefusesEdits() throws {
        var (t, id) = try timeline([cap("a b", 0, 4)])
        t.captionTracks[0].isLocked = true
        let item = t.captionTracks[0].items[0].id
        #expect(throws: EditError.trackLocked) { try t.splitCaption(item, at: s(2)) }
        #expect(throws: EditError.trackLocked) { try t.setCaptionStyle(styleRef: "x", track: id) }
        #expect(throws: EditError.trackLocked) { try t.replaceCaptionText(find: "a", with: "b", caseSensitive: false) }   // all locked
    }

    @Test func addCaptionAtPlayheadFillsFreeSpace() throws {
        var (t, id) = try timeline([cap("a", 0, 2), cap("b", 4, 6)])
        let n = try t.addCaption(at: s(2), duration: s(3), track: id)
        let item = t.captionTracks[0].item(n)!
        #expect(item.range == TimeRange(start: s(2), end: s(4)))           // cut short by b
        #expect(item.styleRef == "style")                                  // takes the track's current style
        #expect(throws: EditError.self) { try t.addCaption(at: s(5), duration: s(1), track: id) }   // inside b
    }

    @Test func splitKeepsLineBreaksWhereItCan() throws {
        var (t, _) = try timeline([CaptionItem(lines: ["a b", "c d"], range: TimeRange(start: s(0), end: s(8)))])
        let id = t.captionTracks[0].items[0].id
        _ = try t.splitCaption(id, at: s(4))
        #expect(t.captionTracks[0].items.map(\.lines) == [["a b"], ["c d"]])
        var (u, _) = try timeline([CaptionItem(lines: ["a b", "c d"], range: TimeRange(start: s(0), end: s(8)))])
        _ = try u.splitCaption(u.captionTracks[0].items[0].id, at: s(2))
        #expect(u.captionTracks[0].items.map(\.lines) == [["a"], ["b", "c d"]])
    }

    @Test func replaceSkipsLockedTracksAndSameTextIsANoOp() throws {
        var t = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        _ = try t.replaceCaptions([cap("cat", 0, 1)])
        var locked = CaptionTrack(name: "C2", isLocked: true)
        try locked.replaceAll([cap("cat", 2, 3)])
        t.captionTracks.append(locked)
        #expect(try t.replaceCaptionText(find: "cat", with: "dog", caseSensitive: false) == 1)
        #expect(t.captionTracks[0].items[0].text == "dog" && t.captionTracks[1].items[0].text == "cat")
        #expect(try t.replaceCaptionText(find: "dog", with: "dog", caseSensitive: true) == 0)
    }
}

