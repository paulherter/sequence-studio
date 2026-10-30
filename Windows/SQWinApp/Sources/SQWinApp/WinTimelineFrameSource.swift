import Foundation
import SQCore
import SQExport
import SQFrame
import SQGPUD3D12
import SQMediaFFmpeg
import SQPlayback
import SQRender
import SQText

/// Sequence frames for export on Windows (the Mac `TimelineFrameSource`): every video layer of the frame decoded through
/// FFmpeg, graded and composited by `WinCompositor` on the shared D3D12 device, read back as RGBA8 display code values
/// (BT.709) at the sequence size. Feed it to `FFmpegExportEncoder` (it takes `MemoryFrame` RGBA).
/// Frames render in order on `WinRenderActor` (off the main thread, its own D3D12 device) with their own decoders and
/// compositor, so playback state and the window are untouched.
/// The same layer coverage as the Program engine (clip effects, temporal filters, titles, shapes, Lottie); with
/// `captions` the visible caption tracks burn in as the Program monitor draws them (`CaptionLayerPlan`).
/// `width` / `height`: the output size (the Present pass resamples the sequence-sized composite, as the Mac source).
/// `linear` (image sequences, the Mac rgbaHalf source with a transparent background): rgba16f frames of the linear
/// composite instead, empty areas clear, stretched to the output size like the Mac `encodeRGBAHalf`.
/// Not segmentable: `FFmpegExportEncoder` writes one piece, so parallel segments would gain nothing on Windows yet.
@WinRenderActor
final class WinTimelineFrameSource: FrameSource {
    /// What a source needs from the session, read on the main actor (`AppController.frameInput`).
    struct Input: Sendable {
        var timeline: Timeline
        var sequences: [Timeline.ID: Timeline]
        var range: TimeRange?
        var media: [MediaRef]
        var width: Int?, height: Int?
        var captions = false, linear = false
    }

    /// A source on the render actor's device (made there; the first one also makes the device).
    static func make(_ i: Input) throws -> WinTimelineFrameSource {
        try WinTimelineFrameSource(timeline: i.timeline, sequences: i.sequences, range: i.range, media: i.media,
                                   device: WinRenderDevice.get(), width: i.width, height: i.height,
                                   captions: i.captions, linear: i.linear)
    }

    nonisolated let frameCount: Int
    nonisolated let frameDuration: Time
    private let timeline: Timeline
    private let sequences: [Timeline.ID: Timeline]
    private let start: Time
    private let paths: [UUID: String]
    private let compositor: WinCompositor
    private let colorResolver: LayerColorResolver
    private var sources: [UUID: WinMediaSource] = [:]
    private var cache: [UUID: [Int: NV12Picture]] = [:]
    private let outputSize: (width: Int, height: Int)
    private let captionLibrary: CaptionPresetLibrary?
    private let linear: Bool
    private static let readAhead = 8
    /// The next frame, already submitted with its readback (`WinCompositor.lastReadback`): the GPU draws it while the
    /// encoder takes the frame before it (two frames in flight).
    private var pending: (index: Int, picture: NV12Picture, readback: D3D12GPUDevice.Readback)?

    /// `range` nil exports the whole sequence. `media`: the project's media (paths and infos for the grades). `width` /
    /// `height` nil: the sequence size.
    init(timeline: Timeline, sequences: [Timeline.ID: Timeline], range: TimeRange? = nil, media: [MediaRef],
         device: D3D12GPUDevice, width: Int? = nil, height: Int? = nil, captions: Bool = false, linear: Bool = false) throws {
        self.timeline = timeline
        self.linear = linear
        captionLibrary = captions && !timeline.captionTracks.isEmpty ? CaptionLookRegistry.shared.library : nil
        outputSize = (max(1, width ?? timeline.format.width), max(1, height ?? timeline.format.height))
        self.sequences = sequences
        let fd = timeline.frameDuration
        let r = range ?? TimeRange(start: .zero, duration: timeline.duration)
        start = r.start.snapped(to: fd)
        frameDuration = fd
        frameCount = max(0, Int((r.end - start).frameIndex(frameDuration: fd)))
        paths = Dictionary(media.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        let infos = MediaInfoTable()
        infos.set(Dictionary(media.map { ($0.id, $0.info) }, uniquingKeysWith: { a, _ in a }))
        colorResolver = WinMediaSource.colorResolver(infos)
        compositor = try WinCompositor(device: device)
        compositor.clipDurations = WinCompositor.clipDurations(of: timeline, sequences: sequences)
    }

    nonisolated func frame(at index: Int) async throws -> ExportFrame {
        try await render(index)
    }

    /// The sequence frame `index` (from the range start) as RGBA8 bytes. Frames asked in order are pipelined: frame
    /// `index + 1` is recorded and submitted before frame `index` is read back.
    func rgba(at index: Int) async throws -> NV12Picture {
        if linear { return try await submit(index) }
        var current: (picture: NV12Picture, readback: D3D12GPUDevice.Readback?)
        if let p = pending, p.index == index { current = (p.picture, p.readback) } else {
            let p = try await submit(index, readback: true)
            current = (p, compositor.lastReadback)
        }
        pending = nil
        if index + 1 < frameCount {
            let next = try await submit(index + 1, readback: true)
            if let r = compositor.lastReadback { pending = (index + 1, next, r) }
        }
        guard let r = current.readback else { return compositor.download(current.picture) }
        var out = current.picture
        out.bytes = r.finish()
        out.texture = nil
        guard !out.bytes.isEmpty else { throw AppError("export: frame \(index) did not read back") }
        return out
    }

    /// Records and submits frame `index` (no wait); `readback` also records its bytes' readback.
    private func submit(_ index: Int, readback: Bool = false) async throws -> NV12Picture {
        guard index >= 0, index < frameCount else { throw FrameSourceError.indexOutOfRange(index) }
        let t = start + frameDuration * Int64(index)
        let seqs = sequences
        let requests = timeline.videoLayers(at: t, sequences: { seqs[$0] })
        var pictures: [UUID: (index: Int, picture: NV12Picture)] = [:]
        for l in requests where l.generator == nil {
            guard pictures[l.media] == nil, let src = try source(l.media) else { continue }
            let i = src.frameIndex(at: l.sourceTime)
            pictures[l.media] = (i, try await picture(src, l.media, i))
        }
        let captions = captionLibrary.map { lib in
            CaptionLayerPlan.layers(timeline, slots: timeline.captionSlots(at: t), at: t, library: lib) {
                TextGenerator.portableUnits(ref: $0)
            }
        } ?? []
        let resolver = colorResolver
        return try compositor.render(requests, format: timeline.format, outputSize: outputSize, transparent: linear,
                                      readback: readback, captions: captions, grade: { l in
            resolver.pipelineBlocking(for: l.color, media: l.media, owner: l.clip)
        }) { [self] l in
            guard l.generator == nil, let s = sources[l.media], let pic = pictures[l.media] else { return nil }
            return WinCompositor.Source(media: l.media, index: pic.index, picture: pic.picture, info: s.info)
        }
    }

    private func render(_ index: Int) async throws -> SQFrame {
        let p = try await rgba(at: index)
        if linear {
            guard let l = compositor.downloadLinear(size: outputSize) else { throw AppError("export: frame \(index) did not read back") }
            return SQFrame(width: l.width, height: l.height, pixelFormat: .rgba16f, colorSpace: .rec709,
                           presentationTime: frameDuration * Int64(index),
                           storage: MemoryFrame(bytes: l.bytes, bytesPerRow: l.width * 8))
        }
        return SQFrame(width: p.width, height: p.height, pixelFormat: .rgba8, colorSpace: .rec709,
                       presentationTime: frameDuration * Int64(index),
                       storage: MemoryFrame(bytes: p.bytes, bytesPerRow: p.width * 4))
    }

    /// The decoded picture `i` of `media`: frames of one media come in order, so it decodes a few ahead and drops older ones.
    private func picture(_ src: WinMediaSource, _ media: UUID, _ i: Int) async throws -> NV12Picture {
        if let p = cache[media]?[i] { return p }
        let last = min(src.frameCount - 1, i + Self.readAhead)
        let decoded = try await WinMediaSource.decodePictures(src.decoder, i...max(i, last))
        var c = (cache[media] ?? [:]).filter { $0.key >= i }
        for (k, p) in decoded { c[k] = p }
        cache[media] = c
        guard let p = c[i] else { throw AppError("export: frame \(i) of media \(media) did not decode") }
        return p
    }

    /// nil for offline media (drawn as the offline placeholder).
    private func source(_ media: UUID) throws -> WinMediaSource? {
        if let s = sources[media] { return s }
        guard let path = paths[media], FileManager.default.fileExists(atPath: path) else { return nil }
        let s = try WinMediaSource(path: path, media: media)
        sources[media] = s
        return s
    }
}
