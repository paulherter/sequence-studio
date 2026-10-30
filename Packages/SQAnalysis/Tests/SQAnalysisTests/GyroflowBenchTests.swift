import AVFoundation
import CoreVideo
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQAnalysis

// Gyroflow benchmarks (docs/research/stabilization/G2-gyroflow-deep.md section 13) on a synthetic 1280x720 clip with a
// .gcsv log (no real camera clip in the repo; SQ_GYRO_CLIP in GyroflowEngineTests covers a real one). Numbers print as
// "PERF gyro bench ..." and are recorded in the design notes. Needs build/gyro/libsqgyro.dylib.

private let engine = GyroflowEngine.shared
private let libraryBuilt = engine.availability == .available

private func log(seconds: Double, rate: Double = 500) -> String {
    var s = "GYROFLOW IMU LOG\nversion,1.3\nid,sq_bench\norientation,XYZ\ntscale,0.001\ngscale,0.001\nascale,0.001\nt,gx,gy,gz,ax,ay,az\n"
    for i in 0...Int(seconds * rate) {
        let t = Double(i) / rate
        s += "\(Int(t * 1000)),\(Int(0.20 * sin(2 * .pi * 1.0 * t) * 1000)),\(Int(0.15 * sin(2 * .pi * 2.3 * t + 1) * 1000)),\(Int(0.10 * sin(2 * .pi * 3.1 * t + 2) * 1000)),0,0,1000\n"
    }
    return s
}

private func clip(width: Int = 1280, height: Int = 720) async throws -> URL {
    var spec = TestClipSpec()
    spec.width = width; spec.height = height; spec.frameCount = 60
    let url = try await TestClipWriter.write(spec)
    try log(seconds: 2.1).write(to: url.deletingPathExtension().appendingPathExtension("gcsv"), atomically: true, encoding: .utf8)
    return url
}

private func frames(_ url: URL, count: Int) async throws -> [(CVPixelBuffer, CMTime)] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    reader.add(out)
    reader.startReading()
    var r: [(CVPixelBuffer, CMTime)] = []
    while r.count < count, let sb = out.copyNextSampleBuffer() {
        if let pb = CMSampleBufferGetImageBuffer(sb) { r.append((pb, CMSampleBufferGetPresentationTimeStamp(sb))) }
    }
    return r
}

private func luma(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let h = CVPixelBufferGetHeightOfPlane(pb, 0), w = CVPixelBufferGetWidthOfPlane(pb, 0)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    var out: [UInt8] = []
    out.reserveCapacity(w * h)
    for y in 0..<h { out.append(contentsOf: UnsafeBufferPointer(start: base + y * bpr, count: w)) }
    return out
}

private func us(_ t: CMTime) -> Int64 { GyroflowOptions.timestampMicroseconds(Time(t.value, Int64(t.timescale))) }

private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

private func ready(_ path: String, _ o: GyroflowOptions) async -> Bool {
    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
        switch engine.analysisState(path: path, options: o) {
        case .ready: return true
        case .failed: return false
        default: try? await Task.sleep(for: .milliseconds(2))
        }
    }
    return false
}

@Suite(.serialized) struct GyroflowBenchTests {
    /// Time from `prepare` to `.ready` for a new option set on an already analyzed file (a slider step).
    @Test(.enabled(if: libraryBuilt)) func optionChangeLatency() async throws {
        let url = try await clip()
        var times: [Double] = []
        for i in 0..<6 {
            var o = GyroflowOptions()
            o.smoothness = 40 + Double(i) * 7
            let t0 = ContinuousClock.now
            engine.prepare(path: url.path, options: o)
            #expect(await ready(url.path, o))
            times.append(ms(ContinuousClock.now - t0))
        }
        print("PERF gyro bench option-change latency 720p (ms, first = cold open): \(times.map { String(format: "%.1f", $0) })")
    }

    /// GPU (quarter-size probe map) against the CPU-buffer warp (per-pixel kernel), center / edge band / corners.
    @Test(.enabled(if: libraryBuilt && GyroMetalWarp.shared != nil)) func mapAccuracyByRegion() async throws {
        let url = try await clip()
        var o = GyroflowOptions()
        o.smoothness = 77
        let fs = try await frames(url, count: 40)
        let w = 1280, h = 720
        var center: [Int] = [], edge: [Int] = [], corner: [Int] = []
        for (pb, pts) in [fs[8], fs[20], fs[33]] {
            let g = luma(try #require(engine.warp(pb, path: url.path, options: o, timestampUS: us(pts), wait: true)))
            let c = luma(try #require(engine.warpOnCPU(pb, path: url.path, options: o, timestampUS: us(pts))))
            for y in 0..<h {
                for x in 0..<w {
                    let d = abs(Int(g[y * w + x]) - Int(c[y * w + x]))
                    let ex = min(x, w - 1 - x), ey = min(y, h - 1 - y)
                    if ex < w / 20 && ey < h / 20 { corner.append(d) } else if ex < w / 20 || ey < h / 20 { edge.append(d) } else { center.append(d) }
                }
            }
        }
        func stat(_ a: [Int]) -> String {
            let s = a.sorted()
            return String(format: "mean %.3f p99 %d max %d", Double(s.reduce(0, +)) / Double(max(s.count, 1)), s[s.count * 99 / 100], s.last ?? 0)
        }
        print("PERF gyro bench map accuracy 720p luma GPU vs CPU: center \(stat(center)); edge \(stat(edge)); corner \(stat(corner))")
    }

    /// The sync offset's direction: +X ms on the option shows what the gyro saw X ms EARLIER (Gyroflow: ts -= offset).
    @Test(.enabled(if: libraryBuilt)) func syncOffsetSign() async throws {
        let url = try await clip()
        let fs = try await frames(url, count: 2)
        let step = us(fs[1].1) - us(fs[0].1)
        var plain = GyroflowOptions(), shifted = GyroflowOptions()
        plain.smoothness = 50; shifted.smoothness = 50; shifted.syncOffsetMS = 100
        engine.prepare(path: url.path, options: plain)
        engine.prepare(path: url.path, options: shifted)
        #expect(await ready(url.path, plain))
        #expect(await ready(url.path, shifted))
        // The synthetic yaw is a sinusoid: motion at t with +100 ms offset equals motion at t-100 ms without.
        var worst = 0.0, wrongWay = 0.0
        for t in stride(from: Int64(500_000), to: 1_500_000, by: 100_000) {
            let a = try #require(engine.motionStep(path: url.path, options: shifted, timestampUS: t, stepUS: step)).raw
            let early = try #require(engine.motionStep(path: url.path, options: plain, timestampUS: t - 100_000, stepUS: step)).raw
            let late = try #require(engine.motionStep(path: url.path, options: plain, timestampUS: t + 100_000, stepUS: step)).raw
            worst = max(worst, abs(a - early)); wrongWay = max(wrongWay, abs(a - late))
        }
        print("PERF gyro bench sync sign: |shifted - earlier| worst \(worst) deg, |shifted - later| worst \(wrongWay) deg")
        #expect(worst < wrongWay, "+offset must take the EARLIER gyro sample")
    }

    /// A new option set on an analyzed file forks its handle (no file read) and must give the same motion as a cold open.
    @Test(.enabled(if: libraryBuilt)) func forkMatchesColdOpen() async throws {
        let url = try await clip()
        let fs = try await frames(url, count: 2)
        let step = us(fs[1].1) - us(fs[0].1)
        var first = GyroflowOptions(), second = GyroflowOptions()
        first.smoothness = 30; second.smoothness = 70
        let warm = GyroflowEngine(), cold = GyroflowEngine()
        func wait(_ e: GyroflowEngine, _ o: GyroflowOptions) async {
            e.prepare(path: url.path, options: o)
            for _ in 0..<30_000 { if case .ready = e.analysisState(path: url.path, options: o) { return }; try? await Task.sleep(for: .milliseconds(2)) }
        }
        await wait(warm, first)
        await wait(warm, second)       // forked from `first`
        await wait(cold, second)       // opened from the file
        for t in stride(from: Int64(400_000), to: 1_600_000, by: 200_000) {
            let a = try #require(warm.motionStep(path: url.path, options: second, timestampUS: t, stepUS: step))
            let b = try #require(cold.motionStep(path: url.path, options: second, timestampUS: t, stepUS: step))
            #expect(abs(a.raw - b.raw) < 1e-6 && abs(a.stabilised - b.stabilised) < 1e-6)
        }
    }

    /// Playback as the render loop does it (`warp(wait: false)` frame after frame at 4K, one frame time apart), then a
    /// slider drag (new options every 16 ms while frames keep coming). Prints ms per warp call and how many frames of the
    /// drag came out unstabilized (nil) or from a stale analysis.
    @Test(.enabled(if: libraryBuilt)) func playbackAndDrag() async throws {
        let url = try await clip(width: 3840, height: 2160)
        let fs = try await frames(url, count: 40)
        var o = GyroflowOptions()
        o.smoothness = 50
        engine.prepare(path: url.path, options: o)
        #expect(await ready(url.path, o))
        var steady: [Double] = []
        for round in 0..<2 {
            for (pb, pts) in fs {
                let t0 = ContinuousClock.now
                _ = engine.warp(pb, path: url.path, options: o, timestampUS: us(pts), wait: false)
                if round == 1 { steady.append(ms(ContinuousClock.now - t0)) }
                try await Task.sleep(for: .milliseconds(33))     // playback pace: lets the prefetch run like in the app
            }
        }
        steady.sort()
        print("PERF gyro bench 4K steady playback warp call (ms): median \(String(format: "%.2f", steady[steady.count / 2])) p95 \(String(format: "%.2f", steady[steady.count * 95 / 100])) max \(String(format: "%.2f", steady.last ?? 0))")
        var split: [String] = []
        for (pb, pts) in fs.prefix(8) {
            if let t = engine.gpuTiming(pb, path: url.path, options: o, timestampUS: us(pts)) {
                split.append(String(format: "map %.1f + pass %.1f", ms(t.map), ms(t.pass)))
            }
        }
        print("PERF gyro bench 4K split per frame (ms): \(split)")
        var drag: [Double] = [], nils = 0, calls = 0
        let t0 = ContinuousClock.now
        for i in 0..<60 {
            var d = o
            d.zoomLimit = 100 + Double(i) * 2
            let (pb, pts) = fs[i % fs.count]
            let c0 = ContinuousClock.now
            if engine.warp(pb, path: url.path, options: d, timestampUS: us(pts), wait: false) == nil { nils += 1 }
            drag.append(ms(ContinuousClock.now - c0)); calls += 1
            try await Task.sleep(for: .milliseconds(16))
        }
        drag.sort()
        print("PERF gyro bench 4K zoom-limit drag: \(calls) ticks in \(String(format: "%.0f", ms(ContinuousClock.now - t0))) ms, warp call median \(String(format: "%.2f", drag[drag.count / 2])) max \(String(format: "%.2f", drag.last ?? 0)) ms, \(nils) of \(calls) frames unstabilized")
    }

    /// Map resolution at 4K: GPU warp against the CPU-buffer warp, and the time of building one map, per divisor.
    @Test(.enabled(if: libraryBuilt && GyroMetalWarp.shared != nil)) func mapDivisorAccuracy4K() async throws {
        let url = try await clip(width: 3840, height: 2160)
        let fs = try await frames(url, count: 24)
        var o = GyroflowOptions()
        o.smoothness = 77; o.fieldOfView = 130
        for divisor in [4, 6, 8, 12] {
            let e = GyroflowEngine()
            e.mapDivisor = divisor
            e.prepare(path: url.path, options: o)
            var err: [Int] = [], maps: [Double] = []
            for (pb, pts) in [fs[6], fs[14], fs[21]] {
                let t = try #require(e.gpuTiming(pb, path: url.path, options: o, timestampUS: us(pts)))
                maps.append(ms(t.map))
                let g = luma(try #require(e.warp(pb, path: url.path, options: o, timestampUS: us(pts), wait: true)))
                let c = luma(try #require(e.warpOnCPU(pb, path: url.path, options: o, timestampUS: us(pts))))
                for k in stride(from: 0, to: g.count, by: 7) { err.append(abs(Int(g[k]) - Int(c[k]))) }
            }
            err.sort()
            print("PERF gyro bench 4K map divisor \(divisor): map build ms \(maps.map { String(format: "%.1f", $0) }), luma err mean \(String(format: "%.3f", Double(err.reduce(0, +)) / Double(err.count))) p99 \(err[err.count * 99 / 100]) max \(err.last ?? 0)")
        }
    }
}
