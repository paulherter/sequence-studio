import Foundation
import Testing
@testable import SQCore

/// N8b: the duck curve drawn on the music track (breakpoints of `LiveDucking.gain`).
@Suite struct LiveDuckingCurveTests {
    static func sec(_ a: Int64, _ len: Int64) -> TimeRange { TimeRange(start: Time(a, 1), duration: Time(len, 1)) }
    static func d(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
    let live = LiveDucking(amountDB: 12, fade: Time(1, 2))

    @Test func noDialogueIsAFlatLine() {
        let p = live.curve(ranges: [], in: Self.sec(0, 30))
        #expect(p.count == 2 && p.allSatisfy { $0.gain == 1 })
        #expect(p[0].time == .zero && p[1].time == Time(30, 1))
    }

    @Test func rampsAroundOneRange() {
        let f = live.factor
        let p = live.curve(ranges: [Self.sec(10, 10)], in: Self.sec(0, 30))
        #expect(p.map(\.time) == [Time(0, 1), Time(19, 2), Time(10, 1), Time(20, 1), Time(41, 2), Time(30, 1)].sorted())
        #expect(p.map(\.gain) == [1, 1, f, f, 1, 1])
    }

    @Test func closeRangesHoldTheDuckBetween() {
        // gap 0.5 s <= two fades: one dip, no release in between
        let p = live.curve(ranges: [Self.sec(10, 2), TimeRange(start: Time(25, 2), duration: Time(2, 1))], in: Self.sec(0, 30))
        #expect(p.filter { $0.time > Time(10, 1) && $0.time < Time(29, 2) }.allSatisfy { $0.gain == live.factor })
    }

    @Test func windowClipsThePoints() {
        let p = live.curve(ranges: [Self.sec(10, 10)], in: Self.sec(12, 4))
        #expect(p.first?.time == Time(12, 1) && p.last?.time == Time(16, 1))
        #expect(p.allSatisfy { $0.gain == live.factor })
    }

    @Test func offHasNoCurve() {
        #expect(LiveDucking(amountDB: 0).curve(ranges: [Self.sec(1, 1)], in: Self.sec(0, 5)).isEmpty)
    }

    @Test func curveMatchesGainEverywhere() {
        let ranges = [Self.sec(3, 2), Self.sec(9, 4), Self.sec(14, 1)]
        let p = live.curve(ranges: ranges, in: Self.sec(0, 20))
        for i in 0..<(p.count - 1) {
            let a = p[i], b = p[i + 1]
            let mid = Time(Int64(((Self.d(a.time) + Self.d(b.time)) / 2 * 1000).rounded()), 1000)
            let lerp = a.gain + (b.gain - a.gain) * Float((Self.d(mid) - Self.d(a.time)) / (Self.d(b.time) - Self.d(a.time)))
            #expect(abs(live.gain(at: mid, ranges: ranges) - lerp) < 1e-3)
        }
    }
}
