import Testing
import Metal
import simd
@testable import SSRender

@Suite struct ColorPipelineGPUTests {
    static func lut3D(_ n: Int, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> CubeLUT {
        var t: [SIMD3<Float>] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n { t.append(f(SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1))) } } }
        return CubeLUT(kind: .lut3D, size: n, table: t)
    }
    static func lut1D(_ n: Int) -> CubeLUT {
        let t = (0..<n).map { i -> SIMD3<Float> in
            let x = Float(i) / Float(n - 1)
            return SIMD3(powf(x, 0.9), powf(x, 1.1) * 0.95 + 0.02, sqrtf(x))
        }
        return CubeLUT(kind: .lut1D, size: n, table: t)
    }
    static let convLUT = lut3D(17) { SIMD3(powf($0.x, 0.9) * 1.05, $0.y * 0.95 + 0.03 * $0.z, sqrtf($0.z) * 0.9 + 0.1 * $0.x) }
    static let creativeLUT = lut3D(9) { SIMD3($0.y, $0.z * 0.8 + 0.1, 1 - $0.x * 0.7) }

    static func strong() -> ColorCorrection {
        var c = ColorCorrection()
        c.temperature = 40; c.tint = -25; c.exposure = 0.7; c.contrast = 45
        c.highlights = -30; c.shadows = 60; c.saturation = 160
        return c
    }

    static func randomPixels(count: Int, seed: UInt64) -> [SIMD3<Float>] {
        var rng = LCG(s: seed)
        var px: [SIMD3<Float>] = [[0, 0, 0], [1, 1, 1], [0.5, 0.5, 0.5], [1, 0, 0], [0, 1, 0], [0, 0, 1]]
        while px.count < count { px.append(rng.rgb()) }
        return px
    }

    static func maxError(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        var m: Float = 0
        for (x, y) in zip(a, b) {
            for i in 0..<3 { m = max(m, abs(x[i] - y[i]) / max(1, abs(y[i]))) }
        }
        return m
    }

    @Test func matchesCPUReference() throws {
        guard let device = GPUTest.device, let queue = device.makeCommandQueue() else { return }
        let gpu = try ColorPipelineGPU(device: device)
        let w = 64, h = 64
        let px = Self.randomPixels(count: w * h, seed: 99)
        let sources: [SourceColorSpace] = [.sLog3SGamut3Cine, .hlgBT2020, .rec709]
        let corrections: [ColorCorrection] = [.neutral, Self.strong()]
        var worst: Float = 0
        for src in sources { for corr in corrections {
            var configs: [ColorPipeline] = []
            configs.append(ColorPipeline(source: src, correction: corr))
            configs.append(ColorPipeline(source: src, correction: corr, conversionLUT: Self.convLUT))
            configs.append(ColorPipeline(source: src, correction: corr, conversionLUT: Self.lut1D(1024)))
            configs.append(ColorPipeline(source: src, correction: corr, creativeLUT: Self.creativeLUT, creativeIntensity: 0.5))
            configs.append(ColorPipeline(source: src, correction: corr, creativeLUT: Self.lut1D(33), creativeIntensity: 1))
            configs.append(ColorPipeline(source: src, correction: corr, conversionLUT: Self.convLUT,
                                         creativeLUT: Self.creativeLUT, creativeIntensity: 0.5))
            for p in configs {
                let s = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
                let d = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
                GPUTest.upload(s, px)
                _ = GPUTest.run(queue) { gpu.encode(p, source: s, destination: d, commandBuffer: $0) }
                let got = GPUTest.download(d)
                let want = px.map { p.process($0) }
                let e = Self.maxError(got, want)
                worst = max(worst, e)
                #expect(e <= 1e-4, "\(src) corr=\(corr.isNeutral ? "neutral" : "strong") conv=\(p.conversionLUT?.kind as Any) cre=\(p.creativeLUT?.kind as Any): \(e)")
            }
        } }
        print("GPU color max rel error (float32):", worst)
    }

    @Test func halfFloatTexturesWithinTolerance() throws {
        guard let device = GPUTest.device, let queue = device.makeCommandQueue() else { return }
        let gpu = try ColorPipelineGPU(device: device)
        let w = 64, h = 64
        let px = Self.randomPixels(count: w * h, seed: 7).map { SIMD3(Float(Float16($0.x)), Float(Float16($0.y)), Float(Float16($0.z))) }
        let p = ColorPipeline(source: .sLog3SGamut3Cine, correction: Self.strong(), conversionLUT: Self.convLUT,
                              creativeLUT: Self.creativeLUT, creativeIntensity: 0.5)
        let s = GPUTest.makeTexture(device, width: w, height: h, format: .rgba16Float)
        let d = GPUTest.makeTexture(device, width: w, height: h, format: .rgba16Float)
        GPUTest.upload(s, px)
        _ = GPUTest.run(queue) { gpu.encode(p, source: s, destination: d, commandBuffer: $0) }
        let e = Self.maxError(GPUTest.download(d), px.map { p.process($0) })
        print("GPU color max rel error (float16):", e)
        #expect(e <= 2e-3)
    }

    @Test func videoRangeLUTsMatchCPU() throws {
        guard let device = GPUTest.device, let queue = device.makeCommandQueue() else { return }
        let gpu = try ColorPipelineGPU(device: device)
        let w = 64, h = 64
        let px = Self.randomPixels(count: w * h, seed: 13)
        func flagged(_ l: CubeLUT, _ i: Bool, _ o: Bool) -> CubeLUT {
            CubeLUT(kind: l.kind, size: l.size, domainMin: l.domainMin, domainMax: l.domainMax, table: l.table, inVideoRange: i, outVideoRange: o)
        }
        for (i, o) in [(true, false), (false, true), (true, true)] {
            for lut in [flagged(Self.convLUT, i, o), flagged(Self.lut1D(64), i, o)] {
                let p = ColorPipeline(source: .sLog3SGamut3Cine, conversionLUT: lut, creativeLUT: flagged(Self.creativeLUT, o, i), creativeIntensity: 0.7)
                let s = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
                let d = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
                GPUTest.upload(s, px)
                _ = GPUTest.run(queue) { gpu.encode(p, source: s, destination: d, commandBuffer: $0) }
                #expect(Self.maxError(GPUTest.download(d), px.map { p.process($0) }) <= 1e-4)
            }
        }
    }

    @Test func inPlaceMatchesOutOfPlace() throws {
        guard let device = GPUTest.device, let queue = device.makeCommandQueue() else { return }
        let gpu = try ColorPipelineGPU(device: device)
        let w = 32, h = 32
        let px = Self.randomPixels(count: w * h, seed: 3)
        let p = ColorPipeline(source: .hlgBT2020, correction: Self.strong(), conversionLUT: Self.convLUT)
        let t = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
        GPUTest.upload(t, px)
        _ = GPUTest.run(queue) { gpu.encode(p, source: t, destination: t, commandBuffer: $0) }
        #expect(Self.maxError(GPUTest.download(t), px.map { p.process($0) }) <= 1e-4)
    }

    @Test func lutTexturesAreCached() throws {
        guard let device = GPUTest.device, let queue = device.makeCommandQueue() else { return }
        let gpu = try ColorPipelineGPU(device: device)
        let p = ColorPipeline(source: .rec709, conversionLUT: Self.convLUT)
        let s = GPUTest.makeTexture(device, width: 8, height: 8, format: .rgba32Float)
        let d = GPUTest.makeTexture(device, width: 8, height: 8, format: .rgba32Float)
        _ = GPUTest.run(queue) { cb in for _ in 0..<3 { gpu.encode(p, source: s, destination: d, commandBuffer: cb) } }
        #expect(gpu.cachedLUTCount == 1)
    }

    @Test func timing4K() throws {
        guard let device = GPUTest.device, let queue = device.makeCommandQueue() else { return }
        let gpu = try ColorPipelineGPU(device: device)
        let p = ColorPipeline(source: .sLog3SGamut3Cine, correction: Self.strong(), conversionLUT: Self.convLUT,
                              creativeLUT: Self.creativeLUT, creativeIntensity: 0.5)
        let s = GPUTest.makeTexture(device, width: 3840, height: 2160, format: .rgba16Float)
        let d = GPUTest.makeTexture(device, width: 3840, height: 2160, format: .rgba16Float)
        var best = Double.infinity
        for _ in 0..<5 {
            let cb = GPUTest.run(queue) { gpu.encode(p, source: s, destination: d, commandBuffer: $0) }
            best = min(best, cb.gpuEndTime - cb.gpuStartTime)
        }
        print("GPU color chain 3840x2160 rgba16Float (S-Log3, strong, conv+creative LUT): \(best * 1000) ms")
    }
}
