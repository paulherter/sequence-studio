import CoreVideo
import Foundation
import Metal
import Synchronization
import SQAnalysis
import SQCore
import SQLottie
import SQRender
import SQText

/// A decoded source frame plus what the compositor needs to interpret it.
public struct ProvidedFrame: @unchecked Sendable {
    public var buffer: CVPixelBuffer
    public var info: VideoTrackInfo
    /// Presentation start and duration of this source frame in the media (nil = unknown: no Frame Blending).
    public var start: Time?
    public var duration: Time?
    /// Position of the frame in the media's sample index (0 for a still): keys subject-matte smoothing like playback
    /// (`RenderLoop.frameIndex`). nil = unknown: derived from `start` and `duration` (exact for constant frame rate only).
    public var sampleIndex: Int?
    public init(buffer: CVPixelBuffer, info: VideoTrackInfo, start: Time? = nil, duration: Time? = nil, sampleIndex: Int? = nil) {
        self.buffer = buffer; self.info = info; self.start = start; self.duration = duration; self.sampleIndex = sampleIndex
    }
}

/// Decoded-frame supply for export (the real decoder plugs in with E-03/E-09). Returns nil when the media is
/// offline; the layer is then drawn as the offline placeholder.
public protocol FrameProvider: Sendable {
    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame?
    /// The export has moved past these media (no later frame of this source draws them): free their decoders and frames.
    func release(media: Set<UUID>) async
    /// The export will soon ask for this frame (a clip start ahead): decode it in the background. Returns at once.
    func prefetch(media: UUID, at sourceTime: Time) async
}

public extension FrameProvider {
    func release(media: Set<UUID>) async {}
    func prefetch(media: UUID, at sourceTime: Time) async {}
}

/// Carries CoreVideo references across an isolation boundary (they are thread-safe, just not annotated).
struct Box<T>: @unchecked Sendable {
    let buffer: T
    init(_ b: T) { buffer = b }
}

/// Plane textures of a frame in flight together with the cache they came from; `drop` (on Metal's completion queue,
/// once) releases the textures while the cache is still held.
final class TextureHold: @unchecked Sendable {
    private var textures: [CVMetalTexture]
    private let cache: CVMetalTextureCache
    init(textures: [CVMetalTexture], cache: CVMetalTextureCache) { self.textures = textures; self.cache = cache }
    func drop() { withExtendedLifetime(cache) { textures.removeAll() } }
}

/// Summed time per stage of `TimelineFrameSource` renders: fetch (timeline query + stacked decodes), layers (layer build,
/// remaining decodes, text, grade lookup), encode (CPU command encoding), wait (commit to completion), gpu (GPU busy).
public struct RenderStageProfile: Sendable {
    public var frames = 0
    public var fetch = Duration.zero, layers = Duration.zero, encode = Duration.zero, wait = Duration.zero, gpu = Duration.zero
    /// Parts of `layers`: waiting for decodes the fetch did not do (one media per frame: all of them), and building text
    /// layers (titles / captions rasterized on the CPU).
    public var layerDecode = Duration.zero, layerText = Duration.zero
    /// The part of `layerText` spent on text whose still raster was not cached yet (first frame of a clip), and how often.
    public var layerTextCold = Duration.zero, textColdLayers = 0
    /// Compositor intermediates and working textures allocated so far (the pools reuse them).
    public var intermediateAllocations = 0, workingTextures = 0
    /// Media layers left out because an opaque full-canvas picture lies over them (`LayerOcclusion`): not decoded or drawn.
    public var hiddenLayers = 0
    public init() {}
}

/// Completion of a committed command buffer that can be awaited later (or already be done).
final class GPUCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: (any Error)??
    private var waiter: CheckedContinuation<Void, any Error>?

    func finish(_ error: (any Error)?) {
        lock.lock()
        result = .some(error)
        let w = waiter; waiter = nil
        lock.unlock()
        if let w { if let error { w.resume(throwing: error) } else { w.resume() } }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if let r = result {
                lock.unlock()
                if let e = r { c.resume(throwing: e) } else { c.resume() }
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }
}

public enum TimelineFrameSourceError: Error, Sendable, Equatable {
    case noMetalDevice, invalidSize, oddDimensionsFor420, commandBufferFailed(String), bufferCreationFailed(Int32)
}

/// Renders timeline frames for export: `Timeline.videoLayers(at:)` -> decoded frames -> `Compositor`
/// (working-linear rgba16Float) -> optional caption burn-in -> BT.709 OETF output pass -> `ExportPixelFormat` buffer
/// tagged 1-1-1. One command buffer per frame; output buffers come from a pool.
public final class TimelineFrameSource: SegmentableFrameSource {
    public let frameCount: Int
    public let frameDuration: Time
    public let startTime: Time
    public let width: Int, height: Int
    public let pixelFormat: ExportPixelFormat
    private let renderer: Renderer
    /// Everything needed to build an independent renderer for a segment (own compositor, own decoders).
    private let rebuild: @Sendable (_ start: Time, _ count: Int) throws -> TimelineFrameSource
    public let isSegmentable: Bool
    /// Render ahead: once frame N's GPU work is committed, frame N+1's CPU work (decodes, layers, encoding) starts while
    /// N is still on the GPU and the caller encodes it. At most one frame ahead; same work in the same order, so the
    /// pixels are those of a plain sequential render.
    private let renderAhead: Bool
    private let ahead = Mutex<Ahead>(Ahead())
    private struct Ahead {
        /// The next frame, submitted ahead (CPU work done, GPU work committed) or still being submitted.
        var pending: (index: Int, task: Task<Renderer.Submitted, any Error>)?
    }

    deinit { ahead.withLock { $0.pending?.task.cancel() } }

    /// - Parameters:
    ///   - width/height: output size (the working frame is sequence-sized and resampled if they differ).
    ///   - startTime: timeline time of frame 0 (range start).
    ///   - layerConcurrency: media of one output frame decoded at once (stacked layers); 1 = one after the other.
    ///   - renderAhead: after a frame is submitted, submit the next one too (decode + GPU overlap the caller's encode);
    ///     byte-identical output, one extra frame of GPU memory. Off on 8 GB Macs (`WorkLimits.exportRenderAhead`).
    ///   - clipPrefetch: hand clip starts `clipPrefetchLead` ahead to `provider.prefetch` (decoded on their own decoder
    ///     lane while the render goes on); same frames, so byte-identical output.
    ///   - cullHidden: leave out media layers that lie under an opaque full-canvas picture (`LayerOcclusion`): they are not
    ///     decoded or drawn; same picture.
    public init(timeline: Timeline, sequences: [Timeline.ID: Timeline] = [:], provider: any FrameProvider, width: Int, height: Int,
                frameDuration: Time, frameCount: Int, startTime: Time = .zero,
                pixelFormat: ExportPixelFormat = .bgra8, captions: CaptionBurnIn? = nil,
                colorResolver: LayerColorResolver? = nil, gyroWarper: GyroFrameWarper? = nil,
                continueOnDamagedFrames: Bool = false,
                device: MTLDevice? = MTLCreateSystemDefaultDevice(),
                makeProvider: (@Sendable () -> any FrameProvider)? = nil,
                layerConcurrency: Int = WorkLimits.current.layerDecodes,
                renderAhead: Bool = WorkLimits.current.exportRenderAhead,
                subjectMattes: ExportSubjectMattes? = nil,
                clipPrefetch: Bool = TimelineFrameSource.clipPrefetchDefault,
                cullHidden: Bool = TimelineFrameSource.cullHiddenDefault,
                hdrToSDR: HDRToSDR? = nil,
                hdrOutput: HDRDelivery.Transfer? = nil) throws {
        TextGenerator.installFollowMeasure()   // G11: Follow measures text targets during evaluation
        guard let device, let queue = device.makeCommandQueue() else { throw TimelineFrameSourceError.noMetalDevice }
        guard width > 0, height > 0, timeline.format.width > 0, timeline.format.height > 0 else {
            throw TimelineFrameSourceError.invalidSize
        }
        if pixelFormat.needsEvenSize, width % 2 != 0 || height % 2 != 0 { throw TimelineFrameSourceError.oddDimensionsFor420 }
        self.frameCount = frameCount; self.frameDuration = frameDuration; self.startTime = startTime
        self.width = width; self.height = height; self.pixelFormat = pixelFormat
        renderer = try Renderer(timeline: timeline, sequences: sequences, provider: provider, width: width, height: height,
                                format: pixelFormat, captions: captions, colorResolver: colorResolver, gyroWarper: gyroWarper,
                                continueOnDamaged: continueOnDamagedFrames, layerConcurrency: layerConcurrency,
                                subjectMattes: subjectMattes, device: device, queue: queue, cullsHidden: cullHidden, hdrToSDR: hdrToSDR, hdrOutput: hdrOutput,
                                prefetch: clipPrefetch ? ClipPrefetchScanner(start: startTime, frameDuration: frameDuration,
                                                                             frameCount: frameCount,
                                                                             leadFrames: Self.leadFrames(frameDuration)) : nil)
        isSegmentable = makeProvider != nil
        self.renderAhead = renderAhead
        let dev = Box(device)
        rebuild = { start, count in
            try TimelineFrameSource(timeline: timeline, sequences: sequences, provider: makeProvider?() ?? provider,
                                    width: width, height: height, frameDuration: frameDuration, frameCount: count,
                                    startTime: start, pixelFormat: pixelFormat, captions: captions,
                                    colorResolver: colorResolver, gyroWarper: gyroWarper,
                                    continueOnDamagedFrames: continueOnDamagedFrames, device: dev.buffer, makeProvider: makeProvider, layerConcurrency: layerConcurrency,
                                    renderAhead: renderAhead, subjectMattes: subjectMattes, clipPrefetch: clipPrefetch,
                                    cullHidden: cullHidden, hdrToSDR: hdrToSDR, hdrOutput: hdrOutput)
        }
    }

    public func frame(at index: Int) async throws -> CVPixelBuffer {
        guard index >= 0, index < frameCount else { throw FrameSourceError.indexOutOfRange(index) }
        try Task.checkCancellation()
        guard renderAhead else { return try await renderer.render(at: time(index)).buffer }
        let pending = ahead.withLock { a in defer { a.pending = nil }; return a.pending }
        var submitted: Renderer.Submitted?
        if let pending, pending.index == index {
            submitted = try await withTaskCancellationHandler { try await pending.task.value } onCancel: { pending.task.cancel() }
        } else if let pending {
            // A jump: the frame submitted ahead is not wanted. It finishes (renders never overlap) and is dropped.
            pending.task.cancel()
            if let s = try? await pending.task.value { _ = try? await renderer.complete(s) }
        }
        let s: Renderer.Submitted
        if let submitted { s = submitted } else { s = try await renderer.submit(at: time(index)) }
        // Frame N is on the GPU: frame N+1's CPU work starts now.
        if index + 1 < frameCount, !Task.isCancelled {
            let renderer = self.renderer, t = time(index + 1)
            ahead.withLock { $0.pending = (index + 1, Task { try await renderer.submit(at: t) }) }
        }
        return try await withTaskCancellationHandler {
            try await renderer.complete(s).buffer
        } onCancel: {
            ahead.withLock { $0.pending?.task.cancel() }
        }
    }

    private func time(_ index: Int) -> Time { startTime + frameDuration * Int64(index) }

    /// Frames `range` as an independent source: its own compositor, command queue and (with `makeProvider`) decoders,
    /// so segments render and decode in parallel. Sharing one provider would make its decoders seek back and forth.
    public func segment(_ range: Range<Int>) throws -> any FrameSource {
        guard range.lowerBound >= 0, range.upperBound <= frameCount, !range.isEmpty else {
            throw FrameSourceError.indexOutOfRange(range.lowerBound)
        }
        return try rebuild(startTime + frameDuration * Int64(range.lowerBound), range.count)
    }

    /// W9.8: Vision runs for subject masks so far, their frame indices in order, clips with tracker state (tests).
    func subjectSegmentations() async -> Int { await renderer.subjectIndices.count }
    func subjectFrameIndices() async -> [Int] { await renderer.subjectIndices }
    func subjectKeys() async -> Set<UUID> { renderer.subject.keys }
    /// Media released to the provider so far, and layers drawn with the damaged placeholder (tests).
    func releasedMedia() async -> Set<UUID> { await renderer.released }
    /// Time spent per render stage so far (bench, docs/PLAYBACK-PERF.md "Export compositing").
    public func stageProfile() async -> RenderStageProfile { await renderer.currentProfile() }
    func damagedLayers() async -> Int { await renderer.damaged }
    /// Returns once the text rasters handed to the background queue so far are rendered (tests).
    func waitForTextPrewarm() async { await renderer.waitForTextPrewarm() }

    /// Per media, the end of its last use in `timeline`: the clip's end, or for media inside a nested sequence the end of
    /// the outermost nested clip. Export moves forward, so past that time (and not drawn in the current frame, which
    /// covers transition handles) the media is never needed again.
    static func mediaEnds(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) -> [UUID: Time] {
        var out: [UUID: Time] = [:]
        func visit(_ tl: Timeline, end: Time?, visiting: Set<Timeline.ID>) {
            for track in tl.tracks where track.kind == .video {
                for c in track.clips {
                    let e = end ?? c.timeline.end
                    if let s = c.sequence {
                        // An Angles piece only draws its active angle: the other angles' media are not kept for it.
                        if !visiting.contains(s), let inner = sequences[s] {
                            visit(c.angleView(of: inner), end: e, visiting: visiting.union([s]))
                        }
                    } else if c.generator == nil {
                        out[c.media] = max(out[c.media] ?? e, e)
                    }
                }
            }
        }
        visit(timeline, end: nil, visiting: [timeline.id])
        return out
    }

    /// A text raster's clip on the output timeline (nested text: the outer clip's span).
    struct TextSpan: Sendable, Equatable {
        var range: TimeRange
        var ref: GeneratorRef
    }

    /// Text generator and graphics text layers, one span per clip, earliest start first (PLAYBACK-PERF "Export layers").
    static func textSpans(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) -> [TextSpan] {
        var out: [TextSpan] = []
        func visit(_ tl: Timeline, outer: TimeRange?, visiting: Set<Timeline.ID>) {
            for track in tl.tracks where track.kind == .video {
                for c in track.clips {
                    let r = outer ?? c.timeline
                    if let s = c.sequence {
                        if !visiting.contains(s), let inner = sequences[s] {
                            visit(c.angleView(of: inner), outer: r, visiting: visiting.union([s]))   // only the shown angle
                        }
                        continue
                    }
                    if let g = c.generator, g.kind == GeneratorRef.text { out.append(TextSpan(range: r, ref: g)) }
                    guard let doc = c.graphics else { continue }
                    for l in doc.layers {
                        guard case .text(let g) = l.content else { continue }
                        // Item lanes: an item with a range warms for its own span, and one that never shows not at all.
                        let d = c.timeline.duration
                        let shown = doc.shownRange(of: l, clipDuration: d)
                        let a = min(max(shown.start, .zero), d), b = min(max(shown.end, .zero), d)
                        if b <= a { continue }
                        let own = TimeRange(start: c.timeline.start + a, end: c.timeline.start + b)
                        out.append(TextSpan(range: outer ?? own, ref: g))
                    }
                }
            }
        }
        visit(timeline, outer: nil, visiting: [timeline.id])
        // Stable: equal starts keep track order.
        return out.enumerated().sorted { ($0.element.range.start, $0.offset) < ($1.element.range.start, $1.offset) }.map(\.element)
    }

    /// Frames run through the smoother before the first output frame of a clip that starts earlier (a parallel segment
    /// or a range export starting inside the clip), so the matte is as settled as in one continuous render.
    static let subjectWarmupFrames = 6

    /// How far ahead of the render position text rasters are warmed (export renders faster than real time, so a few
    /// seconds of output are well under a second of wall time; the raster cache holds 128 MB).
    static let textPrewarmLead = Time(3, 1)

    /// How far ahead of the render position clip starts are handed to the provider's prefetch: a seek on Sony long-GOP
    /// 4K takes up to ~0.3 s of decoding, and export runs at ~2-3x real time, so 1 s of output is ~0.3-0.5 s of wall time.
    static let clipPrefetchLead = Time(1, 1)

    /// `SQ_EXPORT_CLIP_PREFETCH=0` turns clip prefetch off (A/B bench only).
    public static var clipPrefetchDefault: Bool { ProcessInfo.processInfo.environment["SQ_EXPORT_CLIP_PREFETCH"] != "0" }
    /// `SQ_EXPORT_CULL=0` draws hidden layers too (A/B bench only).
    public static var cullHiddenDefault: Bool { ProcessInfo.processInfo.environment["SQ_EXPORT_CULL"] != "0" }

    static func leadFrames(_ fd: Time) -> Int {
        guard fd > .zero else { return 0 }
        return Int((clipPrefetchLead.value * fd.timescale + fd.value * clipPrefetchLead.timescale - 1) / (fd.value * clipPrefetchLead.timescale))
    }

    // MARK: Renderer (serializes compositor use)

    private actor Renderer {
        let timeline: Timeline
        let sequences: [Timeline.ID: Timeline]
        let clipDurations: [Clip.ID: Time]
        let provider: any FrameProvider
        let width: Int, height: Int
        let format: ExportPixelFormat
        let captions: CaptionBurnIn?
        let colorResolver: LayerColorResolver?
        /// Export HDR to SDR trim, applied to every HDR layer's tone map (nil = the clip's own).
        let hdrToSDR: HDRToSDR?
        /// HDR delivery (HLG / PQ): HDR layers keep their highlights above SDR white and the output stage encodes them.
        let hdrOutput: HDRDelivery.Transfer?
        /// Gyroflow Stabilizer warps (the same engine call as playback; export waits for the analysis).
        let gyroWarper: GyroFrameWarper?
        let continueOnDamaged: Bool
        /// Media of one output frame decoded at once (1 = serial).
        let layerConcurrency: Int
        let clipNames: [Clip.ID: String]
        let mediaEnds: [UUID: Time]
        /// Media handed to `provider.release` (never drawn again by this source).
        var released: Set<UUID> = []
        /// Layers drawn as the damaged placeholder (continue on damaged frames).
        var damaged = 0
        /// Upright size of every media whose decoded frames are opaque video (learned from the frames themselves): what
        /// `LayerOcclusion` may take as a cover. A media not decoded yet is unknown and covers nothing.
        var opaquePictures: [UUID: LayerOcclusion.Picture] = [:]
        /// Leave out layers hidden under an opaque full-canvas picture.
        let cullsHidden: Bool
        let device: MTLDevice
        let queue: MTLCommandQueue
        let compositor: Compositor
        let cache: CVMetalTextureCache
        let pool: CVPixelBufferPool
        /// Output passes for `format`: (kernel, plane, plane texture format).
        let passes: [(MTLComputePipelineState, Int, MTLPixelFormat)]
        var freeWorking: [MTLTexture] = []
        /// W9.8 subject masks: person mattes at the accurate quality, smoothed in frame order (one per renderer, so
        /// parallel segments never share a smoother). Export only moves forward: the smoother keeps 2 results per clip
        /// (accurate mattes are large), and a clip's state is released once export has moved past it.
        nonisolated let subject = SubjectMatteTracker(capacity: 2)
        /// Tracker keys (clip and decoded source, as playback's `SubjectMatteScheduler.Key`) segmented by this renderer
        /// (their warm-up is done).
        var subjectSeen: Set<UUID> = []
        /// Frame index of every Vision run, in order (tests).
        var subjectIndices: [Int] = []
        /// Magic masks read their tracked mattes only (Track ran in the app); export never segments for them.
        nonisolated let magicStore = MagicMatteStore.shared
        /// Layers drawn with a Magic mask that has no tracked matte at that frame (stale or untracked: covers nothing).
        var untrackedMagicFrames = 0
        /// Stored accurate person mattes (nil = always segment). Per tracker key: read from the store (its range was fully
        /// stored when the clip first showed) or segmented and written to it.
        let subjectMattes: ExportSubjectMattes?
        var subjectFromStore: [UUID: Bool] = [:]
        var subjectStored: [UUID: (media: UUID, puts: Int)] = [:]
        var clipSources: [Clip.ID: TimeRange] = [:]
        var profile = RenderStageProfile()
        /// Text rasters warmed on a background queue shortly before their clip shows (first CoreText layout off the
        /// serial render path; playback does the same in its render loop).
        var textCursor: TextPrewarmCursor
        /// Clip starts ahead of the render position, handed to `provider.prefetch` (nil = off).
        var prefetchScanner: ClipPrefetchScanner?
        nonisolated let textQueue = DispatchQueue(label: "sq.export.text-prewarm", qos: .userInitiated)
        func waitForTextPrewarm() async { await withCheckedContinuation { c in textQueue.async { c.resume() } } }
        func currentProfile() -> RenderStageProfile {
            var p = profile
            p.intermediateAllocations = compositor.intermediateAllocations
            p.workingTextures = workingAllocations
            return p
        }
        var workingAllocations = 0
        /// Video Denoise / Deflicker: decoded neighbors by media and sample index. Export moves forward, so the window of
        /// the last output frame holds the next frame's earlier neighbors; everything outside the windows drawn in the
        /// current output frame is dropped after it (memory: one window per filtered media).
        var temporalHistory = FrameHistory<ProvidedFrame>()
        var temporalSpans: [UUID: [ClosedRange<Int>]] = [:]
        private var pressureToken: MemoryPressureToken?
        private struct CompositorRef: @unchecked Sendable { let compositor: Compositor }

        init(timeline: Timeline, sequences: [Timeline.ID: Timeline], provider: any FrameProvider, width: Int, height: Int, format: ExportPixelFormat,
             captions: CaptionBurnIn?, colorResolver: LayerColorResolver?, gyroWarper: GyroFrameWarper? = nil, continueOnDamaged: Bool,
             layerConcurrency: Int, subjectMattes: ExportSubjectMattes? = nil, device: MTLDevice, queue: MTLCommandQueue,
             cullsHidden: Bool = true, hdrToSDR: HDRToSDR? = nil, hdrOutput: HDRDelivery.Transfer? = nil,
             prefetch: ClipPrefetchScanner? = nil) throws {
            self.hdrToSDR = hdrToSDR; self.hdrOutput = hdrOutput
            self.subjectMattes = subjectMattes; self.cullsHidden = cullsHidden
            self.timeline = timeline; self.sequences = sequences; self.provider = provider
            prefetchScanner = prefetch
            var durations: [Clip.ID: Time] = [:], names: [Clip.ID: String] = [:]
            for tl in [timeline] + Array(sequences.values) {
                for t in tl.tracks { for c in t.clips { durations[c.id] = c.source.duration; names[c.id] = c.name; clipSources[c.id] = c.source } }
            }
            clipDurations = durations; clipNames = names; self.width = width; self.height = height
            self.continueOnDamaged = continueOnDamaged
            self.layerConcurrency = max(1, layerConcurrency)
            mediaEnds = TimelineFrameSource.mediaEnds(timeline, sequences: sequences)
            // SQ_EXPORT_TEXT_PREWARM=0 turns it off (A/B bench only).
            let warms = ProcessInfo.processInfo.environment["SQ_EXPORT_TEXT_PREWARM"] != "0"
            textCursor = TextPrewarmCursor(spans: warms ? TimelineFrameSource.textSpans(timeline, sequences: sequences) : [],
                                           lead: TimelineFrameSource.textPrewarmLead)
            self.format = format; self.captions = captions; self.colorResolver = colorResolver; self.gyroWarper = gyroWarper; self.device = device; self.queue = queue
            compositor = try Compositor(device: device)
            compositor.colorResolver = colorResolver; compositor.colorResolverBlocks = true   // masked Color effects' LUTs
            compositor.intermediatePoolByteLimit = WorkLimits.current.exportIntermediatePoolBytes   // 256 MB on 8 GB Macs
            let lib = try device.makeLibrary(source: ExportShaderSource.msl(hdr: hdrOutput), options: nil)
            func pipe(_ n: String) throws -> MTLComputePipelineState {
                try device.makeComputePipelineState(function: lib.makeFunction(name: n)!)
            }
            switch format {
            case .bgra8: passes = [(try pipe("encodeBGRA"), 0, .bgra8Unorm)]
            case .yuv420v: passes = [(try pipe("encodeLuma"), 0, .r8Unorm), (try pipe("encodeChroma"), 1, .rg8Unorm)]
            case .yuv420v10: passes = [(try pipe("encodeLuma10"), 0, .r16Unorm), (try pipe("encodeChroma420_10"), 1, .rg16Unorm)]
            case .yuv422v10: passes = [(try pipe("encodeLuma10"), 0, .r16Unorm), (try pipe("encodeChroma422_10"), 1, .rg16Unorm)]
            case .ayuv4444: passes = [(try pipe("encodeAYUV16"), 0, .rgba16Unorm)]
            case .ayuv4444Alpha: passes = [(try pipe("encodeAYUV16Alpha"), 0, .rgba16Unorm)]
            case .rgbaHalf: passes = [(try pipe("encodeRGBAHalf"), 0, .rgba16Float)]
            }
            let usage = MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
            var c: CVMetalTextureCache?
            let cs = CVMetalTextureCacheCreate(nil, nil, device, [kCVMetalTextureUsage: usage] as CFDictionary, &c)
            guard cs == kCVReturnSuccess, let c else { throw TimelineFrameSourceError.bufferCreationFailed(cs) }
            cache = c
            // Memory pressure (memory audit): warning keeps half the free intermediates, critical none (the pool has its
            // own lock; the next frame allocates what it needs again).
            let ref = CompositorRef(compositor: compositor), poolCap = compositor.intermediatePoolByteLimit
            pressureToken = MemoryPressureRegistry.shared.register("export compositor pool") { level in
                if level != .normal { ref.compositor.trimIntermediatePool(toBytes: level == .critical ? 0 : poolCap / 2) }
            }
            let fmt = format.cvPixelFormat
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: fmt, kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
            var p: CVPixelBufferPool?
            let ps = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &p)
            guard ps == kCVReturnSuccess, let p else { throw TimelineFrameSourceError.bufferCreationFailed(ps) }
            pool = p
        }

        func workingTexture() throws -> MTLTexture {
            if let t = freeWorking.popLast() { return t }
            workingAllocations += 1
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: timeline.format.width,
                                                             height: timeline.format.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw TimelineFrameSourceError.bufferCreationFailed(-1) }
            return t
        }

        func planeTexture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat, keep: inout [CVMetalTexture]) throws -> MTLTexture {
            let planar = CVPixelBufferIsPlanar(pb)
            let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
            let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
            var out: CVMetalTexture?
            let r = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &out)
            guard r == kCVReturnSuccess, let out, let tex = CVMetalTextureGetTexture(out) else {
                throw TimelineFrameSourceError.bufferCreationFailed(r)
            }
            keep.append(out)
            return tex
        }

        func dispatch(_ p: MTLComputePipelineState, src: MTLTexture, dst: MTLTexture, _ cb: MTLCommandBuffer) throws {
            guard let enc = cb.makeComputeCommandEncoder() else { throw TimelineFrameSourceError.commandBufferFailed("encoder") }
            enc.setComputePipelineState(p)
            enc.setTexture(src, index: 0); enc.setTexture(dst, index: 1)
            enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
        }

        /// Text generator layer: the raster's center placed relative to the canvas center; the animation factors
        /// (opacity, scale, offset, rotation) are folded into the layer transform.
        func textLayer(_ l: LayerRequest, _ ref: GeneratorRef) throws -> RenderLayer {
            let dur = l.clipDuration ?? clipDurations[l.clip] ?? l.localTime
            guard let f = try TextGenerator.frame(ref: ref, localTime: l.localTime, clipDuration: dur,
                                                  canvas: timeline.format, scale: 1) else {
                var tr = l.transform; tr.opacity = 0
                return RenderLayer(content: .placeholder(.loading), transform: tr)   // empty text: invisible
            }
            let tr = f.layerTransform(base: l.transform, canvas: timeline.format)
            return RenderLayer(content: .linearPremultiplied(f.buffer, width: f.width, height: f.height), transform: tr,
                               cornerRadius: l.cornerRadius).withFootageFill(of: ref)
        }

        /// The layer with the clip's effects (Crop, Rounded Corners, Gaussian Blur) and blend mode attached, like playback.
        /// A source frame that fails to decode stops the export with the clip and time (`ExportDecodeError`), or, with
        /// "continue on damaged frames", is drawn as the damaged placeholder as the Program monitor does.
        func layer(for l: LayerRequest, at t: Time, fetched: Fetched = [:]) async throws -> RenderLayer {
            do {
                return try await baseLayer(for: l, fetched: fetched).applying(l)
            } catch let e as FrameDecodeError {
                guard continueOnDamaged else {
                    throw ExportDecodeError(clip: l.clip, clipName: clipNames[l.clip] ?? "?", time: t,
                                            timecode: ExportDecodeError.timecode(t, frameDuration: timeline.format.frameDuration),
                                            reason: e.reason)
                }
                damaged += 1
                return RenderLayer(content: .placeholder(.damaged), transform: l.transform, cornerRadius: l.cornerRadius).applying(l)
            }
        }

        /// The layer's color pipeline with the export's HDR to SDR trim on its tone map (HDR sources only use it).
        func exportPipeline(for l: LayerRequest) -> ColorPipeline? {
            guard var p = colorResolver?.pipelineBlocking(for: l.color, media: l.media, owner: l.clip) else { return nil }
            if let hdrToSDR, p.source.isHDR { p.toneMapping = hdrToSDR.applied(to: p.toneMapping) }
            if hdrOutput != nil, p.source.isHDR { p.skipsToneMap = true }   // an HDR delivery keeps the picture's HDR range
            return p
        }

        func baseLayer(for l: LayerRequest, fetched: Fetched) async throws -> RenderLayer {
            /// The frame fetched for this output frame, else asked now.
            func frame(_ media: UUID, _ at: Time) async throws -> ProvidedFrame? {
                if let r = fetched[FetchKey(media: media, time: at)] { return try r.get() }
                let c = ContinuousClock.now
                defer { profile.layerDecode += ContinuousClock.now - c }
                return try await provider.frame(media: media, at: at)
            }
            if let g = l.generator {
                if g.kind == GeneratorRef.solid {
                    return RenderLayer.solid(payload: g.payload, transform: l.transform, colorPipeline: exportPipeline(for: l),
                                             cornerRadius: l.cornerRadius)
                }
                if g.kind == GeneratorRef.text {
                    let cold = !TextGenerator.isCached(ref: g)
                    let c = ContinuousClock.now
                    defer {
                        profile.layerText += ContinuousClock.now - c
                        if cold { profile.layerTextCold += ContinuousClock.now - c; profile.textColdLayers += 1 }
                    }
                    return try textLayer(l, g)
                }
                if g.kind == GeneratorRef.dateStamp {          // Date Stamp: the same text layer as a title, built from its spec
                    guard let t = DateStampText.textRef(for: g) else { return RenderLayer(content: .placeholder(.offline), transform: l.transform) }
                    return try textLayer(l, t)
                }
                if g.kind == GeneratorRef.shape { return ShapeRenderer.layer(for: l) }
                if g.kind == GeneratorRef.lottie { return LottieRenderer.layer(for: l, canvas: timeline.format) }
                if g.kind == GeneratorRef.adjustment {
                    return RenderLayer.adjustment(transform: l.transform,
                                                  colorPipeline: exportPipeline(for: l))
                }
                return RenderLayer(content: .placeholder(.offline), transform: l.transform, cornerRadius: l.cornerRadius)
            }
            if var f = try await frame(l.media, l.sourceTime) {
                let shown = shownInfo(f, media: l.media)       // F7.3: desqueezed by the item's pixel aspect
                opaquePictures[l.media] = Self.opaquePicture(f, shown: shown)
                // Gyroflow Stabilizer: the decoded frame warped first (same engine call as playback, waiting for the
                // clip's analysis). A frame the engine cannot warp is drawn as decoded.
                func stabilised(_ pb: CVPixelBuffer, pts: Time) -> CVPixelBuffer {
                    guard let g = l.gyro, let gyroWarper else { return pb }
                    return gyroWarper.warp(pb, media: l.media, options: g, pts: pts, wait: true) ?? pb
                }
                let decoded = f.buffer
                f.buffer = stabilised(decoded, pts: f.start ?? l.sourceTime)
                // Frame Blending: mix with the next source frame by the fractional source position.
                var blend: FrameBlend?
                // Source times of the other frames mixed into this one (nil = one of them is unknown): an Anonymize
                // cover takes all of them.
                var mixed: [Double]? = []
                func seconds(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }
                if let (next, w) = Self.blendNext(l, f), let n = try await frame(l.media, next), n.buffer !== decoded {
                    mixed?.append(seconds(n.start ?? next))
                    // Optical flow: export quality, cached per source pair (a slow motion reuses it for several frames).
                    let flow = l.interpolation == .opticalFlow
                        ? OpticalFlowRequest(key: FlowPairKey(media: l.media, from: f.start ?? l.sourceTime, to: next,
                                                              variant: l.gyro?.hashValue ?? 0), quality: .better)
                        : nil
                    blend = FrameBlend(next: stabilised(n.buffer, pts: n.start ?? next), weight: w, flow: flow)
                }
                // Video Denoise / Deflicker: the full window of neighbors (export is exact), in place of Frame Blending.
                var temporal: TemporalFrames?
                if let filter = l.effects.temporal {
                    let n = try await temporalNeighbours(for: l, center: f, before: filter.reachBack, after: filter.reachAhead)
                    temporal = TemporalFrames(filter: filter, before: n.before.map { stabilised($0.buffer, pts: $0.start ?? l.sourceTime) },
                                              after: n.after.map { stabilised($0.buffer, pts: $0.start ?? l.sourceTime) })
                    blend = nil
                    let starts = (n.before + n.after).map(\.start)
                    mixed = starts.contains { $0 == nil } ? nil : starts.compactMap { $0.map(seconds) }
                }
                var layer = RenderLayer(content: .frame(f.buffer, colorHint: f.info), transform: l.transform,
                                        colorPipeline: exportPipeline(for: l),
                                        cornerRadius: l.cornerRadius, nativeSize: (shown.desqueezedWidth, shown.height), blend: blend)
                layer.temporal = temporal
                if l.effects.needsSubjectMatte { layer.subjectMatte = try await subjectMatte(for: l, frame: f) }
                if !l.effects.magicMattes.isEmpty {
                    let fw = Double(shown.displayWidth)
                    if let s = f.start {
                        // An Anonymize cover takes every frame in the mix (the box around them under optical flow); too
                        // many neighbors or one without a time: the whole frame (`warped`).
                        let pts = seconds(s)
                        let known = mixed.map { $0.count <= MagicMatteStore.maxNeighbors } ?? false
                        layer.mattes = magicStore.mattes(for: l.effects, pts: pts, frameWidth: fw, warped: l.gyro != nil || !known,
                                                         neighbors: known ? mixed ?? [] : [], spanning: blend?.flow != nil)
                        if magicStore.missesMatte(for: l.effects, pts: pts) { untrackedMagicFrames += 1 }
                    } else {
                        // A still (one picture, no source time): the matte tracked on it, else the whole frame.
                        layer.mattes = magicStore.mattes(for: l.effects, pts: 0, frameWidth: fw, warped: l.gyro != nil, still: true)
                    }
                }
                return layer
            }
            return RenderLayer(content: .placeholder(.offline), transform: l.transform, cornerRadius: l.cornerRadius)
        }

        /// The upright size of `f` when its pixel format carries no alpha (YCbCr video); nil otherwise.
        static func opaquePicture(_ f: ProvidedFrame, shown: VideoTrackInfo) -> LayerOcclusion.Picture? {
            guard PixelFormats.info(for: CVPixelBufferGetPixelFormatType(f.buffer))?.layout == .biplanarYCbCr else { return nil }
            return LayerOcclusion.Picture(width: shown.displayWidth, height: shown.displayHeight)
        }

        /// `f`'s track info read with the pixel aspect of the project's media item (the decoder only knows the file's tag).
        /// Media the project has no info for is square, as in playback.
        func shownInfo(_ f: ProvidedFrame, media: UUID) -> VideoTrackInfo {
            f.info.adoptingPixelAspect(of: colorResolver?.info(of: media)?.video)
        }

        /// The decoded neighbors of `f` within `before` / `after` frames, nearest first on each side, from `temporalHistory` or the
        /// provider. Asked in ascending source order (earliest first) so the decoder only moves forward. A side stops at
        /// the media's ends or a neighbor that does not decode (the filter then uses fewer frames; never an export error).
        func temporalNeighbours(for l: LayerRequest, center f: ProvidedFrame, before: Int, after: Int) async throws
            -> (before: [ProvidedFrame], after: [ProvidedFrame]) {
            let ci = Self.sampleIndex(f, sourceTime: l.sourceTime)
            temporalHistory[l.media, ci] = f
            temporalSpans[l.media, default: []].append((ci - before)...(ci + after))
            guard before > 0 || after > 0, let start = f.start, let d = f.duration, d > .zero else { return ([], []) }
            // The clip's source range (widened to the shown frame, e.g. a transition handle): never a frame cut away.
            let lo = min(l.sourceStart ?? .zero, start), hi = l.sourceEnd.map { max($0, start + d) }
            var got: [Int: ProvidedFrame] = [:]
            for k in Array(stride(from: -before, through: -1, by: 1)) + Array(stride(from: 1, through: after, by: 1)) {
                try Task.checkCancellation()
                let at = start + d * Int64(k)
                guard at + d > lo, hi.map({ at < $0 }) ?? true else { continue }
                if let h = temporalHistory[l.media, ci + k] { got[k] = h; continue }
                guard at >= .zero, let n = try? await provider.frame(media: l.media, at: at),
                      Self.sampleIndex(n, sourceTime: at) == ci + k else { continue }
                temporalHistory[l.media, ci + k] = n
                got[k] = n
            }
            func side(_ sign: Int) -> [ProvidedFrame] {
                var out: [ProvidedFrame] = []
                for k in stride(from: 1, through: sign < 0 ? before : after, by: 1) { guard let n = got[sign * k] else { break }; out.append(n) }
                return out
            }
            return (side(-1), side(1))
        }

        /// Frame Blending: source time of the next frame to mix with `f`, and its weight (nil = no blend).
        static func blendNext(_ l: LayerRequest, _ f: ProvidedFrame) -> (Time, Float)? {
            guard l.interpolation.mixesFrames, let s = f.start, let d = f.duration else { return nil }
            let w = FrameBlend.weight(sourceTime: l.sourceTime, frameStart: s, frameDuration: d)
            guard w > 0, l.sourceEnd.map({ s + d < $0 }) ?? true else { return nil }
            return (s + d, w)
        }

        struct FetchKey: Hashable, Sendable { var media: UUID; var time: Time }
        typealias Fetched = [FetchKey: Result<ProvidedFrame?, any Error>]

        /// Stacked layers: decodes the frames of `requests` with up to `layerConcurrency` media at once. One media's
        /// frames are asked one after the other in layer order (as the serial render does: its decoder sees the same
        /// sequence of requests), so only independent media overlap. Results (errors too) are kept by media and source
        /// time; the layers are then built in layer order from them, so output and the reported error are the serial
        /// render's. A single media or `layerConcurrency` 1: nothing fetched (the layers ask the provider themselves).
        /// `seed`: frames already asked for this output frame (kept, never asked again).
        func fetchFrames(_ requests: [LayerRequest], seed: Fetched = [:]) async -> Fetched {
            guard layerConcurrency > 1 else { return seed }
            var order: [UUID] = [], byMedia: [UUID: [LayerRequest]] = [:]
            for l in requests where l.generator == nil {
                if byMedia[l.media] == nil { order.append(l.media) }
                byMedia[l.media, default: []].append(l)
            }
            guard order.count > 1 else { return seed }
            let provider = self.provider, width = min(layerConcurrency, order.count)
            return await withTaskGroup(of: Fetched.self) { g in
                var next = 0, out: Fetched = seed
                func start(_ reqs: [LayerRequest]) {
                    g.addTask {
                        var got: Fetched = seed
                        func fetch(_ m: UUID, _ t: Time) async -> ProvidedFrame? {
                            let key = FetchKey(media: m, time: t)
                            if let r = got[key] { return try? r.get() }
                            let r: Result<ProvidedFrame?, any Error>
                            do { r = .success(try await provider.frame(media: m, at: t)) } catch { r = .failure(error) }
                            got[key] = r
                            return try? r.get()
                        }
                        for l in reqs {
                            if Task.isCancelled { break }
                            guard let f = await fetch(l.media, l.sourceTime) else { continue }
                            if let (n, _) = Self.blendNext(l, f) { _ = await fetch(l.media, n) }
                        }
                        return got
                    }
                }
                while next < width { start(byMedia[order[next]]!); next += 1 }
                while let r = await g.next() {
                    out.merge(r) { a, _ in a }
                    if next < order.count, !Task.isCancelled { start(byMedia[order[next]]!); next += 1 }
                }
                return out
            }
        }

        static func sampleIndex(_ f: ProvidedFrame, sourceTime: Time) -> Int {
            if let i = f.sampleIndex { return i }
            let fdur = f.duration ?? f.info.nominalFrameDuration
            return fdur > .zero ? Int((f.start ?? sourceTime).frameIndex(frameDuration: fdur)) : 0
        }

        /// The accurate, smoothed person matte of `f`. The first time this renderer meets a clip past its first frame,
        /// up to `subjectWarmupFrames` earlier frames go through the smoother first (no pop at a segment boundary).
        static func subjectKey(_ l: LayerRequest) -> UUID { SubjectMatteScheduler.Key(clip: l.clip, source: l.media).trackerKey }

        func subjectMatte(for l: LayerRequest, frame f: ProvidedFrame) async throws -> SubjectMatte? {
            let index = Self.sampleIndex(f, sourceTime: l.sourceTime)
            let key = Self.subjectKey(l)
            if let m = subjectMattes, let fstart = f.start {
                if subjectFromStore[key] == nil {
                    let r = clipSources[l.clip]
                    let from = r.map { Double($0.start.value) / Double($0.start.timescale) } ?? 0
                    let end = l.sourceEnd ?? r.map { $0.start + $0.duration }
                    subjectFromStore[key] = end.map { m.covers(media: l.media, from: from, to: Double($0.value) / Double($0.timescale)) } ?? false
                }
                if subjectFromStore[key] == true {
                    subjectSeen.insert(key)
                    let pts = Double(fstart.value) / Double(fstart.timescale)
                    if let hit = m.matte(media: l.media, pts: pts) { return hit }
                }
            }
            if subjectSeen.insert(key).inserted, index > 0, let start = f.start, let d = f.duration, d > .zero {
                let back = min(TimelineFrameSource.subjectWarmupFrames, Int(l.localTime.frameIndex(frameDuration: timeline.format.frameDuration)))
                var done = Set<Int>()
                for k in stride(from: back, to: 0, by: -1) {
                    try Task.checkCancellation()
                    guard let w = try await provider.frame(media: l.media, at: start - d * Int64(k)) else { continue }
                    let wi = Self.sampleIndex(w, sourceTime: start - d * Int64(k))
                    guard wi < index, done.insert(wi).inserted else { continue }
                    _ = segment(w, index: wi, key: key, media: l.media)
                }
            }
            return segment(f, index: index, key: key, media: l.media)
        }

        private func segment(_ f: ProvidedFrame, index: Int, key: UUID, media: UUID) -> SubjectMatte? {
            if let m = subject.cached(key: key, frameIndex: index) { return m }
            subjectIndices.append(index)
            let m = subject.layerMatte(for: f.buffer, rotationDegrees: f.info.rotation, key: key, frameIndex: index, quality: .accurate)
            // Kept for the next export of this clip (only real mattes: "no person" stays a live decision).
            if let m, let store = subjectMattes, let start = f.start {
                store.put(m, media: media, pts: Double(start.value) / Double(start.timescale))
                let n = (subjectStored[key]?.puts ?? 0) + 1
                subjectStored[key] = (media, n)
                if n % 120 == 0 { store.save(media: media) }
            }
            return m
        }

        func render(at t: Time) async throws -> Box<CVPixelBuffer> {
            try await complete(submit(at: t))
        }

        /// A frame whose GPU work is committed (`submit`) and not yet waited for (`complete`).
        struct Submitted: Sendable {
            var out: Box<CVPixelBuffer>
            var working: Box<MTLTexture>
            var commandBuffer: Box<MTLCommandBuffer>
            var done: GPUCompletion
        }

        /// Everything on the CPU for the frame at `t` (decodes, layers, command encoding), then commits its GPU work.
        func submit(at t: Time) async throws -> Submitted {
            let c0 = ContinuousClock.now
            for ref in textCursor.advance(to: t) { textQueue.async { try? TextGenerator.prewarm(ref: ref) } }
            if var scanner = prefetchScanner {
                // The scan sees what the render will draw: a layer coming out from under a cover counts as appearing, so its
                // decoder is moved there ahead of time (it was not decoded while hidden).
                let known = cullsHidden ? opaquePictures : [:]
                let hints = scanner.advance(to: t) { [timeline, sequences] u in
                    let all = GraphicsTextBounds.$exact.withValue(true) { timeline.videoLayers(at: u, sequences: { sequences[$0] }) }
                    guard !known.isEmpty else { return all }
                    let hidden = LayerOcclusion.evaluate(all, canvas: timeline.format) { known[$0.media] }.hidden
                    return hidden.isEmpty ? all : all.indices.filter { !hidden.contains($0) }.map { all[$0] }
                }
                prefetchScanner = scanner
                for h in hints { await provider.prefetch(media: h.media, at: h.sourceTime) }
            }
            // Export measures every Follow text target exactly (laid out here if not warm yet; playback never does).
            let requests = GraphicsTextBounds.$exact.withValue(true) {
                timeline.videoLayers(at: t, sequences: { [sequences] in sequences[$0] })
            }
            // Layers under an opaque full-canvas picture are left out, once that picture is certain: the cover's layer is
            // built first and must come out as a real opaque frame of the known size. An offline or damaged cover is a
            // canvas-sized placeholder that hides nothing, so everything is drawn then. A hidden layer is not decoded,
            // so a damaged frame of it neither stops the export nor counts (it contributes no pixel; DECISIONS 2026-10-06).
            var keepIndices = Array(requests.indices), seed: Fetched = [:]
            var prebuilt: (index: Int, layer: Result<RenderLayer, any Error>)?
            if cullsHidden, !opaquePictures.isEmpty {
                let o = LayerOcclusion.evaluate(requests, canvas: timeline.format) { [opaquePictures] in opaquePictures[$0.media] }
                if let c = o.cover {
                    let cover = requests[c]
                    let r: Result<ProvidedFrame?, any Error>
                    do { r = .success(try await provider.frame(media: cover.media, at: cover.sourceTime)) } catch { r = .failure(error) }
                    seed[FetchKey(media: cover.media, time: cover.sourceTime)] = r
                    let built: Result<RenderLayer, any Error>
                    do { built = .success(try await layer(for: cover, at: t, fetched: seed)) } catch { built = .failure(error) }
                    prebuilt = (c, built)
                    if case .success(let f?) = r,
                       Self.opaquePicture(f, shown: shownInfo(f, media: cover.media)) == opaquePictures[cover.media],
                       case .success(let coverLayer) = built, case .frame = coverLayer.content {
                        keepIndices = requests.indices.filter { !o.hidden.contains($0) }
                        profile.hiddenLayers += o.hidden.count
                    }
                }
            }
            let drawn = keepIndices.map { requests[$0] }
            let fetched = await fetchFrames(drawn, seed: seed)
            let c1 = ContinuousClock.now
            var layers: [RenderLayer] = []
            for i in keepIndices {
                try Task.checkCancellation()
                // The cover was built ahead; its layer (or its error, at its place in layer order) is used here.
                if let p = prebuilt, p.index == i { layers.append(try p.layer.get()) } else {
                    layers.append(try await layer(for: requests[i], at: t, fetched: fetched))
                }
            }
            temporalHistory.keep(temporalSpans)
            temporalSpans = [:]
            let c2 = ContinuousClock.now
            profile.fetch += c1 - c0; profile.layers += c2 - c1; profile.frames += 1
            // Export only moves forward: a subject-masked clip no longer drawn is done, its matte state goes.
            let live = Set(requests.filter { $0.effects.needsSubjectMatte }.map(Self.subjectKey))
            for gone in subjectSeen.subtracting(live) {
                subject.reset(key: gone); subjectSeen.remove(gone); subjectFromStore[gone] = nil
                if let s = subjectStored.removeValue(forKey: gone) { subjectMattes?.save(media: s.media) }
            }
            // Media whose last clip has ended and that this frame does not draw: their decoders and frames go.
            let shown = Set(requests.filter { $0.generator == nil }.map(\.media))
            let past = Set(mediaEnds.filter { $0.value <= t && !shown.contains($0.key) }.keys).subtracting(released)
            if !past.isEmpty { released.formUnion(past); await provider.release(media: past) }
            try Task.checkCancellation()

            var out: CVPixelBuffer?
            let st = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard st == kCVReturnSuccess, let out else { throw TimelineFrameSourceError.bufferCreationFailed(st) }
            let working = try workingTexture()
            guard let cb = queue.makeCommandBuffer() else { throw TimelineFrameSourceError.commandBufferFailed("command buffer") }
            var keep: [CVMetalTexture] = []
            do {
                try compositor.render(nodes: RenderNode.tree(requests: drawn, layers: layers), format: timeline.format, into: working, commandBuffer: cb,
                                         background: format == .ayuv4444Alpha || format == .rgbaHalf ? .transparent : .black)
                try captions?.encode(at: t, into: working, commandBuffer: cb)
                for (p, plane, f) in passes {
                    try dispatch(p, src: working, dst: planeTexture(out, plane: plane, format: f, keep: &keep), cb)
                }
            } catch {
                freeWorking.append(working)
                throw error
            }
            let done = GPUCompletion()
            // The plane textures live until the GPU is done, and their cache must outlive them: a texture released on
            // Metal's completion queue after the renderer (and its cache) had gone crashed in
            // `CVMetalTextureCache::bufferBackingNotInUse` (abandoned frames: cancel, an error in a later frame).
            let keepAlive = TextureHold(textures: keep, cache: cache)
            cb.addCompletedHandler { b in
                keepAlive.drop()
                done.finish(b.error)
            }
            cb.commit()
            profile.encode += ContinuousClock.now - c2
            return Submitted(out: Box(out), working: Box(working), commandBuffer: Box(cb), done: done)
        }

        /// Waits for a submitted frame's GPU work and returns its tagged buffer. Other frames may be submitted meanwhile.
        func complete(_ s: Submitted) async throws -> Box<CVPixelBuffer> {
            let c0 = ContinuousClock.now
            do {
                try await s.done.wait()
            } catch {
                freeWorking.append(s.working.buffer)
                throw error
            }
            freeWorking.append(s.working.buffer)
            profile.wait += ContinuousClock.now - c0
            let cb = s.commandBuffer.buffer
            profile.gpu += .seconds(max(0, cb.gpuEndTime - cb.gpuStartTime))
            try Task.checkCancellation()
            let out = s.out.buffer
            Self.tag(out)
            if format == .ayuv4444Alpha {
                CVBufferSetAttachment(out, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
            }
            CVMetalTextureCacheFlush(cache, 0)
            return s.out
        }

        static func tag(_ pb: CVPixelBuffer) {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
    }
}

/// Hands out each text ref once, when one of its clips starts within `lead` of the render position and is not over yet.
/// Export moves forward, so one pass over the sorted spans suffices.
struct TextPrewarmCursor: Sendable {
    let spans: [TimelineFrameSource.TextSpan]
    let lead: Time
    private var next = 0
    private var handed: Set<GeneratorRef> = []

    init(spans: [TimelineFrameSource.TextSpan], lead: Time) { self.spans = spans; self.lead = lead }

    mutating func advance(to t: Time) -> [GeneratorRef] {
        var out: [GeneratorRef] = []
        let horizon = t + lead
        while next < spans.count, spans[next].range.start <= horizon {
            let s = spans[next]; next += 1
            guard s.range.end > t, handed.insert(s.ref).inserted else { continue }
            out.append(s.ref)
        }
        return out
    }
}
