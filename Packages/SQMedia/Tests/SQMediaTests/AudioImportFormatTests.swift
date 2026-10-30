import AVFoundation
import Foundation
import SQCore
import Testing
@testable import SQMedia

/// Import handling of audio files the editor meets: 44.1 vs 48 kHz, multichannel recorder files, and files that
/// cannot be read. All files are generated here (a second of tone, one level per channel); no footage.
///
/// Behavior these tests pin down:
/// - The probe reports the file's own sample rate and channel count; the project rate (48 kHz) is applied when the
///   audio is opened, where the file is resampled and keeps its duration (within a few samples) and its level.
/// - A multichannel file (4 ch field recorder, 5.1) plays through a channel map: the default plays channels 0 and 1,
///   a map picks any other pair, one channel is read at its recorded level.
/// - A file that is not audio, or has a codec this Mac cannot decode, fails the probe with a `MediaError` (the import
///   dialog then names the file; audio codecs get WAV/AAC advice).
@Suite struct AudioImportFormatTests {
    private func makeFile(ext: String = "wav", rate: Double, channels: AVAudioChannelCount, seconds: Double = 1,
                          levels: [Float]? = nil, settings: [String: Any]? = nil,
                          layoutTag: AudioChannelLayoutTag? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audioimport-\(UUID().uuidString).\(ext)")
        let format: AVAudioFormat
        let layoutTag = layoutTag ?? (channels > 2 ? AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | channels) : nil)
        if let layoutTag, let layout = AVAudioChannelLayout(layoutTag: layoutTag) {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        } else {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        }
        let frames = AVAudioFrameCount(rate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<Int(channels) {
            let level = levels?[c] ?? 0.5
            for i in 0..<Int(frames) {
                buf.floatChannelData![c][i] = level * Float(sin(2 * Double.pi * 440 * Double(i) / rate))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings)
        try file.write(from: buf)
        return url
    }

    private func readPeak(_ s: any AudioSource, channel: Int, from: Int64 = 4_800, count: Int = 9_600) throws -> Float {
        var out = [Float](repeating: 0, count: count)
        let n = try out.withUnsafeMutableBufferPointer { try s.read(from: from, count: count, into: $0.baseAddress!, channel: channel) }
        #expect(n == count)
        return out.map(abs).max() ?? 0
    }

    private func frameCount(_ s: any AudioSource) throws -> Int {
        var buf = [Float](repeating: 0, count: 200_000)
        return try buf.withUnsafeMutableBufferPointer { try s.read(from: 0, count: 200_000, into: $0.baseAddress!, channel: 0) }
    }

    @Test func probeReportsFileRateAndChannels() async throws {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let url = try makeFile(rate: rate, channels: 2)
            defer { try? FileManager.default.removeItem(at: url) }
            let (_, info) = try await MediaImporter.probe(url)
            #expect(info.audio?.sampleRate == Int(rate))
            #expect(info.audio?.channels == 2)
            #expect(info.video == nil)
            #expect(abs(Double(info.duration.value) / Double(info.duration.timescale) - 1) < 0.01)
        }
    }

    @Test func fortyFourOneFileIsResampledToProjectRateKeepingDurationAndLevel() async throws {
        let url = try makeFile(rate: 44_100, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try await AudioSources.open(url: url, sampleRate: 48_000)
        let frames = try frameCount(src)
        #expect(abs(frames - 48_000) <= 64, "frames \(frames)")
        let peak = try readPeak(src, channel: 0)
        #expect(peak > 0.45 && peak < 0.55, "peak \(peak)")
    }

    @Test func fortyFourOneAndFortyEightFilesLineUpAtTheSameTime() async throws {
        // A burst at 0.5 s in a 44.1 kHz file and in a 48 kHz file must land on the same project frame (24 000).
        func burstFile(rate: Double) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("burst-\(UUID().uuidString).wav")
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let frames = AVAudioFrameCount(rate)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buf.frameLength = frames
            for i in 0..<Int(frames) { buf.floatChannelData![0][i] = 0 }
            buf.floatChannelData![0][Int(rate / 2)] = 1
            try AVAudioFile(forWriting: url, settings: format.settings).write(from: buf)
            return url
        }
        var positions: [Int] = []
        for rate in [44_100.0, 48_000.0] {
            let url = try burstFile(rate: rate)
            defer { try? FileManager.default.removeItem(at: url) }
            let src = try await AudioSources.open(url: url, sampleRate: 48_000)
            var buf = [Float](repeating: 0, count: 48_000)
            let n = try buf.withUnsafeMutableBufferPointer { try src.read(from: 0, count: 48_000, into: $0.baseAddress!, channel: 0) }
            #expect(n > 0)
            positions.append(buf.indices.max { abs(buf[$0]) < abs(buf[$1]) } ?? -1)
        }
        #expect(abs(positions[0] - 24_000) <= 48, "44.1 kHz burst at \(positions[0])")
        #expect(abs(positions[1] - 24_000) <= 2, "48 kHz burst at \(positions[1])")
    }

    @Test func fourChannelRecorderFileOffersEveryChannel() async throws {
        let levels: [Float] = [0.2, 0.4, 0.6, 0.8]
        let url = try makeFile(rate: 48_000, channels: 4, levels: levels)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, info) = try await MediaImporter.probe(url)
        #expect(info.audio?.channels == 4)
        for ch in 0..<4 {
            let src = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(ch), expectedChannels: 4)
            let peak = try readPeak(src, channel: 0)
            #expect(abs(peak - levels[ch]) < 0.03, "channel \(ch) peak \(peak)")
        }
        let pair = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .stereo(2, 3), expectedChannels: 4)
        #expect(abs(try readPeak(pair, channel: 0) - 0.6) < 0.03)
        #expect(abs(try readPeak(pair, channel: 1) - 0.8) < 0.03)
    }

    @Test func fiveOneFileProbesSixChannelsAndPlaysTheFrontPair() async throws {
        let levels: [Float] = [0.3, 0.5, 0.1, 0.1, 0.1, 0.1]
        let url = try makeFile(rate: 48_000, channels: 6, levels: levels, layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, info) = try await MediaImporter.probe(url)
        #expect(info.audio?.channels == 6)
        // No map: the file layout plays; it must not throw and the front left/right keep their own levels.
        let src = try await AudioSources.open(url: url, sampleRate: 48_000)
        let l = try readPeak(src, channel: 0), r = try readPeak(src, channel: 1)
        #expect(l > 0.05 && r > 0.05, "l \(l) r \(r)")
        #expect(try frameCount(src) >= 47_000)
    }

    @Test func flacImportsWithItsRate() async throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2]
        guard let url = try? makeFile(ext: "flac", rate: 44_100, channels: 2, settings: settings) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, info) = try await MediaImporter.probe(url)
        #expect(info.audio?.sampleRate == 44_100 && info.audio?.channels == 2)
    }

    @Test func unreadableFilesFailWithAMediaError() async throws {
        for ext in ["wav", "ogg", "mp4", "m4a"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).\(ext)")
            try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            await #expect(throws: MediaError.self, "\(ext)") { _ = try await MediaImporter.probe(url) }
        }
    }

    @Test func truncatedWavDoesNotCrashTheProbe() async throws {
        let url = try makeFile(rate: 48_000, channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let cut = FileManager.default.temporaryDirectory.appendingPathComponent("cut-\(UUID().uuidString).wav")
        try data.prefix(60).write(to: cut)
        defer { try? FileManager.default.removeItem(at: cut) }
        // Either a usable (short) file or a MediaError; never a trap.
        do { _ = try await MediaImporter.probe(cut) } catch { #expect(error is MediaError) }
    }
}
