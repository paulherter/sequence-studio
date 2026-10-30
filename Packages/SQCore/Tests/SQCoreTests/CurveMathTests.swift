import Testing
@testable import SQCore

/// The color curve spline lives in SQCore so every platform's renderer and curve editor share it.
@Suite struct CurveMathTests {
    @Test func passesThroughItsPointsAndStaysInRange() {
        let pts = [CurvePoint(0, 0.1), CurvePoint(0.4, 0.7), CurvePoint(1, 0.9)]
        for p in pts { #expect(abs(CurveMath.evaluate(pts, p.x) - p.y) < 1e-5) }
        for i in 0...100 { let v = CurveMath.evaluate(pts, Float(i) / 100); #expect(v >= 0 && v <= 1) }
        #expect(abs(CurveMath.evaluate([], 0.3) - 0.3) < 1e-6, "no points: the diagonal")
        #expect(CurveMath.sample(pts, 3) == [CurveMath.evaluate(pts, 0), CurveMath.evaluate(pts, 0.5), CurveMath.evaluate(pts, 1)])
    }
}
