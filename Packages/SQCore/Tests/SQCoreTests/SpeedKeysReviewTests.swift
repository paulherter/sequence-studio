import Foundation
import Testing
@testable import SQCore

private let fd = Time(1001, 30000)
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private func seg(_ n: Int64, _ a: Double, _ b: Double? = nil, rev: Bool = false) -> SpeedSegment {
    SpeedSegment(duration: fd * n, from: pct(a), to: pct(b ?? a), reversed: rev)
}
private func rampClip() -> Clip {
    var c = Clip(name: "r", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: fd * 5,
                 mediaDuration: Time(60, 1))
    c.setSpeedKeys(SpeedKeys(segments: [seg(30, 100), seg(41, 100, 300), seg(30, 300)], origin: Time(7, 3)))
    return c
}

@Suite struct SpeedKeysReviewTests {
    @Test func splitAndHeadTrimReproduceTheMappingFrameForFrame() throws {
        let c = rampClip()
        let n = c.duration.frameIndex(frameDuration: fd)
        var before: [Time] = []
        for i in 0..<n { before.append(c.sourceTime(at: c.start + fd * i, frameDuration: fd)) }
        for cut in stride(from: 7 as Int64, to: n, by: 7) {
            var t = Track(kind: .video)
            try t.overwrite(c)
            try t.split(at: c.start + fd * cut)
            let l = t.clips[0], r = t.clips[1]
            for i in 0..<n {
                let clip = i < cut ? l : r
                let got = clip.sourceTime(at: c.start + fd * i, frameDuration: fd)
                #expect(got == before[Int(i)], "cut \(cut) frame \(i)")
                #expect(got.frameIndex(frameDuration: fd) == before[Int(i)].frameIndex(frameDuration: fd))
            }
        }
        for g in [3 as Int64, 10, 31, 45] {
            var h = c
            h.extendHead(by: .zero - fd * g)
            for i in g..<n {
                #expect(h.sourceTime(at: h.start + fd * (i - g), frameDuration: fd) == before[Int(i)], "head trim \(g) frame \(i)")
            }
        }
    }

    @Test func exactOriginSurvivesTheFile() throws {
        let c = rampClip()
        var t = Track(kind: .video)
        try t.overwrite(c)
        try t.split(at: c.start + fd * 7)
        let r = t.clips[1]
        #expect(r.speedKeys?.originExact != nil)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(r))
        #expect(back == r && back.sourceTime(at: back.start + fd * 3, frameDuration: fd) == r.sourceTime(at: r.start + fd * 3, frameDuration: fd))
    }

    @Test func roundTripOnFrameStartsAcrossReversedAndForwardSegments() {
        var c = Clip(name: "p", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero,
                     mediaDuration: Time(60, 1))
        c.setSpeedKeys(SpeedKeys(segments: [seg(30, 100), seg(20, 100, rev: true), seg(30, 100)], origin: Time(2, 1)))
        let n = c.duration.frameIndex(frameDuration: fd)
        for i in 0..<n {
            let s = c.sourceTime(at: fd * i, frameDuration: fd)
            let back = c.timelineTime(forSource: s, frameDuration: fd)
            #expect(c.sourceTime(at: back, frameDuration: fd) == s, "frame \(i)")
        }
    }

    @Test func mappingCallsAreCheap() {
        var c = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero,
                     mediaDuration: Time(600, 1))
        c.setSpeedKeys(SpeedKeys(segments: [seg(60, 100), seg(20, 100, 400), seg(60, 400), seg(20, 400, 50), seg(60, 50)], origin: Time(1, 1)))
        let n = Int(c.duration.frameIndex(frameDuration: fd))
        let clock = ContinuousClock()
        var sink = Time.zero
        let rounds = 40
        let t0 = clock.now
        for _ in 0..<rounds { for i in 0..<n { sink = c.sourceTime(at: fd * Int64(i), frameDuration: fd) } }
        let d0 = clock.now - t0
        let t1 = clock.now
        for _ in 0..<rounds { for i in 0..<n { sink = c.timelineTime(forSource: Time(Int64(i), 100), frameDuration: fd) } }
        let d1 = clock.now - t1
        let us0 = Double(d0.components.attoseconds) / 1e12 / Double(rounds * n) + Double(d0.components.seconds) * 1e6 / Double(rounds * n)
        let us1 = Double(d1.components.attoseconds) / 1e12 / Double(rounds * n) + Double(d1.components.seconds) * 1e6 / Double(rounds * n)
        print("[speedkeys] sourceTime \(us0) us/call, timelineTime(forSource:) \(us1) us/call")
        _ = sink
        #expect(us0 < 50 && us1 < 200)
    }

    @Test func scalingKeepsSegmentSpeedsInRangeAndSourceSpans() throws {
        var c = Clip(name: "s", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero,
                     mediaDuration: Time(600, 1))
        c.setSpeedKeys(SpeedKeys(segments: [seg(60, 50), seg(60, 200)], origin: .zero))
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        let before = tl.tracks[0].clips[0]
        try tl.setDuration(before.id, to: fd)                                   // absurdly short
        let c1 = tl.tracks[0].clips[0]
        let k = try #require(c1.speedKeys)
        for s in k.segments { #expect(s.from <= .maximum && s.to <= .maximum && s.from >= .minimum) }
        #expect(c1.duration >= k.durationLimits(frameDuration: fd).min)
        #expect(abs(k.pathLength.value * before.retimeSpan.timescale - before.retimeSpan.value * k.pathLength.timescale)
                < 3 * k.pathLength.timescale * before.retimeSpan.timescale)   // spans preserved up to frame rounding
        try tl.setDuration(before.id, to: Time(100_000, 1))                     // absurdly long
        for s in tl.tracks[0].clips[0].speedKeys!.segments { #expect(s.from >= .minimum && s.to >= .minimum) }
    }

    @Test func nestedReversedUsesTheInnerFrameDuration() {
        let m = UUID()
        let iv = Clip(name: "iv", media: m, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero, mediaDuration: Time(10, 1))
        let inner = Timeline(name: "inner", frameDuration: Time(1, 25), tracks: [Track(kind: .video, clips: [iv])])
        var n = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero,
                     mediaDuration: Time(10, 1), sequence: inner.id, reversed: true)
        n.speed = .normal
        let outer = Timeline(name: "o", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [n])])
        let l = outer.videoLayers(at: .zero, sequences: { $0 == inner.id ? inner : nil })
        #expect(l.first?.sourceTime == Time(10, 1) - Time(1, 25))               // the last INNER frame, not an outer frame earlier
    }
}

