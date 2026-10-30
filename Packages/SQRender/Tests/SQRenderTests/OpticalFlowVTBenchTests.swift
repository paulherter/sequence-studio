#if canImport(Metal)
import CoreMedia
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
import VideoToolbox
@testable import SQRender

/// Research benchmark (2026-10-05, the design notes "Optical flow"): Apple's VTFrameProcessor frame-rate conversion on the
/// same synthetic frames as `OpticalFlowTests`, for error and time against the own Metal flow. Opt-in
/// (`SQ_VT_FLOW_BENCH=1`): the ML model loads for seconds and the numbers are only for the decision log.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SQ_VT_FLOW_BENCH"] == "1"))
struct OpticalFlowVTBenchTests {
    private static func blobs(_ x: Double, _ y: Double) -> Double {
        let cell = 40.0, cx = Int((x / cell).rounded(.down)), cy = Int((y / cell).rounded(.down))
        var sum = 0.0
        for j in (cy - 1)...(cy + 1) { for i in (cx - 1)...(cx + 1) {
            var hsh = UInt64(bitPattern: Int64(i &* 73856093 ^ j &* 19349663)) &* 0x9E3779B97F4A7C15
            func next() -> Double { hsh ^= hsh >> 29; hsh &*= 0xBF58476D1CE4E5B9; hsh ^= hsh >> 32; return Double(hsh % 10_000) / 10_000 }
            let bx = (Double(i) + next()) * cell, by = (Double(j) + next()) * cell
            let r = 6 + 14 * next(), amp = (next() - 0.5) * 0.6
            sum += amp * exp(-((x - bx) * (x - bx) + (y - by) * (y - by)) / (2 * r * r))
        } }
        return sum
    }

    private static func pattern(_ x: Double, _ y: Double) -> SIMD3<Double> {
        let v = 0.5 + 0.12 * sin(x / 9.1 + 0.7 * sin(y / 23)) + 0.1 * sin(y / 7.3 + x / 31) + 0.08 * sin((x + y) / 13.7)
        let w = 0.5 + 0.14 * sin(x / 11.3 - y / 17.9) + 0.1 * cos(y / 8.7 + 0.5 * sin(x / 29))
        let k = blobs(x, y)
        return SIMD3(v + k, w - 0.6 * k, 0.5 * v + 0.5 * w + 0.4 * k)
    }

    private static func buffer(_ w: Int, _ h: Int, attrs: [String: Any], _ f: (Double, Double) -> SIMD3<Double>) -> CVPixelBuffer {
        var bgra: CVPixelBuffer?
        let a: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, a as CFDictionary, &bgra) == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(bgra!, [])
        let base = CVPixelBufferGetBaseAddress(bgra!)!, stride = CVPixelBufferGetBytesPerRow(bgra!)
        DispatchQueue.concurrentPerform(iterations: h) { y in
            let row = (base + y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let c = f(Double(x) + 0.5, Double(y) + 0.5)
                func b(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
                row[x * 4] = b(c.z); row[x * 4 + 1] = b(c.y); row[x * 4 + 2] = b(c.x); row[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(bgra!, [])
        // Into the processor's own format.
        var out: CVPixelBuffer?
        var attrs = attrs
        attrs[kCVPixelBufferWidthKey as String] = w; attrs[kCVPixelBufferHeightKey as String] = h
        let fmt = (attrs[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber])?.first?.uint32Value
            ?? (attrs[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? kCVPixelFormatType_32BGRA
        precondition(CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &out) == kCVReturnSuccess)
        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        precondition(VTPixelTransferSessionTransferImage(session!, from: bgra!, to: out!) == noErr)
        return out!
    }

    private func blank(_ w: Int, _ h: Int, attrs: [String: Any]) -> CVPixelBuffer {
        var attrs = attrs
        attrs[kCVPixelBufferWidthKey as String] = w; attrs[kCVPixelBufferHeightKey as String] = h
        let fmt = (attrs[kCVPixelBufferPixelFormatTypeKey as String] as? [NSNumber])?.first?.uint32Value
            ?? (attrs[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? kCVPixelFormatType_32BGRA
        var out: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &out) == kCVReturnSuccess)
        return out!
    }

    @Test func frameRateConversionVersusOwnFlow() async throws {
        guard VTFrameRateConversionConfiguration.isSupported,
              let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        var lines: [String] = []
        for (w, h, d) in [(1920, 1080, SIMD2(48.0, -20.0)), (3840, 2160, SIMD2(96.0, -40.0))] {
            for quality in [VTFrameRateConversionConfiguration.QualityPrioritization.normal, .quality] {
                guard let cfg = VTFrameRateConversionConfiguration(frameWidth: w, frameHeight: h, usePrecomputedFlow: false,
                                                                   qualityPrioritization: quality, revision: .revision1)
                else { continue }
                let src = cfg.sourcePixelBufferAttributes, dst = cfg.destinationPixelBufferAttributes
                let a = Self.buffer(w, h, attrs: src) { Self.pattern($0, $1) }
                let b = Self.buffer(w, h, attrs: src) { Self.pattern($0 - d.x, $1 - d.y) }
                let gt = Self.buffer(w, h, attrs: src) { Self.pattern($0 - 0.5 * d.x, $1 - 0.5 * d.y) }
                let out = blank(w, h, attrs: dst)
                let processor = VTFrameProcessor()
                let t0 = Date()
                try processor.startSession(configuration: cfg)
                let startMs = Date().timeIntervalSince(t0) * 1000
                var best = Double.infinity
                for i in 0..<4 {
                    let fa = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: CMTime(value: 0, timescale: 30))!
                    let fb = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(value: 1, timescale: 30))!
                    let fo = VTFrameProcessorFrame(buffer: out, presentationTimeStamp: CMTime(value: 1, timescale: 60))!
                    let p = VTFrameRateConversionParameters(sourceFrame: fa, nextFrame: fb, opticalFlow: nil, interpolationPhase: [0.5],
                                                            submissionMode: i == 0 ? .random : .sequentialReferencesUnchanged,
                                                            destinationFrames: [fo])!
                    let s = Date()
                    _ = try await processor.process(parameters: p)
                    best = min(best, Date().timeIntervalSince(s) * 1000)
                }
                processor.endSession()
                // VT works in RGBA half (the source's encoded values): error read straight from the buffers.
                func half(_ pb: CVPixelBuffer) -> [Float16] {
                    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                    let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
                    var px = [Float16](repeating: 0, count: w * h * 4)
                    px.withUnsafeMutableBytes { dst in
                        for row in 0..<h { (dst.baseAddress! + row * w * 8).copyMemory(from: base + row * stride, byteCount: w * 8) }
                    }
                    return px
                }
                let vo = half(out), vg = half(gt)
                let m = Int(max(abs(d.x), abs(d.y))) + 8
                var vsum = 0.0, vn = 0
                for py in m..<(h - m) { for px in stride(from: m, to: w - m, by: 2) {
                    let i = (py * w + px) * 4
                    for c in 0..<3 { vsum += abs(Double(vo[i + c]) - Double(vg[i + c])) }
                    vn += 3
                } }
                func render(_ pb: CVPixelBuffer, _ blend: FrameBlend? = nil) async throws -> ([Float16], Double) {
                    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
                    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
                    let t = dev.makeTexture(descriptor: td)!
                    let cb = q.makeCommandBuffer()!
                    let hint = VideoTrackInfo(width: w, height: h, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                              nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, matrix: nil)
                    try comp.render([RenderLayer(content: .frame(pb, colorHint: hint), blend: blend)],
                                    format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 30)), into: t, commandBuffer: cb)
                    cb.commit(); await cb.completed()
                    var px = [Float16](repeating: 0, count: w * h * 4)
                    t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                    return (px, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
                }
                if quality == .normal {
                    // The own Metal flow on the same pictures (8-bit BGRA, export quality): error and GPU time.
                    let bgra: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                               kCVPixelBufferMetalCompatibilityKey as String: true,
                                               kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
                    let a8 = Self.buffer(w, h, attrs: bgra) { Self.pattern($0, $1) }
                    let b8 = Self.buffer(w, h, attrs: bgra) { Self.pattern($0 - d.x, $1 - d.y) }
                    let g8 = Self.buffer(w, h, attrs: bgra) { Self.pattern($0 - 0.5 * d.x, $1 - 0.5 * d.y) }
                    let (truth, _) = try await render(g8)
                    var ms = Double.infinity, own: [Float16] = []
                    for _ in 0..<4 {
                        let r = try await render(a8, FrameBlend(next: b8, weight: 0.5, flow: OpticalFlowRequest(key: nil)))
                        own = r.0; ms = min(ms, r.1)
                    }
                    let (plain, _) = try await render(a8, FrameBlend(next: b8, weight: 0.5))
                    lines.append("own flow \(w)x\(h) d=\(d): error \(String(format: "%.2f", meanError(own, truth, w, h, d))) steps (blend \(String(format: "%.2f", meanError(plain, truth, w, h, d)))), \(String(format: "%.1f", ms)) ms GPU incl. measuring")
                }
                lines.append("VT FRC \(w)x\(h) \(quality == .quality ? "quality" : "normal") d=\(d): error \(String(format: "%.2f", vsum / Double(vn) * 255)) steps, process \(String(format: "%.1f", best)) ms (best of 4), session start \(String(format: "%.0f", startMs)) ms")
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-optical-flow-metrics.txt")
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(data); try? fh.close() } else { try? data.write(to: url) }
    }

    private func meanError(_ x: [Float16], _ y: [Float16], _ w: Int, _ h: Int, _ d: SIMD2<Double>) -> Double {
        func enc(_ l: Double) -> Double { l < 0.018 ? 4.5 * l : 1.099 * pow(l, 0.45) - 0.099 }
        let m = Int(max(abs(d.x), abs(d.y))) + 8
        var sum = 0.0, n = 0
        for py in m..<(h - m) { for px in stride(from: m, to: w - m, by: 2) {
            let i = (py * w + px) * 4
            for c in 0..<3 { sum += abs(enc(Double(x[i + c])) - enc(Double(y[i + c]))) }
            n += 3
        } }
        return sum / Double(n) * 255
    }
}
#endif
