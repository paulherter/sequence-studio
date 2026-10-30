import Testing
import Foundation
import CoreVideo
import Synchronization
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
@testable import SQExport

// Hidden layers (SQCore `LayerOcclusion`): a media layer under an opaque full-canvas picture is not decoded or drawn, and
// the exported picture is the same.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

/// Opaque 8-bit 4:2:0 video frames: luma depends on the media and the source frame, so a wrong or missing layer shows.
private final class VideoProvider: FrameProvider, Sendable {
    let level: [UUID: Int]
    /// Media that stop decoding from this source frame on (the provider answers nil: drawn as the offline placeholder).
    let offlineFrom: [UUID: Int64]
    /// Source frames that fail to decode (the provider throws `FrameDecodeError`).
    let damaged: [UUID: Set<Int64>]
    let calls = Mutex<[UUID: Int]>([:])
    init(_ level: [UUID: Int], offlineFrom: [UUID: Int64] = [:], damaged: [UUID: Set<Int64>] = [:]) {
        self.level = level; self.offlineFrom = offlineFrom; self.damaged = damaged
    }

    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        calls.withLock { $0[media, default: 0] += 1 }
        guard let base = level[media] else { return nil }
        let n = sourceTime.value * Int64(fd.timescale) / (Int64(sourceTime.timescale) * fd.value)
        if let o = offlineFrom[media], n >= o { return nil }
        if damaged[media]?.contains(n) == true { throw FrameDecodeError(media: media, sourceTime: sourceTime, reason: "test") }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        for plane in 0..<2 {
            let p = CVPixelBufferGetBaseAddressOfPlane(buf, plane)!.assumingMemoryBound(to: UInt8.self)
            let count = CVPixelBufferGetBytesPerRowOfPlane(buf, plane) * CVPixelBufferGetHeightOfPlane(buf, plane)
            for i in 0..<count { p[i] = plane == 0 ? UInt8(min(235, base + Int(n) * 6)) : 128 }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let info = VideoTrackInfo(width: 64, height: 32, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: fd, isVariableFrameRate: false)
        return ProvidedFrame(buffer: buf, info: info, start: f(n), duration: fd)
    }
}

private func bytes(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(pb), w = CVPixelBufferGetWidth(pb) * 4
    return (0..<CVPixelBufferGetHeight(pb)).flatMap { y in Array(UnsafeBufferPointer(start: base + y * stride, count: w)) }
}

@Suite struct HiddenLayerExportTests {
    private let a = UUID(), b = UUID()

    /// A on V1 for 8 frames; B on V2 over frames 2..<5, full canvas.
    private func timeline(coverOpacity: Double = 1, interpolation: TimeInterpolation = .frameSampling) -> Timeline {
        let lower = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(8)), start: .zero)
        var upper = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: .zero, duration: f(3)), start: f(2))
        upper.animation.opacity = AnimatedProperty(coverOpacity)
        upper.timeInterpolation = interpolation
        return Timeline(name: "cover", format: SequenceFormat(width: 64, height: 32, frameDuration: fd),
                        tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])])
    }

    private func render(_ tl: Timeline, provider: VideoProvider, cull: Bool, continueOnDamaged: Bool = false) async throws -> [[UInt8]] {
        let src = try TimelineFrameSource(timeline: tl, provider: provider, width: 64, height: 32, frameDuration: fd,
                                          frameCount: 8, continueOnDamagedFrames: continueOnDamaged, cullHidden: cull)
        var out: [[UInt8]] = []
        for i in 0..<8 { out.append(bytes(try await src.frame(at: i))) }
        return out
    }

    private func damagedCount(_ tl: Timeline, provider: VideoProvider, cull: Bool) async throws -> Int {
        let src = try TimelineFrameSource(timeline: tl, provider: provider, width: 64, height: 32, frameDuration: fd,
                                          frameCount: 8, continueOnDamagedFrames: true, cullHidden: cull)
        for i in 0..<8 { _ = try await src.frame(at: i) }
        return await src.damagedLayers()
    }

    @Test func aCoveredLayerIsNotDecodedAndThePictureIsTheSame() async throws {
        let all = VideoProvider([a: 40, b: 150]), culled = VideoProvider([a: 40, b: 150])
        let reference = try await render(timeline(), provider: all, cull: false)
        let output = try await render(timeline(), provider: culled, cull: true)
        #expect(output == reference)
        #expect(reference[1] != reference[3])          // the cover really shows
        #expect(all.calls.withLock { $0[a] } == 8)
        // B's first frame (2) is drawn with A below it (B is not known to be opaque before its first frame); 3 and 4 are not.
        #expect(culled.calls.withLock { $0[a] } == 6)
        let src = try TimelineFrameSource(timeline: timeline(), provider: VideoProvider([a: 40, b: 150]), width: 64, height: 32,
                                          frameDuration: fd, frameCount: 8)
        for i in 0..<8 { _ = try await src.frame(at: i) }
        #expect(await src.stageProfile().hiddenLayers == 2)
    }

    @Test func aTransparentCoverHidesNothing() async throws {
        let p = VideoProvider([a: 40, b: 150]), q = VideoProvider([a: 40, b: 150])
        let reference = try await render(timeline(coverOpacity: 0.5), provider: q, cull: false)
        #expect(try await render(timeline(coverOpacity: 0.5), provider: p, cull: true) == reference)
        #expect(p.calls.withLock { $0[a] } == 8)
    }

    /// The cover goes offline on its third frame: its placeholder must not hide the layer below.
    @Test func aCoverThatDoesNotDecodeHidesNothing() async throws {
        let p = VideoProvider([a: 40, b: 150], offlineFrom: [b: 2]), q = VideoProvider([a: 40, b: 150], offlineFrom: [b: 2])
        let reference = try await render(timeline(), provider: q, cull: false)
        #expect(try await render(timeline(), provider: p, cull: true) == reference)
        #expect(p.calls.withLock { $0[a] } == 7)       // only frame 3 hid A
    }

    /// A cover with Frame Blending (or Optical Flow) needs a second frame and can end up as a placeholder: it never covers.
    @Test func aFrameBlendedCoverHidesNothing() async throws {
        let tl = timeline(interpolation: .frameBlend)
        let p = VideoProvider([a: 40, b: 150]), q = VideoProvider([a: 40, b: 150])
        let reference = try await render(tl, provider: q, cull: false)
        #expect(try await render(tl, provider: p, cull: true) == reference)
        #expect(p.calls.withLock { $0[a] } == 8)
    }

    /// The cover's frame is damaged on its third frame ("continue on damaged frames"): its layer is the damaged
    /// placeholder, not a picture, so the layer below is drawn for that frame.
    @Test func aDamagedCoverHidesNothing() async throws {
        let p = VideoProvider([a: 40, b: 150], damaged: [b: [2]]), q = VideoProvider([a: 40, b: 150], damaged: [b: [2]])
        let reference = try await render(timeline(), provider: q, cull: false, continueOnDamaged: true)
        #expect(try await render(timeline(), provider: p, cull: true, continueOnDamaged: true) == reference)
        #expect(p.calls.withLock { $0[a] } == 7)       // only frame 3 hid A
        #expect(try await damagedCount(timeline(), provider: VideoProvider([a: 40, b: 150], damaged: [b: [2]]), cull: true) == 1)
        // Without "continue on damaged frames" the cover's damaged frame stops the export as before.
        await #expect(throws: ExportDecodeError.self) {
            _ = try await render(timeline(), provider: VideoProvider([a: 40, b: 150], damaged: [b: [2]]), cull: true)
        }
    }

    /// A damaged frame of a hidden clip contributes no pixel: it neither stops the export nor counts as damaged
    /// (DECISIONS 2026-10-06). A's source frames 3 and 4 lie under B.
    @Test func aDamagedHiddenFrameDoesNotStopTheExport() async throws {
        func provider() -> VideoProvider { VideoProvider([a: 40, b: 150], damaged: [a: [3, 4]]) }
        // Everything drawn: the export stops at the damaged frame.
        await #expect(throws: ExportDecodeError.self) { _ = try await render(timeline(), provider: provider(), cull: false) }
        // Hidden layers left out: it goes through, with the picture the placeholder under the cover would have given.
        let output = try await render(timeline(), provider: provider(), cull: true)
        #expect(output == (try await render(timeline(), provider: provider(), cull: false, continueOnDamaged: true)))
        #expect(try await damagedCount(timeline(), provider: provider(), cull: true) == 0)
        #expect(try await damagedCount(timeline(), provider: provider(), cull: false) == 2)
    }
}

/// Real decoders: a layer hidden for seconds (its decoder stands still across many sync samples) shows the right frame
/// on the first frame it is visible again.
@Suite(.serialized) struct HiddenLayerDecoderTests {
    @Test func aLayerHiddenAcrossManyGOPsComesBackOnTheRightFrame() async throws {
        var spec = TestClipSpec(); spec.frameCount = 150          // 5 s, a sync sample every 12 frames
        let a = UUID(), b = UUID()
        let urls = [try await TestClipWriter.write(spec), try await TestClipWriter.write(spec)]
        defer { for u in urls { try? FileManager.default.removeItem(at: u) } }
        // A for 150 frames; B (same size as the canvas) over frames 20..<125, starting at its source frame 30.
        let lower = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(150)), start: .zero)
        let upper = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: f(30), duration: f(105)), start: f(20))
        let tl = Timeline(name: "long", format: SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])])
        func render(cull: Bool) async throws -> (frames: [[UInt8]], hidden: Int) {
            let resolver = StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: urls[0]), b: try await AVDemuxer(url: urls[1])], audio: [:])
            let src = try TimelineFrameSource(timeline: tl, provider: DecoderFrameProvider(resolver: resolver), width: spec.width,
                                              height: spec.height, frameDuration: fd, frameCount: 150, cullHidden: cull)
            var out: [[UInt8]] = []
            for i in 0..<150 { out.append(bytes(try await src.frame(at: i))) }
            return (out, await src.stageProfile().hiddenLayers)
        }
        let reference = try await render(cull: false), output = try await render(cull: true)
        #expect(reference.hidden == 0)
        #expect(output.hidden == 104)                 // B's first frame still draws A
        for i in 0..<150 where output.frames[i] != reference.frames[i] { Issue.record("frame \(i) differs"); break }
        #expect(reference.frames[124] != reference.frames[125])      // A really comes back at 125
        #expect(reference.frames[19] != reference.frames[20])
    }
}
