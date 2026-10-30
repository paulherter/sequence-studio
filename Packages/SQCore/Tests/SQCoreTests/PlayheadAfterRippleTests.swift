import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: s(0), duration: s(dur)), start: s(start))
}
private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}
private func timeline(_ tracks: [Track]) -> Timeline { Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks) }
private func span(_ a: Int64, _ b: Int64) -> TimeRange { TimeRange(start: s(a), end: s(b)) }

/// The playhead keeps its picture when a ripple closes material before it (DECISIONS "Playhead follows ripple").
@Suite struct PlayheadAfterRippleTests {
    // MARK: Pure rule

    @Test func spanBeforeThePlayheadMovesItLeftByTheSpan() {
        #expect(Timeline.playheadAfterRipple(s(10), closing: [span(2, 5)]) == s(7))
    }

    @Test func spanEndingAtThePlayheadMovesItToTheEditPoint() {
        #expect(Timeline.playheadAfterRipple(s(5), closing: [span(2, 5)]) == s(2))
    }

    @Test func playheadInsideTheSpanLandsOnItsStart() {
        #expect(Timeline.playheadAfterRipple(s(3), closing: [span(2, 5)]) == s(2))
        #expect(Timeline.playheadAfterRipple(s(2), closing: [span(2, 5)]) == s(2))
    }

    @Test func spanAfterThePlayheadLeavesIt() {
        #expect(Timeline.playheadAfterRipple(s(1), closing: [span(2, 5)]) == s(1))
    }

    @Test func emptySpanAndNoSpanLeaveIt() {
        #expect(Timeline.playheadAfterRipple(s(4), closing: []) == s(4))
        #expect(Timeline.playheadAfterRipple(s(4), closing: [span(2, 2)]) == s(4))
    }

    /// Spans are applied in the order the edits ran, each in the coordinates the one before left behind.
    @Test func spansAddUpInOrder() {
        #expect(Timeline.playheadAfterRipple(s(10), closing: [span(6, 8), span(1, 3)]) == s(6))
        #expect(Timeline.playheadAfterRipple(s(7), closing: [span(6, 8), span(1, 3)]) == s(4))
    }

    @Test func staysRational() {
        let p = Time(1001, 30000) * 100, sp = TimeRange(start: Time(1001, 30000) * 10, duration: Time(1001, 30000) * 7)
        #expect(Timeline.playheadAfterRipple(p, closing: [sp]) == Time(1001, 30000) * 93)
    }

    // MARK: The playhead riding along with an edit

    @Test func rippleDeleteBeforeThePlayhead() throws {
        let a = clip(0, 2), b = clip(2, 3), c = clip(5, 4), d = clip(9, 2)
        var tl = timeline([track([a, b, c, d])])
        let p = try tl.followingRipple(playhead: s(10)) { try $0.rippleDelete([a.id, c.id]) }
        #expect(tl.tracks[0].clips.last?.start == s(3))
        #expect(p == s(4))                                               // 1 s into d before and after
        #expect(p == Timeline.playheadAfterRipple(s(10), closing: [span(5, 9), span(0, 2)]))
        #expect(tl.markers.isEmpty)                                      // the probe is gone
    }

    @Test func rippleDeleteOfTheClipUnderThePlayheadLandsOnTheEditPoint() throws {
        let a = clip(0, 2), b = clip(2, 3), c = clip(5, 4)
        var tl = timeline([track([a, b, c])])
        #expect(try tl.followingRipple(playhead: s(4)) { try $0.rippleDelete([b.id]) } == s(2))
    }

    @Test func rippleDeleteAfterThePlayheadLeavesIt() throws {
        let a = clip(0, 2), b = clip(2, 3)
        var tl = timeline([track([a, b])])
        #expect(try tl.followingRipple(playhead: s(1)) { try $0.rippleDelete([b.id]) } == s(1))
    }

    @Test func rippleDeleteMovesByWhatActuallyClosed() throws {
        // V1 a [0,2) b [2,4); V2 (sync-locked) has a clip across the cut: the playhead moves by what the edit reports.
        let a = clip(0, 2), b = clip(2, 2)
        var tl = timeline([track([a, b]), track([clip(1, 2)])])
        var closed = Time.zero
        let p = try tl.followingRipple(playhead: s(3)) { closed = try $0.rippleDelete([a.id]) }
        #expect(p == s(3) - closed)
    }

    @Test func refusedEditThrowsAndChangesNothing() {
        var tl = timeline([track([clip(0, 2)])])
        let before = tl
        #expect(throws: EditError.self) { try tl.followingRipple(playhead: s(1)) { try $0.rippleDelete([UUID()]) } }
        #expect(tl == before)
    }

    @Test func closeGapBeforeAndUnderThePlayhead() throws {
        let a = clip(0, 2), b = clip(5, 2)
        let base = timeline([track([a, b])])
        var tl = base
        #expect(try tl.followingRipple(playhead: s(6)) { try $0.closeGap(on: $0.tracks[0].id, at: s(3)) } == s(3))
        tl = base
        #expect(try tl.followingRipple(playhead: s(4)) { try $0.closeGap(on: $0.tracks[0].id, at: s(3)) } == s(2))
        tl = base
        #expect(try tl.followingRipple(playhead: s(1)) { try $0.closeGap(on: $0.tracks[0].id, at: s(3)) } == s(1))
    }

    @Test func extractBeforeThePlayhead() throws {
        var tl = timeline([track([clip(0, 20)])])
        #expect(try tl.followingRipple(playhead: s(10)) { try $0.extract(span(2, 4), tracks: [$0.tracks[0].id]) } == s(8))
    }

    @Test func rippleTrimOfAnEarlierTail() throws {
        let a = clip(0, 4), b = clip(4, 4)
        var tl = timeline([track([a, b])])
        #expect(try tl.followingRipple(playhead: s(6)) { try $0.rippleTrim(a.id, edge: .tail, by: s(-1)) } == s(5))
    }

    /// A head trim keeps the clip start: the picture inside the clip slides left by the cut head.
    @Test func rippleTrimOfAHeadMovesThePictureInsideTheClip() throws {
        let a = clip(0, 4), b = clip(4, 4)
        var tl = timeline([track([a, b])])
        #expect(try tl.followingRipple(playhead: s(6)) { try $0.rippleTrim(b.id, edge: .head, by: s(1)) } == s(5))
        #expect(tl.tracks[0].clips[1].timeline == span(4, 7))
    }

    /// Only closing moves the playhead: material pushed later does not take it along.
    @Test func lengtheningRippleTrimLeavesThePlayhead() throws {
        let a = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(2)), start: s(0))
        var long = a; long.source = TimeRange(start: s(2), duration: s(2))
        var tl = timeline([track([long, clip(2, 2)])])
        #expect(try tl.followingRipple(playhead: s(3)) { try $0.rippleTrim(long.id, edge: .head, by: s(-1)) } == s(3))
        #expect(tl.tracks[0].clips[1].start == s(3))
    }

    @Test func existingMarkersKeepTheirOrderAndFollowAsBefore() throws {
        let a = clip(0, 2), b = clip(2, 20)
        var tl = timeline([track([a, b])])
        tl.markers = [Marker(time: s(1), name: "in"), Marker(time: s(10), name: "later")]
        let p = try tl.followingRipple(playhead: s(10)) { try $0.rippleDelete([a.id]) }
        #expect(p == s(8))
        #expect(tl.markers.map(\.name) == ["in", "later"])
        #expect(tl.markers.map(\.time) == [s(0), s(8)])
    }
}
