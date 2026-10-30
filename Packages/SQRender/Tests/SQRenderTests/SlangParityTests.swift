#if canImport(Metal)
import Foundation
import Metal
import simd
import SQGPU
import SQGPUKernels
import SQGPUMetal
import Testing
@testable import SQRender

/// Seam 4: every kernel that moved to Slang gives the same pixels as its old hand-written MSL (LegacyKernelSource) on the
/// same input, max channel difference <= 1/255. Kernel by kernel with identical uniforms, odd sizes, HDR and alpha values.
@Suite(.serialized) struct SlangParityTests {
    let dev: MTLDevice
    let gpu: MetalGPUDevice
    let kernels: GPUKernels<MetalGPUDevice>
    let legacy: MTLLibrary
    let legacyFlow: MTLLibrary
    let w = 97, h = 61

    init() throws {
        dev = MTLCreateSystemDefaultDevice()!
        gpu = try MetalGPUDevice(device: dev)
        kernels = try GPUKernels(device: gpu)
        let o = MTLCompileOptions()
        o.mathMode = .safe
        o.languageVersion = .version3_1
        legacy = try dev.makeLibrary(source: LegacyKernelSource.msl, options: o)
        legacyFlow = try dev.makeLibrary(source: LegacyKernelSource.opticalFlow, options: o)
    }

    /// Random premultiplied-ish half pixels: color -0.1...1.6 (HDR, a few negatives), alpha 0...1 with a third opaque.
    func randomTexture(_ tw: Int, _ th: Int, seed: UInt64, opaque: Bool = false) -> MTLTexture {
        var g = SplitMix(seed)
        var px = [Float16](repeating: 0, count: tw * th * 4)
        for i in 0..<(tw * th) {
            let a: Float = opaque || g.next() % 3 == 0 ? 1 : Float(g.next() % 1000) / 999
            for c in 0..<3 { px[i * 4 + c] = Float16(Float(g.next() % 1700) / 1000 - 0.1) }
            px[i * 4 + 3] = Float16(a)
        }
        let t = gpu.makeTexture(GPUTextureDescriptor(width: tw, height: th, cpuAccessible: true))!.texture
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: tw * 8) }
        return t
    }

    func blank(_ tw: Int, _ th: Int) -> MTLTexture { gpu.makeTexture(GPUTextureDescriptor(width: tw, height: th, cpuAccessible: true))!.texture }

    func halfPixels(_ t: MTLTexture) -> [Float] {
        var px = [Float16](repeating: 0, count: t.width * t.height * 4)
        px.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0) }
        return px.map(Float.init)
    }

    /// Old kernel: inputs at texture(0...), output after them, `u` at buffer(0), optional `extra` floats at buffer(1).
    func runLegacy(_ name: String, inputs: [MTLTexture], output: MTLTexture, u: UnsafeRawBufferPointer?, extra: [Float]? = nil,
                   grid: (Int, Int)? = nil, library: MTLLibrary? = nil) throws {
        let p = try dev.makeComputePipelineState(function: (library ?? legacy).makeFunction(name: name)!)
        let cb = gpu.makeCommandBuffer()!
        let enc = cb.buffer.makeComputeCommandEncoder()!
        enc.setComputePipelineState(p)
        for (i, t) in inputs.enumerated() { enc.setTexture(t, index: i) }
        enc.setTexture(output, index: inputs.count)
        if let u { enc.setBytes(u.baseAddress!, length: u.count, index: 0) }
        if let extra { extra.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 1) } }
        let g = grid ?? (output.width, output.height)
        enc.dispatchThreads(MTLSize(width: g.0, height: g.1, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        gpu.commitAndWait(cb)
    }

    func runNew<U: BitwiseCopyable>(_ e: GPUKernels<MetalGPUDevice>.Entry, inputs: [MTLTexture], output: MTLTexture, u: U,
                                    grid: (Int, Int)? = nil) {
        let cb = gpu.makeCommandBuffer()!
        kernels.run(e, cb, inputs: inputs.map(MetalGPUTexture.init), output: MetalGPUTexture(output), constants: u, grid: grid)
        gpu.commitAndWait(cb)
    }

    /// rgba32Float, CPU-readable: values in lo...hi.
    func floatTexture(_ tw: Int, _ th: Int, seed: UInt64, lo: Float = 0, hi: Float = 1) -> MTLTexture {
        var g = SplitMix(seed)
        let px = (0..<(tw * th * 4)).map { _ in lo + (hi - lo) * Float(g.next() % 10_000) / 9_999 }
        let t = gpu.makeTexture(GPUTextureDescriptor(width: tw, height: th, format: .rgba32Float, cpuAccessible: true))!.texture
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: tw * 16) }
        return t
    }

    func floatBlank(_ tw: Int, _ th: Int) -> MTLTexture {
        gpu.makeTexture(GPUTextureDescriptor(width: tw, height: th, format: .rgba32Float, cpuAccessible: true))!.texture
    }

    func pixels(_ t: MTLTexture) -> [Float] {
        if t.pixelFormat == .rgba32Float {
            var px = [Float](repeating: 0, count: t.width * t.height * 4)
            px.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width * 16, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0) }
            return px
        }
        return halfPixels(t)
    }

    func expectSame(_ a: MTLTexture, _ b: MTLTexture, _ what: String) {
        let x = pixels(a), y = pixels(b)
        var maxD: Float = 0
        for i in x.indices where !(x[i].isNaN && y[i].isNaN) { maxD = max(maxD, abs(x[i] - y[i])) }
        #expect(maxD <= 1 / 255, "\(what): max channel diff \(maxD)")
    }

    /// One filter kernel, old vs new, same FilterU.
    func compareFilter(_ legacyName: String, _ e: GPUKernels<MetalGPUDevice>.Entry, _ u: GPUFilterUniforms, inputs: [MTLTexture],
                       out: (Int, Int), grid: (Int, Int)? = nil) throws {
        let a = blank(out.0, out.1), b = blank(out.0, out.1)
        try withUnsafeBytes(of: u) { try runLegacy(legacyName, inputs: inputs, output: a, u: $0, grid: grid) }
        runNew(e, inputs: inputs, output: b, u: u, grid: grid)
        expectSame(a, b, legacyName)
    }

    @Test func filterKernelsMatchTheirOldMSL() throws {
        let img = randomTexture(w, h, seed: 1)
        var u = GPUFilterUniforms(center: SIMD2(48, 30), frame: SIMD2(81, 45))
        u.a.x = 1.3; u.i = SIMD4(8, 8, 88, 52)
        try compareFilter("filterSharpen", .filterSharpen, u, inputs: [img], out: (w, h))
        u = GPUFilterUniforms(); u.a = SIMD4(7, 3, 0, 0); u.i.x = 9
        try compareFilter("filterDirectionalBlur", .filterDirectionalBlur, u, inputs: [img], out: (w, h))
        u = GPUFilterUniforms(); u.a = SIMD4(1.2, 0.4, 0, 0); u.b = SIMD4(-16, -16, 0, 0); u.i.x = 6
        try compareFilter("filterSmearComb", .filterSmearComb, u, inputs: [img], out: (w + 32, h + 32))
        u = GPUFilterUniforms(center: SIMD2(40, 30)); u.a = SIMD4(0.8660254, 0.5, 0, 0)
        try compareFilter("filterMirror", .filterMirror, u, inputs: [img], out: (w, h))
        for (color, clip) in [(1, 1), (0, 0)] as [(Int32, Int32)] {
            u = GPUFilterUniforms(); u.a.x = 0.3; u.i = SIMD4(color, clip, Int32(bitPattern: 0xdead_beef), 0)
            try compareFilter("filterNoise", .filterNoise, u, inputs: [img], out: (w, h))
        }
        u = GPUFilterUniforms(center: SIMD2(48.5, 30.5), frame: SIMD2(81, 45)); u.i = SIMD4(7, 5, 0, 8)
        u.a = SIMD4(81 / 7, 45 / 5, 0, 0)  // block size: the new kernels take it from the CPU
        try compareFilter("filterMosaicRows", .filterMosaicRows, u, inputs: [img], out: (7, 45))
        let rowMeans = randomTexture(7, 45, seed: 2), blocks = randomTexture(7, 5, seed: 3)
        try compareFilter("filterMosaicBlocks", .filterMosaicBlocks, u, inputs: [img, rowMeans], out: (7, 5))
        u.i.z = 1
        try compareFilter("filterMosaicBlocks", .filterMosaicBlocks, u, inputs: [img, rowMeans], out: (7, 5))
        try compareFilter("filterMosaicApply", .filterMosaicApply, u, inputs: [img, blocks], out: (w, h))
    }

    @Test func unsharpAndGlowMatchTheirOldMSL() throws {
        let img = randomTexture(w, h, seed: 4), blur = randomTexture(w, h, seed: 5)
        var u = GPUFilterUniforms(); u.a = SIMD4(1.5, 0.05, 0, 0); u.i = SIMD4(8, 8, 88, 52)
        try compareFilter("filterUnsharp", .filterUnsharp, u, inputs: [img, blur], out: (w, h))
        for (tinted, red) in [(0, 1), (1, 3)] as [(Int32, Int32)] {
            u = GPUFilterUniforms(); u.a = SIMD4(0.4, 1.7, 0, 0); u.b = SIMD4(0.9, 0.3, 0.1, 1); u.i = SIMD4(tinted, red, 0, 0)
            let rw = (w + Int(red) - 1) / Int(red), rh = (h + Int(red) - 1) / Int(red)
            try compareFilter("filterGlowBright", .filterGlowBright, u, inputs: [img], out: (rw, rh))
            let plane = randomTexture(rw, rh, seed: 6)
            try compareFilter("filterGlowAdd", .filterGlowAdd, u, inputs: [img, plane], out: (w, h))
        }
    }

    /// Every op of the style families (StyleFilters op codes) with plausible uniforms on a picture frame inside the texture.
    @Test func styleKernelsMatchTheirOldMSL() throws {
        let img = randomTexture(w, h, seed: 7)
        let c = SIMD2<Float>(48.5, 30.5), f = SIMD2<Float>(81, 45)
        func style(_ entry: GPUKernels<MetalGPUDevice>.Entry, _ set: (inout GPUFilterUniforms) -> Void) throws {
            var u = GPUFilterUniforms(center: c, frame: f)
            set(&u)
            try compareFilter(entry.name, entry, u, inputs: [img], out: (w, h))
        }
        // Pixel ops.
        try style(.filterStylePixel) { $0.a = SIMD4(0.8, 0.5, 0.3, 0.4); $0.i.w = 1 }
        try style(.filterStylePixel) { $0.a = SIMD4(-0.8, 0.5, -0.5, 0.4); $0.i.w = 1 }
        for ch: Int32 in [0, 2, 4] { try style(.filterStylePixel) { $0.a.x = 0.3; $0.i.x = ch; $0.i.w = 3 } }
        try style(.filterStylePixel) { $0.a.x = 5; $0.i.w = 4 }
        try style(.filterStylePixel) { $0.a = SIMD4(0.1, 0.2, 0.3, 0.8); $0.b = SIMD4(0.9, 0.8, 0.6, 0); $0.i.w = 5 }
        try style(.filterStylePixel) { $0.a = SIMD4(0.2, 1.4, 0, 0); $0.i.w = 6 }
        for op: Int32 in 0...4 { try style(.filterStylePixel) { $0.a = SIMD4(0.7, 0.2, 0.5, 0.6); $0.i.x = op; $0.i.w = 7 } }
        try style(.filterStylePixel) { $0.a.w = 0.5; $0.i.y = 1; $0.i.w = 7 }
        try style(.filterStylePixel) { $0.a.x = 0.7; $0.i = SIMD4(0, 1, 0, 8) }
        try style(.filterStylePixel) { $0.a.x = 0.9; $0.i = SIMD4(1, 0, 1, 8) }
        try style(.filterStylePixel) {
            $0.center = SIMD2(30, 20); $0.frame = SIMD2(0.6, 0.8); $0.a = SIMD4(1, 0.5, 0.2, 0.9); $0.b = SIMD4(0.2, 0.4, 1, 40); $0.i.w = 9
        }
        for radial: Int32 in [0, 1] {
            try style(.filterStylePixel) {
                $0.center = SIMD2(20, 15); $0.frame = SIMD2(50, 30); $0.a = SIMD4(1, 0, 0, 0.7); $0.b = SIMD4(0, 0, 1, 0)
                $0.i = SIMD4(radial, 0, 0, 10)
            }
        }
        for color: Int32 in [0, 1] { try style(.filterStylePixel) { $0.a = SIMD4(6, 0.4, 0.3, 0.9); $0.i = SIMD4(color, 0, 0, 11) } }
        try style(.filterStylePixel) { $0.a.x = 12; $0.i.w = 12 }
        // Warp ops.
        try style(.filterStyleWarp) { $0.i = SIMD4(1, 1, 0, 20) }
        try style(.filterStyleWarp) { $0.a = SIMD4(1.2, 40, 0, 0); $0.i.w = 21 }
        for (type, pin) in [(0, 0), (1, 1), (2, 2), (3, 3)] as [(Int32, Int32)] {
            try style(.filterStyleWarp) { $0.a = SIMD4(4, 23, 0.5, -0.8660254); $0.b.x = 0.3; $0.i = SIMD4(type, pin, 0, 22) }
        }
        for s: Float in [0.7, -0.6] { try style(.filterStyleWarp) { $0.a = SIMD4(35, s, 0, 0); $0.i.w = 23 } }
        try style(.filterStyleWarp) { $0.a = SIMD4(0.9, 0.1, -0.05, 1.1); $0.b = SIMD4(3, -2, 0.8, 0); $0.i.w = 24 }
        for mirror: Float in [0, 1] { try style(.filterStyleWarp) { $0.a = SIMD4(3, 2, 0.25, 0.1); $0.b.x = mirror; $0.i.w = 25 } }
        try style(.filterStyleWarp) { $0.a = SIMD4(2 * .pi / 6, 0.3, 1.2, 0); $0.i.w = 26 }
        for (alongX, persp) in [(0, 0), (1, 1)] as [(Int32, Int32)] {
            try style(.filterStyleWarp) {
                $0.a = SIMD4(6, -4, alongX != 0 ? 81 : 45, 0); $0.i = SIMD4(alongX, persp, 0, 27)
                $0.c = SIMD4(1.02, 0.01, 1.5, -0.01); $0.d = SIMD4(0.98, -1, 0.0004, 0.0002)
            }
        }
        for degenerate: Int32 in [0, 1] {
            try style(.filterStyleWarp) {
                $0.a = SIMD4(1.05, 0.02, 2, -0.03); $0.b = SIMD4(0.97, -1.5, 0.0005, -0.0003); $0.i = SIMD4(degenerate, 0, 0, 28)
            }
        }
        for fill: Int32 in [1, 2] {
            try style(.filterStyleWarp) { $0.a = SIMD4(1.1, 0.05, -0.04, 1.08); $0.b = SIMD4(9, -6, 1, 0); $0.i = SIMD4(fill, 0, 0, 29) }
        }
        // Lens: old model, exact barrel/pincushion, auto-scale hold.
        let origin = c - f / 2, halfDiag = simd_length(f) / 2
        for (k, exact, hold, zoom) in [(Float(0.4), Int32(0), Int32(0), Float(1)), (-0.4, 0, 0, 1), (0.5, 1, 0, 1),
                                       (-0.5, 1, 0, 1), (-0.6, 1, 1, 0.8)] {
            try style(.filterLens) {
                $0.center = c + SIMD2(3, -2); $0.a = SIMD4(k, halfDiag, origin.x, origin.y); $0.b = SIMD4(0.1, 0.2, 0.3, 1)
                $0.i = SIMD4(Int32(bitPattern: zoom.bitPattern), hold, exact, 0)
            }
        }
        try style(.filterGlitch) { $0.a = SIMD4(6, 5, 2, 0.6); $0.i.x = 1234 }
        for radial: Int32 in [0, 1] { try style(.filterRGBSplit) { $0.a = SIMD4(3, -2, 0.3, halfDiag); $0.i.x = radial } }
        for zoom: Int32 in [0, 1] { try style(.filterRadialBlur) { $0.a.x = 0.15; $0.i = SIMD4(zoom, 12, 0, 0) } }
    }

    @Test func outlineLongShadowAndAntiFlickerMatchTheirOldMSL() throws {
        let img = randomTexture(w, h, seed: 8)
        var u = GPUFilterUniforms()
        try compareFilter("filterOutlineSeed", .filterOutlineSeed, u, inputs: [img], out: (w, h))
        // Seeds: some empty (x = 30000), the rest small integer offsets plus a sub-pixel part.
        let seeds = blank(w, h)
        var g = SplitMix(9)
        var px = [Float16](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where g.next() % 4 != 0 {
            px[i * 4] = Float16(Int(g.next() % 9) - 4); px[i * 4 + 1] = Float16(Int(g.next() % 9) - 4)
            px[i * 4 + 2] = Float16(Float(g.next() % 100) / 100 - 0.5); px[i * 4 + 3] = Float16(Float(g.next() % 100) / 100 - 0.5)
        }
        for i in 0..<(w * h) where px[i * 4] == 0 && px[i * 4 + 1] == 0 && px[i * 4 + 2] == 0 { px[i * 4] = 30_000 }
        px.withUnsafeBytes { seeds.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
        for step: Int32 in [8, 1] {
            u.i.x = step
            try compareFilter("filterOutlineJump", .filterOutlineJump, u, inputs: [seeds], out: (w, h))
        }
        for position: Int32 in 0...2 {
            u = GPUFilterUniforms(); u.a = SIMD4(4, 1.5, 0, 0); u.b = SIMD4(0.9, 0.2, 0.1, 1); u.i.x = position
            try compareFilter("filterOutlineApply", .filterOutlineApply, u, inputs: [img, seeds], out: (w, h))
        }
        let plane = randomTexture(41, 29, seed: 10)
        for first: Int32 in [1, 0] {
            u = GPUFilterUniforms(); u.a = SIMD4(2.5, -1.5, 0.1, 0); u.i.x = first
            try compareFilter("filterLongShadowStep", .filterLongShadowStep, u, inputs: [first == 1 ? img : plane], out: (41, 29))
        }
        u = GPUFilterUniforms(); u.a.w = 0.8; u.b = SIMD4(0.1, 0.1, 0.3, 1)
        try compareFilter("filterLongShadowApply", .filterLongShadowApply, u, inputs: [img, plane], out: (w, h))
        let a = blank(w, h), b = blank(w, h)
        let k = AntiFlickerFilter.neighborWeight(strength: 0.7)
        try withUnsafeBytes(of: k) { try runLegacy("antiFlickerVertical", inputs: [img], output: a, u: $0) }
        runNew(.antiFlickerVertical, inputs: [img], output: b, u: SIMD4<Float>(k, 0, 0, 0))
        expectSame(a, b, "antiFlickerVertical")
    }

    @Test func opticalFlowKernelsMatchTheirOldMSL() throws {
        func compare(_ e: GPUKernels<MetalGPUDevice>.Entry, _ inputs: [MTLTexture], out: (Int, Int), new u: GPUFlowUniforms,
                     old: [UInt8]?) throws {
            let a = floatBlank(out.0, out.1), b = floatBlank(out.0, out.1)
            if let old { try old.withUnsafeBytes { try runLegacy(e.name, inputs: inputs, output: a, u: $0, library: legacyFlow) } }
            else { try runLegacy(e.name, inputs: inputs, output: a, u: nil, library: legacyFlow) }
            runNew(e, inputs: inputs, output: b, u: u)
            expectSame(a, b, e.name)
        }
        func bytes<T>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v) { Array($0) } }
        let none = GPUFlowUniforms()
        let img = randomTexture(w, h, seed: 21), img2 = randomTexture(w, h, seed: 22)
        let (lw, lh) = (73, 46)
        try compare(.ofLuma, [img], out: (lw, lh), new: none, old: nil)
        let l0 = floatTexture(lw, lh, seed: 23), l1 = floatTexture(lw, lh, seed: 24)
        try compare(.ofDown, [l0], out: (37, 23), new: none, old: nil)
        try compare(.ofGrad, [l0], out: (lw, lh), new: none, old: nil)
        let g0 = floatTexture(lw, lh, seed: 25, lo: -0.3, hi: 0.3), g1 = floatTexture(lw, lh, seed: 26, lo: -0.3, hi: 0.3)
        let coarse = floatTexture(37, 23, seed: 27, lo: -3, hi: 3)
        for hasPrev: UInt32 in [0, 1] {
            var u = none; u.hasPrev = hasPrev
            try compare(.ofUp, [coarse], out: (lw, lh), new: u, old: bytes(hasPrev))
        }
        let flow = floatTexture(lw, lh, seed: 28, lo: -3, hi: 3), back = floatTexture(lw, lh, seed: 29, lo: -3, hi: 3)
        for radius: Int32 in [2, 4] {
            var u = none
            let sigma = Float(radius) * 0.75 + 0.5
            u.radius = radius; u.lambda = 1e-4; u.invTwoSigma2 = 1 / (2 * sigma * sigma); u.maxStep = 2
            try compare(.ofLK, [l0, g0, l1, g1, flow], out: (lw, lh), new: u, old: bytes(SIMD4<Float>(Float(bitPattern: UInt32(bitPattern: radius)), u.lambda, u.invTwoSigma2, u.maxStep)))
        }
        try compare(.ofMedian, [flow], out: (lw, lh), new: none, old: nil)
        try compare(.ofConfidence, [l0, l1, flow, back], out: (lw, lh), new: none, old: nil)
        let trustF = floatTexture(lw, lh, seed: 30, lo: -2, hi: 2), trustB = floatTexture(lw, lh, seed: 31, lo: -2, hi: 2)
        for (t, lin) in [(Float(0.3), UInt32(0)), (0.7, 1)] {
            var u = none
            u.t = t; u.linearize = lin; u.sigma = 0.1; u.flowScale = SIMD2(Float(w) / Float(lw), Float(h) / Float(lh))
            // Old InterpParams: t, linearize, flowScale, sigma.
            var old = bytes(t) + bytes(lin) + bytes(u.flowScale) + bytes(u.sigma)
            old += [UInt8](repeating: 0, count: 32 - old.count)
            try compare(.ofInterpolate, [img, img2, trustF, trustB], out: (w, h), new: u, old: old)
        }
    }

    /// Scopes: the old four-kernel encode (as ScopesGPU had it) against the Slang one, same counts, maxima and planes.
    @Test func scopeKernelsMatchTheirOldMSL() throws {
        let o = MTLCompileOptions()
        o.mathMode = .safe
        o.languageVersion = .version3_1
        let lib = try dev.makeLibrary(source: LegacyScopeShaderSource.msl, options: o)
        func p(_ n: String) throws -> MTLComputePipelineState { try dev.makeComputePipelineState(function: lib.makeFunction(name: n)!) }
        let clear = try p("scopeClear"), accumulate = try p("scopeAccumulate"), findMax = try p("scopeFindMax"), resolve = try p("scopeResolve")
        let scopes = try ScopesGPU(device: dev)
        let img = randomTexture(w * 3, h * 2, seed: 41, opaque: true)
        for step in [1, 2] {
            let l = ScopeLayout(waveformWidth: 200, waveformLevels: 128, vectorscopeSize: 96)
            let old = try #require(scopes.makeResources(layout: l)), new = try #require(scopes.makeResources(layout: l))
            // Old encode.
            let cb = gpu.makeCommandBuffer()!
            let enc = cb.buffer.makeComputeCommandEncoder()!
            var total = UInt32(l.totalCount)
            enc.setComputePipelineState(clear); enc.setBuffer(old.counts, offset: 0, index: 0); enc.setBytes(&total, length: 4, index: 1)
            enc.dispatchThreads(MTLSize(width: l.totalCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            var u: [UInt32] = [UInt32(img.width), UInt32(img.height), UInt32(step), ScopeSelection.all.rawValue,
                               UInt32(l.waveformWidth), UInt32(l.waveformLevels), UInt32(l.vectorscopeSize), 0,
                               UInt32(l.offsetWaveformLuma), UInt32(l.offsetParade), UInt32(l.offsetVector), UInt32(l.offsetHistogram),
                               UInt32(l.offsetMaxima), 0, 0, 0]
            enc.setComputePipelineState(accumulate); enc.setTexture(img, index: 0)
            enc.setBytes(&u, length: u.count * 4, index: 1)
            enc.dispatchThreads(MTLSize(width: (img.width + step - 1) / step, height: (img.height + step - 1) / step, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            let regions = [(l.offsetWaveformLuma, l.waveformLumaCount), (l.offsetParade, l.paradeCount),
                           (l.offsetVector, l.vectorCount), (l.offsetHistogram, l.histogramCount)]
            enc.setComputePipelineState(findMax)
            for (i, g) in regions.enumerated() {
                var mp: [UInt32] = [UInt32(g.0), UInt32(g.1), UInt32(l.offsetMaxima + i), 0]
                enc.setBytes(&mp, length: 16, index: 1)
                enc.dispatchThreads(MTLSize(width: g.1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }
            enc.setComputePipelineState(resolve)
            for (i, t) in [old.waveformLuma, old.waveformParade, old.vectorscope, old.histogram].enumerated() {
                var rp: [UInt32] = [UInt32(regions[i].0), UInt32(l.offsetMaxima + i), UInt32(t.width), UInt32(t.height)]
                enc.setBytes(&rp, length: 16, index: 1); enc.setTexture(t, index: 0)
                enc.dispatchThreads(MTLSize(width: t.width, height: t.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            enc.endEncoding()
            gpu.commitAndWait(cb)
            let cb2 = gpu.makeCommandBuffer()!
            scopes.encode(source: img, into: new, pixelStride: step, commandBuffer: cb2.buffer)
            gpu.commitAndWait(cb2)
            let a = old.readCounts(), b = new.readCounts()
            #expect(a == b, "stride \(step)")
            #expect(b.maxWaveformLuma > 0 && b.maxHistogram > 0)
            // Planes: private textures, so blit both into shared ones.
            for (x, y) in zip([old.waveformLuma, old.waveformParade, old.vectorscope, old.histogram],
                              [new.waveformLuma, new.waveformParade, new.vectorscope, new.histogram]) {
                #expect(planeValues(x) == planeValues(y), "plane \(x.width)x\(x.height) stride \(step)")
            }
        }
    }

    /// One old-MSL dispatch with explicit texture, bytes and buffer indices (threads, or whole groups when `groups`).
    func legacyDispatch(_ lib: MTLLibrary, _ name: String, textures: [Int: MTLTexture], bytes: [Int: [UInt8]] = [:],
                        buffers: [Int: MTLBuffer] = [:], size: (Int, Int), groups: Bool = false) throws {
        let p = try dev.makeComputePipelineState(function: lib.makeFunction(name: name)!)
        let cb = gpu.makeCommandBuffer()!
        let enc = cb.buffer.makeComputeCommandEncoder()!
        enc.setComputePipelineState(p)
        for (i, t) in textures { enc.setTexture(t, index: i) }
        for (i, b) in bytes { b.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: i) } }
        for (i, b) in buffers { enc.setBuffer(b, offset: 0, index: i) }
        let tg = MTLSize(width: name == "deflickerGains" ? 64 : 16, height: name == "deflickerGains" ? 1 : 16, depth: 1)
        if groups { enc.dispatchThreadgroups(MTLSize(width: size.0, height: size.1, depth: 1), threadsPerThreadgroup: tg) }
        else { enc.dispatchThreads(MTLSize(width: size.0, height: size.1, depth: 1), threadsPerThreadgroup: tg) }
        enc.endEncoding()
        gpu.commitAndWait(cb)
    }

    /// One SQGPU dispatch of a single-entry module: inputs by slot, constants by slot, data buffers by slot.
    func newDispatch(_ m: GPUShaderModule, entry: String? = nil, inputs: [Int: MTLTexture], output: MTLTexture? = nil,
                     constants: [Int: [UInt8]], buffers: [Int: MTLBuffer] = [:], size: (Int, Int)) throws {
        let p = try gpu.makePipeline(GPUKernel(m, entry ?? m.entries[0]))
        let cb = gpu.makeCommandBuffer()!
        let enc = cb.makeComputeEncoder()!
        enc.setPipeline(p)
        for (i, t) in inputs { enc.setInput(MetalGPUTexture(t), at: i) }
        if let output { enc.setOutput(MetalGPUTexture(output)) }
        for (i, c) in constants { c.withUnsafeBytes { enc.setConstantBytes($0, slot: i) } }
        for (i, b) in buffers { enc.setBuffer(MetalGPUBuffer(b), at: i) }
        enc.dispatch(width: size.0, height: size.1)
        enc.end()
        gpu.commitAndWait(cb)
    }

    func floats(_ b: MTLBuffer) -> [Float] { Array(UnsafeBufferPointer(start: b.contents().assumingMemoryBound(to: Float.self), count: b.length / 4)) }

    /// Video Denoise, Deflicker and Trails: stats + gains, the denoise (fast, best with motion search, half size), the
    /// spatial smooth and every Trails blend, old MSL against the Slang modules, Y'CbCr and alpha RGB sources.
    @Test func temporalKernelsMatchTheirOldMSL() throws {
        let o = MTLCompileOptions()
        o.mathMode = .safe
        o.languageVersion = .version3_1
        let lib = try dev.makeLibrary(source: LegacyTemporalShaderSource.msl, options: o)
        func bytes<T>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v) { Array($0) } }
        #expect(MemoryLayout<Compositor.Uniforms>.size == 368)
        var ycc = Compositor.Uniforms()
        ycc.mode = 0
        ycc.m = simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.1873, 1.8556), SIMD3(1.5748, -0.4681, 0)))
        ycc.range = SIMD4(1.164, -0.073, 1.138, -0.57)
        var rgb = Compositor.Uniforms()
        rgb.mode = 1; rgb.alphaMode = 1
        let n = 5
        let ys = (0..<n).map { randomTexture(w, h, seed: 60 + UInt64($0), opaque: true) }
        let cs = (0..<n).map { randomTexture(w, h, seed: 70 + UInt64($0)) }
        let tiles = 16 * 9
        for (label, cu) in [("ycc", ycc), ("rgb", rgb)] {
            // Stats and gains.
            for local in [UInt32(0), 1] {
                let mOld = dev.makeBuffer(length: n * tiles * 4, options: .storageModeShared)!
                let mNew = dev.makeBuffer(length: n * tiles * 4, options: .storageModeShared)!
                let gOld = dev.makeBuffer(length: n * tiles * 4, options: .storageModeShared)!
                let gNew = dev.makeBuffer(length: n * tiles * 4, options: .storageModeShared)!
                for j in 0..<n {
                    let p = bytes(SIMD4<UInt32>(UInt32(j), 16, 9, 0))
                    try legacyDispatch(lib, "temporalStats", textures: [0: ys[j], 1: cs[j]], bytes: [0: bytes(cu), 2: p],
                                       buffers: [1: mOld], size: (16, 9), groups: true)
                    try newDispatch(GeneratedShaders.temporalStats, inputs: [0: ys[j], 1: cs[j]], constants: [0: bytes(cu), 1: p],
                                    buffers: [2: mNew], size: (16 * 16, 9 * 16))
                }
                let d = Compositor.DeflickerUniforms(frames: UInt32(n), tiles: UInt32(tiles), dfBefore: 2, dfAfter: 2, statsBefore: 2,
                                                     local: local, strength: 0.8)
                try legacyDispatch(lib, "deflickerGains", textures: [:], bytes: [2: bytes(d)], buffers: [0: mOld, 1: gOld], size: (tiles, 1))
                try newDispatch(GeneratedShaders.deflickerGains, inputs: [:], constants: [0: bytes(d)], buffers: [2: mNew, 3: gNew],
                                size: (tiles, 1))
                let ma = floats(mOld), mb = floats(mNew), ga = floats(gOld), gb = floats(gNew)
                #expect(zip(ma, mb).allSatisfy { abs($0 - $1) <= 1e-4 }, "\(label) means")
                #expect(zip(ga, gb).allSatisfy { abs($0 - $1) <= 1e-4 }, "\(label) gains local \(local)")
                #expect(Set(gb).count > 1, "\(label) gains vary")

                // Denoise with these gains: fast and best (9 search offsets), full and half size.
                for (flags, outW, outH) in [(UInt32(3), w, h), (UInt32(15), w, h), (UInt32(5), w / 2, h / 2)] {
                    var t = Compositor.TemporalUniforms(count: UInt32(n), nBefore: 2, statsBefore: 2, flags: flags,
                                                        lumaS: 0.12, colorS: 0.1, motion: 0.2, keep: 0.1)
                    t.searchStep = 2; t.searchCount = flags & 4 != 0 ? 9 : 1; t.tilesX = 16; t.tilesY = 9
                    var tex: [Int: MTLTexture] = [:]
                    for i in 0..<11 { tex[i] = ys[min(i, n - 1)]; tex[11 + i] = cs[min(i, n - 1)] }
                    let a = blank(outW, outH), b = blank(outW, outH)
                    var old = tex; old[22] = a
                    try legacyDispatch(lib, "temporalDenoise", textures: old, bytes: [0: bytes(cu), 1: bytes(t)], buffers: [2: gOld],
                                       size: (outW, outH))
                    try newDispatch(GeneratedShaders.temporalDenoise, inputs: tex, output: b, constants: [0: bytes(cu), 1: bytes(t)],
                                    buffers: [3: gOld], size: (outW, outH))
                    expectSame(a, b, "\(label) temporalDenoise flags \(flags) \(outW)x\(outH) local \(local)")
                }
            }
            // Trails, every blend, from the planes and over a filtered center.
            for blend in [UInt32(0), 1, 2] {
                for flags: UInt32 in [0, 3] {
                    let tu = Compositor.TrailsUniforms(count: UInt32(n - 1), blend: blend, flags: flags,
                                                       w0: SIMD4(0.8, 0.6, 0.4, 0.2), w1: .zero)
                    var tex: [Int: MTLTexture] = [:]
                    for i in 0..<9 { tex[i] = ys[min(i, n - 1)]; tex[9 + i] = cs[min(i, n - 1)] }
                    tex[18] = randomTexture(w, h, seed: 80)
                    let a = blank(w, h), b = blank(w, h)
                    var old = tex; old[19] = a
                    try legacyDispatch(lib, "temporalTrails", textures: old, bytes: [0: bytes(cu), 1: bytes(tu)], size: (w, h))
                    try newDispatch(GeneratedShaders.temporalTrails, inputs: tex, output: b, constants: [0: bytes(cu), 1: bytes(tu)],
                                    size: (w, h))
                    expectSame(a, b, "\(label) temporalTrails blend \(blend) flags \(flags)")
                }
            }
        }
        // Spatial smooth.
        let src = randomTexture(w, h, seed: 90)
        for (r, s, lin) in [(Int32(1), Int32(1), UInt32(0)), (2, 2, 1)] {
            let su = Compositor.SpatialUniforms(radius: r, step: s, lumaS: 0.05, colorS: 0.06, linearize: lin)
            let a = blank(w, h), b = blank(w, h)
            try legacyDispatch(lib, "spatialDenoise", textures: [0: src, 1: a], bytes: [0: bytes(su)], size: (w, h))
            try newDispatch(GeneratedShaders.spatialDenoise, inputs: [0: src], output: b, constants: [0: bytes(su)], size: (w, h))
            expectSame(a, b, "spatialDenoise r \(r) step \(s)")
        }
    }

    /// Opt-in A/B (SQ_STACK_BENCH=1): 1080p temporal denoise, best mode with 9 search offsets over 11 frames, old MSL
    /// against the Slang module; GPU ms best of 10, appended to SQ_PERF_OUT (default $TMPDIR/sqstackcost.txt).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_STACK_BENCH"] != nil)) func measureTemporalDenoiseAgainstOldMSL() throws {
        let o = MTLCompileOptions()
        o.mathMode = .safe
        o.languageVersion = .version3_1
        let lib = try dev.makeLibrary(source: LegacyTemporalShaderSource.msl, options: o)
        let old = try dev.makeComputePipelineState(function: lib.makeFunction(name: "temporalDenoise")!)
        let new = try gpu.makePipeline(GPUKernel(GeneratedShaders.temporalDenoise, "temporalDenoise"))
        let (bw, bh) = (1920, 1080)
        let ys = (0..<11).map { randomTexture(bw, bh, seed: 100 + UInt64($0), opaque: true) }
        let cs = (0..<11).map { _ in randomTexture(bw / 2, bh / 2, seed: 120) }
        let out = blank(bw, bh)
        var cu = Compositor.Uniforms()
        cu.mode = 0
        var t = Compositor.TemporalUniforms(count: 11, nBefore: 5, statsBefore: 5, flags: 1 | 4, lumaS: 0.12, colorS: 0.1, motion: 0.2)
        t.searchStep = 4; t.searchCount = 9
        let gains = dev.makeBuffer(length: 4096, options: .storageModeShared)!
        func time(_ encode: (MTLCommandBuffer) -> Void) -> Double {
            var best = Double.infinity
            for _ in 0..<10 {
                let cb = gpu.makeCommandBuffer()!
                encode(cb.buffer)
                gpu.commitAndWait(cb)
                best = min(best, (cb.buffer.gpuEndTime - cb.buffer.gpuStartTime) * 1000)
            }
            return best
        }
        let a = time { cb in
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(old)
            for i in 0..<11 { enc.setTexture(ys[i], index: i); enc.setTexture(cs[i], index: 11 + i) }
            enc.setTexture(out, index: 22)
            enc.setBytes(&cu, length: MemoryLayout<Compositor.Uniforms>.stride, index: 0)
            enc.setBytes(&t, length: MemoryLayout<Compositor.TemporalUniforms>.stride, index: 1)
            enc.setBuffer(gains, offset: 0, index: 2)
            enc.dispatchThreads(MTLSize(width: bw, height: bh, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        }
        let b = time { cb in
            let enc = gpu.wrap(cb).makeComputeEncoder()!
            enc.setPipeline(new)
            for i in 0..<11 { enc.setInput(MetalGPUTexture(ys[i]), at: i); enc.setInput(MetalGPUTexture(cs[i]), at: 11 + i) }
            enc.setOutput(MetalGPUTexture(out))
            withUnsafeBytes(of: &cu) { enc.setConstantBytes($0, slot: 0) }
            withUnsafeBytes(of: &t) { enc.setConstantBytes($0, slot: 1) }
            enc.setBuffer(MetalGPUBuffer(gains), at: 3)
            enc.dispatch(width: bw, height: bh)
            enc.end()
        }
        let line = String(format: "temporalDenoise 1080p best x9, 11 frames: old MSL %.2f ms, Slang %.2f ms\n", a, b)
        let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] ?? NSTemporaryDirectory() + "sqstackcost.txt"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { try Data(line.utf8).write(to: URL(fileURLWithPath: path)) }
    }

    func planeValues(_ t: MTLTexture) -> [Float] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: t.width, height: t.height, mipmapped: false)
        d.storageMode = .shared
        let s = dev.makeTexture(descriptor: d)!
        let cb = gpu.makeCommandBuffer()!
        let blit = cb.buffer.makeBlitCommandEncoder()!
        blit.copy(from: t, to: s); blit.endEncoding()
        gpu.commitAndWait(cb)
        var px = [Float](repeating: 0, count: t.width * t.height)
        px.withUnsafeMutableBytes { s.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0) }
        return px
    }

    @Test func compositorCoreKernelsMatchTheirOldMSL() throws {
        let img = randomTexture(w, h, seed: 4), img2 = randomTexture(w, h, seed: 5)
        for (old, e) in [("premultipliedLinearToEncoded709", GPUKernels<MetalGPUDevice>.Entry.premultipliedLinearToEncoded709),
                         ("straightToPremultiplied", .straightToPremultiplied)] {
            let a = blank(w, h), b = blank(w, h)
            try runLegacy(old, inputs: [img], output: a, u: nil)
            runNew(e, inputs: [img], output: b, u: SIMD4<Float>.zero)
            expectSame(a, b, old)
        }
        for (x, y, opaque) in [(Float(0.37), Float(1), false), (0.8, 0, false), (0.5, 1, true)] {
            let p1 = opaque ? randomTexture(w, h, seed: 6, opaque: true) : img
            let p2 = opaque ? randomTexture(w, h, seed: 7, opaque: true) : img2
            let a = blank(w, h), b = blank(w, h)
            let p = SIMD2<Float>(x, y)
            try withUnsafeBytes(of: p) { try runLegacy("blendFrames", inputs: [p1, p2], output: a, u: $0) }
            runNew(.blendFrames, inputs: [p1, p2], output: b, u: SIMD4<Float>(x, y, 0, 0))
            expectSame(a, b, "blendFrames \(x) \(y) opaque \(opaque)")
        }
        // Blur: both axes (two dispatches each), with and without Repeat Edge Pixels.
        let weights = (0..<19).map { k in expf(-Float((k - 9) * (k - 9)) / 18) }
        let sum = weights.reduce(0, +), wn = weights.map { $0 / sum }
        for edges in [nil, (lo: SIMD2<Int32>(6, 5), hi: SIMD2<Int32>(90, 55))] as [(lo: SIMD2<Int32>, hi: SIMD2<Int32>)?] {
            let a = randomTexture(w, h, seed: 8), aTmp = blank(w, h)
            let b = randomTexture(w, h, seed: 8), bTmp = blank(w, h)
            for axis in [SIMD2<Int32>(1, 0), SIMD2<Int32>(0, 1)] {
                let bu = GPUBlurUniforms(axis: axis, radius: 9, clampEdges: edges == nil ? 0 : 1, lo: edges?.lo ?? .zero, hi: edges?.hi ?? .zero)
                let (src, dst) = axis.x == 1 ? (a, aTmp) : (aTmp, a)
                try withUnsafeBytes(of: bu) { try runLegacy("gaussianBlur1D", inputs: [src], output: dst, u: $0, extra: wn) }
            }
            let cb = gpu.makeCommandBuffer()!
            kernels.blur(cb, MetalGPUTexture(b), via: MetalGPUTexture(bTmp), weights: wn, repeatEdges: edges)
            gpu.commitAndWait(cb)
            expectSame(a, b, "gaussianBlur1D edges \(edges != nil)")
        }
    }

    /// Source conversion, effect masks, film look, Drop Shadow and the transition kernels: the compositor's MSL kernels
    /// against their Slang modules (the fragments still use that MSL until the draw moves too).
    @Test func compositorEffectKernelsMatchTheirOldMSL() throws {
        let o = MTLCompileOptions()
        o.mathMode = .safe
        o.languageVersion = .version3_1
        let lib = try dev.makeLibrary(source: LegacyCompositorShaderSource.msl, options: o)
        func bytes<T>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v) { Array($0) } }
        func fb(_ v: [Float]) -> [UInt8] { v.withUnsafeBytes { Array($0) } }
        func buffer(_ v: [Float]) -> MTLBuffer { dev.makeBuffer(bytes: v, length: v.count * 4, options: .storageModeShared)! }
        let out = GPUBinding.metalOutputIndex

        // Conversion: Y'CbCr and alpha RGB, full size, half size through two curves, an origin, the any-ratio scaled one.
        var ycc = Compositor.Uniforms()
        ycc.mode = 0
        ycc.m = simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.1873, 1.8556), SIMD3(1.5748, -0.4681, 0)))
        ycc.range = SIMD4(1.164, -0.073, 1.138, -0.57)
        var rgb = Compositor.Uniforms()
        rgb.mode = 1; rgb.alphaMode = 1
        var packed = ycc
        packed.mode = 4; packed.alphaMode = 2
        let y = randomTexture(w, h, seed: 80, opaque: true), c = randomTexture(w / 2 + 1, h / 2 + 1, seed: 81)
        let cases: [(String, Compositor.Uniforms, Int, Int, UInt32, SIMD2<UInt32>, String)] = [
            ("ycc full", ycc, w, h, .max, .zero, "convertToRGB"), ("ycc half 709", ycc, w / 2, h / 2, 2, .zero, "convertToRGB"),
            ("rgb half log", rgb, w / 2, h / 2, 5, .zero, "convertToRGB"), ("packed full", packed, w, h, .max, .zero, "convertToRGB"),
            ("ycc origin", ycc, w, h, .max, SIMD2(8, 4), "convertToRGB"), ("ycc scaled", ycc, 40, 25, 2, .zero, "convertToRGBScaled"),
            ("rgb scaled", rgb, 31, 17, .max, .zero, "convertToRGBScaled")]
        for (label, cu, ow, oh, transfer, origin, entry) in cases {
            let a = blank(ow, oh), b = blank(ow, oh)
            let grid = (ow - Int(origin.x), oh - Int(origin.y))
            try legacyDispatch(lib, entry, textures: [0: y, 1: c, 2: a], bytes: [0: bytes(cu), 1: bytes(origin), 2: bytes(transfer)],
                               size: grid)
            try newDispatch(GeneratedShaders.sourceConvert, entry: entry, inputs: [0: y, 1: c], output: b,
                            constants: [0: bytes(cu), 1: bytes(Compositor.ConvertUniforms(origin: origin, transfer: transfer))], size: grid)
            expectSame(a, b, "convert \(label)")
        }

        // Effect masks: a feathered polygon, an inverted subject matte (intersect), a color range and a tilted Picture mask.
        var mu = Compositor.Uniforms()
        mu.size = SIMD2(Float(w), Float(h)); mu.maskSize = mu.size; mu.scale = SIMD2(1, 1); mu.maskCount = 4
        let md = buffer([16, 3, 0, 0, 6, 0, 1, 0,   0, 0, 2, 1, 0, 0, 0.8, 1,   19, 0, 0, 0, 0, 0, 1, 10,   22, 0, 0, 0, 0, 0, 1, 7,
                         -30, -20, 35, -10, 0, 25,   0.5, 0.4, 0.3, 0.3, 0.2, 0,
                         1, 0.1, -0.1, 1, Float(w) / 2, Float(h) / 2, 1 / Float(w), 1 / Float(h), Float(w) / 2, Float(h) / 2,
                         0.1, 0.2, 500, 0])
        let pre = randomTexture(w, h, seed: 82), post = randomTexture(w, h, seed: 83)
        let mt = randomTexture(w, h, seed: 84), pm = randomTexture(w, h, seed: 85)
        do {
            let a = blank(w, h), b = blank(w, h)
            try legacyDispatch(lib, "maskScopeMix", textures: [0: pre, 1: post, 2: a, 3: mt, 4: pm, 5: pm], bytes: [0: bytes(mu)],
                               buffers: [1: md], size: (w, h))
            try newDispatch(GeneratedShaders.maskScope, inputs: [0: pre, 1: post, 3: mt, 4: pm, 5: pm], output: b,
                            constants: [0: bytes(mu)], buffers: [2: md], size: (w, h))
            expectSame(a, b, "maskScopeMix")
        }

        // Film look: every part on, then grain alone in color.
        var lu = Compositor.LookUniforms()
        lu.dims = SIMD4(Float(w), Float(h), 1.3, 0)
        lu.ids = SIMD4(1 | 8 | 16 | 32 | 64, 11, 12, 13)
        lu.grain = SIMD4(0.6, 2.5, 0.5, 0.4); lu.scan = SIMD4(0.5, 4, 0.4, 0); lu.chroma = SIMD4(3, 1.5, 0, 0)
        lu.track = SIMD4(0.7, 0.3, 0.4, 0); lu.aged = SIMD4(1, 1, 0.5, 0)
        var grainOnly = lu
        grainOnly.ids.x = 1; grainOnly.dims.w = 0.6
        for (label, l) in [("all", lu), ("color grain", grainOnly)] {
            let a = blank(w, h), b = blank(w, h)
            try legacyDispatch(lib, "filmLook", textures: [0: pre, 1: a], bytes: [0: bytes(l)], size: (w, h))
            try newDispatch(GeneratedShaders.filmLook, inputs: [0: pre], output: b, constants: [0: bytes(l)], size: (w, h))
            expectSame(a, b, "filmLook \(label)")
        }

        // Drop Shadow: extract into a reduced plane, composite behind and alone.
        struct ShadowUniforms { var offset: SIMD2<Float>; var color: SIMD4<Float>; var shadowOnly: Int32; var spread: Float }
        for only in [Int32(0), 1] {
            let su = ShadowUniforms(offset: SIMD2(3.5, -2.25), color: SIMD4(0.2, 0.1, 0.05, 0.8), shadowOnly: only, spread: 0.3)
            let pa = blank(w / 2, h / 2), pb = blank(w / 2, h / 2)
            try legacyDispatch(lib, "shadowExtract", textures: [0: pre, 1: pa], bytes: [0: bytes(su)], size: (w / 2, h / 2))
            try newDispatch(GeneratedShaders.dropShadow, entry: "shadowExtract", inputs: [0: pre], output: pb,
                            constants: [0: bytes(su)], size: (w / 2, h / 2))
            expectSame(pa, pb, "shadowExtract")
            let a = blank(w, h), b = blank(w, h)
            try legacyDispatch(lib, "shadowComposite", textures: [0: pre, 1: pa, 2: a], bytes: [0: bytes(su)], size: (w, h))
            try newDispatch(GeneratedShaders.dropShadow, entry: "shadowComposite", inputs: [0: pre, 1: pa], output: b,
                            constants: [0: bytes(su)], size: (w, h))
            expectSame(a, b, "shadowComposite only \(only)")
        }

        // Cover: exact smallest alpha, opaque and see-through sides, the new grid in whole groups.
        let opaque = randomTexture(w, h, seed: 86, opaque: true)
        for (label, t) in [("see-through", pre), ("opaque", opaque)] {
            let ca = buffer([1, 1]), cb = buffer([1, 1])
            try legacyDispatch(lib, "transitionCoverMin", textures: [0: t], bytes: [1: bytes(UInt32(1))], buffers: [0: ca], size: (w, h))
            try newDispatch(GeneratedShaders.transitionCover, inputs: [0: t], constants: [0: bytes(SIMD4<UInt32>(1, 0, 0, 0))],
                            buffers: [2: cb], size: ((w + 15) / 16 * 16, (h + 15) / 16 * 16))
            #expect(floats(ca) == floats(cb), "transitionCoverMin \(label)")
        }

        // Transitions: a side is (offset, blur, scale, opacity, zoomBlur, taps, rotation, mirror).
        let sideA: [Float] = [0.05, -0.02, 0.03, 0.01, 0.9, 1, 0, 0, 0.1, 1]
        let sideB: [Float] = [-0.1, 0.04, 0, 0, 1.1, 0.8, 0.2, 0, 0, 0]
        let canvas = SIMD2(Float(w), Float(h))
        for slot in [UInt32(0), 1] {
            let cover = buffer([1, 0.5])
            let bw = w + 20, bh = h + 12
            let a = blank(bw, bh), b = blank(bw, bh)
            try legacyDispatch(lib, "transitionPreBlur", textures: [0: pre, 1: a],
                               bytes: [0: fb(sideA), 1: bytes(Float(0.1)), 2: bytes(canvas), 4: bytes(slot)], buffers: [3: cover],
                               size: (bw, bh))
            try newDispatch(GeneratedShaders.transitionPreBlur, inputs: [0: pre], output: b,
                            constants: [0: fb(sideA), 1: bytes(Compositor.PreBlurUniforms(canvas: canvas, pad: 0.1, slot: slot))],
                            buffers: [2: cover], size: (bw, bh))
            expectSame(a, b, "transitionPreBlur slot \(slot)")
        }
        let tb = randomTexture(w, h, seed: 87)
        for compose in 0...16 {
            for shape in compose == 10 ? Array(0...14) : [0] {
                let dir: [Float] = compose == 4 || compose == 8 ? [Float(bitPattern: 0x1234567), 0]
                    : compose == 10 ? [Float(shape), 0] : [0.6, 0.8]
                let border: [Float] = compose == 3 ? [0.05, 1, 0.5, 0.2] : [0, 0, 0, 0]
                let tu = sideA + sideB + dir + [0.45, 0.08, Float(bitPattern: UInt32(compose))] + border
                let cover = buffer([1, compose == 0 ? 0.5 : 1])
                let a = blank(w, h), b = blank(w, h)
                try legacyDispatch(lib, "transitionMix", textures: [0: pre, 1: tb, 2: a], bytes: [0: fb(tu) + [0, 0, 0, 0]],
                                   buffers: [1: cover], size: (w, h))
                try newDispatch(GeneratedShaders.transitionMix, inputs: [0: pre, 1: tb], output: b,
                                constants: [0: fb(tu) + [0, 0, 0, 0]], buffers: [2: cover], size: (w, h))
                expectSame(a, b, "transitionMix compose \(compose) shape \(shape)")
            }
        }
    }

    /// The generic color chain: every grade of GradeFusionTests (every block kind, LUT kinds, several passes, Steps,
    /// columns, keys, every source space) through the old MSL `colorChain` / `colorChainInPlace` (ColorPipelineGPU,
    /// specialisation off) and through the Slang modules, whole texture and a region of a quarter-turned picture.
    @Test func colorChainMatchesItsOldMSL() throws {
        let ref = try ColorPipelineGPU(device: dev)
        ref.specialization = .off
        let input = randomTexture(w, h, seed: 100)
        for (name, p) in GradeFusionTests.grades() {
            let passes = p.gpuPasses
            let luts = try ref.luts(passes)
            for region in [nil, Compositor.SourceRegion(x: 5, y: 3, width: 40, height: 30)] {
                let turned = region != nil
                let a = blank(w, h), b = blank(w, h)
                let cb = gpu.makeCommandBuffer()!
                try ref.encode(p, source: input, destination: a, commandBuffer: cb.buffer, quarterTurned: turned, region: region)
                gpu.commitAndWait(cb)
                for (i, pass) in passes.enumerated() {
                    var hd = pass.header
                    hd.extra = SIMD4(turned ? 1 : 0, UInt32(region?.x ?? 0), UInt32(region?.y ?? 0), 0)
                    var secs = pass.sections
                    secs += [ColorPipelineGPU.Sec](repeating: ColorPipelineGPU.Sec(), count: ColorPipelineGPU.maxGroupSections - secs.count)
                    var curves = pass.curves
                    curves += [SIMD4<Float>](repeating: .zero, count: ColorPipelineGPU.maxCurves * 64 - curves.count)
                    let c0 = withUnsafeBytes(of: hd) { Array($0) } + secs.withUnsafeBytes { Array($0) }
                    let c1 = curves.withUnsafeBytes { Array($0) }
                    var inputs: [Int: MTLTexture] = [24: luts[i].0, 3: luts[i].1]
                    if i == 0 { inputs[0] = input }
                    try newDispatch(i == 0 ? GeneratedShaders.colorChain : GeneratedShaders.colorChainInPlace, inputs: inputs,
                                    output: b, constants: [0: c0, 1: c1], size: (region?.width ?? w, region?.height ?? h))
                }
                expectSame(a, b, "color chain \(name) region \(turned)")
            }
        }
    }

    /// One draw of the old MSL (inline samplers, old binding indices) and one of the Slang module (SQGPU samplers, new
    /// indices) onto copies of the same background, compared <= 1/255.
    struct DrawSide {
        var textures: [Int: MTLTexture] = [:], bytes: [Int: [UInt8]] = [:], buffers: [Int: MTLBuffer] = [:]
    }
    func compareDraw(_ what: String, legacy lib: MTLLibrary, _ oldVertex: String, _ oldFragment: String, _ old: DrawSide,
                     _ m: GPUShaderModule, _ vertex: String, _ fragment: String, _ new: DrawSide, blend: GPUBlend,
                     vertexBytes: [UInt8], count: Int, strip: Bool, background: MTLTexture,
                     legacySampler: MTLSamplerState? = nil) throws {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: oldVertex)
        d.fragmentFunction = lib.makeFunction(name: oldFragment)
        let ca = d.colorAttachments[0]!
        ca.pixelFormat = .rgba16Float
        if blend != .replace {
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
            let f: MTLBlendFactor = blend == .additive ? .one : .oneMinusSourceAlpha
            ca.destinationRGBBlendFactor = f; ca.destinationAlphaBlendFactor = f
        }
        let oldState = try dev.makeRenderPipelineState(descriptor: d)
        let newState = try gpu.makeRenderPipeline(GPURenderKernel(m, vertex: vertex, fragment: fragment), pixelFormat: .rgba16Float,
                                                  blend: blend).state
        var targets: [MTLTexture] = []
        for (state, side, slang) in [(oldState, old, false), (newState, new, true)] {
            let t = blank(background.width, background.height)
            let cb = gpu.makeCommandBuffer()!
            let blit = cb.buffer.makeBlitCommandEncoder()!
            blit.copy(from: background, to: t)
            blit.endEncoding()
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = t
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            let enc = cb.buffer.makeRenderCommandEncoder(descriptor: pass)!
            enc.setRenderPipelineState(state)
            enc.setCullMode(.none)
            if slang { gpu.bindSamplers(enc) } else if let legacySampler { enc.setFragmentSamplerState(legacySampler, index: 0) }
            vertexBytes.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            for (i, tex) in side.textures { enc.setFragmentTexture(tex, index: i) }
            for (i, b) in side.bytes { b.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: i) } }
            for (i, b) in side.buffers { enc.setFragmentBuffer(b, offset: 0, index: i) }
            enc.drawPrimitives(type: strip ? .triangleStrip : .triangle, vertexStart: 0, vertexCount: count)
            enc.endEncoding()
            gpu.commitAndWait(cb)
            targets.append(t)
        }
        expectSame(targets[0], targets[1], what)
    }

    /// The 7 render functions: the layer quad with its plain, blend-mode, fused film look and fused transition fragments,
    /// and the monitor's present pass.
    @Test func drawsMatchTheirOldMSL() throws {
        let o = MTLCompileOptions()
        o.mathMode = .safe
        o.languageVersion = .version3_1
        let lib = try dev.makeLibrary(source: LegacyCompositorShaderSource.msl, options: o)
        func bytes<T>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v) { Array($0) } }
        func fb(_ v: [Float]) -> [UInt8] { v.withUnsafeBytes { Array($0) } }
        func buffer(_ v: [Float]) -> MTLBuffer { dev.makeBuffer(bytes: v, length: v.count * 4, options: .storageModeShared)! }
        let bg = randomTexture(w, h, seed: 90)
        let y = randomTexture(w, h, seed: 91, opaque: true), c = randomTexture(w / 2 + 1, h / 2 + 1, seed: 92)
        let mt = randomTexture(w, h, seed: 93), pm = randomTexture(w, h, seed: 94)
        let md = buffer([16, 3, 0, 0, 6, 0, 1, 0,   0, 0, 2, 1, 0, 0, 0.8, 1,   19, 0, 0, 0, 0, 0, 1, 10,   22, 0, 0, 0, 0, 0, 1, 7,
                         -30, -20, 35, -10, 0, 25,   0.5, 0.4, 0.3, 0.3, 0.2, 0,
                         1, 0.1, -0.1, 1, Float(w) / 2, Float(h) / 2, 1 / Float(w), 1 / Float(h), Float(w) / 2, Float(h) / 2,
                         0.1, 0.2, 500, 0])
        let none = buffer([0, 0])

        var base = Compositor.Uniforms()
        base.canvas = SIMD2(Float(w), Float(h)); base.size = base.canvas; base.mode = 1; base.opacity = 0.85
        var rotated = base
        rotated.rotCos = cos(0.3); rotated.rotSin = sin(0.3); rotated.cornerRadius = 9; rotated.scale = SIMD2(0.8, 0.7)
        rotated.position = SIMD2(4, -3); rotated.anchor = SIMD2(2, 1)
        var ycc = base
        ycc.mode = 0
        ycc.m = simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(0, -0.1873, 1.8556), SIMD3(1.5748, -0.4681, 0)))
        ycc.range = SIMD4(1.164, -0.073, 1.138, -0.57)
        ycc.crop = SIMD4(0.05, 0.1, 0.08, 0.02); ycc.cropFeather = 4; ycc.tilt = SIMD3(0.2, -0.3, 600); ycc.quarter = 1
        var packed = ycc
        packed.mode = 4; packed.alphaMode = 2; packed.tilt = .zero; packed.quarter = 2; packed.roundFirst = 1; packed.cornerRadius = 6
        var solid = base
        solid.mode = 2; solid.solid = SIMD4(0.3, 0.6, 0.2, 1); solid.maskCount = 4; solid.maskSize = base.size
        var keyed = base
        keyed.keyCount = 2; keyed.key0 = SIMD4(120, 30, 20, 0.5); keyed.matte0 = SIMD4(0.2, 0.1, 0, 0)
        keyed.shape0 = SIMD4(0.4, 0.5, 0.3, 0.2); keyed.cc0 = SIMD4(1.2, 0.3, 0.9, 0.5)
        keyed.key1 = SIMD4(0.3, 0.1, 1, 0); keyed.matte1 = SIMD4(-0.3, 0, 0, 1); keyed.quarter = 3
        var matteView = keyed
        matteView.matte0.z = 1
        var group = keyed
        group.mode = 3; group.maskCount = 4; group.maskSize = base.size
        var part = base
        part.mode = 3; part.part = SIMD4(10, 6, Float(w) + 20, Float(h) + 12)

        let layerCases: [(String, Compositor.Uniforms, GPUBlend)] = [
            ("rgb", base, .premultipliedOver), ("rotated rounded", rotated, .premultipliedOver),
            ("ycc crop tilt quarter", ycc, .premultipliedOver), ("packed round first", packed, .premultipliedOver),
            ("solid masks", solid, .premultipliedOver), ("keys", keyed, .premultipliedOver), ("key matte view", matteView, .replace),
            ("group keys masks", group, .premultipliedOver), ("group part", part, .premultipliedOver), ("additive", rotated, .additive)]
        for (label, u, blend) in layerCases {
            let ub = bytes(u)
            let old = DrawSide(textures: [0: y, 1: c, 2: mt, 3: pm, 4: pm], bytes: [0: ub], buffers: [1: u.maskCount > 0 ? md : none])
            let new = DrawSide(textures: [0: y, 1: c, 3: mt, 4: pm, 5: pm], bytes: [0: ub], buffers: [2: u.maskCount > 0 ? md : none])
            try compareDraw("layer \(label)", legacy: lib, "compositeVertex", "compositeFragment", old, GeneratedShaders.layer,
                            "compositeVertex", "compositeFragment", new, blend: blend, vertexBytes: ub, count: 4, strip: true,
                            background: bg)
        }

        // Blend modes read the target (programmable blending, Apple GPUs).
        if dev.supportsFamily(.apple1) {
            for mode in [UInt32(1), 2, 3, 5, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 27] {
                var u = rotated
                u.blend = mode
                let ub = bytes(u)
                let old = DrawSide(textures: [0: y, 1: c, 2: mt, 3: pm, 4: pm], bytes: [0: ub], buffers: [1: none])
                let new = DrawSide(textures: [0: y, 1: c, 3: mt, 4: pm, 5: pm], bytes: [0: ub], buffers: [2: none])
                try compareDraw("blend \(mode)", legacy: lib, "compositeVertex", "compositeFragmentBlend", old, GeneratedShaders.layer,
                                "compositeVertex", "compositeFragmentBlend", new, blend: .replace, vertexBytes: ub, count: 4,
                                strip: true, background: bg)
            }
        }

        // Fused film look: every part on.
        var lu = Compositor.LookUniforms()
        lu.dims = SIMD4(Float(w), Float(h), 1.3, 0.4)
        lu.ids = SIMD4(1 | 8 | 16 | 32 | 64, 11, 12, 13)
        lu.grain = SIMD4(0.6, 2.5, 0.5, 0.4); lu.scan = SIMD4(0.5, 4, 0.4, 0); lu.chroma = SIMD4(3, 1.5, 0, 0)
        lu.track = SIMD4(0.7, 0.3, 0.4, 0); lu.aged = SIMD4(1, 1, 0.5, 0)
        for (label, u) in [("rgb", base), ("ycc", ycc)] {
            let ub = bytes(u)
            let old = DrawSide(textures: [0: y, 1: c, 2: mt, 3: pm, 4: pm], bytes: [0: ub, 2: bytes(lu)], buffers: [1: none])
            let new = DrawSide(textures: [0: y, 1: c, 3: mt, 4: pm, 5: pm], bytes: [0: ub, 1: bytes(lu)], buffers: [2: none])
            try compareDraw("look \(label)", legacy: lib, "compositeVertex", "compositeFragmentLook", old, GeneratedShaders.layerLook,
                            "compositeVertex", "compositeFragmentLook", new, blend: .replace, vertexBytes: ub, count: 4, strip: true,
                            background: bg)
        }

        // Fused transition: a few compose kinds, over and additive.
        let sideA: [Float] = [0.05, -0.02, 0.03, 0.01, 0.9, 1, 0, 0, 0.1, 1]
        let sideB: [Float] = [-0.1, 0.04, 0, 0, 1.1, 0.8, 0.2, 0, 0, 0]
        let tb = randomTexture(w, h, seed: 95)
        for (compose, blend) in [(UInt32(0), GPUBlend.premultipliedOver), (3, .premultipliedOver), (5, .additive), (10, .premultipliedOver)] {
            let border: [Float] = compose == 3 ? [0.05, 1, 0.5, 0.2] : [0, 0, 0, 0]
            let tu = fb(sideA + sideB + [0.6, 0.8, 0.45, 0.08, Float(bitPattern: compose)] + border + [0, 0, 0, 0])
            let cover = buffer([1, compose == 0 ? 0.5 : 1])
            let ub = bytes(base)
            let old = DrawSide(textures: [0: bg, 1: tb], bytes: [0: ub, 2: tu], buffers: [3: cover])
            let new = DrawSide(textures: [0: bg, 1: tb], bytes: [0: ub, 1: tu], buffers: [2: cover])
            try compareDraw("transition \(compose)", legacy: lib, "compositeVertex", "compositeFragmentTransition", old,
                            GeneratedShaders.layerTransition, "compositeVertex", "compositeFragmentTransition", new, blend: blend,
                            vertexBytes: ub, count: 4, strip: true, background: y)
        }

        // Present: SDR with a view gamma, P3, HDR roll-off; linear and nearest sampling of a smaller picture.
        let presentLib = try dev.makeLibrary(source: LegacyPresent.msl, options: nil)
        let picture = randomTexture(w / 2 + 3, h / 2 + 1, seed: 96)
        let p3 = simd_float3x3(columns: (SIMD3(0.8225, 0.0332, 0.0171), SIMD3(0.1774, 0.9669, 0.0724), SIMD3(0, 0, 0.9108)))
        for (mode, exponent, nearest) in [(Float(0), Float(1), false), (0, 1.1, true), (1, 1, false), (2, 1, false), (3, 1, true)] {
            let m = mode == 0 ? matrix_identity_float3x3 : p3
            struct ViewParams { var m0, m1, m2: SIMD4<Float>; var mode, peak, knee: Float }
            struct PresentU { var m0, m1, m2: SIMD4<Float>; var mode, peak, knee, exponent: Float; var nearest: UInt32 }
            let vp = ViewParams(m0: SIMD4(m.columns.0, 0), m1: SIMD4(m.columns.1, 0), m2: SIMD4(m.columns.2, 0), mode: mode, peak: 4,
                                knee: 0.75)
            let pu = PresentU(m0: vp.m0, m1: vp.m1, m2: vp.m2, mode: mode, peak: 4, knee: 0.75, exponent: exponent,
                              nearest: nearest ? 1 : 0)
            let sd = MTLSamplerDescriptor()
            sd.minFilter = nearest ? .nearest : .linear; sd.magFilter = sd.minFilter
            sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
            let sampler = dev.makeSamplerState(descriptor: sd)!
            let old = DrawSide(textures: [0: picture], bytes: [0: bytes(exponent), 1: bytes(vp)])
            let new = DrawSide(textures: [0: picture], bytes: [0: bytes(pu)])
            try compareDraw("present mode \(mode) exponent \(exponent) nearest \(nearest)", legacy: presentLib, "presentVertex",
                            "presentFragment", old, GeneratedShaders.present, "presentVertex", "presentFragment", new,
                            blend: .replace, vertexBytes: bytes(pu), count: 3, strip: false, background: bg,
                            legacySampler: sampler)
        }
    }

    /// Opt-in A/B (SQ_STACK_BENCH=1): 1080p blur r=18 + sharpen + noise, old MSL encoders vs the SQGPU path, interleaved.
    /// GPU ms best of 20 and CPU encode microseconds; appended to SQ_PERF_OUT (default $TMPDIR/sqstackcost.txt).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_STACK_BENCH"] != nil)) func measureSlangPathAgainstOldMSL() throws {
        let W = 1920, H = 1080
        let a = randomTexture(W, H, seed: 9), t = blank(W, H), o = blank(W, H)
        let wts = (0..<37).map { _ in Float(1) / 37 }
        let blurP = try dev.makeComputePipelineState(function: legacy.makeFunction(name: "gaussianBlur1D")!)
        let sharpP = try dev.makeComputePipelineState(function: legacy.makeFunction(name: "filterSharpen")!)
        let noiseP = try dev.makeComputePipelineState(function: legacy.makeFunction(name: "filterNoise")!)
        var su = GPUFilterUniforms(); su.a.x = 1; su.i = SIMD4(0, 0, Int32(W - 1), Int32(H - 1))
        var nu = GPUFilterUniforms(); nu.a.x = 0.2; nu.i = SIMD4(1, 1, 7, 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1), grid = MTLSize(width: W, height: H, depth: 1)
        func old(_ cb: MTLCommandBuffer, _ parts: Int) {
            if parts & 1 != 0 {
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(blurP)
            wts.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 1) }
            for (axis, s, d) in [(SIMD2<Int32>(1, 0), a, t), (SIMD2<Int32>(0, 1), t, a)] {
                var bu = GPUBlurUniforms(axis: axis, radius: 18)
                enc.setTexture(s, index: 0); enc.setTexture(d, index: 1)
                enc.setBytes(&bu, length: 32, index: 0)
                enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            }
            enc.endEncoding()
            }
            for (bit, p, var u) in [(2, sharpP, su), (4, noiseP, nu)] where parts & bit != 0 {
                let e = cb.makeComputeCommandEncoder()!
                e.setComputePipelineState(p); e.setTexture(a, index: 0); e.setTexture(o, index: 1)
                e.setBytes(&u, length: MemoryLayout<GPUFilterUniforms>.stride, index: 0)
                e.dispatchThreads(grid, threadsPerThreadgroup: tg)
                e.endEncoding()
            }
        }
        func new(_ cb: MTLCommandBuffer, _ parts: Int) {
            let g = gpu.wrap(cb), ta = MetalGPUTexture(a), to = MetalGPUTexture(o)
            if parts & 1 != 0 { kernels.blur(g, ta, via: MetalGPUTexture(t), weights: wts) }
            if parts & 2 != 0 { kernels.sharpen(g, ta, into: to, amount: 1, rect: (0, 0, W - 1, H - 1)) }
            if parts & 4 != 0 { kernels.noise(g, ta, into: to, amount: 0.2, color: true, clip: true, seed: 7) }
        }
        var lines: [String] = []
        for (parts, label) in [(1, "blur r18"), (2, "sharpen"), (4, "noise"), (7, "blur+sharpen+noise")] {
        var gpuBest = [Double.infinity, .infinity], cpuBest = [Double.infinity, .infinity]
        for i in 0..<23 {
            for side in 0..<2 {
                let cb = gpu.makeCommandBuffer()!.buffer
                let t0 = DispatchTime.now().uptimeNanoseconds
                side == 0 ? old(cb, parts) : new(cb, parts)
                let enc = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
                cb.commit(); cb.waitUntilCompleted()
                if i >= 3 {
                    gpuBest[side] = min(gpuBest[side], (cb.gpuEndTime - cb.gpuStartTime) * 1000)
                    cpuBest[side] = min(cpuBest[side], enc)
                }
            }
        }
        lines.append(String(format: "%@: gpu ms old %.3f new %.3f, encode us old %.1f new %.1f",
                            label, gpuBest[0], gpuBest[1], cpuBest[0], cpuBest[1]))
        }
        let line = "SQSLANG 1080p " + lines.joined(separator: " | ")
        NSLog("%@", line)
        let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] ?? (NSTemporaryDirectory() + "sqstackcost.txt")
        if let hd = FileHandle(forWritingAtPath: path) { try? hd.seekToEnd(); try? hd.write(contentsOf: Data((line + "\n").utf8)); try? hd.close() }
        else { try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    }
}

struct SplitMix {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9e37_79b9_7f4a_7c15
        var z = s
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// The monitor's present pass as it was before Seam 4 (Presenter.shaderSource), for SlangParityTests.
enum LegacyPresent {
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut presentVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);          // full-viewport triangle
        VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
    }
    inline float3 oetf709(float3 l) {
        l = max(l, 0.0f);
        return select(1.09929682680944f * pow(l, 0.45f) - 0.09929682680944f, 4.5f * l, l < 0.018053968510807f);
    }
    struct ViewParams { float4 m0; float4 m1; float4 m2; float mode; float peak; float knee; };
    fragment float4 presentFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                                  constant float &viewExponent [[buffer(0)]],
                                  constant ViewParams &vp [[buffer(1)]]) {
        float4 px = tex.sample(s, in.uv);
        float3 lin = vp.mode == 0.0f ? px.rgb : max(float3x3(vp.m0.xyz, vp.m1.xyz, vp.m2.xyz) * px.rgb, 0.0f);
        float3 code;
        if (vp.mode < 1.5f) {
            code = saturate(oetf709(lin));
            if (viewExponent != 1.0f) { code = pow(code, float3(viewExponent)); }
        } else {
            code = lin;
            float mx = max(lin.x, max(lin.y, lin.z));
            if (vp.mode == 2.0f && mx > 0.0f) {
                float m = mx / vp.peak;
                if (m > vp.knee) { float r = 1.0f - vp.knee; m = vp.knee + r * (1.0f - exp(-(m - vp.knee) / r)); }
                code = lin * (m * vp.peak / mx);
            }
        }
        float a = saturate(px.a);
        if (a < 1.0f) {
            uint2 cell = uint2(in.pos.xy) / 16u;
            float checker = ((cell.x + cell.y) & 1u) == 0u ? 0.20f : 0.32f;
            code = code + (1.0f - a) * checker;
        }
        return float4(vp.mode < 1.5f ? saturate(code) : code, 1.0);
    }
    """
}
#endif
