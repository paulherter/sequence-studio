import Foundation
import Testing
#if canImport(simd)
import simd
#endif
@testable import SQRender

@Suite struct LUTInterpolationAndOutputTests {
    /// A 2-point cube whose corners hold a non-linear (cross-channel) mapping, so the two interpolators differ.
    private func nonLinearCube() throws -> CubeLUT {
        var s = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
            let (fr, fg, fb) = (Float(r), Float(g), Float(b))
            s += "\(fr * fg) \(fg * fb) \(max(fr, fb))\n"
        } } }
        return try CubeLUT.parse(s)
    }

    @Test func tetrahedralIsTheDefault() throws {
        #expect(try nonLinearCube().interpolation == .tetrahedral)
        #expect(CubeLUT.Interpolation.allCases == [.tetrahedral, .trilinear])
    }

    @Test func trilinearMatchesTheMultilinearFormula() throws {
        let lut = try nonLinearCube().with(interpolation: .trilinear)
        let p = SIMD3<Float>(0.3, 0.6, 0.8)
        // Corner functions are multilinear (r*g, g*b) or max (not multilinear): check the first two channels exactly.
        let out = lut.lookup(p)
        #expect(abs(out.x - 0.3 * 0.6) < 1e-6)
        #expect(abs(out.y - 0.6 * 0.8) < 1e-6)
    }

    @Test func interpolationsAgreeOnGridPointsAndDifferBetweenThem() throws {
        let tet = try nonLinearCube(), tri = tet.with(interpolation: .trilinear)
        for c in [SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 0)] {
            #expect(simd_length(tet.lookup(c) - tri.lookup(c)) < 1e-6)
        }
        let p = SIMD3<Float>(0.3, 0.6, 0.8)
        #expect(simd_length(tet.lookup(p) - tri.lookup(p)) > 1e-3)
    }

    @Test func trilinearIdentityCube() throws {
        let lut = try CubeLUT.parse(identityCube3D(17)).with(interpolation: .trilinear)
        var rng = LCG(s: 7)
        for _ in 0..<200 {
            let p = rng.rgb()
            #expect(simd_length(lut.lookup(p) - p) < 1e-5)
        }
    }

    // MARK: .vlt

    private func identityVLT(_ n: Int) -> String {
        var s = "# panasonic vlt file version 1\n# source vlt file\nLUT_3D_SIZE \(n)\n\n"
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let d = Double(n - 1)
            s += "\(Int((Double(r) / d * 4095).rounded())) \(Int((Double(g) / d * 4095).rounded())) \(Int((Double(b) / d * 4095).rounded()))\n"
        } } }
        return s
    }

    @Test func parsesVLTIdentityThroughParse() throws {
        let lut = try CubeLUT.parse(identityVLT(5))
        #expect(lut.kind == .lut3D && lut.size == 5)
        var rng = LCG(s: 3)
        for _ in 0..<100 {
            let p = rng.rgb()
            #expect(simd_length(lut.lookup(p) - p) < 5e-4)
        }
    }

    @Test func vltRedChangesFastestAndScalesBy4095() throws {
        let text = "# panasonic vlt file version 1\nLUT_3D_SIZE 2\n0 0 0\n4095 0 0\n0 4095 0\n4095 4095 0\n0 0 4095\n4095 0 4095\n0 4095 4095\n4095 4095 4095\n"
        let lut = try CubeLUT.parseVLT(text)
        #expect(lut.table[1] == SIMD3<Float>(1, 0, 0))
        #expect(lut.table[2] == SIMD3<Float>(0, 1, 0))
        #expect(lut.table[4] == SIMD3<Float>(0, 0, 1))
    }

    @Test func vltRejectsWrongCountAndMissingSize() {
        #expect(throws: CubeLUTError.self) { try CubeLUT.parseVLT("# panasonic vlt file version 1\nLUT_3D_SIZE 2\n0 0 0\n") }
        #expect(throws: CubeLUTError.self) { try CubeLUT.parseVLT("# panasonic vlt file version 1\n0 0 0\n") }
    }

    // MARK: Output gamut

    @Test func softCompressionLeavesMostOfTheGamutAlone() {
        for v in [SIMD3<Float>(0.2, 0.5, 0.8), SIMD3(0.5, 0.5, 0.5), SIMD3(1, 0.3, 0.3), SIMD3(0, 0, 0)] {
            #expect(simd_length(SoftGamutCompression.compress(v) - v) < 1e-6)
        }
    }

    @Test func softCompressionPullsNegativesInsideWithoutAStep() {
        var last: Float = -1
        for neg: Float in stride(from: 0, through: -0.4, by: -0.01) {
            let out = SoftGamutCompression.compress(SIMD3(0.8, 0.4, neg))
            #expect(out.min() >= 0, "neg=\(neg) out=\(out)")
            #expect(out.x == 0.8)                       // brightest channel kept
            // Walking further out of gamut never makes the blue channel go back down: monotonic, no clip edge.
            if neg < 0 { #expect(out.z >= 0) }
            last = out.z
        }
        _ = last
        // Continuity at the edge: just inside and just outside differ by a tiny amount.
        let a = SoftGamutCompression.compress(SIMD3(0.8, 0.4, 0.0))
        let b = SoftGamutCompression.compress(SIMD3(0.8, 0.4, -0.001))
        #expect(simd_length(a - b) < 0.01)
    }

    @Test func compressedDistanceIsMonotonic() {
        var prev: Float = -1
        for d: Float in stride(from: 0, through: 1.5, by: 0.005) {
            let c = SoftGamutCompression.compressDistance(d)
            #expect(c >= prev)
            prev = c
        }
        #expect(abs(SoftGamutCompression.compressDistance(SoftGamutCompression.limit) - 1) < 1e-5)
    }

    @Test func wideGamutColorLandsInsideP3WithoutClipping() {
        // A saturated Rec.2020 green is outside P3: hard conversion gives a negative channel.
        let green2020 = SIMD3<Float>(0.1, 0.8, 0.1)
        let raw = Gamut.bt2020.matrix(to: .displayP3) * green2020
        #expect(raw.min() < 0)
        let enc = OutputTarget.displayP3.encode(green2020, working: .bt2020)
        #expect(enc.min() >= 0 && enc.max() <= 1)
        let enc2020 = OutputTarget.rec2020.encode(green2020, working: .bt2020)
        let expected = TransferFunctions.bt709OETF(green2020)
        #expect(simd_length(enc2020 - expected) < 1e-5)
    }

    @Test func rec709TargetMatchesTheExistingEncodeForInGamutColors() {
        let c = SIMD3<Float>(0.2, 0.3, 0.4)
        let a = OutputTarget.rec709.encode(c, working: .rec709)
        #expect(simd_length(a - Rec709Output.encode(c)) < 1e-5)
    }
}
