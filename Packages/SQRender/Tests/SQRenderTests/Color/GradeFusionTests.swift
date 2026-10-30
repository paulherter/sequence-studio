#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import simd
import Testing
@testable import SQRender

/// Export perf: the grade chain runs as specialised kernels (one per pass layout, conversion fused into the first pass,
/// identity blocks skipped). The picture must stay byte for byte that of the generic interpreter path.
/// See docs/PLAYBACK-PERF.md "Grade kernels".
@Suite struct GradeFusionTests {
    // MARK: Fixtures

    static func lut3D(_ n: Int, _ f: (SIMD3<Float>) -> SIMD3<Float>) -> CubeLUT {
        var t: [SIMD3<Float>] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            t.append(f(SIMD3(Float(r), Float(g), Float(b)) / Float(n - 1)))
        } } }
        return CubeLUT(kind: .lut3D, size: n, table: t)
    }

    static let look = lut3D(17) { c in SIMD3(c.x * 0.9 + 0.05 * c.y, pow(c.y, 1.1), c.z * 0.8 + 0.1) }
    static let videoLook = CubeLUT(kind: .lut3D, size: 9, table: lut3D(9) { SIMD3($0.z, $0.x, $0.y) }.table,
                                   inVideoRange: true, outVideoRange: true)
    static let conversionLUT = lut3D(33) { c in simd_clamp(c * 1.2 - SIMD3<Float>(repeating: 0.1), SIMD3<Float>.zero, SIMD3<Float>.one) }
    static let look1D = CubeLUT(kind: .lut1D, size: 1024,
                                table: (0..<1024).map { i in let x = Float(i) / 1023; return SIMD3(x * x, sqrt(x), x) })

    static func lumetri() -> BasicCorrection {
        var b = BasicCorrection(model: .lumetri)
        b.temperature = 12; b.tint = -5; b.exposure = 0.6; b.contrast = 25; b.highlights = -30; b.shadows = 20
        b.whites = 10; b.blacks = -8; b.saturation = 115; b.vibrance = 20
        return b
    }
    static func legacy() -> BasicCorrection {
        var b = BasicCorrection(model: .legacy)
        b.exposure = -0.3; b.contrast = 40; b.highlights = 15; b.shadows = -10; b.whites = -5; b.blacks = 6; b.saturation = 80
        return b
    }
    static func creative() -> CreativeLook {
        var c = CreativeLook(); c.fadedFilm = 15; c.vibrance = 25; c.saturation = 110
        c.shadowTint = WheelValue(hue: 200, amount: 30); c.highlightTint = WheelValue(hue: 40, amount: 20); c.tintBalance = 10
        return c
    }
    static func curves() -> RGBCurves {
        var c = RGBCurves()
        c.master = [CurvePoint(0, 0.02), CurvePoint(0.3, 0.25), CurvePoint(0.7, 0.78), CurvePoint(1, 0.98)]
        c.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.55), CurvePoint(1, 1)]
        return c
    }
    static func vignette(_ a: Float = -1.2) -> Vignette { var v = Vignette(); v.amount = a; v.roundness = 30; return v }
    static func wheels() -> ColorWheels {
        var w = ColorWheels(); w.shadows = WheelValue(hue: 220, amount: 20); w.midtones = WheelValue(hue: 30, amount: 15)
        w.highlights = WheelValue(hue: 60, amount: 10); w.midtonesLuma = 10; w.saturation = 120
        return w
    }
    static func hueCurves() -> HueCurves {
        var h = HueCurves()
        h.hueVsSat = [CurvePoint(0, 0.5), CurvePoint(0.3, 0.7), CurvePoint(1, 0.5)]
        h.hueVsHue = [CurvePoint(0, 0.5), CurvePoint(0.6, 0.4), CurvePoint(1, 0.5)]
        h.lumaVsSat = [CurvePoint(0, 0.4), CurvePoint(1, 0.6)]
        return h
    }
    static func range() -> HSLSecondary { var r = HSLSecondary(); r.hueShift = 20; r.saturation = 130; return r }

    /// Grade configurations: the real project's chain, every op kind, pre-conversion ops, identity blocks, LUT kinds,
    /// chains that need several passes (two LUTs, more than 8 blocks, more than 3 curve tables).
    static func grades() -> [(String, ColorPipeline)] {
        var identityLook = CreativeLook(); identityLook.look = nil
        var g: [(String, ColorPipeline)] = [
            ("709 identity", ColorPipeline(source: .rec709)),
            ("slog3 conversion", ColorPipeline(source: .sLog3SGamut3Cine)),
            ("project chain", ColorPipeline(source: .sLog3SGamut3Cine, ops: [
                .conversion(nil), .basic(lumetri()), .look(look, intensity: 0.8), .creative(creative()), .curves(curves())])),
            ("709 legacy basic curves vignette", ColorPipeline(source: .rec709, ops: [
                .conversion(nil), .basic(legacy()), .curves(curves()), .vignette(vignette())])),
            ("conversion LUT + look (2 passes)", ColorPipeline(source: .sLog3SGamut3Cine, ops: [
                .conversion(conversionLUT), .basic(lumetri()), .look(look, intensity: 1), .curves(curves())])),
            ("pre-conversion ops", ColorPipeline(source: .sLog3SGamut3Cine, ops: [
                .basic(lumetri()), .creative(creative()), .look(look, intensity: 0.5), .curves(curves()), .vignette(vignette()),
                .conversion(nil), .basic(legacy())])),
            ("identity blocks", ColorPipeline(source: .vLogVGamut, ops: [
                .conversion(nil), .basic(BasicCorrection()), .creative(CreativeLook()), .look(look, intensity: 0),
                .vignette(Vignette()), .curves(curves()), .creative(identityLook)])),
            ("pre identity blocks", ColorPipeline(source: .hlgBT2020, ops: [
                .basic(BasicCorrection()), .creative(CreativeLook()), .vignette(Vignette()), .conversion(nil)])),
            ("wheels huecurves range 1D look", ColorPipeline(source: .vLogVGamut, ops: [
                .conversion(nil), .wheels(wheels()), .hueCurves(hueCurves()), .hslSecondary(range()),
                .look(look1D, intensity: 0.7), .look(videoLook, intensity: 1)])),
            ("many blocks", ColorPipeline(source: .appleLog, ops: [.conversion(nil)]
                + [ColorOp](repeating: .curves(curves()), count: 4) + [.basic(lumetri()), .creative(creative()),
                   .vignette(vignette(0.8)), .wheels(wheels()), .basic(legacy()), .hueCurves(hueCurves())])),
        ]
        for (name, p) in ColorGraphRenderTests.chains(.sLog3SGamut3Cine) where name != "one step" {
            g.append(("graph \(name)", p))
        }
        for s in SourceColorSpace.allCases {
            g.append(("\(s) basic", ColorPipeline(source: s, ops: [.conversion(nil), .basic(lumetri()), .creative(creative())],
                                                  toneMapping: ToneMapping(knee: 0.7))))
        }
        return g
    }

    // MARK: Sources

    private static func buffer(_ w: Int, _ h: Int, _ fmt: OSType) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        precondition(CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &pb) == kCVReturnSuccess)
        return pb!
    }

    /// Deterministic noise in 0...1.
    private static func noise(_ x: Int, _ y: Int, _ k: Int) -> Double {
        var v = UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663 ^ k &* 83_492_791)
        v ^= v >> 13; v = v &* 0x5bd1e995; v ^= v >> 15
        return Double(v % 10_000) / 9_999
    }

    static func bgra(_ w: Int, _ h: Int, alpha: Bool) -> CVPixelBuffer {
        let pb = buffer(w, h, kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h { for x in 0..<w {
            let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            let a = alpha ? UInt8(min(255, x * 255 / max(1, w - 1) + Int(noise(x, y, 9) * 30))) : 255
            for c in 0..<3 {
                let v = Double(x + y * (c + 1)) / Double(w + h * 3) * 255 + noise(x, y, c) * 60 - 20
                p[c] = UInt8(max(0, min(255, v)))
            }
            p[3] = a
        } }
        return pb
    }

    /// 4:2:0 bi-planar, video range, codes spread over (and a little past) the legal range.
    static func ycbcr(_ w: Int, _ h: Int, bits: Int) -> CVPixelBuffer {
        let fmt = bits == 8 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let pb = buffer(w, h, fmt)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let maxCode = (1 << bits) - 1
        func store(_ v: Double, _ p: UnsafeMutableRawPointer, _ i: Int) {
            let code = max(0, min(maxCode, Int(v * Double(maxCode))))
            if bits == 8 { p.storeBytes(of: UInt8(code), toByteOffset: i, as: UInt8.self) }
            else { p.storeBytes(of: UInt16(code << 6), toByteOffset: i * 2, as: UInt16.self) }
        }
        let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0..<h { for x in 0..<w {
            store(0.03 + 0.95 * Double(x + y) / Double(w + h) + (noise(x, y, 1) - 0.5) * 0.08, yp + y * ys, x)
        } }
        let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for y in 0..<(h / 2) { for x in 0..<(w / 2) {
            store(0.5 + 0.4 * sin(Double(x) * 0.3) + (noise(x, y, 2) - 0.5) * 0.1, cp + y * cs, x * 2)
            store(0.5 + 0.4 * cos(Double(y) * 0.4) + (noise(x, y, 3) - 0.5) * 0.1, cp + y * cs, x * 2 + 1)
        } }
        return pb
    }

    static func sources() -> [(String, CVPixelBuffer, VideoTrackInfo)] {
        let w = 160, h = 90
        func hint(_ bits: Int) -> VideoTrackInfo {
            VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: bits, chroma: "4:2:0",
                           nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        }
        return [("bgra", bgra(w, h, alpha: false), hint(8)), ("bgra alpha", bgra(w, h, alpha: true), hint(8)),
                ("420 8-bit", ycbcr(w, h, bits: 8), hint(8)), ("420 10-bit", ycbcr(w, h, bits: 10), hint(10))]
    }

    /// Full size, half size (shown at <= 50 %), and a visible region only (partly off the canvas).
    static let transforms: [(String, ClipTransform)] = [
        ("full", ClipTransform()),
        ("half", ClipTransform(position: Vec2(10, -6), scale: Vec2(0.45, 0.45))),
        ("region", ClipTransform(position: Vec2(70, 20), scale: Vec2(0.8, 0.8), rotation: 90)),
    ]

    static func render(_ comp: Compositor, _ layer: RenderLayer, format f: SequenceFormat, dev: MTLDevice,
                       queue q: MTLCommandQueue) throws -> [UInt16] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let target = dev.makeTexture(descriptor: d)!
        let cb = q.makeCommandBuffer()!
        try comp.render([layer], format: f, into: target, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.error == nil)
        var px = [UInt16](repeating: 0, count: f.width * f.height * 4)
        target.getBytes(&px, bytesPerRow: f.width * 8, from: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0)
        return px
    }

    static func hash(_ v: [UInt16]) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for x in v { h = (h ^ UInt64(x)) &* 0x100_0000_01b3 }
        return h
    }

    // MARK: Golden (development check against the code before the change)

    /// `SQ_GRADE_GOLDEN=<file>`: writes the reference hashes when the file is missing, else compares with it. Used to
    /// check that the reference (generic) path itself did not move while the shader code was refactored.
    @Test func goldenHashes() throws {
        guard let path = ProcessInfo.processInfo.environment["SQ_GRADE_GOLDEN"],
              let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        let f = SequenceFormat(width: 192, height: 108, frameDuration: Time(1, 25))
        var lines: [String] = []
        for (gn, g) in Self.grades() { for (sn, pb, hint) in Self.sources() { for (tn, t) in Self.transforms {
            let layer = RenderLayer(content: .frame(pb, colorHint: hint), transform: t, colorPipeline: g)
            lines.append("\(gn) | \(sn) | \(tn) \(Self.hash(try Self.render(comp, layer, format: f, dev: dev, queue: q)))")
        } } }
        if let old = try? String(contentsOfFile: path, encoding: .utf8) {
            let o = old.split(separator: "\n").map(String.init)
            #expect(o.count == lines.count)
            for (a, b) in zip(o, lines) { #expect(a == b) }
        } else {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Specialised = generic

    static func compositor(_ dev: MTLDevice, _ mode: ColorPipelineGPU.Specialization, display: Bool = false) throws -> Compositor {
        let c = try Compositor(device: dev)
        c.colorGPU.specialization = mode
        c.gradesAtDisplaySize = display
        c.tonesBeforeDisplayScale = false     // that path has no generic twin (DisplaySizeGradeTests covers it)
        return c
    }

    /// Compositor output with the fused, specialised kernels equals the generic path's, byte for byte: BGRA (opaque and
    /// alpha), 4:2:0 8 and 10-bit, full size, half size, visible region of a turned layer, export and display-size grade.
    @Test(arguments: [false, true]) func fusedCompositeIsByteIdentical(display: Bool) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let ref = try Self.compositor(dev, .off, display: display), fast = try Self.compositor(dev, .sync, display: display)
        let f = SequenceFormat(width: 192, height: 108, frameDuration: Time(1, 25))
        var compared = 0
        for (gn, g) in Self.grades() { for (sn, pb, hint) in Self.sources() { for (tn, t) in Self.transforms {
            let layer = RenderLayer(content: .frame(pb, colorHint: hint), transform: t, colorPipeline: g)
            let a = try Self.render(ref, layer, format: f, dev: dev, queue: q)
            let b = try Self.render(fast, layer, format: f, dev: dev, queue: q)
            #expect(a == b, "\(gn) | \(sn) | \(tn) | display \(display)")
            compared += 1
        } } }
        #expect(compared == Self.grades().count * 12)
        #expect(ref.colorGPU.specialisedPasses == 0)
        #expect(fast.colorGPU.specialisedPasses >= (Self.grades().count - 1) * 12, "the specialised kernels ran")
    }

    /// The chain alone (no conversion fused), on values far outside 0...1, in place and source -> destination, with a
    /// region and a quarter turn (vignette geometry): specialised = generic, byte for byte, for rgba16Float and rgba32Float.
    @Test(arguments: [MTLPixelFormat.rgba16Float, .rgba32Float]) func specialisedChainIsByteIdentical(format: MTLPixelFormat) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let ref = try ColorPipelineGPU(device: dev), fast = try ColorPipelineGPU(device: dev)
        ref.specialization = .off; fast.specialization = .sync
        let w = 67, h = 41
        var input = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 { input[i * 4 + c] = Float(Self.noise(i, c, 5) * 2.4 - 0.6) * (i % 7 == 0 ? 40 : 1) }
            input[i * 4 + 3] = Float(Self.noise(i, 3, 7))
        }
        input[0] = -0.0; input[5] = 0; input[10] = 1e-6
        func texture(_ data: [Float]) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
            let t = dev.makeTexture(descriptor: d)!
            if format == .rgba32Float {
                t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 16)
            } else {
                let hdata = data.map { Float16($0) }
                t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: hdata, bytesPerRow: w * 8)
            }
            return t
        }
        func bytes(_ t: MTLTexture) -> [UInt8] {
            let bpr = w * (format == .rgba32Float ? 16 : 8)
            var b = [UInt8](repeating: 0, count: bpr * h)
            t.getBytes(&b, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return b
        }
        func run(_ gpu: ColorPipelineGPU, _ p: ColorPipeline, inPlace: Bool, turned: Bool, region: Compositor.SourceRegion?) throws -> [UInt8] {
            let src = texture(input), dst = inPlace ? src : texture([Float](repeating: 0.25, count: w * h * 4))
            let cb = q.makeCommandBuffer()!
            try gpu.encode(p, source: src, destination: dst, commandBuffer: cb, quarterTurned: turned, region: region)
            cb.commit(); cb.waitUntilCompleted()
            return bytes(dst)
        }
        for (gn, g) in Self.grades() {
            for (inPlace, turned, region) in [(true, false, nil), (false, true, nil),
                                              (true, true, Compositor.SourceRegion(x: 5, y: 3, width: 40, height: 30))] {
                let a = try run(ref, g, inPlace: inPlace, turned: turned, region: region)
                let b = try run(fast, g, inPlace: inPlace, turned: turned, region: region)
                #expect(a == b, "\(gn) in place \(inPlace) turned \(turned) region \(region != nil)")
            }
        }
        #expect(fast.specialisedPasses >= Self.grades().count * 3)
    }

    /// Identity blocks are dropped from the passes; the chain keeps its pass boundaries (each one rounds to half).
    @Test func identityBlocksAreSkipped() {
        let p = ColorPipeline(source: .vLogVGamut, ops: [
            .conversion(nil), .basic(BasicCorrection()), .creative(CreativeLook()), .vignette(Vignette()), .curves(Self.curves())])
        #expect(p.gpuPasses.count == 1)
        #expect(p.gpuPasses[0].sections.map(\.head.x) == [ColorPipelineGPU.kindConversion, ColorPipelineGPU.kindCurves])
        #expect(p.gpuPasses[0].header.ints.x == 2)
        // Before the conversion a neutral creative still runs (its BT.709 round trip is not exact); a neutral basic does not.
        let pre = ColorPipeline(source: .hlgBT2020, ops: [.basic(BasicCorrection()), .creative(CreativeLook()), .conversion(nil)])
        #expect(pre.gpuPasses[0].sections.map(\.head.x) == [ColorPipelineGPU.kindCreative, ColorPipelineGPU.kindConversion])
        // Two LUTs: still two passes.
        let two = ColorPipeline(source: .sLog3SGamut3Cine, ops: [.conversion(Self.conversionLUT), .look(Self.look, intensity: 1)])
        #expect(two.gpuPasses.count == 2)
    }

    /// Perf (printed): GPU ms of one graded 4K layer (the real project's chain) at full size in a 4K canvas: conversion +
    /// generic chain vs fused specialised kernel; and the chain alone on a 4K rgba16Float texture (EngineBench --grades).
    @Test func fusedGradeIsFasterFor4K() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let w = 3840, h = 2160
        let pb = Self.ycbcr(w, h, bits: 10)
        let hint = VideoTrackInfo(width: w, height: h, codec: "avc1", bitDepth: 10, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let grade = Self.grades().first { $0.0 == "project chain" }!.1
        let layer = RenderLayer(content: .frame(pb, colorHint: hint), transform: ClipTransform(), colorPipeline: grade)
        let f = SequenceFormat(width: w, height: h, frameDuration: Time(1, 30))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead, .shaderWrite]; d.storageMode = .private
        let target = dev.makeTexture(descriptor: d)!
        func best(_ n: Int = 12, _ body: (MTLCommandBuffer) throws -> Void) rethrows -> Double {
            var b = Double.infinity
            for _ in 0..<n {
                let cb = q.makeCommandBuffer()!
                try body(cb)
                cb.commit(); cb.waitUntilCompleted()
                b = min(b, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            return b
        }
        let ref = try Self.compositor(dev, .off), fast = try Self.compositor(dev, .sync)
        let plain = RenderLayer(content: .frame(pb, colorHint: hint), transform: ClipTransform())
        let draw = try best { try ref.render([plain], format: f, into: target, commandBuffer: $0) }
        let before = try best { try ref.render([layer], format: f, into: target, commandBuffer: $0) }
        let after = try best { try fast.render([layer], format: f, into: target, commandBuffer: $0) }
        let gRef = try ColorPipelineGPU(device: dev), gFast = try ColorPipelineGPU(device: dev)
        gRef.specialization = .off; gFast.specialization = .sync
        let chainBefore = try best { try gRef.encode(grade, source: target, destination: target, commandBuffer: $0) }
        let chainAfter = try best { try gFast.encode(grade, source: target, destination: target, commandBuffer: $0) }
        print("PERF 4K graded layer (project chain): composite \(before) -> \(after) ms (ungraded draw \(draw) ms); "
              + "chain alone \(chainBefore) -> \(chainAfter) ms")
        #expect(after < before)
    }

    // MARK: Half rounding

    /// The fused kernel stands in for "write to the rgba16Float intermediate, read it back" with `storeHalf`. That is
    /// exact only if it rounds like the texture store: every float (half normals, subnormals, ties, overflow, infinity,
    /// signed zero) must give the same value both ways. (`half(x)` rounds to nearest; the store rounds toward zero.)
    @Test func storeHalfMatchesTextureStore() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        \(ColorShaderSource.storeHalfMSL)
        kernel void k(device const float* inp [[buffer(0)]], texture2d<float, access::write> t [[texture(0)]],
                      device float* outp [[buffer(1)]], uint i [[thread_position_in_grid]]) {
            float v = inp[i];
            t.write(float4(v, -v, v, 1.0f), uint2(i % 1024, i / 1024));
            outp[i] = storeHalf1(v);
        }
        """
        let o = MTLCompileOptions(); o.mathMode = .safe; o.languageVersion = .version3_1
        let lib = try dev.makeLibrary(source: src, options: o)
        let ps = try dev.makeComputePipelineState(function: lib.makeFunction(name: "k")!)
        var vals: [Float] = [0, -0.0, .nan, .infinity, -.infinity, 65504, 65519, 65520, 70000, 1e-8, 5.96e-8, 2.98e-8, 2.99e-8]
        var seed: UInt64 = 0x9e37_79b9_7f4a_7c15
        func next() -> UInt32 { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return UInt32(seed >> 33) }
        for e in -40...18 { for _ in 0..<400 {
            let m = 1 + Float(next() % 1_000_000) / 1_000_000
            vals.append(m * powf(2, Float(e))); vals.append(-m * powf(2, Float(e)))
        } }
        // Exact ties and near ties of the half mantissa (bit 12 of the float mantissa) over the half range.
        for _ in 0..<20_000 {
            let exp = 103 + next() % 40
            let b = ((next() % 1024) << 13) | (1 << 12) | (exp << 23) | (next() % 3 == 0 ? next() % 8 : 0)
            vals.append(Float(bitPattern: b)); vals.append(Float(bitPattern: b | 0x8000_0000))
        }
        while vals.count % 1024 != 0 { vals.append(0.5) }
        let n = vals.count
        let inb = dev.makeBuffer(bytes: vals, length: n * 4)!, outb = dev.makeBuffer(length: n * 4)!
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1024, height: n / 1024, mipmapped: false)
        td.usage = [.shaderWrite]; td.storageMode = .shared
        let tex = dev.makeTexture(descriptor: td)!
        let cb = q.makeCommandBuffer()!, e = cb.makeComputeCommandEncoder()!
        e.setComputePipelineState(ps); e.setBuffer(inb, offset: 0, index: 0); e.setBuffer(outb, offset: 0, index: 1)
        e.setTexture(tex, index: 0)
        e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        e.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: n * 4)
        tex.getBytes(&px, bytesPerRow: 1024 * 8, from: MTLRegionMake2D(0, 0, 1024, n / 1024), mipmapLevel: 0)
        let shader = outb.contents().bindMemory(to: Float.self, capacity: n)
        var bad = 0, samples: [String] = []
        for i in 0..<n {
            let t = Float(px[i * 4]), m = shader[i]
            if t.bitPattern == m.bitPattern || (t.isNaN && m.isNaN) { continue }
            if samples.count < 4 { samples.append("\(vals[i]): texture \(t) shader \(m)") }
            bad += 1
        }
        #expect(bad == 0, "\(bad) of \(n): \(samples)")
    }
}
#endif
