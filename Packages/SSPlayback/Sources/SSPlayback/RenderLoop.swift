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
    private enum Entry: Sendable { case ready(any Demuxing), still(StillFrame), offline }
    private struct State { var entries: [UUID: Entry] = [:]; var info: [UUID: VideoTrackInfo] = [:]; var damaged: [UUID: [ClosedRange<Int>]] = [:] }
    private let state = Mutex(State())
    let resolver: any MediaResolver

    init(resolver: any MediaResolver) { self.resolver = resolver }

    /// Resolved once per media and remembered (offline too, until `forgetOffline`). A still image is asked first.
    private func entry(_ media: UUID) -> Entry {
        if let e = state.withLock({ $0.entries[media] }) { return e }
        let e: Entry
        if let still = try? resolver.stillFrame(for: media) { e = .still(still) }
        else if let d = try? resolver.demuxer(for: media) { e = .ready(d) }
        else { e = .offline }
        return state.withLock { s in
            if let old = s.entries[media] { return old }
            s.entries[media] = e; return e
        }
    }

    func demuxer(_ media: UUID) -> (any Demuxing)? {
        if case .ready(let d) = entry(media) { return d }
        return nil
    }

    /// The decoded picture when `media` is a still image.
    func still(_ media: UUID) -> StillFrame? {
        if case .still(let f) = entry(media) { return f }
        return nil
    }

    /// Already resolved demuxer only; never calls the resolver (safe on the main actor).
    func resolvedDemuxer(_ media: UUID) -> (any Demuxing)? {
        if case .ready(let d)? = state.withLock({ $0.entries[media] }) { return d }
        return nil
    }

    /// True once resolved and unusable; a still counts as resolved (nothing to decode ahead).
    func isKnownOffline(_ media: UUID) -> Bool {
        switch state.withLock({ $0.entries[media] }) {
        case .offline?, .still?: return true
        default: return false
        }
    }

    func clearDamaged() { state.withLock { $0.damaged.removeAll() } }

    /// Forgets offline and still entries (stills re-ask the caching resolver, so a relink shows the new picture).
    func forgetOffline() {
        state.withLock { s in s.entries = s.entries.filter { if case .ready = $0.value { true } else { false } } }
    }

    func setInfo(_ info: VideoTrackInfo, for media: UUID) { state.withLock { $0.info[media] = info } }
    func info(_ media: UUID) -> VideoTrackInfo? { state.withLock { $0.info[media] } }
    /// A failed decode job damages its frames (one GOP), not the whole media: earlier/later good GOPs keep playing.
    func markDamaged(_ media: UUID, frames: ClosedRange<Int>) { state.withLock { $0.damaged[media, default: []].append(frames) } }
    func isDamaged(_ media: UUID, frame: Int) -> Bool {
        state.withLock { $0.damaged[media]?.contains { $0.contains(frame) } ?? false }
    }
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
        /// Bumped by every invalidator; a tick renders when it differs from `renderedGeneration` and records the
        /// generation it snapshotted, so an invalidation that lands during a tick is never lost.
        var generation: UInt64 = 1
        var renderedGeneration: UInt64 = 0
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
        /// Zoom of the last composite handed to the present path (headless too; test hook).
        var lastPresentedZoom: ViewerZoom?
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
        // A background colour build finished: redraw with the new pipeline.
        resolver.colorResolver?.setOnWarmed { [weak self] in self?.invalidate() }
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
            onError: { [weak self] job, _ in self?.decodeFailed(job) })
    }

    /// Every decoded frame of a job is kept (a random access decodes the whole GOP: stepping back through it is free).
    private func store(_ frames: [DecodedFrame], scale: DecodeScale) {
        for f in frames { cache.insert(f, for: FrameKey(media: f.media, pts: f.pts, scale: scale)) }
    }

    private func decodeFailed(_ job: Job) {
        media.markDamaged(job.media, frames: job.frames)
        state.withLock { $0.generation &+= 1 }
    }

    /// Posts `jobs` to the scheduler in call order (last wins), without blocking the caller.
    private func post(_ jobs: [Job], to scheduler: DecodeScheduler) {
        submitChain.withLock { last in
            let prev = last
            last = Task { await prev?.value; await scheduler.submit(jobs) }
        }
    }

    /// Clears the scheduler's failed-job memory, ordered with the submissions.
    private func post(reset scheduler: DecodeScheduler) {
        submitChain.withLock { last in
            let prev = last
            last = Task { await prev?.value; await scheduler.resetFailures() }
        }
    }

    /// Suspends until every posted submission reached the scheduler and nothing is queued or decoding.
    func waitForDecodes() async {
        await media.resolver.colorResolver?.waitUntilIdle()
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
            s.generation &+= 1
            s.lastJobs = []
        }
        // Colour pipelines (LUT reads) are built off the render thread, now, so the first frame rarely waits.
        if let colors = media.resolver.colorResolver { colors.warm(Self.colorLayers(timeline, sequences: sequences)) }
        // Edits may have fixed a damaged/relinked media: forget damage marks and failed jobs.
        media.clearDamaged()
        if let s = state.withLock({ $0.scheduler }) { post(reset: s) }
    }

    func setQuality(_ q: DecodeScale) {
        guard state.withLock({ $0.schedulerScale != q }) else { return }
        let new = makeScheduler(q)
        let old: DecodeScheduler? = state.withLock { s in
            guard s.schedulerScale != q else { return nil }
            let old = s.scheduler
            s.scheduler = new; s.quality = q; s.schedulerScale = q; s.generation &+= 1; s.lastJobs = []
            return old
        }
        if let old { Task { await old.cancelAll() } }
    }

    /// Viewer zoom for the present path. A change re-presents the current frame (from the cache, no decode).
    func setZoom(_ z: ViewerZoom) {
        state.withLock { s in
            guard s.zoom != z else { return }
            s.zoom = z; s.generation &+= 1
        }
    }

    var lastPresentedZoom: ViewerZoom? { state.withLock { $0.lastPresentedZoom } }

    func setPresenter(_ p: Presenter?) { state.withLock { $0.presenter = p; $0.generation &+= 1 } }

    func invalidate() { state.withLock { $0.generation &+= 1 } }

    func beginStep(target: Time) {
        state.withLock { $0.pendingStep = (target, ContinuousClock.now); $0.generation &+= 1 }
    }

    /// Handed off under its own short lock after each render (never waits on the GPU lock).
    private let lastTexture = Mutex<RenderedTexture?>(nil)
    var lastRendered: RenderedTexture? { lastTexture.withLock { $0 } }

    var stats: PlaybackStats {
        var s = state.withLock { $0.stats }
        s.cacheBytes = cache.usedBytes
        s.renderTicks = timing.withLock { $0.ticks }
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
        let start = ContinuousClock.now
        let o = gpu.withLock { g in tickLocked(&g, drawable: drawable) }
        let dt = ContinuousClock.now - start
        timing.withLock { t in
            t.ticks += 1; t.total += dt
            if o?.presented == true { t.presents += 1; t.presentTotal += dt }
        }
        return o
    }

    /// Render-loop iteration counts and wall time (bench / diagnostics; driver ticks included).
    struct TickTiming: Sendable { var ticks = 0; var total = Duration.zero; var presents = 0; var presentTotal = Duration.zero }
    let timing = Mutex(TickTiming())

    private struct LayerBuild { var layers: [RenderLayer] = []; var missing = 0; var waiting = false; var misses: [(UUID, Int)] = [] }

    private func tickLocked(_ g: inout GPU, drawable: CAMetalDrawable?) -> TickOutcome? {
        let now = clock.now()
        let rate = clock.rate
        let snap = state.withLock { s in
            (s.timeline, s.sequences, s.quality, s.zoom, s.generation, s.renderedGeneration != s.generation,
             s.incomplete, s.lastTime, s.presenter, s.pendingStep != nil)
        }
        guard let tl = snap.0 else { return nil }
        let (sequences, scale, zoom, generation, invalidated, incomplete, lastTime, presenter, stepPending) =
            (snap.1, snap.2, snap.3, snap.4, snap.5, snap.6, snap.7, snap.8, snap.9)
        let fd = tl.format.frameDuration
        let last = Self.lastFrame(tl)
        var t = Self.gridTime(now, tl)
        var edge = false
        // The audio clock never goes below 0 in reverse (the feeder stops producing at frame 0): stop inside frame 0.
        let audioMaster = (clock as? SwitchingClock)?.isAudio ?? (clock is AudioClock)
        if (rate.isForward && now >= last + fd) || (rate.isReverse && (now.isNegative || (audioMaster && now < fd))) {
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
            if presented { lastTexture.withLock { $0 = RenderedTexture(texture: target) } }
        }

        let isNew = t != lastTime
        let playing = !rate.isPaused && !edge
        // A/V drift: audio clock after the composite vs the frame just presented.
        var drift = Time.zero
        if presented && playing && audioMaster {
            let d = clock.now() - t
            drift = d.isNegative ? -d : d
        }
        state.withLock { s in
            if drift > s.stats.maxAVDrift { s.stats.maxAVDrift = drift }
            s.renderedGeneration = generation
            s.incomplete = b.waiting
            guard presented else { return }
            s.lastTime = t
            s.lastPresentedZoom = zoom
            s.stats.presentedFrames += 1
            // A drop is a playing frame shown without its exact picture; a paused seek/step waiting for decode is not.
            if isNew && b.missing > 0 && playing && !stepPending { s.stats.droppedFrames += 1 }
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
        if let still = media.still(r.media) {
            return RenderLayer(content: .frame(still.buffer, colorHint: still.info), transform: r.transform,
                               colorPipeline: media.resolver.colorResolver?.pipeline(for: r.color, media: r.media),
                               cornerRadius: r.cornerRadius)
        }
        guard let d = media.demuxer(r.media) else { return placeholder(.offline) }
        let index = d.index
        guard index.count > 0 else { return placeholder(.damaged) }
        let f = Self.frameIndex(r.sourceTime, in: index)
        let key = FrameKey(media: r.media, pts: index.entries[f].pts, scale: scale)
        var frame = cache.frame(key)
        if frame == nil {
            if media.isDamaged(r.media, frame: f) { return placeholder(.damaged) }
            b.missing += 1; b.waiting = true; b.misses.append((r.media, f))
            frame = cache.nearest(media: r.media, atOrBefore: key.pts, scale: scale)
        }
        guard let frame else { return placeholder(.loading) }
        let info = media.info(r.media) ?? VideoTrackInfo(
            width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer),
            codec: "", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: frame.duration, isVariableFrameRate: false)
        return RenderLayer(content: .frame(frame.pixelBuffer, colorHint: info), transform: r.transform,
                           colorPipeline: media.resolver.colorResolver?.pipeline(for: r.color, media: r.media),
                           cornerRadius: r.cornerRadius)
    }

    /// Frame showing `sourceTime`; before the first frame -> 0, at/after the end -> last. Requires a non-empty index.
    static func frameIndex(_ sourceTime: Time, in index: SampleIndex) -> Int {
        if let f = index.frame(at: sourceTime) { return f }
        return sourceTime < index.entries[0].pts ? 0 : index.count - 1
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
    /// Main-actor entry. Never calls the resolver on the caller's thread: when every media is already resolved the
    /// window is planned right here; otherwise resolving + planning run on `resolveQueue` (ordered in the submit chain,
    /// so `waitForDecodes` covers it).
    func prefetch(at t: Time, rate: PlaybackRate) {
        guard let (tl, scale, ids) = state.withLock({ s in s.timeline.map { ($0, s.quality, s.mediaIDs) } }) else { return }
        let at = Self.gridTime(t, tl)
        if ids.allSatisfy({ media.resolvedDemuxer($0) != nil || media.isKnownOffline($0) }) {
            prefetch(timeline: tl, at: at, rate: rate, scale: scale, misses: [], resolve: false)
            return
        }
        let queue = resolveQueue
        submitChain.withLock { last in
            let prev = last
            last = Task { [weak self] in
                await prev?.value
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    queue.async {
                        self?.prefetch(timeline: tl, at: at, rate: rate, scale: scale, misses: [], resolve: true)
                        c.resume()
                    }
                }
            }
        }
    }

    /// Resolver calls requested from the main actor run here (may block on opening an asset).
    private let resolveQueue = DispatchQueue(label: "SSPlayback.resolve", qos: .userInitiated)

    private func prefetch(timeline tl: Timeline, at t: Time, rate: PlaybackRate, scale: DecodeScale, misses: [(UUID, Int)],
                          resolve: Bool = true) {
        let (ids, mapping) = state.withLock { ($0.mediaIDs, $0.mapping) }
        var indexes: [UUID: SampleIndex] = [:]
        for id in ids {
            if let d = resolve ? media.demuxer(id) : media.resolvedDemuxer(id) { indexes[id] = d.index }
        }
        let cache = self.cache
        var jobs = planner.jobs(timeline: tl, playhead: t, rate: rate, indexes: indexes) { m, i in
            guard let idx = indexes[m], i < idx.count else { return true }
            return cache.frame(FrameKey(media: m, pts: idx.entries[i].pts, scale: scale)) != nil
        }
        // Misses the planner does not see (nested sequences): their GOP goes first.
        var urgent: [Job] = []
        for (m, f) in misses where !media.isDamaged(m, frame: f) {
            guard let idx = media.resolvedDemuxer(m)?.index else { continue }
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

    /// Every (clip colour, media) of the picture clips, nested sequences included.
    static func colorLayers(_ tl: Timeline, sequences: [Timeline.ID: Timeline]) -> [(color: ClipColor, media: UUID)] {
        var out: [(color: ClipColor, media: UUID)] = []
        var visited = Set<Timeline.ID>()
        func walk(_ t: Timeline) {
            guard visited.insert(t.id).inserted else { return }
            for track in t.tracks where track.kind == .video {
                for c in track.clips where !c.isGenerator {
                    if let s = c.sequence { if let inner = sequences[s] { walk(inner) } } else { out.append((c.color, c.media)) }
                }
            }
        }
        walk(tl)
        return out
    }

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

    /// Merges the outcome into the pending report (presented/stoppedAtEdge are OR-ed, time is the latest presented
    /// one); ticks that neither presented nor stopped are ignored. Returns true when the caller must schedule a
    /// main-actor hop (none pending yet).
    func publish(_ o: TickOutcome) -> Bool {
        guard o.presented || o.stoppedAtEdge else { return false }
        return state.withLock { s in
            if var m = s.lastOutcome {
                if o.presented { m.time = o.time; m.presented = true }
                m.stoppedAtEdge = m.stoppedAtEdge || o.stoppedAtEdge
                s.lastOutcome = m
            } else {
                s.lastOutcome = o
            }
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
/// `stop()` takes effect promptly (CFRunLoopStop) and drops the tick closure, so nothing keeps the loop alive.
final class DisplayLinkDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private struct LayerBox: @unchecked Sendable { let layer: CAMetalLayer }
    private struct RunLoopBox: @unchecked Sendable { let runLoop: CFRunLoop }
    private struct State {
        var stopped = false
        var runLoop: RunLoopBox?
        var onTick: (@Sendable (CAMetalDrawable) -> Void)?
    }
    private let state: Mutex<State>

    init(layer: CAMetalLayer, onTick: @escaping @Sendable (CAMetalDrawable) -> Void) {
        state = Mutex(State(onTick: onTick))
        super.init()
        let box = LayerBox(layer: layer)
        let thread = Thread { [self] in
            let link = CAMetalDisplayLink(metalLayer: box.layer)
            link.delegate = self
            link.add(to: .current, forMode: .default)
            state.withLock { $0.runLoop = RunLoopBox(runLoop: CFRunLoopGetCurrent()) }
            while !state.withLock({ $0.stopped }) {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            link.invalidate()
            state.withLock { $0.runLoop = nil }
        }
        thread.name = "SSPlayback.render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        let rl = state.withLock { s -> RunLoopBox? in
            s.stopped = true; s.onTick = nil
            return s.runLoop
        }
        if let rl { CFRunLoopStop(rl.runLoop); CFRunLoopWakeUp(rl.runLoop) }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        state.withLock { $0.onTick }?(update.drawable)
    }
}
