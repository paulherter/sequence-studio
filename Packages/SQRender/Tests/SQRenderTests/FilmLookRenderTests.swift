#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// MARK: Helpers

private func makeBGRA(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h {
        for x in 0..<w {
            let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            let c = f(x, y)
            px[0] = c.0; px[1] = c.1; px[2] = c.2; px[3] = c.3
        }
    }
    return b
}

private func hint(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func fmt(_ w: Int, _ h: Int) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)) }

private func target(_ d: MTLDevice, _ w: Int, _ h: Int) -> MTLTexture {
    let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    t.usage = [.renderTarget, .shaderRead]; t.storageMode = .shared
    return d.makeTexture(descriptor: t)!
}

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

@discardableResult
private func render(_ comp: Compositor, _ q: MTLCommandQueue, _ layers: [RenderLayer], _ w: Int, _ h: Int, into t: MTLTexture) throws -> MTLCommandBuffer {
    let cb = q.makeCommandBuffer()!
    try comp.render(layers, format: fmt(w, h), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    return cb
}

private func readAll(_ t: MTLTexture) -> [SIMD4<Float>] {
    var px = [Float16](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    var out: [SIMD4<Float>] = []
    out.reserveCapacity(t.width * t.height)
    for i in 0..<(t.width * t.height) {
        out.append(SIMD4<Float>(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2]), Float(px[i * 4 + 3])))
    }
    return out
}

/// Raw half bit patterns of the whole texture (exact comparisons, -0 and +0 differ).
private func readBits(_ t: MTLTexture) -> [UInt16] {
    var px = [UInt16](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    return px
}

private func layer(_ pb: CVPixelBuffer, _ w: Int, _ h: Int, effects: ClipEffects = .none) -> RenderLayer {
    RenderLayer(content: .frame(pb, colorHint: hint(w, h)), effects: effects)
}

private func lum(_ c: SIMD4<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

private typealias Pixel = (UInt8, UInt8, UInt8, UInt8)

private func renderFx(_ w: Int, _ h: Int, _ f: (Int, Int) -> Pixel, _ fx: ClipEffects) throws -> [SIMD4<Float>]? {
    guard let (dev, q, comp) = setup() else { return nil }
    let pb = makeBGRA(w, h, f)
    let t = target(dev, w, h)
    try render(comp, q, [layer(pb, w, h, effects: fx)], w, h, into: t)
    return readAll(t)
}

private func grey(_ x: Int, _ y: Int) -> Pixel { (128, 128, 128, 255) }

// MARK: Look pass

@Suite struct FilmLookRenderTests {
    @Test func aLookWithNothingInItIsThePlainPath() throws {
        guard let a = try renderFx(32, 32, grey, .none), let b = try renderFx(32, 32, grey, ClipEffects(look: FilmLook())) else { return }
        #expect(a == b)
    }

    @Test func grainIsNoiseWithTheSameMeanAndTheSameSeedGivesTheSameFrame() throws {
        func fx(_ seed: UInt32) -> ClipEffects {
            ClipEffects(look: FilmLook(grain: .init(amount: 0.5, size: 1, softness: 0.3, lumaWeight: 0, seed: seed)))
        }
        guard let plain = try renderFx(64, 64, grey, .none), let g1 = try renderFx(64, 64, grey, fx(1)),
              let g1b = try renderFx(64, 64, grey, fx(1)), let g2 = try renderFx(64, 64, grey, fx(2)) else { return }
        #expect(g1 == g1b)                                           // deterministic
        #expect(g1 != g2)                                            // the seed changes the pattern
        let vals = g1.map { lum($0) }
        let mean = vals.reduce(0, +) / Float(vals.count)
        let variance = vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(vals.count)
        #expect(variance > 1e-5)                                     // visible noise
        #expect(abs(mean - lum(plain[0])) < 0.06)                    // no overall shift of the brightness
        #expect(g1.allSatisfy { abs($0.w - 1) < 1e-3 })              // alpha stays opaque
    }

    @Test func grainAmountScalesTheNoise() throws {
        func spread(_ a: Double) throws -> Float {
            let fx = ClipEffects(look: FilmLook(grain: .init(amount: a, size: 1, softness: 0, lumaWeight: 0, seed: 3)))
            guard let o = try renderFx(64, 64, grey, fx) else { return 0 }
            let v = o.map { lum($0) }
            return v.max()! - v.min()!
        }
        let lo = try spread(0.1), hi = try spread(0.8)
        if lo == 0 && hi == 0 { return }
        #expect(hi > lo * 3)
    }

    @Test func lumaWeightKeepsDeepShadowsClean() throws {
        func spread(_ v: UInt8, weight: Double) throws -> Float {
            let fx = ClipEffects(look: FilmLook(grain: .init(amount: 0.8, size: 1, softness: 0, lumaWeight: weight, seed: 5)))
            guard let o = try renderFx(64, 64, { _, _ in (v, v, v, 255) }, fx) else { return 0 }
            let vals = o.map { lum($0) }
            return vals.max()! - vals.min()!
        }
        let darkWeighted = try spread(4, weight: 1), midWeighted = try spread(128, weight: 1)
        if darkWeighted == 0 && midWeighted == 0 { return }
        #expect(midWeighted > darkWeighted * 4)
        #expect(try spread(4, weight: 0) > darkWeighted)             // unweighted grain shows in the shadows
    }

    @Test func agedFilmIsDeterministicPerSeedAndEachPartShowsOnAFlatFrame() throws {
        func fx(_ d: Double, _ sc: Double, _ f: Double, _ seed: UInt32) -> ClipEffects {
            let aged = FilmLook.Aged(dust: d, scratches: sc, flicker: f, seed: seed)
            return ClipEffects(look: FilmLook(aged: aged))
        }
        guard let plain = try renderFx(256, 144, grey, .none),
              let a = try renderFx(256, 144, grey, fx(1, 1, 0, 4)), let a2 = try renderFx(256, 144, grey, fx(1, 1, 0, 4)),
              let b = try renderFx(256, 144, grey, fx(1, 1, 0, 40)) else { return }
        #expect(a == a2)                                              // deterministic
        #expect(a != b)                                               // the frame id changes the dust
        #expect(a != plain)
        // Scratches alone: whole columns are touched (a vertical line), some rows stay untouched.
        guard let s = try renderFx(256, 144, grey, fx(0, 1, 0, 4)) else { return }
        var cols: [Int] = []
        for x in 0..<256 {
            var touched = false
            for y in 0..<144 where s[y * 256 + x] != plain[y * 256 + x] { touched = true; break }
            if touched { cols.append(x) }
        }
        #expect(!cols.isEmpty && cols.count < 24)
        // Flicker alone: the whole frame moves in brightness together; flicker 0 changes nothing.
        guard let f1 = try renderFx(64, 64, grey, fx(0, 0, 1, 1)), let f2 = try renderFx(64, 64, grey, fx(0, 0, 1, 2)) else { return }
        #expect(f1.allSatisfy { $0 == f1[0] } && f1[0] != f2[0])
        let flickerGap: Float = abs(lum(f1[0]) - lum(f2[0]))
        #expect(flickerGap < 0.35)
    }

    @Test func scanlinesDarkenEveryOtherRowAtSpacingTwo() throws {
        let fx = ClipEffects(look: FilmLook(scanlines: .init(intensity: 1, spacing: 2, thickness: 0.5)))
        // 1080 rows so the look scale is 1 and the spacing is exactly 2 px.
        guard let o = try renderFx(8, 1080, grey, fx) else { return }
        let row = { (y: Int) in lum(o[y * 8 + 4]) }
        let a = row(100), b = row(101)
        #expect(min(a, b) < 0.15 * max(a, b), "rows \(a) \(b)")
        #expect(abs(row(102) - a) < 1e-3 && abs(row(103) - b) < 1e-3)
    }

    @Test func colourGrainVariesTheChannelsAndGreyGrainDoesNot() throws {
        func fx(_ color: Double) -> ClipEffects {
            ClipEffects(look: FilmLook(grain: .init(amount: 0.6, size: 1, softness: 0, lumaWeight: 0, color: color, seed: 4)))
        }
        guard let mono = try renderFx(64, 64, grey, fx(0)), let col = try renderFx(64, 64, grey, fx(1)) else { return }
        #expect(mono.allSatisfy { abs($0.x - $0.y) < 1e-3 && abs($0.y - $0.z) < 1e-3 })
        #expect(col.contains { abs($0.x - $0.y) > 0.01 })
    }

    @Test func chromaBleedSmearsColourButKeepsBrightness() throws {
        let split: (Int, Int) -> Pixel = { x, _ in x < 64 ? (200, 40, 40, 255) : (40, 40, 200, 255) }
        let fx = ClipEffects(look: FilmLook(chromaBleed: .init(bleed: 20, shift: 0)))
        guard let plain = try renderFx(128, 128, split, .none), let o = try renderFx(128, 128, split, fx) else { return }
        let i = 64 * 128 + 66                                        // just right of the edge
        #expect(abs(o[i].x - plain[i].x) > 0.005)                    // color leaks across the edge
        #expect(abs(lum(o[i]) - lum(plain[i])) < 0.03)               // brightness stays
        #expect(abs(o[64 * 128 + 4].x - plain[64 * 128 + 4].x) < 0.05)
    }

    @Test func trackingNoiseShiftsRowsInsideItsBand() throws {
        let edge: (Int, Int) -> Pixel = { x, _ in x < 128 ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        let fx = ClipEffects(look: FilmLook(tracking: .init(amount: 1, bandHeight: 0.2, phase: 0.5, seed: 4)))
        guard let o = try renderFx(256, 1080, edge, fx) else { return }
        func edgeX(_ y: Int) -> Int { (0..<256).first { o[y * 256 + $0].x < 0.5 } ?? 256 }
        let band = (500..<580).map(edgeX)                            // phase 0.5 from the bottom: rows around 540
        #expect(Set(band).count > 8, "band edges \(Set(band).count)")
    }

    @Test func gateWeaveMovesTheLayerAndKeepsItCoveringTheFrame() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 480, h = 270                                          // scale 0.25: 8 px of weave = 2 px
        let pb = makeBGRA(w, h) { x, _ in x < 240 ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        func edgeX(_ weave: GateWeave?) throws -> Int {
            let t = target(dev, w, h)
            try render(comp, q, [layer(pb, w, h, effects: ClipEffects(look: FilmLook(weave: weave)))], w, h, into: t)
            let o = readAll(t)
            #expect(o[135 * w + 1].w > 0.99 && o[135 * w + w - 2].w > 0.99)   // no gap at the sides
            return (0..<w).first { o[135 * w + $0].x < 0.5 } ?? w
        }
        let still = try edgeX(nil)
        let moved = try edgeX(GateWeave(offsetX: 8, offsetY: 0, rotation: 0, maxOffset: 8, maxRotation: 0))
        #expect(abs(still - 240) <= 1)
        #expect(moved - still >= 1 && moved - still <= 4, "moved \(moved - still)")
    }

    @Test func blurThenLookKeepsTheGrainCrisp() throws {
        var fx = ClipEffects(look: FilmLook(grain: .init(amount: 0.8, size: 1, softness: 0, lumaWeight: 0, seed: 9)))
        fx.blur = 3
        guard let o = try renderFx(64, 64, grey, fx) else { return }
        let v = o.map { lum($0) }
        #expect(v.max()! - v.min()! > 0.02)
    }

    /// A clip mask on a layer with a look is applied once, in the final draw (a soft edge keeps its coverage, not its square).
    @Test func aMaskedLayerWithALookKeepsTheMaskEdge() throws {
        let mask = MaskShape(polygon: [Vec2(0, 0), Vec2(0.5, 0), Vec2(0.5, 1), Vec2(0, 1)], feather: 12)
        var plain = ClipEffects.none
        plain.masks = [mask]
        var looked = ClipEffects(look: FilmLook(grain: .init(amount: 0.0005, size: 1, softness: 0, lumaWeight: 0, seed: 2)))
        looked.masks = [mask]
        guard let a = try renderFx(64, 64, grey, plain), let b = try renderFx(64, 64, grey, looked) else { return }
        for x in [4, 24, 30, 32, 34, 40, 60] {
            #expect(abs(a[32 * 64 + x].x - b[32 * 64 + x].x) < 0.004, "x \(x): \(a[32 * 64 + x].x) vs \(b[32 * 64 + x].x)")
        }
    }

    /// Grain / scanlines only: the look runs in the layer's upright draw (one pass, no extra texture). Bit for bit the
    /// pixels of the three-step pass (draw, look kernel, composite), for every kind of layer that reaches it.
    @Test func aPointwiseLookInTheUprightDrawIsBitIdenticalToTheThreeStepPass() throws {
        guard let (dev, q, comp) = setup() else { return }
        let w = 97, h = 61
        let pb = makeBGRA(w, h) { x, y in (UInt8((x * 7) & 255), UInt8((y * 13) & 255), UInt8((x * y) & 255), 255) }
        let grain = FilmLook.Grain(amount: 0.6, size: 1.7, softness: 0.4, lumaWeight: 0.5, seed: 11)
        let colour = FilmLook.Grain(amount: 0.4, size: 1, softness: 0, lumaWeight: 0, color: 0.7, seed: 3)
        let scan = FilmLook.Scanlines(intensity: 0.8, spacing: 3, thickness: 0.4)
        var cases: [(String, RenderLayer)] = []
        func add(_ name: String, _ fx: ClipEffects, transform: ClipTransform = .identity, grade: Bool = false) {
            var l = layer(pb, w, h, effects: fx)
            l.transform = transform
            if grade {
                var b = BasicCorrection(); b.exposure = 0.4; b.saturation = 130
                l.colorPipeline = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(b)])
            }
            cases.append((name, l))
        }
        add("grain", ClipEffects(look: FilmLook(grain: grain)))
        add("color grain", ClipEffects(look: FilmLook(grain: colour)))
        add("scanlines", ClipEffects(look: FilmLook(scanlines: scan)))
        add("aged film", ClipEffects(look: FilmLook(aged: .init(dust: 1, scratches: 1, flicker: 0.8, seed: 9))))
        add("graded grain + scanlines", ClipEffects(look: FilmLook(grain: grain, scanlines: scan)), grade: true)
        var moved = ClipTransform.identity
        moved.position = Vec2(9, -5); moved.scale = Vec2(0.8, 0.8); moved.rotation = 7; moved.opacity = 0.7
        add("moved", ClipEffects(look: FilmLook(grain: grain)), transform: moved)
        var masked = ClipEffects(look: FilmLook(grain: grain))
        masked.masks = [MaskShape(polygon: [Vec2(0.1, 0.1), Vec2(0.6, 0), Vec2(0.7, 0.9), Vec2(0, 1)], feather: 6)]
        masked.pre = EffectMasks(crop: CropInsets(left: 0.1, top: 0.05), cornerRadius: 8)
        add("masked, cropped, rounded", masked)
        var blurred = ClipEffects(look: FilmLook(grain: grain, scanlines: scan))
        blurred.blur = 2
        add("blurred", blurred, grade: true)
        let t = target(dev, w, h)
        for (name, l) in cases {
            comp.fusesPointwiseLook = false
            try render(comp, q, [l], w, h, into: t)
            let ref = readBits(t)
            let fusedBefore = comp.fusedLookDraws
            comp.fusesPointwiseLook = true
            try render(comp, q, [l], w, h, into: t)
            #expect(comp.fusedLookDraws == fusedBefore + 1, "\(name): fused path not taken")
            let got = readBits(t)
            let diff = zip(ref, got).filter { $0 != $1 }.count
            if diff > 0, let path = ProcessInfo.processInfo.environment["SQ_DIAG_OUT"] {
                let pairs = zip(ref, got).enumerated().filter { $0.element.0 != $0.element.1 }.prefix(6)
                    .map { "\($0.offset % 4)@\($0.offset / 4): \(Float(Float16(bitPattern: $0.element.0))) vs \(Float(Float16(bitPattern: $0.element.1)))" }
                let line = "\(name): \(diff) " + pairs.joined(separator: ", ") + "\n"
                if let hd = FileHandle(forWritingAtPath: path) { try? hd.seekToEnd(); try? hd.write(contentsOf: Data(line.utf8)); try? hd.close() }
                else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
            }
            #expect(diff == 0, "\(name): \(diff) half values differ")
        }
        // Chroma bleed / tracking read neighboring pixels: they keep the three-step pass.
        let before = comp.fusedLookDraws
        try render(comp, q, [layer(pb, w, h, effects: ClipEffects(look: FilmLook(grain: grain, chromaBleed: .init(bleed: 4, shift: 1))))],
                   w, h, into: t)
        #expect(comp.fusedLookDraws == before)
    }

    @Test func aCroppedLayerStaysInsideItsMask() throws {
        var fx = ClipEffects(look: FilmLook(grain: .init(amount: 0.5, size: 1, softness: 0, lumaWeight: 0, seed: 2)))
        fx.pre = EffectMasks(crop: CropInsets(left: 0.5), cornerRadius: 0)
        guard let o = try renderFx(64, 64, grey, fx) else { return }
        #expect(o[32 * 64 + 8].x < 0.001)                             // cropped half stays black (target is cleared opaque)
        #expect(o[32 * 64 + 56].x > 0.1)
    }
}

// MARK: Cost

@Suite struct FilmLookCostTests {
    /// Prints ms per frame (GPU time of the whole command buffer) at 1080p and 4K for each look effect alone and the presets.
    @Test func measureCost() throws {
        guard let (dev, q, comp) = setup() else { return }
        func clipWith(_ preset: String) -> Clip {
            var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
            c.applyPreset(FilmPresets.preset(id: preset)!.preset)
            return c
        }
        func single(_ kind: String) -> Clip {
            var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
            c.addEffect(kind: kind)
            return c
        }
        let cases: [(String, Clip)] = [
            ("grain", single(ClipEffect.grainKind)), ("scanlines", single(ClipEffect.scanlinesKind)),
            ("chromaBleed", single(ClipEffect.chromaBleedKind)), ("tracking", single(ClipEffect.trackingNoiseKind)),
            ("weave", single(ClipEffect.gateWeaveKind)), ("aged", single(ClipEffect.agedFilmKind)),
            ("FilmLook", clipWith("preset.filmLook")), ("VHS", clipWith("preset.vhs")), ("BadTV", clipWith("preset.badTV")),
        ]
        for (w, h, name) in [(1920, 1080, "1080p"), (3840, 2160, "4K")] {
            let pb = makeBGRA(w, h) { x, y in (UInt8(x & 255), UInt8(y & 255), 128, 255) }
            let t = target(dev, w, h)
            func gpuMs(_ fx: ClipEffects) throws -> Double {
                var times: [Double] = []
                for i in 0..<12 {
                    let cb = try render(comp, q, [layer(pb, w, h, effects: fx)], w, h, into: t)
                    if i >= 2 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                }
                return times.sorted()[times.count / 2]
            }
            var line = "\(name): plain \(String(format: "%.2f", try gpuMs(.none))) ms"
            for (n, c) in cases { line += ", \(n) \(String(format: "%.2f", try gpuMs(c.effects(at: Time(1, 1))))) ms" }
            NSLog("SQLOOKCOST %@", line)
            print("SQLOOKCOST \(line)")
            // Also appended to a file so a script can read it (scripts/test.sh prints errors only).
            let path = NSTemporaryDirectory() + "sqlookcost.txt"
            if let hd = FileHandle(forWritingAtPath: path) { try? hd.seekToEnd(); try? hd.write(contentsOf: Data((line + "\n").utf8)); try? hd.close() }
            else { try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
        }
    }
}
#endif
