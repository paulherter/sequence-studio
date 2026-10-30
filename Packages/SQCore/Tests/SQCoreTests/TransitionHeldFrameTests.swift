import Foundation
import Testing
@testable import SQCore

// Q-TRN1 rec 1 + Premiere parity fix 8: a video transition at a cut is never refused for missing media beyond the cut. A
// side with no media there holds its edge frame (derived when the transition resolves, nothing stored) and is marked
// (isClamped drives the red tick, heldBefore / heldAfter the hatch). A centered apply with media on one side only moves to
// that side (End / Start at Cut) when the handle holds it whole. Audio never holds.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func clip(_ name: String, start: Int64, from: Int64, frames: Int64 = 60, media: Int64 = 300, kind: TrackKind = .video) -> Clip {
    Clip(name: name, media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: f(frames)), start: f(start), mediaDuration: f(media))
}
private func pair(_ a: Clip, _ b: Clip, kind: TrackKind = .video) throws -> (Timeline, Clip, Clip) {
    var t = Track(kind: kind)
    try t.overwrite(a); try t.overwrite(b)
    return (Timeline(name: "t", frameDuration: fd, tracks: [t]), a, b)
}

@Suite struct TransitionHeldFrameTests {
    /// A centered transition as an older project stores it (no apply-time alignment pick): appended directly.
    private func stored(_ t: inout Timeline, _ a: Clip, _ b: Clip, frames: Int64) {
        t.tracks[0].transitions.append(Transition(kind: .crossDissolve, duration: f(frames), outgoing: a.id, incoming: b.id))
    }

    @Test func storedCentredTransitionWithNoOutgoingTailStillHoldsAfterTheCut() throws {
        // A ends exactly at the end of its media (no tail); B has 30 frames of head handle. Old projects: unchanged.
        var (t, a, b) = try pair(clip("A", start: 0, from: 240), clip("B", start: 60, from: 30))
        stored(&t, a, b, frames: 20)
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.alignment == .center && r.span == TimeRange(start: f(50), duration: f(20)))
        #expect(r.heldFrames == 10 && r.heldAfter == 10 && r.heldBefore == 0 && r.isHeld && r.isClamped)
    }

    @Test func storedCentredTransitionWithNoIncomingHeadStillHoldsBeforeTheCut() throws {
        var (t, a, b) = try pair(clip("A", start: 0, from: 30), clip("B", start: 60, from: 0))
        stored(&t, a, b, frames: 20)
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.span == TimeRange(start: f(50), duration: f(20)) && r.heldFrames == 10 && r.heldBefore == 10 && r.isClamped)
    }

    @Test func centredApplyWithNoOutgoingTailEndsAtTheCut() throws {
        // Premiere: media only on the incoming side, so the whole transition sits before the cut on B's head handle.
        var (t, a, b) = try pair(clip("A", start: 0, from: 240), clip("B", start: 60, from: 30))
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.alignment == .endAtCut && r.span == TimeRange(start: f(40), duration: f(20)) && !r.isHeld && !r.isClamped)
    }

    @Test func centredApplyWithNoIncomingHeadStartsAtTheCut() throws {
        var (t, a, b) = try pair(clip("A", start: 0, from: 30), clip("B", start: 60, from: 0))
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.alignment == .startAtCut && r.span == TimeRange(start: f(60), duration: f(20)) && !r.isHeld)
    }

    @Test func oneSidedHandleTooShortForTheMoveFallsBackToTheCentredHold() throws {
        // A no tail, B only 5 frames of head: End at Cut would give 5 frames, so it stays centered (before = 5 real frames,
        // after = held A) at the length the small handle allows, as before.
        var (t, a, b) = try pair(clip("A", start: 0, from: 240), clip("B", start: 60, from: 5))
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.alignment == .center && r.span == TimeRange(start: f(55), duration: f(11)) && r.heldAfter == 6 && r.heldBefore == 0)
    }

    @Test func realHandlesAreNotMarked() throws {
        var (t, a, b) = try pair(clip("A", start: 0, from: 30), clip("B", start: 60, from: 30))
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.alignment == .center && r.heldFrames == 0 && !r.isHeld && !r.isClamped)
    }

    @Test func smallButNonZeroHandleStillClamps() throws {
        var (t, a, b) = try pair(clip("A", start: 0, from: 30), clip("B", start: 60, from: 5))
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(30))
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.heldFrames == 0 && r.span.duration == f(11))
    }

    @Test func bothSidesEmptyHoldBothEdgeFrames() throws {
        // Whole clips end to end (phone clips): no media beyond the cut on either side. Applied at the full length,
        // centered; B holds its first frame before the cut, A its last frame after it.
        var (t, a, b) = try pair(clip("A", start: 0, from: 240), clip("B", start: 60, from: 0))
        let tid = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tid, outgoing: a.id, incoming: b.id, duration: f(20))
        let r = try #require(t.resolvedTransitions(on: tid).first)
        #expect(r.alignment == .center && r.span == TimeRange(start: f(50), duration: f(20)) && r.span.duration == r.requestedDuration)
        #expect(r.heldBefore == 10 && r.heldAfter == 10 && r.heldFrames == 20 && r.isClamped)
        let early = t.videoLayers(at: f(55))
        #expect(early.count == 2 && early[0].sourceTime == f(295) && early[1].sourceTime == .zero)   // B frozen on frame 0
        let late = t.videoLayers(at: f(65))
        #expect(late.count == 2 && late[0].sourceTime == f(299) && late[1].sourceTime == f(5))       // A frozen on frame 299
        #expect(t.maxTransitionFrames(r.id) == 120)                                                  // only the clips bound it
    }

    @Test func bothSidesEmptyHonourExplicitAlignments() throws {
        var (t, a, b) = try pair(clip("A", start: 0, from: 240), clip("B", start: 60, from: 0))
        let tid = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tid, outgoing: a.id, incoming: b.id, duration: f(12), alignment: .startAtCut)
        var r = try #require(t.resolvedTransitions(on: tid).first)
        #expect(r.span == TimeRange(start: f(60), duration: f(12)) && r.heldAfter == 12 && r.heldBefore == 0)
        try t.addTransition(kind: .crossDissolve, track: tid, outgoing: a.id, incoming: b.id, duration: f(12), alignment: .endAtCut)
        r = try #require(t.resolvedTransitions(on: tid).first)
        #expect(r.span == TimeRange(start: f(48), duration: f(12)) && r.heldBefore == 12 && r.heldAfter == 0)
    }

    @Test func clipsShorterThanTheTransitionBoundItEvenWhenHeld() throws {
        // 10-frame whole clips, 30 frames asked: the transition spans both clips entirely (20 frames), no more.
        var (t, a, b) = try pair(clip("A", start: 0, from: 290, frames: 10), clip("B", start: 10, from: 0, frames: 10))
        let tid = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tid, outgoing: a.id, incoming: b.id, duration: f(30))
        let r = try #require(t.resolvedTransitions(on: tid).first)
        #expect(r.span == TimeRange(start: .zero, duration: f(20)) && r.heldBefore == 10 && r.heldAfter == 10)
    }

    @Test func applyAtEveryCutOfWholeClipsSucceeds() throws {
        // Cmd+D over four whole clips placed end to end: every cut gets its full-length transition.
        var track = Track(kind: .video)
        let cs = (0..<4).map { clip("C\($0)", start: Int64($0) * 60, from: 0, frames: 60, media: 60) }
        for c in cs { try track.overwrite(c) }
        var t = Timeline(name: "t", frameDuration: fd, tracks: [track])
        for i in 0..<3 {
            try t.addTransition(point: .cut(outgoing: cs[i].id, incoming: cs[i + 1].id), kind: .crossDissolve,
                                track: t.tracks[0].id, duration: f(30))
        }
        let rs = t.resolvedTransitions(on: t.tracks[0].id)
        #expect(rs.count == 3 && rs.allSatisfy { $0.span.duration == f(30) && $0.heldFrames == 30 })
    }

    @Test func trimmingBothHandlesAwayKeepsTheTransition() throws {
        // Real handles at apply; a later edit uses them up: the transition stays and holds instead of being pruned.
        var (t, a, b) = try pair(clip("A", start: 0, from: 220, media: 290), clip("B", start: 60, from: 10))
        let tid = t.tracks[0].id
        try t.addTransition(kind: .crossDissolve, track: tid, outgoing: a.id, incoming: b.id, duration: f(10))
        _ = try t.slip(a.id, by: f(10))     // A now reaches its media end
        _ = try t.slip(b.id, by: f(-10))    // B now starts at its media start
        #expect(t.tracks[0].clips[0].source.end == f(290) && t.tracks[0].clips[1].source.start == .zero)
        t.pruneTransitions()
        let r = try #require(t.resolvedTransitions(on: tid).first)
        #expect(r.span.duration == f(10) && r.heldBefore == 5 && r.heldAfter == 5)
    }

    @Test func audioTransitionsNeverHold() throws {
        var (t, a, b) = try pair(clip("A", start: 0, from: 240, kind: .audio), clip("B", start: 60, from: 30, kind: .audio), kind: .audio)
        #expect(throws: EditError.insufficientMedia) {
            try t.addTransition(kind: .constantPower, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        }
        var (u, c, d) = try pair(clip("A", start: 0, from: 240, kind: .audio), clip("B", start: 60, from: 0, kind: .audio), kind: .audio)
        #expect(throws: EditError.insufficientMedia) {
            try u.addTransition(kind: .constantPower, track: u.tracks[0].id, outgoing: c.id, incoming: d.id, duration: f(20))
        }
    }

    @Test func startAtCutWithNoTailHoldsTheWholeSpan() throws {
        var (t, a, b) = try pair(clip("A", start: 0, from: 240), clip("B", start: 60, from: 30))
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(12), alignment: .startAtCut)
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.span == TimeRange(start: f(60), duration: f(12)) && r.heldFrames == 12 && r.heldAfter == 12)
    }

    @Test func sourceTimeOutsideTheClipHoldsTheMediaEdges() {
        let a = clip("A", start: 0, from: 240)                       // media 300 frames, plays 240..300
        #expect(a.sourceTime(at: f(70), frameDuration: fd) == f(299))   // past the end: last frame
        #expect(a.sourceTime(at: f(50), frameDuration: fd) == f(290))   // inside: unchanged
        let b = clip("B", start: 60, from: 0)
        #expect(b.sourceTime(at: f(50), frameDuration: fd) == .zero)    // before the start: first frame
    }

    @Test func heldFrameIsTheClipsOwnEdgeFrameAt200Percent() throws {
        // A plays source 180..300 at 200 %: 60 timeline frames, last frame shows source 298 (not the media's 299).
        let a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: f(180), duration: f(120)), start: .zero,
                     mediaDuration: f(300), speed: ClipSpeed(percent: 200))
        #expect(a.duration == f(60) && a.tailRoom == .zero)
        #expect(a.sourceTime(at: f(59), frameDuration: fd) == f(298))
        #expect(a.sourceTime(at: f(65), frameDuration: fd) == f(298))
        #expect(a.sourceTime(at: f(60), frameDuration: fd) == f(298))
    }

    @Test func heldFrameIsTheClipsOwnEdgeFrameWithSpeedKeys() throws {
        var a = clip("A", start: 0, from: 180, frames: 120)
        a.setSpeedKeys(SpeedKeys(constant: ClipSpeed(percent: 200), reversed: false, duration: f(60), origin: f(180)))
        a.mediaDuration = a.source.end
        let tail = try #require(a.tailRoom)
        #expect(tail.frameIndex(frameDuration: fd) == 0)
        let last = a.sourceTime(at: a.timeline.end - fd, frameDuration: fd)
        #expect(a.sourceTime(at: a.timeline.end + f(5), frameDuration: fd) == last)
        #expect(a.sourceTime(at: a.timeline.end, frameDuration: fd) == last)
    }

    @Test func reversedOutgoingWithoutTailHoldsItsLastFrame() throws {
        // Reversed A plays source 0..60 backwards: its tail is the media start, so after the cut it holds source 0.
        let a = Clip(name: "A", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero,
                     mediaDuration: f(300), reversed: true)
        let b = clip("B", start: 60, from: 30)
        var (t, _, _) = try pair(a, b)
        t.tracks[0].transitions = [Transition(kind: .crossDissolve, duration: f(20), outgoing: a.id, incoming: b.id)]
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.heldAfter == 10)
        let last = a.sourceTime(at: f(59), frameDuration: fd)
        #expect(t.videoLayers(at: f(65))[0].sourceTime == last && a.sourceTime(at: f(69), frameDuration: fd) == last)
    }

    @Test func bothSidesHeldAroundAShortMiddleClipShareItsFrames() throws {
        // A | M (10 frames, whole media) | B, all whole clips. M's frames are budgeted between its two transitions: the
        // first takes all 10 after its cut, the second gets what is left (1 frame, M's last frame held) and never overlaps.
        var track = Track(kind: .video)
        let a = clip("A", start: 0, from: 240), m = clip("M", start: 60, from: 0, frames: 10, media: 10)
        let b = clip("B", start: 70, from: 0)
        for c in [a, m, b] { try track.overwrite(c) }
        var t = Timeline(name: "t", frameDuration: fd, tracks: [track])
        let tid = t.tracks[0].id
        let first = try t.addTransition(point: .cut(outgoing: a.id, incoming: m.id), kind: .crossDissolve, track: tid, duration: f(20))
        let second = try t.addTransition(point: .cut(outgoing: m.id, incoming: b.id), kind: .crossDissolve, track: tid, duration: f(20))
        let rs = t.resolvedTransitions(on: tid)
        let r1 = try #require(rs.first { $0.id == first }), r2 = try #require(rs.first { $0.id == second })
        #expect(r1.span == TimeRange(start: f(50), duration: f(20)) && r1.heldBefore == 10 && r1.heldAfter == 10)
        #expect(r1.span.end <= r2.span.start && r2.before == .zero && r2.heldAfter == r2.after.frameIndex(frameDuration: fd))
        #expect(r1.after + r2.before <= m.duration)
    }

    @Test func subFrameHandleCountsAsNoHandle() throws {
        // B starts half a frame into its media: less than one whole frame of head handle, so it holds like zero.
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: Time(1, 60), duration: f(60)), start: f(60),
                     mediaDuration: f(300))
        var (t, a, _) = try pair(clip("A", start: 0, from: 240), b)
        try t.addTransition(kind: .crossDissolve, track: t.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        let r = try #require(t.resolvedTransitions(on: t.tracks[0].id).first)
        #expect(r.span == TimeRange(start: f(50), duration: f(20)) && r.heldBefore == 10 && r.heldAfter == 10)
        #expect(t.videoLayers(at: f(55))[1].sourceTime == Time(1, 60))   // B's own first frame, not media frame 0
    }

    @Test func reversedClipBeforeItsStartHoldsInsideTheMedia() {
        // Reversed B plays source 240..300 backwards: its head is the media end, so a held head reads the last frame.
        let b = Clip(name: "B", media: UUID(), kind: .video, source: TimeRange(start: f(240), duration: f(60)), start: f(60),
                     mediaDuration: f(300), reversed: true)
        #expect(b.sourceTime(at: f(60), frameDuration: fd) == f(299))
        #expect(b.sourceTime(at: f(50), frameDuration: fd) == f(299))   // before the start: stays on the last frame
    }
}
