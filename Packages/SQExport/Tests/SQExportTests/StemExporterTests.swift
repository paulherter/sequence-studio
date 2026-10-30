import Foundation
import Testing
import SQCore
@testable import SQExport

/// Stems go through the platform's `ExportEncoding` (Windows: FFmpeg), one audio file per stem.
@Suite struct StemExporterTests {
    private final class Recorder: ExportEncoding, @unchecked Sendable {
        var files: [(String, AudioFileFormat, Time, Bool)] = []
        func export(video: any FrameSource, audio: (any AudioSource)?, settings: ExportSettings, to url: URL,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? { nil }
        func exportAudioFile(_ audio: any AudioSource, format: AudioFileFormat, duration: Time, settings: AudioSettings,
                             to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
            files.append((url.lastPathComponent, format, duration, settings.loudness == nil))
            try Data([1]).write(to: url)
            progress(1)
            return nil
        }
    }

    private struct Silence: AudioSource {
        let sampleRate = 48_000, channels = 2
        func nextChunk(maxFrames: Int) async throws -> AudioChunk? { nil }
    }

    @Test func everyStemGoesThroughTheEncoder() async throws {
        var tl = Timeline(name: "T", format: SequenceFormat(frameDuration: Time(1, 30)))
        let c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, end: Time(2, 1)), start: .zero)
        var d = Track(kind: .audio, clips: [c]); d.audioRole = .dialogue
        var m = Track(kind: .audio, clips: [c]); m.audioRole = .music
        tl.tracks = [d, m]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stemenc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0]).write(to: dir.appendingPathComponent("Show_music.flac"))   // an old file is replaced
        let rec = Recorder()
        var a = AudioSettings(); a.codec = .pcm; a.pcmBitDepth = 24
        let out = try await StemExporter.export(stems: StemPlan.stems(for: tl), base: "Show", directory: dir, format: .flac,
                                                duration: Time(2, 1), settings: a, encoder: rec,
                                                audioFor: { _ in Silence() }, progress: { _ in })
        #expect(out.map(\.url.lastPathComponent) == ["Show_dialogue.flac", "Show_music.flac", "Show_me.flac"])
        #expect(rec.files.map(\.0) == ["Show_dialogue.flac", "Show_music.flac", "Show_me.flac"])
        #expect(rec.files.allSatisfy { $0.1 == .flac && $0.2 == Time(2, 1) && $0.3 })
    }
}
