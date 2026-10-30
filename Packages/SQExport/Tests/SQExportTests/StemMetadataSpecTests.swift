import Testing
import AVFoundation
import Foundation
import SQCore
@testable import SQExport

private final class SilentAudio: AudioSource, @unchecked Sendable {
    let sampleRate = 48_000
    let channels = 2
    private var pos = 0
    let total: Int
    init(seconds: Int) { total = seconds * 48_000 }
    func nextChunk(maxFrames: Int) async throws -> AudioChunk? {
        let n = min(maxFrames, total - pos)
        guard n > 0 else { return nil }
        pos += n
        return AudioChunk(samples: [Float](repeating: 0.1, count: n * channels), channels: channels)
    }
}

@Suite struct StemMetadataSpecTests {
    @Test func proResLtAndProxy() {
        #expect(VideoCodec.prores422LT.isProRes && VideoCodec.prores422Proxy.isMastering)
        #expect(VideoCodec.prores422LT.displayName == "ProRes 422 LT")
        var s = ExportSettings()
        s.video.codec = .prores422LT
        #expect(ExportWriter.videoOutputSettings(s)[AVVideoCodecKey] as? AVVideoCodecType == .proRes422LT)
        s.video.codec = .prores422Proxy
        #expect(ExportWriter.videoOutputSettings(s)[AVVideoCodecKey] as? AVVideoCodecType == .proRes422Proxy)
        s.video.codec = .prores422LT
        let lt = s.estimatedVideoBitsPerSecond
        s.video.codec = .prores422
        #expect(lt < s.estimatedVideoBitsPerSecond)
        #expect(s.validate().isEmpty)
    }

    @Test func metadataItemsAndChapters() {
        let ms = [Marker(time: Time(0, 1), name: "Intro"), Marker(time: Time(20, 1), name: "Main"), Marker(time: Time(50, 1), name: "End")]
        let m = ExportMetadata(title: "Film", comment: "Cut 3", creationDate: Date(timeIntervalSince1970: 0), markers: ms)
        #expect(m.fullComment == "Cut 3\n\n0:00 Intro\n0:20 Main\n0:50 End")
        #expect(m.items.count == 3)
        #expect(ExportMetadata().isEmpty && ExportMetadata().items.isEmpty)
        var s = ExportSettings()
        s.metadata = m
        let back = try? JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s))
        #expect(back?.metadata == m)
    }

    @Test func oldSettingsDecodeWithoutMetadata() throws {
        let data = try JSONEncoder().encode(ExportSettings())
        let s = try JSONDecoder().decode(ExportSettings.self, from: data)
        #expect(s.metadata == nil)
    }

    @Test func platformSpecBundled() {
        let p = PlatformSpec.bundled
        #expect(p.platforms.count == 3)
        #expect(p.entry("shorts")?.maxDurationSeconds == 180)
        #expect(p.platforms.allSatisfy { $0.source.hasPrefix("https://") && $0.verified.count == 10 })
    }

    @Test func stemsWriteOneFilePerStem() async throws {
        var tl = Timeline(name: "T", format: SequenceFormat(frameDuration: Time(1, 30)))
        let c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, end: Time(2, 1)), start: .zero)
        var d = Track(kind: .audio, clips: [c]); d.audioRole = .dialogue
        var m = Track(kind: .audio, clips: [c]); m.audioRole = .music
        tl.tracks = [d, m]
        let stems = StemPlan.stems(for: tl)
        #expect(stems.count == 3)   // dialogue, music, M&E
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stems-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var a = AudioSettings(); a.codec = .pcm
        let out = try await StemExporter.export(stems: stems, base: "Show", directory: dir, format: .wav, duration: Time(1, 1),
                                                settings: a, encoder: AVExportEncoder(), audioFor: { _ in SilentAudio(seconds: 1) }, progress: { _ in })
        #expect(out.map(\.url.lastPathComponent) == ["Show_dialogue.wav", "Show_music.wav", "Show_me.wav"])
        for w in out { #expect((try? FileManager.default.attributesOfItem(atPath: w.url.path)[.size] as? Int) ?? 0 > 1000) }
    }
}
