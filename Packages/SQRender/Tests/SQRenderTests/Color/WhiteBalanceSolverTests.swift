import Testing
import simd
import SQCore
@testable import SQRender

/// White-balance eyedropper: temperature/tint that make a picked (working-linear) colour neutral.
@Suite struct WhiteBalanceSolverTests {
    static func wb(_ t: Float, _ n: Float) -> simd_float3x3 {
        var b = BasicCorrection(); b.temperature = t; b.tint = n
        return PreparedBasic(b, gamut: .rec709).wb
    }
    static func spread(_ v: SIMD3<Float>) -> Float { (max(v.x, v.y, v.z) - min(v.x, v.y, v.z)) / max(v.y, 1e-4) }

    @Test func neutralPickKeepsSettings() throws {
        let r = try #require(WhiteBalanceSolver.solve(picked: SIMD3(repeating: 0.4), temperature: 12, tint: -7))
        #expect(abs(r.temperature - 12) < 0.5 && abs(r.tint + 7) < 0.5)
    }

    @Test(arguments: [(30, 10), (-40, 0), (0, -25), (60, 30), (-80, -50)] as [(Float, Float)])
    func undoesAKnownCast(cast: (Float, Float)) throws {
        let grey = SIMD3<Float>(repeating: 0.35)
        let picked = Self.wb(cast.0, cast.1) * grey          // a grey wall seen through the cast
        let r = try #require(WhiteBalanceSolver.solve(picked: picked, temperature: 0, tint: 0))
        let fixed = Self.wb(r.temperature, r.tint) * picked
        #expect(Self.spread(fixed) < 0.01, "cast \(cast) -> \(r)")
        if abs(cast.0) <= 60 && abs(cast.1) <= 30 { #expect(abs(r.temperature + cast.0) < 10 && abs(r.tint + cast.1) < 10) }
    }

    @Test func resultStaysInRange() throws {
        let r = try #require(WhiteBalanceSolver.solve(picked: SIMD3(0.9, 0.2, 0.01), temperature: 90, tint: 90))
        #expect(abs(r.temperature) <= 100 && abs(r.tint) <= 100)
    }

    @Test func blackOrNonFiniteIsRejected() {
        #expect(WhiteBalanceSolver.solve(picked: .zero, temperature: 0, tint: 0) == nil)
        #expect(WhiteBalanceSolver.solve(picked: SIMD3(.nan, 1, 1), temperature: 0, tint: 0) == nil)
    }
}
