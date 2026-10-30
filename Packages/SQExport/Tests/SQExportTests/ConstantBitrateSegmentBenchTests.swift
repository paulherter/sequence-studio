import Testing
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQMedia
import SQPlayback
import SQRender
@testable import SQExport

/// Bits of every compressed video sample of the written file, in presentation order.
func sampleBitsInPresentationOrder(_ url: URL) async throws -> [Int] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let tk = Box(track)
    return try await offPool {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: tk.buffer, outputSettings: nil)
        reader.add(out); reader.startReading()
        var samples: [(pts: CMTime, bits: Int)] = []
        while let sb = out.copyNextSampleBuffer() {
            for i in 0..<CMSampleBufferGetNumSamples(sb) {
                var t = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sb, at: i, timingInfoOut: &t) == noErr else { continue }
                samples.append((t.presentationTimeStamp, CMSampleBufferGetSampleSize(sb, at: i) * 8))
            }
        }
        return samples.sorted { $0.pts < $1.pts }.map(\.bits)
    }
}

/// Bitrate over every window of `window` frames (one second), as a fraction of `target`.
struct WindowRates {
    var ratios: [Double]
    init(bits: [Int], window: Int, target: Int) {
        var r: [Double] = []
        var sum = bits.prefix(window).reduce(0, +)
        if bits.count >= window { r.append(Double(sum) / Double(target)) }
        if bits.count > window {
            for i in window..<bits.count { sum += bits[i] - bits[i - window]; r.append(Double(sum) / Double(target)) }
        }
        ratios = r
    }
    private func slice(_ range: Range<Int>?) -> [Double] {
        range.map { Array(ratios[max(0, $0.lowerBound)..<min(ratios.count, $0.upperBound)]) } ?? ratios
    }
    /// Largest distance from the target over the windows that start in `range` (nil = all), as a fraction of the target.
    func maxDeviation(startingIn range: Range<Int>? = nil) -> Double { slice(range).map { abs($0 - 1) }.max() ?? 0 }
    func peak(startingIn range: Range<Int>? = nil) -> Double { slice(range).max() ?? 0 }
}

/// Render-bound constant-bitrate bench: a graded 1080p clip under a cropped, blurred copy of itself, decoded from a
/// real file, exported in one and in two segments. Run with `SQ_CBR_BENCH=<rounds> SQ_CBR_REPORT=<file> SQ_TEST_RELEASE=1`.
@Suite(.serialized) struct ConstantBitrateSegmentBenchTests {
    static let fps = 30
    static let seconds = 30
    static var frames: Int { fps * seconds }
    /// Calm 0-8 s, noise 8-20 s (the two-segment join at 15 s lies inside it), calm 20-25 s, noise 25-30 s.
    static func noisy(_ i: Int) -> Bool { (240..<600).contains(i) || i >= 750 }

    /// The uneven pictures alone, already built: an encoder-bound source that can be cut into segments.
    struct Prebuilt: SegmentableFrameSource {
        let inner: CalmThenNoisySource
        var offset = 0
        var count: Int
        var frameCount: Int { count }
        var frameDuration: Time { inner.frameDuration }
        var pixelFormat: ExportPixelFormat { .yuv420v }
        func frame(at index: Int) async throws -> CVPixelBuffer { try await inner.frame(at: offset + index) }
        func segment(_ range: Range<Int>) throws -> any FrameSource {
            var s = self; s.offset = offset + range.lowerBound; s.count = range.count
            return s
        }
    }

    struct Resolver: MediaResolver {
        let base: StaticMediaResolver
        let colorResolver: LayerColorResolver?
        func demuxer(for media: UUID) throws -> any Demuxing { try base.demuxer(for: media) }
        func audio(for media: UUID) throws -> any SQMedia.AudioSource { try base.audio(for: media) }
    }

    struct Fixture {
        let timeline: Timeline
        let resolver: Resolver
        func source(_ s: ExportSettings) throws -> TimelineFrameSource {
            let r = resolver
            return try TimelineFrameSource(timeline: timeline, provider: DecoderFrameProvider(resolver: r),
                                           width: s.video.width, height: s.video.height, frameDuration: s.video.frameDuration,
                                           frameCount: ConstantBitrateSegmentBenchTests.frames, pixelFormat: s.sourcePixelFormat,
                                           colorResolver: r.colorResolver, makeProvider: { DecoderFrameProvider(resolver: r) })
        }
    }

    static func settings(_ codec: VideoCodec, _ kind: BitrateKind, bitrate: Int) -> ExportSettings {
        var s = ExportSettings()
        s.video.codec = codec
        s.video.width = 1920; s.video.height = 1080
        s.video.frameDuration = Time(1, Int64(fps))
        s.video.bitrate = .average(bitrate)
        s.video.bitrateKind = kind
        s.video.keyframeInterval = 60
        s.video.hardwareEncoding = true
        s.audio.enabled = false
        return s
    }

    static func fixture(in dir: URL) async throws -> Fixture {
        let fd = Time(1, Int64(fps))
        // 4K media under a 1080p sequence: three decodes, a grade and two blurs per frame.
        let raw = try CalmThenNoisySource(width: 3840, height: 2160, frameCount: frames, frameDuration: fd, noisyAt: { noisy($0) })
        var ms = settings(.h264, .vbr, bitrate: 80_000_000)
        ms.video.width = 3840; ms.video.height = 2160
        ms.video.keyframeInterval = 30
        let url = dir.appendingPathComponent("media.mp4")
        try await ExportWriter.export(video: raw, audio: nil, settings: ms, to: url, segments: 1, progress: { _ in })
        let media = UUID(), left = UUID(), right = UUID()
        let info = MediaInfo(duration: fd * Int64(frames))
        let resolver = Resolver(base: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url), left: try await AVDemuxer(url: url),
                                                                     right: try await AVDemuxer(url: url)]),
                                colorResolver: LayerColorResolver(lutProvider: nil) { $0 == media ? info : nil })
        let range = TimeRange(start: .zero, duration: fd * Int64(frames))
        var graded = Clip(name: "graded", media: media, kind: .video, source: range, start: .zero)
        graded.color.source = .sLog3SGamut3Cine
        func strip(_ id: UUID, _ key: String) -> Clip {
            var c = Clip(name: "strip", media: id, kind: .video, source: range, start: .zero)
            let crop = c.addEffect(kind: ClipEffect.cropKind)!
            c.setParameter(crop, key, to: 85)
            let blur = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
            c.setParameter(blur, ClipEffect.blurrinessKey, to: 12)
            return c
        }
        let tl = Timeline(name: "bench", format: SequenceFormat(width: 1920, height: 1080, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [graded]), Track(kind: .video, clips: [strip(left, ClipEffect.cropLeftKey)]),
                                   Track(kind: .video, clips: [strip(right, ClipEffect.cropRightKey)])])
        return Fixture(timeline: tl, resolver: resolver)
    }

    struct Run { var fps: Double; var bits: [Int] }

    /// `ExportWriter.segmentCount` keeps CBR in one piece, so the "CBR 2 segments" row only runs with that guard lifted
    /// (measured 2026-10-08: no gain, see docs/ENGINE-NOTES.md "CBR export speed").
    static func splits(_ s: ExportSettings, _ n: Int) -> Bool {
        n == 1 || ExportWriter.segmentCount(requested: n, source: SegmentablePattern(width: 64, height: 64, frameCount: frames), settings: s) == n
    }

    static func run(_ f: Fixture, _ s: ExportSettings, segments: Int, in dir: URL, name: String) async throws -> Run {
        try await run(try f.source(s), s, segments: segments, in: dir, name: name)
    }

    static func run(_ src: any FrameSource, _ s: ExportSettings, segments: Int, in dir: URL, name: String) async throws -> Run {
        let url = dir.appendingPathComponent("\(name).mp4")
        try? FileManager.default.removeItem(at: url)
        let clock = ContinuousClock()
        let start = clock.now
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, segments: segments, progress: { _ in })
        let secs = SQTiming.ms(clock.now - start) / 1000
        let e = try await readEncoded(url)
        #expect(e.times.count == frames, "\(name): every frame written")
        let pts = e.times.map { Int(($0.pts.seconds * Double(fps)).rounded()) }.sorted()
        #expect(pts == Array(pts[0]..<(pts[0] + frames)), "\(name): frame grid without gap or duplicate")
        let dts = e.times.map(\.dts).filter(\.isValid)
        #expect(zip(dts, dts.dropFirst()).allSatisfy { $0 < $1 }, "\(name): decode times increase")
        return Run(fps: Double(frames) / secs, bits: try await sampleBitsInPresentationOrder(url))
    }

    static func line(_ label: String, _ runs: [Run], target: Int) -> String {
        let best = runs.map(\.fps).max() ?? 0
        let all = runs.map(\.fps).map { String(format: "%.0f", $0) }.joined(separator: "/")
        let join = frames / 2
        // The worst run counts for the bitrate.
        let w = runs.map { WindowRates(bits: $0.bits, window: fps, target: target) }
        let mean = runs.map { Double($0.bits.reduce(0, +)) / Double(seconds) / 1e6 }.max() ?? 0
        let dev = w.map { $0.maxDeviation() }.max() ?? 0
        let peak = w.map { $0.peak() }.max() ?? 0
        // Windows that hold the join: they start up to one second before it.
        let atJoin = w.map { $0.maxDeviation(startingIn: (join - fps + 1)..<(join + 1)) }.max() ?? 0
        let perSecond = stride(from: 0, to: frames, by: fps).map { i in
            String(format: "%.1f", Double(runs[0].bits[i..<min(frames, i + fps)].reduce(0, +)) / 1e6)
        }.joined(separator: " ")
        return String(format: "  %@  %.0f fps (%@)  mean %.2f  max dev %.0f %%  peak %.0f %%  windows over join %.0f %%  | %@",
                      label, best, all, mean, dev * 100, peak * 100, atJoin * 100, perSecond)
    }

    @Test(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SQ_CBR_BENCH"] != nil), arguments: [VideoCodec.h264, .hevc])
    func renderBoundOneAndTwoSegments(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = try await Self.fixture(in: dir)
        let target = 12_000_000
        let vbr = Self.settings(codec, .vbr, bitrate: target), cbr = Self.settings(codec, .cbr, bitrate: target)
        // Render alone (no encoder): how far the export is render-bound.
        let src = try f.source(cbr)
        let clock = ContinuousClock()
        let t0 = clock.now
        for i in 0..<Self.frames { _ = try await src.frame(at: i) }
        let renderFps = Double(Self.frames) / (SQTiming.ms(clock.now - t0) / 1000)
        _ = try await Self.run(f, vbr, segments: 1, in: dir, name: "warm")
        var runs: [String: [Run]] = [:]
        let rounds = Int(ProcessInfo.processInfo.environment["SQ_CBR_BENCH"] ?? "") ?? 2
        for round in 0..<max(1, rounds) {
            for (label, s, n) in [("VBR 1 segment ", vbr, 1), ("VBR 2 segments", vbr, 2), ("CBR 1 segment ", cbr, 1), ("CBR 2 segments", cbr, 2)]
            where Self.splits(s, n) {
                runs[label, default: []].append(try await Self.run(f, s, segments: n, in: dir, name: "\(label)-\(round)"))
            }
        }
        cbrReport(String(format: "%@ render-bound: 1920x1080 %d s, graded 4K clip + two cropped blurred 4K copies, target %.0f Mbit/s, render alone %.0f fps",
                         codec.rawValue, Self.seconds, Double(target) / 1e6, renderFps))
        for label in runs.keys.sorted() { cbrReport(Self.line(label, runs[label]!, target: target)) }
    }

    @Test(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SQ_CBR_BENCH"] != nil), arguments: [VideoCodec.h264, .hevc])
    func encoderBoundOneAndTwoSegments(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let fd = Time(1, Int64(Self.fps))
        let src = Prebuilt(inner: try CalmThenNoisySource(width: 1920, height: 1080, frameCount: Self.frames, frameDuration: fd,
                                                          noisyAt: { Self.noisy($0) }), count: Self.frames)
        let target = 12_000_000
        let vbr = Self.settings(codec, .vbr, bitrate: target), cbr = Self.settings(codec, .cbr, bitrate: target)
        _ = try await Self.run(src, vbr, segments: 1, in: dir, name: "warm")
        var runs: [String: [Run]] = [:]
        let rounds = Int(ProcessInfo.processInfo.environment["SQ_CBR_BENCH"] ?? "") ?? 2
        for round in 0..<max(1, rounds) {
            for (label, s, n) in [("VBR 1 segment ", vbr, 1), ("VBR 2 segments", vbr, 2), ("CBR 1 segment ", cbr, 1), ("CBR 2 segments", cbr, 2)]
            where Self.splits(s, n) {
                runs[label, default: []].append(try await Self.run(src, s, segments: n, in: dir, name: "\(label)-\(round)"))
            }
        }
        cbrReport(String(format: "%@ encoder-bound: 1920x1080 %d s, prebuilt pictures, target %.0f Mbit/s", codec.rawValue, Self.seconds, Double(target) / 1e6))
        for label in runs.keys.sorted() { cbrReport(Self.line(label, runs[label]!, target: target)) }
    }
}
