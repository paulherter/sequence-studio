import AVFoundation
import CoreVideo
import Foundation
import Testing
import SQCore
@testable import SQAnalysis

/// Opt-in real-media bench (`SQ_REAL_MEDIA=1`, optional `SQ_SUBJECT_CLIP=<path>`): Vision person segmentation cost per frame
/// at each quality and frame-to-frame edge change of the raw and the smoothed matte (`SubjectMatte.edgeDelta`, in source px)
/// on the first `SQ_BENCH_FRAMES` (default 30) decoded frames. Edge change includes the person's real motion, so it is an upper bound for flicker.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SQ_REAL_MEDIA"] == "1"))
struct SubjectMatteBenchTests {
    static var clip: URL {
        if let p = ProcessInfo.processInfo.environment["SQ_SUBJECT_CLIP"] { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Videos/iPhone 18 Pro/P1000066.MP4")
    }

    /// stderr, and appended to `SQ_BENCH_LOG` when set (swift test may hold a test's output back until it ends).
    static func log(_ s: String) {
        let line = Data((s + "\n").utf8)
        FileHandle.standardError.write(line)
        if let p = ProcessInfo.processInfo.environment["SQ_BENCH_LOG"] {
            if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
            if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        }
    }
    static var frameCount: Int { Int(ProcessInfo.processInfo.environment["SQ_BENCH_FRAMES"] ?? "") ?? 30 }

    /// Streams decoded frames to `body` (frames are not kept: the reader's buffer pool would run dry and stall).
    static func eachFrame(_ url: URL, count: Int, _ body: (Int, CVPixelBuffer) throws -> Void) async throws {
        log("PERF subject bench open \(url.lastPathComponent)")
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        log("PERF subject bench track loaded")
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        #expect(reader.startReading())
        var i = 0
        while i < count, let s = out.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(s) { try body(i, pb); i += 1 }
        }
        reader.cancelReading()
    }

    @Test func segmentationCostAndEdgeChange() async throws {
        let url = Self.clip
        Self.log("PERF subject bench start")
        try #require(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
        for q in [PersonSegmenter.Quality.fast, .balanced, .accurate] {
            let tracker = SubjectMatteTracker()
            let key = UUID()
            var times: [Double] = []
            var rawPrev: SubjectMatte?, outPrev: SubjectMatte?
            var rawMax = 0.0, rawMean = 0.0, outMax = 0.0, outMean = 0.0, n = 0.0
            var matteW = 0, matteH = 0, area = 0.0, frames = 0, srcW = 0, srcH = 0
            try await Self.eachFrame(url, count: Self.frameCount) { i, pb in
                srcW = CVPixelBufferGetWidth(pb); srcH = CVPixelBufferGetHeight(pb); frames += 1
                if i % 10 == 0 { Self.log("PERF subject \(q) frame \(i)") }
                // Timed: the real path (tracker with its reused request and sequence handler, smoothing included).
                let t0 = ContinuousClock.now
                let out = try #require(try tracker.matte(for: pb, key: key, frameIndex: i, quality: q))
                let dt = ContinuousClock.now - t0
                if i > 0 { times.append(Double(dt / .microseconds(1)) / 1000) }   // first frame warms the model
                // Untimed: the raw matte of the same frame, for the flicker comparison.
                let raw = try #require(try PersonSegmenter.matte(in: pb, quality: q))
                matteW = raw.width; matteH = raw.height
                area += raw.area / Double(raw.width * raw.height)
                let px = Double(srcW) / Double(raw.width)
                if let rp = rawPrev, let op = outPrev {
                    let r = SubjectMatte.edgeDelta(rp, raw), o = SubjectMatte.edgeDelta(op, out)
                    rawMax = max(rawMax, r.max * px); rawMean += r.mean * px
                    outMax = max(outMax, o.max * px); outMean += o.mean * px; n += 1
                }
                rawPrev = raw; outPrev = out
            }
            try #require(frames >= min(10, Self.frameCount))
            if q == .fast { Self.log("PERF subject bench \(url.lastPathComponent) \(srcW)x\(srcH) frames \(frames)") }
            let sorted = times.sorted()
            let mean = times.reduce(0, +) / Double(times.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            Self.log(String(format: "PERF subject %@ matte %dx%d person %.0f%% | ms mean %.1f p95 %.1f max %.1f | edge px raw %.2f/%.1f smooth %.2f/%.1f",
                         "\(q)", matteW, matteH, area / Double(frames) * 100, mean, p95, sorted.last ?? 0,
                         rawMean / max(n, 1), rawMax, outMean / max(n, 1), outMax))
        }
    }
}
