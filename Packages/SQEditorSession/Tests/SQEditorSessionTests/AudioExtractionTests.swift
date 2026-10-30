import AVFoundation
import Foundation
import Testing
import SQCore
import SQMedia
import SQPlayback
@testable import SQEditorSession

@MainActor @Suite struct AudioExtractionTests {
    private func ref(_ name: String, audio: Bool = true, path: String) -> MediaRef {
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false)
        let a = audio ? AudioTrackInfo(sampleRate: 48_000, channels: 2, codec: "aac") : nil
        return MediaRef(name: name, path: path, fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1),
                        info: MediaInfo(duration: Time(2, 1), video: v, audio: a))
    }

    private func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sqax-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func destinationNamesTheFileAfterTheMediaAndNeverOverwrites() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let r = ref("Interview.mov", path: "/x/Interview.mov")
        let first = AudioExtraction.destination(for: r, in: dir)
        #expect(first.lastPathComponent == "Interview (audio).m4a")
        try Data([1]).write(to: first)
        #expect(AudioExtraction.destination(for: r, in: dir).lastPathComponent == "Interview (audio 2).m4a")
    }

    @Test func mediaWithoutSoundIsRefused() async {
        let r = ref("silent.mov", audio: false, path: "/x/silent.mov")
        let url = tmp().appendingPathComponent("o.m4a")
        await #expect(throws: AudioExtraction.Failure.noAudio) {
            try await AudioExtraction.write(r, resolver: StaticMediaResolver(), to: url)
        }
    }

    @Test func extractWritesAnM4AOfTheSourceLengthAndImportsItAsAnItem() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = ref("Talk.mov", path: dir.appendingPathComponent("Talk.mov").path)
        try Data([1]).write(to: URL(fileURLWithPath: source.path))
        let n = 96_000
        let tone = (0..<n).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.3 }
        let resolver = StaticMediaResolver(audio: [source.id: MemoryAudioSource(left: tone, right: tone)])
        var p = Project(name: "P"); p.add(source)
        let model = ProjectPanelModel(project: p, probe: { url in
            MediaRef(name: url.lastPathComponent, path: url.path, fingerprint: MediaFingerprint(size: 1))
        }, onEdit: { _, _ in })
        let id = try await model.extractAudio(of: source.id, resolver: resolver, folder: dir)
        let item = try #require(id.flatMap { model.project.media($0) })
        #expect(item.name == "Talk (audio).m4a")
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: item.path))
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 2.0) < 0.15)
        #expect(model.project.media.count == 2)       // the source stays
    }
}
