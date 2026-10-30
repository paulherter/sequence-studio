import AVFoundation
import Foundation
import SQCore
import Testing
@testable import SQMedia

/// Audio import conformance: one generated file per container family, decoded through `AudioSources.open`, must put
/// a marker where the file says it is (sample accurate for lossless, within one codec frame for lossy), keep channel
/// order, and survive the odd headers recorders write (RF64, MP3 with encoder delay). No footage: every file is built here.
@Suite struct AudioConformanceTests {
    private static let rate = 48_000.0

    private func tmpURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("conf-\(UUID().uuidString).\(ext)")
    }

    /// Writes `channels` of tone (100 Hz, one level each) or, with `burstAt`, silence with a click burst.
    private func write(ext: String, settings: [String: Any], channels: AVAudioChannelCount, seconds: Double = 1,
                       levels: [Float]? = nil, burstAt: Int? = nil, layoutTag: AudioChannelLayoutTag? = nil) throws -> URL {
        let url = tmpURL(ext)
        let rate = Self.rate
        let format: AVAudioFormat
        if let tag = layoutTag, let layout = AVAudioChannelLayout(layoutTag: tag) {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        } else {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        }
        let frames = AVAudioFrameCount(rate * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for c in 0..<Int(channels) {
            let p = buf.floatChannelData![c]
            for i in 0..<Int(frames) {
                if let b = burstAt {
                    p[i] = (i >= b && i < b + 480) ? 0.9 * Float(sin(2 * Double.pi * 1000 * Double(i - b) / rate)) : 0
                } else {
                    p[i] = (levels?[c] ?? 0.5) * Float(sin(2 * Double.pi * 100 * Double(i) / rate))
                }
            }
        }
        var settings = settings
        if channels > 2, let l = format.channelLayout?.layout {
            settings[AVChannelLayoutKey] = Data(bytes: l, count: MemoryLayout<AudioChannelLayout>.size)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buf)
        }
        return url
    }

    private func readAll(_ src: any AudioSource, channel: Int = 0, max: Int = 200_000) throws -> [Float] {
        var out = [Float](repeating: 0, count: max)
        let n = try out.withUnsafeMutableBufferPointer { try src.read(from: 0, count: max, into: $0.baseAddress!, channel: channel) }
        return Array(out[0..<n])
    }

    private func firstLoud(_ a: [Float], threshold: Float = 0.2) -> Int? { a.firstIndex { abs($0) > threshold } }

    private func peak(_ a: [Float], from: Int = 4_800, count: Int = 9_600) -> Float {
        a[from..<min(a.count, from + count)].map(abs).max() ?? 0
    }

    // MARK: Sample-accurate sync, one per container family

    @Test(arguments: [
        ("wav", Int(kAudioFormatLinearPCM)),
        ("aif", Int(kAudioFormatLinearPCM)),
        ("caf", Int(kAudioFormatLinearPCM)),
        ("flac", Int(kAudioFormatFLAC)),
        ("m4a", Int(kAudioFormatAppleLossless)),
    ])
    func losslessFamiliesKeepTheMarkerExactly(ext: String, format: Int) async throws {
        var s: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1]
        if format == Int(kAudioFormatLinearPCM) {
            s[AVLinearPCMBitDepthKey] = 24
            s[AVLinearPCMIsFloatKey] = false
            s[AVLinearPCMIsBigEndianKey] = ext == "aif"
            s[AVLinearPCMIsNonInterleaved] = false
        }
        let url = try write(ext: ext, settings: s, channels: 1, burstAt: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try await AudioSources.open(url: url, sampleRate: 48_000)
        let first = try firstLoud(readAll(src))
        #expect(first != nil && abs(first! - 24_000) <= 2, "\(ext) marker at \(String(describing: first))")
    }

    @Test func aacMarkerIsWithinOneCodecFrame() async throws {
        let s: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
                                AVEncoderBitRateKey: 128_000]
        let url = try write(ext: "m4a", settings: s, channels: 1, burstAt: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let src = try await AudioSources.open(url: url, sampleRate: 48_000)
        let first = try firstLoud(readAll(src), threshold: 0.1)
        #expect(first != nil && abs(first! - 24_000) <= 1_024, "aac marker at \(String(describing: first))")
    }

    // MARK: Channel order

    @Test func fiveOneAACKeepsFilmChannelOrder() async throws {
        // Whatever order the file declares (AAC 5.1: C L R Ls Rs LFE); every channel gets its own level and must come back at the same index.
        let levels: [Float] = [0.15, 0.3, 0.45, 0.6, 0.75, 0.9]
        let s: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 6,
                                AVEncoderBitRateKey: 384_000]
        let url = try write(ext: "m4a", settings: s, channels: 6, levels: levels, layoutTag: kAudioChannelLayoutTag_AAC_5_1)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, info) = try await MediaImporter.probe(url)
        #expect(info.audio?.channels == 6)
        var got: [Float] = []
        for ch in 0..<6 {
            let src = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(ch), expectedChannels: 6)
            got.append(peak(try readAll(src)))
        }
        for ch in 0..<6 { #expect(abs(got[ch] - levels[ch]) < 0.12, "channel \(ch): \(got[ch]) vs \(levels[ch])") }
        #expect(got == got.sorted(), "order preserved: \(got)")
    }

    @Test func eightChannelAACProbesAndDecodesEveryChannel() async throws {
        let levels: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        let s: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 8,
                                AVEncoderBitRateKey: 512_000]
        let url = try write(ext: "m4a", settings: s, channels: 8, levels: levels, layoutTag: kAudioChannelLayoutTag_AAC_7_1)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, info) = try await MediaImporter.probe(url)
        #expect(info.audio?.channels == 8)
        for ch in [0, 3, 7] {
            let src = try await AudioSources.open(url: url, sampleRate: 48_000, channelMap: .mono(ch), expectedChannels: 8)
            let p = peak(try readAll(src))
            #expect(p > 0.03, "channel \(ch) silent")
        }
    }

    // MARK: Headers

    /// RF64 is what recorders write past 4 GB: "RF64" magic, 0xFFFFFFFF sizes, a ds64 chunk with the real ones.
    @Test func rf64WaveReadsLikeWave() async throws {
        let frames = 48_000
        var pcm = Data()
        for i in 0..<frames {
            var v = Int16(0)
            if i >= 24_000 && i < 24_480 { v = Int16(0.9 * 32_767 * sin(2 * Double.pi * 1000 * Double(i - 24_000) / Self.rate)) }
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RF64".utf8) + le32(0xFFFF_FFFF) + Data("WAVE".utf8)
        d += Data("ds64".utf8) + le32(28) + le64(UInt64(4 + 36 + 28 + 8 + pcm.count)) + le64(UInt64(pcm.count)) + le64(UInt64(frames)) + le32(0)
        d += Data("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(48_000) + le32(96_000) + le16(2) + le16(16)
        d += Data("data".utf8) + le32(0xFFFF_FFFF) + pcm
        let url = tmpURL("wav")
        try d.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, info) = try await MediaImporter.probe(url)
        #expect(info.audio?.sampleRate == 48_000 && info.audio?.channels == 1)
        #expect(abs(Double(info.duration.value) / Double(info.duration.timescale) - 1) < 0.01)
        let src = try await AudioSources.open(url: url, sampleRate: 48_000)
        let first = try firstLoud(readAll(src))
        #expect(first != nil && abs(first! - 24_000) <= 2, "rf64 marker at \(String(describing: first))")
    }

    /// MP3 has an encoder delay (1105 samples with the usual decoder). A silent stream of N frames must report and
    /// decode to about N * 1152 samples minus that delay, never longer than the frames it holds.
    @Test func mp3KeepsItsDurationWithEncoderDelay() async throws {
        let frameCount = 100                                       // MPEG-1 Layer III, 128 kbps, 44.1 kHz: 417 bytes
        var frame = Data([0xFF, 0xFB, 0x90, 0x64]); frame.append(Data(count: 413))
        var d = Data()
        for _ in 0..<frameCount { d.append(frame) }
        let url = tmpURL("mp3")
        try d.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, info) = try await MediaImporter.probe(url)
        let seconds = Double(info.duration.value) / Double(info.duration.timescale)
        let full = Double(frameCount * 1152) / 44_100
        #expect(seconds <= full + 0.001 && seconds > full - 0.06, "mp3 duration \(seconds) vs \(full)")
        // AVAssetReader ends this stream at either 16 samples short or 560 past the track's end (about one in four reads,
        // measured 2026-10-28): several opens, so the overrun cannot slip through on a lucky read.
        let expected = full * 48_000
        for _ in 0..<8 {
            let src = try await AudioSources.open(url: url, sampleRate: 48_000)
            let frames = try readAll(src, max: 400_000).count
            #expect(Double(frames) <= expected + 100 && Double(frames) > expected - 0.06 * 48_000, "mp3 frames \(frames) vs \(expected)")
        }
    }
}
