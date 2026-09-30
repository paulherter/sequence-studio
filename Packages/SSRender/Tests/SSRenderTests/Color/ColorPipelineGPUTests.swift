import Testing
import Metal
import simd
@testable import SSRender

@Suite(.enabled(if: GPUTest.device != nil, "no Metal device")) struct ColorPipelineGPUTests {
    static func lut3D(_ n: Int, domain: ClosedRange<Float> = 0...1, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> CubeLUT {
        var t: [SIMD3<Float>] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n { t.append(f(SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1))) } } }
        return CubeLUT(kind: .lut3D, size: n, domainMin: SIMD3(repeating: domain.lowerBound),
                       domainMax: SIMD3(repeating: domain.upperBound), table: t)
    }
    static func lut1D(_ n: Int, domain: ClosedRange<Float> = 0...1) -> CubeLUT {
        let t = (0..<n).map { i -> SIMD3<Float> in
            let x = Float(i) / Float(n - 1)
            return SIMD3(powf(x, 0.9), powf(x, 1.1) * 0.95 + 0.02, sqrtf(x))
        }
        return CubeLUT(kind: .lut1D, size: n, domainMin: SIMD3(repeating: domain.lowerBound),
                       domainMax: SIMD3(repeating: domain.upperBound), table: t)
    }
    static let convLUT = lut3D(17) { SIMD3(powf($0.x, 0.9) * 1.05, $0.y * 0.95 + 0.03 * $0.z, sqrtf($0.z) * 0.9 + 0.1 * $0.x) }
    static let creativeLUT = lut3D(9) { SIMD3($0.y, $0.z * 0.8 + 0.1, 1 - $0.x * 0.7) }
    static let convLUTDomain = lut3D(17, domain: -0.1...1.2) { SIMD3(powf($0.x, 0.9) * 1.05, $0.y * 0.95 + 0.03 * $0.z, sqrtf($0.z) * 0.9 + 0.1 * $0.x) }
    static let creativeLUTDomain = lut3D(9, domain: -0.1...1.2) { SIMD3($0.y, $0.z * 0.8 + 0.1, 1 - $0.x * 0.7) }

    static func strong() -> ColorCorrection {
        var c = ColorCorrection()
        c.temperature = 40; c.tint = -25; c.exposure = 0.7; c.contrast = 45
        c.highlights = -30; c.shadows = 60; c.saturation = 160
        return c
    }

    /// Corners, edges, negatives, out-of-range (S-Log3 CV 1023 = 1.0947 range-expanded) and random values.
    static func randomPixels(count: Int, seed: UInt64) -> [SIMD3<Float>] {
        var rng = LCG(s: seed)
        var px: [SIMD3<Float>] = [[0, 0, 0], [1, 1, 1], [0.5, 0.5, 0.5], [1, 0, 0], [0, 1, 0], [0, 0, 1],
                                  [1.0947, 1.0947, 1.0947], [-0.2, 0.3, 1.1], [-0.05, -0.05, -0.05], [1.2, -0.1, 0.5],
                                  [1e-4, 2e-4, 5e-5], [0.003, 0.002, 0.004]]
        while px.count < count {
            var v = rng.rgb()
            if px.count % 4 == 0 { v = v * 1.35 - SIMD3(repeating: 0.25) }   // -0.25 … 1.1
            if px.count % 7 == 0 { v = v * v * v * 0.05 }                    // dark
            px.append(v)
        }
        return Array(px.prefix(count))
    }

    /// Normalized error: <= 1 means |gpu − cpu| <= 1e-4·max(|cpu|, 1e-3) + 1e-6 (relative with a small absolute floor).
    static func normalizedError(_ gpu: [SIMD3<Float>], _ cpu: [SIMD3<Float>], darkAbs: inout Float) -> Float {
        var m: Float = 0
        for (g, c) in zip(gpu, cpu) {
            for i in 0..<3 {
                if c[i].isFinite { #expect(g[i].isFinite, "gpu non-finite where cpu finite: \(g) vs \(c)") }
                let d = abs(g[i] - c[i])
                m = max(m, d / (1e-4 * max(abs(c[i]), 1e-3) + 1e-6))
                if abs(c[i]) < 0.01 { darkAbs = max(darkAbs, d) }
            }
        }
        return m
    }

    /// Old metric for the half-float test: relative for |y| > 1, absolute otherwise.
    static func maxError(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        var m: Float = 0
        for (x, y) in zip(a, b) { for i in 0..<3 { m = max(m, abs(x[i] - y[i]) / max(1, abs(y[i]))) } }
        return m
    }

    /// Runs `p` on the GPU (rgba32Float, given size) and compares to the CPU. Returns (normalized error, dark abs error).
    @discardableResult
    static func compare(_ p: ColorPipeline, _ label: String, width w: Int = 64, height h: Int = 64, seed: UInt64 = 99,
                        alpha: Bool = false) throws -> (Float, Float) {
        let device = GPUTest.device!
        let queue = device.makeCommandQueue()!
        let gpu = try shared(device)
        let px = randomPixels(count: w * h, seed: seed)
        let a = alpha ? (0..<(w * h)).map { Float($0 % 97) / 96 * 0.9 + 0.05 } : nil
        let s = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
        let d = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
        GPUTest.upload(s, px, alpha: a)
        var err: Error?
        _ = GPUTest.run(queue) { do { try gpu.encode(p, source: s, destination: d, commandBuffer: $0) } catch { err = error } }
        if let err { throw err }
        var dark: Float = 0
        let e = normalizedError(GPUTest.download(d), px.map { p.process($0) }, darkAbs: &dark)
        #expect(e <= 1, "\(label): normalized error \(e)")
        if let a { #expect(GPUTest.downloadAlpha(d) == a, "\(label): alpha not passed through") }
        return (e, dark)
    }

    nonisolated(unsafe) static var sharedGPU: ColorPipelineGPU?
    static func shared(_ device: MTLDevice) throws -> ColorPipelineGPU {
        if let g = sharedGPU { return g }
        let g = try ColorPipelineGPU(device: device); sharedGPU = g; return g
    }

    static let sources: [SourceColorSpace] = [.sLog3SGamut3Cine, .hlgBT2020, .rec709]

    @Test func matchesCPUReference() throws {
        var worst: Float = 0, worstDark: Float = 0
        for src in Self.sources { for corr in [ColorCorrection.neutral, Self.strong()] {
            let tm = ToneMapping(knee: 0.6)
            let configs: [ColorPipeline] = [
                ColorPipeline(source: src, correction: corr),
                ColorPipeline(source: src, correction: corr, toneMapping: tm),
                ColorPipeline(source: src, correction: corr, conversionLUT: Self.convLUT),
                ColorPipeline(source: src, correction: corr, conversionLUT: Self.lut1D(1024)),
                ColorPipeline(source: src, correction: corr, creativeLUT: Self.creativeLUT, creativeIntensity: 0.5),
                ColorPipeline(source: src, correction: corr, creativeLUT: Self.lut1D(33), creativeIntensity: 1),
                ColorPipeline(source: src, correction: corr, conversionLUT: Self.convLUT, creativeLUT: Self.creativeLUT, creativeIntensity: 0.5),
                ColorPipeline(source: src, correction: corr, toneMapping: tm, conversionLUT: Self.convLUTDomain,
                              creativeLUT: Self.creativeLUTDomain, creativeIntensity: 0.5),
                ColorPipeline(source: src, correction: corr, conversionLUT: Self.lut1D(64, domain: -0.1...1.2),
                              creativeLUT: Self.lut1D(64, domain: -0.1...1.2), creativeIntensity: 0.3),
            ]
            for (i, p) in configs.enumerated() {
                let (e, d) = try Self.compare(p, "\(src) strong=\(!corr.isNeutral) cfg=\(i)")
                worst = max(worst, e); worstDark = max(worstDark, d)
            }
        } }
        print("GPU color worst normalized error (<=1 passes):", worst, " max abs error on dark (<0.01) values:", worstDark)
    }

    @Test func eachCorrectionParameterInIsolation() throws {
        let params: [(String, (inout ColorCorrection) -> Void)] = [
            ("temperature+", { $0.temperature = 70 }), ("temperature-", { $0.temperature = -70 }),
            ("tint+", { $0.tint = 70 }), ("tint-", { $0.tint = -70 }),
            ("exposure+", { $0.exposure = 2.5 }), ("exposure-", { $0.exposure = -3 }),
            ("contrast+", { $0.contrast = 80 }), ("contrast-", { $0.contrast = -80 }),
            ("highlights+", { $0.highlights = 90 }), ("highlights-", { $0.highlights = -90 }),
            ("shadows+", { $0.shadows = 90 }), ("shadows-", { $0.shadows = -90 }),
            ("saturation<", { $0.saturation = 30 }), ("saturation0", { $0.saturation = 0 }), ("saturation>", { $0.saturation = 190 }),
        ]
        var worst: Float = 0
        for src in Self.sources { for (name, f) in params {
            var c = ColorCorrection(); f(&c)
            worst = max(worst, try Self.compare(ColorPipeline(source: src, correction: c), "\(src) \(name)").0)
        } }
        print("GPU per-parameter worst normalized error:", worst)
    }

    @Test func oddSizesAndAlphaPassthrough() throws {
        let p = ColorPipeline(source: .sLog3SGamut3Cine, correction: Self.strong(), conversionLUT: Self.convLUT,
                              creativeLUT: Self.creativeLUT, creativeIntensity: 0.5)
        for (w, h) in [(37, 23), (1, 1), (33, 5), (5, 65)] {
            try Self.compare(p, "\(w)x\(h)", width: w, height: h, seed: UInt64(w * 31 + h), alpha: true)
        }
    }

    @Test func halfFloatTexturesWithinTolerance() throws {
        let device = GPUTest.device!, queue = device.makeCommandQueue()!
        let gpu = try Self.shared(device)
        let w = 64, h = 64
        let px = Self.randomPixels(count: w * h, seed: 7).map { SIMD3(Float(Float16($0.x)), Float(Float16($0.y)), Float(Float16($0.z))) }
        let p = ColorPipeline(source: .sLog3SGamut3Cine, correction: Self.strong(), conversionLUT: Self.convLUT,
                              creativeLUT: Self.creativeLUT, creativeIntensity: 0.5)
        let s = GPUTest.makeTexture(device, width: w, height: h, format: .rgba16Float)
        let d = GPUTest.makeTexture(device, width: w, height: h, format: .rgba16Float)
        GPUTest.upload(s, px)
        _ = GPUTest.run(queue) { try! gpu.encode(p, source: s, destination: d, commandBuffer: $0) }
        let e = Self.maxError(GPUTest.download(d), px.map { p.process($0) })
        print("GPU color max rel error (float16):", e)
        #expect(e <= 2e-3)
    }

    @Test func inPlaceMatchesOutOfPlace() throws {
        let device = GPUTest.device!, queue = device.makeCommandQueue()!
        let gpu = try Self.shared(device)
        let w = 37, h = 23
        let px = Self.randomPixels(count: w * h, seed: 3)
        let p = ColorPipeline(source: .hlgBT2020, correction: Self.strong(), conversionLUT: Self.convLUT)
        let t = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
        GPUTest.upload(t, px)
        _ = GPUTest.run(queue) { try! gpu.encode(p, source: t, destination: t, commandBuffer: $0) }
        var dark: Float = 0
        #expect(Self.normalizedError(GPUTest.download(t), px.map { p.process($0) }, darkAbs: &dark) <= 1)
    }

    @Test func callerMistakesThrow() throws {
        let device = GPUTest.device!, queue = device.makeCommandQueue()!
        let gpu = try Self.shared(device)
        let p = ColorPipeline(source: .rec709)
        let cb = queue.makeCommandBuffer()!
        let a = GPUTest.makeTexture(device, width: 8, height: 8, format: .rgba32Float)
        let big = GPUTest.makeTexture(device, width: 9, height: 8, format: .rgba32Float)
        let bgra = GPUTest.makeTexture(device, width: 8, height: 8, format: .bgra8Unorm)
        let readOnly = GPUTest.makeTexture(device, width: 8, height: 8, format: .rgba32Float, usage: .shaderRead)
        let writeOnly = GPUTest.makeTexture(device, width: 8, height: 8, format: .rgba32Float, usage: .shaderWrite)
        #expect(throws: ColorPipelineGPUError.self) { try gpu.encode(p, source: a, destination: big, commandBuffer: cb) }
        #expect(throws: ColorPipelineGPUError.self) { try gpu.encode(p, source: bgra, destination: a, commandBuffer: cb) }
        #expect(throws: ColorPipelineGPUError.self) { try gpu.encode(p, source: a, destination: bgra, commandBuffer: cb) }
        #expect(throws: ColorPipelineGPUError.self) { try gpu.encode(p, source: a, destination: readOnly, commandBuffer: cb) }
        #expect(throws: ColorPipelineGPUError.self) { try gpu.encode(p, source: writeOnly, destination: a, commandBuffer: cb) }
        #expect(throws: ColorPipelineGPUError.self) { try gpu.encode(p, source: readOnly, destination: readOnly, commandBuffer: cb) }
        #expect(throws: Never.self) { try gpu.encode(p, source: a, destination: a, commandBuffer: cb) }
        cb.commit()
    }

    @Test func largeMultiRow1DLUTWorks() throws {
        for n in [4096, 4097, 10_000, 65_536] {
            let p = ColorPipeline(source: .sLog3SGamut3Cine, correction: Self.strong(), conversionLUT: Self.lut1D(n),
                                  creativeLUT: Self.lut1D(n, domain: -0.1...1.2), creativeIntensity: 0.6)
            try Self.compare(p, "1D LUT \(n)")
        }
    }

    @Test func lutTexturesAreCachedWithLRUEviction() throws {
        let device = GPUTest.device!, queue = device.makeCommandQueue()!
        let gpu = try ColorPipelineGPU(device: device)   // private instance: cache state is asserted
        let s = GPUTest.makeTexture(device, width: 8, height: 8, format: .rgba32Float)
        let d = GPUTest.makeTexture(device, width: 8, height: 8, format: .rgba32Float)
        func run(_ lut: CubeLUT) throws {
            var err: Error?
            _ = GPUTest.run(queue) { cb in
                do { try gpu.encode(ColorPipeline(source: .rec709, conversionLUT: lut), source: s, destination: d, commandBuffer: cb) }
                catch { err = error }
            }
            if let err { throw err }
        }
        let hot = Self.lut3D(4) { $0 }
        try run(hot); try run(hot); try run(hot)
        #expect(gpu.cachedLUTCount == 1)
        var others: [CubeLUT] = []   // kept alive so buffer addresses stay distinct
        for i in 0..<20 {
            others.append(Self.lut3D(3) { $0 * (1 + Float(i) * 0.01) })
            try run(others[i])
            try run(hot)              // keeps the hot LUT most recently used
        }
        #expect(gpu.cachedLUTCount == ColorPipelineGPU.maxCachedLUTs)
        #expect(gpu.isCached(hot))
        #expect(!gpu.isCached(others[0]) && !gpu.isCached(others[3]))
        #expect(gpu.isCached(others[19]))
    }

    @Test func timing4K() throws {
        let device = GPUTest.device!, queue = device.makeCommandQueue()!
        let gpu = try Self.shared(device)
        let p = ColorPipeline(source: .sLog3SGamut3Cine, correction: Self.strong(), conversionLUT: Self.convLUT,
                              creativeLUT: Self.creativeLUT, creativeIntensity: 0.5)
        let s = GPUTest.makeTexture(device, width: 3840, height: 2160, format: .rgba16Float)
        let d = GPUTest.makeTexture(device, width: 3840, height: 2160, format: .rgba16Float)
        var best = Double.infinity
        for _ in 0..<5 {
            let cb = GPUTest.run(queue) { try! gpu.encode(p, source: s, destination: d, commandBuffer: $0) }
            best = min(best, cb.gpuEndTime - cb.gpuStartTime)
        }
        print("GPU color chain 3840x2160 rgba16Float (S-Log3, strong, conv+creative LUT): \(best * 1000) ms")
    }
}
