import Foundation
import Testing
@testable import SQCore

/// Fixes from the SQCore edit-logic review: overflow-safe time arithmetic, duplicate placement, punch-in on copies,
/// reverse of a speed-keyed clip, negative edit points, deterministic ripple delete, range markers on ripple delete.
@Suite struct CoreReviewFixTests {
    private static let ntsc = Time(1001, 30000)

    private func secondsOf(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

    // MARK: (1) Overflow

    private func retimeTimeline() throws -> (Timeline, Clip.ID) {
        var c = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(441001, 44100)),
                     start: .zero, mediaDuration: Time(3600, 1))
        c.animation.opacity.track.insert(Keyframe(time: Self.ntsc * 7, value: 0.5))
        var v = Track(kind: .video)
        try v.overwrite(c)
        return (Timeline(name: "t", frameDuration: Self.ntsc, tracks: [v]), c.id)
    }

    @Test func secondRetimeDoesNotOverflowAndKeysFollow() throws {
        var (tl, id) = try retimeTimeline()
        let d0 = tl.tracks[0].clips[0].duration
        try tl.setSpeed(id, to: ClipSpeed(percent: 33.33))
        try tl.setSpeed(id, to: ClipSpeed(percent: 77.77))
        let c = tl.tracks[0].clips[0]
        let key = try #require(c.animation.opacity.track.keys.first).time
        let want = secondsOf(Self.ntsc * 7) * secondsOf(c.duration) / secondsOf(d0)
        #expect(abs(secondsOf(key) - want) < 1e-6)
    }

    @Test func secondRateStretchDoesNotOverflow() throws {
        var (tl, id) = try retimeTimeline()
        let d0 = tl.tracks[0].clips[0].duration
        try tl.rateStretch(id, edge: .tail, by: Self.ntsc * 200)
        try tl.rateStretch(id, edge: .tail, by: Self.ntsc * -117)
        try tl.setDuration(id, to: Self.ntsc * 401)
        let c = tl.tracks[0].clips[0]
        let key = try #require(c.animation.opacity.track.keys.first).time
        let want = secondsOf(Self.ntsc * 7) * secondsOf(c.duration) / secondsOf(d0)
        #expect(abs(secondsOf(key) - want) < 1e-6)
        _ = c.averageSpeed
    }

    @Test func timeArithmeticNeverTraps() {
        let a = Time(1, (1 << 40) + 1), b = Time(1, (1 << 40) + 3)
        let s = a + b
        #expect(abs(secondsOf(s) - (secondsOf(a) + secondsOf(b))) < 1e-15)
        let big = Time(Int64.max / 2, 1) + Time(Int64.max / 2 + 10, 1)
        #expect(big.value > 0)
        #expect(big.timescale == 1)                        // clamped, not wrapped
        let neg = Time(Int64.min / 2, 1) - Time(Int64.max / 2 + 10, 1)
        #expect(neg.value < 0)
        let m = Time(Int64.max / 3, 7) * 100
        #expect(m.value > 0)
        let sp = ClipSpeed(percent: 33.33)
        let sc = sp.scale(Time(Int64.max / 5, Int64.max / 7))
        #expect(abs(secondsOf(sc) - 0.3333 * 7 / 5) < 1e-9)
        // Exact results stay exact.
        #expect(Time(1, 3) + Time(1, 6) == Time(1, 2))
        #expect(Time(1001, 30000) * 30 == Time(1001, 1000))
    }

    // MARK: (2) Duplicate / paste never overwrite the original

    @Test func duplicateLandsAfterAnOffFrameEnd() throws {
        let c = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(51, 100)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(c)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v])
        let made = try tl.duplicate([c.id])
        let orig = try #require(tl.find(c.id)).clip
        #expect(orig.timeline.end == Time(51, 100))
        let copy = try #require(tl.find(made[0])).clip
        #expect(copy.start == Time(16, 30))
        let consistent = tl.tracks.allSatisfy { $0.isConsistent }; #expect(consistent)
    }

    // MARK: (3) Punch-in on copies

    @Test func punchInTogglesOffOnTheRightHalfOfACut() throws {
        let c = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(c)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v])
        let first = try tl.togglePunchIn([c.id])
        #expect(first)
        let right = try tl.addEdit(at: Time(1, 1), tracks: nil)
        let rid = try #require(right.first)
        let r0 = try #require(tl.find(rid)).clip
        #expect(tl.isPunchedIn(r0))
        let on = try tl.togglePunchIn([rid])
        #expect(!on)
        let r = try #require(tl.find(rid)).clip
        let stages = r.effects.filter { $0.kind == ClipEffect.transformKind }.count
        #expect(stages == 0)
        // The left half keeps its punch-in.
        let left = try #require(tl.find(c.id)).clip
        #expect(tl.isPunchedIn(left))
    }

    @Test func punchInOnAPastedCopyDoesNotStack() throws {
        let c = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var v = Track(kind: .video)
        try v.overwrite(c)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v])
        try tl.togglePunchIn([c.id])
        let made = try tl.duplicate([c.id])
        let off = try tl.togglePunchIn(made)
        #expect(!off)
        let again = try tl.togglePunchIn(made)
        #expect(again)
        let copy = try #require(tl.find(made[0])).clip
        let stages = copy.effects.filter { $0.kind == ClipEffect.transformKind }.count
        #expect(stages == 1)
    }

    // MARK: (4) Reverse of a speed-keyed clip mirrors keys

    @Test func reversingASpeedKeyedClipMirrorsKeys() throws {
        let fd = Self.ntsc
        var c = Clip(name: "r", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero,
                     mediaDuration: Time(60, 1))
        c.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: fd * 30, from: .normal, to: .normal),
                                            SpeedSegment(duration: fd * 30, from: ClipSpeed(percent: 200), to: ClipSpeed(percent: 200))],
                                 origin: Time(1, 1)))
        c.animation.opacity.track.insert(Keyframe(time: fd * 10, value: 0.5))
        var v = Track(kind: .video)
        try v.overwrite(c)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [v])
        let d = tl.tracks[0].clips[0].duration
        try tl.setSpeed(c.id, to: tl.tracks[0].clips[0].averageSpeed, reversed: true)
        let r = tl.tracks[0].clips[0]
        #expect(r.duration == d)
        #expect(r.animation.opacity.track.keys.first?.time == d - fd * 10)
    }

    // MARK: (5) Negative edit points

    @Test func overwriteAndInsertRejectNegativeTimes() throws {
        let v = Track(kind: .video)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v])
        let c = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
        var threw = 0
        do { try tl.overwrite([(c, v.id)], at: Time(-1, 2)) } catch { threw += 1 }
        do { try tl.insert([(c, v.id)], at: Time(-1, 2)) } catch { threw += 1 }
        #expect(threw == 2)
        #expect(tl.tracks[0].clips.isEmpty)
    }

    // MARK: (6) Ripple delete with two linked members on one track

    @Test func rippleDeleteIsTheSameWhicheverMemberIsClicked() throws {
        func s(_ n: Int64) -> Time { Time(n, 1) }
        let link = UUID()
        let a = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero, link: link)
        let b = Clip(name: "b", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: s(20), link: link)
        let m = Clip(name: "m", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(6)), start: s(12))
        let z = Clip(name: "z", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: s(40))
        var v = Track(kind: .video)
        for c in [a, b, m, z] { try v.overwrite(c) }
        let base = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v])
        var x = base, y = base
        let cx = try x.rippleDelete([a.id])
        let cy = try y.rippleDelete([b.id])
        #expect(cx == cy)
        let rx = x.tracks[0].clips.map { $0.timeline }, ry = y.tracks[0].clips.map { $0.timeline }
        #expect(rx == ry)
        let consistent = x.tracks.allSatisfy { $0.isConsistent }; #expect(consistent)
    }

    // MARK: (7) Range markers on ripple delete

    @Test func rippleDeleteShortensRangeMarkers() throws {
        func s(_ n: Int64) -> Time { Time(n, 1) }
        let clips = [(0, 3), (3, 2), (5, 5)].map { st, d in
            Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(d)), start: s(Int64(st)))
        }
        var v = Track(kind: .video)
        for c in clips { try v.overwrite(c) }
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [v])
        tl.markers = [Marker(time: s(2), duration: s(4)),      // spans the deleted 3..5
                      Marker(time: s(4), duration: s(4)),      // starts inside it
                      Marker(time: s(1), duration: s(3)),      // ends inside it
                      Marker(time: s(7), duration: s(1))]      // after it
        try tl.rippleDelete([clips[1].id])
        let got = tl.markers.map { ($0.time, $0.duration) }.sorted { $0.0 < $1.0 }
        #expect(got.map(\.0) == [s(1), s(2), s(3), s(5)])
        #expect(got.map(\.1) == [s(2), s(2), s(3), s(1)])
    }
}
