import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .audio, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(dur)), start: s(start), link: link)
}
private func stack(_ takes: Int, kind: TrackKind = .audio) throws -> (Timeline, [Clip]) {
    var cs: [Clip] = []
    var tracks: [Track] = []
    for _ in 0..<takes {
        let c = clip(0, 20, kind: kind); cs.append(c)
        var t = Track(kind: kind); try t.overwrite(c); tracks.append(t)
    }
    return (Timeline(name: "t", frameDuration: Time(1, 30), tracks: tracks), cs)
}

@Suite struct TimelineCompingTests {
    @Test func picksTakeInRangeOnly() throws {
        var (tl, cs) = try stack(2)
        let chosen = try tl.compTake(of: cs[1].id, range: TimeRange(start: s(5), duration: s(5)))
        #expect(chosen.count == 1)
        let t0 = tl.tracks[0].clips.map { ($0.start, $0.isEnabled) }
        #expect(t0.count == 3)
        #expect(t0[0].0 == s(0) && t0[0].1)
        #expect(t0[1].0 == s(5) && !t0[1].1)
        #expect(t0[2].0 == s(10) && t0[2].1)
        let mid = tl.tracks[1].clips.first { $0.start == s(5) }
        #expect(mid?.isEnabled == true)
        #expect(mid?.id == chosen[0])
    }

    @Test func doesNotTouchTrackSwitches() throws {
        var (tl, cs) = try stack(2)
        tl.tracks[0].isMuted = true
        try tl.compTake(of: cs[1].id, range: TimeRange(start: s(0), duration: s(20)))
        #expect(tl.tracks[0].isMuted)
        #expect(!tl.tracks[0].isSolo && !tl.tracks[1].isMuted)
        #expect(tl.tracks[0].clips.allSatisfy { !$0.isEnabled })
    }

    @Test func rangeClampedToClip() throws {
        var (tl, cs) = try stack(2)
        try tl.compTake(of: cs[0].id, range: TimeRange(start: s(15), duration: s(50)))
        #expect(tl.tracks[1].clips.filter { !$0.isEnabled }.map(\.start) == [s(15)])
    }

    @Test func refusals() throws {
        var (one, c1) = try stack(1)
        #expect(throws: EditError.notACut) { try one.compTake(of: c1[0].id, range: TimeRange(start: .zero, duration: s(5))) }
        #expect(!one.canCompTake(of: c1[0].id, range: TimeRange(start: .zero, duration: s(5))))
        var (two, c2) = try stack(2)
        #expect(two.canCompTake(of: c2[0].id, range: TimeRange(start: .zero, duration: s(5))))
        #expect(throws: EditError.clipNotFound) { try two.compTake(of: c2[0].id, range: TimeRange(start: s(30), duration: s(5))) }
        two.tracks[0].isLocked = true
        #expect(throws: EditError.trackLocked) { try two.compTake(of: c2[0].id, range: TimeRange(start: .zero, duration: s(5))) }
    }

    @Test func lockedOtherTakeIsIgnored() throws {
        var (tl, cs) = try stack(3)
        tl.tracks[0].isLocked = true
        try tl.compTake(of: cs[2].id, range: TimeRange(start: s(2), duration: s(4)))
        #expect(tl.tracks[0].clips.count == 1)
        #expect(tl.tracks[1].clips.count == 3)
    }

    @Test func linkedPartnerFollowsItsTake() throws {
        let l1 = UUID(), l2 = UUID()
        var v0 = Track(kind: .video), v1 = Track(kind: .video), a0 = Track(kind: .audio), a1 = Track(kind: .audio)
        let c0 = clip(0, 20, kind: .video, link: l1), c1 = clip(0, 20, kind: .video, link: l2)
        try v0.overwrite(c0); try v1.overwrite(c1)
        try a0.overwrite(clip(0, 20, kind: .audio, link: l1)); try a1.overwrite(clip(0, 20, kind: .audio, link: l2))
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v0, v1, a0, a1])
        try tl.compTake(of: c1.id, range: TimeRange(start: s(4), duration: s(4)))
        let off = tl.tracks[2].clips.first { $0.start == s(4) }
        let on = tl.tracks[3].clips.first { $0.start == s(4) }
        #expect(off?.isEnabled == false)
        #expect(on?.isEnabled == true)
        let vOff = tl.tracks[0].clips.first { $0.start == s(4) }
        #expect(vOff?.link == off?.link)
        #expect(tl.tracks[2].clips.count == 3 && tl.tracks[0].clips.count == 3)
    }

    @Test func lockedPartnerTrackRefusesAndChangesNothing() throws {
        let l1 = UUID(), l2 = UUID()
        var v0 = Track(kind: .video), v1 = Track(kind: .video), a0 = Track(kind: .audio), a1 = Track(kind: .audio)
        let c1 = clip(0, 20, kind: .video, link: l2)
        try v0.overwrite(clip(0, 20, kind: .video, link: l1)); try v1.overwrite(c1)
        try a0.overwrite(clip(0, 20, kind: .audio, link: l1)); try a1.overwrite(clip(0, 20, kind: .audio, link: l2))
        a1.isLocked = true
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v0, v1, a0, a1])
        let before = tl
        #expect(throws: EditError.trackLocked) { try tl.compTake(of: c1.id, range: TimeRange(start: s(4), duration: s(4))) }
        #expect(tl == before)
    }

    @Test func lockedOwnTrackCannotComp() throws {
        var (tl, cs) = try stack(2)
        tl.tracks[1].isLocked = true
        #expect(!tl.canCompTake(of: cs[1].id, range: TimeRange(start: .zero, duration: s(5))))
    }
}
