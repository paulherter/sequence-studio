import Testing
import SQCore
@testable import SQLibrary

@Suite struct AudioPreviewTests {
    let dur = Time(10, 1)

    @Test func fractionToTime() {
        #expect(PreviewTimeMap.time(fraction: 0.5, duration: dur) == Time(5, 1))
        #expect(PreviewTimeMap.time(fraction: 0, duration: dur) == .zero)
        #expect(PreviewTimeMap.time(fraction: 1, duration: dur) == dur)
    }

    @Test func fractionClamps() {
        #expect(PreviewTimeMap.time(fraction: -1, duration: dur) == .zero)
        #expect(PreviewTimeMap.time(fraction: 7, duration: dur) == dur)
        #expect(PreviewTimeMap.time(fraction: .nan, duration: dur) == .zero)
    }

    @Test func timeToFraction() {
        #expect(PreviewTimeMap.fraction(time: Time(5, 2), duration: dur) == 0.25)
        #expect(PreviewTimeMap.fraction(time: Time(20, 1), duration: dur) == 1)
        #expect(PreviewTimeMap.fraction(time: Time(-1, 1), duration: dur) == 0)
        #expect(PreviewTimeMap.fraction(time: Time(1, 1), duration: .zero) == 0)
    }

    @Test func roundTripIsRational() {
        let t = PreviewTimeMap.time(fraction: 1.0 / 3.0, duration: Time(3, 1))
        #expect(abs(PreviewTimeMap.fraction(time: t, duration: Time(3, 1)) - 1.0 / 3.0) < 1e-6)
    }

    @Test func rangeDefaultsToWhole() {
        let r = PreviewRange(duration: dur)
        #expect(r.timeRange == TimeRange(start: .zero, duration: dur))
        #expect(r.isWhole)
    }

    @Test func rangeClampsAndOrders() {
        var r = PreviewRange(duration: dur)
        r.setIn(Time(4, 1)); r.setOut(Time(99, 1))
        #expect(r.timeRange == TimeRange(start: Time(4, 1), end: dur))
        r.setOut(Time(2, 1)) // before in: out stays one minimum step after in? no, clamped to in
        #expect(r.outPoint >= r.inPoint)
        #expect(r.timeRange == nil)
        r.setIn(Time(-5, 1))
        #expect(r.inPoint == .zero)
    }

    @Test func rangeFromFractions() {
        let r = PreviewRange(duration: dur, inFraction: 0.8, outFraction: 0.2)
        #expect(r.timeRange == TimeRange(start: Time(2, 1), end: Time(8, 1)))
        #expect(!r.isWhole)
    }

    @Test func rangeClampedToNewDuration() {
        var r = PreviewRange(duration: dur)
        r.setIn(Time(6, 1))
        r.duration = Time(5, 1)
        #expect(r.inPoint == Time(5, 1))
        #expect(r.outPoint == Time(5, 1))
    }

    @Test func playbackClampsToRange() {
        var r = PreviewRange(duration: dur)
        r.setIn(Time(2, 1)); r.setOut(Time(6, 1))
        #expect(r.clamp(Time(1, 1)) == Time(2, 1))
        #expect(r.clamp(Time(9, 1)) == Time(6, 1))
        #expect(r.clamp(Time(3, 1)) == Time(3, 1))
    }
}
