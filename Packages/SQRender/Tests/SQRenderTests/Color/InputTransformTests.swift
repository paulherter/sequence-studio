import Foundation
import Testing
#if canImport(simd)
import simd
#endif
import SQCore
@testable import SQRender

/// W9.3: input transforms (S-Log3, V-Log, Apple Log, D-Log, PQ, HLG) against independent Double references of the
/// published formulas (Sony S-Log3 tech summary, Panasonic V-Log/V-Gamut reference manual, Apple Log profile white
/// paper, DJI D-Log/D-Gamut white paper, SMPTE ST 2084). Chart: camera-encoded 10-bit legal-range patches, decoded by
/// the pipeline and compared with the scene values in CIELAB (ΔE76, stricter than ΔE2000 here), all < 2.
@Suite struct InputTransformTests {
    // MARK: Independent references (Double)

    enum Ref {
        static func slog3Encode(_ x: Double) -> Double {   // CV / 1023
            x >= 0.01125 ? (420 + log10((x + 0.01) / 0.19) * 261.5) / 1023 : (x * (171.2102946929 - 95) / 0.01125 + 95) / 1023
        }
        static func vlogEncode(_ x: Double) -> Double {    // CV / 1023
            x < 0.01 ? 5.6 * x + 0.125 : 0.241514 * log10(x + 0.00873) + 0.598206
        }
        static func dlogEncode(_ x: Double) -> Double {    // CV / 1023
            x <= 0.0078 ? 6.025 * x + 0.0929 : log10(x * 0.9892 + 0.0108) * 0.256663 + 0.584555
        }
        // Canon white paper "Canon Log Gamma Curves" (code-value form): input = reflection / 0.9, output = CV / 1023.
        static func canonLogEncode(_ r: Double) -> Double {
            let x = r / 0.9
            return x < 0 ? -(0.45310179 * log10(-x * 10.1596 + 1) - 0.12512248) : 0.45310179 * log10(10.1596 * x + 1) + 0.12512248
        }
        static func canonLog2Encode(_ r: Double) -> Double {
            let x = r / 0.9
            return x < 0 ? -(0.24136077 * log10(-x * 87.09937546 + 1) - 0.092864125)
                         : 0.24136077 * log10(x * 87.09937546 + 1) + 0.092864125
        }
        static func canonLog3Encode(_ r: Double) -> Double {
            let x = r / 0.9
            if x < -0.014 { return -0.36726845 * log10(-x * 14.98325 + 1) + 0.12783901 }
            if x <= 0.014 { return 1.9754798 * x + 0.12512219 }
            return 0.36726845 * log10(x * 14.98325 + 1) + 0.12240537
        }
        static func appleLogEncode(_ x: Double) -> Double { // normalized signal (video range applied by the codec)
            let r0 = -0.05641088, rt = 0.01, c = 47.28711236, b = 0.00964052, g = 0.08550479, d = 0.69336945
            if x >= rt { return g * log2(x + b) + d }
            if x >= r0 { return c * (x - r0) * (x - r0) }
            return 0
        }
        static func pqEncode(nits: Double) -> Double {
            let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
            let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
            let y = pow(max(nits, 0) / 10000, m1)
            return pow((c1 + c2 * y) / (1 + c3 * y), m2)
        }

        /// RGB -> XYZ from xy primaries (D65 white).
        static func rgbToXYZ(_ r: SIMD2<Double>, _ g: SIMD2<Double>, _ b: SIMD2<Double>) -> simd_double3x3 {
            func xyz(_ p: SIMD2<Double>) -> SIMD3<Double> { SIMD3(p.x / p.y, 1, (1 - p.x - p.y) / p.y) }
            let m = simd_double3x3(columns: (xyz(r), xyz(g), xyz(b)))
            let s = m.inverse * xyz(SIMD2(0.3127, 0.3290))
            return m * simd_double3x3(diagonal: s)
        }
        static let rec709 = rgbToXYZ([0.64, 0.33], [0.30, 0.60], [0.15, 0.06])
        static let bt2020 = rgbToXYZ([0.708, 0.292], [0.170, 0.797], [0.131, 0.046])
        static let sGamut3Cine = rgbToXYZ([0.766, 0.275], [0.225, 0.800], [0.089, -0.087])
        static let vGamut = rgbToXYZ([0.730, 0.280], [0.165, 0.840], [0.100, -0.030])
        static let dGamut = rgbToXYZ([0.71, 0.31], [0.21, 0.88], [0.09, -0.08])
        static let cinemaGamut = rgbToXYZ([0.740, 0.270], [0.170, 1.140], [0.080, -0.100])

        /// XYZ (white Y = 1) -> CIELAB, D65.
        static func lab(_ xyz: SIMD3<Double>) -> SIMD3<Double> {
            let w = SIMD3<Double>(0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290)
            func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
            let fx = f(xyz.x / w.x), fy = f(xyz.y / w.y), fz = f(xyz.z / w.z)
            return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
        }
    }

    /// Full-range code fraction (CV/1023) -> 10-bit legal code -> range-expanded value the compositor delivers.
    static func legalFromCode(_ cv: Double) -> Float { Float((cv * 1023 - 64).rounded() / 876) }
    /// Normalized signal stored video range (10 bit) -> range-expanded value.
    static func legalFromSignal(_ e: Double) -> Float { Float(((e * 876).rounded()) / 876) }

    // MARK: Published points

    @Test func publishedCodeValues() {
        typealias T = TransferFunctions
        func legal(_ cv: Float) -> Float { (cv - 64) / 876 }
        // Sony: 0 % = 95, 18 % = 420, 90 % = 598 (10 bit).
        #expect(abs(T.slog3DecodeLegal(legal(420)) - 0.18) < 1e-4)
        #expect(abs(T.slog3DecodeLegal(legal(598)) - 0.90) < 4e-3)
        // Panasonic V-Log: 0 % = 128, 18 % = 433, 90 % = 602.
        #expect(abs(T.vlogDecodeLegal(legal(128))) < 1e-3)
        #expect(abs(T.vlogDecodeLegal(legal(433)) - 0.18) < 1e-3)
        #expect(abs(T.vlogDecodeLegal(legal(602)) - 0.90) < 6e-3)
        // DJI D-Log: 0 % at 0.0929, 18 % at 0.3988.
        #expect(abs(T.dlogDecode(0.0929)) < 1e-5)
        #expect(abs(T.dlogDecode(0.39877) - 0.18) < 1e-4)
        // Apple Log: 18 % gray at 0.4883, 0 at Pt = c (0 - R0)^2.
        #expect(abs(T.appleLogDecode(0.48827) - 0.18) < 1e-4)
        #expect(abs(T.appleLogDecode(47.28711236 * 0.05641088 * 0.05641088)) < 1e-5)
        // PQ: 100 nits = 0.5081, 203 nits (reference white = 1.0) = 0.5806, 1000 = 0.7518, 10000 = 1.
        #expect(abs(T.pqDecode(0.50808) * 203 - 100) < 0.1)
        #expect(abs(T.pqDecode(0.58069) - 1) < 1e-3)
        #expect(abs(T.pqDecode(0.75183) * 203 - 1000) < 1)
        #expect(abs(T.pqDecode(1) * 203 - 10000) < 5)
        #expect(T.pqDecode(0) == 0)
    }

    /// F7.2: Canon's published 10-bit code values (0 % black, 18 % gray, 90 % white) and the exact curve values.
    @Test func canonPublishedCodeValues() {
        typealias T = TransferFunctions
        func legal(_ cv: Float) -> Float { (cv - 64) / 876 }
        // Canon Log: 0 % = 128 (7.3 IRE), 18 % = 351 (32.8 IRE), 90 % = 614 (62.7 IRE).
        #expect(abs(T.canonLogDecodeLegal(legal(128))) < 1e-3)
        #expect(abs(T.canonLogDecodeLegal(legal(351)) - 0.18) < 1e-3)
        #expect(abs(T.canonLogDecodeLegal(legal(614)) - 0.90) < 6e-3)
        // Canon Log 2: 0 % = 95 (3.5 IRE), 18 % = 407 (39.2 IRE), 90 % = 575 (58.4 IRE).
        #expect(abs(T.canonLog2DecodeLegal(legal(95))) < 1e-3)
        #expect(abs(T.canonLog2DecodeLegal(legal(407)) - 0.18) < 2e-3)
        #expect(abs(T.canonLog2DecodeLegal(legal(575)) - 0.90) < 6e-3)
        // Canon Log 3: 0 % = 128 (7.3 IRE), 18 % = 351 (32.8 IRE), 90 % = 577 (58.6 IRE).
        #expect(abs(T.canonLog3DecodeLegal(legal(128))) < 1e-3)
        #expect(abs(T.canonLog3DecodeLegal(legal(351)) - 0.18) < 1e-3)
        #expect(abs(T.canonLog3DecodeLegal(legal(577)) - 0.90) < 6e-3)
        // Exact curve values for 18 % gray (percent of full scale): 34.3389649, 39.8254692, 34.3389370.
        #expect(abs(T.canonLogEncode(0.18) - 0.343389649) < 2e-6)
        #expect(abs(T.canonLog2Encode(0.18) - 0.398254692) < 2e-6)
        #expect(abs(T.canonLog3Encode(0.18) - 0.343389370) < 2e-6)
        #expect(abs(T.canonLogDecode(0.343389649) - 0.18) < 1e-5)
        #expect(abs(T.canonLog2Decode(0.398254692) - 0.18) < 1e-5)
        #expect(abs(T.canonLog3Decode(0.343389370) - 0.18) < 1e-5)
        // IRE positions Canon quotes: (CV - 64) / 876.
        #expect(abs(Double(T.codeFractionToLegal(T.canonLogEncode(0.18))) - 0.328) < 1e-3)
        #expect(abs(Double(T.codeFractionToLegal(T.canonLogEncode(0.90))) - 0.627) < 1e-3)
        #expect(abs(Double(T.codeFractionToLegal(T.canonLog2Encode(0.18))) - 0.392) < 1e-3)
        #expect(abs(Double(T.codeFractionToLegal(T.canonLog2Encode(0.90))) - 0.584) < 1e-3)
        #expect(abs(Double(T.codeFractionToLegal(T.canonLog3Encode(0.18))) - 0.328) < 1e-3)
        #expect(abs(Double(T.codeFractionToLegal(T.canonLog3Encode(0.90))) - 0.586) < 1e-3)
    }

    @Test func canonCurvesMatchTheDoubleReferenceRoundTripAndAreContinuous() {
        typealias T = TransferFunctions
        let curves: [(String, (Float) -> Float, (Float) -> Float, (Double) -> Double)] = [
            ("canon log", T.canonLogEncode, T.canonLogDecode, Ref.canonLogEncode),
            ("canon log 2", T.canonLog2Encode, T.canonLog2Decode, Ref.canonLog2Encode),
            ("canon log 3", T.canonLog3Encode, T.canonLog3Decode, Ref.canonLog3Encode),
        ]
        for (name, enc, dec, ref) in curves {
            // Below black (sensor noise), the toe and up to far above white.
            var y: Float = -0.05
            while y <= 20 {
                let e = enc(y)
                #expect(abs(Double(e) - ref(Double(y))) < 2e-6, "\(name) encode y=\(y)")
                let back = dec(e)
                #expect(abs(back - y) <= 2e-4 * max(1, abs(y)), "\(name) y=\(y) back=\(back)")
                y += y < 0.05 ? 0.0005 : y < 1 ? 0.005 : 0.5
            }
            // Monotonic over the whole code range.
            var last = dec(0)
            for cv in 1...1023 { let l = dec(Float(cv) / 1023); #expect(l > last, "\(name) cv=\(cv)"); last = l }
        }
        // Legal-range forms invert each other too.
        for y: Float in [-0.01, 0, 0.18, 0.9, 4] {
            #expect(abs(T.canonLogDecodeLegal(T.canonLogEncodeLegal(y)) - y) < 2e-4 * max(1, y))
            #expect(abs(T.canonLog2DecodeLegal(T.canonLog2EncodeLegal(y)) - y) < 2e-4 * max(1, y))
            #expect(abs(T.canonLog3DecodeLegal(T.canonLog3EncodeLegal(y)) - y) < 2e-4 * max(1, y))
        }
        // No jump at black (Canon Log, Canon Log 2) and at both ends of the Canon Log 3 toe.
        #expect(abs(T.canonLogDecode(0.12512248 - 1e-6) - T.canonLogDecode(0.12512248 + 1e-6)) < 1e-5)
        #expect(abs(T.canonLog2Decode(0.092864125 - 1e-6) - T.canonLog2Decode(0.092864125 + 1e-6)) < 1e-5)
        #expect(abs(T.canonLog3Decode(0.097465473 - 1e-6) - T.canonLog3Decode(0.097465473 + 1e-6)) < 1e-5)
        #expect(abs(T.canonLog3Decode(0.15277891 - 1e-6) - T.canonLog3Decode(0.15277891 + 1e-6)) < 1e-5)
        #expect(abs(T.canonLog3Decode(0.15277891) - 0.014 * 0.9) < 1e-5)
    }

    @Test func curvesRoundTripAndAreContinuous() {
        typealias T = TransferFunctions
        let pairs: [(String, (Float) -> Float, (Float) -> Float)] = [
            ("vlog", T.vlogEncodeLegal, T.vlogDecodeLegal),
            ("dlog", T.dlogEncodeLegal, T.dlogDecodeLegal),
            ("applelog", T.appleLogEncode, T.appleLogDecode),
            ("pq", T.pqEncode, T.pqDecode),
        ]
        for (name, enc, dec) in pairs {
            var y: Float = 0
            while y <= 20 {
                let back = dec(enc(y))
                #expect(abs(back - y) <= 2e-4 * max(1, y), "\(name) y=\(y) back=\(back)")
                y += y < 1 ? 0.005 : 0.5
            }
        }
        // Breakpoints: no jump.
        #expect(abs(T.vlogDecode(0.181 - 1e-6) - T.vlogDecode(0.181 + 1e-6)) < 1e-4)
        #expect(abs(T.dlogDecode(0.14 - 1e-6) - T.dlogDecode(0.14 + 1e-6)) < 1e-3)
        let pt: Float = 47.28711236 * (0.01 + 0.05641088) * (0.01 + 0.05641088)
        #expect(abs(T.appleLogDecode(pt - 1e-6) - T.appleLogDecode(pt + 1e-6)) < 1e-4)
        #expect(abs(T.appleLogDecode(pt) - 0.01) < 1e-4)
    }

    // MARK: Test chart, ΔE < 2

    /// Scene-linear Rec.709 chart: ColorChecker-like patches (sRGB-ish values linearised) plus a gray ramp and highlights.
    static let chart: [SIMD3<Double>] = {
        let srgb: [SIMD3<Double>] = [
            [115, 82, 68], [194, 150, 130], [98, 122, 157], [87, 108, 67], [133, 128, 177], [103, 189, 170],
            [214, 126, 44], [80, 91, 166], [193, 90, 99], [94, 60, 108], [157, 188, 64], [224, 163, 46],
            [56, 61, 150], [70, 148, 73], [175, 54, 60], [231, 199, 31], [187, 86, 149], [8, 133, 161],
            [243, 243, 242], [200, 200, 200], [160, 160, 160], [122, 122, 121], [85, 85, 85], [52, 52, 52],
        ]
        func lin(_ v: Double) -> Double { let c = v / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        var out = srgb.map { SIMD3(lin($0.x), lin($0.y), lin($0.z)) }
        out += [0.005, 0.02, 0.09, 0.18, 0.36, 0.72].map { SIMD3<Double>(repeating: $0) }
        return out
    }()

    /// Encodes each chart patch the camera way (Rec.709 linear -> camera gamut -> curve -> 10-bit legal), decodes it
    /// with the pipeline's source transform and gamut matrix, and returns the worst ΔE76 against the patch.
    static func worstDeltaE(_ space: SourceColorSpace, gamut: simd_double3x3, scale: Double = 1,
                            encode: (Double) -> Float) -> Double {
        let toCam = gamut.inverse * Ref.rec709
        let m = space.gamut.matrix(to: .rec709)
        var worst = 0.0
        for p in chart {
            let cam = toCam * (p * scale)
            let v = SIMD3<Float>(encode(cam.x), encode(cam.y), encode(cam.z))
            let back709 = m * space.decode(v)
            let got = SIMD3<Double>(back709) / scale
            let de = simd_length(Ref.lab(Ref.rec709 * got) - Ref.lab(Ref.rec709 * p))
            worst = max(worst, de)
        }
        return worst
    }

    @Test func slog3ChartWithinDeltaE2() {
        let de = Self.worstDeltaE(.sLog3SGamut3Cine, gamut: Ref.sGamut3Cine) { Self.legalFromCode(Ref.slog3Encode($0)) }
        print("PERF W9.3 S-Log3 chart worst dE76", de); #expect(de < 2, "S-Log3 ΔE \(de)")
    }

    @Test func vlogChartWithinDeltaE2() {
        let de = Self.worstDeltaE(.vLogVGamut, gamut: Ref.vGamut) { Self.legalFromCode(Ref.vlogEncode($0)) }
        print("PERF W9.3 V-Log chart worst dE76", de); #expect(de < 2, "V-Log ΔE \(de)")
    }

    @Test func dlogChartWithinDeltaE2() {
        let de = Self.worstDeltaE(.dLogDGamut, gamut: Ref.dGamut) { Self.legalFromCode(Ref.dlogEncode($0)) }
        print("PERF W9.3 D-Log chart worst dE76", de); #expect(de < 2, "D-Log ΔE \(de)")
    }

    @Test func canonChartsWithinDeltaE2() {
        let cases: [(SourceColorSpace, simd_double3x3, (Double) -> Double)] = [
            (.canonLogCinemaGamut, Ref.cinemaGamut, Ref.canonLogEncode), (.canonLogBT2020, Ref.bt2020, Ref.canonLogEncode),
            (.canonLogBT709, Ref.rec709, Ref.canonLogEncode),
            (.canonLog2CinemaGamut, Ref.cinemaGamut, Ref.canonLog2Encode), (.canonLog2BT2020, Ref.bt2020, Ref.canonLog2Encode),
            (.canonLog2BT709, Ref.rec709, Ref.canonLog2Encode),
            (.canonLog3CinemaGamut, Ref.cinemaGamut, Ref.canonLog3Encode), (.canonLog3BT2020, Ref.bt2020, Ref.canonLog3Encode),
            (.canonLog3BT709, Ref.rec709, Ref.canonLog3Encode),
        ]
        for (space, gamut, enc) in cases {
            let de = Self.worstDeltaE(space, gamut: gamut) { Self.legalFromCode(enc($0)) }
            print("PERF F7.2 \(space) chart worst dE76", de); #expect(de < 2, "\(space) ΔE \(de)")
        }
    }

    @Test func appleLogChartWithinDeltaE2() {
        let de = Self.worstDeltaE(.appleLog, gamut: Ref.bt2020) { Self.legalFromSignal(Ref.appleLogEncode($0)) }
        print("PERF W9.3 Apple Log chart worst dE76", de); #expect(de < 2, "Apple Log ΔE \(de)")
    }

    @Test func pqChartWithinDeltaE2() {
        // Chart white (1.0) placed at PQ reference white, 203 nits.
        let de = Self.worstDeltaE(.pqBT2020, gamut: Ref.bt2020) { Self.legalFromSignal(Ref.pqEncode(nits: $0 * 203)) }
        print("PERF W9.3 PQ chart worst dE76", de); #expect(de < 2, "PQ ΔE \(de)")
    }

    // MARK: Gamuts and pipeline wiring

    @Test func newGamutsMatchTheirPrimaries() {
        func close(_ a: simd_double3x3, _ b: simd_double3x3) -> Bool {
            (0..<3).allSatisfy { c in (0..<3).allSatisfy { r in abs(a[c][r] - b[c][r]) < 1e-9 } }
        }
        #expect(close(Gamut.vGamut.rgbToXYZDouble, Ref.vGamut))
        #expect(close(Gamut.dGamut.rgbToXYZDouble, Ref.dGamut))
        #expect(close(Gamut.cinemaGamut.rgbToXYZDouble, Ref.cinemaGamut))
        // Published Cinema Gamut primaries and D65 white come back out of the matrix.
        func xy(_ rgb: SIMD3<Double>) -> SIMD2<Double> { let v = Gamut.cinemaGamut.rgbToXYZDouble * rgb; return SIMD2(v.x, v.y) / (v.x + v.y + v.z) }
        for (rgb, want) in [(SIMD3<Double>(1, 0, 0), SIMD2<Double>(0.740, 0.270)), (SIMD3(0, 1, 0), SIMD2(0.170, 1.140)),
                            (SIMD3(0, 0, 1), SIMD2(0.080, -0.100)), (SIMD3(1, 1, 1), SIMD2(0.3127, 0.3290))] {
            #expect(simd_length(xy(rgb) - want) < 1e-9)
        }
        for s in [SourceColorSpace.canonLogCinemaGamut, .canonLog2CinemaGamut, .canonLog3CinemaGamut] { #expect(s.gamut == .cinemaGamut) }
        for s in [SourceColorSpace.canonLogBT2020, .canonLog2BT2020, .canonLog3BT2020] { #expect(s.gamut == .bt2020) }
        for s in [SourceColorSpace.canonLogBT709, .canonLog2BT709, .canonLog3BT709] { #expect(s.gamut == .rec709) }
        #expect(SourceColorSpace.vLogVGamut.gamut == .vGamut)
        #expect(SourceColorSpace.dLogDGamut.gamut == .dGamut)
        #expect(SourceColorSpace.appleLog.gamut == .bt2020)
        #expect(SourceColorSpace.pqBT2020.gamut == .bt2020)
    }

    @Test func everyColorSpaceIDMapsToASource() {
        let map: [ColorSpaceID: SourceColorSpace] = [
            .rec709: .rec709, .sLog3SGamut3Cine: .sLog3SGamut3Cine, .hlgBT2020: .hlgBT2020, .pqBT2020: .pqBT2020,
            .vLogVGamut: .vLogVGamut, .appleLog: .appleLog, .dLogDGamut: .dLogDGamut,
            .canonLogCinemaGamut: .canonLogCinemaGamut, .canonLogBT2020: .canonLogBT2020, .canonLogBT709: .canonLogBT709,
            .canonLog2CinemaGamut: .canonLog2CinemaGamut, .canonLog2BT2020: .canonLog2BT2020,
            .canonLog2BT709: .canonLog2BT709, .canonLog3CinemaGamut: .canonLog3CinemaGamut,
            .canonLog3BT2020: .canonLog3BT2020, .canonLog3BT709: .canonLog3BT709,
            .logC3WideGamut3: .logC3WideGamut3, .logC4WideGamut4: .logC4WideGamut4,
            .log3G10RedWideGamut: .log3G10RedWideGamut, .bmdFilmGen5WideGamut: .bmdFilmGen5WideGamut,
            .nLogBT2020: .nLogBT2020, .fLog2FGamutC: .fLog2FGamutC, .acesCCTAP1: .acesCCTAP1,
        ]
        for id in ColorSpaceID.allCases { #expect(SourceColorSpace(id) == map[id], "\(id)") }
        #expect(SourceColorSpace.allCases.count == ColorSpaceID.allCases.count)
        #expect(Set(ColorSpaceID.allCases.map { SourceColorSpace($0) }).count == SourceColorSpace.allCases.count)
    }

    @Test func encodeIsTheInverseOfDecodeForEverySource() {
        for s in SourceColorSpace.allCases {
            for v in [SIMD3<Float>(0.1, 0.4, 0.7), SIMD3<Float>(0.5, 0.5, 0.5), SIMD3<Float>(0.8, 0.3, 0.2)] {
                let back = s.encode(s.decode(v))
                #expect(simd_length(back - v) < 1e-3, "\(s) \(v) -> \(back)")
            }
        }
    }

    @Test func projectDefaultReachesThePipelineButNotOverASonyDetection() {
        let video = VideoTrackInfo(width: 8, height: 8, codec: "avc1", bitDepth: 10, chroma: "4:2:2",
                                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        let plain = MediaInfo(duration: Time(1, 1), video: video, detectedColorSpace: .rec709)
        let p = ColorPipeline.from(clipColor: .default, mediaID: UUID(), mediaInfo: plain.applyingProjectInput(.vLogVGamut),
                                   lutProvider: nil)
        #expect(p.source == .vLogVGamut)
        #expect(!p.isIdentity)
        let sony = MediaInfo(duration: Time(1, 1), video: video, detectedColorSpace: .sLog3SGamut3Cine)
        let q = ColorPipeline.from(clipColor: .default, mediaID: UUID(), mediaInfo: sony.applyingProjectInput(.vLogVGamut),
                                   lutProvider: nil)
        #expect(q.source == .sLog3SGamut3Cine)
        let r = ColorPipeline.from(clipColor: ClipColor(source: .appleLog), mediaID: UUID(),
                                   mediaInfo: sony.applyingProjectInput(.vLogVGamut), lutProvider: nil)
        #expect(r.source == .appleLog)
        // Tagged Rec.709 (iPhone SDR, screen recording) keeps the identity path under a project default.
        let tagged = VideoTrackInfo(width: 8, height: 8, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                    nominalFrameDuration: Time(1, 30), isVariableFrameRate: false,
                                    colorPrimaries: "ITU_R_709_2", transfer: "ITU_R_709_2")
        let phone = MediaInfo(duration: Time(1, 1), video: tagged, detectedColorSpace: .rec709)
        let t = ColorPipeline.from(clipColor: .default, mediaID: UUID(), mediaInfo: phone.applyingProjectInput(.appleLog),
                                   lutProvider: nil)
        #expect(t.source == .rec709)
        #expect(t.isIdentity)
    }

    @Test func logGreyLandsNearDisplayMidGrey() {
        // 18 % gray through the automatic conversion lands in the display mid-tones for every log curve (no crush).
        let spaces: [(SourceColorSpace, Float)] = [
            (.sLog3SGamut3Cine, (420 - 64) / 876), (.vLogVGamut, (433 - 64) / 876),
            (.dLogDGamut, (Float(0.39877) * 1023 - 64) / 876), (.appleLog, 0.48827),
            (.canonLogCinemaGamut, (351 - 64) / 876), (.canonLogBT709, (351 - 64) / 876),
            (.canonLog2CinemaGamut, (407 - 64) / 876), (.canonLog2BT2020, (407 - 64) / 876),
            (.canonLog3CinemaGamut, (351 - 64) / 876), (.canonLog3BT2020, (351 - 64) / 876),
        ]
        for (s, v) in spaces {
            let out = ColorPipeline(source: s).process(SIMD3(repeating: v))
            let display = TransferFunctions.bt709OETF(out.x)
            #expect(display > 0.3 && display < 0.6, "\(s) gray -> \(display)")
            #expect(abs(out.x - out.y) < 1e-3 && abs(out.y - out.z) < 1e-3, "\(s) gray stays neutral")
        }
    }
}
