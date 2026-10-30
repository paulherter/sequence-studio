import AVFoundation
import SQCore
import XCTest
@testable import SQMedia

/// Proxies, stabilization and transcription read WebM / MKV and MXF through `WebMReadback`: MXF goes the same way.
final class ContainerReadbackTests: XCTestCase {
    private func writeMXF(audioTracks: Int) throws -> URL {
        var fx = MXFFixture()
        fx.frames = (0..<6).map { H264TestStream.frame(.init(), luma: 40 + 20 * $0, idrID: $0 & 1) }
        fx.audioTracks = audioTracks
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-readback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.MXF")
        try fx.build().write(to: url)
        return url
    }

    func testHandlesWebMAndMXFOnly() throws {
        let mxf = try writeMXF(audioTracks: 0)
        XCTAssertTrue(WebMReadback.handles(mxf))
        let other = mxf.deletingLastPathComponent().appendingPathComponent("x.mov")
        try Data([0, 0, 0, 8, 0x66, 0x74, 0x79, 0x70]).write(to: other)
        XCTAssertFalse(WebMReadback.handles(other))
        let mkv = mxf.deletingLastPathComponent().appendingPathComponent("x.mkv")
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0, 0]).write(to: mkv)
        XCTAssertTrue(WebMReadback.handles(mkv), "Matroska shares the WebM header")
    }

    func testMXFFramesComeThroughTheSharedReader() async throws {
        let url = try writeMXF(audioTracks: 0)
        var pts: [Time] = []
        try await WebMReadback.forEachFrame(url: url) { pts.append($0.pts) }
        XCTAssertEqual(pts.count, 6)
        XCTAssertEqual(pts, pts.sorted())
        var part = 0
        try await WebMReadback.forEachFrame(url: url, range: TimeRange(start: pts[2], duration: Time(2, 25))) { _ in part += 1 }
        XCTAssertEqual(part, 2)
    }

    func testMXFAudioBecomesAReadableFile() async throws {
        let url = try writeMXF(audioTracks: 2)
        let (_, total) = try await WebMReadback.openAudio(url, sampleRate: 48_000)
        XCTAssertEqual(total, 6 * 1920)
        let out = url.deletingLastPathComponent().appendingPathComponent("a.caf")
        try await WebMReadback.writeAudioFile(from: url, to: out)
        let file = try AVAudioFile(forReading: out)
        XCTAssertEqual(file.length, 6 * 1920)
    }

    func testMXFWithoutSoundThrowsForAudio() async throws {
        let url = try writeMXF(audioTracks: 0)
        do { _ = try await WebMReadback.openAudio(url, sampleRate: 48_000); XCTFail("no sound") } catch {}
    }
}
