import Testing
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
@testable import SQExport

/// Compressed samples of the first video track in decode order, plus its format description.
struct EncodedTrack {
    var format: CMFormatDescription
    /// (pts, dts) in decode order; dts is invalid for intra-only codecs.
    var times: [(pts: CMTime, dts: CMTime)]
    /// True when a later sample in decode order is presented earlier: the stream has B-frames (frame reordering).
    var hasReordering: Bool {
        zip(times, times.dropFirst()).contains { $1.pts < $0.pts }
    }
    var duration: Double
}

struct Pair: Sendable { var pts: CMTime; var dts: CMTime }

func readEncoded(_ url: URL) async throws -> EncodedTrack {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let fd = try #require(try await track.load(.formatDescriptions).first)
    let tk = Box(track)
    let times = try await offPool {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: tk.buffer, outputSettings: nil)
        reader.add(out); reader.startReading()
        var times: [Pair] = []
        while let sb = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sb) > 0 else { continue }
            times.append(Pair(pts: CMSampleBufferGetPresentationTimeStamp(sb), dts: CMSampleBufferGetDecodeTimeStamp(sb)))
        }
        return times
    }.map { (pts: $0.pts, dts: $0.dts) }
    let dur = try await track.load(.timeRange).duration.seconds
    return EncodedTrack(format: fd, times: times, duration: dur)
}

/// HEVC decoder configuration (hvcC): general_profile_idc and bitDepthLumaMinus8 + 8.
func hevcProfileAndDepth(_ fd: CMFormatDescription) -> (profile: Int, bitDepth: Int)? {
    guard let atoms = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
          let hvcc = atoms["hvcC"] as? Data, hvcc.count > 18 else { return nil }
    let b = [UInt8](hvcc)
    return (Int(b[1] & 0x1f), Int(b[17] & 0x07) + 8)
}

/// Frames whose bottom counter bar fill reveals the frame index (TestPatternSource) — read back as BGRA.
func decodedCounterFills(_ url: URL) async throws -> [Int] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let tk = Box(track)
    return try await offPool {
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: tk.buffer, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out); reader.startReading()
    var fills: [Int] = []
    while let sb = out.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + (h - 2) * CVPixelBufferGetBytesPerRow(pb)
        var n = 0
        for x in 0..<w where row[x * 4 + 1] > 128 { n += 1 }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        fills.append(n)
    }
    return fills
    }
}

private func readColourTags(_ fd: CMFormatDescription) -> (String?, String?, String?) {
    func ext(_ k: CFString) -> String? { CMFormatDescriptionGetExtension(fd, extensionKey: k) as? String }
    return (ext(kCMFormatDescriptionExtension_ColorPrimaries), ext(kCMFormatDescriptionExtension_TransferFunction),
            ext(kCMFormatDescriptionExtension_YCbCrMatrix))
}

private let rec709 = (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
                      kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
                      kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)

/// A test pattern that can be split into segments (each a fresh source over a sub-range of frames).
struct SegmentablePattern: SegmentableFrameSource {
    let inner: TestPatternSource
    var offset = 0
    var count: Int
    init(width: Int, height: Int, frameCount: Int) {
        inner = TestPatternSource(width: width, height: height, frameCount: frameCount, frameDuration: Time(1, 30))
        count = frameCount
    }
    var frameCount: Int { count }
    var frameDuration: Time { inner.frameDuration }
    var pixelFormat: ExportPixelFormat { .bgra8 }
    func frame(at index: Int) async throws -> CVPixelBuffer { try await inner.frame(at: offset + index) }
    func segment(_ range: Range<Int>) throws -> any FrameSource {
        var s = self
        s.offset = offset + range.lowerBound
        s.count = range.count
        return s
    }
}

@Suite(.serialized) struct Export10BitBFramesTests {
    // MARK: settings

    @Test func bFramesDefaultOnAndOldSettingsDecode() throws {
        #expect(VideoSettings().allowsFrameReordering)
        let old = #"{"codec":"h264","width":1080,"height":1920,"frameDuration":{"value":1,"timescale":30},"profile":"high","bitrate":{"average":{"_0":12000000}},"keyframeInterval":60,"hardwareEncoding":true}"#
        let v = try JSONDecoder().decode(VideoSettings.self, from: Data(old.utf8))
        #expect(v.allowsFrameReordering && v.codec == .h264 && v.width == 1080 && v.keyframeInterval == 60)
        var s = VideoSettings(); s.allowsFrameReordering = false; s.codec = .prores4444
        #expect(try JSONDecoder().decode(VideoSettings.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func outputSettingsReorderingFollowsSettingsAndProfile() {
        var s = smallSettings(codec: .h264)
        func reorder(_ s: ExportSettings) -> Bool? {
            (ExportWriter.videoOutputSettings(s)[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoAllowFrameReorderingKey] as? Bool
        }
        #expect(reorder(s) == true)
        s.video.allowsFrameReordering = false
        #expect(reorder(s) == false)
        s.video.allowsFrameReordering = true; s.video.profile = .baseline
        #expect(reorder(s) == false)   // Baseline has no B-frames
    }

    @Test func pixelFormatFollowsCodecAndDepth() {
        #expect(ExportSettings.socialDefault.sourcePixelFormat == .yuv420v)
        var s = ExportPreset.proRes.settings
        #expect(s.sourcePixelFormat == .yuv422v10)
        s.video.codec = .prores422
        #expect(s.sourcePixelFormat == .yuv422v10)
        s.video.codec = .prores4444
        #expect(s.sourcePixelFormat == .ayuv4444)
        s.video.codec = .hevc; s.video.profile = .main10
        #expect(s.sourcePixelFormat == .yuv420v10)
        #expect(s.video.bitDepth == 10)
        s.video.profile = .main
        #expect(s.video.bitDepth == 8)
    }

    @Test func newPresetsAreInTheCatalogue() {
        let ids = Set(ExportPreset.all.map(\.id))
        #expect(ids.contains(ExportPreset.proRes422.id) && ids.contains(ExportPreset.proRes4444.id))
        #expect(ids.contains(ExportPreset.hevc10.id))
        #expect(ExportPreset.proRes422.settings.video.codec == .prores422)
        #expect(ExportPreset.proRes4444.settings.video.codec == .prores4444)
        let h = ExportPreset.hevc10.settings
        #expect(h.video.codec == .hevc && h.video.profile == .main10)
        // Delivery presets ship with B-frames.
        #expect(ExportPreset.all.filter { !$0.codec.isMastering && $0 != .bestAtSize }.allSatisfy { $0.settings.video.allowsFrameReordering })
        #expect(ExportPreset.all.allSatisfy { $0.settings.validate().isEmpty })
    }

    // MARK: files

    @Test(.serialized, arguments: [VideoCodec.h264, VideoCodec.hevc])
    func bFramesInOutputOnlyWhenAllowed(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for allow in [true, false] {
            var s = smallSettings(codec: codec, width: 128, height: 128)
            s.video.allowsFrameReordering = allow
            s.video.keyframeInterval = 30
            let url = dir.appendingPathComponent("b\(allow).mp4")
            let src = TestPatternSource(width: 128, height: 128, frameCount: 30, frameDuration: Time(1, 30))
            try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
            let e = try await readEncoded(url)
            #expect(e.times.count == 30)
            #expect(e.hasReordering == allow, "\(codec) allow=\(allow)")
            let tags = readColourTags(e.format)
            #expect(tags.0 == rec709.0 && tags.1 == rec709.1 && tags.2 == rec709.2)
        }
    }

    @Test func hevcMain10IsTenBitAndTagged() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("h10.mov")
        var s = smallSettings(codec: .hevc, width: 128, height: 64)
        s.video.profile = .main10
        let tl = solidTimeline()
        let src = try TimelineFrameSource(timeline: tl, provider: solidProvider, width: 128, height: 64, frameDuration: Time(1, 30),
                                          frameCount: 12, pixelFormat: s.sourcePixelFormat)
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
        let e = try await readEncoded(url)
        #expect(CMFormatDescriptionGetMediaSubType(e.format) == kCMVideoCodecType_HEVC)
        let pd = try #require(hevcProfileAndDepth(e.format))
        #expect(pd.profile == 2 && pd.bitDepth == 10)   // Main 10
        let tags = readColourTags(e.format)
        #expect(tags.0 == rec709.0 && tags.1 == rec709.1 && tags.2 == rec709.2)
        #expect(e.times.count == 12)
    }

    @Test(.serialized, arguments: [(VideoCodec.prores422, kCMVideoCodecType_AppleProRes422), (VideoCodec.prores4444, kCMVideoCodecType_AppleProRes4444),
                      (VideoCodec.prores422HQ, kCMVideoCodecType_AppleProRes422HQ)])
    func proResVariantsDecodeToTheSourceColour(codec: VideoCodec, fourCC: CMVideoCodecType) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.mov")
        var s = ExportSettings.proRes422HQMaster
        s.video.codec = codec
        s.video.width = 128; s.video.height = 64
        s.audio.enabled = false
        let src = try TimelineFrameSource(timeline: solidTimeline(), provider: solidProvider, width: 128, height: 64,
                                          frameDuration: Time(1, 30), frameCount: 6, pixelFormat: s.sourcePixelFormat)
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: url, progress: { _ in })
        let info = try await readVideo(url)
        #expect(info.codec == fourCC)
        #expect(info.primaries == rec709.0 && info.transfer == rec709.1 && info.matrix == rec709.2)
        #expect(info.frames == 6)
        // Orange BGRA (40, 140, 230) survives the 10/16-bit source path within rounding.
        let px = try await firstFramePixel(url, x: 64, y: 32)
        #expect(abs(px.b - 40) <= 3 && abs(px.g - 140) <= 3 && abs(px.r - 230) <= 3, "\(codec): \(px)")
    }

    // MARK: parallel segments

    @Test(.serialized, arguments: [VideoCodec.h264, VideoCodec.prores422])
    func parallelSegmentsKeepEveryFrameInOrder(codec: VideoCodec) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = codec.isMastering ? ExportSettings.proRes422HQMaster : smallSettings(codec: codec, width: 128, height: 64)
        s.video.codec = codec
        s.video.width = 128; s.video.height = 64
        s.video.keyframeInterval = 15
        s.audio.enabled = true
        let url = dir.appendingPathComponent(codec.isMastering ? "seg.mov" : "seg.mp4")
        let src = SegmentablePattern(width: 128, height: 64, frameCount: 75)
        let audio = SineAudioSource(sampleRate: 48_000, channels: 2, duration: Time(75, 30))
        let box = ProgressBox()
        try await ExportWriter.export(video: src, audio: audio, settings: s, to: url, segments: 3, progress: { box.add($0) })
        let e = try await readEncoded(url)
        #expect(e.times.count == 75)
        // Presentation times are the frame grid with no gaps or duplicates (passthrough reads media times: with
        // B-frames they start at the composition delay, which the track's edit list maps to 0).
        let pts = e.times.map { Int(($0.pts.seconds * 30).rounded()) }.sorted()
        #expect(pts == Array(pts[0]..<(pts[0] + 75)))
        #expect(abs(e.duration - 2.5) < 0.02)
        if !codec.isMastering { #expect(e.hasReordering) }
        let dts = e.times.map(\.dts).filter { $0.isValid }
        #expect(zip(dts, dts.dropFirst()).allSatisfy { $0 < $1 }, "decode times increase across seams")
        let tags = readColourTags(e.format)
        #expect(tags.0 == rec709.0 && tags.1 == rec709.1 && tags.2 == rec709.2)
        // Counter bar grows frame by frame: the segments were joined in order.
        let fills = try await decodedCounterFills(url)
        #expect(fills.count == 75)
        #expect(zip(fills, fills.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(fills.last ?? 0 >= 126)
        // Audio is there and as long as the video.
        let a = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first)
        #expect(abs(try await a.load(.timeRange).duration.seconds - 2.5) < 0.05)
        let v = box.values
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 } && v.last == 1.0)
    }

    @Test func segmentsFallBackToOneForPlainSources() {
        let plain = TestPatternSource(width: 64, height: 64, frameCount: 900, frameDuration: Time(1, 30))
        #expect(ExportWriter.segmentCount(requested: 4, source: plain, settings: smallSettings(codec: .h264)) == 1)
        let seg = SegmentablePattern(width: 64, height: 64, frameCount: 900)
        #expect(ExportWriter.segmentCount(requested: 4, source: seg, settings: smallSettings(codec: .h264)) == 4)
        // Never more segments than frames allow (at least one keyframe interval per segment).
        let short = SegmentablePattern(width: 64, height: 64, frameCount: 20)
        #expect(ExportWriter.segmentCount(requested: 4, source: short, settings: smallSettings(codec: .h264)) == 1)
        // Automatic picks more than one for a long segmentable source.
        #expect(ExportWriter.segmentCount(requested: nil, source: seg, settings: smallSettings(codec: .h264)) >= 1)
    }

    /// Automatic segments (head probe, then one or two for the rest): every frame once, in order, with the same decoded
    /// pictures as a single-session export. A fast source is encoder-bound (rest in one piece), a slow one render-bound.
    @Test(arguments: [false, true])
    func automaticSegmentsKeepPicturesIdenticalToOneSession(slow: Bool) async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        var s = smallSettings(codec: .h264, width: 128, height: 64)
        s.video.frameDuration = Time(1, 30)
        s.video.keyframeInterval = 15
        let inner = SegmentablePattern(width: 128, height: 64, frameCount: 300)
        let src: any FrameSource = slow ? SlowSegmentable(inner: inner) : inner
        let one = dir.appendingPathComponent("one.mp4"), auto = dir.appendingPathComponent("auto.mp4")
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: one, segments: 1, progress: { _ in })
        try await ExportWriter.export(video: src, audio: nil, settings: s, to: auto, progress: { _ in })
        let e = try await readEncoded(auto)
        #expect(e.times.count == 300)
        let pts = e.times.map { Int(($0.pts.seconds * 30).rounded()) }.sorted()
        #expect(pts == Array(pts[0]..<(pts[0] + 300)))
        let a = try await decodedCounterFills(auto), b = try await decodedCounterFills(one)
        #expect(a.count == 300 && a == b)
    }

    @Test func cancelledSegmentedExportLeavesNoFiles() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.mp4")
        let src = SlowSegmentable(inner: SegmentablePattern(width: 64, height: 64, frameCount: 300))
        let task = Task {
            try await ExportWriter.export(video: src, audio: nil, settings: smallSettings(codec: .h264, width: 64, height: 64),
                                          to: url, segments: 2, progress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
}

struct SlowSegmentable: SegmentableFrameSource {
    let inner: SegmentablePattern
    var frameCount: Int { inner.frameCount }
    var frameDuration: Time { inner.frameDuration }
    var pixelFormat: ExportPixelFormat { .bgra8 }
    func frame(at index: Int) async throws -> CVPixelBuffer {
        try await Task.sleep(for: .milliseconds(20))
        return try await inner.frame(at: index)
    }
    func segment(_ range: Range<Int>) throws -> any FrameSource {
        SlowSegmentable(inner: try inner.segment(range) as! SegmentablePattern)
    }
}

private let solidID = UUID()
private let solidProvider = SolidProvider(colors: [solidID: (40, 140, 230)], width: 128, height: 64)
private func solidTimeline() -> Timeline {
    let c = Clip(name: "o", media: solidID, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
    return Timeline(name: "t", format: SequenceFormat(width: 128, height: 64, frameDuration: Time(1, 30)),
                    tracks: [Track(kind: .video, clips: [c])])
}

private func firstFramePixel(_ url: URL, x: Int, y: Int) async throws -> (b: Int, g: Int, r: Int) {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let tk = Box(track)
    let px: [Int]? = try await offPool {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: tk.buffer, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading()
        guard let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
        return [Int(p[0]), Int(p[1]), Int(p[2])]
    }
    let v = try #require(px)
    return (v[0], v[1], v[2])
}
