import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private func seg(_ frames: Int64, _ a: Double, _ b: Double? = nil) -> SpeedSegment {
    SpeedSegment(duration: f(frames), from: pct(a), to: pct(b ?? a), reversed: false)
}

private func close(_ a: EaseHandle, _ b: EaseHandle) -> Bool { abs(a.dx - b.dx) < 1e-5 && abs(a.dy - b.dy) < 1e-5 }

@Suite struct SpeedKeysPointsTests {
    @Test func aNoChangePointRetimesTheSpanBeforeIt() throws {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 100)], origin: .zero)
        let slower = try #require(k.retimingKey(atBoundary: 1, by: f(30), frameDuration: fd))
        #expect(slower.segments.map(\.duration) == [f(60), f(30)])
        #expect(slower.segments[0].from == pct(50) && slower.segments[1].from == pct(100))
        #expect(slower.duration == f(90))
        // the point keeps its source frame: 30 frames of source before it, as before
        #expect(slower.position(at: f(60)) == k.position(at: f(30)))
        let faster = try #require(k.retimingKey(atBoundary: 1, by: .zero - f(15), frameDuration: fd))
        #expect(faster.segments[0].duration == f(15) && faster.segments[0].from == pct(200) && faster.duration == f(45))
    }

    @Test func retimeStaysWithinSpeedLimitsAndOneFrame() throws {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 100)], origin: .zero)
        let tiny = try #require(k.retimingKey(atBoundary: 1, by: .zero - f(100), frameDuration: fd))
        #expect(tiny.segments[0].duration >= fd && tiny.segments[0].from <= .maximum)
        let huge = try #require(k.retimingKey(atBoundary: 1, by: f(100_000), frameDuration: fd))
        #expect(huge.segments[0].from == .minimum)
        #expect(k.retimingKey(atBoundary: 1, by: .zero, frameDuration: fd) == nil)
    }

    @Test func retimeLeavesHalvesOfATransitionAlone() {
        let k = SpeedKeys(segments: [seg(30, 100), seg(10, 100, 200), seg(30, 200)], origin: .zero)
        #expect(k.retimingKey(atBoundary: 1, by: f(5), frameDuration: fd) == nil)
        #expect(k.retimingKey(atBoundary: 2, by: f(5), frameDuration: fd) == nil)
    }

    @Test func easingAPointOpensATransitionWithTheCurve() throws {
        let k = SpeedKeys(segments: [seg(40, 100), seg(40, 300)], origin: .zero)
        let e = try #require(k.easingPoint(atLocal: f(40), curve: .easeInOut, side: .both, frameDuration: fd))
        #expect(e.segments.count == 3 && e.segments[1].isRamp && e.segments[1].duration == f(20))
        #expect(e.duration == k.duration)
        #expect(close(e.segments[1].easeShape.out, EasingCurve.easeInOut.outHandle) && close(e.segments[1].easeShape.in, EasingCurve.easeInOut.inHandle))
        // easing again with one side keeps the other side's handle
        let out = try #require(e.easingPoint(atLocal: f(40), curve: .fastStart, side: .out, frameDuration: fd))
        #expect(close(out.segments[1].easeShape.in, EasingCurve.easeInOut.inHandle))
        #expect(close(out.segments[1].easeShape.out, EasingCurve.fastStart.outHandle))
        #expect(out.segments.count == 3)
    }

    @Test func easeNeedsAChangeOfSpeedAndAPoint() {
        let same = SpeedKeys(segments: [seg(40, 100), seg(40, 100)], origin: .zero)
        #expect(same.easingPoint(atLocal: f(40), curve: .easeInOut, side: .both, frameDuration: fd) == nil)
        let k = SpeedKeys(segments: [seg(40, 100), seg(40, 300)], origin: .zero)
        #expect(k.easingPoint(atLocal: f(10), curve: .easeInOut, side: .both, frameDuration: fd) == nil)
        #expect(k.easingPoint(atLocal: f(40), curve: .hold, side: .both, frameDuration: fd) == nil)
    }
}
