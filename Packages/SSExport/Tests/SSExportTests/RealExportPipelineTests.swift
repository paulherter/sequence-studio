import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SSCore
import SSMedia
import SSMediaTestSupport
import SSPlayback
import SSText
import Testing
import VideoToolbox
@testable import SSExport

/// 2 s timeline from a generated stamped clip (source starts 10 frames in, so output frame i shows stamp i + 10),
/// a text clip on the second video track (0.5 s ... 1.5 s) and the clip's audio (click at source 0.5 s).
fileprivate struct Fixture {
    let timeline: Timeline
    let resolver: StaticMediaResolver
    let mediaID = UUID()
    let textClip: Clip
}

private let fd = Time(1, 30)

fileprivate func makeFixture(withText: Bool = true) async throws -> Fixture {
    var spec = TestClipSpec()
    spec.width = 320; spec.height = 180; spec.frameCount = 90          // 3 s
    spec.audioClicks = [CMTime(value: 1, timescale: 2)]                // source 0.5 s
    let url = try await TestClipWriter.write(spec)
    let id = UUID()
    let demuxer = try await AVDemuxer(url: url)
    let audio = try await AssetAudioSource.open(url: url, sampleRate: 48_000)
    let resolver = StaticMediaResolver(demuxers: [id: demuxer], audio: [id: audio])

    let src = TimeRange(start: Time(1, 3), duration: Time(2, 1))       // frame 10 ... 70
    let video = Clip(name: "v", media: id, kind: .video, source: src, start: .zero)
    let audioClip = Clip(name: "a", media: id, kind: .audio, source: src, start: .zero)
    let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "HELLO", style: TextStyle(size: 60, weight: .bold)),
                                        animations: nil)
    let textID = UUID()
    let text = Clip(name: "text", media: textID, kind: .video,
                    source: TimeRange(start: .zero, duration: Time(1, 1)), start: Time(1, 2), generator: ref)
    var tracks = [Track(kind: .video, clips: [video])]
    if withText { tracks.append(Track(kind: .video, clips: [text])) }
    tracks.append(Track(kind: .audio, clips: [audioClip]))
    let tl = Timeline(name: "t", format: SequenceFormat(width: 320, height: 180, frameDuration: fd), tracks: tracks)
    var f = Fixture(timeline: tl, resolver: resolver, textClip: text)
    _ = f.mediaID
    f = Fixture(timeline: tl, resolver: resolver, textClip: text)
    return f
}

/// VT delivers the native (often lossless-compressed) format, which FrameStamp cannot read: convert to BGRA first.
private func readStamp(_ src: CVPixelBuffer) -> Int? {
    if FrameStamp.supportedFormats.contains(CVPixelBufferGetPixelFormatType(src)) { return FrameStamp.read(src) }
    var dst: CVPixelBuffer?
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), kCVPixelFormatType_32BGRA, nil, &dst)
    var xfer: VTPixelTransferSession?
    guard let dst, VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &xfer) == noErr, let xfer,
          VTPixelTransferSessionTransferImage(xfer, from: src, to: dst) == noErr else { return nil }
    return FrameStamp.read(dst)
}

private func bgraRegionSum(_ pb: CVPixelBuffer, x: Range<Int>, y: Range<Int>) -> Int {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    var s = 0
    for yy in y { for xx in x { let p = base + yy * stride + xx * 4; s += Int(p[0]) + Int(p[1]) + Int(p[2]) } }
    return s
}

@Suite(.serialized) struct RealExportPipelineTests {
    @Test func decoderProviderDecodesSequentiallyWithoutReseeks() async throws {
        let f = try await makeFixture()
        let id = f.timeline.tracks[0].clips[0].media
        let provider = DecoderFrameProvider(resolver: f.resolver)
        for i in 0..<30 {
            let t = Time(10 + Int64(i), 30)
            let frame = try #require(try await provider.frame(media: id, at: t))
            #expect(readStamp(frame.buffer) == 10 + i)
        }
        let seq = await provider.reseeks
        #expect(seq <= 3)   // first request (+ at most a GOP start), never one per frame
        // Jump back: reseek, correct frame.
        let back = try #require(try await provider.frame(media: id, at: Time(3, 30)))
        #expect(readStamp(back.buffer) == 3)
        #expect(await provider.reseeks > seq)
        // Unknown media = offline.
        #expect(try await provider.frame(media: UUID(), at: .zero) == nil)
    }

    @Test func textLayerAppearsOnlyWhileTheClipIsActive() async throws {
        let withText = try await makeFixture(withText: true)
        let without = try await makeFixture(withText: false)
        func source(_ f: Fixture) throws -> TimelineFrameSource {
            try TimelineFrameSource(timeline: f.timeline, provider: DecoderFrameProvider(resolver: f.resolver),
                                    width: 320, height: 180, frameDuration: fd, frameCount: 60)
        }
        let a = try source(withText), b = try source(without)
        let centre = 100..<220, rows = 60..<120
        // Frame 5 (0.167 s): no text yet, identical to the text-free render.
        #expect(bgraRegionSum(try await a.frame(at: 5), x: centre, y: rows) == bgraRegionSum(try await b.frame(at: 5), x: centre, y: rows))
        // Frame 25 (0.83 s): text is on.
        #expect(bgraRegionSum(try await a.frame(at: 25), x: centre, y: rows) != bgraRegionSum(try await b.frame(at: 25), x: centre, y: rows))
        // Frame 50 (1.67 s): text is gone again.
        #expect(bgraRegionSum(try await a.frame(at: 50), x: centre, y: rows) == bgraRegionSum(try await b.frame(at: 50), x: centre, y: rows))
    }

    @Test func mixedAudioSourceIsSampleAccurateAndRewindable() async throws {
        let f = try await makeFixture()
        let audio = TimelineAudioSource(timeline: f.timeline, range: TimeRange(start: .zero, duration: Time(2, 1)),
                                        resolver: f.resolver)
        func peak() async throws -> (index: Int, total: Int) {
            var idx = 0, best: Float = 0, at = 0
            while let c = try await audio.nextChunk(maxFrames: 4000) {
                for i in 0..<c.frameCount where abs(c.samples[2 * i]) > best { best = abs(c.samples[2 * i]); at = idx + i }
                idx += c.frameCount
            }
            return (at, idx)
        }
        let first = try await peak()
        #expect(first.total == 96_000)
        // Click at source 0.5 s, clip source starts at 1/3 s -> timeline 1/6 s = frame 8000.
        #expect(first.index == 8000)
        try await audio.rewind()
        let second = try await peak()
        #expect(second.index == 8000 && second.total == 96_000)
    }

    @Test func exportWritesStampedVideoTextAndAudioTagged709() async throws {
        let f = try await makeFixture()
        var settings = ExportSettings()
        settings.video.width = 320; settings.video.height = 180
        settings.video.frameDuration = fd
        settings.video.bitrate = .average(4_000_000)
        settings.video.keyframeInterval = 30
        settings.audio.loudness = nil
        let provider = DecoderFrameProvider(resolver: f.resolver)
        let video = try TimelineFrameSource(timeline: f.timeline, provider: provider, width: 320, height: 180,
                                            frameDuration: fd, frameCount: 60)
        let audio = TimelineAudioSource(timeline: f.timeline, range: TimeRange(start: .zero, duration: Time(2, 1)),
                                        resolver: f.resolver)
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("out.mp4")
        let t0 = ContinuousClock.now
        try await ExportWriter.export(video: video, audio: audio, settings: settings, to: url, progress: { _ in })
        let elapsed = ContinuousClock.now - t0
        print("EXPORT-SPEED 60 frames 320x180 + audio: \(elapsed)")
        #expect(FileManager.default.fileExists(atPath: url.path))

        let asset = AVURLAsset(url: url)
        let vt = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let at = try await asset.loadTracks(withMediaType: .audio)
        #expect(at.count == 1)
        let fd0 = try #require(try await vt.load(.formatDescriptions).first)
        func ext(_ k: CFString) -> String? { CMFormatDescriptionGetExtension(fd0, extensionKey: k) as? String }
        #expect(ext(kCMFormatDescriptionExtension_ColorPrimaries) == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
        #expect(ext(kCMFormatDescriptionExtension_TransferFunction) == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
        #expect(ext(kCMFormatDescriptionExtension_YCbCrMatrix) == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String))

        // Frame stamps at the right times: output frame i (pts i/30) shows source frame i + 10.
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        #expect(reader.startReading())
        var stamps: [(pts: CMTime, stamp: Int?)] = []
        while let sb = out.copyNextSampleBuffer() {
            let pb = CMSampleBufferGetImageBuffer(sb)!
            stamps.append((CMSampleBufferGetPresentationTimeStamp(sb), FrameStamp.read(pb)))
        }
        #expect(stamps.count == 60)
        for (i, s) in stamps.sorted(by: { $0.pts < $1.pts }).enumerated() {
            #expect(s.pts == CMTime(value: Int64(i), timescale: 30), "pts of frame \(i)")
            #expect(s.stamp == 10 + i, "stamp at output frame \(i)")
        }

        // Audio: click near timeline frame 8000 (AAC smears it; allow a few ms).
        let areader = try AVAssetReader(asset: asset)
        let aout = AVAssetReaderTrackOutput(track: at[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])
        areader.add(aout)
        #expect(areader.startReading())
        var samples: [Float] = []
        while let sb = aout.copyNextSampleBuffer() {
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sb)!, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            ptr!.withMemoryRebound(to: Float.self, capacity: len / 4) { samples += Array(UnsafeBufferPointer(start: $0, count: len / 4)) }
        }
        let peakFrame = samples.enumerated().filter { $0.offset % 2 == 0 }.max { abs($0.element) < abs($1.element) }!.offset / 2
        #expect(abs(peakFrame - 8000) < 1500, "audio click at frame \(peakFrame)")
        #expect(samples.count / 2 >= 90_000)
    }
}

@Suite struct ExportSourceBuilderTests {
    @Test func frameCountRoundsUpAndHandlesRanges() {
        let r = TimeRange(start: .zero, duration: Time(2, 1))
        #expect(ExportSourceBuilder.frameCount(range: r, frameDuration: Time(1, 30)) == 60)
        #expect(ExportSourceBuilder.frameCount(range: TimeRange(start: .zero, duration: Time(1, 45)), frameDuration: Time(1, 30)) == 1)
        #expect(ExportSourceBuilder.frameCount(range: TimeRange(start: .zero, duration: .zero), frameDuration: Time(1, 30)) == 0)
        #expect(ExportSourceBuilder.frameCount(range: r, frameDuration: Time(1001, 30000)) == 60)   // 59.94 fps: 59.94 -> 60
    }

    @Test func builderProducesVideoAudioAndCues() async throws {
        let f = try await makeFixture()
        var s = ExportSettings()
        s.video.width = 320; s.video.height = 180; s.video.frameDuration = fd
        let src = try ExportSourceBuilder.make(timeline: f.timeline, sequences: [:], settings: s, resolver: f.resolver)
        #expect(src.video.frameCount == 60)
        #expect(src.audio != nil)
        s.audio.enabled = false
        #expect(try ExportSourceBuilder.make(timeline: f.timeline, sequences: [:], settings: s, resolver: f.resolver).audio == nil)
    }
}
