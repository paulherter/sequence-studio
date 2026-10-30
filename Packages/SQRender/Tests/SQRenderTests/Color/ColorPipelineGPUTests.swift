#if canImport(Metal)
import Testing
import Metal
import simd
import SQCore
@testable import SQRender

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

    static func strong(_ m: BasicToneModel = .current) -> BasicCorrection {
        var c = BasicCorrection(model: m)
        c.temperature = 40; c.tint = -25; c.exposure = 0.7; c.contrast = 45
        c.highlights = -30; c.shadows = 60; c.whites = 20; c.blacks = -15; c.saturation = 160; c.vibrance = 35
        return c
    }
    static func curvesParams() -> RGBCurves {
        var c = RGBCurves()
        c.master = [CurvePoint(0, 0.03), CurvePoint(0.3, 0.22), CurvePoint(0.7, 0.8), CurvePoint(1, 1)]
        c.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.58), CurvePoint(1, 1)]
        c.blue = [CurvePoint(0, 0.05), CurvePoint(1, 0.92)]
        return c
    }
    static func wheelsParams() -> ColorWheels {
        var w = ColorWheels()
        w.shadows = WheelValue(hue: 210, amount: 0.6); w.midtones = WheelValue(hue: 40, amount: 0.4)
        w.highlights = WheelValue(hue: 320, amount: 0.5)
        w.shadowsLuma = 20; w.midtonesLuma = -15; w.highlightsLuma = 25; w.saturation = 120
        return w
    }
    static func mildWheels() -> ColorWheels {
        var w = ColorWheels()
        w.shadows = WheelValue(hue: 100, amount: 0.2); w.highlights = WheelValue(hue: 300, amount: 0.2); w.midtonesLuma = 5
        return w
    }
    static func creativeParams() -> CreativeLook {
        var k = CreativeLook()
        k.fadedFilm = 40; k.vibrance = -20; k.saturation = 110
        k.shadowTint = WheelValue(hue: 200, amount: 0.7); k.highlightTint = WheelValue(hue: 30, amount: 0.5); k.tintBalance = 20
        return k
    }
    static func hueCurvesParams() -> HueCurves {
        var h = HueCurves()
        h.hueVsSat = [CurvePoint(0, 0.7), CurvePoint(0.15, 0.3), CurvePoint(0.6, 0.85), CurvePoint(1, 0.7)]
        h.hueVsHue = [CurvePoint(0, 0.5), CurvePoint(0.3, 0.8), CurvePoint(0.7, 0.2), CurvePoint(1, 0.5)]
        h.hueVsLuma = [CurvePoint(0, 0.5), CurvePoint(0.5, 0.65), CurvePoint(1, 0.5)]
        h.lumaVsSat = [CurvePoint(0, 0.6), CurvePoint(0.5, 0.45), CurvePoint(1, 0.3)]
        h.satVsSat = [CurvePoint(0, 0.5), CurvePoint(0.7, 0.5), CurvePoint(1, 0.2)]
        return h
    }
    static func hslParams(invert: Bool = false, allHues: Bool = false, softness: Float = 30, openLuma: Bool = false) -> HSLSecondary {
        var r = HSLSecondary()
        r.hueCenter = 200; r.hueWidth = allHues ? 360 : 90; r.satMin = 5; r.satMax = 90; r.lumMin = 10; r.lumMax = 85
        if openLuma { r.lumMin = 0; r.lumMax = 100 }
        r.softness = softness; r.invert = invert
        r.hueShift = 25; r.saturation = 140; r.exposure = 0.6; r.temperature = -30; r.tint = 20
        return r
    }
    static func zoneBoardParams() -> ZoneBoard {
        var z = ZoneBoard()
        z.global = ZoneSetting(puckX: 0.6, puckY: 0.55, saturation: 0.62, exposure: 0.55)
        z.shadows = ZoneSetting(puckX: 0.3, puckY: 0.7, saturation: 0.4, exposure: 0.4)
        z.midtones = ZoneSetting(puckX: 0.8, puckY: 0.35, saturation: 0.7, exposure: 0.6)
        z.highlights = ZoneSetting(puckX: 0.45, puckY: 0.2, saturation: 0.3, exposure: 0.75)
        return z
    }
    static func volumeParams(invert: Bool = false) -> HSLSecondary {
        var r = HSLSecondary()
        r.maskMode = .volume; r.hueCenter = 30; r.volumeSat = 55; r.volumeLum = 60; r.volumeRadius = 40; r.softness = 40
        r.invert = invert; r.hueShift = 25; r.saturation = 140; r.exposure = 0.6
        return r
    }
    static func vignetteParams() -> Vignette {
        var v = Vignette(); v.amount = -2.5; v.midpoint = 40; v.roundness = 30; v.feather = 60
        return v
    }

    /// Every block kind, before and after the conversion.
    static func stacks(_ src: SourceColorSpace) -> [(String, ColorPipeline)] {
        let tm = ToneMapping(knee: 0.6)
        let all: [ColorOp] = [.basic(strong()), .creative(creativeParams()), .curves(curvesParams()),
                              .wheels(wheelsParams()), .hslSecondary(hslParams()), .zoneBoard(zoneBoardParams()), .vignette(vignetteParams())]
        return [
            ("plain", ColorPipeline(source: src)),
            ("tone map", ColorPipeline(source: src, toneMapping: tm)),
            ("hue curves post", ColorPipeline(source: src, ops: [.conversion(nil), .hueCurves(hueCurvesParams())])),
            ("hue curves pre", ColorPipeline(source: src, ops: [.hueCurves(hueCurvesParams()), .conversion(nil)])),
            ("hue curves between curves", ColorPipeline(source: src, ops: [.conversion(nil), .curves(curvesParams()), .hueCurves(hueCurvesParams()),
                                                                          .curves(curvesParams()), .hueCurves(hueCurvesParams())])),
            ("color range post", ColorPipeline(source: src, ops: [.conversion(nil), .hslSecondary(hslParams())])),
            ("color range pre", ColorPipeline(source: src, ops: [.hslSecondary(hslParams()), .conversion(nil)])),
            ("color range open luma", ColorPipeline(source: src, ops: [.conversion(nil), .hslSecondary(hslParams(openLuma: true))])),
            ("color range open luma pre", ColorPipeline(source: src, ops: [.hslSecondary(hslParams(openLuma: true)), .conversion(nil)])),
            ("color range inverted", ColorPipeline(source: src, ops: [.conversion(nil), .hslSecondary(hslParams(invert: true))])),
            // A narrow edge (softness 15) amplifies input differences by its slope; PQ's pow error at softness 5 exceeds
            // the per-pixel PQ metric although both sides compute the same function.
            ("color range all hues, narrow edge", ColorPipeline(source: src, ops: [.conversion(nil),
                                                                                  .hslSecondary(hslParams(allHues: true, softness: 15))])),
            ("zone board post", ColorPipeline(source: src, ops: [.conversion(nil), .zoneBoard(zoneBoardParams())])),
            ("zone board pre", ColorPipeline(source: src, ops: [.zoneBoard(zoneBoardParams()), .conversion(nil)])),
            ("color volume post", ColorPipeline(source: src, ops: [.conversion(nil), .hslSecondary(volumeParams())])),
            ("color volume inverted pre", ColorPipeline(source: src, ops: [.hslSecondary(volumeParams(invert: true)), .conversion(nil)])),
            ("basic pre", ColorPipeline(source: src, ops: [.basic(strong()), .conversion(nil)])),
            ("basic post", ColorPipeline(source: src, ops: [.conversion(nil), .basic(strong())])),
            ("basic legacy pre", ColorPipeline(source: src, ops: [.basic(strong(.legacy)), .conversion(nil)])),
            ("basic legacy post", ColorPipeline(source: src, ops: [.conversion(nil), .basic(strong(.legacy))])),
            ("all post", ColorPipeline(source: src, ops: [.conversion(nil)] + all)),
            ("all pre", ColorPipeline(source: src, ops: all + [.conversion(nil)])),
            ("conv LUT + basic pre/post", ColorPipeline(source: src, ops: [.basic(strong()), .conversion(convLUT), .basic(strong())])),
            ("conv LUT 1D + all", ColorPipeline(source: src, ops: [.conversion(lut1D(1024))] + all)),
            ("look + tone", ColorPipeline(source: src, ops: [.conversion(nil), .look(creativeLUT, intensity: 0.5), .creative(creativeParams())])),
            ("look pre", ColorPipeline(source: src, ops: [.look(lut1D(33), intensity: 1), .conversion(convLUT)])),
            ("two LUTs domain", ColorPipeline(source: src, ops: [
                .conversion(convLUTDomain), .look(creativeLUTDomain, intensity: 0.5)], toneMapping: tm)),
            ("multi pass", ColorPipeline(source: src, ops: [
                .basic(strong()), .look(creativeLUT, intensity: 0.4), .conversion(convLUT), .curves(curvesParams()),
                .look(lut1D(64, domain: -0.1...1.2), intensity: 0.7), .wheels(wheelsParams()), .vignette(vignetteParams()),
                .look(creativeLUTDomain, intensity: 1), .curves(curvesParams())])),
            ("many sections", ColorPipeline(source: src, ops: [.conversion(nil)] + (0..<12).map { i -> ColorOp in
                i % 3 == 0 ? .curves(curvesParams()) : i % 3 == 1 ? .vignette(vignetteParams()) : .wheels(mildWheels()) })),
        ]
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

    /// Normalized error: <= 2 means |gpu − cpu| <= 2e-4·max(|cpu|, 1e-3) + 1e-6 (relative with a small absolute floor).
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
        let cpu = px.enumerated().map { (i, v) in
            p.process(v, uv: SIMD2((Float(i % w) + 0.5) / Float(w), (Float(i / w) + 0.5) / Float(h)), aspect: Float(w) / Float(h))
        }
        let g = GPUTest.download(d)
        if p.source == .pqBT2020 {
            // PQ gets a per-pixel metric (error relative to the pixel's largest channel, < 2e-3, far below ΔE 0.1):
            // Metal's pow (<= 16 ulp) is amplified ~6x by the 1/m1 exponent and by the c2 - c3·p cancellation, and a
            // saturated pixel's near-zero channel after the gamut matrix inherits that from channels up to 49.
            var worst: Float = 0
            for (gp, cp) in zip(g, cpu) {
                let mag = max(abs(cp.x), abs(cp.y), abs(cp.z), 1e-3)
                worst = max(worst, simd_reduce_max(simd_abs(gp - cp)) / mag)
            }
            #expect(worst < 2e-3, "\(label): pixel-relative error \(worst)")
            if let a { #expect(GPUTest.downloadAlpha(d) == a, "\(label): alpha not passed through") }
            return (0, 0)
        }
        let e = normalizedError(g, cpu, darkAbs: &dark)
        #expect(e <= 2, "\(label): normalized error \(e)")
        if let a { #expect(GPUTest.downloadAlpha(d) == a, "\(label): alpha not passed through") }
        return (e, dark)
    }

    nonisolated(unsafe) static var sharedGPU: ColorPipelineGPU?
    static func shared(_ device: MTLDevice) throws -> ColorPipelineGPU {
        if let g = sharedGPU { return g }
        let g = try ColorPipelineGPU(device: device); sharedGPU = g; return g
    }

    /// Correction before and after a LUT conversion, a creative look and the other block kinds.
    static func heavy() -> ColorPipeline {
        ColorPipeline(source: .sLog3SGamut3Cine, ops: [
            .basic(strong()), .conversion(convLUT), .basic(strong()), .look(creativeLUT, intensity: 0.5),
            .creative(creativeParams()), .curves(curvesParams()), .wheels(wheelsParams()), .vignette(vignetteParams())])
    }

    static let sources: [SourceColorSpace] = SourceColorSpace.allCases

    @Test func matchesCPUReference() throws {
        var worst: Float = 0, worstDark: Float = 0
        for src in Self.sources { for (name, p) in Self.stacks(src) {
            let (e, d) = try Self.compare(p, "\(src) \(name)")
            worst = max(worst, e); worstDark = max(worstDark, d)
        } }
        print("GPU color worst normalized error (<=1 passes):", worst, " max abs error on dark (<0.01) values:", worstDark)
    }

    @Test func passesSplitAtSecondLUTAndResourceLimits() {
        let p = ColorPipeline(source: .rec709, ops: [.look(Self.creativeLUT, intensity: 1), .conversion(Self.convLUT),
                                                      .look(Self.creativeLUT, intensity: 1)])
        let passes = ColorPipelineGPU.passes(for: p)
        #expect(passes.count == 3)
        #expect(passes.map { $0.header.ints.y } == [0, 1, 2], "start domains: source-encoded, source-linear, display")
        #expect(passes.map { $0.header.ints.z } == [1, 2, 3], "end domains")
        let many = ColorPipeline(source: .rec709, ops: [.conversion(nil)] + (0..<7).map { _ in .curves(Self.curvesParams()) })
        #expect(ColorPipelineGPU.passes(for: many).count == 3, "3 curve tables per pass")
        let single = ColorPipelineGPU.passes(for: ColorPipeline(source: .rec709))
        #expect(single.count == 1 && single[0].header.ints.x == 1)
    }

    @Test(arguments: [BasicToneModel.legacy, .lumetri]) func eachBasicParameterInIsolation(_ m: BasicToneModel) throws {
        let params: [(String, (inout BasicCorrection) -> Void)] = [
            ("temperature+", { $0.temperature = 70 }), ("temperature-", { $0.temperature = -70 }),
            ("tint+", { $0.tint = 70 }), ("tint-", { $0.tint = -70 }),
            ("exposure+", { $0.exposure = 2.5 }), ("exposure-", { $0.exposure = -3 }), ("exposure small+", { $0.exposure = 0.1 }),
            ("contrast+", { $0.contrast = 80 }), ("contrast-", { $0.contrast = -80 }),
            ("highlights+", { $0.highlights = 90 }), ("highlights-", { $0.highlights = -90 }),
            ("shadows+", { $0.shadows = 90 }), ("shadows-", { $0.shadows = -90 }),
            ("whites+", { $0.whites = 90 }), ("whites-", { $0.whites = -90 }),
            ("blacks+", { $0.blacks = 90 }), ("blacks-", { $0.blacks = -90 }),
            ("saturation<", { $0.saturation = 30 }), ("saturation0", { $0.saturation = 0 }), ("saturation>", { $0.saturation = 190 }),
            ("vibrance+", { $0.vibrance = 90 }), ("vibrance-", { $0.vibrance = -90 }),
        ]
        var worst: Float = 0
        for src in Self.sources { for (name, f) in params {
            var c = BasicCorrection(model: m); f(&c)
            worst = max(worst, try Self.compare(ColorPipeline(source: src, ops: [.basic(c), .conversion(nil)]), "\(src) pre \(name)").0)
            worst = max(worst, try Self.compare(ColorPipeline(source: src, ops: [.conversion(nil), .basic(c)]), "\(src) post \(name)").0)
        } }
        print("GPU per-parameter worst normalized error:", worst)
    }

    @Test func oddSizesAndAlphaPassthrough() throws {
        let p = Self.heavy()
        for (w, h) in [(37, 23), (1, 1), (33, 5), (5, 65)] {
            try Self.compare(p, "\(w)x\(h)", width: w, height: h, seed: UInt64(w * 31 + h), alpha: true)
        }
    }

    @Test func halfFloatTexturesWithinTolerance() throws {
        let device = GPUTest.device!, queue = device.makeCommandQueue()!
        let gpu = try Self.shared(device)
        let w = 64, h = 64
        let px = Self.randomPixels(count: w * h, seed: 7).map { SIMD3(Float(Float16($0.x)), Float(Float16($0.y)), Float(Float16($0.z))) }
        let p = Self.heavy()
        let s = GPUTest.makeTexture(device, width: w, height: h, format: .rgba16Float)
        let d = GPUTest.makeTexture(device, width: w, height: h, format: .rgba16Float)
        GPUTest.upload(s, px)
        _ = GPUTest.run(queue) { try! gpu.encode(p, source: s, destination: d, commandBuffer: $0) }
        let cpu = px.enumerated().map { (i, v) in
            p.process(v, uv: SIMD2((Float(i % w) + 0.5) / Float(w), (Float(i / w) + 0.5) / Float(h)), aspect: Float(w) / Float(h))
        }
        let e = Self.maxError(GPUTest.download(d), cpu)
        print("GPU color max rel error (float16):", e)
        #expect(e <= 5e-3)
    }

    @Test func inPlaceMatchesOutOfPlace() throws {
        let device = GPUTest.device!, queue = device.makeCommandQueue()!
        let gpu = try Self.shared(device)
        let w = 37, h = 23
        let px = Self.randomPixels(count: w * h, seed: 3)
        let p = ColorPipeline(source: .hlgBT2020, ops: [.basic(Self.strong()), .conversion(Self.convLUT), .curves(Self.curvesParams()), .vignette(Self.vignetteParams())])
        let t = GPUTest.makeTexture(device, width: w, height: h, format: .rgba32Float)
        GPUTest.upload(t, px)
        _ = GPUTest.run(queue) { try! gpu.encode(p, source: t, destination: t, commandBuffer: $0) }
        var dark: Float = 0
        let cpu = px.enumerated().map { (i, v) in
            p.process(v, uv: SIMD2((Float(i % w) + 0.5) / Float(w), (Float(i / w) + 0.5) / Float(h)), aspect: Float(w) / Float(h))
        }
        #expect(Self.normalizedError(GPUTest.download(t), cpu, darkAbs: &dark) <= 1)
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
            let p = ColorPipeline(source: .sLog3SGamut3Cine, ops: [.basic(Self.strong()), .conversion(Self.lut1D(n)),
                                  .look(Self.lut1D(n, domain: -0.1...1.2), intensity: 0.6)])
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
        let p = Self.heavy()
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
#endif
