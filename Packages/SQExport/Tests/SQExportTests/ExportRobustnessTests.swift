import Testing
import AVFoundation
import Foundation
import SQCore
import VideoToolbox
@testable import SQExport

/// EXP-08 (encoder choice) and EXP-31 (file names against what is already on disk).
///
/// There is no encoder factory to inject: the writer hands AVAssetWriter an encoder specification and VideoToolbox picks
/// the encoder. "Hardware" never sets RequireHardwareAcceleratedVideoEncoder, so a Mac without the engine (or with a
/// busy one) is served by the software encoder instead of failing the export. These tests pin that contract.
@Suite struct ExportRobustnessTests {
    private let enableKey = kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String
    private let requireKey = kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String

    @Test(.serialized, arguments: [VideoCodec.h264, VideoCodec.hevc])
    func softwareSwitchSetsTheSpecificationKey(codec: VideoCodec) throws {
        var s = smallSettings(codec: codec)
        s.video.hardwareEncoding = false
        let spec = try #require(ExportWriter.videoOutputSettings(s)[AVVideoEncoderSpecificationKey] as? [String: Any])
        #expect(spec[enableKey] as? Bool == false)
        #expect(spec[requireKey] == nil)
    }

    @Test(.serialized, arguments: [VideoCodec.h264, VideoCodec.hevc])
    func hardwareDefaultNeverRequiresTheEngine(codec: VideoCodec) {
        var s = smallSettings(codec: codec)
        s.video.hardwareEncoding = true
        let out = ExportWriter.videoOutputSettings(s)
        // No specification at all: the system may use the hardware engine and falls back to software when it cannot.
        #expect(out[AVVideoEncoderSpecificationKey] == nil)
    }

    @Test func hardwareIsTheDefault() {
        #expect(ExportSettings().video.hardwareEncoding)
    }

    /// Whatever engine the Mac has (or lacks), the default (hardware allowed) export finishes and produces all frames.
    @Test(.serialized, arguments: [true, false])
    func exportFinishesWhicheverEncoderServesIt(hardware: Bool) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.mp4")
        var s = smallSettings(codec: .h264, width: 320, height: 568)
        s.video.hardwareEncoding = hardware
        let src = TestPatternSource(width: 320, height: 568, frameCount: 12, frameDuration: Time(1, 30))
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
        let info = try await readVideo(url)
        #expect(info.frames == 12)
        #expect(info.codec == kCMVideoCodecType_H264)
    }

    // MARK: EXP-31

    private func job(_ name: String, dir: URL, srt: Bool = false) -> ExportJob {
        var s = smallSettings(codec: .h264)
        if srt { s.captions = .sidecarSRT }
        return ExportJob(name: name, settings: s, outputDirectory: dir) {
            ExportSources(video: TestPatternSource(width: 64, height: 112, frameCount: 3, frameDuration: Time(1, 30)))
        }
    }

    @Test func existingFileDifferingOnlyInCaseIsNotOverwritten() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("clip.MP4")
        try Data([7]).write(to: existing)
        // Only meaningful on a case-insensitive volume (the default); on a case-sensitive one the names do not collide.
        let insensitive = FileManager.default.fileExists(atPath: dir.appendingPathComponent("CLIP.mp4").path)
        let q = ExportQueue()
        let id = await q.enqueue(job("Clip", dir: dir))
        let name = try #require(await q.status(id)).outputURL.lastPathComponent
        #expect(name == (insensitive ? "Clip 2.mp4" : "Clip.mp4"))
        await q.runAll()
        #expect(try Data(contentsOf: existing) == Data([7]))
    }

    @Test func existingSidecarOnDiskReservesTheName() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1]).write(to: dir.appendingPathComponent("Clip.srt"))   // no Clip.mp4, but the .srt is taken
        let q = ExportQueue()
        let withSRT = await q.enqueue(job("Clip", dir: dir, srt: true))
        let without = await q.enqueue(job("Clip", dir: dir))
        #expect(try #require(await q.status(withSRT)).outputURL.lastPathComponent == "Clip 2.mp4")
        #expect(try #require(await q.status(without)).outputURL.lastPathComponent == "Clip.mp4")
        await q.runAll()
        #expect(try Data(contentsOf: dir.appendingPathComponent("Clip.srt")) == Data([1]))
    }

    @Test func gapsInExistingNamesAreFilledInOrder() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["Clip.mp4", "Clip 2.mp4", "Clip 4.mp4"] { try Data([0]).write(to: dir.appendingPathComponent(n)) }
        let q = ExportQueue()
        let ids = [await q.enqueue(job("Clip", dir: dir)), await q.enqueue(job("Clip", dir: dir))]
        var names: [String] = []
        for id in ids { names.append(try #require(await q.status(id)).outputURL.lastPathComponent) }
        #expect(names == ["Clip 3.mp4", "Clip 5.mp4"])
    }

    @Test func unsafeNameThatCollidesStillGetsANumber() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0]).write(to: dir.appendingPathComponent("a-b.mp4"))
        let q = ExportQueue()
        let id = await q.enqueue(job("a/b", dir: dir))
        #expect(try #require(await q.status(id)).outputURL.lastPathComponent == "a-b 2.mp4")
    }
}
