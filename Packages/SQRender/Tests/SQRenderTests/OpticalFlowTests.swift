#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

/// Optical-flow interpolation against ground truth: synthetic moving patterns whose in-between frame is known exactly.
/// Numbers go to `$TMPDIR/sq-optical-flow-metrics.txt` (scripts/test.sh prints errors only).
private enum Pattern {
    /// Smooth color texture (waves with periods >= 40 px plus non-repeating blobs, one per 40 px cell at a hashed
    /// place, size and sign: like real detail, a shift can not be mistaken for a period), encoded 0...1.
    static func p(_ x: Double, _ y: Double) -> SIMD3<Double> {
        let v = 0.5 + 0.12 * sin(x / 9.1 + 0.7 * sin(y / 23)) + 0.1 * sin(y / 7.3 + x / 31) + 0.08 * sin((x + y) / 13.7)
        let w = 0.5 + 0.14 * sin(x / 11.3 - y / 17.9) + 0.1 * cos(y / 8.7 + 0.5 * sin(x / 29))
        let k = blobs(x, y)
        return SIMD3(v + k, w - 0.6 * k, 0.5 * v + 0.5 * w + 0.4 * k)
    }

    static func waves(_ x: Double, _ y: Double) -> SIMD3<Double> {
        let v = 0.5 + 0.2 * sin(x / 9.1 + 0.7 * sin(y / 23)) + 0.15 * sin(y / 7.3 + x / 31)
        return SIMD3(v, 1 - v, 0.5)
    }

    static func blobs(_ x: Double, _ y: Double) -> Double {
        let cell = 40.0, cx = Int((x / cell).rounded(.down)), cy = Int((y / cell).rounded(.down))
        var sum = 0.0
        for j in (cy - 1)...(cy + 1) { for i in (cx - 1)...(cx + 1) {
            var hsh = UInt64(bitPattern: Int64(i &* 73856093 ^ j &* 19349663)) &* 0x9E3779B97F4A7C15
            func next() -> Double { hsh ^= hsh >> 29; hsh &*= 0xBF58476D1CE4E5B9; hsh ^= hsh >> 32; return Double(hsh % 10_000) / 10_000 }
            let bx = (Double(i) + next()) * cell, by = (Double(j) + next()) * cell
            let r = 6 + 14 * next(), amp = (next() - 0.5) * 0.6
            let d2 = (x - bx) * (x - bx) + (y - by) * (y - by)
            sum += amp * exp(-d2 / (2 * r * r))
        } }
        return sum
    }
    /// A different texture (cut, moving object).
    static func q(_ x: Double, _ y: Double) -> SIMD3<Double> {
        let v = 0.45 + 0.25 * sin(x / 6.9 + y / 15.1) * cos(y / 10.3 - x / 41)
        return SIMD3(1 - v, v, 0.3 + 0.4 * v)
    }

    static func buffer(_ w: Int, _ h: Int, _ f: (Double, Double) -> SIMD3<Double>) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(pb!, [])
        defer { CVPixelBufferUnlockBaseAddress(pb!, []) }
        let base = CVPixelBufferGetBaseAddress(pb!)!, stride = CVPixelBufferGetBytesPerRow(pb!)
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                // Pixel center, 2 x 2 supersampled (a box-filtered camera pixel).
                var c = SIMD3<Double>(repeating: 0)
                for sy in [0.25, 0.75] { for sx in [0.25, 0.75] { c += f(Double(x) + sx, Double(y) + sy) } }
                c /= 4
                func b(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
                row[x * 4] = b(c.z); row[x * 4 + 1] = b(c.y); row[x * 4 + 2] = b(c.x); row[x * 4 + 3] = 255
            }
        }
        return pb!
    }
}

private func hint(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, matrix: nil)
}

private func log(_ s: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-optical-flow-metrics.txt")
    let line = Data((s + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: url) }
}

private final class Rig {
    let dev: MTLDevice, q: MTLCommandQueue, comp: Compositor
    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return nil }
        self.dev = dev; self.q = q; self.comp = comp
    }

    func target(_ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        return dev.makeTexture(descriptor: d)!
    }

    /// Renders one layer; returns GPU milliseconds.
    @discardableResult
    func render(_ layer: RenderLayer, _ w: Int, _ h: Int, into t: MTLTexture) throws -> Double {
        let cb = q.makeCommandBuffer()!
        try comp.render([layer], format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 30)), into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        return (cb.gpuEndTime - cb.gpuStartTime) * 1000
    }

    func pixels(_ t: MTLTexture) -> [Float16] {
        var px = [Float16](repeating: 0, count: t.width * t.height * 4)
        t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        return px
    }

    /// Mean absolute RGB error in 8-bit encoded steps (BT.709 OETF of the linear output) inside `margin`.
    func error(_ a: MTLTexture, _ b: MTLTexture, margin: Int) -> Double {
        let x = pixels(a), y = pixels(b)
        func enc(_ l: Double) -> Double { l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099 }
        var sum = 0.0, n = 0
        for py in margin..<(a.height - margin) { for px in margin..<(a.width - margin) {
            let i = (py * a.width + px) * 4
            for c in 0..<3 { sum += abs(enc(Double(x[i + c])) - enc(Double(y[i + c]))) }
            n += 3
        } }
        return sum / Double(n) * 255
    }
}

@Suite(.serialized) struct OpticalFlowTests {
    /// Frame A, frame B and the true picture at `t` for a pattern moved by `d` pixels per frame.
    private func translation(_ w: Int, _ h: Int, d: SIMD2<Double>, t: Double) -> (CVPixelBuffer, CVPixelBuffer, CVPixelBuffer) {
        (Pattern.buffer(w, h) { Pattern.p($0, $1) },
         Pattern.buffer(w, h) { Pattern.p($0 - d.x, $1 - d.y) },
         Pattern.buffer(w, h) { Pattern.p($0 - t * d.x, $1 - t * d.y) })
    }

    /// (flow error, blend error) against the truth.
    private func errors(_ rig: Rig, a: CVPixelBuffer, b: CVPixelBuffer, truth: CVPixelBuffer, t: Float, margin: Int,
                        quality: FlowQuality = .better) throws -> (Double, Double) {
        let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
        let gt = rig.target(w, h), fl = rig.target(w, h), bl = rig.target(w, h)
        try rig.render(RenderLayer(content: .frame(truth, colorHint: hint(w, h))), w, h, into: gt)
        try rig.render(RenderLayer(content: .frame(a, colorHint: hint(w, h)),
                                   blend: FrameBlend(next: b, weight: t, flow: OpticalFlowRequest(key: nil, quality: quality))), w, h, into: fl)
        try rig.render(RenderLayer(content: .frame(a, colorHint: hint(w, h)), blend: FrameBlend(next: b, weight: t)), w, h, into: bl)
        return (rig.error(fl, gt, margin: margin), rig.error(bl, gt, margin: margin))
    }

    @Test func translationIsInterpolatedCloseToTheTruth() throws {
        guard let rig = Rig() else { return }
        for (d, t) in [(SIMD2(6.4, -3.3), Float(0.5)), (SIMD2(23.7, 11.2), Float(0.25)), (SIMD2(-32.0, 14.5), Float(0.5))] {
            let (a, b, gt) = translation(640, 360, d: d, t: Double(t))
            let margin = Int(max(abs(d.x), abs(d.y))) + 8
            let (fe, be) = try errors(rig, a: a, b: b, truth: gt, t: t, margin: margin)
            let (ff, _) = try errors(rig, a: a, b: b, truth: gt, t: t, margin: margin, quality: .faster)
            log("translation d=\(d) t=\(t): flow(better) \(String(format: "%.2f", fe)) flow(faster) \(String(format: "%.2f", ff)) blend \(String(format: "%.2f", be)) (8-bit steps)")
            #expect(fe < be * 0.25, "d \(d): flow \(fe) vs blend \(be)")
            #expect(fe < 3, "d \(d): flow error \(fe)")
            #expect(ff < be * 0.5, "d \(d): faster flow \(ff) vs blend \(be)")
        }
    }

    @Test func motionBeyondTheEstimateIsNoWorseThanTheBlend() throws {
        guard let rig = Rig() else { return }
        let d = SIMD2(-70.0, 31.0)
        let (a, b, gt) = translation(640, 360, d: d, t: 0.5)
        let (fe, be) = try errors(rig, a: a, b: b, truth: gt, t: 0.5, margin: 78)
        log("large motion d=\(d) t=0.5: flow \(String(format: "%.2f", fe)) blend \(String(format: "%.2f", be))")
        #expect(fe <= be * 1.05, "flow \(fe) vs blend \(be)")
    }

    @Test func movingObjectOverAStillBackground() throws {
        guard let rig = Rig() else { return }
        let w = 640, h = 360, d = SIMD2(20.0, 9.0), t = 0.5
        func frame(_ s: Double) -> CVPixelBuffer {
            Pattern.buffer(w, h) { x, y in
                let ox = 220 + s * d.x, oy = 110 + s * d.y
                return x >= ox && x < ox + 150 && y >= oy && y < oy + 120 ? Pattern.q(x - ox, y - oy) : Pattern.p(x, y)
            }
        }
        let (fe, be) = try errors(rig, a: frame(0), b: frame(1), truth: frame(t), t: Float(t), margin: 8)
        log("moving object 150x120 d=\(d) t=\(t): flow \(String(format: "%.2f", fe)) blend \(String(format: "%.2f", be))")
        #expect(fe < be * 0.5, "flow \(fe) vs blend \(be)")
    }

    @Test func aCutFallsBackToTheBlend() throws {
        guard let rig = Rig() else { return }
        let w = 640, h = 360
        let a = Pattern.buffer(w, h) { Pattern.p($0, $1) }, b = Pattern.buffer(w, h) { Pattern.q($0 * 1.3, $1 * 0.8) }
        let fl = rig.target(w, h), bl = rig.target(w, h)
        try rig.render(RenderLayer(content: .frame(a, colorHint: hint(w, h)),
                                   blend: FrameBlend(next: b, weight: 0.5, flow: OpticalFlowRequest(key: nil))), w, h, into: fl)
        try rig.render(RenderLayer(content: .frame(a, colorHint: hint(w, h)), blend: FrameBlend(next: b, weight: 0.5)), w, h, into: bl)
        let diff = rig.error(fl, bl, margin: 0)
        log("cut (unrelated frames): flow vs blend \(String(format: "%.2f", diff))")
        #expect(diff < 6, "flow strays \(diff) steps from the blend on a cut")
    }

    @Test func flowIsCachedPerFramePairAndTheResultIsTheSame() throws {
        guard let rig = Rig() else { return }
        let w = 320, h = 180
        let (a, b, _) = translation(w, h, d: SIMD2(5, 2), t: 0.5)
        let key = FlowPairKey(media: UUID(), from: .zero, to: Time(1, 30))
        func run(_ k: FlowPairKey?, _ t: Float, _ out: MTLTexture) throws {
            try rig.render(RenderLayer(content: .frame(a, colorHint: hint(w, h)),
                                       blend: FrameBlend(next: b, weight: t, flow: OpticalFlowRequest(key: k))), w, h, into: out)
        }
        let first = rig.target(w, h), again = rig.target(w, h), uncached = rig.target(w, h)
        try run(key, 0.5, first)
        let engine = try #require(rig.comp.flowEngine())
        #expect(engine.measureCount == 1)
        try run(key, 0.25, again); try run(key, 0.5, again)
        #expect(engine.measureCount == 1 && engine.cachedPairs == 1)
        try run(nil, 0.5, uncached)
        #expect(engine.measureCount == 2 && engine.cachedPairs == 1)
        // Cached and freshly measured: the same pixels (playback and export agree).
        #expect(rig.pixels(first) == rig.pixels(again) && rig.pixels(first) == rig.pixels(uncached))
        // Bounded: a small cap keeps only the newest pair.
        engine.cacheByteLimit = 1
        try run(FlowPairKey(media: key.media, from: Time(1, 30), to: Time(2, 30)), 0.5, again)
        #expect(engine.cachedPairs == 1)
    }

    @Test func performanceAt1080pAnd4K() throws {
        guard let rig = Rig() else { return }
        for (w, h, budget) in [(1920, 1080, 25.0), (3840, 2160, 60.0)] {
            // Waves only: the cost does not depend on the content, and 4K blobs take long on the CPU.
            let a = Pattern.buffer(w, h) { Pattern.waves($0, $1) }, b = Pattern.buffer(w, h) { Pattern.waves($0 - 14, $1 + 6) }
            let out = rig.target(w, h)
            func ms(_ blend: FrameBlend) throws -> Double {
                let layer = RenderLayer(content: .frame(a, colorHint: hint(w, h)), blend: blend)
                try rig.render(layer, w, h, into: out)     // warm up (pipelines, pools)
                var best = Double.infinity
                for _ in 0..<5 { best = min(best, try rig.render(layer, w, h, into: out)) }
                return best
            }
            let plain = try ms(FrameBlend(next: b, weight: 0.5))
            let better = try ms(FrameBlend(next: b, weight: 0.5, flow: OpticalFlowRequest(key: nil, quality: .better)))
            let faster = try ms(FrameBlend(next: b, weight: 0.5, flow: OpticalFlowRequest(key: nil, quality: .faster)))
            let key = FlowPairKey(media: UUID(), from: .zero, to: Time(1, 30))
            let cached = try ms(FrameBlend(next: b, weight: 0.5, flow: OpticalFlowRequest(key: key)))
            log("perf \(w)x\(h) GPU ms (best of 5): blend \(String(format: "%.2f", plain)), flow better \(String(format: "%.2f", better)), faster \(String(format: "%.2f", faster)), cached pair \(String(format: "%.2f", cached))")
            #expect(better < SQTiming.budget(budget), "\(w)x\(h) flow \(better) ms")
            #expect(cached < plain + SQTiming.budget(budget / 4), "\(w)x\(h) cached flow \(cached) ms vs blend \(plain)")
        }
    }
}
#endif
