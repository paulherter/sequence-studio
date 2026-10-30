import Foundation
import Testing
@testable import SQCore

/// Live ducking timing controls (lookahead, attack, hold, recovery, minimum pause) on the one LiveDucking system.
@Suite struct LiveDuckingTimingTests {
    static func sec(_ a: Int64, _ len: Int64) -> TimeRange { TimeRange(start: Time(a, 1), duration: Time(len, 1)) }
    static func ms(_ v: Int64) -> Time { Time(v, 1000) }

    @Test func classicTimingIsTheOldBehaviour() {
        let old = LiveDucking(amountDB: 12, fade: Time(1, 2))
        #expect(old.timing == DuckTiming(attackMs: 500, recoveryMs: 500))
        let ranges = [Self.sec(10, 4), Self.sec(15, 2), Self.sec(40, 3)]
        let f = old.factor
        for t in stride(from: 0, to: 6000, by: 7) {
            let time = Time(Int64(t), 100)
            let g = old.gain(at: time, ranges: ranges)
            // Reference: the original single-fade rule.
            var expect: Float = 1
            for (i, r) in ranges.enumerated() {
                if i + 1 < ranges.count, ranges[i + 1].start - r.end <= old.fade + old.fade, time >= r.end, time <= ranges[i + 1].start { expect = f; break }
                let d: Time = time < r.start ? r.start - time : (time > r.end ? time - r.end : .zero)
                let x: Float = d == .zero ? f : (d >= old.fade ? 1 : f + (1 - f) * Float(Double(d.value) / Double(d.timescale) / 0.5))
                expect = min(expect, x)
            }
            #expect(g == expect)
        }
    }

    @Test func lookaheadStartsTheDuckEarlier() {
        let live = LiveDucking(amountDB: 12, timing: DuckTiming(lookaheadMs: 100, attackMs: 0, holdMs: 0, recoveryMs: 0))
        let r = [Self.sec(10, 2)]
        #expect(live.gain(at: Time(9, 1) + Self.ms(950), ranges: r) == live.factor)
        #expect(live.gain(at: Time(9, 1) + Self.ms(850), ranges: r) == 1)
    }

    @Test func holdKeepsTheDuckAfterTheDialogue() {
        let live = LiveDucking(amountDB: 12, timing: DuckTiming(lookaheadMs: 0, attackMs: 0, holdMs: 200, recoveryMs: 0))
        let r = [Self.sec(10, 2)]
        #expect(live.gain(at: Time(12, 1) + Self.ms(150), ranges: r) == live.factor)
        #expect(live.gain(at: Time(12, 1) + Self.ms(250), ranges: r) == 1)
    }

    @Test func attackAndRecoveryAreIndependentRamps() {
        let live = LiveDucking(amountDB: 20, timing: DuckTiming(lookaheadMs: 0, attackMs: 100, holdMs: 0, recoveryMs: 1000))
        let r = [Self.sec(10, 2)]
        let f = live.factor
        // half way down (50 ms before), half way up (500 ms after)
        #expect(abs(live.gain(at: Time(10, 1) - Self.ms(50), ranges: r) - (f + (1 - f) * 0.5)) < 1e-5)
        #expect(abs(live.gain(at: Time(12, 1) + Self.ms(500), ranges: r) - (f + (1 - f) * 0.5)) < 1e-5)
        #expect(live.gain(at: Time(10, 1) - Self.ms(150), ranges: r) == 1)
        #expect(live.gain(at: Time(12, 1) + Self.ms(1100), ranges: r) == 1)
    }

    @Test func minimumPauseBridgesShortGaps() {
        let r = [Self.sec(10, 2), TimeRange(start: Time(12, 1) + Self.ms(300), duration: Time(2, 1))]
        let a = LiveDucking(amountDB: 12, timing: DuckTiming(lookaheadMs: 0, attackMs: 10, holdMs: 0, recoveryMs: 10, minPauseMs: 0))
        let b = LiveDucking(amountDB: 12, timing: DuckTiming(lookaheadMs: 0, attackMs: 10, holdMs: 0, recoveryMs: 10, minPauseMs: 400))
        let mid = Time(12, 1) + Self.ms(150)
        #expect(a.gain(at: mid, ranges: r) == 1)
        #expect(b.gain(at: mid, ranges: r) == b.factor)
    }

    @Test func curveMatchesGainWithTiming() {
        let live = LiveDucking(amountDB: 12, timing: .resolve)
        let ranges = [Self.sec(10, 2), Self.sec(20, 3)]
        let pts = live.curve(ranges: ranges, in: Self.sec(0, 40))
        for i in 0..<(pts.count - 1) {
            let mid = pts[i].time + (pts[i + 1].time - pts[i].time).halved
            let lerp = (pts[i].gain + pts[i + 1].gain) / 2
            #expect(abs(live.gain(at: mid, ranges: ranges) - lerp) < 1e-4)
        }
    }

    @Test func projectSettingRoundTripsAndOldFilesDecode() throws {
        let p = ProjectLiveDucking(isOn: true, amountDB: 9, timing: .resolve)
        let data = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(ProjectLiveDucking.self, from: data) == p)
        #expect(p.liveDucking?.timing == .resolve)
        let old = try JSONDecoder().decode(ProjectLiveDucking.self, from: Data(#"{"isOn":true,"amountDB":12}"#.utf8))
        #expect(old.timing == nil && old.liveDucking?.timing == .classic)
        #expect(ProjectLiveDucking(isOn: true, timing: .classic).timing == nil)
    }

    @Test func preferencesStoreTiming() {
        let d = UserDefaults(suiteName: "sq.test.duckTiming")!
        d.removePersistentDomain(forName: "sq.test.duckTiming")
        LiveDucking.setAmount(12, defaults: d)
        #expect(LiveDucking.current(d)?.timing == .classic)
        DuckTiming.store(.resolve, defaults: d)
        #expect(LiveDucking.current(d)?.timing == .resolve)
        DuckTiming.store(.classic, defaults: d)
        #expect(d.object(forKey: DuckTiming.holdKey) == nil)
        d.removePersistentDomain(forName: "sq.test.duckTiming")
    }

    @Test func bakedKeysReproduceTheTimedCurve() {
        let live = LiveDucking(amountDB: 12, timing: DuckTiming(lookaheadMs: 200, attackMs: 100, holdMs: 500, recoveryMs: 400))
        var t = LiveDuckingTests.timeline(dialogue: [(10, 5), (30, 5)])
        let ranges = LiveDucking.dialogueRanges(in: t)
        #expect(live.bake(into: &t) > 0)
        let c = t.tracks[1].clips[0]
        for probe in [Time(19, 2), Time(99, 10), Time(10, 1), Time(15, 1), Time(155, 10), Time(16, 1), Time(171, 10), Time(20, 1), Time(36, 1), Time(367, 10)] {
            let baked = c.animation.volume.value(atLocal: probe - c.start)
            #expect(abs(baked - Double(live.gain(at: probe, ranges: ranges))) < 1e-5, "at \(probe)")
        }
    }
}
