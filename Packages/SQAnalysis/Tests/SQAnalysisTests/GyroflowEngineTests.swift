import AVFoundation
import CoreVideo
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQAnalysis

// Gyroflow engine (gyroflow_core via libsqgyro, docs/GYROFLOW.md): a synthetic clip with a `.gcsv` gyro log next to it
// is analyzed in the background and its frames come back warped, the same for every call (playback = export).
// The library tests run when build/gyro/libsqgyro.dylib exists (scripts/build-gyro.sh).

private let engine = GyroflowEngine.shared
private let libraryBuilt = engine.availability == .available

/// Gyroflow's CSV gyro log: a shaking camera (rotation around all three axes, a few degrees at 1-3 Hz).
private func gcsv(seconds: Double, rate: Double = 500) -> String {
    var s = """
    GYROFLOW IMU LOG
    version,1.3
    id,sq_test
    orientation,XYZ
    tscale,0.001
    gscale,0.001
    ascale,0.001
    t,gx,gy,gz,ax,ay,az

    """
    let n = Int(seconds * rate)
    for i in 0...n {
        let t = Double(i) / rate
        // rad/s in 1/1000 units
        let gx = Int((0.20 * sin(2 * .pi * 1.0 * t)) * 1000)
        let gy = Int((0.15 * sin(2 * .pi * 2.3 * t + 1)) * 1000)
        let gz = Int((0.10 * sin(2 * .pi * 3.1 * t + 2)) * 1000)
        s += "\(Int(t * 1000)),\(gx),\(gy),\(gz),0,0,1000\n"
    }
    return s
}

/// A 2 s 320x180 H.264 clip with a gyro log next to it.
private func clipWithLog() async throws -> URL {
    var spec = TestClipSpec()
    spec.frameCount = 60
    let url = try await TestClipWriter.write(spec)
    try gcsv(seconds: 2.1).write(to: url.deletingPathExtension().appendingPathExtension("gcsv"), atomically: true, encoding: .utf8)
    return url
}

/// Decoded frames (bi-planar 8-bit 4:2:0, video range, as the playback decoder delivers) with their pts.
private func frames(_ url: URL, count: Int) async throws -> [(CVPixelBuffer, CMTime)] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    reader.add(out)
    reader.startReading()
    var result: [(CVPixelBuffer, CMTime)] = []
    while result.count < count, let sb = out.copyNextSampleBuffer() {
        if let pb = CMSampleBufferGetImageBuffer(sb) { result.append((pb, CMSampleBufferGetPresentationTimeStamp(sb))) }
    }
    return result
}

private func bytes(_ pb: CVPixelBuffer, plane: Int) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let h = CVPixelBufferGetHeightOfPlane(pb, plane), w = CVPixelBufferGetWidthOfPlane(pb, plane)
    let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
    let bpp = plane == 0 ? 1 : 2
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!.assumingMemoryBound(to: UInt8.self)
    var out: [UInt8] = []
    out.reserveCapacity(w * bpp * h)
    for y in 0..<h { out.append(contentsOf: UnsafeBufferPointer(start: base + y * bpr, count: w * bpp)) }
    return out
}

private func us(_ t: CMTime) -> Int64 { GyroflowOptions.timestampMicroseconds(Time(t.value, Int64(t.timescale))) }

@Suite(.serialized) struct GyroflowEngineTests {
    @Test func aMissingLibraryIsUnavailableAndWarpsNothing() throws {
        let missing = GyroflowEngine(libraryURL: URL(fileURLWithPath: "/nonexistent/libsqgyro.dylib"))
        #expect(missing.availability == .unavailable(GyroflowEngine.missingReason))
        missing.prepare(path: "/x.mp4", options: GyroflowOptions())
        #expect(missing.analysisState(path: "/x.mp4", options: GyroflowOptions()) == .idle)
        let pb = try #require(FrameStamp.makePixelBuffer(width: 320, height: 180, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, frame: 0))
        #expect(missing.warp(pb, path: "/x.mp4", options: GyroflowOptions(), timestampUS: 0, wait: true) == nil)
    }

    @Test func aCancelDuringAnExportIsNotUndoneByItsNextFrame() {
        let t0 = ContinuousClock.now
        // Canceled before the export began: the export needs the analysis and starts it.
        #expect(!GyroflowEngine.continuesExport(held: true, lastExportCall: nil, now: t0))
        // Canceled while frames were being asked: the next frame leaves it canceled.
        #expect(GyroflowEngine.continuesExport(held: true, lastExportCall: t0, now: t0 + .milliseconds(200)))
        // A later export (long after the last frame) starts it again.
        #expect(!GyroflowEngine.continuesExport(held: true, lastExportCall: t0, now: t0 + .seconds(30)))
        #expect(!GyroflowEngine.continuesExport(held: false, lastExportCall: t0, now: t0 + .milliseconds(200)))
    }

    @Test(.enabled(if: libraryBuilt)) func aGyroLogClipIsAnalysedAndItsFramesWarped() async throws {
        let url = try await clipWithLog()
        let opts = GyroflowOptions()
        #expect(engine.analysisState(path: url.path, options: opts) == .idle)
        engine.prepare(path: url.path, options: opts)
        let fs = try await frames(url, count: 20)
        let (pb, pts) = try #require(fs.last)
        // Export: waits for the analysis.
        let warped = try #require(engine.warp(pb, path: url.path, options: opts, timestampUS: us(pts), wait: true))
        #expect(engine.analysisState(path: url.path, options: opts) == .ready)
        #expect(CVPixelBufferGetPixelFormatType(warped) == CVPixelBufferGetPixelFormatType(pb))
        #expect(CVPixelBufferGetWidth(warped) == 320 && CVPixelBufferGetHeight(warped) == 180)
        #expect(warped !== pb)
        // The camera shakes: the stabilized picture moved.
        let a = bytes(pb, plane: 0), b = bytes(warped, plane: 0)
        let changed = zip(a, b).filter { abs(Int($0) - Int($1)) > 8 }.count
        #expect(changed > a.count / 50, "changed \(changed) of \(a.count)")
        print("PERF gyro synthetic: \(changed * 100 / a.count)% of luma changed by the warp")
        // Playback and export get the same picture for the same frame (non-blocking once ready).
        let again = try #require(engine.warp(pb, path: url.path, options: opts, timestampUS: us(pts), wait: false))
        #expect(bytes(again, plane: 0) == b)
        #expect(bytes(again, plane: 1) == bytes(warped, plane: 1))
    }

    /// The GPU warp (probe map + Metal Lanczos pass) gives the CPU-buffer warp's pixels within a small tolerance.
    @Test(.enabled(if: libraryBuilt && GyroMetalWarp.shared != nil)) func theGPUWarpMatchesTheCPUReference() async throws {
        let url = try await clipWithLog()
        var opts = GyroflowOptions()
        opts.smoothness = 77
        let fs = try await frames(url, count: 30)
        for (pb, pts) in [fs[5], fs[17], fs[29]] {
            let gpu = try #require(engine.warp(pb, path: url.path, options: opts, timestampUS: us(pts), wait: true))
            let cpu = try #require(engine.warpOnCPU(pb, path: url.path, options: opts, timestampUS: us(pts)))
            for plane in 0..<2 {
                let a = bytes(gpu, plane: plane), b = bytes(cpu, plane: plane)
                let d = zip(a, b).map { abs(Int($0) - Int($1)) }.sorted()
                let mean = Double(d.reduce(0, +)) / Double(d.count)
                let p99 = d[d.count * 99 / 100]
                print("PERF gyro GPU vs CPU plane \(plane) at \(us(pts)) us: mean \(mean), p99 \(p99), max \(d.last ?? 0)")
                // Measured: luma mean 0.11-0.13, p99 2 (the map is a quarter-size grid, interpolated); chroma exact.
                #expect(mean < 0.5, "plane \(plane) mean diff \(mean)")
                #expect(p99 <= 3, "plane \(plane) p99 diff \(p99)")
            }
        }
    }

    @Test(.enabled(if: libraryBuilt)) func playbackDoesNotWaitAndOptionsAreSeparateAnalyses() async throws {
        let url = try await clipWithLog()
        var opts = GyroflowOptions()
        opts.smoothness = 140
        let fs = try await frames(url, count: 1)
        let (pb, pts) = try #require(fs.first)
        // Not prepared yet: playback gets nil at once (shows the frame unwarped) and the analysis starts.
        #expect(engine.warp(pb, path: url.path, options: opts, timestampUS: us(pts), wait: false) == nil)
        let ready = await waitReady(url.path, opts)
        #expect(ready)
        #expect(engine.warp(pb, path: url.path, options: opts, timestampUS: us(pts), wait: false) != nil)
        var other = opts
        other.horizonLock = 100
        #expect(engine.analysisState(path: url.path, options: other) == .idle)
    }

    /// Field of View and Sync Offset reach gyroflow_core: each changes the stabilized picture of the same frame. Lens
    /// Correction warps too (the synthetic log has no lens profile, so its picture may equal the default's).
    @Test(.enabled(if: libraryBuilt)) func fieldOfViewAndSyncOffsetChangeThePicture() async throws {
        let url = try await clipWithLog()
        let fs = try await frames(url, count: 20)
        let (pb, pts) = try #require(fs.last)
        func luma(_ o: GyroflowOptions) throws -> [UInt8] {
            try bytes(#require(engine.warp(pb, path: url.path, options: o, timestampUS: us(pts), wait: true)), plane: 0)
        }
        func changed(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).filter { abs(Int($0) - Int($1)) > 8 }.count }
        var base = GyroflowOptions()
        base.smoothness = 63
        let ref = try luma(base)
        var fov = base; fov.fieldOfView = 150
        let wide = try luma(fov)
        #expect(changed(ref, wide) > ref.count / 50, "fov changed \(changed(ref, wide))")
        var sync = base; sync.syncOffsetMS = 120
        let shifted = try luma(sync)
        #expect(changed(ref, shifted) > ref.count / 100, "sync changed \(changed(ref, shifted))")
        var lens = base; lens.lensCorrection = 0
        _ = try luma(lens)
        print("PERF gyro options: fov 150 changed \(changed(ref, wide) * 100 / ref.count)%, sync +120 ms \(changed(ref, shifted) * 100 / ref.count)%")
    }

    @Test(.enabled(if: libraryBuilt)) func aClipWithoutGyroDataFails() async throws {
        let url = try await TestClipWriter.write(TestClipSpec())
        let opts = GyroflowOptions()
        engine.prepare(path: url.path, options: opts)
        _ = await waitReady(url.path, opts)
        guard case .failed = engine.analysisState(path: url.path, options: opts) else {
            Issue.record("expected failed, got \(engine.analysisState(path: url.path, options: opts))"); return
        }
        let fs = try await frames(url, count: 1)
        #expect(engine.warp(try #require(fs.first?.0), path: url.path, options: opts, timestampUS: 0, wait: true) == nil)
    }

    @Test(.enabled(if: libraryBuilt)) func observersHearWhenAnAnalysisFinishes() async throws {
        let url = try await clipWithLog()
        let heard = Heard()
        engine.addObserver { heard.mark() }
        var opts = GyroflowOptions()
        opts.zoomLimit = 111
        engine.prepare(path: url.path, options: opts)
        _ = await waitReady(url.path, opts)
        try await Task.sleep(for: .milliseconds(50))
        #expect(heard.count > 0)
    }

    /// Real clip (opt-in: SQ_GYRO_CLIP=/path/to/C2160.MP4): times the warp of decoded frames through the Swift path.
    @Test(.enabled(if: libraryBuilt && ProcessInfo.processInfo.environment["SQ_GYRO_CLIP"] != nil))
    func realClipWarpTiming() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SQ_GYRO_CLIP"])
        let opts = GyroflowOptions()
        let start = ContinuousClock.now
        engine.prepare(path: path, options: opts)
        let ok = await waitReady(path, opts, timeout: 60)
        print("PERF gyro analysis \(ContinuousClock.now - start), state \(engine.analysisState(path: path, options: opts))")
        #expect(ok)
        let fs = try await frames(URL(fileURLWithPath: path), count: 12)
        var times: [Duration] = []
        for (pb, pts) in fs {
            let t0 = ContinuousClock.now
            #expect(engine.warp(pb, path: path, options: opts, timestampUS: us(pts), wait: true) != nil)
            times.append(ContinuousClock.now - t0)
        }
        // Residual motion: frame-to-frame camera rotation over the clip, raw vs stabilized.
        let step = us(fs[1].1) - us(fs[0].1)
        var raw = 0.0, stab = 0.0, n = 0
        let duration = try await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration)
        var t: Int64 = 0
        while t + step < us(duration), let m = engine.motionStep(path: path, options: opts, timestampUS: t, stepUS: step) {
            raw += m.raw; stab += m.stabilised; n += 1; t += step
        }
        print("PERF gyro motion per frame over \(n) steps: raw \(raw / Double(max(n, 1))) deg, stabilized \(stab / Double(max(n, 1))) deg")
        print("PERF gyro warp \(CVPixelBufferGetWidth(fs[0].0))x\(CVPixelBufferGetHeight(fs[0].0)): \(times.map { "\($0.components.attoseconds / 1_000_000_000_000_000) ms" })")
        func ms(_ d: Duration) -> String { String(format: "%.1f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        var split: [String] = [], cpu: [String] = []
        for (pb, pts) in fs.prefix(6) {
            if let t = engine.gpuTiming(pb, path: path, options: opts, timestampUS: us(pts)) { split.append("map \(ms(t.map)) + pass \(ms(t.pass))") }
            let t0 = ContinuousClock.now
            _ = engine.warpOnCPU(pb, path: path, options: opts, timestampUS: us(pts))
            cpu.append(ms(ContinuousClock.now - t0))
        }
        print("PERF gyro GPU split (ms): \(split)")
        print("PERF gyro CPU-buffer warp (ms): \(cpu)")
        // GPU vs CPU on the real 4K frame.
        let (pb, pts) = fs[6]
        let g = try #require(engine.warp(pb, path: path, options: opts, timestampUS: us(pts), wait: true))
        let c = try #require(engine.warpOnCPU(pb, path: path, options: opts, timestampUS: us(pts)))
        for plane in 0..<2 {
            let a = bytes(g, plane: plane), b = bytes(c, plane: plane)
            let d = zip(a, b).map { abs(Int($0) - Int($1)) }.sorted()
            print("PERF gyro 4K GPU vs CPU plane \(plane): mean \(Double(d.reduce(0, +)) / Double(d.count)), p99 \(d[d.count * 99 / 100]), max \(d.last ?? 0)")
        }
    }
}

private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func mark() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Polls until the analysis is ready or failed. true = ready.
private func waitReady(_ path: String, _ opts: GyroflowOptions, timeout: Double = 20) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        switch engine.analysisState(path: path, options: opts) {
        case .ready: return true
        case .failed: return false
        default: try? await Task.sleep(for: .milliseconds(20))
        }
    }
    return false
}
