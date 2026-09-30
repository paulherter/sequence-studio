import Testing
import simd
@testable import SSRender

@Suite struct TransferFunctionTests {
    typealias T = TransferFunctions

    @Test func slog3GreyIsCV420() {
        let v = (Float(420) - 64) / 876
        #expect(abs(T.slog3DecodeLegal(v) - 0.18) < 1e-5)
        #expect(abs(T.slog3Encode(0.18) * 1023 - 420) < 1e-2)
    }

    @Test func slog3RoundTripZeroTo38() {
        var y: Float = -0.005
        while y <= 38 {
            let back = T.slog3DecodeLegal(T.slog3EncodeLegal(y))
            #expect(abs(back - y) <= 1e-4 * max(1, abs(y)), "y=\(y) back=\(back)")
            y += y < 1 ? 0.01 : 0.7
        }
    }

    @Test func slog3Continuity() {
        let e = T.slog3CutEncoded
        #expect(abs(T.slog3Decode(e - 1e-6) - T.slog3Decode(e + 1e-6)) < 1e-4)
        #expect(abs(T.slog3Decode(e) - 0.01125) < 1e-5)
    }

    @Test func hlgGreyAndReferenceWhite() {
        #expect(abs(T.hlgDecode(0.38) - 0.18) < 1e-5)
        let w = T.hlgDecode(0.75)
        #expect(abs(w - 0.99) < 0.02)
        #expect(abs(T.hlgScale - 3.74) < 0.01)
    }

    @Test func hlgContinuityAndRoundTrip() {
        #expect(abs(T.hlgInverseOETF(0.5 - 1e-6) - T.hlgInverseOETF(0.5 + 1e-6)) < 1e-5)
        #expect(abs(T.hlgInverseOETF(1) - 1) < 1e-4)
        var e: Float = 0
        while e <= 1 {
            #expect(abs(T.hlgEncode(T.hlgDecode(e)) - e) < 1e-5)
            e += 0.01
        }
    }

    @Test func bt709RoundTripAndContinuity() {
        var v: Float = 0
        while v <= 1 {
            #expect(abs(T.bt709OETF(T.bt709InverseOETF(v)) - v) < 1e-5)
            v += 0.005
        }
        let b = T.bt709Beta
        #expect(abs(T.bt709OETF(b - 1e-7) - T.bt709OETF(b + 1e-7)) < 1e-5)
        #expect(abs(T.bt709OETF(1) - 1) < 1e-6)
    }
}

@Suite struct GamutTests {
    @Test func rec709MatrixMatchesPublished() {
        let m = Gamut.rec709.rgbToXYZ
        let rows: [[Float]] = [[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]
        for r in 0..<3 { for c in 0..<3 { #expect(abs(m[c][r] - rows[r][c]) < 1e-4, "r\(r) c\(c)") } }
    }

    @Test func bt2020To709MatchesPublished() {
        let m = Gamut.bt2020.matrix(to: .rec709)
        let rows: [[Float]] = [[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]]
        for r in 0..<3 { for c in 0..<3 { #expect(abs(m[c][r] - rows[r][c]) < 1e-3, "r\(r) c\(c)") } }
    }

    @Test func sGamut3CineTo709MatchesSony() {
        let m = Gamut.sGamut3Cine.matrix(to: .rec709)
        let rows: [[Float]] = [[1.62695, -0.54014, -0.08681], [-0.17852, 1.41794, -0.23943], [-0.04444, -0.19592, 1.24036]]
        for r in 0..<3 { for c in 0..<3 { #expect(abs(m[c][r] - rows[r][c]) < 1e-4, "r\(r) c\(c)") } }
    }

    @Test func whiteMapsToWhite() {
        let all: [Gamut] = [.rec709, .bt2020, .sGamut3Cine]
        for a in all { for b in all {
            let w = a.matrix(to: b) * SIMD3<Float>(1, 1, 1)
            #expect(simd_length(w - SIMD3<Float>(1, 1, 1)) < 1e-5)
        } }
    }

    @Test func lumaRowSumsToGreyAt018() {
        for g in [Gamut.rec709, .bt2020, .sGamut3Cine] { #expect(abs(g.lumaRow.sum() - 1) < 1e-5) }
    }

    @Test func bradfordIdentityAndWhiteMapping() {
        let d65 = WhitePoint.xyz(Gamut.d65)
        let i = WhitePoint.bradford(from: d65, to: d65)
        #expect(simd_length(i * SIMD3<Double>(0.3, 0.4, 0.5) - SIMD3<Double>(0.3, 0.4, 0.5)) < 1e-12)
        let d50 = WhitePoint.xyz(SIMD2(0.3457, 0.3585))
        #expect(simd_length(WhitePoint.bradford(from: d65, to: d50) * d65 - d50) < 1e-9)
    }

    @Test func cctLocus() {
        let xy = WhitePoint.xy(cct: 6504, duv: 0)
        #expect(abs(xy.x - 0.3135) < 2e-3 && abs(xy.y - 0.3237) < 2e-3)
        let warm = WhitePoint.xy(cct: 3000, duv: 0)
        #expect(warm.x > xy.x)
        #expect(WhitePoint.xy(cct: 6504, duv: 0.01).y > xy.y)
    }
}
