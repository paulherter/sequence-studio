import AVFoundation
import Foundation
import Testing
import SQCore
@testable import SQTranscribe

// F7.10: transcription hears what the clip plays (the mapped channels). Channel c of the test file holds (c + 1) / 10.

private func writeWAV(channels: Int, frames: Int = 24_000) throws -> URL {
    func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    let values = (0..<channels).map { le(Int16((Double($0 + 1) / 10 * 32768).rounded())) }
    var pcm: [UInt8] = []
    for _ in 0..<frames { for c in 0..<channels { pcm += values[c] } }
    var d: [UInt8] = Array("RIFF".utf8) + le(UInt32(36 + pcm.count)) + Array("WAVEfmt ".utf8) + le(UInt32(16))
    d += le(UInt16(1)) + le(UInt16(channels)) + le(UInt32(48_000)) + le(UInt32(48_000 * channels * 2))
    d += le(UInt16(channels * 2)) + le(UInt16(16)) + Array("data".utf8) + le(UInt32(pcm.count)) + pcm
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-tr-\(UUID().uuidString).wav")
    try Data(d).write(to: url)
    return url
}

/// Records the file it was given and the level of its first channel at that moment.
private final class ListeningService: TranscriptionService, @unchecked Sendable {
    private let lock = NSLock()
    private var _heard: [(url: URL, level: Float)] = []
    var heard: [(url: URL, level: Float)] { lock.withLock { _heard } }
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let f = try AVAudioFile(forReading: url)
        let buf = try #require(AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4096))
        try f.read(into: buf, frameCount: 4096)
        let level = buf.floatChannelData![0][2000]
        lock.withLock { _heard.append((url, level)) }
        return Transcript(language: "de-DE", words: [w("hallo", 100, 400)])
    }
}

@Suite struct ChannelMappedTranscriptionTests {
    private func run(map: AudioChannelMap?, url: URL, expected: Int? = nil) async throws -> ListeningService {
        let m = UUID()
        let clip = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: t(0), end: t(500)), start: t(0),
                        mediaDuration: t(500))
        let tl = Timeline(name: "S", format: SequenceFormat(frameDuration: Time(1, 30)), tracks: [Track(kind: .audio, clips: [clip])])
        let service = ListeningService()
        let tr = try await TimelineTranscription.transcribe(timeline: tl, urls: [m: url], channelMaps: map.map { [m: $0] } ?? [:],
                                                            expectedChannels: expected.map { [m: $0] } ?? [:],
                                                            service: service, locale: Locale(identifier: "de-DE"), progress: { _ in })
        #expect(tr.words.map(\.text) == ["hallo"])
        return service
    }

    @Test func aMappedClipIsTranscribedFromItsChannel() async throws {
        let url = try writeWAV(channels: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try await run(map: .mono(2), url: url)          // the lavalier on channel 3
        let heard = try #require(s.heard.first)
        #expect(heard.url != url)
        #expect(abs(heard.level - 0.3) < 1e-3)
        #expect(!FileManager.default.fileExists(atPath: heard.url.path))      // the temporary file is gone
    }

    @Test func aClipWithoutAMapIsTranscribedFromTheFile() async throws {
        let url = try writeWAV(channels: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let s = try await run(map: nil, url: url)
        #expect(s.heard.first?.url == url)
    }

    @Test func aRenderErrorIsNotReportedAsNoAudio() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("sq-tr-missing-\(UUID().uuidString).wav")
        var thrown: Error?
        do { _ = try await run(map: .mono(0), url: missing) } catch { thrown = error }
        let error = try #require(thrown)
        #expect((error as? TranscriptionError) != .noAudio)
    }

    /// Transcribing again after the map changed renders the new channels (nothing is kept from the first run).
    @Test func reTranscribingAfterTheMapChangedHearsTheNewChannel() async throws {
        let url = try writeWAV(channels: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try await run(map: .mono(2), url: url, expected: 4)
        let second = try await run(map: .mono(1), url: url, expected: 4)
        #expect(abs(try #require(first.heard.first).level - 0.3) < 1e-3)
        #expect(abs(try #require(second.heard.first).level - 0.2) < 1e-3)
    }

    /// A map chosen against another channel count is stale: the file layout is transcribed.
    @Test func aStaleMapIsTranscribedFromTheFileLayout() async throws {
        let url = try writeWAV(channels: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let stale = try await run(map: .mono(2), url: url, expected: 2)
        #expect(abs(try #require(stale.heard.first).level - 0.3) > 1e-3)
    }
}
