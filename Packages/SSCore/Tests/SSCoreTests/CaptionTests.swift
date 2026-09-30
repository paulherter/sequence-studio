import Foundation
import Testing
@testable import SSCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func cap(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)), styleRef: "style", animationRef: "anim")
}
private func clip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}
private func base(clips: [Clip] = []) throws -> Timeline {
    var v = Track(kind: .video)
    for c in clips { try v.overwrite(c) }
    return Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v])
}

@Suite struct CaptionTests {
    @Test func replaceCreatesTrackAndSorts() throws {
        var t = try base()
        let id = try t.replaceCaptions([cap("b", 4, 6), cap("a", 0, 2)])
        #expect(t.captionTracks.count == 1)
        #expect(t.captionTracks[0].items.map(\.text) == ["a", "b"])
        // Replacing again reuses the track and drops the old items.
        #expect(try t.replaceCaptions([cap("c", 1, 2)]) == id)
        #expect(t.captionTracks[0].items.map(\.text) == ["c"])
        #expect(try t.replaceCaptions([]) == id)
        #expect(t.captionTracks[0].items.isEmpty)
    }

    @Test func replaceRejectsOverlapAndEmptyWithoutChange() throws {
        var t = try base()
        let id = try t.replaceCaptions([cap("a", 0, 2)])
        let before = t
        #expect(throws: EditError.collision) { try t.replaceCaptions([cap("a", 0, 3), cap("b", 2, 4)], track: id) }
        #expect(throws: EditError.emptyClip) { try t.replaceCaptions([cap("a", 1, 1)], track: id) }
        #expect(t == before)
        // Touching items are fine.
        _ = try t.replaceCaptions([cap("a", 0, 2), cap("b", 2, 4)], track: id)
    }

    @Test func editTextKeepsTiming() throws {
        var t = try base()
        _ = try t.replaceCaptions([cap("a", 0, 2)])
        let item = t.captionTracks[0].items[0]
        try t.setCaptionText(item.id, lines: ["x", "y"])
        let back = t.captionTracks[0].items[0]
        #expect(back.lines == ["x", "y"] && back.text == "x\ny")
        #expect(back.range == item.range && back.styleRef == "style" && back.animationRef == "anim")
        #expect(throws: EditError.clipNotFound) { try t.setCaptionText(UUID(), lines: []) }
    }

    @Test func moveClampsToNeighbours() throws {
        var t = try base()
        _ = try t.replaceCaptions([cap("a", 2, 4), cap("b", 6, 8), cap("c", 10, 12)])
        let b = t.captionTracks[0].items[1].id
        #expect(try t.moveCaption(b, to: s(5)) == s(5))                  // free
        #expect(try t.moveCaption(b, to: s(0)) == s(4))                  // stops at a's end
        #expect(try t.moveCaption(b, to: s(20)) == s(8))                 // stops at c (duration 2 -> start 8)
        let a = t.captionTracks[0].items[0].id
        #expect(try t.moveCaption(a, to: s(-5)) == .zero)                // never before 0
        #expect(t.captionTracks[0].items.map(\.range.start) == [s(0), s(8), s(10)])
    }

    @Test func trimClampsToNeighboursAndOneFrame() throws {
        var t = try base()
        _ = try t.replaceCaptions([cap("a", 0, 2), cap("b", 4, 8), cap("c", 9, 12)])
        let b = t.captionTracks[0].items[1].id
        #expect(try t.trimCaption(b, edge: .head, to: s(1)) == TimeRange(start: s(2), end: s(8)))     // a's end
        #expect(try t.trimCaption(b, edge: .tail, to: s(20)) == TimeRange(start: s(2), end: s(9)))    // c's start
        let frame = Time(1, 30)
        #expect(try t.trimCaption(b, edge: .tail, to: s(0)) == TimeRange(start: s(2), duration: frame))
        #expect(try t.trimCaption(b, edge: .head, to: s(100)).duration == frame)
        let c = t.captionTracks[0].items[2].id
        #expect(try t.trimCaption(c, edge: .tail, to: s(15)) == TimeRange(start: s(9), end: s(15)))
    }

    @Test func deleteAndLock() throws {
        var t = try base()
        let id = try t.replaceCaptions([cap("a", 0, 2), cap("b", 3, 4)])
        let a = t.captionTracks[0].items[0].id
        try t.deleteCaption(a)
        #expect(t.captionTracks[0].items.map(\.text) == ["b"])
        #expect(throws: EditError.clipNotFound) { try t.deleteCaption(a) }
        t.captionTracks[0].isLocked = true
        let b = t.captionTracks[0].items[0].id
        #expect(throws: EditError.trackLocked) { try t.deleteCaption(b) }
        #expect(throws: EditError.trackLocked) { try t.moveCaption(b, to: s(5)) }
        #expect(throws: EditError.trackLocked) { try t.replaceCaptions([], track: id) }
    }

    @Test func captionsAtTime() throws {
        var t = try base()
        let a = try t.replaceCaptions([cap("a", 1, 3), cap("b", 3, 5)])
        var second = CaptionTrack(name: "C2")
        try second.replaceAll([cap("x", 2, 4)])
        t.captionTracks.append(second)
        #expect(t.captions(at: s(0)).isEmpty)
        #expect(t.captions(at: s(1)).map(\.item.text) == ["a"])
        #expect(t.captions(at: s(3)).map(\.item.text) == ["b", "x"])     // half-open, bottom track first
        #expect(t.captions(at: s(3))[0].track == a)
        #expect(t.captions(at: s(5)).isEmpty)
        t.captionTracks[1].isVisible = false
        #expect(t.captions(at: s(3)).map(\.item.text) == ["b"])
    }

    // MARK: Ripple

    @Test func rippleDeleteClosesCaptions() throws {
        let a = clip(0, 4), b = clip(4, 4), c = clip(8, 4)
        var t = try base(clips: [a, b, c])
        _ = try t.replaceCaptions([cap("a", 0, 4), cap("b", 4, 8), cap("c", 8, 12)])
        let d = try t.rippleDelete([b.id])
        #expect(d == s(4))
        // b (fully inside the removed span) vanishes, c moves left, a stays.
        #expect(t.captionTracks[0].items.map(\.text) == ["a", "c"])
        #expect(t.captionTracks[0].items.map(\.range.start) == [s(0), s(4)])
    }

    @Test func rippleDeleteShrinksStraddlingCaption() throws {
        let a = clip(0, 4), b = clip(4, 4)
        var t = try base(clips: [a, b])
        _ = try t.replaceCaptions([cap("x", 2, 6), cap("y", 6, 8)])
        try t.rippleDelete([a.id])                       // span 0...4 closed
        // x: 2...6 -> 0...2 ; y: 6...8 -> 2...4
        #expect(t.captionTracks[0].items.map(\.range) == [TimeRange(start: s(0), end: s(2)), TimeRange(start: s(2), end: s(4))])
    }

    @Test func lockedOrUnsyncedCaptionTrackDoesNotShift() throws {
        let a = clip(0, 4), b = clip(4, 4), c = clip(8, 4)
        var t = try base(clips: [a, b, c])
        _ = try t.replaceCaptions([cap("c", 9, 11)])
        t.captionTracks[0].isLocked = true
        try t.rippleDelete([a.id])
        #expect(t.captionTracks[0].items[0].range.start == s(9))
        t.captionTracks[0].isLocked = false
        t.captionTracks[0].syncLock = false
        try t.rippleDelete([t.tracks[0].clips[0].id])
        #expect(t.captionTracks[0].items[0].range.start == s(9))
    }

    @Test func rippleTrimShiftsCaptions() throws {
        let a = clip(0, 4), b = clip(4, 4)
        var t = try base(clips: [a, b])
        _ = try t.replaceCaptions([cap("a", 0, 2), cap("b", 5, 7)])
        try t.rippleTrim(a.id, edge: .tail, by: s(1))               // a longer: later material +1
        #expect(t.captionTracks[0].items.map(\.range.start) == [s(0), s(6)])
        try t.rippleTrim(a.id, edge: .tail, by: s(-2))              // a shorter: later material -2
        #expect(t.captionTracks[0].items.map(\.range.start) == [s(0), s(4)])
    }

    @Test func insertShiftsCaptionsAndStretchesTheOneUnderneath() throws {
        let a = clip(0, 4), b = clip(4, 4)
        var t = try base(clips: [a, b])
        _ = try t.replaceCaptions([cap("under", 3, 5), cap("later", 6, 7)])
        try t.insert([(clip: clip(0, 2), track: t.tracks[0].id)], at: s(4))
        #expect(t.captionTracks[0].items.map(\.range) == [TimeRange(start: s(3), end: s(7)), TimeRange(start: s(8), end: s(9))])
    }

    @Test func extractClosesCaptionsToo() throws {
        let a = clip(0, 10)
        var t = try base(clips: [a])
        _ = try t.replaceCaptions([cap("a", 1, 2), cap("mid", 4, 5), cap("b", 8, 9)])
        let closed = try t.extract(TimeRange(start: s(3), end: s(6)), tracks: [t.tracks[0].id])
        #expect(closed == s(3))
        #expect(t.captionTracks[0].items.map(\.text) == ["a", "b"])
        #expect(t.captionTracks[0].items.map(\.range.start) == [s(1), s(5)])
    }

    @Test func rippleKeepsCaptionsNonOverlapping() throws {
        let a = clip(0, 10)
        var t = try base(clips: [a])
        _ = try t.replaceCaptions([cap("1", 0, 3), cap("2", 3, 6), cap("3", 6, 9)])
        try t.extract(TimeRange(start: s(2), end: s(7)), tracks: [t.tracks[0].id])
        let items = t.captionTracks[0].items
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.range.end <= $1.range.start })
        #expect(items.map(\.range) == [TimeRange(start: s(0), end: s(2)), TimeRange(start: s(2), end: s(4))])
    }

    @Test func captionTracksSurviveCodable() throws {
        var t = try base()
        _ = try t.replaceCaptions([cap("a", 0, 2)])
        let p = Project(name: "P", timelines: [t])
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        #expect(back == p)
        #expect(back.timelines[0].captionTracks[0].items[0].styleRef == "style")
    }
}
