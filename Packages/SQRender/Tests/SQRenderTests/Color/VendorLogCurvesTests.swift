import Foundation
import Testing
#if canImport(simd)
import simd
#endif
import SQCore
@testable import SQRender

/// Vendor log curves and the SQ Intermediate / SQ Wide working-space candidate.
/// Gray references (18 % scene gray -> signal): LogC3 EI800 0.391007 (ARRI), LogC4 0.278396 (ARRI), Log3G10 1/3 (RED),
/// ACEScct 0.4135884 (AMPAS), SQ Intermediate ~0.336 (the published DaVinci Intermediate constants).
/// Checked against colour-science output: Blackmagic Film Gen 5 (0.383581 here), F-Log2.
/// UNCERTAIN, flagged: the Nikon N-Log cube-root constants (650, 0.0075, 0.328 cut) and the F-Log2 18 % value 0.391
/// were written from the public spec text from memory; the gray test uses a wide tolerance for them. Re-check both
/// against a real N-Log / F-Log2 clip's 18 % card before relying on them for matching.
@Suite struct VendorLogCurvesTests {
    typealias Curve = (name: String, enc: @Sendable (Float) -> Float, dec: @Sendable (Float) -> Float, gray: Float, tol: Float)

    static let curves: [Curve] = [
        ("SQ Intermediate", TransferFunctions.sqLogEncode, TransferFunctions.sqLogDecode, 0.336, 0.002),
        ("LogC3", TransferFunctions.logC3Encode, TransferFunctions.logC3Decode, 0.391007, 1e-4),
        ("LogC4", TransferFunctions.logC4Encode, TransferFunctions.logC4Decode, 0.278396, 1e-4),
        ("Log3G10", TransferFunctions.log3G10Encode, TransferFunctions.log3G10Decode, 1.0 / 3, 1e-3),
        ("BMD Film Gen 5", TransferFunctions.bmdFilmGen5Encode, TransferFunctions.bmdFilmGen5Decode, 0.383581, 1e-3),
        ("N-Log (uncertain)", TransferFunctions.nLogEncode, TransferFunctions.nLogDecode, 372.0 / 1023, 0.003),
        ("F-Log2 (uncertain)", TransferFunctions.fLog2Encode, TransferFunctions.fLog2Decode, 0.391, 0.003),
        ("ACEScct", TransferFunctions.acesCCTEncode, TransferFunctions.acesCCTDecode, 0.4135884, 1e-4),
    ]

    @Test func encodeDecodeIsIdentity() {
        for c in Self.curves {
            for x: Float in [0, 0.0005, 0.003, 0.01, 0.05, 0.18, 0.5, 1, 4, 16, 60] {
                let back = c.dec(c.enc(x))
                #expect(abs(back - x) <= 2e-4 * max(1, x), "\(c.name) x=\(x) back=\(back)")
            }
        }
    }

    @Test func decodeEncodeIsIdentityOnSignal() {
        for c in Self.curves {
            for y: Float in stride(from: 0.02, through: 0.98, by: 0.04) {
                #expect(abs(c.enc(c.dec(y)) - y) <= 3e-4, "\(c.name) y=\(y)")
            }
        }
    }

    @Test func eighteenPercentGrayMatchesTheVendorCodeValue() {
        for c in Self.curves { #expect(abs(c.enc(0.18) - c.gray) <= c.tol, "\(c.name) gray=\(c.enc(0.18))") }
    }

    @Test func smallNegativesSurvive() {
        // N-Log is left out: its cube-root toe is defined from -0.0075 up and clamps below that.
        for c in Self.curves where !c.name.hasPrefix("N-Log") {
            for x: Float in [-0.001, -0.004] {
                #expect(abs(c.dec(c.enc(x)) - x) <= 1e-4, "\(c.name) x=\(x)")
            }
        }
        #expect(abs(TransferFunctions.nLogDecode(TransferFunctions.nLogEncode(-0.005)) + 0.005) <= 2e-4)
        #expect(TransferFunctions.sqLogDecode(TransferFunctions.sqLogEncode(-0.2)) < -0.19)
    }

    @Test func curvesAreMonotonic() {
        for c in Self.curves {
            var last = -Float.infinity
            for x: Float in stride(from: -0.003, through: 8, by: 0.01) {
                let y = c.enc(x)
                #expect(y >= last, "\(c.name) x=\(x)")
                last = y
            }
        }
    }

    @Test func legalWrappersUseTheVideoRange() {
        // The compositor hands over the range-expanded value v; the curve sees the code (v*876+64)/1023.
        let code: Float = 0.391007
        let v = (code * 1023 - 64) / 876
        #expect(abs(TransferFunctions.logC3DecodeLegal(v) - 0.18) < 2e-4)
        #expect(abs(TransferFunctions.logC3EncodeLegal(0.18) - v) < 1e-4)
    }

    // MARK: SQ Wide

    @Test func sqWideRoundTripsThroughRec709() {
        let there = Gamut.sqWide.matrix(to: .rec709), back = Gamut.rec709.matrix(to: .sqWide)
        for v in [SIMD3<Float>(0.18, 0.18, 0.18), SIMD3(0.5, 0.2, 0.1), SIMD3(-0.02, 0.4, 0.9), SIMD3(1, 0, 0)] {
            #expect(simd_length(back * (there * v) - v) < 1e-4)
        }
        // White stays white (same D65 white point, no adaptation).
        #expect(simd_length(there * SIMD3<Float>(1, 1, 1) - SIMD3<Float>(1, 1, 1)) < 1e-3)
    }

    @Test func sqWideEncodeDecodeKeepsNegativesAndGray() {
        let rgb = SIMD3<Float>(0.18, 0.18, 0.18)
        let enc = TransferFunctions.sqLogEncode(rgb)
        #expect(abs(enc.x - 0.336) < 0.002)
        let dec = TransferFunctions.sqLogDecode(enc)
        #expect(simd_length(dec - rgb) < 1e-5)
        let neg = SIMD3<Float>(-0.03, 0.2, 0.01)
        #expect(simd_length(TransferFunctions.sqLogDecode(TransferFunctions.sqLogEncode(neg)) - neg) < 1e-5)
    }

    @Test func sqIntermediateMatchesTheWhitepaperTable() {
        // Blackmagic whitepaper v1.1 reference points (docs/research/color/C2-resolve-color-deep.md, section 4).
        let table: [(Float, Float)] = [(-0.01, -0.104443), (0, 0), (0.18, 0.336043), (1, 0.513837), (10, 0.756599),
                                       (40, 0.903125), (100, 1.0)]
        for (lin, enc) in table {
            #expect(abs(TransferFunctions.sqLogEncode(lin) - enc) < 2e-6, "encode \(lin)")
            #expect(abs(TransferFunctions.sqLogDecode(enc) - lin) < 2e-4 * max(1, abs(lin)), "decode \(enc)")
        }
    }

    @Test func sqWideMatricesMatchTheWhitepaper() {
        let toXYZ: [[Double]] = [[0.70062239, 0.14877482, 0.10105872], [0.27411851, 0.87363190, -0.14775041],
                                 [-0.09896291, -0.13789533, 1.32591599]]
        let fromXYZ: [[Double]] = [[1.51667204, -0.28147805, -0.14696363], [-0.46491710, 1.25142378, 0.17488461],
                                   [0.06484905, 0.10913934, 0.76141462]]
        let m = Gamut.sqWide.rgbToXYZDouble, inv = m.inverse
        for r in 0..<3 { for c in 0..<3 {
            #expect(abs(m[c][r] - toXYZ[r][c]) < 2e-4, "rgbToXYZ \(r),\(c)")
            #expect(abs(inv[c][r] - fromXYZ[r][c]) < 2e-4, "xyzToRGB \(r),\(c)")
        } }
    }

    // MARK: Input spaces

    @Test func everyColorSpaceIDMapsToARenderSpace() {
        for id in ColorSpaceID.allCases { _ = SourceColorSpace(id) }
        #expect(ColorSpaceID.allCases.count == SourceColorSpace.allCases.count)
    }

    @Test func eachVendorSpaceDecodesGrayToNeutral() {
        let pairs: [(SourceColorSpace, Float)] = [
            (.logC3WideGamut3, 0.391007), (.logC4WideGamut4, 0.278396), (.log3G10RedWideGamut, 1.0 / 3),
            (.bmdFilmGen5WideGamut, 0.383581), (.acesCCTAP1, 0.4135884),
        ]
        for (space, code) in pairs {
            // Legal-range wrappers expect legal-range values for the 10-bit curves.
            let legal = (code * 1023 - 64) / 876
            let input: Float = [.log3G10RedWideGamut, .acesCCTAP1].contains(space) ? code : legal
            let lin = space.decode(SIMD3(repeating: input))
            #expect(abs(lin.x - 0.18) < 2e-3 && abs(lin.x - lin.y) < 1e-6 && abs(lin.y - lin.z) < 1e-6, "\(space)")
            let back = space.encode(lin)
            #expect(abs(back.x - input) < 2e-4, "\(space)")
        }
    }

    @Test func vendorGamutWhitesAreNeutralInD65() {
        for g in [Gamut.sqWide, .displayP3, .arriWideGamut3, .arriWideGamut4, .redWideGamutRGB, .blackmagicWideGamut,
                  .fGamutC, .acesAP1] {
            let w = g.matrix(to: .rec709) * SIMD3<Float>(1, 1, 1)
            #expect(abs(w.x - w.y) < 2e-3 && abs(w.y - w.z) < 2e-3, "white \(w)")
        }
    }
}
