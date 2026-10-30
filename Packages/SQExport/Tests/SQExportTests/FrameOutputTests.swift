@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
@testable import SQExport

// GIF export (centisecond delays), numbered image sequences with alpha, FLAC, constant quality.

@Suite(.serialized) struct FrameOutputTests {
    // MARK: GIF timing

    @Test func gifDelaysAlternateAndSumToTheDuration() {
        let d24 = GIFTiming.delaysCentiseconds(frameDuration: Time(1, 24), frameCount: 6)
        #expect(Array(d24.prefix(3)) == [4, 4, 5])
        #expect(d24.reduce(0, +) == 25)
        // 23.976, 24, 29.97: the sum is the sequence duration in centiseconds (rounded), not frames * round(100 / fps).
        for (fd, frames) in [(Time(1001, 24000), 240), (Time(1, 24), 240), (Time(1001, 30000), 300)] {
            let delays = GIFTiming.delaysCentiseconds(frameDuration: fd, frameCount: frames)
            #expect(delays.count == frames)
            let exact = Double(frames) * 100 * Double(fd.value) / Double(fd.timescale)
            #expect(delays.reduce(0, +) == Int(exact.rounded()), "\(fd)")
            #expect(delays.allSatisfy { $0 >= 3 && $0 <= 5 })
        }
    }

    @Test func gifDelaysOfNothing() {
        #expect(GIFTiming.delaysCentiseconds(frameDuration: Time(1, 24), frameCount: 0).isEmpty)
        #expect(GIFTiming.delaysCentiseconds(frameDuration: Time(0, 24), frameCount: 3).isEmpty)
    }

    @Test func gifFileHasFrameCountAndDelays() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.gif")
        var s = ExportSettings(); s.frameOutput = .gif
        s.video.width = 32; s.video.height = 32; s.video.frameDuration = Time(1, 24)
        let v = TestPatternSource(width: 32, height: 32, frameCount: 8, frameDuration: Time(1, 24))
        try await ExportWriter.export(video: v, audio: nil, settings: s, to: url, progress: { _ in })
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 8)
        var total = 0.0
        for i in 0..<8 {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = try #require(props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            total += (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        }
        #expect(abs(total - 0.33) < 0.005, "sum of delays \(total)")
    }

    // MARK: Naming

    @Test func sequenceNamesAreSanitizedAndPadded() {
        #expect(ImageSequenceNaming.fileName(stem: "a/b:c", number: 7, digits: 4, ext: "png") == "a-b-c_0007.png")
        #expect(ImageSequenceNaming.digits(startNumber: 0, count: 10) == 4)
        #expect(ImageSequenceNaming.digits(startNumber: 0, count: 10_000) == 4)
        #expect(ImageSequenceNaming.digits(startNumber: 0, count: 10_001) == 5)
        #expect(ImageSequenceNaming.digits(startNumber: 99_990, count: 20) == 6)
        let names = ImageSequenceNaming.fileNames(stem: "Shot", startNumber: 8, count: 3, ext: "tiff")
        #expect(names == ["Shot_0008.tiff", "Shot_0009.tiff", "Shot_0010.tiff"])
        #expect(ImageSequenceNaming.fileNames(stem: "x", count: 0, ext: "png").isEmpty)
    }

    // MARK: Settings

    @Test func frameOutputSettings() throws {
        var s = ExportPreset.imageSequence.settings
        #expect(s.frameOutput == .sequence(.pngAlpha))
        #expect(s.fileExtension == "")
        #expect(s.sourcePixelFormat == .rgbaHalf)
        s.video.width = 33; s.video.height = 17
        #expect(s.validate().isEmpty)
        let back = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        var g = ExportPreset.gif.settings
        #expect(g.fileExtension == "gif" && g.sourcePixelFormat == .bgra8)
        g.video.width = 0
        #expect(g.validate().contains(.oddDimensions))
        let plain = try JSONEncoder().encode(ExportSettings())
        #expect(!String(decoding: plain, as: UTF8.self).contains("frameOutput"))
    }

    @Test func queueNamesASequenceFolderWithoutExtension() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let queue = ExportQueue()
        let job = ExportJob(name: "My: Shot", settings: ExportPreset.imageSequence.settings, outputDirectory: dir) {
            ExportSources(video: TestPatternSource(width: 8, height: 8, frameCount: 1, frameDuration: Time(1, 30)))
        }
        let id = await queue.enqueue(job)
        let url = try #require(await queue.status(id)?.outputURL)
        #expect(url.lastPathComponent == "My- Shot")
    }

    // MARK: Constant quality

    @Test func constantQualityReplacesTheBitrate() throws {
        var s = ExportSettings(); s.video.codec = .hevc
        s.video.constantQuality = 0.6
        #expect(s.video.usesConstantQuality && !s.video.usesConstantBitrate)
        let comp = try #require(ExportWriter.videoOutputSettings(s)[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(comp[AVVideoQualityKey] as? Double == 0.6)
        #expect(comp[AVVideoAverageBitRateKey] == nil)
        let p = ExportWriter.speedEncoderProperties(s)
        #expect(p.required["Quality"] as? Double == 0.6)
        #expect(p.required["AverageBitRate"] == nil)
        // Bitrate mode is unchanged, ProRes ignores the quality.
        var b = ExportSettings()
        #expect((ExportWriter.videoOutputSettings(b)[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAverageBitRateKey] != nil)
        b.video.codec = .prores422; b.video.constantQuality = 0.5
        #expect(b.video.constantQuality == nil)
    }

    @Test func oldSettingsDecodeInBitrateMode() throws {
        let data = try JSONEncoder().encode(ExportSettings())
        #expect(!String(decoding: data, as: UTF8.self).contains("constantQuality"))
        #expect(try JSONDecoder().decode(ExportSettings.self, from: data).video.constantQuality == nil)
        var s = ExportSettings(); s.video.constantQuality = 0.7
        let back = try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s))
        #expect(back.video.constantQuality == 0.7)
    }

    @Test func constantQualityEncodesAFile() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = ExportSettings(); s.video.width = 64; s.video.height = 64; s.video.frameDuration = Time(1, 30)
        s.video.constantQuality = 0.5; s.audio.enabled = false
        let v = TestPatternSource(width: 64, height: 64, frameCount: 12, frameDuration: Time(1, 30))
        let url = dir.appendingPathComponent("q.mp4")
        try await ExportWriter.export(video: v, audio: nil, settings: s, to: url, progress: { _ in })
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    }

    // MARK: FLAC

    @Test func flacAudioOnlyExport() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.flac")
        let s = ExportPreset.audioFLAC.settings
        #expect(s.audioOnly == .flac && s.fileExtension == "flac" && s.validate().isEmpty)
        let v = TestPatternSource(width: 64, height: 112, frameCount: 30, frameDuration: Time(1, 30))
        let a = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(1, 1))
        try await ExportWriter.export(video: v, audio: a, settings: s, to: url, progress: { _ in })
        let f = try AVAudioFile(forReading: url)
        #expect(f.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatFLAC)
        #expect(f.length == 48_000)
        #expect(f.fileFormat.channelCount == 2)
        var bad = s; bad.audio.pcmBitDepth = 32
        #expect(bad.validate().contains(.invalidAudio))
    }

    // MARK: Sequence through the real pipeline

    func decode(_ url: URL) throws -> (w: Int, h: Int, px: [UInt8], alpha: CGImageAlphaInfo) {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, px, img.alphaInfo)
    }

    @Test func imageSequenceKeepsAlphaAndRange() async throws {
        var spec = TestClipSpec(); spec.codec = .prores4444Alpha; spec.width = 64; spec.height = 32; spec.frameCount = 4
        let clipURL = try await TestClipWriter.write(spec); defer { try? FileManager.default.removeItem(at: clipURL) }
        let media = UUID()
        let provider = DecoderFrameProvider(resolver: StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: clipURL)]))
        let fd = Time(1, 30)
        let clip = Clip(name: "fg", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 30)), start: .zero)
        let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 32, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [clip])])
        var s = ExportPreset.imageSequence.settings
        s.video.width = 64; s.video.height = 32; s.video.frameDuration = fd
        // Two frames of the four: the range decides the file count.
        s.range = .inOut(TimeRange(start: Time(1, 30), duration: Time(2, 30)))
        let src = try TimelineFrameSource(timeline: tl, provider: provider, width: 64, height: 32, frameDuration: fd,
                                          frameCount: 2, startTime: Time(1, 30), pixelFormat: s.sourcePixelFormat)
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Seq")
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: folder, progress: { _ in })
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["Seq_0000.png", "Seq_0001.png"])
        let d = try decode(folder.appendingPathComponent(files[0]))
        #expect(d.alpha != .none && d.alpha != .noneSkipLast)
        let row = 16 * d.w * 4
        #expect(d.px[row + 12 * 4 + 3] > 250, "opaque part")
        #expect(d.px[row + 58 * 4 + 3] < 5, "transparent part")
    }
}
