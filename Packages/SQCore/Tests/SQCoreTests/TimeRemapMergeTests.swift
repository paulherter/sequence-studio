import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private func seg(_ n: Int64, _ a: Double, _ b: Double? = nil, rev: Bool = false) -> SpeedSegment {
    SpeedSegment(duration: f(n), from: pct(a), to: pct(b ?? a), reversed: rev)
}
private func keyed(_ name: String, start: Int64, origin: Time, _ segs: [SpeedSegment]) -> Clip {
    var c = Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: origin, duration: f(1)), start: f(start),
                 mediaDuration: f(3000))
    c.setSpeedKeys(SpeedKeys(segments: segs, origin: origin))
    return c
}

@Suite struct TimeRemapMergeTests {
    @Test func oneMappingHoldThenSpeedKeysThenConstant() {
        var c = keyed("k", start: 0, origin: f(100), [seg(30, 100), seg(30, 200)])
        let t = f(40)
        let live = c.sourceTime(at: t, frameDuration: fd)
        #expect(live != f(100))
        c.holdFrame = f(77)
        #expect(c.sourceTime(at: t, frameDuration: fd) == f(77))                  // hold beats the speed track
        #expect(c.sourceInstant(atLocal: f(40)) == f(77))
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        c.timeInterpolation = .frameBlend
        tl.tracks[0].replace(c)
        let l = tl.videoLayers(at: t).first
        #expect(l?.sourceTime == f(77) && l?.interpolation == .frameSampling)       // a held clip never blends
        c.holdFrame = nil
        tl.tracks[0].replace(c)
        #expect(tl.videoLayers(at: t).first?.interpolation == .frameBlend)
        #expect(tl.videoLayers(at: t).first?.sourceTime == live)
    }

    @Test func freezingARemappedClipDropsTheSpeedTrack() throws {
        let c = keyed("k", start: 0, origin: f(100), [seg(30, 100), seg(30, 200)])
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        _ = try tl.addFrameHold(of: c.id, at: f(10))
        let held = tl.tracks[0].clips.first { $0.holdFrame != nil }
        #expect(held?.speedKeys == nil)
    }

    @Test func handlesAndTransitionsThroughTheMapping() throws {
        let a = keyed("A", start: 0, origin: f(200), [seg(30, 100), seg(30, 200)])               // ends at 200 + 30 + 60 frames
        let b = keyed("B", start: 60, origin: f(500), [seg(30, 50), seg(30, 100)])
        // head / tail rooms come from the first / last speed (and direction) of the track
        #expect(a.tailRoom == pct(200).unscale(f(3000) - a.speedKeys!.endPosition))
        #expect(b.headHandle == pct(50).unscale(f(500)))
        var t = Track(kind: .video)
        try t.overwrite(a); try t.overwrite(b)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [t])
        _ = try tl.addTransition(kind: .crossDissolve, track: tl.tracks[0].id, outgoing: a.id, incoming: b.id, duration: f(20))
        let r = try #require(tl.resolvedTransitions(on: tl.tracks[0].id).first)
        #expect(!r.isClamped && r.before == f(10))
        // Inside the transition A plays on past its end at its last speed, B before its start at its first speed.
        let at = f(65), before = f(55)
        let after = tl.videoLayers(at: at)
        let la = try #require(after.first { $0.clip == a.id }), lb = try #require(after.first { $0.clip == b.id })
        #expect(la.sourceTime == a.sourceTime(at: at, frameDuration: fd))
        #expect(la.sourceTime > a.speedKeys!.endPosition)
        let pre = tl.videoLayers(at: before)
        let lb2 = try #require(pre.first { $0.clip == b.id })
        #expect(lb2.sourceTime == b.sourceTime(at: before, frameDuration: fd))
        #expect(lb2.sourceTime < b.speedKeys!.origin)
        _ = lb
    }

    @Test func reversedEndSegmentsHaveTheirHandlesOnTheOtherSide() {
        let c = keyed("R", start: 0, origin: f(500), [seg(30, 100), seg(30, 100, rev: true)])   // ends 30 frames below the turn
        let k = c.speedKeys!
        #expect(c.tailRoom == pct(100).unscale(k.endPosition))                    // runs on downward: room down to 0
        // outside the clip the reversed tail keeps going down (never clamped into the hull)
        #expect(c.sourceTime(at: f(70), frameDuration: fd) < k.endPosition)
        #expect(c.sourceTime(at: f(-5), frameDuration: fd) < f(500))
        #expect(c.sourceTime(at: f(-5), frameDuration: fd) == f(495))
    }

    @Test func nestedRetimeWithStyledGroupKeepsItsMapping() throws {
        let m = UUID()
        let iv = Clip(name: "iv", media: m, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero, mediaDuration: Time(10, 1))
        let inner = Timeline(name: "inner", frameDuration: fd, tracks: [Track(kind: .video, clips: [iv])])
        var n = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero,
                     mediaDuration: Time(10, 1), sequence: inner.id)
        let cropID = n.addEffect(kind: ClipEffect.cropKind)
        let crop = try #require(cropID)
        n.setParameter(crop, ClipEffect.cropLeftKey, to: 10)
        n.speed = pct(200)
        n.blendMode = .screen
        let outer = Timeline(name: "o", frameDuration: fd, tracks: [Track(kind: .video, clips: [n])])
        let l = try #require(outer.videoLayers(at: Time(1, 1), sequences: { $0 == inner.id ? inner : nil }).first)
        #expect(l.sourceTime == Time(2, 1))
        #expect(l.groups.count == 1 && !l.groups[0].effects.isEmpty)
    }
}
