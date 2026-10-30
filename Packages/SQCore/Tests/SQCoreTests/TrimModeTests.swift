import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }

private func clip(_ name: String, start: Int64, from: Int64 = 30, frames: Int64 = 60) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         mediaDuration: f(300))
}

/// A 0..60, B 60..120, C 150..210 (gap 120..150) on one track; 30 frames of handle on each side of every clip.
private func make() throws -> (Timeline, Clip, Clip, Clip) {
    let a = clip("A", start: 0), b = clip("B", start: 60), c = clip("C", start: 150)
    var tr = Track(kind: .video)
    try tr.overwrite(a); try tr.overwrite(b); try tr.overwrite(c)
    return (Timeline(name: "t", frameDuration: fd, tracks: [tr]), a, b, c)
}

@Suite struct TrimModeTests {
    @Test func nearestPointPrefersTheCutAndKnowsLoneEdges() throws {
        let (t, a, b, c) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(58)))
        #expect(p.outgoing == a.id && p.incoming == b.id && p.time == f(60))
        let q = try #require(t.nearestTrimPoint(to: f(125)))        // B's tail beside a gap
        #expect(q.outgoing == b.id && q.incoming == nil && q.time == f(120))
        let r = try #require(t.nearestTrimPoint(to: f(148)))
        #expect(r.outgoing == nil && r.incoming == c.id)
    }

    @Test func zeroIsNotAnEditPoint() throws {
        let (t, _, _, _) = try make()
        #expect(t.nearestTrimPoint(to: f(1))?.time == f(60))
    }

    @Test func lockedTracksAreSkipped() throws {
        var (t, _, _, _) = try make()
        t.tracks[0].isLocked = true
        #expect(t.nearestTrimPoint(to: f(60)) == nil)
    }

    @Test func rollKeepsTheLengthAndMovesTheCut() throws {
        var (t, a, b, _) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        let moved = try t.trimEdit(p, side: .roll, by: f(5))
        #expect(moved == f(5))
        #expect(t.find(a.id)?.clip.timeline.end == f(65) && t.find(b.id)?.clip.start == f(65))
        #expect(t.find(b.id)?.clip.timeline.end == f(120))
        #expect(t.resolved(p)?.time == f(65))
    }

    @Test func rippleOutgoingShiftsEverythingAfter() throws {
        var (t, a, b, c) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        let moved = try t.trimEdit(p, side: .outgoing, by: f(-5))
        #expect(moved == f(-5))
        #expect(t.find(a.id)?.clip.timeline.end == f(55) && t.find(b.id)?.clip.start == f(55))
        #expect(t.find(c.id)?.clip.start == f(145))
    }

    @Test func rippleIncomingKeepsItsStartAndShortensTheClip() throws {
        var (t, a, b, c) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        _ = try t.trimEdit(p, side: .incoming, by: f(5))
        #expect(t.find(a.id)?.clip.timeline.end == f(60) && t.find(b.id)?.clip.start == f(60))
        #expect(t.find(b.id)?.clip.duration == f(55) && t.find(b.id)?.clip.source.start == f(35))
        #expect(t.find(c.id)?.clip.start == f(145))
    }

    @Test func handlesClampTheMove() throws {
        var (t, _, _, _) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        let moved = try t.trimEdit(p, side: .roll, by: f(-45))     // B has 30 frames of head handle
        #expect(moved == f(-30))
        #expect(try t.trimEdit(p, side: .roll, by: f(100)) == f(89))   // B (90 frames now) keeps one frame
    }

    @Test func missingSideThrows() throws {
        var (t, _, _, _) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(125)))
        #expect(throws: EditError.self) { try t.trimEdit(p, side: .roll, by: f(1)) }
        #expect(throws: EditError.self) { try t.trimEdit(p, side: .incoming, by: f(1)) }
    }

    @Test func monitorFramesAreLastOutgoingAndFirstIncoming() throws {
        var (t, _, _, _) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        var fr = t.trimFrames(p)
        #expect(fr.outgoing == f(59) && fr.incoming == f(60))
        try t.trimEdit(p, side: .roll, by: f(5))
        fr = t.trimFrames(p)
        #expect(fr.outgoing == f(64) && fr.incoming == f(65))
        let lone = try #require(t.nearestTrimPoint(to: f(125)))
        #expect(t.trimFrames(lone).incoming == nil)
    }

    @Test func sideCycleSkipsMissingSides() throws {
        let (t, _, _, _) = try make()
        let cut = try #require(t.nearestTrimPoint(to: f(60)))
        #expect(TrimSide.outgoing.next(in: cut) == .incoming && TrimSide.incoming.next(in: cut) == .roll
                && TrimSide.roll.next(in: cut) == .outgoing)
        let lone = try #require(t.nearestTrimPoint(to: f(125)))
        #expect(TrimSide.outgoing.next(in: lone) == .outgoing)
        #expect(lone.defaultSide(pointerBefore: false) == .outgoing)
        #expect(cut.defaultSide(pointerBefore: false) == .incoming && cut.defaultSide(pointerBefore: true) == .outgoing)
    }

    @Test func deletedSideDegradesAndTheOtherSideStillTrims() throws {
        var (t, a, b, c) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        t.tracks[0].remove(b.id)
        let r = try #require(t.resolved(p))
        #expect(r.incoming == nil && r.outgoing == a.id && r.time == f(60))
        #expect(try t.trimEdit(p, side: .outgoing, by: f(-5)) == f(-5))
        #expect(t.tracks[0].clips.first { $0.id == c.id }?.start == f(145))
        #expect(throws: EditError.self) { try t.trimEdit(p, side: .roll, by: f(1)) }
    }

    @Test func bothSidesGoneLeavesTheMode() throws {
        var (t, a, b, _) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        t.tracks[0].remove(a.id); t.tracks[0].remove(b.id)
        #expect(t.resolved(p) == nil)
    }

    @Test func clipsThatNoLongerTouchLeaveTheMode() throws {
        var (t, a, _, _) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        try t.trim(a.id, edge: .tail, by: f(-5))           // plain trim leaves a gap
        #expect(t.resolved(p) == nil)
        #expect(throws: EditError.self) { try t.trimEdit(p, side: .roll, by: f(1)) }
    }

    @Test func rollDoesNotJumpToAnotherNeighbour() throws {
        var (t, a, b, c) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        t.tracks[0].remove(b.id)
        try t.rippleTrim(c.id, edge: .head, by: .zero)
        // A now ends at 60, nothing starts there: the roll must refuse instead of rolling A | C.
        #expect(throws: EditError.self) { try t.trimEdit(p, side: .roll, by: f(1)) }
        _ = a
    }

    @Test func fractionalHandlesGiveWholeFrames() throws {
        let a = clip("A", start: 0)
        var b = clip("B", start: 60, from: 30, frames: 70)
        b.speed = ClipSpeed(num: 7, den: 2)                // 20 timeline frames, head handle 8.57 frames
        var tr = Track(kind: .video)
        try tr.overwrite(a); try tr.overwrite(b)
        var t = Timeline(name: "t", frameDuration: fd, tracks: [tr])
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        let moved = try t.trimEdit(p, side: .roll, by: f(-10))
        #expect(moved == f(-8))
        #expect(t.tracks[0].clips[1].start == f(52) && t.tracks[0].clips[1].start.frameIndex(frameDuration: fd) == 52)
    }

    @Test func rippleClampsInsteadOfEmptyingTheClip() throws {
        var (t, a, _, _) = try make()
        let p = try #require(t.nearestTrimPoint(to: f(60)))
        let moved = try t.trimEdit(p, side: .outgoing, by: f(-100))
        #expect(moved == f(-59))
        #expect(t.tracks[0].clips.first { $0.id == a.id }?.duration == f(1))
    }
}
