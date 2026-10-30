#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
import simd
@testable import SQRender

// F7.15 Lens Distortion: nothing happens at Curvature 0, a straight line bends the right way, the opposite Curvature
// undoes it, Auto Scale leaves no empty edge, the GPU kernel matches the reference, and what a 4K frame costs.

private typealias Px = (UInt8, UInt8, UInt8, UInt8)          // B, G, R, A

private func makeBGRA(_ w: Int, _ h: Int, _ f: (Int, Int) -> Px) -> CVPixelBuffer {
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

private func linear(_ c: Px) -> SIMD4<Float> {
    let a = Float(c.3) / 255
    return SIMD4(StyleFilters.dec(Float(c.2) / 255) * a, StyleFilters.dec(Float(c.1) / 255) * a, StyleFilters.dec(Float(c.0) / 255) * a, a)
}

private func image(_ w: Int, _ h: Int, _ src: (Int, Int) -> Px) -> ImageFilters.Image {
    ImageFilters.Image(width: w, height: h) { x, y in linear(src(x, y)) }
}

private func ref(_ f: ImageFilter, _ img: ImageFilters.Image) -> ImageFilters.Image {
    let size = SIMD2(Float(img.width), Float(img.height))
    return StyleFilters.reference(f, img, frame: ImageFilters.Frame(center: size / 2, size: size))!
}

/// The exact model, as every newly added Lens Distortion uses it (`ClipEffect.lensModelKey`).
private func lens(_ curvature: Double, decenter: Vec2 = .zero, fillAlpha: Bool = true, auto: Bool = false) -> ImageFilter {
    .lensDistortion(curvature: curvature, decenter: decenter, fillAlpha: fillAlpha, fill: SIMD3(1, 0, 0), autoScale: auto,
                    exactModel: true)
}

private struct GPU {
    let dev: MTLDevice, queue: MTLCommandQueue, comp: Compositor
    init?() {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
        dev = d; queue = q; comp = c
    }
    func target(_ w: Int, _ h: Int) -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        return dev.makeTexture(descriptor: td)!
    }
    @discardableResult
    func render(_ pb: CVPixelBuffer, _ fx: ClipEffects, into t: MTLTexture) throws -> MTLCommandBuffer {
        let w = t.width, h = t.height
        let hint = VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        let cb = queue.makeCommandBuffer()!
        try comp.render([RenderLayer(content: .frame(pb, colorHint: hint), effects: fx)],
                        format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        #expect(cb.error == nil)
        return cb
    }
    func read(_ t: MTLTexture) -> [Float16] {
        var half = [Float16](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&half, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return half
    }
}

private func filtered(_ f: ImageFilter) -> ClipEffects { ClipEffects(segments: [EffectSegment(filter: f), EffectSegment()]) }

/// Smooth, low-frequency color (no detail the warp could lose).
private func smooth(_ x: Int, _ y: Int) -> Px {
    let fx = Double(x), fy = Double(y)
    func c(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (128 + 100 * v).rounded()))) }
    return (c(sin(fx / 17 + fy / 29)), c(cos(fx / 23 - fy / 19)), c(sin(fx / 31) * cos(fy / 13)), 255)
}

/// Row of the white line's center of mass in column `x`.
private func lineRow(_ img: ImageFilters.Image, _ x: Int) -> Float {
    var sum: Float = 0, weight: Float = 0
    for y in 0..<img.height { sum += Float(y) * img[x, y].y; weight += img[x, y].y }
    return weight > 0 ? sum / weight : .nan
}

/// Prints a measurement and appends it to the file named by SQ_PERF_OUT (scripts/test.sh shows errors only).
private func report(_ line: String) {
    print(line)
    guard let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"], let data = (line + "\n").data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

@Suite struct LensDistortionTests {
    @Test func curvatureZeroIsSkippedAndTheFrameIsBitIdentical() throws {
        var clip = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        var e = try #require(ClipEffect.make(kind: ClipEffect.lensDistortionKind))
        e.parameters[ClipEffect.lensAutoScaleKey] = AnimatedProperty(1.0)       // Auto Scale alone changes nothing either
        clip.effects = [e]
        let fx = clip.effects(at: Time(1, 1))
        #expect(fx == .none)                                                     // no pass is planned at all
        guard let gpu = GPU() else { return }
        let pb = makeBGRA(48, 32, smooth)
        let plain = gpu.target(48, 32), withEffect = gpu.target(48, 32)
        try gpu.render(pb, .none, into: plain)
        try gpu.render(pb, fx, into: withEffect)
        #expect(gpu.read(plain) == gpu.read(withEffect))
    }

    /// A Lens Distortion saved before F7.15 has no `lensModel` key: it keeps the old formula (pincushion as
    /// 1 / (1 + a r^2), not the exact inverse) and its single bilinear tap, on the CPU reference and on the GPU.
    @Test func anEffectWithoutTheModelKeyKeepsItsOldLook() throws {
        let w = 96, h = 64
        let img = image(w, h, smooth)
        let size = SIMD2(Float(w), Float(h)), center = size / 2, half = simd_length(size) / 2
        let gpu = GPU()
        for curvature in [100.0, -100.0] {
            var e = try #require(ClipEffect.make(kind: ClipEffect.lensDistortionKind))
            e.parameters[ClipEffect.lensCurvatureKey] = AnimatedProperty(curvature)
            var clip = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
            clip.effects = [e]
            let fresh = try #require(clip.effects(at: Time(1, 1)).segments.first?.filter)
            #expect(e.parameters[ClipEffect.lensModelKey] != nil)                 // a new effect carries the key
            e.parameters[ClipEffect.lensModelKey] = nil                           // ... a saved one does not
            clip.effects = [e]
            let fx = clip.effects(at: Time(1, 1))
            let old = try #require(fx.segments.first?.filter)
            #expect(old == .lensDistortion(curvature: curvature / 100, decenter: .zero, fillAlpha: true, fill: SIMD3(1, 1, 1)))
            let out = ref(old, img)
            let k = Float(-curvature / 100 * 0.6)
            var worst: Float = 0
            for y in 0..<h {
                for x in 0..<w {
                    let d = SIMD2(Float(x) + 0.5, Float(y) + 0.5) - center, r = simd_length(d) / half
                    let source = center + d * (k >= 0 ? 1 + k * r * r : 1 / (1 - k * r * r))
                    worst = max(worst, simd_reduce_max(simd_abs(out[x, y] - img.sample(source))))
                }
            }
            #expect(worst < 1e-6, "curvature \(curvature): \(worst) off the old formula")
            // The exact model is a different picture (that is why the key exists).
            let now = ref(fresh, img)
            #expect(zip(now.px, out.px).contains { simd_reduce_max(simd_abs($0 - $1)) > 0.02 })
            guard let gpu else { continue }
            let t = gpu.target(w, h)
            try gpu.render(makeBGRA(w, h, smooth), fx, into: t)
            let got = gpu.read(t)
            var off: Float = 0
            for i in 0..<(w * h) { for c in 0..<3 { off = max(off, abs(Float(got[i * 4 + c]) - out.px[i][c])) } }   // over black
            #expect(off <= 0.01, "curvature \(curvature): GPU \(off) off the old look")
        }
    }

    /// A horizontal line above the center: a barrel (Curvature < 0, fisheye) pulls its ends towards the center, so it
    /// bows away from the center in the middle; a pincushion (Curvature > 0) pushes the ends outwards.
    @Test func aStraightLineBendsTheRightWay() {
        let img = image(96, 96) { _, y in (20...22).contains(y) ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        #expect(abs(lineRow(img, 48) - 21) < 0.01 && abs(lineRow(img, 8) - 21) < 0.01)
        let barrel = ref(lens(-0.5), img)
        let midB = lineRow(barrel, 48), endB = lineRow(barrel, 8)
        #expect(endB - midB > 2, "barrel: middle \(midB), end \(endB)")
        #expect(abs(lineRow(barrel, 8) - lineRow(barrel, 87)) < 0.05)             // symmetric
        let pinch = ref(lens(0.5), img)
        let midP = lineRow(pinch, 48), endP = lineRow(pinch, 8)
        #expect(midP - endP > 2, "pincushion: middle \(midP), end \(endP)")
        // A vertical line right of the center bends the same way (ends towards the center under a barrel).
        let v = image(96, 96) { x, _ in (73...75).contains(x) ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        func column(_ i: ImageFilters.Image, _ y: Int) -> Float {
            var sum: Float = 0, weight: Float = 0
            for x in 0..<i.width { sum += Float(x) * i[x, y].y; weight += i[x, y].y }
            return sum / weight
        }
        let bv = ref(lens(-0.5), v)
        #expect(column(bv, 48) - column(bv, 8) > 2)
    }

    /// The opposite Curvature is the exact inverse: barrel then pincushion gives the picture back (the barrel shrinks the
    /// whole picture into the frame, so nothing is lost but resolution at the corners).
    @Test func theOppositeCurvatureUndoesIt() {
        let img = image(128, 96, smooth)
        for c in [0.25, 0.5, 1.0] {
            let back = ref(lens(c), ref(lens(-c), img))
            // The interior only: the barrel's picture outline fades into the fill over one px, and the way back reads it.
            var worst: Float = 0, sum: Float = 0, n: Float = 0
            for y in 3..<(img.height - 3) {
                for x in 3..<(img.width - 3) {
                    let d = simd_reduce_max(simd_abs(back[x, y] - img[x, y]))
                    worst = max(worst, d); sum += d; n += 1
                }
            }
            report("SQLENSROUNDTRIP curvature \(Int(c * 100)): worst \(worst), mean \(sum / n)")
            #expect(worst < 0.03, "curvature \(c): worst \(worst)")
            #expect(sum / n < 0.004)
        }
        // The mapping itself: where the pincushion reads is where the barrel put that point (within a thousandth of a px).
        let frame = ImageFilters.Frame(center: SIMD2(960, 540), size: SIMD2(1920, 1080))
        let (_, barrel) = StyleFilters.plan(lens(-0.8, decenter: Vec2(0.2, -0.1)), frame: frame, pf: 1)!
        let (_, pinch) = StyleFilters.plan(lens(0.8, decenter: Vec2(0.2, -0.1)), frame: frame, pf: 1)!
        for q in [SIMD2<Float>(0.5, 0.5), SIMD2(1919.5, 300), SIMD2(700, 1079.5), SIMD2(1152, 486)] {
            let there = StyleFilters.lensSource(q, pinch)
            #expect(simd_length(StyleFilters.lensSource(there, barrel) - q) < 0.01, "\(q)")
        }
    }

    @Test func autoScaleLeavesNoEmptyEdge() {
        let img = image(96, 64, smooth)
        for (c, d) in [(-0.8, Vec2.zero), (-0.4, Vec2(0.3, -0.2)), (0.6, Vec2.zero), (0.6, Vec2(-0.4, 0.1))] {
            let plain = ref(lens(c, decenter: d), img)
            let auto = ref(lens(c, decenter: d, auto: true), img)
            if c < 0 { #expect(plain.px.contains { $0.w < 0.5 }, "barrel \(c) leaves corners empty without Auto Scale") }
            let least = auto.px.map(\.w).min() ?? 0
            #expect(least > 0.999, "curvature \(c) decenter \(d): least alpha \(least)")
        }
        // A barrel zooms in (below 1), a centered pincushion zooms out until the edge middles touch the border.
        let frame = ImageFilters.Frame(center: SIMD2(48, 32), size: SIMD2(96, 64))
        func zoom(_ f: ImageFilter) -> Float { Float(bitPattern: UInt32(bitPattern: StyleFilters.plan(f, frame: frame, pf: 1)!.1.i.x)) }
        #expect(zoom(lens(-0.8)) == 1 && zoom(lens(-0.8, auto: true)) < 0.8)
        #expect(zoom(lens(0.6, auto: true)) > 1.05)
        let u = StyleFilters.plan(lens(0.6, auto: true), frame: frame, pf: 1)!.1
        #expect(abs(StyleFilters.lensSource(SIMD2(48, 0), u).y) < 0.05)           // the top edge's middle reads the border
    }

    /// Where the barrel shrinks the picture (towards the edges) the four-tap footprint keeps one-px stripes near their
    /// mean instead of the moire a single tap makes.
    @Test func shrunkDetailIsAveragedNotAliased() {
        let img = image(128, 16) { x, _ in x % 2 == 0 ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        let out = ref(lens(-1), img)
        let u = StyleFilters.plan(lens(-1), frame: ImageFilters.Frame(center: SIMD2(64, 8), size: SIMD2(128, 16)), pf: 1)!.1
        var lo: Float = 1, hi: Float = 0, n = 0
        for x in 70..<128 {                                                       // where the picture is shrunk to about half
            let (s, stretch) = StyleFilters.lensMap(SIMD2(Float(x) + 0.5, 8.5), u)
            guard s.x < 124, (1.8...2.2).contains(stretch.x) else { continue }
            lo = min(lo, out[x, 8].y); hi = max(hi, out[x, 8].y); n += 1
        }
        #expect(n >= 3)
        report("SQLENSALIAS stripe range \(lo)...\(hi) over \(n) px")
        #expect(hi - lo < 0.45, "stripes range \(lo)...\(hi)")
    }

    @Test func aHardAlphaEdgeNeverGivesMoreColorThanCoverage() {
        let w = 64, h = 48
        // Opaque white left of a hard edge at x = 31.5 + a fractional slant, clear (premultiplied zero) right of it.
        let src: (Int, Int) -> Px = { x, y in x < 30 + y / 12 ? (255, 255, 255, 255) : (0, 0, 0, 0) }
        // The GPU path decodes video frames as opaque, so the alpha edge is checked on the CPU twin; the Metal lines are the same.
        for f in [lens(-0.3, fillAlpha: false), lens(0.3, fillAlpha: false), lens(-0.6, decenter: Vec2(0.1, 0), fillAlpha: false),
                  lens(0.6, fillAlpha: false, auto: true)] {
            let out = ref(f, image(w, h, src))
            var over: Float = 0
            for i in 0..<(w * h) {
                let p = out.px[i]
                over = max(over, max(p.x, p.y, p.z) - p.w, -p.w)
            }
            #expect(over <= 1e-5, "\(f): color exceeds alpha by \(over)")
        }
    }

    /// The same alpha-edge check on Metal, with a premultiplied half-float raster (the only layer content that carries
    /// alpha into the effect) over a transparent background: no channel may exceed the coverage.
    @Test func aHardAlphaEdgeNeverGivesMoreColorThanCoverageOnMetal() throws {
        guard let gpu = GPU() else { return }
        let w = 64, h = 48
        var pbOut: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pbOut) == kCVReturnSuccess)
        let pb = try #require(pbOut)
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h {
            let row = (base + y * stride).assumingMemoryBound(to: Float16.self)
            for x in 0..<w {
                let on: Float16 = x < 30 + y / 12 ? 1 : 0
                for c in 0..<4 { row[x * 4 + c] = on }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let format = SequenceFormat(width: w, height: h, frameDuration: Time(1, 25))
        for f in [lens(-0.3, fillAlpha: false), lens(0.3, fillAlpha: false), lens(-0.6, decenter: Vec2(0.1, 0), fillAlpha: false),
                  lens(0.6, fillAlpha: false, auto: true)] {
            let t = gpu.target(w, h)
            let cb = gpu.queue.makeCommandBuffer()!
            let layer = RenderLayer(content: .linearPremultiplied(pb, width: Double(w), height: Double(h)), effects: filtered(f))
            try gpu.comp.render(nodes: [.layer(layer)], format: format, into: t, commandBuffer: cb, background: .transparent)
            cb.commit(); cb.waitUntilCompleted()
            #expect(cb.error == nil)
            let px = gpu.read(t)
            var over: Float = 0
            for i in 0..<(w * h) {
                let a = Float(px[i * 4 + 3])
                over = max(over, max(Float(px[i * 4]), Float(px[i * 4 + 1]), Float(px[i * 4 + 2])) - a, -a)
            }
            #expect(over <= 2e-3, "\(f): color exceeds alpha by \(over) on Metal")
        }
    }

    @Test func theKernelMatchesTheReference() throws {
        guard let gpu = GPU() else { return }
        let w = 48, h = 32
        let filters = [lens(-0.6, decenter: Vec2(0.1, -0.2)), lens(0.5, fillAlpha: false), lens(-0.9, fillAlpha: false),
                       lens(-0.7, auto: true), lens(0.8, decenter: Vec2(0.3, 0.2), auto: true)]
        for f in filters {
            let t = gpu.target(w, h)
            try gpu.render(makeBGRA(w, h, smooth), filtered(f), into: t)
            let got = gpu.read(t), want = ref(f, image(w, h, smooth))
            var worst: Float = 0, at = 0
            for i in 0..<(w * h) {
                for c in 0..<3 where abs(Float(got[i * 4 + c]) - want.px[i][c]) > worst { worst = abs(Float(got[i * 4 + c]) - want.px[i][c]); at = i }
            }
            #expect(worst <= 0.01, "\(f): worst \(worst) at (\(at % w), \(at / w))")
        }
    }
}

@Suite(.serialized) struct LensDistortionCostTests {
    /// Prints the GPU time of one frame without the effect, with it, and with Auto Scale, at 1080p and 4K; "old" is the
    /// look of effects saved before F7.15 (one bilinear tap), what the effect cost before.
    @Test func measureCost() throws {
        guard let gpu = GPU() else { return }
        for (w, h, name) in [(1920, 1080, "1080p"), (3840, 2160, "4K")] {
            let pb = makeBGRA(w, h) { x, y in (UInt8(x & 255), UInt8(y & 255), 128, 255) }
            let t = gpu.target(w, h)
            func ms(_ fx: ClipEffects) throws -> Double {
                var times: [Double] = []
                for i in 0..<14 {
                    let cb = try gpu.render(pb, fx, into: t)
                    if i >= 4 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
                }
                return times.sorted()[times.count / 2]
            }
            let plain = try ms(.none)
            var line = "\(name): plain \(String(format: "%.2f", plain)) ms"
            let old = ImageFilter.lensDistortion(curvature: -0.5, decenter: .zero, fillAlpha: true, fill: SIMD3(1, 0, 0))
            for (label, f) in [("old barrel 50", old), ("pincushion 50", lens(0.5)), ("barrel 50", lens(-0.5)),
                               ("barrel 100", lens(-1)), ("barrel 100 auto", lens(-1, auto: true))] {
                line += ", \(label) +\(String(format: "%.2f", try ms(filtered(f)) - plain)) ms"
            }
            report("SQLENSCOST \(line)")
        }
    }

    /// A 4K frame with the heaviest Lens Distortion (barrel 100 with Auto Scale) must stay far inside a frame budget:
    /// the median GPU time of the effect pass, with a generous bound scaled by machine load.
    @Test func heaviestLensStaysUnderBudgetAt4K() throws {
        guard let gpu = GPU() else { return }
        let w = 3840, h = 2160
        let pb = makeBGRA(w, h) { x, y in (UInt8(x & 255), UInt8(y & 255), 128, 255) }
        let t = gpu.target(w, h)
        let fx = filtered(lens(-1, auto: true))
        var times: [Double] = []
        for i in 0..<14 {
            let cb = try gpu.render(pb, fx, into: t)
            if i >= 4 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        let median = times.sorted()[times.count / 2]
        report("SQLENSCOST budget check 4K barrel 100 auto \(String(format: "%.2f", median)) ms")
        #expect(median < SQTiming.budget(40), "4K lens frame took \(median) ms")
    }
}
#endif
