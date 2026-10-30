import Testing
import AVFoundation
import CoreMedia
import Foundation
import SQCore
@testable import SQExport

func makeTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sqexport-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func smallSettings(codec: VideoCodec, width: Int = 64, height: Int = 112) -> ExportSettings {
    var s = ExportSettings()
    s.video.codec = codec
    s.video.width = width; s.video.height = height
    s.video.frameDuration = Time(1, 30)
    s.video.bitrate = .average(400_000)
    s.video.keyframeInterval = 10
    s.video.hardwareEncoding = false
    s.audio.enabled = false
    return s
}

/// Runs blocking AVAssetReader work on a dispatch queue: blocking cooperative-pool threads in many parallel tests
/// starves the export tasks they wait for (deadlock).
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await onBlockingReadQueue(work)
}

struct VideoInfo { var primaries: String?; var transfer: String?; var matrix: String?; var codec: CMVideoCodecType; var size: CGSize; var frames: Int }

func readVideo(_ url: URL) async throws -> VideoInfo {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let fd = try #require(try await track.load(.formatDescriptions).first)
    func ext(_ k: CFString) -> String? { CMFormatDescriptionGetExtension(fd, extensionKey: k) as? String }
    let size = try await track.load(.naturalSize)
    let tk = Box(track)
    let n = try await offPool {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: tk.buffer, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading()
        var n = 0
        while out.copyNextSampleBuffer() != nil { n += 1 }
        return n
    }
    return VideoInfo(primaries: ext(kCMFormatDescriptionExtension_ColorPrimaries),
                     transfer: ext(kCMFormatDescriptionExtension_TransferFunction),
                     matrix: ext(kCMFormatDescriptionExtension_YCbCrMatrix),
                     codec: CMFormatDescriptionGetMediaSubType(fd), size: size, frames: n)
}

@Suite struct ExportWriterTests {
    @Test(.serialized, arguments: [VideoCodec.h264, VideoCodec.hevc])
    func exportsTaggedRec709(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.mp4")
        let s = smallSettings(codec: codec)
        let src = TestPatternSource(width: 64, height: 112, frameCount: 20, frameDuration: Time(1, 30))
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
        let info = try await readVideo(url)
        #expect(info.primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
        #expect(info.transfer == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
        #expect(info.matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String))
        #expect(info.codec == (codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC))
        #expect(info.size == CGSize(width: 64, height: 112))
        #expect(info.frames == 20)
    }

    @Test func progressIsMonotonicAndEndsAtOne() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let box = ProgressBox()
        let src = TestPatternSource(width: 64, height: 112, frameCount: 12, frameDuration: Time(1, 30))
        try await ExportWriter.export(video: src, audio: nil, settings: smallSettings(codec: .h264),
                                      to: dir.appendingPathComponent("p.mp4"), progress: { box.add($0) })
        let v = box.values
        #expect(!v.isEmpty)
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(v.last == 1.0)
    }

    @Test func cancellationRemovesPartialFile() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.mp4")
        let src = SlowSource(inner: TestPatternSource(width: 64, height: 112, frameCount: 300, frameDuration: Time(1, 30)))
        let task = Task {
            try await ExportWriter.export(video: src, audio: nil, settings: smallSettings(codec: .h264), to: url, progress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func invalidSettingsThrow() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = smallSettings(codec: .h264); s.video.width = 63
        let src = TestPatternSource(width: 63, height: 112, frameCount: 2, frameDuration: Time(1, 30))
        await #expect(throws: ExportError.self) {
            try await ExportWriter.export(video: src, audio: nil, settings: s, to: dir.appendingPathComponent("x.mp4"), progress: { _ in })
        }
    }

    @Test func existingFileIsReplaced() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("r.mp4")
        try Data([1, 2, 3]).write(to: url)
        let src = TestPatternSource(width: 64, height: 112, frameCount: 5, frameDuration: Time(1, 30))
        try await ExportWriter.export(video: src, audio: nil, settings: smallSettings(codec: .h264), to: url, progress: { _ in })
        #expect((try await readVideo(url)).frames == 5)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var _v: [Double] = []
    func add(_ x: Double) { lock.lock(); _v.append(x); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _v }
}

/// Blocks in every frame request until the task is canceled (a deterministic "running job", no timing).
struct HoldSource: FrameSource {
    let inner: TestPatternSource
    var frameCount: Int { inner.frameCount }
    var frameDuration: Time { inner.frameDuration }
    func frame(at index: Int) async throws -> CVPixelBuffer {
        try await Task.sleep(for: .seconds(3600))
        return try await inner.frame(at: index)
    }
}

struct SlowSource: FrameSource {
    let inner: TestPatternSource
    var frameCount: Int { inner.frameCount }
    var frameDuration: Time { inner.frameDuration }
    func frame(at index: Int) async throws -> CVPixelBuffer {
        try await Task.sleep(for: .milliseconds(20))
        return try await inner.frame(at: index)
    }
}
