import Foundation
import Testing
@testable import SQCore

/// Int64 products on value/timescale used to trap for huge timescales (imported or corrupt files). These run the
/// call sites with extreme times and check they neither trap nor drift for ordinary inputs.
@Suite struct TimeOverflowFuzzTests {
    struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
        mutating func i64() -> Int64 { Int64(bitPattern: next() ^ (next() >> 29)) }
        mutating func positive() -> Int64 { max(1, Int64(bitPattern: next() >> 1) >> Int64(next() % 63)) }
    }

    static let extremes: [Time] = [
        Time(1, Int64.max), Time(Int64.max, 1), Time(Int64.max, Int64.max - 1), Time(Int64.max / 3, 7),
        Time(1001, 30000), Time(3, Int64.max / 2), Time(Int64.max - 2, Int64.max / 5 + 1), Time(Int64.max / 2 - 1, 1_000_003),
    ]

    @Test func scaledByIntegersIsExactWhenItFits() {
        #expect(Time.scaled(Time(1001, 30000), by: 3, over: 4) == Time(3003, 120000))
        #expect(Time.scaled(Time(5, 1), by: 1, over: 2) == Time(5, 2))
        #expect(Time.scaled(Time(5, 1), by: -2, over: 3) == Time(-10, 3))
        #expect(Time(5, 1).halved == Time(5, 2))
        #expect(Time(Int64.max, 1).halved > Time(Int64.max / 2 - 1, 1))
    }

    /// The lossy fallback of `Time(reducing:)` must stay close in relative terms even when the denominator is small
    /// (it used to shift both by the same power of two, turning 2*max/5 into 2*max/8).
    @Test func reducingFallbackKeepsRelativePrecision() {
        func rel(_ t: Time, _ n: Int128, _ d: Int128) -> Double {
            let want = Double(n) / Double(d), got = Double(t.value) / Double(t.timescale)
            return abs(got - want) / max(abs(want), 1e-300)
        }
        #expect(rel(Time(reducing: 6 * Int128(Int64.max), 15), 6 * Int128(Int64.max), 15) < 1e-12)
        #expect(rel(Time(reducing: -6 * Int128(Int64.max), 15), -6 * Int128(Int64.max), 15) < 1e-12)
        var rng = LCG(s: 99)
        for _ in 0..<20000 {
            let n = Int128(rng.i64()) * Int128(rng.positive()), d = Int128(rng.positive()) * Int128(rng.positive())
            guard abs(Double(n) / Double(d)) < 9e18 else { continue }
            let t = Time(reducing: n, d)
            #expect(rel(t, n, d) < 1e-9 || abs(Double(t.value) / Double(t.timescale) - Double(n) / Double(d)) < 1e-15)
        }
    }

    @Test func scaledByTimesNeverTraps() {
        let m = Time(Int64.max, 1), tiny = Time(1, Int64.max), odd = Time(Int64.max, Int64.max - 1)
        for t in [m, tiny, odd, -m] { for num in [m, tiny, odd, -m] { for den in [m, tiny, odd] {
            #expect(Time.scaled(t, by: num, over: den).timescale > 0)
        } } }
        #expect(Time.scaled(Time(3, 2), by: Time(2, 1), over: Time(3, 1)) == Time(1, 1))
    }

    @Test func scaledByIntegersNeverTraps() {
        var rng = LCG(s: 42)
        for _ in 0..<20000 {
            let t = Time(rng.i64() / 2, rng.positive())
            let r = Time.scaled(t, by: rng.i64() / 2, over: rng.positive())
            #expect(r.timescale > 0)
            #expect(t.halved.timescale > 0)
        }
        for t in Self.extremes {
            for (n, d) in [(Int64.max, Int64(1)), (1, Int64.max), (Int64.max, Int64.max - 1), (-7, 720), (Int64.max / 2, 3)] {
                #expect(Time.scaled(t, by: n, over: d).timescale > 0)
            }
        }
    }

    @Test func frameSnappingNeverTrapsAndStaysExact() {
        let a = Time(Int64.max, Int64.max - 2), fd = Time(Int64.max - 2, Int64.max)
        _ = a.snapped(to: fd); _ = a.ceiled(to: fd); _ = a.frameIndex(frameDuration: fd)
        let big = Time(Int64.max, 1), tiny = Time(1, Int64.max)
        #expect(big.frameIndex(frameDuration: tiny) == Int64.max)
        _ = big.snapped(to: tiny); _ = big.ceiled(to: tiny); _ = (-big).snapped(to: tiny)
        // Ordinary values: ties round up, negative values floor correctly.
        let f = Time(1, 30)
        #expect(Time(1, 60).snapped(to: f) == Time(1, 30))
        #expect(Time(1, 61).snapped(to: f) == .zero)
        #expect(Time(-1, 60).snapped(to: f) == .zero)
        #expect(Time(-1, 59).snapped(to: f) == Time(-1, 30))
        #expect(Time(1001, 30000 * 3).snapped(to: Time(1001, 30000)) == .zero)
        var rng = LCG(s: 7)
        for _ in 0..<20000 {
            let t = Time(rng.i64() / 2, rng.positive()), d = Time(max(1, rng.positive()), rng.positive())
            let s = t.snapped(to: d), c = t.ceiled(to: d)
            _ = t.frameIndex(frameDuration: d)
            #expect(s.timescale > 0 && c.timescale > 0)
        }
        for _ in 0..<2000 {
            let t = Time(rng.i64() % 100_000, Int64(1 + rng.next() % 1000)), d = Time(Int64(1 + rng.next() % 50), Int64(1 + rng.next() % 1000))
            let s = t.snapped(to: d)
            #expect(s - t <= d.halved && t - s < d.halved)
            #expect(Time.scaled(s, by: 1, over: 1).frameIndex(frameDuration: d) * 1 == s.frameIndex(frameDuration: d))
        }
    }

    @Test func sequenceFrameDurationOverflowFallbackStaysPositive() {
        let fd = FrameRate.sequenceFrameDuration(frameCount: 7, duration: Time(Int64.max - 1, Int64.max / 2 + 1))
        #expect(fd > .zero)
    }

    @Test func motionBlurSamplesSurviveHugeFrameDurations() {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        c.animation.shutterAngle = AnimatedProperty(360)
        c.animation.position = AnimatedProperty(.zero, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: .zero), Keyframe(time: Time(5, 1), value: Vec2(100, 0))]))
        let fmt = SequenceFormat(width: 640, height: 360, frameDuration: Time(1, 25))
        let normal = c.motionBlur(at: Time(1, 1), frameDuration: Time(1, 25), format: fmt)
        #expect(normal != nil)
        for fd in Self.extremes {
            _ = c.motionBlur(at: Time(1, 1), frameDuration: fd, format: fmt)
            _ = c.motionBlur(at: Time(Int64.max / 4, 3), frameDuration: fd, format: fmt)
        }
    }

    @Test func clipLevelWindowsSurviveHugeTimescales() {
        for d in Self.extremes where d < Time(3600, 1) {
            let (w, n) = ClipLevels.window(for: d)
            #expect(n >= 1 && w.timescale > 0)
            let c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: d), start: .zero)
            let (levels, _) = ClipLevels.audible(of: c) { _ in 1 }
            #expect(levels.count == n)
        }
        // Ordinary durations stay exact: 1 s is 100 windows of 10 ms.
        #expect(ClipLevels.window(for: Time(1, 1)).window == Time(1, 100))
    }

    @Test func legacyShadowSamplingSurvivesHugeTimescales() {
        for end in [Time(10, Int64.max / 7), Time(5, 1) + Time(1, Int64.max - 1), Time(299, 30)] {
            var e = ClipEffect.make(kind: ClipEffect.dropShadowKind)!
            e.parameters[ClipEffect.shadowRedKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
                Keyframe(time: .zero, value: 0, interpolation: .hold), Keyframe(time: end, value: 255)]))
            e.parameters[ClipEffect.shadowGreenKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
                Keyframe(time: .zero, value: 0), Keyframe(time: end, value: 255)]))
            let up = e.upgradingLegacyShadowColor()
            let keys = up.colors[ClipEffect.shadowColorKey]?.track.keys ?? []
            #expect(keys.count >= 2)
            #expect(zip(keys, keys.dropFirst()).allSatisfy { $0.time < $1.time })
        }
    }

    @Test func karaokeWordsSurviveHugeTimescales() {
        for d in Self.extremes {
            let item = CaptionItem(lines: ["one two three four"], range: TimeRange(start: .zero, duration: d))
            let w = item.effectiveWords
            #expect(w.count == 4)
            for i in 1..<w.count { #expect(w[i - 1].range.start <= w[i].range.start) }
            #expect(w.last!.range.end == d)
        }
    }
}
