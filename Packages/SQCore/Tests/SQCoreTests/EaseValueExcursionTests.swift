import Foundation
import Testing
@testable import SQCore

/// Overshoot and wind-up of an eased segment (what the curve editor's readout shows), and the key speed a vertical
/// handle drag sets.
@Test func smoothAndSteadyCurvesStayBetweenTheirKeys() {
    for s in [EaseShape.linear, EasingCurve.easeInOut.shape, EasingCurve.fastStart.shape, .hold] {
        #expect(s.valueExcursion.below == 0 && s.valueExcursion.above == 0)
    }
}

@Test func negativeArrivalSpeedOvershootsAndNegativeStartSpeedWindsUp() {
    // Arriving from above the end value: the value passed it before.
    let over = EasingCurve.easeInOut.shape.settingSpeed(-1.2, side: .in)
    #expect(over.speedIn == -1.2 && abs(over.reachIn - 1.0 / 3) < 1e-12)
    #expect(over.valueExcursion.above > 0.02 && over.valueExcursion.below == 0)
    // Leaving backwards: wind-up.
    let wind = EasingCurve.easeInOut.shape.settingSpeed(-1.2, side: .out)
    #expect(wind.valueExcursion.below > 0.02 && wind.valueExcursion.above == 0)
    // The readout is the true extreme of the value curve.
    let s = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.2, dy: 0.9), in: EaseHandle(dx: 0.3, dy: -0.4))
    let top = (0...1000).map { KeyframeMath.bezierProgress(Double($0) / 1000, out: s.out, in: s.in) }.max()!
    #expect(abs(s.valueExcursion.above - (top - 1)) < 2e-3)
}

@Test func settingSpeedKeepsTheHandleValueInsideTheGivenRange() {
    let s = EasingCurve.easeInOut.shape
    #expect(s.settingSpeed(100, side: .out, valueRange: -2...3).out.dy == 3)
    #expect(s.settingSpeed(-100, side: .in, valueRange: -2...3).in.dy == -2)
    // A speed transition of the band stores 0...1 only: no overshoot there.
    #expect(s.settingSpeed(-1, side: .in, valueRange: 0...1).in.dy == 0)
    #expect(s.settingSpeed(.nan, side: .out, valueRange: -2...3).out.dy == 0)
    #expect(EaseShape.hold.settingSpeed(2, side: .out, valueRange: -2...3) == .hold)
}

/// A motion effect's Custom curve with overshoot survives the trip through the editor's shape unchanged.
@Test func customCurveWithOvershootRoundTripsThroughTheEditorShape() {
    let c = CubicBezierEase(x1: 0.3, y1: -0.4, x2: 0.6, y2: 1.5)
    #expect(CubicBezierEase(c.shape) == c)
    #expect(c.shape.valueExcursion.above > 0 && c.shape.valueExcursion.below > 0)
    var e = ClipEffect(kind: "motion.zoom")
    e.setCustomCurve(c)
    #expect(e.customCurve == c)
    // Changing only the reach keeps the speed at the key; changing nothing changes nothing.
    let same = c.shape.settingReach(c.shape.reachOut, side: .out).settingSpeed(c.shape.speedIn, side: .in)
    #expect(same.isApproximatelyEqual(to: c.shape, tolerance: 1e-12))
}
