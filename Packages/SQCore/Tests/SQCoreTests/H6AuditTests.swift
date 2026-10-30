import Foundation
import Testing
@testable import SQCore

// H6 core audit (docs/research/H6-core-audit.md), items 1, 2, 5, 6.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func clip(start: Int64 = 0, from: Int64 = 0, frames: Int64, media: Int64? = 3000, kind: TrackKind = .video,
                  link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         link: link, mediaDuration: media.map(f))
}
private func track(_ clips: [Clip], kind: TrackKind = .video) throws -> Track {
    var t = Track(kind: kind)
    for c in clips { try t.overwrite(c) }
    return t
}
private func timeline(_ tracks: Track...) -> Timeline { Timeline(name: "t", frameDuration: fd, tracks: tracks) }

@Suite struct H6SpeedPartnerTests {
    /// V [0,10f) linked to A [0,12f): each member keeps its own source range at the new speed.
    @Test func setSpeedKeepsPartnerSourceRange() throws {
        let l = UUID()
        var tl = timeline(try track([clip(frames: 10, link: l)]), try track([clip(frames: 12, kind: .audio, link: l)], kind: .audio))
        try tl.setSpeed(tl.tracks[0].clips[0].id, to: ClipSpeed(percent: 50))
        let v = tl.tracks[0].clips[0], a = tl.tracks[1].clips[0]
        #expect(v.duration == f(20) && v.source.duration == f(10))
        #expect(a.duration == f(24) && a.source.duration == f(12))
    }

    @Test func setSpeedRippleShiftsByTheLongestPartner() throws {
        let l = UUID()
        var tl = timeline(try track([clip(frames: 10, link: l), clip(start: 10, frames: 10)]),
                          try track([clip(frames: 12, kind: .audio, link: l), clip(start: 12, frames: 10, kind: .audio)], kind: .audio))
        try tl.setSpeed(tl.tracks[0].clips[0].id, to: ClipSpeed(percent: 50), ripple: true)
        #expect(tl.tracks[1].clips[0].duration == f(24))
        #expect(tl.tracks[1].clips[1].start >= f(24))                       // no overlap on the partner's track
        #expect(tl.tracks[0].clips[1].start - f(10) == tl.tracks[1].clips[1].start - f(12))   // trailing clips keep sync
    }

    @Test func rateStretchKeepsPartnerSourceRange() throws {
        let l = UUID()
        var tl = timeline(try track([clip(frames: 10, link: l)]), try track([clip(frames: 12, kind: .audio, link: l)], kind: .audio))
        let applied = try tl.rateStretch(tl.tracks[0].clips[0].id, edge: .tail, by: f(10))
        let v = tl.tracks[0].clips[0], a = tl.tracks[1].clips[0]
        #expect(applied == f(10) && v.duration == f(20) && v.source.duration == f(10))
        #expect(a.duration == f(24) && a.source.duration == f(12) && a.speed == v.speed)
    }

    @Test func rateStretchStopsWhenThePartnerHitsItsNeighbour() throws {
        let l = UUID()
        var tl = timeline(try track([clip(frames: 10, link: l)]),
                          try track([clip(frames: 12, kind: .audio, link: l), clip(start: 18, frames: 5, kind: .audio)], kind: .audio))
        try tl.rateStretch(tl.tracks[0].clips[0].id, edge: .tail, by: f(10))
        let v = tl.tracks[0].clips[0], a = tl.tracks[1].clips[0]
        #expect(a.timeline.end <= f(18) && a.source.duration == f(12))      // partner fills its room, source kept
        #expect(v.source.duration == f(10) && v.speed == a.speed)
        let consistent = tl.tracks.allSatisfy { $0.isConsistent }
        #expect(consistent)
    }
}

@Suite struct H6NestTransitionTests {
    @Test func nestCarriesTransitions() throws {
        let a = clip(start: 0, from: 30, frames: 30, media: nil), b = clip(start: 30, from: 30, frames: 30, media: nil)
        var t = try track([a, b])
        t.transitions = [Transition(kind: .crossDissolve, duration: f(10), outgoing: a.id, incoming: b.id),
                         Transition(kind: .crossDissolve, duration: f(10), outgoing: nil, incoming: a.id)]
        let outer = timeline(t)
        var p = Project(name: "P", timelines: [outer])
        let id = try p.nest(clips: [a.id, b.id], in: outer.id)
        let inner = try #require(p.timeline(id))
        #expect(inner.tracks[0].transitions.count == 2)
        #expect(inner.tracks[0].resolvedTransitions(frameDuration: fd).count == 2)
        #expect(p.timeline(outer.id)!.tracks[0].transitions.isEmpty)
    }

    @Test func nestDropsTransitionsToClipsLeftOutside() throws {
        let a = clip(start: 0, from: 30, frames: 30, media: nil), b = clip(start: 30, from: 30, frames: 30, media: nil)
        var t = try track([a, b])
        t.transitions = [Transition(kind: .crossDissolve, duration: f(10), outgoing: a.id, incoming: b.id),
                         Transition(kind: .crossDissolve, duration: f(10), outgoing: nil, incoming: a.id)]
        let outer = timeline(t)
        var p = Project(name: "P", timelines: [outer])
        let id = try p.nest(clips: [a.id], in: outer.id)
        let inner = try #require(p.timeline(id))
        #expect(inner.tracks[0].transitions.map(\.incoming) == [a.id])          // fade-in on A came along
        #expect(p.timeline(outer.id)!.tracks[0].transitions.isEmpty)           // no dangling A/B dissolve
    }
}

@Suite struct H6ExtendEditTests {
    /// V: L [0,10) B [10,20); A: B's linked audio [10,20) with its own left neighbor. E on B's head moves both.
    @Test func extendHeadMovesLinkedPartner() throws {
        let l = UUID()
        var tl = timeline(try track([clip(start: 0, frames: 10), clip(start: 10, from: 50, frames: 10, link: l)]),
                          try track([clip(start: 0, frames: 10, kind: .audio), clip(start: 10, from: 50, frames: 10, kind: .audio, link: l)],
                                    kind: .audio))
        let b = tl.tracks[0].clips[1].id
        #expect(try tl.extendEdit(b, edge: .head, to: f(7)) == f(-3))
        #expect(tl.tracks[0].clips[1].start == f(7) && tl.tracks[1].clips[1].start == f(7))
        #expect(tl.tracks[0].clips[0].timeline.end == f(7) && tl.tracks[1].clips[0].timeline.end == f(7))
    }

    @Test func extendEditClampsAtNeighbour() throws {
        var tl = timeline(try track([clip(start: 0, frames: 10), clip(start: 10, from: 50, frames: 10)]))
        let a = tl.tracks[0].clips[0].id, b = tl.tracks[0].clips[1].id
        #expect(try tl.extendEdit(a, edge: .tail, to: f(25)) == f(9))          // B keeps one frame
        #expect(tl.tracks[0].clips[1].duration == fd)
        #expect(try tl.extendEdit(b, edge: .head, to: f(-5)) == f(-18))        // A keeps one frame
        #expect(tl.tracks[0].clips[0].duration == fd)
    }
}

@Suite struct H6ReviewFixTests {
    /// B's linked audio B' sits after a gap (no clip ends at the cut): it grows into the gap so it stays in sync.
    @Test func extendHeadGrowsPartnerAfterGap() throws {
        let l = UUID()
        var tl = timeline(try track([clip(start: 0, frames: 10), clip(start: 10, from: 50, frames: 10, link: l)]),
                          try track([clip(start: 10, from: 50, frames: 10, kind: .audio, link: l)], kind: .audio))
        let b = tl.tracks[0].clips[1].id
        #expect(try tl.extendEdit(b, edge: .head, to: f(7)) == f(-3))
        let v = tl.tracks[0].clips[1], a = tl.tracks[1].clips[0]
        #expect(v.start == f(7) && a.start == f(7) && a.source.start == f(47) && a.timeline.end == f(20))
    }

    @Test func extendHeadIsLimitedByThePartnersGap() throws {
        let l = UUID()
        var tl = timeline(try track([clip(start: 0, frames: 10), clip(start: 10, from: 50, frames: 10, link: l)]),
                          try track([clip(start: 0, frames: 8, kind: .audio), clip(start: 10, from: 50, frames: 10, kind: .audio, link: l)],
                                    kind: .audio))
        let b = tl.tracks[0].clips[1].id
        #expect(try tl.extendEdit(b, edge: .head, to: f(5)) == f(-2))
        #expect(tl.tracks[0].clips[1].start == f(8) && tl.tracks[1].clips[1].start == f(8))
    }

    /// The partner of the left clip ends at the cut with nothing after it: its tail follows.
    @Test func extendTailMovesPartnerBeforeGap() throws {
        let l = UUID()
        var tl = timeline(try track([clip(start: 0, frames: 10, link: l), clip(start: 10, from: 50, frames: 10)]),
                          try track([clip(start: 0, frames: 10, kind: .audio, link: l)], kind: .audio))
        let a = tl.tracks[0].clips[0].id
        #expect(try tl.extendEdit(a, edge: .tail, to: f(14)) == f(4))
        #expect(tl.tracks[1].clips[0].timeline.end == f(14))
        #expect(try tl.extendEdit(a, edge: .tail, to: f(11)) == f(-3))
        #expect(tl.tracks[1].clips[0].timeline.end == f(11))
    }

    /// A clip shorter than one frame never makes the roll run the other way.
    @Test func clampNeverReversesTheRoll() throws {
        let half = Time(1, 60)
        let left = Clip(name: "l", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: half), start: .zero)
        let right = Clip(name: "r", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(10)), start: half)
        var tl = timeline(try track([left, right]))
        #expect(try tl.extendEdit(right.id, edge: .head, to: .zero) == .zero)
        #expect(tl.tracks[0].clips[1].start == half)
    }

    @Test func nestKeepsUnrelatedInactiveTransitions() throws {
        // A/B is nested; C/D (a gap between them: the transition's cut is gone, it cannot resolve) is not touched.
        // (No handles no longer makes a video transition inactive: it holds the edge frames, parity fix 8.)
        let a = clip(start: 0, from: 30, frames: 30, media: nil), b = clip(start: 30, from: 30, frames: 30, media: nil)
        let c = clip(start: 100, from: 0, frames: 30, media: 30), d = clip(start: 131, from: 0, frames: 30, media: 30)
        var t = try track([a, b, c, d])
        let inactive = Transition(kind: .crossDissolve, duration: f(10), outgoing: c.id, incoming: d.id)
        t.transitions = [Transition(kind: .crossDissolve, duration: f(10), outgoing: a.id, incoming: b.id), inactive]
        #expect(t.resolvedTransitions(frameDuration: fd).count == 1)
        let outer = timeline(t)
        var p = Project(name: "P", timelines: [outer])
        let id = try p.nest(clips: [a.id, b.id], in: outer.id)
        #expect(p.timeline(outer.id)!.tracks[0].transitions == [inactive])
        #expect(p.timeline(id)!.tracks[0].transitions.count == 1)
    }
}
