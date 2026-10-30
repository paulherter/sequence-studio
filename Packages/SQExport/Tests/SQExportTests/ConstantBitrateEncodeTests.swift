import Testing
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
@testable import SQExport

/// Deliberately uneven content: a calm first half, then full-frame block noise that changes every frame. The frames
/// are built once (the calm picture and a ring of noise pictures), so a timed export measures the encoder, not the source.
final class CalmThenNoisySource: FrameSource, @unchecked Sendable {
    /// `still`: one identical picture; `grain`: the same picture with light per-pixel grain that changes every frame.
    enum Calm: Sendable { case still, grain }
    let frameCount: Int
    let frameDuration: Time
    private let calm: [CVPixelBuffer]
    private let noisy: [CVPixelBuffer]

    /// Which frames are noise; nil = the second half.
    private let noisyAt: (@Sendable (Int) -> Bool)?

    init(width: Int, height: Int, frameCount: Int, frameDuration: Time, calm: Calm = .grain,
         noisyAt: (@Sendable (Int) -> Bool)? = nil) throws {
        self.frameCount = frameCount; self.frameDuration = frameDuration; self.noisyAt = noisyAt
        self.calm = try (0..<(calm == .still ? 1 : 12)).map { try Self.picture(width, height, seed: UInt64($0), grain: calm == .still ? 0 : 6, block: 1) }
        noisy = try (0..<12).map { try Self.picture(width, height, seed: 100 + UInt64($0), grain: 160, block: 8) }
    }

    func frame(at index: Int) async throws -> CVPixelBuffer {
        (noisyAt?(index) ?? (index >= frameCount / 2)) ? noisy[index % noisy.count] : calm[index % calm.count]
    }

    /// A diagonal luma ramp plus noise of `grain` levels in `block` x `block` pixel cells; neutral chroma.
    private static func picture(_ w: Int, _ h: Int, seed: UInt64, grain: Int, block: Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let st = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &out)
        guard st == kCVReturnSuccess, let pb = out else { throw FrameSourceError.bufferCreationFailed(st) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
        let luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ seed &* 0x2545_F491_4F6C_DD1D
        var cells = [Int](repeating: 0, count: (w + block - 1) / block)
        for y in 0..<h {
            if grain > 0, y % block == 0 {
                for i in cells.indices {
                    x ^= x << 13; x ^= x >> 7; x ^= x << 17
                    cells[i] = Int(x >> 40) % grain - grain / 2
                }
            }
            let row = luma + y * stride
            for px in 0..<w {
                let base = 40 + (px + y) * 150 / (w + h)
                row[px] = UInt8(max(16, min(235, base + cells[px / block])))
            }
        }
        return pb
    }
}

/// Bits of video per whole second of presentation time, read from the compressed samples of the written file.
func bitsPerSecond(_ url: URL) async throws -> [Double] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let tk = Box(track)
    return try await offPool {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: tk.buffer, outputSettings: nil)
        reader.add(out); reader.startReading()
        // Streams with B-frames start a frame or two after zero in media time: seconds count from the first frame.
        var samples: [(pts: Double, bits: Int)] = []
        while let sb = out.copyNextSampleBuffer() {
            for i in 0..<CMSampleBufferGetNumSamples(sb) {
                var t = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sb, at: i, timingInfoOut: &t) == noErr else { continue }
                samples.append((t.presentationTimeStamp.seconds, CMSampleBufferGetSampleSize(sb, at: i) * 8))
            }
        }
        let first = samples.map(\.pts).min() ?? 0
        var seconds: [Int: Int] = [:]
        for s in samples { seconds[Int((s.pts - first + 0.001).rounded(.down)), default: 0] += s.bits }
        return seconds.keys.sorted().map { Double(seconds[$0]!) }
    }
}

struct RateStats {
    var perSecond: [Double]
    var mean: Double { perSecond.reduce(0, +) / Double(max(1, perSecond.count)) }
    /// Standard deviation of the per-second bitrate over its mean (coefficient of variation).
    var variation: Double {
        let m = mean
        guard m > 0 else { return 0 }
        return (perSecond.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(perSecond.count)).squareRoot() / m
    }
    var text: String { perSecond.map { String(format: "%.2f", $0 / 1_000_000) }.joined(separator: " ") }
}

/// With `SQ_CBR_REPORT=<file>` the measured numbers are appended there (the test scripts print errors only).
func cbrReport(_ line: String) {
    guard let path = ProcessInfo.processInfo.environment["SQ_CBR_REPORT"] else { return }
    let data = Data((line + "\n").utf8)
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
    else { try? data.write(to: URL(fileURLWithPath: path)) }
}

@Suite(.serialized) struct ConstantBitrateEncodeTests {
    private func settings(_ codec: VideoCodec, _ kind: BitrateKind, hardware: Bool, width: Int, height: Int, bitrate: Int) -> ExportSettings {
        var s = ExportSettings()
        s.video.codec = codec
        s.video.width = width; s.video.height = height
        s.video.frameDuration = Time(1, 30)
        s.video.bitrate = .average(bitrate)
        s.video.bitrateKind = kind
        s.video.keyframeInterval = 30
        s.video.hardwareEncoding = hardware
        s.audio.enabled = false
        return s
    }

    private func measure(_ s: ExportSettings, seconds: Int, in dir: URL, name: String,
                         calm: CalmThenNoisySource.Calm = .grain) async throws -> (stats: RateStats, fps: Double) {
        let n = seconds * 30
        let src = try CalmThenNoisySource(width: s.video.width, height: s.video.height, frameCount: n, frameDuration: Time(1, 30), calm: calm)
        let url = dir.appendingPathComponent("\(name).mp4")
        let clock = ContinuousClock()
        let start = clock.now
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
        let took = clock.now - start
        let e = try await readEncoded(url)
        #expect(e.times.count == n, "\(name): every frame written")
        let secs = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        return (RateStats(perSecond: try await bitsPerSecond(url)), Double(n) / secs)
    }

    /// The session picks the real `ConstantBitRate` on the hardware encoders of Apple silicon and the fallback elsewhere.
    @Test(.serialized, arguments: [VideoCodec.h264, .hevc])
    func rateControlPerEncoder(codec: VideoCodec) throws {
        let soft = try SpeedEncoderSession(settings: settings(codec, .cbr, hardware: false, width: 640, height: 360, bitrate: 2_000_000))
        #expect(soft.rateControl == .constantFallback)
        #expect(try SpeedEncoderSession(settings: settings(codec, .vbr, hardware: true, width: 640, height: 360, bitrate: 2_000_000)).rateControl == .average)
        #if arch(arm64)
        let hard = try SpeedEncoderSession(settings: settings(codec, .cbr, hardware: true, width: 1280, height: 720, bitrate: 6_000_000))
        #expect(hard.rateControl == .constant)
        #endif
    }

    #if arch(arm64)
    /// Calm then noise, 8 s at 1280x720: CBR stays near the target (a hard scene change still shows), VBR swings with the picture.
    @Test(.serialized, arguments: [VideoCodec.h264, .hevc])
    func constantBitrateIsEvenAndOnTarget(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = 6_000_000
        // The first hardware session of a process takes a moment: keep it out of the timed runs.
        _ = try await measure(settings(codec, .vbr, hardware: true, width: 1280, height: 720, bitrate: target), seconds: 1, in: dir, name: "warm")
        let vbr = try await measure(settings(codec, .vbr, hardware: true, width: 1280, height: 720, bitrate: target), seconds: 8, in: dir, name: "vbr")
        var viaSession = settings(codec, .vbr, hardware: true, width: 1280, height: 720, bitrate: target)
        viaSession.encoderSpeed = .balanced
        let vbrSession = try await measure(viaSession, seconds: 8, in: dir, name: "vbr-session")
        let cbr = try await measure(settings(codec, .cbr, hardware: true, width: 1280, height: 720, bitrate: target), seconds: 8, in: dir, name: "cbr")
        // Speed: the better of two alternating runs each (the machine is shared with other builds).
        let vbr2 = try await measure(settings(codec, .vbr, hardware: true, width: 1280, height: 720, bitrate: target), seconds: 8, in: dir, name: "vbr2")
        let cbr2 = try await measure(settings(codec, .cbr, hardware: true, width: 1280, height: 720, bitrate: target), seconds: 8, in: dir, name: "cbr2")
        let (vbrFps, cbrFps) = (max(vbr.fps, vbr2.fps), max(cbr.fps, cbr2.fps))
        cbrReport("\(codec.rawValue) hardware target 6.00 Mbit/s")
        cbrReport(String(format: "  VBR  mean %.2f  variation %.3f  %.0f fps  per second: %@", vbr.stats.mean / 1e6, vbr.stats.variation, vbrFps, vbr.stats.text))
        cbrReport(String(format: "  VBR (session, Balanced)  mean %.2f  variation %.3f  %.0f fps", vbrSession.stats.mean / 1e6, vbrSession.stats.variation, vbrSession.fps))
        cbrReport(String(format: "  CBR  mean %.2f  variation %.3f  %.0f fps  per second: %@", cbr.stats.mean / 1e6, cbr.stats.variation, cbrFps, cbr.stats.text))
        var balanced = settings(codec, .cbr, hardware: true, width: 1280, height: 720, bitrate: target)
        balanced.encoderSpeed = .balanced
        let cbrBalanced = try await measure(balanced, seconds: 8, in: dir, name: "cbr-balanced")
        cbrReport(String(format: "  CBR (Balanced)  mean %.2f  variation %.3f  %.0f fps", cbrBalanced.stats.mean / 1e6, cbrBalanced.stats.variation, cbrBalanced.fps))
        let still = try await measure(settings(codec, .cbr, hardware: true, width: 1280, height: 720, bitrate: target), seconds: 8, in: dir, name: "cbr-still", calm: .still)
        cbrReport(String(format: "  CBR, still first half  mean %.2f  per second: %@", still.stats.mean / 1e6, still.stats.text))
        // Measured (Apple silicon, macOS 27): mean 6.00 for both; variation H.264 0.17 against 0.45, HEVC 0.07 against 0.23.
        #expect(abs(cbr.stats.mean - Double(target)) / Double(target) < 0.10, "CBR mean \(cbr.stats.mean)")
        #expect(cbr.stats.variation < vbr.stats.variation * 0.6, "CBR \(cbr.stats.variation) VBR \(vbr.stats.variation)")
        // A still picture needs next to nothing: constant bitrate pads it up to the target, second by second.
        for second in still.stats.perSecond.prefix(3) { #expect(abs(second - Double(target)) / Double(target) < 0.05, "still second \(second)") }
        #expect(abs(still.stats.mean - Double(target)) / Double(target) < 0.10)
    }
    #endif

    #if arch(arm64)
    /// A rate far too low for the picture (noise at 400 kbit/s): the constant-bitrate session still writes every frame.
    /// It leaves RealTime unset; RealTime true makes the HEVC hardware encoder drop about half of these frames.
    @Test(.serialized, arguments: [VideoCodec.h264, .hevc])
    func starvedConstantBitrateKeepsEveryFrame(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for speed in [EncoderSpeed.quality, .balanced, .fast] {
            var s = settings(codec, .cbr, hardware: true, width: 1280, height: 720, bitrate: 400_000)
            s.encoderSpeed = speed
            #expect(try SpeedEncoderSession(settings: s).rateControl == .constant)
            // `measure` expects every frame in the file; a dropped frame fails the export itself.
            _ = try await measure(s, seconds: 6, in: dir, name: "starved-\(speed.rawValue)")
        }
    }

    /// HEVC Main10 at a starved rate; skipped where the hardware has no Main10 session.
    @Test(.serialized) func starvedConstantBitrateKeepsEveryFrameInMain10() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = settings(.hevc, .cbr, hardware: true, width: 1280, height: 720, bitrate: 400_000)
        s.video.profile = .main10
        guard let session = try? SpeedEncoderSession(settings: s), session.rateControl == .constant else { return }
        for speed in [EncoderSpeed.quality, .balanced, .fast] {
            s.encoderSpeed = speed
            _ = try await measure(s, seconds: 6, in: dir, name: "starved-main10-\(speed.rawValue)")
        }
    }

    /// An encoder that swallows one frame (no callback sample, no drop flag) fails the export instead of shortening it.
    @Test(.serialized, arguments: [VideoCodec.h264, .hevc])
    func aSwallowedFrameFailsTheExport(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = settings(codec, .vbr, hardware: false, width: 320, height: 180, bitrate: 1_000_000)
        s.encoderSpeed = .balanced
        let src = try CalmThenNoisySource(width: 320, height: 180, frameCount: 30, frameDuration: Time(1, 30))
        let url = dir.appendingPathComponent("swallow.mp4")
        await #expect(throws: ExportError.self) {
            try await SpeedEncoderSession.$swallowFrameIndex.withValue(10) {
                try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
            }
        }
        // The same export without the swallow still succeeds.
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
    }
    #endif

    /// Software encoders have no ConstantBitRate: the fallback keeps every second at or below the target.
    @Test(.serialized, arguments: [VideoCodec.h264, .hevc])
    func fallbackHoldsTheTargetAsACeiling(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let target = 1_500_000
        let cbr = try await measure(settings(codec, .cbr, hardware: false, width: 320, height: 180, bitrate: target), seconds: 4, in: dir, name: "soft")
        cbrReport(String(format: "%@ software fallback target 1.50 Mbit/s  mean %.2f  variation %.3f  %.0f fps  per second: %@",
                      codec.rawValue, cbr.stats.mean / 1e6, cbr.stats.variation, cbr.fps, cbr.stats.text))
        // HEVC in software takes no data rate limit either (average only): nothing to hold it to.
        if codec == .h264 { #expect((cbr.stats.perSecond.max() ?? 0) < Double(target) * 1.15) }
    }
}
