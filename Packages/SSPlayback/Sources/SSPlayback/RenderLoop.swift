import CoreVideo
import Foundation
import Metal
import QuartzCore
import Synchronization
import SSCore
import SSMedia
import SSRender

/// Opened media shared by the render thread and the decode threads: demuxer (for the `SampleIndex`), track info
/// (colour hint, known once a decoder exists) and the damaged flag set by decode errors.
final class MediaTable: Sendable {
    private enum Entry: Sendable { case ready(any Demuxing), offline }
    private struct State { var entries: [UUID: Entry] = [:]; var info: [UUID: VideoTrackInfo] = [:]; var damaged: Set<UUID> = [] }
    private let state = Mutex(State())
    let resolver: any MediaResolver

    init(resolver: any MediaResolver) { self.resolver = resolver }

    /// Resolved once per media and remembered (offline too, until `forgetOffline`).
    func demuxer(_ media: UUID) -> (any Demuxing)? {
        if let e = state.withLock({ $0.entries[media] }) {
            if case .ready(let d) = e { return d }
            return nil
        }
        let e: Entry = (try? resolver.demuxer(for: media)).map(Entry.ready) ?? .offline
        let stored = state.withLock { s in
            if let old = s.entries[media] { return old }
            s.entries[media] = e; return e
        }
        if case .ready(let d) = stored { return d }
        return nil
    }

    func forgetOffline() {
        state.withLock { s in s.entries = s.entries.filter { if case .offline = $0.value { false } else { true } } }
    }

    func setInfo(_ info: VideoTrackInfo, for media: UUID) { state.withLock { $0.info[media] = info } }
    func info(_ media: UUID) -> VideoTrackInfo? { state.withLock { $0.info[media] } }
    func markDamaged(_ media: UUID) { state.withLock { _ = $0.damaged.insert(media) } }
    func isDamaged(_ media: UUID) -> Bool { state.withLock { $0.damaged.contains(media) } }
}

/// Counts `decode` calls (tests: "served from cache" = no decode) and forwards to the real decoder.
final class DecodeCounter: Sendable {
    private let n = Mutex(0)
    func increment() { n.withLock { $0 += 1 } }
    var value: Int { n.withLock { $0 } }
}

struct CountingDecoder: VideoDecoding {
    let inner: any VideoDecoding
    let counter: DecodeCounter
    var info: VideoTrackInfo { inner.info }
    var isHardware: Bool { inner.isHardware }
    func invalidate() { inner.invalidate() }
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        counter.increment()
        return try await inner.decode(range)
    }
}

/// Result of one render-loop iteration.
struct TickOutcome: Sendable {
    /// A composite was encoded (and presented when a layer is attached).
    var presented: Bool
    /// Frame position of this iteration (snapped to the sequence frame grid).
    var time: Time
    /// Playback ran past the timeline's first/last frame; the clock was stopped there.
    var stoppedAtEdge: Bool
}

/// Immutable-after-creation texture handle for crossing threads (§8).
public struct RenderedTexture: @unchecked Sendable {
    public let texture: MTLTexture
}

/// One render-loop iteration per display tick (render thread) or per `tick()` call (tests, bench).
///
/// Per tick: `t = clock.now()` floored to the sequence frame grid (clamped to the timeline) -> unchanged and not
/// invalidated and nothing still loading: present nothing -> `videoLayers(at:)` -> source time -> frame through the
/// media's `SampleIndex` -> `FrameKey(media, pts, scale)` -> cache hit, or on a miss the nearest earlier cached frame
/// (a drop, and the GOP is requested), or a `.loading` placeholder -> `RenderNode.tree` -> `Compositor.render` into an
/// rgba16Float texture -> `Presenter` when a layer is attached (headless: the texture is kept as `lastRendered` and the
/// command buffer is waited on). Then the prefetch window is planned and submitted.
final class RenderLoop: @unchecked Sendable {
    typealias Job = PrefetchPlanner.Job
    typealias Mapping = FrameCache<DecodedFrame>.Mapping

    struct RenderState {
        var timeline: Timeline?
        var sequences: [Timeline.ID: Timeline] = [:]
        var mediaIDs: [UUID] = []
        var mapping: Mapping = { $0.pts }
        var quality: DecodeScale = .full
        var zoom: ViewerZoom = .fit
        var invalidated = true
        /// Last composite had a layer without its exact frame (still decoding): re-render until complete.
        var incomplete = false
        var lastTime: Time?
        var pendingStep: (target: Time, start: ContinuousClock.Instant)?
        var stats = PlaybackStats()
        var presenter: Presenter?
        var scheduler: DecodeScheduler?
        var schedulerScale: DecodeScale = .full
        var lastJobs: [Job] = []
        /// Coalesces position reports to the main actor.
        var reportPending = false
        var lastOutcome: TickOutcome?
    }

    /// GPU objects, touched only inside `tick` (the lock serialises ticks from the render thread and from tests).
    private struct GPU: @unchecked Sendable {
        let queue: MTLCommandQueue
        let compositor: Compositor
        var target: MTLTexture?
    }

    let device: MTLDevice
    let clock: any PlaybackClock
    let cache: FrameCache<DecodedFrame>
    let media: MediaTable
    let decodeCounter = DecodeCounter()
    let planner = PrefetchPlanner()
    let state: Mutex<RenderState>
    private let gpu: Mutex<GPU>
    private let submitChain = Mutex<Task<Void, Never>?>(nil)

    init(device: MTLDevice, resolver: any MediaResolver, clock: any PlaybackClock, cache: FrameCache<DecodedFrame>) throws {
        self.device = device; self.clock = clock; self.cache = cache
        self.media = MediaTable(resolver: resolver)
        guard let queue = device.makeCommandQueue() else { throw CompositorError.invalidTarget("no command queue") }
        let compositor = try Compositor(device: device)
        gpu = Mutex(GPU(queue: queue, compositor: compositor, target: nil))
        state = Mutex(RenderState())
        let s = makeScheduler(.full)
        state.withLock { $0.scheduler = s; $0.schedulerScale = .full }
    }

    // MARK: Decode side

    private func makeScheduler(_ scale: DecodeScale) -> DecodeScheduler {
        let media = self.media, counter = decodeCounter
        return DecodeScheduler(
            maxConcurrent: 4,
            decoder: { id in
                guard let d = media.demuxer(id) else { throw MediaResolverError.unknownMedia(id) }
                let dec = try VTVideoDecoder(demuxer: d, media: id, scale: scale)
                media.setInfo(dec.info, for: id)
                return CountingDecoder(inner: dec, counter: counter)
            },
            sink: { [weak self] _, frames in self?.store(frames, scale: scale) },
            onError: { [weak self] job, _ in self?.decodeFailed(job.media) })
    }

    /// Every decoded frame of a job is kept (a random access decodes the whole GOP: stepping back through it is free).
    private func store(_ frames: [DecodedFrame], scale: DecodeScale) {
        for f in frames { cache.insert(f, for: FrameKey(media: f.media, pts: f.pts, scale: scale)) }
    }

    private func decodeFailed(_ id: UUID) {
        media.markDamaged(id)
        state.withLock { $0.invalidated = true }
    }

    /// Posts `jobs` to the scheduler in call order (last wins), without blocking the caller.
    private func post(_ jobs: [Job], to scheduler: DecodeScheduler) {
        submitChain.withLock { last in
            let prev = last
            last = Task { await prev?.value; await scheduler.submit(jobs) }
        }
    }

    /// Suspends until every posted submission reached the scheduler and nothing is queued or decoding.
    func waitForDecodes() async {
        while true {
            let chain = submitChain.withLock { $0 }
            await chain?.value
            guard let s = state.withLock({ $0.scheduler }) else { return }
            await s.waitUntilIdle()
            let (chainNow, sNow) = (submitChain.withLock { $0 }, state.withLock { $0.scheduler })
            if chainNow == chain && sNow === s { return }
        }
    }

    // MARK: Main-actor inputs

    func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        let ids = Self.mediaIDs(timeline, sequences: sequences)
        let mapping = Self.mapping(timeline)
        media.forgetOffline()
        state.withLock { s in
            s.timeline = timeline; s.sequences = sequences; s.mediaIDs = ids; s.mapping = mapping
            s.invalidated = true
        }
    }

    func setQuality(_ q: DecodeScale) {
        let old: DecodeScheduler? = state.withLock { s in
            guard s.schedulerScale != q else { return nil }
            let old = s.scheduler
            s.quality = q; s.schedulerScale = q; s.invalidated = true; s.lastJobs = []
            return old
        }
        guard old != nil else { return }
        let new = makeScheduler(q)
        state.withLock { $0.scheduler = new }
        if let old { Task { await old.cancelAll() } }
    }

    func setPresenter(_ p: Presenter?) { state.withLock { $0.presenter = p; $0.invalidated = true } }

    func invalidate() { state.withLock { $0.invalidated = true } }

    func beginStep(target: Time) {
        state.withLock { $0.pendingStep = (target, ContinuousClock.now); $0.invalidated = true }
    }

    var lastRendered: RenderedTexture? { gpu.withLock { g in g.target.map { RenderedTexture(texture: $0) } } }

    var stats: PlaybackStats {
        var s = state.withLock { $0.stats }
        s.cacheBytes = cache.usedBytes
        return s
    }

    // MARK: Frame grid

    static func lastFrame(_ tl: Timeline) -> Time {
        let fd = tl.format.frameDuration
        let dur = tl.duration
        guard fd > .zero, dur > .zero else { return .zero }
        var n = dur.frameIndex(frameDuration: fd)
        if fd * n == dur { n -= 1 }
        return fd * max(0, n)
    }

    static func gridTime(_ t: Time, _ tl: Timeline) -> Time {
        let fd = tl.format.frameDuration
        guard fd > .zero else { return .zero }
        let g = fd * t.frameIndex(frameDuration: fd)
        return min(max(g, .zero), lastFrame(tl))
    }

    // MARK: Tick

    func tick(drawable: CAMetalDrawable? = nil) -> TickOutcome? {
        gpu.withLock { g in tickLocked(&g, drawable: drawable) }
    }

    private struct LayerBuild { var layers: [RenderLayer] = []; var missing = 0; var waiting = false; var misses: [(UUID, Int)] = [] }

    private func tickLocked(_ g: inout GPU, drawable: CAMetalDrawable?) -> TickOutcome? {
        let now = clock.now()
        let rate = clock.rate
        let snap = state.withLock { s in
            (s.timeline, s.sequences, s.quality, s.zoom, s.invalidated, s.incomplete, s.lastTime, s.presenter)
        }
        guard let tl = snap.0 else { return nil }
        let (sequences, scale, zoom, invalidated, incomplete, lastTime, presenter) =
            (snap.1, snap.2, snap.3, snap.4, snap.5, snap.6, snap.7)
        let fd = tl.format.frameDuration
        let last = Self.lastFrame(tl)
        var t = Self.gridTime(now, tl)
        var edge = false
        if (rate.isForward && now >= last + fd) || (rate.isReverse && now.isNegative) {
            t = rate.isForward ? last : .zero
            clock.stop(); clock.seek(to: t)
            edge = true
        }
        if t == lastTime && !invalidated && !incomplete && !edge {
            return TickOutcome(presented: false, time: t, stoppedAtEdge: false)
        }

        // Layers
        let requests = tl.videoLayers(at: t, sequences: { sequences[$0] }).filter { $0.generator == nil }
        var b = LayerBuild()
        for r in requests { b.layers.append(layer(for: r, scale: scale, build: &b)) }

        // Composite + present
        var presented = false
        if let target = target(&g, format: tl.format), let cb = g.queue.makeCommandBuffer() {
            do {
                try g.compositor.render(nodes: RenderNode.tree(requests: requests, layers: b.layers), format: tl.format,
                                        into: target, commandBuffer: cb)
                if let presenter {
                    if let drawable { presenter.present(target, zoom: zoom, drawable: drawable, commandBuffer: cb) }
                    else { presenter.present(target, zoom: zoom, commandBuffer: cb) }
                }
                presented = true
            } catch {
                presented = false
            }
            cb.commit()
            if presenter == nil { cb.waitUntilCompleted() }
        }

        let isNew = t != lastTime
        state.withLock { s in
            s.invalidated = false
            s.incomplete = b.waiting
            guard presented else { return }
            s.lastTime = t
            s.stats.presentedFrames += 1
            if isNew && b.missing > 0 { s.stats.droppedFrames += 1 }
            if let p = s.pendingStep, p.target == t, b.missing == 0 {
                s.stats.stepLatencies.append(ContinuousClock.now - p.start)
                s.pendingStep = nil
            }
        }

        prefetch(timeline: tl, at: t, rate: edge ? .zero : rate, scale: scale, misses: b.misses)
        return TickOutcome(presented: presented, time: t, stoppedAtEdge: edge)
    }

    private func layer(for r: LayerRequest, scale: DecodeScale, build b: inout LayerBuild) -> RenderLayer {
        func placeholder(_ k: PlaceholderKind) -> RenderLayer {
            RenderLayer(content: .placeholder(k), transform: r.transform, cornerRadius: r.cornerRadius)
        }
        guard let d = media.demuxer(r.media) else { return placeholder(.offline) }
        if media.isDamaged(r.media) { return placeholder(.damaged) }
        let index = d.index
        guard index.count > 0 else { return placeholder(.damaged) }
        let f = index.frame(at: r.sourceTime) ?? (r.sourceTime.isNegative ? 0 : index.count - 1)
        let key = FrameKey(media: r.media, pts: index.entries[f].pts, scale: scale)
        var frame = cache.frame(key)
        if frame == nil {
            b.missing += 1; b.waiting = true; b.misses.append((r.media, f))
            frame = cache.nearest(media: r.media, atOrBefore: key.pts, scale: scale)
        }
        guard let frame else { return placeholder(.loading) }
        let info = media.info(r.media) ?? VideoTrackInfo(
            width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer),
            codec: "", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: frame.duration, isVariableFrameRate: false)
        return RenderLayer(content: .frame(frame.pixelBuffer, colorHint: info), transform: r.transform,
                           cornerRadius: r.cornerRadius)
    }

    private func target(_ g: inout GPU, format: SequenceFormat) -> MTLTexture? {
        if let t = g.target, t.width == format.width, t.height == format.height { return t }
        guard format.width > 0, format.height > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: format.width,
                                                         height: format.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        g.target = device.makeTexture(descriptor: d)
        return g.target
    }

    // MARK: Prefetch

    /// Plans the decode window around `t` and submits it (deduplicated); also used by seek on the main actor so a
    /// random access starts decoding before the next display tick.
    func prefetch(at t: Time, rate: PlaybackRate) {
        guard let (tl, scale) = state.withLock({ s in s.timeline.map { ($0, s.quality) } }) else { return }
        prefetch(timeline: tl, at: Self.gridTime(t, tl), rate: rate, scale: scale, misses: [])
    }

    private func prefetch(timeline tl: Timeline, at t: Time, rate: PlaybackRate, scale: DecodeScale, misses: [(UUID, Int)]) {
        let (ids, mapping) = state.withLock { ($0.mediaIDs, $0.mapping) }
        var indexes: [UUID: SampleIndex] = [:]
        for id in ids where !media.isDamaged(id) { if let d = media.demuxer(id) { indexes[id] = d.index } }
        let cache = self.cache
        var jobs = planner.jobs(timeline: tl, playhead: t, rate: rate, indexes: indexes) { m, i in
            guard let idx = indexes[m], i < idx.count else { return true }
            return cache.frame(FrameKey(media: m, pts: idx.entries[i].pts, scale: scale)) != nil
        }
        // Misses the planner does not see (nested sequences): their GOP goes first.
        var urgent: [Job] = []
        for (m, f) in misses where !media.isDamaged(m) {
            guard let idx = media.demuxer(m)?.index else { continue }
            let gop = idx.gop(containing: f)
            if !jobs.contains(where: { $0.media == m && $0.frames == gop }) && !urgent.contains(where: { $0.media == m && $0.frames == gop }) {
                urgent.append(Job(media: m, frames: gop, priority: urgent.count))
            }
        }
        if !urgent.isEmpty {
            jobs = urgent + jobs.map { Job(media: $0.media, frames: $0.frames, priority: $0.priority + urgent.count) }
        }
        cache.setFocus(playhead: t, direction: rate.isPaused ? 0 : (rate.isReverse ? -1 : 1), mapping: mapping)
        let scheduler: DecodeScheduler? = state.withLock { s in
            guard s.schedulerScale == scale, s.lastJobs != jobs else { return nil }
            s.lastJobs = jobs
            return s.scheduler
        }
        if let scheduler { post(jobs, to: scheduler) }
    }

    // MARK: Timeline helpers

    static func mediaIDs(_ tl: Timeline, sequences: [Timeline.ID: Timeline]) -> [UUID] {
        var out = Set<UUID>()
        var visited = Set<Timeline.ID>()
        func walk(_ t: Timeline) {
            guard visited.insert(t.id).inserted else { return }
            for track in t.tracks where track.kind == .video {
                for c in track.clips where !c.isGenerator {
                    if let s = c.sequence { if let inner = sequences[s] { walk(inner) } } else { out.insert(c.media) }
                }
            }
        }
        walk(tl)
        return Array(out)
    }

    /// FrameKey -> top-level timeline time of the first clip showing that source frame (eviction distance).
    static func mapping(_ tl: Timeline) -> Mapping {
        let clips = tl.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { !$0.isNested && !$0.isGenerator }
        let byMedia = Dictionary(grouping: clips, by: \.media)
        return { key in
            guard let cs = byMedia[key.media] else { return nil }
            for c in cs where c.source.contains(key.pts) { return c.start + (key.pts - c.source.start) }
            return nil
        }
    }

    // MARK: Main-actor reporting (render thread)

    /// Stores the outcome; returns true when the caller must schedule a main-actor hop (none pending yet).
    func publish(_ o: TickOutcome) -> Bool {
        state.withLock { s in
            s.lastOutcome = o
            if s.reportPending { return false }
            s.reportPending = true
            return true
        }
    }

    func takeOutcome() -> TickOutcome? {
        state.withLock { s in s.reportPending = false; defer { s.lastOutcome = nil }; return s.lastOutcome }
    }
}

/// Drives `RenderLoop` from a `CAMetalDisplayLink` on a dedicated render thread while a layer is attached.
final class DisplayLinkDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private struct LayerBox: @unchecked Sendable { let layer: CAMetalLayer }
    private let onTick: @Sendable (CAMetalDrawable) -> Void
    private let stopped = Mutex(false)

    init(layer: CAMetalLayer, onTick: @escaping @Sendable (CAMetalDrawable) -> Void) {
        self.onTick = onTick
        super.init()
        let box = LayerBox(layer: layer)
        let thread = Thread { [self] in
            let link = CAMetalDisplayLink(metalLayer: box.layer)
            link.delegate = self
            link.add(to: .current, forMode: .default)
            while !stopped.withLock({ $0 }) {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            link.invalidate()
        }
        thread.name = "SSPlayback.render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { stopped.withLock { $0 = true } }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        onTick(update.drawable)
    }
}
