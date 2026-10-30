import SQGPU

// The second reference graph: one picture through every shader family that is not an effect filter (source conversion,
// temporal stats / deflicker / denoise / trails, spatial denoise, both color chain entries, optical flow, film look, drop
// shadow, outline, long shadow, anti-flicker, mask scope, transition cover / pre-blur / mix, scopes) and the draws (layer,
// layer + look, fused transition, blend mode via the destination copy, present). Uniforms are packed by byte offset from
// the Slang structs, so the graph needs nothing but the SQGPU protocol and GeneratedShaders.
extension GPUReferenceGraph {
    /// A constant block packed by byte offset (4-byte words; `bytes` = the struct's size, a multiple of 16).
    struct Block {
        var words: [UInt32]
        init(bytes: Int) { words = [UInt32](repeating: 0, count: bytes / 4) }
        mutating func f(_ at: Int, _ v: Float...) { for (i, x) in v.enumerated() { words[at / 4 + i] = x.bitPattern } }
        mutating func u(_ at: Int, _ v: UInt32...) { for (i, x) in v.enumerated() { words[at / 4 + i] = x } }
    }

    /// CompositeU (Parts/CompositeU.slang, 368 bytes): full-range BT.709 Y'CbCr matrix, one layer of `size` on `canvas`.
    static func composite(mode: UInt32, canvas: SIMD2<Float>, size: SIMD2<Float>) -> Block {
        var b = Block(bytes: 368)
        b.f(0, 1, 1, 1, 0); b.f(16, 0, -0.187324, 1.8556, 0); b.f(32, 1.5748, -0.468124, 0, 0)   // m0...m2
        b.f(64, 1, 0, 1, -0.5)                                                                   // range
        b.f(80, canvas.x, canvas.y, size.x, size.y)                                              // canvas, size
        b.f(112, 1, 1, 1, 0, 1)                                                                  // scale, rotCos, rotSin, opacity
        b.u(132, mode)
        b.f(152, size.x, size.y)                                                                 // maskSize
        b.f(272, 1, 0, 1, 0); b.f(288, 1, 0, 1, 0)                                               // cc0, cc1 neutral
        return b
    }

    /// Y'CbCr planes (full range) of the test picture moved `shift` px right and scaled in brightness by `gain`: luma
    /// (Y, Y, Y, 1) full size, chroma (Cb, Cr, 0, 1) half size; rgba32Float rows.
    static func planes(shift: Int, gain: Float) -> (luma: [Float], chroma: [Float]) {
        let w = width, h = graphHeight, src = inputPixels()
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let i = (y * w + min(max(x - shift, 0), w - 1)) * 4
            return SIMD3(src[i], min(src[i + 1], 1), src[i + 2]) * gain
        }
        var luma = [Float](repeating: 1, count: w * h * 4), chroma = [Float](repeating: 1, count: w / 2 * h / 2 * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = rgb(x, y), yy = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z, i = (y * w + x) * 4
                luma[i] = yy; luma[i + 1] = yy; luma[i + 2] = yy
                if x % 2 == 0 && y % 2 == 0 {
                    let j = ((y / 2) * (w / 2) + x / 2) * 4
                    chroma[j] = (c.z - yy) / 1.8556 + 0.5; chroma[j + 1] = (c.x - yy) / 1.5748 + 0.5; chroma[j + 2] = 0
                }
            }
        }
        return (luma, chroma)
    }

    /// The families graph, `width x graphHeight`: 8-bit BT.709 code values from the present draw, alpha 255.
    static func renderFamilies<D: GPUDevice>(on device: D, kernels: GPUKernels<D>) throws -> [UInt8] {
        let w = width, h = graphHeight, fw = Float(w), fh = Float(h)
        let canvas = SIMD2<Float>(fw, fh)
        func tex(_ tw: Int = w, _ th: Int = h, _ format: GPUPixelFormat = .rgba16Float, cpu: Bool = false) throws -> D.Texture {
            guard let t = device.makeTexture(GPUTextureDescriptor(width: tw, height: th, format: format, cpuAccessible: cpu)) else {
                throw GPUError.deviceUnavailable("texture \(tw)x\(th)")
            }
            return t
        }
        func buffer(_ words: [UInt32]) throws -> D.Buffer {
            guard let b = device.makeBuffer(length: words.count * 4) else { throw GPUError.deviceUnavailable("buffer") }
            words.withUnsafeBytes { device.upload($0, to: b) }
            return b
        }
        func compute(_ m: GPUShaderModule, _ entry: String) throws -> D.Pipeline { try device.makePipeline(GPUKernel(m, entry)) }
        guard let cb = device.makeCommandBuffer() else { throw GPUError.deviceUnavailable("command buffer") }
        func run(_ p: D.Pipeline, _ inputs: [Int: D.Texture], _ out: D.Texture, _ blocks: [Block],
                 buffers: [Int: D.Buffer] = [:], grid: (Int, Int)? = nil) {
            guard let enc = cb.makeComputeEncoder() else { return }
            enc.setPipeline(p)
            for (slot, t) in inputs { enc.setInput(t, at: slot) }
            for (slot, b) in buffers { enc.setBuffer(b, at: slot) }
            for (slot, b) in blocks.enumerated() { b.words.withUnsafeBytes { enc.setConstantBytes($0, slot: slot) } }
            enc.setOutput(out)
            let g = grid ?? (out.width, out.height)
            enc.dispatch(width: g.0, height: g.1)
            enc.end()
        }
        func draw(_ p: D.RenderPipeline, into target: D.Texture, clear: SIMD4<Float>? = nil, _ inputs: [Int: D.Texture],
                  _ blocks: [Block], buffers: [Int: D.Buffer] = [:], strip: Bool = true) {
            guard let enc = cb.makeRenderEncoder(target: target, clear: clear) else { return }
            enc.setPipeline(p)
            for (slot, t) in inputs { enc.setInput(t, at: slot) }
            for (slot, b) in buffers { enc.setBuffer(b, at: slot) }
            for (slot, b) in blocks.enumerated() { b.words.withUnsafeBytes { enc.setConstantBytes($0, slot: slot) } }
            enc.draw(strip ? .triangleStrip : .triangles, vertexCount: strip ? 4 : 3)
            enc.end()
        }
        var keep: [D.Texture] = []
        let acquire: (Int, Int) -> D.Texture? = { tw, th in
            guard let t = try? tex(tw, th) else { return nil }
            keep.append(t)
            return t
        }
        /// rgba32Float CPU rows -> a GPU rgba16Float texture (blendFrames with weight 0 copies an opaque picture).
        func upload(_ px: [Float], _ tw: Int, _ th: Int) throws -> D.Texture {
            let staging = try tex(tw, th, .rgba32Float, cpu: true), t = try tex(tw, th)
            px.withUnsafeBytes { device.upload($0, bytesPerRow: tw * 16, to: staging) }
            kernels.blendFrames(cb, staging, staging, into: t, weight: 0, encoded: false)
            keep.append(staging)
            return t
        }

        // Three frames (before, center, after) as Y'CbCr planes: moving and flickering.
        var lumas: [D.Texture] = [], chromas: [D.Texture] = []
        for (shift, gain) in [(0, Float(0.92)), (3, 1), (6, 1.06)] {
            let p = planes(shift: shift, gain: gain)
            lumas.append(try upload(p.luma, w, h)); chromas.append(try upload(p.chroma, w / 2, h / 2))
        }
        let ycc = composite(mode: 0, canvas: canvas, size: canvas)
        let scratch = try tex()   // output of the passes that only write data buffers

        // Source conversion: the before and center frames, the after frame at half size (scaled).
        let convert = try compute(GeneratedShaders.sourceConvert, "convertToRGB")
        let convertScaled = try compute(GeneratedShaders.sourceConvert, "convertToRGBScaled")
        var conv = Block(bytes: 16); conv.u(8, 2)                         // transfer 2: averages in light
        let s0 = try tex(), s1 = try tex(), small = try tex(w / 2, h / 2)
        run(convert, [0: lumas[0], 1: chromas[0]], s0, [ycc, conv])
        run(convert, [0: lumas[1], 1: chromas[1]], s1, [ycc, conv])
        run(convertScaled, [0: lumas[2], 1: chromas[2]], small, [ycc, conv])

        // Temporal: tile means of every frame (stats order: center, before, after), deflicker gains, denoise, trails.
        let tilesX = 4, tilesY = 3, tiles = tilesX * tilesY
        let means = try buffer([UInt32](repeating: 0, count: 3 * tiles)), gains = try buffer([UInt32](repeating: 0, count: 3 * tiles))
        let stats = try compute(GeneratedShaders.temporalStats, "temporalStats")
        for (frame, k) in [1, 0, 2].enumerated() {
            var su = Block(bytes: 16); su.u(0, UInt32(frame), UInt32(tilesX), UInt32(tilesY))
            run(stats, [0: lumas[k], 1: chromas[k]], scratch, [ycc, su], buffers: [2: means], grid: (tilesX * 16, tilesY * 16))
        }
        var du = Block(bytes: 32); du.u(0, 3, UInt32(tiles), 1, 1, 1, 0); du.f(24, 0.8)
        run(try compute(GeneratedShaders.deflickerGains, "deflickerGains"), [:], scratch, [du],
            buffers: [2: means, 3: gains], grid: (tiles, 1))
        var tu = Block(bytes: 48)
        tu.u(0, 3, 1, 1, 1 | 2 | 4); tu.f(16, 0.12, 0.1, 0.25, 0.2); tu.u(32, 2, 9, UInt32(tilesX), UInt32(tilesY))
        let denoised = try tex()
        run(try compute(GeneratedShaders.temporalDenoise, "temporalDenoise"),
            [0: lumas[1], 11: chromas[1], 1: lumas[0], 12: chromas[0], 2: lumas[2], 13: chromas[2]], denoised, [ycc, tu],
            buffers: [3: gains])
        var ru = Block(bytes: 48); ru.u(0, 2, 1, 0); ru.f(16, 0.5, 0.25)
        let trails = try tex()
        run(try compute(GeneratedShaders.temporalTrails, "temporalTrails"),
            [0: lumas[1], 9: chromas[1], 1: lumas[0], 10: chromas[0], 2: lumas[2], 11: chromas[2]], trails, [ycc, ru])
        let temporal = try tex(), smooth = try tex()
        kernels.blendFrames(cb, denoised, trails, into: temporal, weight: 0.4, encoded: false)
        var sp = Block(bytes: 32); sp.u(0, 2, 1); sp.f(8, 0.08, 0.06)
        run(try compute(GeneratedShaders.spatialDenoise, "spatialDenoise"), [0: temporal], smooth, [sp])

        // Color chain: basic (white balance matrix, exposure, contrast) + curves, then a vignette in place.
        var chain = Block(bytes: 3104)
        chain.u(0, 2, 0, 3, 2)                                            // 2 blocks, source-encoded -> working-linear, Rec.709
        chain.u(32, 1, 1, 7, 0); chain.f(48, 1.25, 1.15)                  // basic: matrix + exposure + contrast
        chain.f(72, 1, 0, 0.2126, 0.7152, 0.0722)                         // saturation 1, vibrance 0, luma weights
        chain.f(112, 1.06, 0, 0, 0); chain.f(128, 0, 1, 0, 0); chain.f(144, 0, 0, 0.9, 0)
        chain.u(160, 4, 1, 0, 0)                                          // curves, table 0
        var curves = Block(bytes: 3072)
        for i in 0..<64 {
            let x = Float(i) / 63, s = x * x * (3 - 2 * x)
            curves.f(i * 16, 0.6 * s + 0.4 * x, 0.7 * s + 0.3 * x, 0.5 * s + 0.5 * x, 0)
        }
        let graded = try tex()
        run(try compute(GeneratedShaders.colorChain, "colorChain"), [0: smooth], graded, [chain, curves])
        var vignette = Block(bytes: 3104)
        vignette.u(0, 1, 1, 1, 2); vignette.u(32, 6, 1, 0, 0); vignette.f(48, -1.2, 0.35, 0.6, 2)
        run(try compute(GeneratedShaders.colorChainInPlace, "colorChainInPlace"), [:], graded, [vignette, curves])

        // Optical flow between the before and center frames: coarse level from zero, fine level from the coarse one,
        // backward field, trust both ways, the picture halfway.
        let flow = GeneratedShaders.opticalFlow
        let fW = w / 4, fH = h / 4, cW = (fW + 1) / 2, cH = (fH + 1) / 2
        var fu = Block(bytes: 48); fu.u(0, 3); fu.f(4, 1e-3, 1 / 8, 1.5, 0.5); fu.u(20, 1); fu.f(24, 4, 4, 0.15)
        var fuUp = fu; fuUp.u(36, 1)
        let ofLuma = try compute(flow, "ofLuma"), ofDown = try compute(flow, "ofDown"), ofGrad = try compute(flow, "ofGrad")
        let ofUp = try compute(flow, "ofUp"), ofLK = try compute(flow, "ofLK"), ofMedian = try compute(flow, "ofMedian")
        let l0 = try tex(fW, fH), l1 = try tex(fW, fH), c0 = try tex(cW, cH), c1 = try tex(cW, cH)
        let g0 = try tex(fW, fH), g1 = try tex(fW, fH), cg0 = try tex(cW, cH), cg1 = try tex(cW, cH)
        let cv0 = try tex(cW, cH), cf = try tex(cW, cH), cm = try tex(cW, cH)
        let up = try tex(fW, fH), fwd = try tex(fW, fH), fwdM = try tex(fW, fH), zero = try tex(fW, fH), bwd = try tex(fW, fH)
        let bwdM = try tex(fW, fH), trustF = try tex(fW, fH), trustB = try tex(fW, fH), between = try tex()
        run(ofLuma, [0: s0], l0, [fu]); run(ofLuma, [0: s1], l1, [fu])
        run(ofDown, [0: l0], c0, [fu]); run(ofDown, [0: l1], c1, [fu])
        run(ofGrad, [0: c0], cg0, [fu]); run(ofGrad, [0: c1], cg1, [fu])
        run(ofUp, [0: cm], cv0, [fu])                                     // hasPrev 0: zero field
        run(ofLK, [0: c0, 1: cg0, 2: c1, 3: cg1, 4: cv0], cf, [fu])
        run(ofMedian, [0: cf], cm, [fu])
        run(ofUp, [0: cm], up, [fuUp])
        run(ofGrad, [0: l0], g0, [fu]); run(ofGrad, [0: l1], g1, [fu])
        run(ofLK, [0: l0, 1: g0, 2: l1, 3: g1, 4: up], fwd, [fu])
        run(ofMedian, [0: fwd], fwdM, [fu])
        run(ofUp, [0: cm], zero, [fu])
        run(ofLK, [0: l1, 1: g1, 2: l0, 3: g0, 4: zero], bwd, [fu])
        run(ofMedian, [0: bwd], bwdM, [fu])
        let ofConfidence = try compute(flow, "ofConfidence")
        run(ofConfidence, [0: l0, 1: l1, 2: fwdM, 3: bwdM], trustF, [fu])
        run(ofConfidence, [0: l1, 1: l0, 2: bwdM, 3: fwdM], trustB, [fu])
        run(try compute(flow, "ofInterpolate"), [0: s0, 1: s1, 2: trustF, 3: trustB], between, [fu])

        // Graded picture over the in-between frame, given the test picture's alpha falloff, premultiplied; film look
        // (every flag); drop shadow; outline; long shadow; anti-flicker.
        let mixed = try tex(), cut = try tex(), pm = try tex(), look = try tex()
        kernels.blendFrames(cb, graded, between, into: mixed, weight: 0.35, encoded: false)
        kernels.blendFrames(cb, mixed, try upload(inputPixels(), w, h), into: cut, weight: 0.7, encoded: false)
        kernels.premultiply(cb, cut, into: pm)
        var lu = Block(bytes: 112)
        lu.f(0, fw, fh, 0.3, 0.5); lu.u(16, 1 | 8 | 16 | 32 | 64, 11, 23, 5)
        lu.f(32, 0.4, 2.1, 0.5, 0.5); lu.f(48, 0.3, 4, 0.5, 0); lu.f(64, 2, 1); lu.f(80, 0.5, 0.2, 0.4); lu.f(96, 0.8, 0.8, 0.5)
        run(try compute(GeneratedShaders.filmLook, "filmLook"), [0: pm], look, [lu])
        var shadow = Block(bytes: 48); shadow.f(0, 6, 4); shadow.f(16, 0.05, 0, 0.1, 0.7); shadow.f(36, 0.2)
        let alpha = try tex(), alphaB = try tex(), shadowed = try tex()
        run(try compute(GeneratedShaders.dropShadow, "shadowExtract"), [0: look], alpha, [shadow])
        kernels.blur(cb, alpha, via: alphaB, weights: gaussianWeights(sigma: 2.5))
        run(try compute(GeneratedShaders.dropShadow, "shadowComposite"), [0: look, 1: alpha], shadowed, [shadow])
        let outlined = try tex(), long = try tex(), calm = try tex()
        kernels.outline(cb, shadowed, into: outlined, jumpSteps: [8, 4, 2, 1], width: 3, softness: 1, color: SIMD3(1, 0.8, 0.2),
                        position: 0, acquire: acquire)
        kernels.longShadow(cb, outlined, into: long, planeWidth: w, planeHeight: h, steps: [SIMD3(4, 3, 0.9), SIMD3(8, 6, 0.8)],
                           color: SIMD3(0.1, 0, 0.2), opacity: 0.6, acquire: acquire)
        kernels.antiFlicker(cb, long, into: calm, k: 0.2)

        // Mask scope: the effect (calm) shows inside a soft pentagon intersected with a color range, the plain picture outside.
        var mask: [Float] = [8, 5, 0, 0, 14, 0, 1, 0,   13, 3, 2, 0, 0, 0, 1, 10]
        for k in 0..<5 {
            let a = Float(k) * 2 * .pi / 5 - .pi / 2
            mask += [cosApprox(a) * 70, sinApprox(a) * 70]
        }
        mask += [0.6, 0.5, 0.4, 0.35, 0.2, 0]
        let maskData = try buffer(mask.map(\.bitPattern))
        var scope = composite(mode: 3, canvas: canvas, size: canvas); scope.u(316, 2)
        let scoped = try tex()
        run(try compute(GeneratedShaders.maskScope, "maskScopeMix"), [0: pm, 1: calm], scoped, [scope], buffers: [2: maskData])

        // Transition: smallest alpha of both sides, a mirrored pre-blur of side A, a wipe between it and the small frame.
        let cover = try buffer([Float(1).bitPattern, Float(1).bitPattern])
        let c0u = Block(bytes: 16)
        var c1u = Block(bytes: 16); c1u.u(0, 1)
        let coverMin = try compute(GeneratedShaders.transitionCover, "transitionCoverMin")
        run(coverMin, [0: scoped], scratch, [c0u], buffers: [2: cover], grid: (320, 192))
        run(coverMin, [0: small], scratch, [c1u], buffers: [2: cover], grid: (160, 96))
        var side = Block(bytes: 48); side.f(0, 0.02, 0, 0.01, 0, 1.05, 1, 0, 0, 0.05, 1)
        var pre = Block(bytes: 16); pre.f(0, fw, fh)
        let sideA = try tex(), wipe = try tex()
        run(try compute(GeneratedShaders.transitionPreBlur, "transitionPreBlur"), [0: scoped], sideA, [side, pre], buffers: [2: cover])
        var tr = Block(bytes: 128)
        tr.f(0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, -0.03, 0.01, 0.005, 0, 1.1, 0.9, 0.2, 0, 0.1, 0)
        tr.f(80, 0.8, 0.6, 0.5, 0.1); tr.u(96, 3); tr.f(100, 2, 1, 1, 1)
        run(try compute(GeneratedShaders.transitionMix, "transitionMix"), [0: sideA, 1: small], wipe, [tr], buffers: [2: cover])

        // Scopes of the wipe: luma waveform and histograms, their maximum, the normalized waveform as a picture.
        let waveW = 64, waveL = 64, hist = waveW * waveL, maxSlot = hist + 4 * 256
        let counts = try buffer([UInt32](repeating: 7, count: maxSlot + 1))
        let scopes = GeneratedShaders.scopes, wave = try tex(waveW, waveL)
        func scopeU(offset: Int, count: Int, rowWidth: Int) -> Block {
            var b = Block(bytes: 80)
            b.u(0, UInt32(w), UInt32(h), 1, 1 | 8, UInt32(waveW), UInt32(waveL), 64, UInt32(rowWidth), 0, 0, 0, UInt32(hist))
            b.u(48, UInt32(offset), UInt32(count), UInt32(maxSlot)); b.u(64, UInt32(waveW), UInt32(waveL))
            return b
        }
        run(try compute(scopes, "scopeClear"), [:], wave, [scopeU(offset: 0, count: maxSlot + 1, rowWidth: 64)],
            buffers: [2: counts], grid: (64, (maxSlot + 64) / 64))
        run(try compute(scopes, "scopeAccumulate"), [0: wipe], wave, [scopeU(offset: 0, count: 0, rowWidth: 64)],
            buffers: [2: counts], grid: (w, h))
        run(try compute(scopes, "scopeFindMax"), [:], wave, [scopeU(offset: 0, count: hist, rowWidth: 64)],
            buffers: [2: counts], grid: (64, 64))
        run(try compute(scopes, "scopeResolve"), [:], wave, [scopeU(offset: 0, count: hist, rowWidth: 64)], buffers: [2: counts])

        // Draws on the canvas: the wipe as a turned, rounded, masked layer; the waveform with grain and scanlines; the fused
        // transition (light leak) at half opacity; a solid in the Color blend mode (destination read from a copy); present.
        let target = try tex(), destination = try tex()
        let over = GPUBlend.premultipliedOver
        let layerDraw = try device.makeRenderPipeline(GPURenderKernel(GeneratedShaders.layer, vertex: "compositeVertex",
                                                                      fragment: "compositeFragment"), format: .rgba16Float, blend: over)
        var layer = composite(mode: 3, canvas: canvas, size: canvas)
        layer.f(96, 10, -6, 0, 0, 0.85, 0.85, cosApprox(0.14), sinApprox(0.14), 1)
        layer.f(140, 12); layer.f(160, 0.02, 0.03, 0.04, 0.01); layer.u(316, 1)
        draw(layerDraw, into: target, clear: SIMD4(0.03, 0.03, 0.05, 1), [0: wipe], [layer], buffers: [2: maskData])

        let lookDraw = try device.makeRenderPipeline(GPURenderKernel(GeneratedShaders.layerLook, vertex: "compositeVertex",
                                                                     fragment: "compositeFragmentLook"), format: .rgba16Float, blend: over)
        var waveLayer = composite(mode: 1, canvas: canvas, size: SIMD2(Float(waveW), Float(waveL)))
        waveLayer.f(96, -110, -45); waveLayer.f(112, 1.2, 1.2); waveLayer.f(128, 0.9)
        var waveLook = lu; waveLook.u(16, 1 | 8)
        draw(lookDraw, into: target, [0: wave], [waveLayer, waveLook], buffers: [2: maskData])

        let fused = try device.makeRenderPipeline(GPURenderKernel(GeneratedShaders.layerTransition, vertex: "compositeVertex",
                                                                  fragment: "compositeFragmentTransition"), format: .rgba16Float, blend: over)
        var full = composite(mode: 3, canvas: canvas, size: canvas); full.f(128, 0.5)
        // Light leak, not glitch: the glitch's 24 row bands are 7.5 px on this 180-row canvas, so pixel centers sit exactly
        // on band edges where the backends' rounding picks different bands (also why the grain size is 2.1, not 2).
        var leak = tr; leak.u(96, 6)
        draw(fused, into: target, [0: sideA, 1: small], [full, leak], buffers: [2: cover])

        let blendDraw = try device.makeRenderPipeline(GPURenderKernel(GeneratedShaders.layer, vertex: "compositeVertex",
                                                                      fragment: "compositeFragmentBlend"), format: .rgba16Float, blend: .replace)
        cb.copy(target, to: destination)
        var solid = composite(mode: 2, canvas: canvas, size: SIMD2(120, 70))
        solid.f(48, 0.9, 0.2, 0.05, 1); solid.f(96, 70, 30); solid.f(128, 0.8); solid.u(148, 25)
        draw(blendDraw, into: target, [6: destination], [solid])

        let present = try device.makeRenderPipeline(GPURenderKernel(GeneratedShaders.present, vertex: "presentVertex",
                                                                    fragment: "presentFragment"), format: .rgba16Float, blend: .replace)
        var pu = Block(bytes: 96); pu.f(0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0); pu.f(48, 0, 1, 0.8, 1.1)
        let shown = try tex(), out = try tex(w, h, .rgba32Float, cpu: true)
        draw(present, into: shown, [0: target], [pu], strip: false)
        kernels.blendFrames(cb, shown, shown, into: out, weight: 0, encoded: false)
        device.commitAndWait(cb)
        _ = keep
        return bytes8(device.download(out), count: w * h * 4)
    }
}
