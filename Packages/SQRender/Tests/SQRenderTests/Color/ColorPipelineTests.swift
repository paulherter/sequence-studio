import Testing
import simd
import SQCore
@testable import SQRender

@Suite struct ColorPipelineTests {
    func identityLUT3D(_ n: Int = 17) -> CubeLUT {
        var t: [SIMD3<Float>] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n { t.append(SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)) } } }
        return CubeLUT(kind: .lut3D, size: n, table: t)
    }

    @Test func rec709InvariantRoundTrip() {
        let p = ColorPipeline(source: .rec709)
        var rng = LCG(s: 5)
        var samples: [SIMD3<Float>] = [[0, 0, 0], [1, 1, 1], [0.01, 0.02, 0.03], [0.081, 0.5, 0.99]]
        for _ in 0..<1000 { samples.append(rng.rgb()) }
        for s in samples {
            let o = Rec709Output.encode(p.process(s))
            #expect(simd_length(o - s) <= 1e-5, "\(s) -> \(o)")
        }
    }

    @Test func slog3GreyAutomaticGives018() {
        let v = (Float(420) - 64) / 876
        let p = ColorPipeline(source: .sLog3SGamut3Cine)
        let o = p.process(SIMD3(repeating: v))
        #expect(simd_length(o - SIMD3(repeating: 0.18)) < 1e-4)
    }

    @Test func hlgReferenceWhiteAndPeakBounded() {
        let p = ColorPipeline(source: .hlgBT2020)
        #expect(abs(SourceColorSpace.hlgBT2020.decode(SIMD3(repeating: 0.75)).x - 1) < 1e-4)
        #expect(simd_length(p.process(SIMD3(repeating: 0.75)) - SIMD3(repeating: p.toneMapping.mapMax(1))) < 1e-4)
        #expect(simd_length(p.process(SIMD3(repeating: 0.38)) - SIMD3(repeating: 26.0 / 203)) < 2e-3)
        for s in [SIMD3<Float>(1, 1, 1), [1, 0, 0], [0, 1, 0], [0, 0, 1], [0.9, 1, 0.2]] {
            let w = p.process(s)
            #expect(max(w.x, w.y, w.z) <= 1 + 1e-6)
            let o = Rec709Output.encode(w)
            #expect(max(o.x, o.y, o.z) <= 1)
        }
    }

    @Test func identityConversionLUTReturnsSourceEncoded() {
        let p = ColorPipeline(source: .sLog3SGamut3Cine, conversionLUT: identityLUT3D())
        for v: Float in [0.05, 0.3, 0.488, 0.7, 0.9] {
            let o = Rec709Output.encode(p.process(SIMD3(v, v * 0.8, v * 0.6)))
            #expect(simd_length(o - SIMD3(v, v * 0.8, v * 0.6)) < 1e-5, "v=\(v) o=\(o)")
        }
    }

    @Test func conversionLUTSeesReencodedValues() {
        // A LUT that returns a constant marker proves the LUT is in the chain; one that inverts proves the input.
        var t: [SIMD3<Float>] = []
        let n = 17
        for b in 0..<n { for g in 0..<n { for r in 0..<n { t.append(SIMD3<Float>(1, 1, 1) - SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)) } } }
        let p = ColorPipeline(source: .sLog3SGamut3Cine, conversionLUT: CubeLUT(kind: .lut3D, size: n, table: t))
        let v: Float = 0.5
        let o = Rec709Output.encode(p.process(SIMD3(repeating: v)))
        #expect(abs(o.x - (1 - v)) < 1e-5)
    }

    @Test func exposureIsLinearGainBeforeAndAfterTheConversion() {
        var b = BasicCorrection(); b.exposure = 1
        let lin = TransferFunctions.bt709InverseOETF(0.3)
        for ops in [[ColorOp.basic(b), .conversion(nil)], [.conversion(nil), .basic(b)]] {
            let o = ColorPipeline(source: .rec709, ops: ops).process(SIMD3(repeating: 0.3))
            #expect(abs(o.x - 2 * lin) < 1e-5)
        }
    }

    @Test func conversionIsInsertedWhenMissingAndOnlyTheFirstCounts() {
        var b = BasicCorrection(); b.exposure = 1
        let p = ColorPipeline(source: .rec709, ops: [.basic(b)])
        #expect(p.stages.count == 2)
        let twice = ColorPipeline(source: .rec709, ops: [.conversion(nil), .conversion(Self.constant(0.5))])
        #expect(twice.stages.count == 1)
    }

    static func constant(_ v: Float) -> CubeLUT {
        CubeLUT(kind: .lut3D, size: 2, table: Array(repeating: SIMD3<Float>(repeating: v), count: 8))
    }

    @Test func lookIntensity() {
        let red = CubeLUT(kind: .lut3D, size: 2, table: Array(repeating: SIMD3<Float>(1, 0, 0), count: 8))
        let s = SIMD3<Float>(0.2, 0.4, 0.6)
        func out(_ k: Float) -> SIMD3<Float> {
            Rec709Output.encode(ColorPipeline(source: .rec709, conversionLUT: nil, look: red, lookIntensity: k).process(s))
        }
        #expect(simd_length(out(0) - s) < 1e-5)
        #expect(simd_length(out(1) - SIMD3(1, 0, 0)) < 1e-5)
        #expect(simd_length(out(0.5) - (s + SIMD3(1, 0, 0)) / 2) < 1e-5)
    }

    @Test func lookBeforeTheConversionActsOnTheSourceSignalLikeAfterIt() {
        // For a Rec.709 source both positions see the same picture signal.
        let lut = GPULike.lut(9) { SIMD3($0.y, $0.z * 0.8 + 0.1, 1 - $0.x * 0.7) }
        let a = ColorPipeline(source: .rec709, ops: [.look(lut, intensity: 0.7), .conversion(nil)])
        let b = ColorPipeline(source: .rec709, ops: [.conversion(nil), .look(lut, intensity: 0.7)])
        for s in [SIMD3<Float>(0.2, 0.4, 0.6), [0.9, 0.1, 0.5]] { #expect(simd_length(a.process(s) - b.process(s)) < 1e-5) }
    }

    @Test func outputClampsAndTags() {
        #expect(Rec709Output.encode(SIMD3(2, -1, 0.5)).x == 1)
        #expect(Rec709Output.encode(SIMD3(2, -1, 0.5)).y == 0)
        #expect(Rec709Output.colorPrimaries == 1 && Rec709Output.transferFunction == 1 && Rec709Output.yCbCrMatrix == 1)
    }
}

enum GPULike {
    static func lut(_ n: Int, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> CubeLUT {
        var t: [SIMD3<Float>] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n { t.append(f(SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1))) } } }
        return CubeLUT(kind: .lut3D, size: n, table: t)
    }
}
