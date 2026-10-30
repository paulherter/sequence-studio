#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
import simd
@testable import SQRender

// F7.15 Rolling shutter pass: a vertical bar a pan has leaned comes back vertical, a tilt's stretch is undone, the
// edges stay filled, the GPU kernel matches the reference, and what a frame costs.

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

private func ref(_ f: ImageFilter, _ img: ImageFilters.Image) -> ImageFilters.Image {
    let size = SIMD2(Float(img.width), Float(img.height))
    return StyleFilters.reference(f, img, frame: ImageFilters.Frame(center: size / 2, size: size))!
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

private func smooth(_ x: Int, _ y: Int) -> Px {
    let fx = Double(x), fy = Double(y)
    func c(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (128 + 100 * v).rounded()))) }
    return (c(sin(fx / 17 + fy / 29)), c(cos(fx / 23 - fy / 19)), c(sin(fx / 31) * cos(fy / 13)), 255)
}

private func report(_ line: String) {
    print(line)
    guard let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"], let data = (line + "\n").data(using: .utf8) else { return }
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// A soft vertical bar (6 px wide, triangular profile) at column `center` as a sensor would record it while the
/// picture pans: every row shifted by `lean` px times its scan position (-0.5 top ... +0.5 bottom).
private func leaningBar(_ w: Int, _ h: Int, center: Float, lean: Float) -> ImageFilters.Image {
    ImageFilters.Image(width: w, height: h) { x, y in
        let v = (Float(y) + 0.5 - Float(h) / 2) / Float(h)
        let g = max(0, 1 - abs(Float(x) + 0.5 - (center + lean * v)) / 3)
        return SIMD4(g, g, g, 1)
    }
}

/// Column of the bar's center of mass in row `y` (pixel centers).
private func barColumn(_ img: ImageFilters.Image, _ y: Int) -> Float {
    var sum: Float = 0, weight: Float = 0
    for x in 0..<img.width { sum += (Float(x) + 0.5) * img[x, y].y; weight += img[x, y].y }
    return weight > 0 ? sum / weight : .nan
}

@Suite struct RollingShutterPassTests {
    @Test func aBarLeanedByAPanComesBackVertical() {
        let w = 128, h = 96
        var lines: [String] = []
        for lean in [12.0, -12.0, 4.0, 30.0] as [Float] {
            let skewed = leaningBar(w, h, center: 64, lean: lean)
            let fixed = ref(.rollingShutter(shear: Vec2(Double(lean) / Double(h), 0), alongX: false), skewed)
            var before: Float = 0, after: Float = 0
            for y in 0..<h {
                before = max(before, abs(barColumn(skewed, y) - 64))
                after = max(after, abs(barColumn(fixed, y) - 64))
            }
            #expect(before > abs(lean) / 2 - 0.6)
            #expect(after < 0.1, "lean \(lean): still \(after) px off vertical")
            lines.append("lean \(lean) px: \(String(format: "%.2f", before)) -> \(String(format: "%.3f", after)) px")
            // Half the strength leaves half the lean; the wrong sign doubles it.
            let half = ref(.rollingShutter(shear: Vec2(Double(lean) / Double(h) / 2, 0), alongX: false), skewed)
            #expect(abs(abs(barColumn(half, 2) - 64) - abs(barColumn(skewed, 2) - 64) / 2) < 0.2)
        }
        report("SQROLLINGBAR " + lines.joined(separator: "; "))
    }

    @Test func aTiltsStretchIsUndone() {
        // Tilting moves the content along the scan axis: a row meant for y is recorded at y + s * v(recorded row).
        let w = 64, h = 120
        let s: Float = 10
        func recorded(_ x: Int, _ r: Int) -> SIMD4<Float> {
            let ideal = Float(r) + 0.5 - s * (Float(r) + 0.5 - Float(h) / 2) / Float(h)
            let g = max(max(0, 1 - abs(ideal - 30) / 3), max(0, 1 - abs(ideal - 90) / 3))
            return SIMD4(g, g, g, 1)
        }
        let skewed = ImageFilters.Image(width: w, height: h) { x, y in recorded(x, y) }
        let fixed = ref(.rollingShutter(shear: Vec2(0, Double(s) / Double(h)), alongX: false), skewed)
        func rows(_ img: ImageFilters.Image) -> (Float, Float) {
            func mass(_ range: Range<Int>) -> Float {
                var sum: Float = 0, weight: Float = 0
                for y in range { sum += (Float(y) + 0.5) * img[w / 2, y].y; weight += img[w / 2, y].y }
                return sum / weight
            }
            return (mass(0..<60), mass(60..<h))
        }
        let before = rows(skewed), after = rows(fixed)
        #expect(abs((before.1 - before.0) - 60) > 4)            // stretched
        #expect(abs(after.0 - 30) < 0.15 && abs(after.1 - 90) < 0.15, "rows \(after)")
    }

    @Test func sensorRowsStandingUprightShiftColumns() {
        // Footage stored turned by a quarter: the scan axis is x, a tilt leans horizontals.
        let w = 96, h = 128
        let turned = leaningBar(h, w, center: 48, lean: 12)      // built upright, then read transposed
        let skewed = ImageFilters.Image(width: w, height: h) { x, y in turned[y, x] }
        let fixed = ref(.rollingShutter(shear: Vec2(0, 12.0 / 96), alongX: true), skewed)
        for x in [1, 30, 60, 94] {
            var sum: Float = 0, weight: Float = 0
            for y in 0..<h { sum += (Float(y) + 0.5) * fixed[x, y].y; weight += fixed[x, y].y }
            #expect(abs(sum / weight - 48) < 0.1)
        }
    }

    @Test func theEdgesStayFilled() {
        let w = 64, h = 48
        let img = ImageFilters.Image(width: w, height: h) { _, _ in SIMD4(0.5, 0.5, 0.5, 1) }
        let out = ref(.rollingShutter(shear: Vec2(0.4, 0.2), alongX: false), img)
        for p in out.px { #expect(abs(p.w - 1) < 1e-4 && abs(p.x - 0.5) < 1e-4) }
    }

    /// With a Drop Shadow, Glow or blur above the Stabilizer the working texture is larger than the clip's frame. That
    /// margin is not picture: the pass leaves it as it is instead of smearing the picture's edge over it.
    @Test func theMarginAroundTheFramePassesThrough() {
        let w = 96, h = 72
        let frame = ImageFilters.Frame(center: SIMD2(48, 36), size: SIMD2(64, 48))
        func inside(_ x: Int, _ y: Int) -> Bool { (16..<80).contains(x) && (12..<60).contains(y) }
        let img = ImageFilters.Image(width: w, height: h) { x, y in
            inside(x, y) ? SIMD4(0.5, 0.5, 0.5, 1) : SIMD4(Float(x) / 960, Float(y) / 720, 0.01, 0.125)
        }
        for f in [ImageFilter.rollingShutter(shear: Vec2(0.4, 0.2), alongX: false), .rollingShutter(shear: Vec2(-0.3, 0.25), alongX: true)] {
            let out = StyleFilters.reference(f, img, frame: frame)!
            for y in 0..<h {
                for x in 0..<w {
                    if inside(x, y) {
                        #expect(abs(out[x, y].w - 1) < 1e-4 && abs(out[x, y].x - 0.5) < 1e-4, "(\(x), \(y))")   // edge held
                    } else {
                        #expect(out[x, y] == img[x, y], "margin (\(x), \(y))")
                    }
                }
            }
        }
    }

    /// The same on the GPU: a blur after the pass enlarges the working texture. A flat picture is not changed by the
    /// pass, so the blurred result must be the one without the pass: its edge fades into the empty margin (a pass that
    /// held the picture's edge over the margin gave a larger, hard-edged block).
    @Test func aBlurAboveSeesAnEmptyMarginOnTheGPU() throws {
        guard let gpu = GPU() else { return }
        let w = 64, h = 48
        let pb = makeBGRA(w, h) { _, _ in (200, 200, 200, 255) }
        let hint = VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        // The layer at half size in the middle (x 16..<48, y 12..<36), so the margin around it shows in the target.
        func render(_ fx: ClipEffects) throws -> [Float16] {
            let t = gpu.target(w, h)
            let cb = gpu.queue.makeCommandBuffer()!
            let layer = RenderLayer(content: .frame(pb, colorHint: hint), transform: ClipTransform(scale: Vec2(0.5, 0.5)), effects: fx)
            try gpu.comp.render([layer], format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            #expect(cb.error == nil)
            return gpu.read(t)
        }
        let want = try render(ClipEffects(segments: [EffectSegment(blurAfter: 5), EffectSegment()]))
        let center = Float(want[(24 * w + 32) * 4]), outside = Float(want[(24 * w + 14) * 4])      // 2 px left of the layer
        #expect(center > 0.3 && outside > 0.01 * center && outside < 0.8 * center, "center \(center), outside \(outside)")
        for f in [ImageFilter.rollingShutter(shear: Vec2(0.3, 0.2), alongX: false), .rollingShutter(shear: Vec2(-0.2, 0.3), alongX: true)] {
            let got = try render(ClipEffects(segments: [EffectSegment(filter: f), EffectSegment(blurAfter: 5), EffectSegment()]))
            var worst: Float = 0
            for i in 0..<want.count { worst = max(worst, abs(Float(want[i]) - Float(got[i]))) }
            #expect(worst <= 0.004, "\(f): \(worst)")
        }
    }

    @Test func theKernelMatchesTheReference() throws {
        guard let gpu = GPU() else { return }
        let w = 48, h = 32
        for f in [ImageFilter.rollingShutter(shear: Vec2(0.2, 0), alongX: false), .rollingShutter(shear: Vec2(-0.15, 0.1), alongX: false),
                  .rollingShutter(shear: Vec2(0.1, -0.2), alongX: true)] {
            let t = gpu.target(w, h)
            try gpu.render(makeBGRA(w, h, smooth), filtered(f), into: t)
            let got = gpu.read(t), want = ref(f, ImageFilters.Image(width: w, height: h) { x, y in linear(smooth(x, y)) })
            var worst: Float = 0, at = 0
            for i in 0..<(w * h) {
                for c in 0..<3 where abs(Float(got[i * 4 + c]) - want.px[i][c]) > worst { worst = abs(Float(got[i * 4 + c]) - want.px[i][c]); at = i }
            }
            #expect(worst <= 0.01, "\(f): worst \(worst) at (\(at % w), \(at / w))")
        }
    }
}

@Suite(.serialized) struct RollingShutterPassCostTests {
    /// Prints the GPU time of one frame without and with the pass at 1080p and 4K.
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
            let with = try ms(filtered(.rollingShutter(shear: Vec2(0.01, 0.004), alongX: false)))
            report("SQROLLINGCOST \(name): plain \(String(format: "%.2f", plain)) ms, rolling shutter +\(String(format: "%.2f", with - plain)) ms")
        }
    }
}
#endif
