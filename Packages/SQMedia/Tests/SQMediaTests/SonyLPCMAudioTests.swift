import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import SQMedia

/// Sony XAVC S clips (C21xx.MP4) carry 16-bit little-endian LPCM without a channel layout. A scratch tool once
/// reported all zeros when reading them as Float32; this checks the real app readers (playback/export source and
/// waveform) against an independent Int16 read. Media-gated: skipped when the files are absent.
@Suite struct SonyLPCMAudioTests {
    private static let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Videos/iOS 27 Features #2")

    /// Peak and RMS of all channels, read as interleaved Int16 stereo 48 kHz (the reference path).
    private static func int16Reference(_ url: URL, seconds: Double?) async throws -> (peak: Float, rms: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        if let seconds { reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 48_000)) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000,
        ])
        reader.add(out)
        #expect(reader.startReading())
        var peak: Float = 0, sumSq = 0.0, n = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var tmp = [Int16](repeating: 0, count: len / 2)
            _ = tmp.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for v in tmp { let f = Float(v) / 32_768; peak = max(peak, abs(f)); sumSq += Double(f * f) }
            n += tmp.count
        }
        return (peak, n > 0 ? (sumSq / Double(n)).squareRoot() : 0)
    }

    @Test(arguments: [2101, 2161])
    func assetAudioSourceMatchesInt16(clip: Int) async throws {
        let url = Self.dir.appendingPathComponent("C\(clip).MP4")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let seconds = 10
        let ref = try await Self.int16Reference(url, seconds: Double(seconds))
        let src = try await AssetAudioSource.open(url: url, sampleRate: 48_000)
        #expect(!src.isMono)
        var peak: Float = 0, sumSq = 0.0, n = 0
        let count = 48_000 * seconds
        var buf = [Float](repeating: 0, count: count)
        for ch in 0..<2 {
            let got = try buf.withUnsafeMutableBufferPointer { try src.read(from: 0, count: count, into: $0.baseAddress!, channel: ch) }
            #expect(got == count)
            for v in buf[0..<got] { peak = max(peak, abs(v)); sumSq += Double(v * v) }
            n += got
        }
        let rms = (sumSq / Double(n)).squareRoot()
        print("Sony C\(clip) float source peak \(peak) rms \(rms) | int16 peak \(ref.peak) rms \(ref.rms)")
        #expect(peak > 0.001)
        #expect(abs(peak - ref.peak) <= 1.0 / 16_384)
        #expect(abs(rms - ref.rms) <= ref.rms * 0.001)
    }

    @Test func waveformMatchesInt16() async throws {
        let url = Self.dir.appendingPathComponent("C2101.MP4")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let ref = try await Self.int16Reference(url, seconds: nil)
        let wf = try await WaveformBuilder.build(url: url)
        let peak = wf.levels[0].reduce(Float(0)) { max($0, abs($1)) }
        print("Sony C2101 waveform peak \(peak) | int16 peak \(ref.peak)")
        #expect(peak > 0.5)
        #expect(abs(peak - ref.peak) <= 1.0 / 16_384)
    }
}
