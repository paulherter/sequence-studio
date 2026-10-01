import CoreGraphics
import Foundation
import Testing
import SQCore
@testable import SQEditorUI

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
/// 30 points per second, clip starts at timeline 0 -> x = 30 * seconds + 10.
private func x(_ t: Time) -> CGFloat { 10 + 30 * CGFloat(t.value) / CGFloat(t.timescale) }
private func timeAt(_ x: CGFloat) -> Time { Time(Int64(((x - 10) / 30 * 3000).rounded()), 3000) }
private let lane = CGRect(x: 10, y: 100, width: 300, height: 40)
private func seg(_ frames: Int64, _ a: Double, _ b: Double? = nil) -> SpeedSegment {
    SpeedSegment(duration: f(frames), from: pct(a), to: pct(b ?? a))
}

@Suite struct SpeedBandTests {
    @Test func speedHeightIsLogarithmicAndInvertible() {
        let area = SpeedBand.lineArea(in: lane)
        #expect(SpeedBand.y(forSpeed: 1, in: area) == area.midY)
        #expect(SpeedBand.y(forSpeed: 2, in: area) < area.midY && SpeedBand.y(forSpeed: 0.5, in: area) > area.midY)
        #expect(abs((SpeedBand.y(forSpeed: 4, in: area) - area.midY) + (SpeedBand.y(forSpeed: 0.25, in: area) - area.midY)) < 1e-9)
        for s in [0.1, 0.5, 1.0, 2.5, 8.0] {
            #expect(abs(SpeedBand.speed(forY: SpeedBand.y(forSpeed: s, in: area), in: area) - s) < 1e-9)
        }
        #expect(SpeedBand.snappedPercent(213, steps: true) == 215 && SpeedBand.snappedPercent(213.4, steps: false) == 213)
    }

    @Test func splitKeyShowsTwoHalvesAndTheTransitionSpan() throws {
        let k = try #require(SpeedKeys(segments: [seg(60, 100), seg(60, 300)], origin: .zero)
            .splittingKey(atBoundary: 1, takeLeft: f(5), takeRight: f(15), frameDuration: fd))
        let marks = SpeedBand.keyMarks(keys: k, clipStart: .zero, x: x)
        #expect(marks.count == 2 && marks.allSatisfy(\.isHalf) && marks[0].isLeftHalf == true && marks[1].isLeftHalf == false)
        #expect(marks[0].x == x(f(55)) && marks[1].x == x(f(75)))
        let ramps = SpeedBand.rampMarks(keys: k, clipStart: .zero, lane: lane, x: x)
        #expect(ramps.count == 1 && ramps[0].x0 == x(f(55)) && ramps[0].x1 == x(f(75)))
    }

    @Test func rampHandleSitsInTheMiddleAtTheMiddleSpeed() throws {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 100, 400), seg(30, 400)], origin: .zero)
        let r = try #require(SpeedBand.rampMarks(keys: k, clipStart: .zero, lane: lane, x: x).first)
        #expect(r.segment == 1 && r.handle.x == (x(f(30)) + x(f(60))) / 2)
        let area = SpeedBand.lineArea(in: lane)
        #expect(abs(r.handle.y - SpeedBand.y(forSpeed: 2.5, in: area)) < 1e-9)         // linear speed ramp: (1 + 4) / 2 at the centre
    }

    @Test func hitTestingFindsKeysRampsHandlesAndSegments() {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 100, 400), seg(30, 400)], origin: .zero)
        let strip = SpeedBand.strip(in: lane), area = SpeedBand.lineArea(in: lane)
        func hit(_ p: CGPoint) -> SpeedBand.Hit? { SpeedBand.hit(keys: k, clipStart: .zero, lane: lane, at: p, x: x) }
        #expect(hit(CGPoint(x: x(f(30)), y: strip.midY)) == .key(1))
        #expect(hit(CGPoint(x: x(f(60)), y: strip.midY)) == .key(2))
        #expect(hit(CGPoint(x: x(f(45)), y: strip.midY)) == .ramp(1))
        let r = SpeedBand.rampMarks(keys: k, clipStart: .zero, lane: lane, x: x)[0]
        #expect(hit(r.handle) == .rampHandle(1))
        #expect(hit(CGPoint(x: x(f(10)), y: SpeedBand.y(forSpeed: 1, in: area))) == .segment(0))
        #expect(hit(CGPoint(x: x(f(80)), y: SpeedBand.y(forSpeed: 4, in: area))) == .segment(2))
        #expect(hit(CGPoint(x: x(f(10)), y: area.maxY - 1)) == nil)
    }

    private func gesture(_ k: SpeedKeys, hit: SpeedBand.Hit?, at start: CGPoint, addKey: Bool = false, option: Bool = false,
                         shift: Bool = false) -> SpeedBand.Gesture {
        SpeedBand.Gesture(keys: k, clipStart: .zero, hit: hit, start: start, lane: lane, frameDuration: fd,
                          addKey: addKey, option: option, shift: shift, timeAt: timeAt)
    }

    @Test func draggingASegmentChangesItsSpeedAndTheClipLength() {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 100)], origin: .zero)
        let area = SpeedBand.lineArea(in: lane)
        let g = gesture(k, hit: .segment(1), at: CGPoint(x: x(f(45)), y: SpeedBand.y(forSpeed: 1, in: area)))
        let up = g.update(to: CGPoint(x: x(f(45)), y: SpeedBand.y(forSpeed: 2, in: area)))
        #expect(up.segments.count == 2 && up.segments[1].from == pct(200) && up.duration == f(45))
        #expect(up.endPosition == k.endPosition)                                      // same source, shorter clip
        // overshoot and come back: computed from the original every time
        _ = g.update(to: CGPoint(x: x(f(45)), y: SpeedBand.y(forSpeed: 8, in: area)))
        #expect(g.update(to: CGPoint(x: x(f(45)), y: SpeedBand.y(forSpeed: 1, in: area))).duration == k.duration)
        #expect(g.tooltip(at: CGPoint(x: 0, y: SpeedBand.y(forSpeed: 2, in: area))) == "Speed 200%")
    }

    @Test func cmdClickAddsAKeyWithoutChangingTheMapping() {
        let k = SpeedKeys(segments: [seg(60, 150)], origin: f(7))
        let g = gesture(k, hit: .segment(0), at: CGPoint(x: x(f(20)), y: 120), addKey: true)
        let n = g.update(to: CGPoint(x: x(f(50)), y: 90))                     // drag after Cmd-click does nothing more
        #expect(n.segments.count == 2 && n.boundaries[1] == f(20))
        for i in stride(from: 0 as Int64, through: 60, by: 6) { #expect(n.position(at: f(i)) == k.position(at: f(i))) }
    }

    @Test func draggingTheHalvesOpensAndMovesATransition() throws {
        let k = SpeedKeys(segments: [seg(60, 100), seg(60, 300)], origin: .zero)
        // right half to the right: transition starts at the key, 10 frames wide
        let open = gesture(k, hit: .key(1), at: CGPoint(x: x(f(60)), y: lane.minY + 3)).update(to: CGPoint(x: x(f(70)), y: lane.minY + 3))
        #expect(open.segments.map(\.duration) == [f(60), f(10), f(50)] && open.segments[1].isRamp)
        // left half to the left: transition ends at the key
        let openL = gesture(k, hit: .key(1), at: CGPoint(x: x(f(60)), y: lane.minY + 3)).update(to: CGPoint(x: x(f(52)), y: lane.minY + 3))
        #expect(openL.segments.map(\.duration) == [f(52), f(8), f(60)])
        // drag the right half further: the ramp edge moves
        let wider = gesture(open, hit: .key(2), at: CGPoint(x: x(f(70)), y: lane.minY + 3)).update(to: CGPoint(x: x(f(80)), y: lane.minY + 3))
        #expect(wider.segments.map(\.duration) == [f(60), f(20), f(40)])
        // move the whole transition
        let moved = gesture(open, hit: .ramp(1), at: CGPoint(x: x(f(65)), y: lane.minY + 3)).update(to: CGPoint(x: x(f(75)), y: lane.minY + 3))
        #expect(moved.segments.map(\.duration) == [f(70), f(10), f(40)] && moved.duration == open.duration)
        // handle widens symmetrically
        let h = SpeedBand.rampMarks(keys: open, clipStart: .zero, lane: lane, x: x)[0].handle
        let widened = gesture(open, hit: .rampHandle(1), at: h).update(to: CGPoint(x: h.x + 15, y: h.y))
        #expect(widened.segments[1].duration > open.segments[1].duration)
        // Option-drag moves an unsplit key
        let m = gesture(k, hit: .key(1), at: CGPoint(x: x(f(60)), y: lane.minY + 3), option: true).update(to: CGPoint(x: x(f(70)), y: lane.minY + 3))
        #expect(m.segments.map(\.duration) == [f(70), f(50)])
    }

    @Test func deleteRemovesAKeyOrATransition() throws {
        let k = SpeedKeys(segments: [seg(60, 100), seg(60, 300)], origin: .zero)
        let split = try #require(k.splittingKey(atBoundary: 1, half: f(5), frameDuration: fd))
        let reverted = try #require(SpeedBand.deleting(.key(1), from: split, frameDuration: fd))
        #expect(reverted.segments.count == 2 && !reverted.segments.contains { $0.isRamp } && reverted.duration == k.duration)
        let gone = try #require(SpeedBand.deleting(.key(1), from: k, frameDuration: fd))
        #expect(gone.segments.count == 1)
        #expect(SpeedBand.deleting(.segment(0), from: k, frameDuration: fd) == nil)
    }

    @Test func linePointsFollowTheSegments() {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 100, 400)], origin: .zero)
        let pts = SpeedBand.linePoints(keys: k, clipStart: .zero, lane: lane, x: x)
        let area = SpeedBand.lineArea(in: lane)
        #expect(pts.first == CGPoint(x: x(.zero), y: SpeedBand.y(forSpeed: 1, in: area)))
        #expect(abs(pts.last!.y - SpeedBand.y(forSpeed: 4, in: area)) < 1e-9 && pts.last!.x == x(f(60)))
        #expect(pts.count > 4)
    }
}
