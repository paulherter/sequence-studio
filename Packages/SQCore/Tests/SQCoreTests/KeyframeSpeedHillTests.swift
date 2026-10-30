import Foundation
import Testing
@testable import SQCore

private func smooth(_ r: Double) -> EaseShape {
    EaseShape(interpolation: .bezier, out: EaseHandle(dx: r, dy: 0), in: EaseHandle(dx: r, dy: 0))
}

// MARK: Speed at a key

@Test func speedHillSmoothKeyHasSpeedZero() {
    let s = smooth(0.33)
    #expect(s.speedOut == 0)
    #expect(s.speedIn == 0)
    let pts = SpeedHill.samples(s)
    #expect(abs(pts.first!.speed) < 1e-9)
    #expect(abs(pts.last!.speed) < 1e-9)
    #expect(pts.first!.x == 0)
    #expect(pts.last!.x == 1)
}

@Test func speedHillSteadySegmentIsFlatAtOne() {
    #expect(EaseShape.linear.speedOut == 1)
    #expect(EaseShape.linear.speedIn == 1)
    for p in SpeedHill.samples(.linear) { #expect(abs(p.speed - 1) < 1e-9) }
}

@Test func speedHillHoldHasNoSpeed() {
    #expect(EaseShape.hold.speedOut == 0)
    #expect(EaseShape.hold.speedIn == 0)
    for p in SpeedHill.samples(.hold) { #expect(p.speed == 0) }
}

@Test func speedHillKeySpeedIsTheHandleSlope() {
    let s = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: 0.5), in: EaseHandle(dx: 0.4, dy: 0.1))
    #expect(abs(s.speedOut - 2.5) < 1e-9)
    #expect(abs(s.speedIn - 0.25) < 1e-9)
    let pts = SpeedHill.samples(s)
    #expect(abs(pts.first!.speed - 2.5) < 1e-6)
    #expect(abs(pts.last!.speed - 0.25) < 1e-6)
}

// MARK: Peak and area

@Test func speedHillPeakForReach33Is149TimesAverage() {
    #expect(abs(SpeedHill.peak(smooth(0.33)) - 1.0 / 0.67) < 1e-3)
    #expect(abs(SpeedHill.peak(smooth(0.33)) - 1.49) < 0.005)
    // The peak sits in the middle of the segment.
    let top = SpeedHill.samples(smooth(0.33), count: 49).max { $0.speed < $1.speed }!
    #expect(abs(top.x - 0.5) < 1e-9)
}

@Test func speedHillLongerReachGivesAHigherHill() {
    #expect(SpeedHill.peak(smooth(0.15)) < SpeedHill.peak(smooth(0.33)))
    #expect(abs(SpeedHill.peak(smooth(0.15)) - 1.0 / 0.85) < 1e-3)
}

@Test func speedHillAreaIsTheValueDelta() {
    // Normalized: the area under the hill is 1 (the whole way from the left value to the right value).
    for s in [smooth(0.33), smooth(0.15), EaseShape.linear,
              EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: 0.5), in: EaseHandle(dx: 0.4, dy: 0.1)),
              EasingCurve.easeIn.shape, EasingCurve.easeOut.shape] {
        #expect(abs(SpeedHill.area(SpeedHill.samples(s, count: 400)) - 1) < 2e-3)
    }
    #expect(SpeedHill.area(SpeedHill.samples(.hold)) == 0)
}

@Test func speedHillMatchesTheEvaluatedValueCurve() {
    // The hill is the derivative of what the evaluator plays: compare with central differences on a real track.
    let a = Keyframe(time: kfT(0), value: 0.0, interpolation: .bezier, outHandle: EaseHandle(dx: 0.33, dy: 0))
    let b = Keyframe(time: kfT(2), value: 10.0, inHandle: EaseHandle(dx: 0.33, dy: 0))
    let shape = smooth(0.33)
    for p in SpeedHill.samples(shape, count: 21) where p.x > 0.05 && p.x < 0.95 {
        let h = 1e-5
        let numeric = (KeyframeTrack.segmentValue(a, b, p.x + h) - KeyframeTrack.segmentValue(a, b, p.x - h)) / (2 * h) / 10
        #expect(abs(numeric - p.speed) < 1e-3)
    }
}

// MARK: Reach and speed edits

@Test func speedHillSettingReachKeepsTheKeySpeed() {
    let s = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: 0.5), in: EaseHandle(dx: 0.4, dy: 0.1))
    let longer = s.settingReach(0.4, side: .out)
    #expect(abs(longer.reachOut - 0.4) < 1e-9)
    #expect(abs(longer.speedOut - 2.5) < 1e-9)
    #expect(longer.in == s.in)
    let inSide = s.settingReach(0.1, side: .in)
    #expect(abs(inSide.reachIn - 0.1) < 1e-9)
    #expect(abs(inSide.speedIn - 0.25) < 1e-9)
    #expect(inSide.out == s.out)
}

/// Regression guard (Premiere semantics, feedback 2026-10-05): each handle's influence runs 0...100 % on its own, whatever
/// the other handle of the segment has. The old cross clamp (`1 - other reach`) made a Smooth handle stop at 67 %.
/// The bezier stays a function of time for any x1, x2 in 0...1, so both sides at 100 % play fine.
@Test func speedHillReachIsIndependentPerSideUpToFullInfluence() {
    let s = smooth(0.33)
    #expect(s.settingReach(0.9, side: .out).reachOut == 0.9)
    #expect(s.settingReach(1, side: .out).reachOut == 1)
    #expect(s.settingReach(5, side: .in).reachIn == 1)
    #expect(abs(s.settingReach(-1, side: .out).reachOut - SpeedHill.minReach) < 1e-9)
    let both = s.settingReach(2, side: .both)
    #expect(both.reachOut == 1 && both.reachIn == 1)
    // Both at 100 %: still a valid ease (starts and ends at rest, covers the whole value delta).
    let samples = SpeedHill.samples(both, count: 201)
    #expect(abs(samples.first!.speed) < 1e-9 && abs(samples.last!.speed) < 1e-9)
    #expect(abs(SpeedHill.area(samples) - 1) < 0.01)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0.x <= $1.x })
}

@Test func speedHillSettingReachOnSteadyKeepsTheMotion() {
    let s = EaseShape.linear.settingReach(0.5, side: .out)
    #expect(s.interpolation == .bezier)
    #expect(abs(s.speedOut - 1) < 1e-9)
    for p in SpeedHill.samples(s) { #expect(abs(p.speed - 1) < 1e-6) }
}

@Test func speedHillSettingSpeedKeepsTheReach() {
    let s = smooth(0.33).settingSpeed(2, side: .out)
    #expect(abs(s.reachOut - 0.33) < 1e-9)
    #expect(abs(s.speedOut - 2) < 1e-9)
    #expect(s.speedIn == 0)
    #expect(EaseShape.hold.settingSpeed(2, side: .out) == .hold)
    #expect(EaseShape.hold.settingReach(0.2, side: .out) == .hold)
}

// MARK: Selection

@Test func speedHillTransformWritesEverySelectedSegmentWithItsOwnShape() {
    let pos = [Keyframe(time: kfT(0), value: Vec2(0, 0)), Keyframe(time: kfT(2), value: Vec2(50, 50))]
    let scale = [kfKey(0, 100), kfKey(2, 120)]
    var sum = KeyframeSummary(tracks: ["position": .vector(KeyframeTrack(keys: pos)), "scale": .scalar(KeyframeTrack(keys: scale))])
    let members: Set<SummaryMember> = [SummaryMember(property: "position", keyID: pos[0].id), SummaryMember(property: "position", keyID: pos[1].id),
                                       SummaryMember(property: "scale", keyID: scale[0].id), SummaryMember(property: "scale", keyID: scale[1].id)]
    let sel = EaseSelection(summary: sum, members: members)
    sel.apply(smooth(0.33), to: &sum)
    // Only Scale's out reach changes; Position keeps its own shape.
    let n = sel.transform(in: &sum) { seg, shape in seg.property == "scale" ? shape.settingReach(0.15, side: .out) : shape }
    #expect(n == 2)
    let shapes = sel.shapes(in: sum)
    #expect(shapes.count == 2)
    #expect(abs(shapes.first { $0.segment.property == "scale" }!.shape.reachOut - 0.15) < 1e-9)
    #expect(abs(shapes.first { $0.segment.property == "position" }!.shape.reachOut - 0.33) < 1e-9)
}

@Test func speedHillTrackSegmentsListEverySegmentInOrder() {
    let keys = [kfKey(0, 0), kfKey(2, 10), kfKey(4, 0)]
    var t = PropertyTrack.scalar(KeyframeTrack(keys: keys))
    t.apply(.easeInOut, to: [keys[0].id, keys[1].id])
    let segs = t.easeSegments
    #expect(segs.count == 2)
    #expect(segs[0].from == keys[0].id && segs[0].to == keys[1].id)
    #expect(segs[0].start == kfT(0) && segs[0].end == kfT(2))
    #expect(segs[0].shape.speedOut == 0)
    #expect(segs[1].start == kfT(2) && segs[1].end == kfT(4))
}

// MARK: Shared vertical scale of a row (speed = value change per second)

private func scaledSegments(_ keys: [Keyframe<Double>]) -> [EaseTrackSegment] {
    var t = PropertyTrack.scalar(KeyframeTrack(keys: keys))
    t.apply(.easeInOut, to: Set(keys.map(\.id)))
    return t.easeSegments
}

@Test func speedScaleEqualKeysDrawFlatAtZero() {
    let segs = scaledSegments([kfKey(0, 55), kfKey(2, 50), kfKey(6, 50), kfKey(8, 55)])
    #expect(segs[1].scale == 0)
    #expect(segs[0].scale > 0 && segs[2].scale > 0)
}

@Test func speedScaleDoublingTheChangeDoublesThePeak() {
    let segs = scaledSegments([kfKey(0, 0), kfKey(2, 10), kfKey(4, 30)])
    #expect(abs(segs[1].scale - 1) < 1e-12 && abs(segs[0].scale - 0.5) < 1e-12)
    let peak0 = SpeedHill.peak(segs[0].shape) * segs[0].scale
    let peak1 = SpeedHill.peak(segs[1].shape) * segs[1].scale
    #expect(abs(peak1 - 2 * peak0) < 1e-9)
}

@Test func speedScaleIsValueChangePerSecond() {
    // same change over double the time = half the speed
    let segs = scaledSegments([kfKey(0, 0), kfKey(2, 10), kfKey(6, 20)])
    #expect(abs(segs[1].scale - 0.5) < 1e-12)
}

@Test func renderedValueBetweenEqualKeysIsConstant() {
    var keys = [kfKey(0, 50), kfKey(4, 50)]
    keys[0].interpolation = .bezier
    keys[0].outHandle = EaseHandle(dx: 0.9, dy: 3)       // wild ease: would overshoot a changing value
    keys[1].inHandle = EaseHandle(dx: 0.9, dy: -3)
    let t = KeyframeTrack(keys: keys)
    for s in stride(from: 0, through: 4, by: 1) { #expect(t.value(at: Time(Int64(s * 100) + 0, 100)) == 50) }
}
