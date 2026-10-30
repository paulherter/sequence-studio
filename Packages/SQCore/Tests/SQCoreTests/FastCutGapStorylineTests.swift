import Foundation
import Testing
@testable import SQCore

// Fast Cut remaining Final Cut differences: gap items (a hole on V1 is a host for the clips attached in it), connected
// storylines (derived runs of touching attached clips), the Position move.
// Fixtures use 30 fps; times are given in seconds.

private func s(_ x: Double) -> Time { Time(Int64((x * 30).rounded()), 30) }
private func d(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

private func clip(_ id: UUID = UUID(), _ kind: TrackKind = .video, _ start: Double, _ len: Double,
                  attach: (UUID, Double)? = nil, link: UUID? = nil) -> Clip {
    var c = Clip(id: id, name: "x", media: UUID(), kind: kind, source: TimeRange(start: s(10), duration: s(len)),
                 start: s(start), link: link, mediaDuration: s(100))
    if let attach { c.attachment = ClipAttachment(host: attach.0, point: s(attach.1)) }
    return c
}

private func start(_ tl: Timeline, _ id: Clip.ID) -> Double? { tl.find(id).map { d($0.clip.start) } }
private func trackIndex(_ tl: Timeline, _ id: Clip.ID) -> Int? { tl.find(id)?.track }

@Suite struct FastCutGapItemTests {
    // V1: c1 0-4 | hole 4-6 | c2 6-10;  V2: inGap 4.5-5.5 (attach time in the hole), inside 1-2 (on c1)
    private struct F {
        var tl: Timeline
        let c1 = UUID(), c2 = UUID(), inGap = UUID(), inside = UUID()
        init() {
            let v1 = Track(kind: .video, clips: [clip(c1, .video, 0, 4), clip(c2, .video, 6, 4)])
            let v2 = Track(kind: .video, clips: [clip(inside, .video, 1, 1, attach: (c1, 0)), clip(inGap, .video, 4.5, 1, attach: (c1, 0))])
            tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [v1, v2])
            tl.editMode = .magnetic
        }
    }

    @Test func mainGapsListTheHoleWithItsAttachedClips() {
        let f = F()
        let gaps = f.tl.mainGaps()
        #expect(gaps.count == 1)
        #expect(gaps[0].range == TimeRange(start: s(4), end: s(6)))
        #expect(gaps[0].before == f.c1)
        #expect(gaps[0].after == f.c2)
        #expect(gaps[0].attached == [f.inGap])
        #expect(f.tl.isGapAttached(f.inGap))
        #expect(!f.tl.isGapAttached(f.inside))
    }

    @Test func normalSequenceHasNoGapItems() {
        var f = F()
        f.tl.editMode = .normal
        #expect(f.tl.mainGaps().isEmpty)
    }

    @Test func deletingTheClipBeforeAGapKeepsTheClipsAttachedToTheGap() throws {
        var f = F()
        try f.tl.magneticDelete([f.c1])
        #expect(f.tl.find(f.inside) == nil)                       // attached to the clip itself: goes with it
        let kept = try #require(start(f.tl, f.inGap))             // attached to the gap: stays in it
        let c2 = try #require(start(f.tl, f.c2))
        #expect(c2 - kept == 1.5)                                 // same distance before c2 as before
        #expect(f.tl.isAttachmentValid(f.inGap))
        #expect(f.tl.mainGaps().first?.attached == [f.inGap])
    }

    @Test func normalDeleteStaysALift() throws {
        var f = F()
        f.tl.editMode = .normal
        try f.tl.magneticDelete([f.c1])
        #expect(start(f.tl, f.inGap) == 4.5)
        #expect(start(f.tl, f.c2) == 6)
    }

    @Test func deletingTheGapDeletesItsClips() throws {
        var f = F()
        _ = try f.tl.deleteSpacer(at: s(5))
        #expect(f.tl.find(f.inGap) == nil)
        #expect(f.tl.find(f.inside) != nil)
    }
}

@Suite struct FastCutStorylineTests {
    // V1: c1 0-4, c2 4-8, c3 8-12.  V2: s1 5-6, s2 6-8, s3 8-9 (one run), s4 10-11 (apart).  V3: u 6.5-7.5 (lone).
    private struct F {
        var tl: Timeline
        let c1 = UUID(), c2 = UUID(), c3 = UUID(), s1 = UUID(), s2 = UUID(), s3 = UUID(), s4 = UUID(), u = UUID()
        init() {
            let v1 = Track(kind: .video, clips: [clip(c1, .video, 0, 4), clip(c2, .video, 4, 4), clip(c3, .video, 8, 4)])
            let v2 = Track(kind: .video, clips: [clip(s1, .video, 5, 1), clip(s2, .video, 6, 2), clip(s3, .video, 8, 1),
                                                 clip(s4, .video, 10, 1)])
            let v3 = Track(kind: .video, clips: [clip(u, .video, 6.5, 1)])
            tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [v1, v2, v3])
            tl.editMode = .magnetic
            tl.deriveAttachments()
        }
    }

    @Test func aRunOfTouchingAttachedClipsIsAStoryline() {
        let f = F()
        let lines = f.tl.storylines()
        #expect(lines.count == 1)
        #expect(lines[0].clips == [f.s1, f.s2, f.s3])
        #expect(lines[0].range == TimeRange(start: s(5), end: s(9)))
        #expect(f.tl.storyline(containing: f.s2)?.clips.count == 3)
        #expect(f.tl.storyline(containing: f.s4) == nil)
        #expect(f.tl.storyline(containing: f.c1) == nil)
    }

    @Test func rippleDeleteClosesTheStorylineOnly() throws {
        var f = F()
        try f.tl.storylineRippleDelete(f.s2)
        #expect(f.tl.find(f.s2) == nil)
        #expect(start(f.tl, f.s1) == 5)
        #expect(start(f.tl, f.s3) == 6)
        #expect(start(f.tl, f.s4) == 10)                          // apart from the run: not moved
        #expect(start(f.tl, f.c2) == 4)                           // main track untouched
        #expect(f.tl.isAttachmentValid(f.s3))
    }

    @Test func rearrangeReordersInsideTheStoryline() throws {
        var f = F()
        try f.tl.storylineRearrange(f.s3, to: s(5))
        #expect(start(f.tl, f.s3) == 5)
        #expect(start(f.tl, f.s1) == 6)
        #expect(start(f.tl, f.s2) == 7)
        let ok = f.tl.tracks.allSatisfy { $0.isConsistent }
        #expect(ok)
        #expect(f.tl.storyline(containing: f.s1)?.range == TimeRange(start: s(5), end: s(9)))
    }

    @Test func createGathersTouchingClipsOnOneLane() throws {
        var f = F()
        try f.tl.createStoryline([f.s4, f.u].reduce(into: Set<Clip.ID>()) { $0.insert($1) })
        #expect(trackIndex(f.tl, f.s4) == trackIndex(f.tl, f.u))
        let ok = f.tl.tracks.allSatisfy { $0.isConsistent }
        #expect(ok)
    }

    @Test func createTouchingPairIsOneStoryline() throws {
        var f = F()
        f.tl.tracks[2] = Track(kind: .video, clips: [clip(f.u, .video, 9, 1)])   // u 9-10 touches s3 and s4
        f.tl.deriveAttachments()
        try f.tl.createStoryline([f.u, f.s1])
        #expect(trackIndex(f.tl, f.u) == trackIndex(f.tl, f.s1))
        #expect(f.tl.storyline(containing: f.u) != nil)
    }

    @Test func createNeedsTwoAttachedClipsAndFastCut() {
        var f = F()
        #expect(throws: EditError.self) { try f.tl.createStoryline([f.s1]) }
        #expect(throws: EditError.self) { try f.tl.createStoryline([f.s1, f.c1]) }
        f.tl.editMode = .normal
        #expect(throws: EditError.self) { try f.tl.storylineRippleDelete(f.s2) }
        #expect(f.tl.storylines().isEmpty)
    }
}

@Suite struct FastCutPositionMoveTests {
    // V1: c1 0-4, c2 4-8, c3 8-12; V2: x 5-6 attached to c2.
    private struct F {
        var tl: Timeline
        let c1 = UUID(), c2 = UUID(), c3 = UUID(), x = UUID()
        init() {
            let v1 = Track(kind: .video, clips: [clip(c1, .video, 0, 4), clip(c2, .video, 4, 4), clip(c3, .video, 8, 4)])
            let v2 = Track(kind: .video, clips: [clip(x, .video, 5, 1, attach: (c2, 1))])
            tl = Timeline(name: "S", frameDuration: Time(1, 30), tracks: [v1, v2])
            tl.editMode = .magnetic
        }
    }

    @Test func positionMoveOverwritesAndLeavesAHole() throws {
        var f = F()
        try f.tl.positionMove(f.c1, to: s(8))                     // onto c3
        #expect(start(f.tl, f.c1) == 8)
        #expect(f.tl.find(f.c3) == nil)                           // c3 covered
        #expect(start(f.tl, f.c2) == 4)                           // nothing rippled
        #expect(f.tl.mainGaps().first?.range == TimeRange(start: s(0), end: s(4)))
        #expect(start(f.tl, f.x) == 5)                            // attached clips stay
    }

    @Test func positionMoveClampsAtTheMainTrackEnd() throws {
        var f = F()
        try f.tl.positionMove(f.c1, to: s(40))
        #expect(start(f.tl, f.c1) == 12)                          // after c3, never a hole behind the last clip
    }

    @Test func normalPositionMoveIsPlainMove() throws {
        var f = F()
        f.tl.editMode = .normal
        try f.tl.positionMove(f.c1, to: s(40))
        #expect(start(f.tl, f.c1) == 40)
    }
}
