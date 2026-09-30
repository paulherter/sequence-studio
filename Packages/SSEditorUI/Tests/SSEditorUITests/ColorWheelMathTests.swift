import Foundation
import Testing
@testable import SSEditorUI

@Suite struct ColorWheelMathTests {
    private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

    @Test func polarCardinalDirections() {
        let r = ColorWheelMath.value(dx: 50, dy: 0, radius: 100)
        #expect(near(r.hue, 0) && near(r.amount, 0.5))
        let u = ColorWheelMath.value(dx: 0, dy: 100, radius: 100)   // y up
        #expect(near(u.hue, 90) && near(u.amount, 1))
        let l = ColorWheelMath.value(dx: -100, dy: 0, radius: 100)
        #expect(near(l.hue, 180))
        let d = ColorWheelMath.value(dx: 0, dy: -10, radius: 100)
        #expect(near(d.hue, 270) && near(d.amount, 0.1))
    }

    @Test func clampsToDisc() {
        let v = ColorWheelMath.value(dx: 300, dy: 400, radius: 100)
        #expect(near(v.amount, 1))
        #expect(near(v.hue, atan2(4.0, 3.0) * 180 / .pi))
        let o = ColorWheelMath.offset(of: .init(hue: 45, amount: 5), radius: 10)
        #expect(near(hypot(o.dx, o.dy), 10))
    }

    @Test func roundTrip() {
        for (h, a) in [(0.0, 0.3), (33.0, 0.8), (200.0, 0.55), (359.0, 1.0)] {
            let o = ColorWheelMath.offset(of: .init(hue: h, amount: a), radius: 80)
            let v = ColorWheelMath.value(dx: o.dx, dy: o.dy, radius: 80)
            #expect(near(v.hue, h, 1e-6) && near(v.amount, a, 1e-9))
        }
    }

    @Test func centerHasZeroAmountAndStableHue() {
        let v = ColorWheelMath.value(dx: 0, dy: 0, radius: 100)
        #expect(v.amount == 0 && v.hue == 0)
        #expect(ColorWheelMath.value(dx: 1, dy: 1, radius: 0).amount == 0)
    }

    @Test func resetIsNeutral() {
        #expect(ColorWheelMath.reset == ColorWheelMath.Value(hue: 0, amount: 0))
        #expect(ColorWheelMath.reset.isNeutral)
        #expect(!ColorWheelMath.Value(hue: 10, amount: 0.1).isNeutral)
    }

    @Test func absoluteDragFollowsPointer() {
        let v = ColorWheelMath.drag(start: .init(hue: 0, amount: 0), startPoint: (0, 0), point: (0, 50), radius: 100, fine: false)
        #expect(near(v.hue, 90) && near(v.amount, 0.5))
    }

    @Test func fineDragMovesSlowlyFromStart() {
        let start = ColorWheelMath.Value(hue: 0, amount: 0.5)   // offset (50, 0)
        let v = ColorWheelMath.drag(start: start, startPoint: (50, 0), point: (60, 0), radius: 100, fine: true)
        #expect(near(v.hue, 0) && near(v.amount, 0.5 + 10 * ColorWheelMath.fineFactor / 100, 1e-9))
        let clamped = ColorWheelMath.drag(start: start, startPoint: (50, 0), point: (5000, 0), radius: 100, fine: true)
        #expect(clamped.amount == 1)
    }

    @Test func masterSliderMapping() {
        #expect(near(ColorWheelMath.master(forY: 0, height: 100), 1))
        #expect(near(ColorWheelMath.master(forY: 50, height: 100), 0))
        #expect(near(ColorWheelMath.master(forY: 100, height: 100), -1))
        #expect(ColorWheelMath.master(forY: -40, height: 100) == 1)
        #expect(ColorWheelMath.master(forY: 500, height: 100) == -1)
        #expect(near(ColorWheelMath.y(forMaster: 0.5, height: 100), 25))
    }
}
