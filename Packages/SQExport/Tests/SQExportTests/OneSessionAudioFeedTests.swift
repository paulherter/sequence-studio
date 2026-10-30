import Testing
import Foundation
import AVFoundation
import SQCore
@testable import SQExport

/// Stereo pattern on the 16-bit grid (24-bit PCM stores it exactly): left = f(frame), right = -left. Counts overlapping
/// requests and can fail at a given frame.
private final class PatternAudioSource: AudioSource, @unchecked Sendable {
    let sampleRate = 48_000, channels = 2
    let total: Int
    let failAtFrame: Int?
    private let lock = NSLock()
    private var position = 0, inside = 0
    private var _overlaps = 0, _calls = 0

    struct Broken: Error {}

    init(seconds: Int, failAtFrame: Int? = nil) { total = seconds * 48_000; self.failAtFrame = failAtFrame }

    var overlaps: Int { lock.withLock { _overlaps } }
    var calls: Int { lock.withLock { _calls } }

    static func value(_ frame: Int) -> Float { Float((frame * 37) % 4001 - 2000) / 32_768 }

    func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        lock.withLock {
            inside += 1
            _calls += 1
            if inside > 1 { _overlaps += 1 }
        }
        defer { lock.withLock { inside -= 1 } }
        await Task.yield()
        return try lock.withLock {
            let n = min(maxFrames, total - position)
            guard n > 0 else { return nil }
            if let f = failAtFrame, position + n > f { throw Broken() }
            var out = [Float](repeating: 0, count: n * 2)
            for i in 0..<n {
                let v = Self.value(position + i)
                out[i * 2] = v; out[i * 2 + 1] = -v
            }
            position += n
            return AudioChunk(samples: out, channels: 2)
        }
    }
}

/// A one-session export (one segment: constant bitrate, short exports, sources that cannot be split) feeds its audio from
/// its own task next to the frame loop. What is written must be the source's samples, whole and in order.
@Suite(.serialized) struct OneSessionAudioFeedTests {
    static func settings(_ speed: EncoderSpeed) -> ExportSettings {
        var s = smallSettings(codec: .h264, width: 128, height: 64)
        s.video.keyframeInterval = 15
        s.encoderSpeed = speed
        s.audio.enabled = true
        s.audio.codec = .pcm
        return s
    }

    /// All interleaved float samples of the audio track.
    static func samples(_ url: URL) async throws -> [Float] {
        try await offPool {
            let asset = AVURLAsset(url: url)
            let reader = try AVAssetReader(asset: asset)
            guard let track = asset.tracks(withMediaType: .audio).first else { return [] }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000])
            reader.add(out)
            guard reader.startReading() else { return [] }
            var all: [Float] = []
            while let sb = out.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let len = CMBlockBufferGetDataLength(block)
                var data = [Float](repeating: 0, count: len / 4)
                _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                all += data
            }
            return all
        }
    }

    static func videoFrames(_ url: URL) async throws -> Int {
        try await offPool {
            let asset = AVURLAsset(url: url)
            let reader = try AVAssetReader(asset: asset)
            guard let track = asset.tracks(withMediaType: .video).first else { return 0 }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(out)
            guard reader.startReading() else { return 0 }
            var n = 0
            while let sb = out.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(sb) }
            return n
        }
    }

    /// Audio as long as the video, shorter and longer: every sample of the source is in the file, in order.
    @Test(arguments: [EncoderSpeed.quality, EncoderSpeed.balanced], [3, 1, 4])
    func writesTheSourceSamplesInOrder(speed: EncoderSpeed, audioSeconds: Int) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.mov")
        let audio = PatternAudioSource(seconds: audioSeconds)
        try await ExportWriter.export(video: SegmentablePattern(width: 128, height: 64, frameCount: 90), audio: audio,
                                      settings: Self.settings(speed), to: url, segments: 1, progress: { _ in })
        let got = try await Self.samples(url)
        #expect(got.count == audio.total * 2)
        var wrong = 0
        for f in 0..<min(got.count / 2, audio.total) {
            let v = PatternAudioSource.value(f)
            if got[f * 2] != v || got[f * 2 + 1] != -v { wrong += 1 }
        }
        #expect(wrong == 0, "\(wrong) frames differ from the source")
        #expect(audio.overlaps == 0, "the source never sees two requests at once")
        #expect(try await Self.videoFrames(url) == 90)
    }

    @Test(arguments: [EncoderSpeed.quality, EncoderSpeed.balanced])
    func audioErrorStopsTheExportAndRemovesTheFile(speed: EncoderSpeed) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.mov")
        let audio = PatternAudioSource(seconds: 3, failAtFrame: 48_000)
        await #expect(throws: PatternAudioSource.Broken.self) {
            try await ExportWriter.export(video: SegmentablePattern(width: 128, height: 64, frameCount: 90), audio: audio,
                                          settings: Self.settings(speed), to: url, segments: 1, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: [EncoderSpeed.quality, EncoderSpeed.balanced])
    func cancelStopsTheAudioAndRemovesTheFile(speed: EncoderSpeed) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.mov")
        let audio = PatternAudioSource(seconds: 20)
        let settings = Self.settings(speed)
        let export = Task {
            try await ExportWriter.export(video: SegmentablePattern(width: 128, height: 64, frameCount: 600), audio: audio,
                                          settings: settings, to: url, segments: 1,
                                          progress: { p in if p > 0.1 { withUnsafeCurrentTask { $0?.cancel() } } })
        }
        await #expect(throws: CancellationError.self) { try await export.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // The feed has ended with the export: the source is not asked again.
        let after = audio.calls
        try await Task.sleep(for: .milliseconds(150))
        #expect(audio.calls == after)
    }

    /// Cancel after the last frame, while the rest of a much longer audio drains: the feed stops with the next chunk and
    /// does not mix to the end first.
    @Test(arguments: [EncoderSpeed.quality, EncoderSpeed.balanced])
    func cancelAfterTheLastFrameStopsTheAudioDrain(speed: EncoderSpeed) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.mov")
        let audio = PatternAudioSource(seconds: 300)
        let settings = Self.settings(speed)
        let export = Task {
            // The frame loop reports 0.99 x frames done: the last frame is the only step at 0.99.
            try await ExportWriter.export(video: SegmentablePattern(width: 128, height: 64, frameCount: 30), audio: audio,
                                          settings: settings, to: url, segments: 1,
                                          progress: { p in if p >= 0.985 { withUnsafeCurrentTask { $0?.cancel() } } })
        }
        await #expect(throws: CancellationError.self) { try await export.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let chunks = audio.total / 4096
        #expect(audio.calls < chunks / 2, "the source was read \(audio.calls) of \(chunks) times after the cancel")
        let after = audio.calls
        try await Task.sleep(for: .milliseconds(150))
        #expect(audio.calls == after)
    }
}
