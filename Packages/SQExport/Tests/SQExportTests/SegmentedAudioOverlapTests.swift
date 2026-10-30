import Testing
import Foundation
import AVFoundation
import SQCore
@testable import SQExport

/// Silence with a 20 ms full-scale 1 kHz burst at `at` seconds (A/V sync probe).
final class ClickAudioSource: RewindableAudioSource, @unchecked Sendable {
    let sampleRate = 48_000, channels = 2
    let total: Int, clickAt: Int
    private let lock = NSLock()
    private var position = 0
    private(set) var reads = 0

    init(seconds: Double, clickAt: Double) {
        total = Int(seconds * 48_000); self.clickAt = Int(clickAt * 48_000)
    }

    func rewind() async throws { lock.withLock { position = 0; reads += 1 } }

    func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        lock.withLock {
            let n = min(maxFrames, total - position)
            guard n > 0 else { return nil }
            var out = [Float](repeating: 0, count: n * channels)
            for i in 0..<n {
                let p = position + i
                guard p >= clickAt, p < clickAt + 960 else { continue }
                let v = Float(sin(2 * Double.pi * Double((p - clickAt) * 1000 % 48_000) / 48_000)) * 0.9
                out[i * 2] = v; out[i * 2 + 1] = v
            }
            position += n
            return AudioChunk(samples: out, channels: channels)
        }
    }
}

/// Segmented export mixes and encodes the audio alongside the video segments, then copies it in the join: the result must be
/// sample-identical in timing to the one-session export (same encoder), and the loudness pass must still apply.
@Suite struct SegmentedAudioOverlapTests {
    /// First decoded sample above 0.1 and total decoded frames of the audio track.
    static func audioOnset(_ url: URL) async throws -> (onset: Int, frames: Int, peak: Float) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000])
        reader.add(out)
        #expect(reader.startReading())
        var frames = 0, onset = -1
        var peak: Float = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: len / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for i in stride(from: 0, to: data.count, by: 2) {
                peak = max(peak, abs(data[i]))
                if onset < 0, abs(data[i]) > 0.1 { onset = frames + i / 2 }
            }
            frames += data.count / 2
        }
        return (onset, frames, peak)
    }

    static func export(segments: Int, codec: SQExport.AudioCodec = .aac, loudness: LoudnessNormalization? = nil, in dir: URL)
        async throws -> (url: URL, report: LoudnessReport?, reads: Int) {
        var s = smallSettings(codec: .h264, width: 128, height: 64)
        s.video.keyframeInterval = 15
        s.audio.enabled = true
        s.audio.codec = codec
        s.audio.loudness = loudness
        let url = dir.appendingPathComponent("s\(segments)-\(codec)-\(loudness == nil ? "raw" : "norm").\(codec == .pcm ? "mov" : "mp4")")
        let audio = ClickAudioSource(seconds: 3, clickAt: 1.5)
        let src = SegmentablePattern(width: 128, height: 64, frameCount: 90)
        let r = try await ExportWriter.export(video: src, audio: audio, settings: s, to: url, segments: segments, progress: { _ in })
        return (url, r, audio.reads)
    }

    @Test(.serialized, arguments: [SQExport.AudioCodec.aac, SQExport.AudioCodec.pcm])
    func segmentedAudioKeepsSyncWithOneSession(codec: SQExport.AudioCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let one = try await Self.audioOnset(try await Self.export(segments: 1, codec: codec, in: dir).url)
        let three = try await Self.audioOnset(try await Self.export(segments: 3, codec: codec, in: dir).url)
        // The click sits at 1.5 s = sample 72000 (AAC may smear it by a few samples).
        #expect(abs(one.onset - 72_000) <= 64, "one session onset \(one.onset)")
        #expect(abs(three.onset - one.onset) <= 1, "segmented \(three.onset) vs one session \(one.onset)")
        #expect(abs(three.frames - one.frames) <= 1, "segmented \(three.frames) frames vs \(one.frames)")
        #expect(abs(three.frames - 144_000) <= 48, "3 s of audio, got \(three.frames)")
        // No leftover temporary folder next to the output.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".sq-export") })
    }

    @Test func segmentedLoudnessMatchesOneSession() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let l = LoudnessNormalization(targetLUFS: -14, truePeakCeilingDB: -1)
        let one = try await Self.export(segments: 1, loudness: l, in: dir)
        let three = try await Self.export(segments: 3, loudness: l, in: dir)
        let r1 = try #require(one.report), r3 = try #require(three.report)
        #expect(r1 == r3)
        #expect(three.reads >= 1, "the measure pass rewound the source")
        let a = try await Self.audioOnset(one.url), b = try await Self.audioOnset(three.url)
        #expect(abs(a.peak - b.peak) < 0.01, "same gain: \(a.peak) vs \(b.peak)")
        #expect(abs(a.onset - b.onset) <= 1)
    }

    @Test func nonRewindableSourceWithLoudnessThrowsBeforeEncoding() async throws {
        struct Once: AudioSource {
            let sampleRate = 48_000, channels = 2
            func nextChunk(maxFrames: Int) async throws -> AudioChunk? { nil }
        }
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = smallSettings(codec: .h264, width: 128, height: 64)
        s.audio.enabled = true; s.audio.loudness = LoudnessNormalization()
        let url = dir.appendingPathComponent("x.mp4")
        await #expect(throws: ExportError.self) {
            try await ExportWriter.export(video: SegmentablePattern(width: 128, height: 64, frameCount: 90), audio: Once(),
                                          settings: s, to: url, segments: 3, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
