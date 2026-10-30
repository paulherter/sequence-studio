import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Synchronization
import os
import SQAnalysis
import SQCore
import SQFrame
import SQFrameCoreVideo
import SQMedia
import SQLottie
import SQRender
import SQText

/// Opened media shared by the render thread and the decode threads: demuxer (for the `SampleIndex`), track info
/// (color hint, known once a decoder exists) and the damaged flag set by decode errors.
final class MediaTable: Sendable {
    private enum Entry: Sendable { case ready(any Demuxing), still(StillFrame), offline }
    private struct State { var entries: [UUID: Entry] = [:]; var info: [UUID: VideoTrackInfo] = [:]; var damaged: [UUID: [ClosedRange<Int>]] = [:]
        /// Bumped by `forget`: work that began under an older epoch (a resolve, a decode) must not store its result.
        var epochs: [UUID: Int] = [:]
        /// W9.9: original -> key of its proxy, and back. A proxy is its own "media" for the cache, the decoders, epochs and
        /// damage marks (proxy and original frames never mix); it is resolved through `MediaResolver.proxyDemuxer`.
        var proxyIDs: [UUID: UUID] = [:]
        var origins: [UUID: UUID] = [:]
        /// F7.3: the pixel aspect the project shows each resolved media with (read once with the resolve, off the render
        /// thread; `forget` drops it). Media the project has no info for is square.
        var shapes: [UUID: PixelAspect] = [:] }
    private let state = Mutex(State())
    private let gates = Mutex<[UUID: NSLock]>([:])
    let resolver: any MediaResolver

    /// What is known about a media without asking the resolver (the render thread must never block on an open).
    enum Known { case unresolved, offline, still(StillFrame), ready(any Demuxing) }

    func known(_ media: UUID) -> Known {
        switch state.withLock({ $0.entries[media] }) {
        case nil: .unresolved
        case .offline?: .offline
        case .still(let f)?: .still(f)
        case .ready(let d)?: .ready(d)
        }
    }

    /// Resolves `media` now (may block on opening an asset): background queues only.
    func resolve(_ media: UUID) { _ = entry(media) }

    /// Forgets everything about these media (relinked to other files), their proxies included: the next use resolves them
    /// again. Returns every key forgotten (the media and their proxy keys).
    @discardableResult
    func forget(_ ids: Set<UUID>) -> Set<UUID> {
        state.withLock { s in
            var all = ids
            for id in ids { if let p = s.proxyIDs[id] { all.insert(p) } }
            for id in all { s.entries[id] = nil; s.info[id] = nil; s.shapes[id] = nil; s.damaged[id] = nil; s.epochs[id, default: 0] += 1 }
            return all
        }
    }

    /// Key of `media`'s proxy (created on first use, stable for the table's life).
    func proxyID(for media: UUID) -> UUID {
        state.withLock { s in
            if let p = s.proxyIDs[media] { return p }
            let p = UUID()
            s.proxyIDs[media] = p; s.origins[p] = media
            return p
        }
    }

    func existingProxyID(for media: UUID) -> UUID? { state.withLock { $0.proxyIDs[media] } }

    /// Proxy key -> original media.
    var origins: [UUID: UUID] { state.withLock { $0.origins } }
    func origin(of proxy: UUID) -> UUID? { state.withLock { $0.origins[proxy] } }

    func epoch(_ media: UUID) -> Int { state.withLock { $0.epochs[media] ?? 0 } }

    /// Field order `media`'s decoder deinterlaces with (the media item's setting). nil for progressive media, an item
    /// with Deinterlace off, and every proxy: a proxy of interlaced media is written deinterlaced (`ProxyTranscoder`).
    func deinterlace(_ media: UUID) -> FieldOrder? {
        guard origin(of: media) == nil else { return nil }
        return resolver.colorResolver?.info(of: media)?.video?.deinterlaceFieldOrder
    }

    /// Interlaced media whose Deinterlace is off shows its stored fields: its (deinterlaced) proxy is not that picture.
    func keepsFields(_ media: UUID) -> Bool {
        guard let v = resolver.colorResolver?.info(of: media)?.video else { return false }
        return v.isInterlaced && v.deinterlaceOff
    }

    init(resolver: any MediaResolver) { self.resolver = resolver }

    /// Resolved once per media and remembered (offline too, until `forgetOffline`). A still image is asked first.
    private func entry(_ media: UUID) -> Entry {
        if let e = state.withLock({ $0.entries[media] }) { return e }
        // One resolution per media at a time: a second caller waits and then reads the first one's result (no double open).
        let gate = gates.withLock { g in
            if let l = g[media] { return l }
            let l = NSLock(); g[media] = l; return l
        }
        gate.lock(); defer { gate.unlock() }
        while true {
            if let e = state.withLock({ $0.entries[media] }) { return e }
            let epoch = self.epoch(media)
            var e: Entry
            var shape: PixelAspect?
            if let origin = state.withLock({ $0.origins[media] }) {
                e = (try? resolver.proxyDemuxer(for: origin)).map { .ready($0) } ?? .offline
            } else if let still = try? resolver.stillFrame(for: media) { e = .still(still) }
            else if let d = try? resolver.demuxer(for: media) { e = .ready(d) }
            else { e = .offline }
            if state.withLock({ $0.origins[media] }) == nil {
                let s = resolver.colorResolver?.info(of: media)?.video?.displayPixelAspect ?? .square
                shape = s
                if case .still(var f) = e { f.info.pixelAspect = s; f.info.pixelAspectOverride = nil; e = .still(f) }
            }
            // A relink that landed while this open ran: the result is for the old file, open again.
            let stored: Entry? = state.withLock { s in
                guard (s.epochs[media] ?? 0) == epoch else { return nil }
                if let old = s.entries[media] { return old }
                s.entries[media] = e
                if let shape { s.shapes[media] = shape }
                return e
            }
            if let stored { return stored }
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

    func setInfo(_ info: VideoTrackInfo, for media: UUID, epoch: Int? = nil) {
        state.withLock { s in
            if let epoch, (s.epochs[media] ?? 0) != epoch { return }
            s.info[media] = info
        }
    }
    func info(_ media: UUID) -> VideoTrackInfo? { state.withLock { $0.info[media] } }
    /// One lock for a layer: the decoder's info of the frame's key (the media or its proxy), of the original, and the
    /// pixel aspect the project shows the original with.
    func layerInfo(frame key: UUID, of media: UUID) -> (frame: VideoTrackInfo?, original: VideoTrackInfo?, shape: PixelAspect) {
        state.withLock { ($0.info[key], key == media ? nil : $0.info[media], $0.shapes[media] ?? .square) }
    }
    /// A failed decode job damages its frames (one GOP), not the whole media: earlier/later good GOPs keep playing.
    func markDamaged(_ media: UUID, frames: ClosedRange<Int>) { state.withLock { $0.damaged[media, default: []].append(frames) } }
    func isDamaged(_ media: UUID, frame: Int) -> Bool {
        state.withLock { $0.damaged[media]?.contains { $0.contains(frame) } ?? false }
    }
}

/// Counts `decode` calls (tests: "served from cache" = no decode) and forwards to the real decoder. Keeps only the last
/// `keep` requested ranges (it runs in production too).
final class DecodeCounter: Sendable {
    static let keep = 64
    private let n = Mutex<(total: Int, recent: [ClosedRange<Int>])>((0, []))
    func record(_ r: ClosedRange<Int>) {
        n.withLock { s in
            s.total += 1; s.recent.append(r)
            if s.recent.count > Self.keep { s.recent.removeFirst(s.recent.count - Self.keep) }
        }
    }
    var value: Int { n.withLock { $0.total } }
    /// The kept ranges in call order (tests).
    var ranges: [ClosedRange<Int>] { n.withLock { $0.recent } }
    /// Ranges of call number `since` (0-based) and later that are still kept.
    func ranges(since: Int) -> [ClosedRange<Int>] {
        n.withLock { s in
            let first = s.total - s.recent.count
            return Array(s.recent.dropFirst(max(0, since - first)))
        }
    }
}

/// Frame shown at each clip's in point, by clip id (`RenderLoop.placements`).
final class InPointFrames: Sendable {
    let frames = Mutex<[UUID: Time]>([:])
}

struct CountingDecoder: VideoDecoding {
    let inner: any VideoDecoding
    let counter: DecodeCounter
    var info: VideoTrackInfo { inner.info }
    var isHardware: Bool { inner.isHardware }
    func invalidate() { inner.invalidate() }
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        counter.record(range)
        return try await inner.decode(range)
    }
    func decode(_ range: ClosedRange<Int>, deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        counter.record(range)
        return try await inner.decode(range, deliver: deliver)
    }
    func decode(_ range: ClosedRange<Int>, neededFrom: Int?,
                deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        counter.record(range)
        return try await inner.decode(range, neededFrom: neededFrom, deliver: deliver)
    }
}

/// Drops the frames of a decode that ran for a file the media has since been relinked away from.
struct EpochDecoder: VideoDecoding {
    let inner: any VideoDecoding
    let media: MediaTable
    let id: UUID
    let epoch: Int
    var info: VideoTrackInfo { inner.info }
    var isHardware: Bool { inner.isHardware }
    func invalidate() { inner.invalidate() }
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        let frames = try await inner.decode(range)
        return media.epoch(id) == epoch ? frames : []
    }
    func decode(_ range: ClosedRange<Int>, deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        let (media, id, epoch) = (self.media, self.id, self.epoch)
        let frames = try await inner.decode(range, deliver: { f in if media.epoch(id) == epoch { deliver(f) } })
        return media.epoch(id) == epoch ? frames : []
    }
    func decode(_ range: ClosedRange<Int>, neededFrom: Int?,
                deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        let (media, id, epoch) = (self.media, self.id, self.epoch)
        let frames = try await inner.decode(range, neededFrom: neededFrom, deliver: { f in if media.epoch(id) == epoch { deliver(f) } })
        return media.epoch(id) == epoch ? frames : []
    }
}

/// Result of one render-loop iteration.
struct TickOutcome: Sendable {
    /// A composite was encoded (and presented when a layer is attached).
    var presented: Bool
    /// Frame picked by this iteration (snapped to the sequence frame grid). While playing through a display link it
    /// leads the clock by the display lead (`DisplayLead`).
    var time: Time
    /// Playback ran past the timeline's first/last frame; the clock was stopped there.
    var stoppedAtEdge: Bool
    /// The clock's frame: what the host is told (playhead, timecode). Equal to `time` unless the picture leads.
    var position: Time
    /// The clock as read by this iteration, not snapped (diagnostics, `PresentProbe`).
    var clock: Time
    /// The clock was running: `position` is reported to the host even when this iteration presented nothing (the picked
    /// frame holds at an end while the clock still walks up to it).
    var playing: Bool
    /// `RenderLoop.clockSerial` when this iteration began: a report from before a pause, seek or play is dropped.
    var serial: UInt64 = 0

    init(presented: Bool, time: Time, stoppedAtEdge: Bool, position: Time? = nil, clock: Time? = nil, playing: Bool = false) {
        self.presented = presented; self.time = time; self.stoppedAtEdge = stoppedAtEdge
        self.position = position ?? time; self.clock = clock ?? time; self.playing = playing
    }
}

/// Immutable-after-creation texture handle for crossing threads (§8).
public struct RenderedTexture: @unchecked Sendable {
    public let texture: MTLTexture
}

/// A readback of the finished composite, encoded by the render loop itself. `encode` runs on the loop's command buffer,
/// right after the composite was encoded (so it sees exactly that frame and cannot race the next one), and returns the
/// completion to call once the command buffer finished (on a Metal thread), or nil to skip.
public typealias FrameCaptureEncoder = @Sendable (_ frame: MTLTexture, _ commandBuffer: MTLCommandBuffer) -> (@Sendable () -> Void)?

/// One render-loop iteration per display tick (render thread) or per `tick()` call (tests, bench).
///
/// Per tick: `t = clock.now()` (plus the display lead while playing through a display link, `DisplayLead`) floored to
/// the sequence frame grid (clamped to the timeline) -> unchanged and not
/// invalidated and nothing still loading: present nothing -> `videoLayers(at:)` -> source time -> frame through the
/// media's `SampleIndex` -> `FrameKey(media, pts, scale)` -> cache hit, or on a miss the nearest earlier cached frame
/// (a drop, and the GOP is requested), or a `.loading` placeholder -> `RenderNode.tree` -> `Compositor.render` into an
/// rgba16Float texture -> `Presenter` when a layer is attached (headless: the texture is kept as `lastRendered` and the
/// command buffer is waited on). Then the prefetch window is planned and submitted.
final class RenderLoop: @unchecked Sendable {
    typealias Job = PrefetchPlanner.Job
    typealias Mapping = FrameCache<DecodedFrame>.Mapping
    typealias Placements = FrameCache<DecodedFrame>.Placements

    struct RenderState {
        var timeline: Timeline?
        var sequences: [Timeline.ID: Timeline] = [:]
        /// Bumped with every `setTimeline` (timeline + sequences): names the prefetch memo's entries (`PlanSourceMemo`).
        var timelineEpoch: UInt64 = 0
        var mediaIDs: [UUID] = []
        /// F7.16: the angles the Angles pieces do not show (`standbyMediaIDs`): opened after `mediaIDs`, never planned.
        var standbyIDs: [UUID] = []
        var clipDurations: [Clip.ID: Time] = [:]
        /// The timeline's caption tracks prepared for `captionNodes` (made with every `setTimeline`: checking a track's
        /// order is one pass over its captions, too much for every tick of a long caption track).
        var captionLookup: CaptionSlotLookup?
        var placements: Placements = { [$0.pts] }
        /// The viewer quality (grading mode); frames are decoded and keyed at `schedulerScale` (smaller on weak Macs).
        var quality: DecodeScale = .full
        /// Export Frame is rendering: Follow measures every text target on the tick (a cold one is laid out there).
        var exactText = false
        /// Weak Macs (`WorkLimits.reducedPreviewDecode`): Full quality decodes previews at half size.
        var reducesFullDecode = WorkLimits.current.reducedPreviewDecode
        var zoom: ViewerZoom = .fit
        /// The last presented composite graded downscaled layers at display size (preview); a settled frame redraws exact.
        var lastPreviewGrade = false
        /// Program monitor setting: draw the captions over the picture (the export burn-in does not depend on it).
        var showCaptions = true
        /// Monitor Transparency Grid: the picture composites over transparent, the presenter shows a checkerboard.
        var transparencyGrid = false
        /// Color page Before / Split: these clips are drawn without their grade (monitor only; nil = graded).
        var colorBypass: ColorBypass?
        /// W8.3: the project's style kit for caption styles (nil = none). The library is derived from it and the registered
        /// looks and cached by `captionLibraryKey`, so two open projects with different kits never share one.
        var captionKit: StyleKit?
        var captionLegacyFont = false
        var captionLibrary: (key: Int, library: CaptionPresetLibrary)?
        /// Bumped by every invalidator; a tick renders when it differs from `renderedGeneration` and records the
        /// generation it snapshotted, so an invalidation that lands during a tick is never lost.
        var generation: UInt64 = 1
        var renderedGeneration: UInt64 = 0
        /// Last composite had a layer without its exact frame (still decoding): re-render until complete.
        var incomplete = false
        /// Consecutive composites that were not presented (see `maxRenderRetries`).
        var renderFailures = 0
        var failureGeneration: UInt64 = 0
        var lastTime: Time?
        /// Since when the picture is held for a layer that has no frame yet (capped, see `holdLimit`).
        var holdStart: (time: Time, since: ContinuousClock.Instant)?
        /// Longest a far seek keeps the old picture while its decode is outstanding.
        var holdLimit: Duration = .seconds(1)
        /// Start gate: play was asked for while the frame at the playhead was not complete. The clock (and audio) stay
        /// held at the playhead until a tick has every layer's exact frame, or `startGateLimit` passed; then it starts at
        /// `rate`. Prefetch plans with `rate` meanwhile (window ahead, not the paused radius).
        var startGate: StartGate?
        var startGateLimit: Duration = .seconds(1)
        /// Bumped for every new gate and every seek while one waits: an open requested for an older token is dropped.
        var gateTokens: UInt64 = 0
        /// The render thread found the gate ready (or the limit passed): the main actor starts the clock
        /// (`takeStartGateOpen`), where play, pause and seek are serialized.
        var pendingOpen: (token: UInt64, at: Time, rate: PlaybackRate)?
        var startGateEnabled = true
        /// The last presented composite had every layer's exact frame.
        var lastComplete = false
        /// The last presented composite drew an offline or damaged placeholder (or the damaged fallback) for a layer.
        var lastUnavailable = false
        /// FB-H2: bumped when the files behind media change (relink, proxy change). A tick that started before keeps the
        /// stand-in map untouched: its frames may come from the old file.
        var sourceEpoch: UInt64 = 0
        /// Layers without any picture in the last presented composite (drawn as placeholders once a hold ran out).
        var lastCold: Set<ShownKey> = []
        /// Clips the last presented composite left out as hidden. Coming out from under their cover they have no recent
        /// picture: only a frame close to the wanted one is drawn (`uncoveredStandInFrames`), else the picture is held.
        var lastHidden: Set<ShownKey> = []
        /// The last seek asked for a time at or past the sequence end (the clock stands on the last frame): while paused
        /// there, nothing is drawn (black), as in every gap.
        var beyondEnd = false
        /// Test hook: runs inside a tick right after its layers are built (simulates an input landing mid-tick).
        var afterLayers: (@Sendable () -> Void)?
        /// FB-H: the scrub gesture rests at this position: render and decode the exact frame (not the keyframe) here.
        var refine: Time?
        /// The scrub gesture's last move in sequence frames (signed, 0 = unknown): the next keyframe that way is prefetched.
        var scrubVelocity = 0
        /// seek/step/scrub call waiting for its frame; `scrub`: made during a scrub gesture (keyframe counts as done).
        var pendingStep: (target: Time, start: ContinuousClock.Instant, scrub: Bool)?
        /// Keyframe-only scrub (W6.6): between `beginScrub` and `endScrub` only sync frames are decoded and shown.
        var scrubbing = false
        /// W9.9: when ready proxies are decoded instead of the originals.
        var proxyUse = ProxyUse.default
        var stats = PlaybackStats()
        var presenter: Presenter?
        var scheduler: DecodeScheduler?
        /// The size frames are really decoded at and keyed by (`FrameKey.scale`): `quality`, or half for a reduced Full.
        var schedulerScale: DecodeScale = .full
        var lastJobs: [Job] = []
        /// Coalesces position reports to the main actor.
        var reportPending = false
        /// The clock frame last handed to `publish` by a playing tick.
        var publishedPosition: Time?
        var lastOutcome: TickOutcome?
        /// Zoom of the last composite handed to the present path (headless too; test hook).
        var lastPresentedZoom: ViewerZoom?
        /// Q-PERF2 rec 3: thermal / Low Power policy (prefetch lookahead; the decode cap is applied by the engine).
        var power = PowerPolicy.normal
        /// Q-PERF2 rec 1: spacing of presented frames while playing (bench stat).
        var pacing = PacingMeter()
        /// Steady play: frame changes midway between ticks (`FramePhaseLock`); reset whenever the clock is not running.
        var phase = FramePhaseLock()
        /// Playing through a display link: the picked frame is the one for the time it is shown (`DisplayLead`).
        var lead = DisplayLead()
        /// A layer is attached (or tests): play starts are timed to the display (`PlayStart`).
        var startsOnDisplay = false
        /// Play was asked for and the clock is still parked on the start position while the display link lays the start
        /// out; the main actor starts the clock (`takePlayStart`). Cleared by the first tick that sees the clock run.
        var preroll: PlayStart?
        var prerollSince = ContinuousClock.now
        /// The main actor took the play start (the clock starts right after).
        var prerollTaken: ContinuousClock.Instant?
        /// The newest frame a playing tick handed to the display (claimed before its composite): where a pause parks.
        /// nil: none since the last pause, seek or play.
        var handed: Time?
    }

    /// Serializes clock control (start, stop, seek) between the main actor and the render thread's loop wrap and edge
    /// stop. Taken before `state`, never inside it or by a caller that holds `state`; never waits on the GPU lock.
    private let clockOps = Mutex(())
    /// Counts the main actor's clock changes (pause, seek, play); changed under `state`. A tick that began before one
    /// does not move the clock, and what it reports is dropped.
    private let clockSerial = Atomic<UInt64>(0)

    /// GPU objects, touched only inside `tick` (the lock serializes ticks from the render thread and from tests).
    private struct GPU: @unchecked Sendable {
        let queue: MTLCommandQueue
        let compositor: Compositor
        var target: MTLTexture?
        /// The ungraded composite of a Color page split (its left half is copied into `target`).
        var splitTarget: MTLTexture?
    }

    let device: MTLDevice
    let clock: any PlaybackClock
    let cache: FrameCache<DecodedFrame>
    let media: MediaTable
    let decodeCounter = DecodeCounter()
    /// W9.8 subject masks: person mattes of decoded frames, segmented off the render tick (never under the GPU lock):
    /// fast while playing or scrubbing, balanced for a settled frame; until a frame's matte lands the clip's last good one
    /// is drawn and the loop redraws when it arrives. Keyed by clip and decoded source (original or proxy).
    let subjects = SubjectMatteScheduler()
    /// Subject mattes precomputed per media in the background (like Magic mattes): a frame found there is drawn without
    /// running Vision; `subjects` only covers frames not done yet. Needs the media's file (`MediaResolver.fileURL`).
    let subjectPrecompute = SubjectMattePrecompute()
    /// `MediaResolver.fileURL` per media (nil = none), asked once per media off the decode path.
    private let subjectFiles = Mutex<[UUID: URL?]>([:])
    /// Tracked Magic mask mattes (the app's cache; tests may hand in their own).
    let magicStore: MagicMatteStore = .shared
    private let magicToken = Mutex<UUID?>(nil)
    let planner = PrefetchPlanner()
    /// Test hook: false shows every text clip and caption with whole-box frames, to compare the picture with the
    /// cropped ones.
    let cropsTextClips = Mutex(true)
    let state: Mutex<RenderState>
    private let gpu: Mutex<GPU>
    private let submitChain = Mutex<Task<Void, Never>?>(nil)

    /// FB-H: the frame each clip showed in the last presented composite (`media` = the clip's media; the frame's own
    /// `media` is the decoded source, original or proxy). The picture a layer falls back to while its frame decodes.
    struct ShownFrame: Sendable { let frame: DecodedFrame; let media: UUID }
    /// FB-H2: a clip inside a nested sequence appears once per instance of that sequence with the same `Clip.ID`: the
    /// nesting path (the enclosing nested clips, outermost first) tells the instances apart.
    /// C6: a Picture matte copy (`matteFor`) is keyed apart from the drawn copy of the same clip, so hiding the drawn copy
    /// under a cover never makes the matte copy "uncovered" (it takes the normal stand-in and never holds the picture).
    struct ShownKey: Hashable, Sendable {
        let clip: Clip.ID; let path: [Clip.ID]; let matte: Track.ID?
        init(_ r: LayerRequest) { clip = r.clip; path = r.groups.map(\.clip); matte = r.matteFor }
    }
    let lastShownByClip = Mutex<[ShownKey: ShownFrame]>([:])

    /// The compositor, for pool trims off the render thread (its pool has its own lock).
    private struct CompositorRef: @unchecked Sendable { let compositor: Compositor }
    private let compositorRef: CompositorRef
    /// Text frames drawn as a part of their whole box so far (tests). Read under the lock the ticks count it under,
    /// so a tick running on the render thread is never read halfway; nothing is added to the per-frame path.
    var partialContentFills: Int { gpu.withLock { $0.compositor.partialContentFills } }
    /// The ones read in place, without a whole picture made first (tests), and the switch back to the whole picture.
    var partialContentDraws: Int { gpu.withLock { $0.compositor.partialContentDraws } }
    func setDrawsContentPartsDirectly(_ on: Bool) { gpu.withLock { $0.compositor.drawsContentPartsDirectly = on } }
    private let pressure: any MemoryPressureSource
    /// Q-PERF2 rec 5: free intermediates kept under a memory-pressure warning and after a long idle.
    static let trimmedPoolBytes = 256 << 20
    /// How long the loop stays idle (link paused) before the pool is trimmed.
    var idleTrimDelay: Duration = .seconds(10)
    /// Trims the compositor's free pool to at most the given bytes (tests record the calls instead).
    var trimPool: @Sendable (Int) -> Void = { _ in }

    init(device: MTLDevice, resolver: any MediaResolver, clock: any PlaybackClock, cache: FrameCache<DecodedFrame>,
         pressure: any MemoryPressureSource = SystemMemoryPressureSource(name: "compositor pool"),
         poolBytes: Int = MemoryBudget.current().intermediatePoolBytes) throws {
        TextGenerator.installFollowMeasure()   // G11: Follow measures text targets during evaluation
        self.device = device; self.clock = clock; self.cache = cache
        self.media = MediaTable(resolver: resolver)
        guard let queue = device.makeCommandQueue() else { throw CompositorError.invalidTarget("no command queue") }
        let compositor = try Compositor(device: device)
        // Free intermediate textures scale with RAM (MemoryBudget): 256 MB on an 8 GB Mac instead of a fixed 1 GB.
        compositor.intermediatePoolByteLimit = poolBytes
        compositor.colorResolver = resolver.colorResolver   // LUTs of masked Color effects
        compositor.remembersPlaneTextures = true      // redraws, text rasters, temporal neighbors, warmed next frames
        compositorRef = CompositorRef(compositor: compositor)
        self.pressure = pressure
        trimPool = { [compositorRef] in compositorRef.compositor.trimIntermediatePool(toBytes: $0) }
        gpu = Mutex(GPU(queue: queue, compositor: compositor, target: nil))
        state = Mutex(RenderState())
        let key = Self.decodeScale(viewer: .full, reducesFull: WorkLimits.current.reducedPreviewDecode)
        let s = makeScheduler(key)
        state.withLock { $0.scheduler = s; $0.schedulerScale = key }
        // A background color build finished: redraw with the new pipeline.
        resolver.colorResolver?.setOnWarmed { [weak self] in self?.invalidate() }
        // A Gyroflow analysis finished: redraw with the stabilized picture.
        resolver.gyroWarper?.engine.addObserver { [weak self] in self?.invalidate() }
        // A person matte landed: redraw with it.
        subjects.setOnReady { [weak self] in self?.invalidate() }
        subjectPrecompute.setOnProgress { [weak self] in self?.invalidate() }
        pressure.start { [weak self] level in self?.handlePressure(level) }
        // G11: a Follow text target laid out in the background (never on this thread): redraw with its box.
        // Only the loop that shows the text wakes (the others have nothing to redraw).
        TextGenerator.addFollowMeasureObserver(self) { [weak self] ref in self?.followTextReady(ref) }
        // Failed text layouts were forgotten (fonts registered): a paused monitor redraws them.
        TextGenerator.addFailedLayoutResetObserver(self) { [weak self] in self?.invalidate() }
        // An Anonymize cover's matte file was read or its grown matte made (never on this thread): redraw with it.
        let token = magicStore.observeReady { [weak self] in self?.invalidate() }
        magicToken.withLock { $0 = token }
    }

    deinit {
        pressure.cancel(); TextGenerator.removeFollowMeasureObserver(self); TextGenerator.removeFailedLayoutResetObserver(self)
        if let t = magicToken.withLock({ $0 }) { magicStore.removeObserver(t) }
    }

    /// A text Follow asked for was laid out: redraw when this loop's timeline shows it.
    private func followTextReady(_ ref: GeneratorRef) {
        let shows = state.withLock { s -> Bool in
            guard let tl = s.timeline else { return false }
            return Self.textRefs(tl, sequences: s.sequences).contains(ref)
        }
        if shows { invalidate() }
    }

    /// Memory pressure: warning keeps `trimmedPoolBytes` of free intermediates, critical none (the frame cache trims itself).
    func handlePressure(_ level: MemoryPressure) {
        switch level {
        case .warning: trimPool(Self.trimmedPoolBytes)
        case .critical: trimPool(0); TextGenerator.clearAnimatedCache()
        case .normal: break
        }
    }

    /// The display link paused (idle): unless anything changes for `idleTrimDelay`, the pool drops to `trimmedPoolBytes`.
    func scheduleIdleTrim() {
        let gen = state.withLock { $0.generation }
        let c = idleTrimDelay.components
        let delay = Double(c.seconds) + Double(c.attoseconds) / 1e18
        let trim = trimPool
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isIdle, self.state.withLock({ $0.generation }) == gen else { return }
            trim(Self.trimmedPoolBytes)
        }
    }


    // MARK: Decode side

    /// The size a viewer quality decodes (and keys) at: weak Macs never decode a preview at full size.
    static func decodeScale(viewer: DecodeScale, reducesFull: Bool) -> DecodeScale {
        reducesFull && viewer == .full ? .half : viewer
    }

    /// `scale`: the size originals are decoded at, and every frame's key. A proxy is decoded at what is left of that
    /// reduction (a half proxy keyed half is decoded as is), so its frames, too, have the size their key names, and the
    /// scheduler depends on the key alone (a viewer change with the same key keeps it).
    private func makeScheduler(_ scale: DecodeScale) -> DecodeScheduler {
        let media = self.media, counter = decodeCounter
        let limits = WorkLimits.current
        return DecodeScheduler(
            maxConcurrent: limits.previewDecodeJobs,
            // Two clips of one file at different source positions decode side by side (PLAYBACK-PERF "second decoder").
            lanesPerMedia: 2,
            idleDecoders: MemoryBudget.current().idleDecoders,
            maxSoftwareDecoders: limits.softwareDecoderSessions,
            decoder: { id in
                let epoch = media.epoch(id)
                guard let d = media.demuxer(id) else { throw MediaResolverError.unknownMedia(id) }
                // A proxy is already reduced: only the rest of the viewer's reduction is decoded (half proxy at half = full).
                var s = scale
                if let origin = media.origin(of: id), let o = media.demuxer(origin) {
                    let ow = Int(CMVideoFormatDescriptionGetDimensions(o.formatDescription).width)
                    let pw = Int(CMVideoFormatDescriptionGetDimensions(d.formatDescription).width)
                    s = Self.decodeScale(scale, proxyDivisor: Self.proxyDivisor(originalWidth: ow, proxyWidth: pw))
                }
                // Interlaced media is deinterlaced right after decode: the decoder reads every line (fields need them)
                // and hands out the picture at the size `s` names, so these frames, too, have the size of their key.
                let dec = try makeVideoDecoder(demuxer: d, media: id, scale: s, deinterlace: media.deinterlace(id))
                media.setInfo(dec.info, for: id, epoch: epoch)
                return EpochDecoder(inner: CountingDecoder(inner: dec, counter: counter), media: media, id: id, epoch: epoch)
            },
            sink: { [weak self] _, frames in self?.store(frames, scale: scale) },
            onError: { [weak self] job, _ in self?.decodeFailed(job) })
    }

    /// Every decoded frame of a job is kept (a random access decodes the whole GOP: stepping back through it is free).
    private func store(_ frames: [DecodedFrame], scale: DecodeScale) {
        for f in frames { cache.insert(f, for: FrameKey(media: f.media, pts: f.pts, scale: scale)) }
        // Hidden layers: whether a source is opaque is known from its first decoded frame, before it is ever drawn.
        if let f = frames.first {
            let id = media.origin(of: f.media) ?? f.media
            if case .ready(let d) = media.known(id) {
                learnOpaque(f.media, Self.opaquePicture(f.pixelBuffer, sourceInfo(of: f, media: id, demuxer: d)), drawn: false)
            }
        }
    }

    // MARK: Hidden layers

    /// Media layers under an opaque picture that fills the canvas are not decoded, graded or drawn (`LayerOcclusion`,
    /// the rule export uses; DECISIONS 2026-10-06). `SQ_PLAYBACK_CULL=0` draws everything (bench A/B).
    let cullsHidden = Atomic<Bool>(ProcessInfo.processInfo.environment["SQ_PLAYBACK_CULL"] != "0")

    /// Decoded sources (an original or its proxy, each under its own id: a proxy need not carry what the original
    /// carries) known to decode to opaque pictures, with the upright size their layer is drawn at. `revision` changes
    /// with the map and with everything else the plan's hidden layers depend on (the prefetch window memo's key).
    private struct OpaqueSources {
        var revision: UInt64 = 0
        var pictures: [UUID: LayerOcclusion.Picture] = [:]
        /// Media a drawn layer has reported (the authority: a decoded frame no longer changes the entry).
        var drawn = Set<UUID>()
    }
    private let opaqueSources = Mutex(OpaqueSources())

    /// `drawn`: from the frame a layer shows right now (always taken); otherwise from a decode, only while unknown.
    private func learnOpaque(_ media: UUID, _ picture: LayerOcclusion.Picture?, drawn: Bool) {
        opaqueSources.withLock { s in
            if drawn { s.drawn.insert(media) } else if s.drawn.contains(media) || s.pictures[media] != nil { return }
            if s.pictures[media] != picture { s.pictures[media] = picture; s.revision &+= 1 }
        }
    }

    private func forgetOpaque() {
        opaqueSources.withLock { s in s.pictures = [:]; s.drawn = []; s.revision &+= 1 }
    }

    /// Something a cover depends on changed (a media opened or went offline, a frame was marked damaged, proxy use):
    /// planned windows are evaluated afresh.
    private func occlusionChanged() {
        opaqueSources.withLock { $0.revision &+= 1 }
    }

    /// How far (source frames) the first picture of a clip that was hidden may be from the wanted frame. Anything
    /// older is not composited: the previous picture is held until the frame is decoded (`shouldHold`).
    static let uncoveredStandInFrames = 3

    /// The opaque picture `LayerOcclusion` may count on for a layer: of the source that is decoded for it right now
    /// (`useProxy`: its proxy when ready). nil while the media is not open, offline, or its frame is damaged: such a
    /// layer is a placeholder that covers nothing, so what lies below it is planned and drawn.
    private func occlusionPicture(_ known: [UUID: LayerOcclusion.Picture], proxy useProxy: Bool)
        -> (LayerRequest) -> LayerOcclusion.Picture? {
        { [self] r in
            guard r.generator == nil, case .ready(let d) = media.known(r.media), d.index.count > 0 else { return nil }
            var src: (id: UUID, demuxer: any Demuxing) = (r.media, d)
            if useProxy, let p = proxy(for: r.media, original: d), p.demuxer.index.count > 0,
               !media.isDamaged(p.id, frame: Self.frameIndex(r.sourceTime, in: p.demuxer.index)) {
                src = p
            }
            guard let picture = known[src.id],
                  !media.isDamaged(src.id, frame: Self.frameIndex(r.sourceTime, in: src.demuxer.index)) else { return nil }
            return picture
        }
    }

    /// The opaque sources for `LayerOcclusion` (empty when hidden layers are drawn too).
    private func knownOpaque() -> (revision: UInt64, pictures: [UUID: LayerOcclusion.Picture]) {
        guard cullsHidden.load(ordering: .relaxed) else { return (0, [:]) }
        return opaqueSources.withLock { ($0.revision, $0.pictures) }
    }

    /// Upright size of an opaque frame (video decoded to bi-planar YCbCr carries no alpha); nil = may be transparent.
    static func opaquePicture(_ pb: CVPixelBuffer, _ info: VideoTrackInfo) -> LayerOcclusion.Picture? {
        guard PixelFormats.info(for: CVPixelBufferGetPixelFormatType(pb))?.layout == .biplanarYCbCr else { return nil }
        return LayerOcclusion.Picture(width: info.displayWidth, height: info.displayHeight)
    }

    /// `all` without the layers nothing can show of (planning: prefetch, start gate, scrub). The tick itself checks
    /// that the cover really is drawn as a picture before it leaves anything out.
    static func visible(_ all: [LayerRequest], canvas: SequenceFormat,
                        picture: (LayerRequest) -> LayerOcclusion.Picture?) -> [LayerRequest] {
        let hidden = LayerOcclusion.evaluate(all, canvas: canvas, picture: picture).hidden
        return hidden.isEmpty ? all : all.indices.filter { !hidden.contains($0) }.map { all[$0] }
    }

    /// Track info of the original `media` for a decoded `frame` of it (or of its proxy). Until the decoder reported
    /// its info: native size and rotation from the demuxer (the buffer may be a reduced decode).
    private func sourceInfo(of frame: DecodedFrame, media id: UUID, demuxer d: any Demuxing) -> VideoTrackInfo {
        let dims = CMVideoFormatDescriptionGetDimensions(d.formatDescription)
        let known = media.layerInfo(frame: frame.media, of: id)
        var info = known.frame ?? VideoTrackInfo(
            width: Int(dims.width), height: Int(dims.height),
            codec: "", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: frame.duration, isVariableFrameRate: false,
            rotation: d.rotation)
        if frame.media != id { info = Self.proxyInfo(info, original: known.original, originalFormat: d.formatDescription, rotation: d.rotation) }
        // F7.3: the project's reading of the item, never the file's tag by itself (cached with the resolve).
        info.pixelAspect = known.shape; info.pixelAspectOverride = nil
        return info
    }

    private func decodeFailed(_ job: Job) {
        media.markDamaged(job.media, frames: job.frames)
        occlusionChanged()      // a damaged cover hides nothing
        state.withLock { $0.generation &+= 1 }
        wake()
    }

    /// Posts `jobs` to the scheduler in call order (last wins), without blocking the caller.
    private func post(_ jobs: [Job], to scheduler: DecodeScheduler) {
        submitChain.withLock { last in
            let prev = last
            last = Task { await prev?.value; await scheduler.submit(jobs) }
        }
    }

    /// Drops the scheduler's queued (not running) jobs, ordered with the submissions.
    private func post(dropQueued scheduler: DecodeScheduler) {
        submitChain.withLock { last in
            let prev = last
            last = Task { await prev?.value; await scheduler.dropQueued() }
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
        let standby = Self.standbyMediaIDs(timeline, sequences: sequences, shown: ids)
        let media = self.media
        let placements = Self.placements(timeline, sequences: sequences, shownFrame: { id, t in
            guard let index = media.resolvedDemuxer(id)?.index, let f = index.frame(at: t) else { return nil }
            return index.entries[f].pts
        })
        media.forgetOffline()
        let captionLookup = CaptionSlotLookup(timeline)
        state.withLock { s in
            s.captionLookup = captionLookup
            // A different sequence must not keep showing the previous one's last frame.
            if s.timeline?.id != timeline.id { s.lastTime = nil; s.holdStart = nil; s.lastHidden = []; lastShownByClip.withLock { $0.removeAll() } }
            s.timeline = timeline; s.sequences = sequences; s.mediaIDs = ids; s.standbyIDs = standby; s.placements = placements
            s.timelineEpoch &+= 1
            s.clipDurations = Self.textDurations(timeline, sequences: sequences)
            s.generation &+= 1
            s.lastJobs = []
        }
        wake()
        // Clips that left the timeline or lost their subject mask release their matte history.
        subjects.retain(clips: Self.subjectMaskClips(timeline, sequences: sequences))
        subjectPrecompute.retain(media: Self.subjectMaskMedia(timeline, sequences: sequences))
        for r in Self.textRefs(timeline, sequences: sequences) { prewarmText(r) }   // first rasters off the render thread
        // Anonymize covers: their matte files are read in the background, now; until then they cover the whole frame.
        // Covers and ordinary Magic masks alike: their files are read off the render thread before a frame asks.
        magicStore.preloadSoon(([timeline] + Array(sequences.values)).reduce(into: Set<String>()) { keys, tl in
            keys.formUnion(tl.coverMatteKeys)
            for track in tl.tracks where track.kind == .video { for c in track.clips { keys.formUnion(c.renderedMagicKeys) } }
        })
        textStandIns.prune(keeping: Self.allClipIDs(timeline, sequences: sequences))
        // Color pipelines (LUT reads) are built off the render thread, now, so the first frame rarely waits.
        if let colors = media.resolver.colorResolver { colors.warm(Self.colorLayers(timeline, sequences: sequences)) }
        // Edits may have fixed a damaged/relinked media: forget damage marks and failed jobs.
        media.clearDamaged()
        occlusionChanged()
        if let s = state.withLock({ $0.scheduler }) { post(reset: s) }
        resolveSoon(nil)        // open the timeline's media in the background: a cut or a clip added during playback is never cold
    }

    /// These media now point at other files (online relink): drop the opened demuxers, decoders, track infos, damage marks
    /// and every cached frame, so the next render and plan read the new file. Offline-to-online needs no call.
    func mediaChanged(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let ids = media.forget(ids)         // their proxies too
        for id in ids { cache.remove(media: id) }
        subjects.forget(sources: ids)
        subjectPrecompute.forget(media: ids)
        subjectFiles.withLock { f in for id in ids { f[id] = nil } }
        lastShownByClip.withLock { $0.removeAll() }
        forgetOpaque()
        let s: DecodeScheduler? = state.withLock { s in s.generation &+= 1; s.sourceEpoch &+= 1; s.lastJobs = []; return s.scheduler }
        wake()
        // Ordered with the submissions. The scheduler cancels a running job of these media and drops its result; a job that
        // finished before that already stored frames, so the cache is cleaned again after the scheduler has settled, and
        // the stand-ins and mattes a tick took from those frames meanwhile go with it.
        submitChain.withLock { last in
            let prev = last
            last = Task { [weak self] in
                await prev?.value
                await s?.forget(ids)
                self?.dropStale(ids)
            }
        }
    }

    /// The proxies of these media appeared, changed or went away (W9.9): their proxy demuxers, decoders and cached frames are
    /// dropped and the proxies resolved again. The originals are untouched.
    func proxiesChanged(_ ids: Set<UUID>) {
        let proxies = Set(ids.compactMap { media.existingProxyID(for: $0) })
        guard !proxies.isEmpty else { return }       // never asked for: nothing opened or cached yet
        media.forget(proxies)
        for id in proxies { cache.remove(media: id) }
        subjects.forget(sources: proxies)
        lastShownByClip.withLock { $0.removeAll() }
        forgetOpaque()
        let s: DecodeScheduler? = state.withLock { s in s.generation &+= 1; s.sourceEpoch &+= 1; s.lastJobs = []; return s.scheduler }
        wake()
        submitChain.withLock { last in
            let prev = last
            last = Task { [weak self] in
                await prev?.value
                await s?.forget(proxies)
                self?.dropStale(proxies)
            }
        }
        resolveSoon(nil)
    }

    /// Second clean-up after the scheduler settled (`mediaChanged`, `proxiesChanged`): cached frames, stand-ins and mattes
    /// of these decoded sources that a job or a tick produced from the old file in between.
    private func dropStale(_ ids: Set<UUID>) {
        for id in ids { cache.remove(media: id) }
        subjects.forget(sources: ids)
        lastShownByClip.withLock { m in m = m.filter { !ids.contains($0.value.frame.media) } }
        forgetOpaque()      // a late job of the old file may have taught the memory again
        state.withLock { $0.generation &+= 1 }
        wake()
    }

    func setProxyUse(_ u: ProxyUse) {
        let changed = state.withLock { s -> Bool in
            guard s.proxyUse != u else { return false }
            s.proxyUse = u; s.generation &+= 1; s.lastJobs = []
            return true
        }
        if changed { occlusionChanged(); wake(); resolveSoon(nil) }
    }

    var proxyUse: ProxyUse { state.withLock { $0.proxyUse } }

    /// Scrubbing decodes the proxy when `use.scrubbing`, playing when `use.playback`, paused never (exact original frame).
    static func usesProxy(scrubbing: Bool, playing: Bool, use: ProxyUse) -> Bool {
        scrubbing ? use.scrubbing : playing && use.playback
    }

    /// The proxy to decode instead of `id`: resolved, and with the original's frame times (same count, same first and last
    /// presentation time; otherwise edit points would shift, so the original is used). Never calls the resolver: an
    /// unresolved proxy is opened in the background and a following tick picks it up.
    private func proxy(for id: UUID, original: any Demuxing) -> (id: UUID, demuxer: any Demuxing)? {
        if media.keepsFields(id) { return nil }
        let pid = media.proxyID(for: id)
        switch media.known(pid) {
        case .ready(let p):
            let a = p.index.entries, b = original.index.entries
            guard !a.isEmpty, a.count == b.count, a.first?.pts == b.first?.pts, a.last?.pts == b.last?.pts else { return nil }
            return (pid, p)
        case .unresolved:
            resolveSoon(pid)
            return nil
        case .offline, .still:
            return nil
        }
    }

    /// Track info of a proxy frame: the original's geometry (a proxy is a reduced picture of it) and color tags (matrix,
    /// transfer, primaries: the proxy's are encoder defaults, see `ProxyColorInterpretation`); bit depth, chroma and codec
    /// follow the proxy's own buffers. Before the original was decoded, its format description supplies both.
    static func proxyInfo(_ p: VideoTrackInfo, original o: VideoTrackInfo?, originalFormat fd: CMFormatDescription, rotation: Int) -> VideoTrackInfo {
        var info = p
        if let o {
            info.width = o.width; info.height = o.height; info.rotation = o.rotation
            info.colorPrimaries = o.colorPrimaries; info.transfer = o.transfer; info.matrix = o.matrix
        } else {
            let dims = CMVideoFormatDescriptionGetDimensions(fd)
            info.width = Int(dims.width); info.height = Int(dims.height); info.rotation = rotation
            func tag(_ k: CFString) -> String? { CMFormatDescriptionGetExtension(fd, extensionKey: k) as? String }
            info.colorPrimaries = tag(kCMFormatDescriptionExtension_ColorPrimaries)
            info.transfer = ColorDetection.transferTag(of: fd)
            info.matrix = tag(kCMFormatDescriptionExtension_YCbCrMatrix)
        }
        return info
    }

    /// How much smaller a proxy is than its original (1, 2, 4...; at least 1).
    static func proxyDivisor(originalWidth: Int, proxyWidth: Int) -> Int {
        guard proxyWidth > 0, originalWidth > proxyWidth else { return 1 }
        return max(1, Int((Double(originalWidth) / Double(proxyWidth)).rounded()))
    }

    /// The viewer's decode reduction left to apply to a proxy that is already `proxyDivisor` times smaller (at least full).
    static func decodeScale(_ s: DecodeScale, proxyDivisor: Int) -> DecodeScale {
        let viewer = s == .full ? 1 : s == .half ? 2 : 4
        let rest = max(1, viewer / max(1, proxyDivisor))
        return rest >= 4 ? .quarter : rest >= 2 ? .half : .full
    }

    /// Viewer quality `q`. Frames are decoded and keyed at `decodeScale(viewer:reducesFull:)` (a key always names the
    /// size really decoded); `exact`: at `q` itself, even on a weak Mac (Export Frame).
    func setQuality(_ q: DecodeScale, exact: Bool = false) {
        // Export Frame measures Follow's text targets exactly (see tick); the frame on screen was measured the playback way.
        state.withLock { if $0.exactText != exact { $0.exactText = exact; $0.generation &+= 1 } }
        let (key, gradeOnly) = state.withLock { s -> (DecodeScale?, Bool) in
            let key = exact ? q : Self.decodeScale(viewer: q, reducesFull: s.reducesFullDecode)
            guard s.schedulerScale == key else { return (key, false) }
            guard s.quality != q else { return (nil, false) }
            s.quality = q; s.generation &+= 1                              // same decode size: grading mode only
            return (nil, true)
        }
        guard let key else { if gradeOnly { wake() }; return }
        let new = makeScheduler(key)
        let old: DecodeScheduler? = state.withLock { s in
            guard s.schedulerScale != key else { return nil }
            let old = s.scheduler
            s.scheduler = new; s.quality = q; s.schedulerScale = key; s.generation &+= 1; s.lastJobs = []
            return old
        }
        if let old { wake(); Task { await old.cancelAll() } }
    }

    /// The size frames are decoded and keyed at now.
    var decodeScale: DecodeScale { state.withLock { $0.schedulerScale } }

    /// Weak-Mac reduced preview decode on/off (tests; the default follows `WorkLimits`). Re-applies the viewer quality.
    func setReducesFullDecode(_ on: Bool) {
        let q = state.withLock { s -> DecodeScale in s.reducesFullDecode = on; return s.quality }
        setQuality(q)
    }

    /// The last presented frame is complete (every exact frame, nothing loading) and nothing changed since.
    var lastFrameComplete: Bool {
        state.withLock { $0.lastComplete && !$0.incomplete && $0.renderedGeneration == $0.generation }
    }

    /// `lastFrameComplete`, that frame is the one at `t` with the exact (not the playing preview) grade, and no layer of
    /// it is an offline or damaged placeholder (Export Frame).
    func frameComplete(at t: Time) -> Bool {
        state.withLock {
            $0.lastComplete && !$0.incomplete && $0.renderedGeneration == $0.generation && $0.lastTime == t
                && !$0.lastPreviewGrade && !$0.lastUnavailable
        }
    }

    /// `PlayProbe`: the last presented frame is the one at `t` with every layer's frame (at the viewer's quality, which
    /// may grade at display size; Export Frame's `frameComplete` also demands the full-quality grade).
    func settled(at t: Time) -> Bool {
        state.withLock { $0.lastComplete && !$0.incomplete && $0.renderedGeneration == $0.generation && $0.lastTime == t }
    }

    /// Viewer zoom for the present path. A change re-presents the current frame (from the cache, no decode).
    func setZoom(_ z: ViewerZoom) {
        state.withLock { s in
            guard s.zoom != z else { return }
            s.zoom = z; s.generation &+= 1
        }
        wake()
    }

    var lastPresentedZoom: ViewerZoom? { state.withLock { $0.lastPresentedZoom } }

    /// Shows or hides the captions in the monitor; the current frame is redrawn.
    /// Color page compare: the bypassed clips are drawn ungraded (whole picture, or its left half for a split); the frame
    /// is redrawn. nil or empty = graded.
    func setColorBypass(_ bypass: ColorBypass?) {
        let value = bypass?.isEmpty == true ? nil : bypass
        let timelines = state.withLock { s -> [Timeline] in
            guard s.colorBypass != value else { return [] }
            s.colorBypass = value; s.generation &+= 1
            return (s.timeline.map { [$0] } ?? []) + Array(s.sequences.values)
        }
        // Load the ungraded pipelines' LUTs (e.g. a log clip's camera conversion) before the first Before frame needs them.
        if let value, let colors = media.resolver.colorResolver {
            colors.warm(Self.ungradedColors(timelines, bypass: value))
        }
        wake()
    }

    /// The ungraded color of every bypassed clip (what `ungradedLayers` asks the resolver for).
    static func ungradedColors(_ timelines: [Timeline], bypass: ColorBypass) -> [(color: ClipColor, media: UUID)] {
        var out: [(color: ClipColor, media: UUID)] = []
        for tl in timelines { for tr in tl.tracks { for c in tr.clips where bypass.bypasses(c.id) {
            out.append((c.color.ungraded, c.media))
        } } }
        return out
    }

    func setTransparencyGrid(_ on: Bool) {
        state.withLock { s in
            guard s.transparencyGrid != on else { return }
            s.transparencyGrid = on; s.generation &+= 1
        }
        wake()
    }

    func setShowCaptions(_ on: Bool) {
        state.withLock { s in
            guard s.showCaptions != on else { return }
            s.showCaptions = on; s.generation &+= 1
        }
        wake()
    }

    /// The project's style kit for the caption styles of the monitor (the export gets it explicitly); the frame is redrawn.
    func setCaptionKit(_ kit: StyleKit?) {
        state.withLock { s in
            guard s.captionKit != kit else { return }
            s.captionKit = kit; s.captionLibrary = nil; s.generation &+= 1
        }
        wake()
    }

    func setCaptionLegacyFont(_ on: Bool) {
        state.withLock { s in
            guard s.captionLegacyFont != on else { return }
            s.captionLegacyFont = on; s.captionLibrary = nil; s.generation &+= 1
        }
        wake()
    }

    /// Caption styles of this loop's project: registered looks resolved through its own kit.
    private func captionLibrary() -> CaptionPresetLibrary {
        let version = CaptionLookRegistry.shared.version
        return state.withLock { s in
            if let c = s.captionLibrary, c.key == version { return c.library }
            let lib = CaptionLookRegistry.shared.library(for: s.captionKit, legacyFont: s.captionLegacyFont)
            s.captionLibrary = (version, lib)
            return lib
        }
    }

    func setPresenter(_ p: Presenter?) { state.withLock { $0.presenter = p; $0.generation &+= 1 }; wake() }

    func invalidate() { state.withLock { $0.generation &+= 1 }; wake() }

    // MARK: Idle pause (Q-PERF2 rec 2)

    private let waker = CallbackSlot()
    /// Called after every invalidation (any thread): the display-link driver resumes a link it paused while idle.
    func setWaker(_ w: (@Sendable () -> Void)?) { waker.set(w) }
    private func wake() { waker.call() }

    /// Nothing for a display tick to do until the next invalidation: the clock is paused, not scrubbing, the frame at the
    /// clock is presented and complete (no decode or hold outstanding). Every way out of this state bumps the generation
    /// (seek, play, edit, decode failure, color/matte/text ready) and calls the waker.
    var isIdle: Bool {
        guard clock.rate.isPaused else { return false }
        let now = clock.now()
        return state.withLock { s in
            guard let tl = s.timeline else { return true }
            return s.renderedGeneration == s.generation && !s.incomplete && !s.scrubbing && s.holdStart == nil
                && s.lastTime == Self.gridTime(now, tl) && s.startGate == nil && s.preroll == nil
        }
    }

    /// Display-link rate for the current state (sequence rate while playing) and whether the link may pause.
    func cadence() -> (range: FramePacing.Range, idle: Bool) {
        let (fd, scrubbing, starting) = state.withLock { ($0.timeline?.format.frameDuration, $0.scrubbing, $0.preroll?.rate) }
        let fps = fd.map { $0.value > 0 ? Double($0.timescale) / Double($0.value) : 0 } ?? 0
        let rate = clock.rate
        // A play start runs the link at the playing rate already: it is laid out from that link's ticks.
        return (FramePacing.range(fps: fps, rate: rate.isPaused ? starting ?? rate : rate, scrubbing: scrubbing), isIdle)
    }

    /// A playing frame was presented for display at `seconds` (host time): feeds the pacing stat.
    func notePresent(at seconds: Double) { state.withLock { $0.pacing.record(seconds) } }
    func resetPacing() { state.withLock { $0.pacing.reset() } }

    /// Thermal / Low Power policy: a halved lookahead replans the prefetch window.
    func setPowerPolicy(_ p: PowerPolicy) {
        let changed = state.withLock { s -> Bool in
            guard s.power != p else { return false }
            s.power = p; s.lastJobs = []; s.generation &+= 1
            return true
        }
        if changed { wake() }
    }
    var powerPolicy: PowerPolicy { state.withLock { $0.power } }

    /// A play waiting for its start frame. `id` stays the same for the whole wait; `token` changes with every seek.
    struct StartGate: Sendable {
        var rate: PlaybackRate
        var since: ContinuousClock.Instant
        var id: UInt64
        var token: UInt64
    }

    /// Starts the clock at `start` now when the frame there was shown complete and it and the next `startGateAhead`
    /// frames playback will use (proxies when playback uses them) are cached; otherwise arms the start gate (the clock
    /// stays held at `start`; a tick that has every exact frame, or the limit, starts it). Returns the gate's id when
    /// armed. Main actor (with pause and seek).
    @discardableResult
    func play(at start: Time, rate: PlaybackRate) -> UInt64? {
        let running = !clock.rate.isPaused       // a rate change while playing (J/K/L) never waits
        let snap = state.withLock { s in
            (s.timeline, s.sequences, s.schedulerScale, s.proxyUse, s.startGateEnabled,
             s.lastTime == start && s.lastComplete && !s.incomplete && s.renderedGeneration == s.generation)
        }
        var ready = running || !snap.4
        if !ready, let tl = snap.0 {
            let proxy = Self.usesProxy(scrubbing: false, playing: true, use: snap.3)
            ready = snap.5 && framesCached(tl, sequences: snap.1, after: start, count: Self.startGateAhead, scale: snap.2,
                                           proxy: proxy, reverse: rate.isReverse, includingStart: true)
        } else if snap.0 == nil {
            ready = true                         // nothing to wait for
        }
        let id = state.withLock { s -> UInt64? in
            s.pendingOpen = nil
            s.preroll = nil; s.prerollTaken = nil
            clockSerial.wrappingAdd(1, ordering: .relaxed)
            guard !ready else { s.startGate = nil; return nil }
            s.gateTokens &+= 1
            s.startGate = StartGate(rate: rate, since: ContinuousClock.now, id: s.gateTokens, token: s.gateTokens)
            return s.gateTokens
        }
        clockOps.withLock { _ in
            if id != nil {
                clock.stop(); clock.seek(to: start)
            } else if running || !beginPlayStart(at: start, rate: rate) {
                clock.start(at: start, rate: rate)
            }
        }
        wake()
        return id
    }

    /// Pause (or a new play) while the start gate waits: the clock is not started.
    func cancelStartGate() { state.withLock { $0.startGate = nil; $0.pendingOpen = nil } }

    // MARK: Play start on the display (`PlayStart`)

    /// Play starts are timed to the display (set while a layer is attached; tests).
    var startsOnDisplay: Bool {
        get { state.withLock { $0.startsOnDisplay } }
        set { state.withLock { $0.startsOnDisplay = newValue } }
    }

    /// Main actor: parks the clock on `start` and lets the next display ticks lay the play start out. False: not on a
    /// display (or the lead is off); the caller starts the clock itself.
    func beginPlayStart(at start: Time, rate: PlaybackRate) -> Bool {
        let begun = state.withLock { s -> Bool in
            guard s.startsOnDisplay, s.lead.enabled, let tl = s.timeline, !rate.isPaused else { return false }
            var start = start
            // Play from behind a loop's end starts at its beginning (the running clock would wrap there at once).
            if s.lead.loops, rate.isForward, let r = Self.loopRegion(tl, bounds: s.lead.bounds), start >= r.end { start = r.start }
            clock.stop(); clock.seek(to: start)
            s.gateTokens &+= 1
            s.preroll = PlayStart(start: start, rate: rate, token: s.gateTokens)
            s.prerollSince = ContinuousClock.now
            s.prerollTaken = nil
            s.handed = nil
            s.pacing.reset()
            return true
        }
        if begun { wake() }
        return begun
    }

    /// Longest a play start waits for the display link (a link that does not tick: hidden window).
    static let playStartLimit = Duration.milliseconds(250)

    /// Main actor: seconds until the clock of the waiting play start is due (0: now; nil: none waits). `hostNow` on the
    /// display link's time base.
    func playStartWait(hostNow: Double) -> Double? {
        state.withLock { s in
            guard let p = s.preroll, s.prerollTaken == nil else { return nil }
            if p.immediate { return 0 }
            if let hs = p.hostStart { return max(0, hs - hostNow) }
            let left = Self.playStartLimit - (ContinuousClock.now - s.prerollSince)
            return left > .zero ? Double(left.components.attoseconds) / 1e18 + Double(left.components.seconds) : 0
        }
    }

    /// Main actor: the position to start the clock at now, once the laid-out start time is reached (`force`: now in any
    /// case). The caller starts the clock right away; the play start ends with the first tick that sees it run.
    ///
    /// A caller that comes late (the main actor was busy past the laid-out time): the host clock starts where it would be
    /// by now, so the picture laid out for it stays right. The audio clock starts at the start position itself: sound
    /// that is skipped is never heard, so it begins exactly at the playhead and the picture holds its last start frame
    /// until the clock has caught up (`DisplayLead.prime`).
    func takePlayStart(hostNow: Double, force: Bool = false) -> (at: Time, rate: PlaybackRate)? {
        let audioMaster = isAudioMaster
        return state.withLock { s in
            guard let p = s.preroll, s.prerollTaken == nil else { return nil }
            if !p.immediate, !force {
                guard let hs = p.hostStart, hostNow >= hs else { return nil }
            }
            s.prerollTaken = ContinuousClock.now
            return (audioMaster ? p.start : p.clockPosition(atHost: hostNow), p.rate)
        }
    }

    /// The audio output is the clock (its position is what was heard).
    private var isAudioMaster: Bool { (clock as? SwitchingClock)?.isAudio ?? (clock is AudioClock) }

    var isStartingPlay: Bool { state.withLock { $0.preroll != nil } }

    /// The engine wraps playback inside the play range (or the whole sequence) itself: the clock is moved to the other
    /// end when it leaves, and the picture, which leads the clock, shows the first frames after the wrap in time.
    var loops: Bool {
        get { state.withLock { $0.lead.loops } }
        set { state.withLock { $0.lead.loops = newValue } }
    }

    /// A clock at most this long (at 1x) past a loop's end left it by playing: it continues that far into the loop.
    static let loopOverrun = Time(300_000, 1_000_000)

    /// The span a looping engine plays: the play range inside the timeline, at least one frame.
    static func loopRegion(_ tl: Timeline, bounds: TimeRange?) -> TimeRange? {
        let fd = tl.format.frameDuration
        let end = lastFrame(tl) + fd
        let a = max(.zero, bounds?.start ?? .zero), b = min(bounds?.end ?? end, end)
        return b - a >= fd ? TimeRange(start: a, end: b) : nil
    }

    /// Main actor (pause): stops the clock and parks it on the newest frame handed to the display (`State.handed`): the
    /// last frame the viewer sees. The frames handed over before it still reach the glass in order and the picture stays
    /// on it: it never steps back and never goes on to a frame that was not handed over. Playhead, sound and the
    /// reported position are that frame, at every rate and in reverse. Only when the picture was held while the clock
    /// ran on (a cold layer) it parks on the clock frame, ahead of the picture (`DisplayLead.parkPosition`).
    ///
    /// Returns at once: the clock is stopped outside the state lock, and the GPU lock is not taken (a tick that
    /// composites, or a frame capture, never holds the main actor up). A playing tick claims its frame under the state
    /// lock before it composites: one that claimed before the pause presents the parked frame, one that comes after
    /// presents nothing (`clockSerial`). Their reports are dropped. Returns the parked position.
    func park() -> Time {
        let at = clockOps.withLock { _ -> Time in
            let rate = clock.rate, ran = !rate.isPaused
            clock.stop()
            let stopped = clock.now()
            let at = state.withLock { s -> Time in
                clockSerial.wrappingAdd(1, ordering: .relaxed)
                s.startGate = nil; s.pendingOpen = nil
                s.preroll = nil; s.prerollTaken = nil
                var at = stopped + (ran ? s.phase.offset : .zero)
                if let tl = s.timeline { at = Self.gridTime(at, tl) }
                if let tl = s.timeline {
                    let loop = s.lead.loops ? Self.loopRegion(tl, bounds: s.lead.bounds) : nil
                    at = DisplayLead.parkPosition(handed: s.handed, clock: at, rate: rate, loop: loop)
                }
                s.handed = nil
                s.phase.reset(); s.lead.reset()
                // A report of a tick before the pause would move the host off the parked frame.
                s.lastOutcome = nil; s.publishedPosition = nil
                return at
            }
            clock.seek(to: at)
            return at
        }
        // Prefetch that still waits for a decode slot is dropped; lastJobs cleared so the paused plan is posted anew.
        // Posted on the submit chain, so it runs before the paused plan that follows.
        if let s = state.withLock({ s -> DecodeScheduler? in s.lastJobs = []; return s.scheduler }) { post(dropQueued: s) }
        wake()
        return at
    }

    /// Main actor: the open the render thread asked for, if its gate is still armed and no seek came in between. Clears
    /// the gate; the caller starts the clock at `at`.
    func takeStartGateOpen() -> (at: Time, rate: PlaybackRate)? {
        state.withLock { s in
            guard let p = s.pendingOpen else { return nil }
            s.pendingOpen = nil
            guard let g = s.startGate, g.token == p.token else { return nil }
            s.startGate = nil; s.pacing.reset()
            return (p.at, p.rate)
        }
    }

    /// Main actor: how long gate `id` may still wait (nil: it is gone). At the limit it opens at the held clock position.
    func startGateRemaining(id: UInt64) -> Duration? {
        state.withLock { s in
            guard let g = s.startGate, g.id == id else { return nil }
            let left = s.startGateLimit - (ContinuousClock.now - g.since)
            return left > .zero ? left : .zero
        }
    }

    /// Main actor: opens gate `id` now at the held clock position (limit reached, or the monitor went away).
    func forceStartGateOpen(id: UInt64? = nil) -> (at: Time, rate: PlaybackRate)? {
        let at = clock.now()
        return state.withLock { s in
            guard let g = s.startGate, id == nil || g.id == id else { return nil }
            s.startGate = nil; s.pendingOpen = nil; s.pacing.reset()
            return (at, g.rate)
        }
    }

    /// Tests: the start gate's limit.
    var startGateLimit: Duration {
        get { state.withLock { $0.startGateLimit } }
        set { state.withLock { $0.startGateLimit = newValue } }
    }

    /// Called (any thread) when the render thread requests a gate open; the engine hops to the main actor.
    private let gateOpener = CallbackSlot()
    func setGateOpener(_ f: (@Sendable () -> Void)?) { gateOpener.set(f) }

    /// Display lead (`DisplayLead`; on by default, `SQ_DISPLAY_LEAD=0` or false: bench A/B and tests).
    var leadsDisplay: Bool {
        get { state.withLock { $0.lead.enabled } }
        set { state.withLock { $0.lead.enabled = newValue; $0.lead.reset() } }
    }

    /// The play range the host stops or wraps at (nil: the whole sequence): the picture never leads out of it.
    var leadBounds: TimeRange? {
        get { state.withLock { $0.lead.bounds } }
        set { state.withLock { $0.lead.bounds = newValue } }
    }

    var locksFramePhase: Bool {
        get { state.withLock { $0.phase.enabled } }
        set { state.withLock { $0.phase.enabled = newValue; $0.phase.reset() } }
    }

    /// Offset the phase lock adds to the clock while playing (zero when paused or off): the shown frame is the grid frame
    /// at `clock.now() + phaseOffset`, so a pause lands there.
    var phaseOffset: Time { state.withLock { $0.phase.offset } }

    /// Whether play waits for the start frame (tests, bench).
    var isWaitingToStart: Bool { state.withLock { $0.startGate != nil } }
    var startGateEnabled: Bool {
        get { state.withLock { $0.startGateEnabled } }
        set { state.withLock { $0.startGateEnabled = newValue } }
    }

    /// `refine`: a slow scrub move (see `PlaybackEngine.slowScrubFrames`) shows the exact frame at `target` right away.
    /// `velocity`: a scrub move's size in frames (signed), for prefetching the next keyframe in the drag direction.
    /// `seekClock`: the clock moves to `target` under the same lock as `refine`/`velocity`; the tick reads the clock under
    /// it too, so no tick sees the new position with the previous step's refine (that planned keyframes only and
    /// canceled the running GOP decode).
    func beginStep(target: Time, refine: Bool = false, velocity: Int = 0, seekClock: Bool = false, beyondEnd: Bool = false) {
        // `clockOps` first (lock order): a loop wrap of a tick that read the clock before this seek must not undo it.
        if seekClock {
            clockOps.withLock { _ in beginStepLocked(target: target, refine: refine, velocity: velocity, seekClock: true, beyondEnd: beyondEnd) }
        } else {
            beginStepLocked(target: target, refine: refine, velocity: velocity, seekClock: false, beyondEnd: beyondEnd)
        }
        wake()
    }

    private func beginStepLocked(target: Time, refine: Bool, velocity: Int, seekClock: Bool, beyondEnd: Bool) {
        state.withLock { s in
            s.beyondEnd = beyondEnd
            if seekClock { clock.seek(to: target); clockSerial.wrappingAdd(1, ordering: .relaxed) }
            s.handed = nil
            // A seek while a play start waits: it starts afresh from the new position.
            if seekClock, let p = s.preroll, s.prerollTaken == nil, clock.rate.isPaused {
                s.gateTokens &+= 1
                s.preroll = PlayStart(start: target, rate: p.rate, token: s.gateTokens)
                s.prerollSince = ContinuousClock.now
            }
            s.scrubVelocity = s.scrubbing ? velocity : 0
            s.pendingStep = (target, ContinuousClock.now, s.scrubbing); s.generation &+= 1
            if s.startGate != nil {                    // a seek while waiting: wait afresh; a requested open is stale
                s.gateTokens &+= 1
                s.startGate?.since = ContinuousClock.now; s.startGate?.token = s.gateTokens
                s.pendingOpen = nil
            }
            if refine && s.scrubbing { s.refine = target } else if s.refine != target { s.refine = nil }
        }
    }

    /// FB-H: the scrub gesture rests at `t` (no move for a moment): decode and show the exact frame there, still inside
    /// the gesture. The next move to another position drops back to keyframes. Resting drops the drag velocity: the
    /// exact window around `t` is planned, not the slow-drag one (forward only in the last move's direction).
    func refineScrub(at t: Time) {
        let changed = state.withLock { s -> Bool in
            guard s.scrubbing, s.refine != t || s.scrubVelocity != 0 else { return false }
            s.refine = t; s.scrubVelocity = 0; s.lastJobs = []; s.generation &+= 1
            return true
        }
        if changed { wake() }
    }

    /// The last scrub move's size in frames (0 outside a drag or while resting). Test hook.
    var scrubVelocity: Int { state.withLock { $0.scrubVelocity } }

    /// Enters/leaves keyframe-only scrubbing. The decode window is replanned by the next prefetch (the caller seeks).
    func setScrubbing(_ on: Bool) {
        state.withLock { s in
            guard s.scrubbing != on else { return }
            s.scrubbing = on; s.refine = nil; s.scrubVelocity = 0; s.lastJobs = []; s.generation &+= 1
        }
        wake()
    }

    var isScrubbing: Bool { state.withLock { $0.scrubbing } }

    /// Pending captures by key: a newer request with the same key replaces the older one (coalesced, not queued).
    private let pendingCapture = Mutex<[String: FrameCaptureEncoder]>([:])
    private let captureQueue = DispatchQueue(label: "sq.renderloop.capture")

    /// Reads back the next finished composite, or the current one when nothing is waiting to be rendered. Never blocks
    /// the caller: a request made after an edit is served by the render that follows it; an idle loop serves it from a
    /// command buffer on its own queue (ordered behind the render that produced the frame). One pending request.
    func requestCapture(key: String, _ encode: @escaping FrameCaptureEncoder) {
        pendingCapture.withLock { $0[key] = encode }
        let idle = state.withLock { $0.renderedGeneration == $0.generation && !$0.incomplete }
        guard idle else { return }       // the render that is already due serves it
        captureQueue.async { [self] in
            let all = pendingCapture.withLock { c -> [FrameCaptureEncoder] in defer { c = [:] }; return Array(c.values) }
            guard !all.isEmpty else { return }
            gpu.withLock { g in
                guard let target = g.target, let cb = g.queue.makeCommandBuffer() else { return }
                for encode in all { if let done = encode(target, cb) { cb.addCompletedHandler { _ in done() } } }
                cb.commit()
            }
        }
    }

    /// Handed off under its own short lock after each render (never waits on the GPU lock).
    private let lastTexture = Mutex<RenderedTexture?>(nil)
    var lastRendered: RenderedTexture? { lastTexture.withLock { $0 } }

    /// Phases of the last iteration that got past the "nothing changed" check (profiling; GPU time filled on completion).
    let lastProfile = Mutex<TickProfile?>(nil)
    /// On-glass timing diagnostics (`PlaybackEngine.presentProbe`); nil = off.
    let presentProbe = Mutex<PresentProbe?>(nil)
    /// Mirrors `presentProbe != nil`, so a tick checks a flag instead of taking the lock.
    let presentProbeOn = Atomic<Bool>(false)
    /// Profiling: keep the node tree of the last composite (`lastNodes`), so a bench can cost each node on its own.
    let captureNodes = Atomic<Bool>(false)
    let lastNodes = Mutex<(nodes: [RenderNode], format: SequenceFormat)?>(nil)
    static let signposter = OSSignposter(subsystem: "de.paulherter.SequenceStudio", category: "playback")

    var stats: PlaybackStats {
        var s = state.withLock { $0.stats }
        s.cacheBytes = cache.usedBytes
        s.renderTicks = timing.withLock { $0.ticks }
        s.presentIntervalSpread = state.withLock { $0.pacing.spreadMilliseconds }
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

    /// A seek to `t` asks for a time at or past the end of the sequence (gridTime clamps it to the last frame).
    static func isBeyondEnd(_ t: Time, _ tl: Timeline) -> Bool {
        tl.duration > .zero && t >= tl.duration
    }

    static func gridTime(_ t: Time, _ tl: Timeline) -> Time {
        let fd = tl.format.frameDuration
        guard fd > .zero else { return .zero }
        let g = fd * t.frameIndex(frameDuration: fd)
        return min(max(g, .zero), lastFrame(tl))
    }

    // MARK: Tick

    /// `presentAt`: host time (`CACurrentMediaTime` base) the display link will show this tick's frame at; nil (headless
    /// ticks) = no display lead. `hostNow`: tests only (default: read together with the clock).
    func tick(drawable: CAMetalDrawable? = nil, presentAt: Double? = nil, hostNow: Double? = nil) -> TickOutcome? {
        let start = ContinuousClock.now
        let serial = clockSerial.load(ordering: .relaxed)
        var o = gpu.withLock { g in tickLocked(&g, serial: serial, drawable: drawable, presentAt: presentAt, hostNow: hostNow) }
        o?.serial = serial
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

    private struct LayerBuild { var layers: [RenderLayer] = []; var missing = 0; var waiting = false; var misses: [(UUID, Int)] = []; var noFrame = 0
        /// Layers drawn as an offline or damaged placeholder (no picture will come without a relink or an edit).
        var unavailable = 0
        /// Keyframe-only scrub: a layer is complete with its scrub frame; a miss requests that frame, not the GOP.
        var scrub = false
        /// Playing: the one budget of this tick for waiting on text frames the text lane is drawing (nil: never wait).
        var textWait: TextGenerator.RasterWait?
        /// Ready proxies are drawn instead of the originals (W9.9, `usesProxy`).
        var proxy = false
        /// Playing (not paused, not at the edge): subject masks segment with the fast quality.
        var playing = false
        /// Playing direction (subject masks segment the next decoded frames ahead).
        var forward = true
        /// Playing: per clip with a Magic mask, the source times its next frames ask for (`MatteLookAhead`).
        var matteAhead: [Clip.ID: [Time]] = [:]
        /// Cold (undecoded) layers that are part of a transition, and flat color layers (dips) and Adjustment Layers, which are never cold.
        var coldInTransition = 0; var solids = 0
        /// Source pts of the frame the bottom picture layer shows (diagnostics, `PlaybackStats.lastShownPTS`).
        var shown: Time?
        /// Frame per clip in this composite (committed to `lastShownByClip` when presented).
        var shownByClip: [ShownKey: ShownFrame] = [:]
        /// Layers that have no picture at all in this composite.
        var coldKeys: Set<ShownKey> = []
        /// Clips that were hidden in the last presented composite, and how many of them have no close frame yet.
        var uncovered: Set<ShownKey> = []; var coldUncovered = 0
        /// The hold for this frame ran out: an uncovered clip takes any stand-in rather than the gray placeholder.
        var holdExpired = false }

    /// Whether to keep showing the last presented frame instead of compositing now. Solid dip layers do not count as
    /// pictures; a transition with one cold side holds too (a dissolve against the gray "loading" placeholder would flash).
    /// Paused (seek, scrub, step) any cold picture layer holds: a gray layer among others is a flash too. Playing, one cold
    /// layer among others composites (one slow layer never freezes playback). FB-H2: the paused hold for a cold layer among
    /// others needs `moved`: the playhead moved, or a layer went cold that the last presented composite did not already
    /// draw as a placeholder (a clip just added). An edit while a layer stays cold composites at once instead of waiting
    /// up to `holdLimit` for that layer again.
    static func shouldHold(noFrame: Int, layers: Int, solids: Int, coldInTransition: Int, hasLast: Bool, playing: Bool = true,
                           moved: Bool = true) -> Bool {
        hasLast && ((noFrame > 0 && (noFrame == layers - solids || (!playing && moved))) || coldInTransition > 0)
    }

    static let maxRenderRetries = 30
    /// After this many failed attempts the next one draws the placeholder instead of the real composite.
    static let fallbackAfter = 3

    /// `SQ_DISPLAY_GRADE=0` turns the display-size grade off (A/B in EngineBench `project-play`).
    static let displayGradeEnabled = ProcessInfo.processInfo.environment["SQ_DISPLAY_GRADE"] != "0"

    /// Playback perf: the compositor grades pointwise layers at the size they are shown (`Compositor.gradesAtDisplaySize`)
    /// while playing or scrubbing, and at a reduced preview quality. A settled full-quality frame is graded exactly as
    /// export grades it.
    static func gradesAtDisplaySize(playing: Bool, scrubbing: Bool, quality: DecodeScale,
                                    enabled: Bool = displayGradeEnabled) -> Bool {
        enabled && (playing || scrubbing || quality != .full)
    }

    private func tickLocked(_ g: inout GPU, serial: UInt64, drawable: CAMetalDrawable?, presentAt: Double? = nil, hostNow: Double? = nil) -> TickOutcome? {
        // Display lead: host time from this clock read to the moment the frame is shown (zero without a timestamp).
        let host = hostNow ?? CACurrentMediaTime()
        let hostLead: Time? = presentAt == nil ? nil : DisplayLead.hostLead(presentAt: presentAt, hostNow: host)
        let audioMaster = isAudioMaster
        // The clock is read under the state lock: a step (`beginStep(seekClock:)`) moves it and sets refine/velocity in
        // one critical section, so this tick sees both or neither.
        let (now, clockRate, snap, loopRegion, wrapTo) = state.withLock { s in
            var now = clock.now()
            let rate = clock.rate
            var region: TimeRange?
            var wrapTo: Time?
            if !rate.isPaused {
                // The clock runs: a play start is over. The lead is full from this tick on (`DisplayLead.prime`).
                if let p = s.preroll {
                    s.preroll = nil; s.prerollTaken = nil
                    s.lead.prime(floor: p.lastLed, hostLead: p.lastHostLead)
                }
                // Loop: the clock left the loop and continues at its other end.
                if s.lead.loops, let tl = s.timeline, let r = Self.loopRegion(tl, bounds: s.lead.bounds) {
                    region = r
                    // Far outside (play began behind the loop): its beginning (its last frame in reverse).
                    let slack = scaled(Self.loopOverrun, by: rate)
                    // Only decided here: the clock is moved after the lock (`wrapTo`), a seek of the audio clock
                    // restarts the output.
                    if rate.isForward, now >= r.end {
                        now = now - r.end <= slack ? DisplayLead.wrapped(now, in: r) : r.start
                        wrapTo = now
                    } else if rate.isReverse, now < r.start || (audioMaster && r.start == .zero && now <= .zero) {
                        // (The audio clock never goes below 0: it stops there, at the end of frame 0, and wraps.)
                        now = r.end - (r.start - now <= -slack ? max(r.start - now, DisplayLead.quantum) : DisplayLead.quantum)
                        if now < r.start { now = r.start }
                        wrapTo = now
                    }
                }
            } else if let taken = s.prerollTaken, ContinuousClock.now - taken > .milliseconds(500) {
                s.preroll = nil; s.prerollTaken = nil          // the clock never started (no output): back to paused
            } else if s.preroll != nil, s.lead.loops, let tl = s.timeline {
                region = Self.loopRegion(tl, bounds: s.lead.bounds)
            }
            return (now, rate, (s.timeline, s.sequences, s.schedulerScale, s.zoom, s.generation, s.renderedGeneration != s.generation,
             s.incomplete, s.lastTime, s.presenter, s.pendingStep != nil, s.scrubbing, s.refine, s.sourceEpoch, s.lastCold,
             s.timelineEpoch, s.quality), region, wrapTo)
        }
        if let wrapTo {
            // Not when the main actor paused, sought or restarted since this tick began: its position stands.
            clockOps.withLock { _ in
                if clockSerial.load(ordering: .relaxed) == serial, !clock.rate.isPaused { clock.seek(to: wrapTo) }
            }
        }
        guard let tl = snap.0 else { return nil }
        let (gate, starting) = state.withLock { s in (s.startGate, clockRate.isPaused && s.startGate == nil ? s.preroll : nil) }
        // A play start counts as playing (frames are picked for their display time, proxies, prefetch ahead).
        let rate = starting?.rate ?? clockRate
        let (sequences, scale, zoom, generation, invalidated, incomplete, lastTime, presenter, stepPending) =
            (snap.1, snap.2, snap.3, snap.4, snap.5, snap.6, snap.7, snap.8, snap.9)
        let fd = tl.format.frameDuration
        let last = Self.lastFrame(tl)
        // Playing: the frame is taken at the phase-locked position (same grid frames, changes kept between ticks).
        // The picked frame is the one for the time it is on glass (`DisplayLead`): only the picture leads. `position`,
        // the frame at the clock, is what the host gets (playhead, timecode), and audio stays on the clock.
        var startStep: PlayStart.Step?
        var clockRead = now
        let (sampled, led) = state.withLock { s -> (Time, Time) in
            if let starting, var p = s.preroll, p.token == starting.token {
                // Play start: the clock is parked; the frame is the one of the laid-out start at this tick's display time.
                s.phase.reset(); s.lead.reset()
                let fps = fd.value > 0 ? Double(fd.timescale) / Double(fd.value) : 0
                let link = Double(FramePacing.range(fps: fps, rate: p.rate, scrubbing: false).preferred)
                let step = p.tick(presentAt: presentAt, hostNow: host, frameDuration: fd, linkInterval: link > 0 ? 1 / link : 0)
                s.preroll = p
                startStep = step
                clockRead = p.virtualClock(atHost: host)
                guard case .led(let v, _) = step else { return (now, .zero) }
                let held = s.lead.held(v, clock: now, reverse: p.rate.isReverse, frameDuration: fd)
                return (held, held - now)
            }
            guard !rate.isPaused, gate == nil else { s.phase.reset(); s.lead.reset(); return (now, .zero) }
            let ahead = s.lead.position(clock: now, rate: rate, hostLead: hostLead, frameDuration: fd)
            return (s.phase.sample(ahead, frameDuration: fd, reverse: rate.isReverse), ahead - now)
        }
        // The main actor starts the clock (now, or at the laid-out time).
        if let startStep, startStep == .startNow || { if case .led(_, true) = startStep { true } else { false } }() {
            gateOpener.call()
        }
        var t: Time, position: Time
        if let r = loopRegion, now >= r.start, now < r.end {
            // Looping: the picture, ahead of the clock, is past the wrap before the clock is.
            t = Self.gridTime(DisplayLead.wrapped(sampled, in: r), tl)
            position = led == .zero ? t : Self.gridTime(DisplayLead.wrapped(sampled - led, in: r), tl)
        } else {
            t = Self.gridTime(sampled, tl)
            position = led == .zero ? t : Self.gridTime(sampled - led, tl)
        }
        let clockRuns = !rate.isPaused && gate == nil
        var edge = false
        // The audio clock never goes below 0 in reverse (the feeder stops producing at frame 0): stop inside frame 0.
        // (Looping, the clock wraps at 0 instead.)
        if starting == nil || loopRegion == nil,
           (rate.isForward && now >= last + fd) || (rate.isReverse && (now.isNegative || (audioMaster && loopRegion == nil && now < fd))) {
            t = rate.isForward ? last : .zero
            position = t
            let stale = clockOps.withLock { _ -> Bool in
                guard clockSerial.load(ordering: .relaxed) == serial else { return true }
                clock.stop(); clock.seek(to: t)
                return false
            }
            if stale { return nil }                 // the main actor moved the clock meanwhile: its position stands
            // The clock stands on the edge frame: a pause that follows (the host's answer to the stop) stays there.
            state.withLock { s in
                s.handed = nil
                if starting != nil { s.preroll = nil; s.prerollTaken = nil }
            }
            edge = true
        }
        // Leaving playback or a scrub at the same frame redraws it with the exact grade.
        let previewGrade = Self.gradesAtDisplaySize(playing: (!rate.isPaused || gate != nil) && !edge,
                                                    scrubbing: snap.10 && snap.11 != t, quality: snap.15)
        let gradeModeChanged = state.withLock { $0.lastPreviewGrade } != previewGrade
        if t == lastTime && !invalidated && !incomplete && !edge && !gradeModeChanged {
            if let gate {
                // Start frame shown complete: waiting for the frames after it (or the limit).
                let (complete, limit, use) = state.withLock { ($0.lastComplete, $0.startGateLimit, $0.proxyUse) }
                let proxy = Self.usesProxy(scrubbing: false, playing: true, use: use)
                if ContinuousClock.now - gate.since >= limit
                    || (complete && framesCached(tl, sequences: snap.1, after: t, count: Self.startGateAhead, scale: snap.2,
                                                 proxy: proxy, reverse: gate.rate.isReverse)) {
                    openStartGate(at: t, gate: gate)
                }
            }
            return TickOutcome(presented: false, time: t, stoppedAtEdge: false, position: position, clock: clockRead, playing: clockRuns)
        }

        // Layers
        let sp = Self.signposter
        let tickID = sp.makeSignpostID()
        let buildState = sp.beginInterval("build", id: tickID)
        let buildStart = ContinuousClock.now
        var profile = TickProfile()
        profile.time = t
        defer { lastProfile.withLock { $0 = profile } }
        // Export Frame only (the flag is off otherwise, so playback pays nothing): the exact measure, as export does.
        var requests = state.withLock({ $0.exactText })
            ? GraphicsTextBounds.$exact.withValue(true) { tl.videoLayers(at: t, sequences: { sequences[$0] }) }
            : tl.videoLayers(at: t, sequences: { sequences[$0] })
        // Paused after a seek past the end: the clock stands on the last frame, but no clip is under the playhead.
        let beyond = state.withLock { s -> Bool in
            if !rate.isPaused || s.preroll != nil { s.beyondEnd = false }
            return s.beyondEnd && t == last
        }
        if beyond { requests = [] }
        let atPlayhead = requests       // as evaluated (the prefetch's hidden-layer warm reads the same list)
        let durations = state.withLock { $0.clipDurations }
        var b = LayerBuild()
        b.scrub = snap.10 && snap.11 != t     // resting during a drag: the exact frame (FB-H), balanced subject matte
        b.playing = (!rate.isPaused || gate != nil) && !edge     // waiting to start counts as playing (proxy, mattes)
        // Motion Blur while playing: at most `playbackMaxSamples` shutter copies per layer (paused frames and export use all).
        if b.playing { requests = Self.thinnedForPlayback(requests) }
        // Seek, pause, step and scrub never wait for the text lane; a playing tick waits at most a frame, once.
        if b.playing, !b.scrub {
            let fd = tl.format.frameDuration
            b.textWait = TextGenerator.RasterWait(limit: min(Self.textWaitLimit, Double(fd.value) / Double(max(1, fd.timescale))))
        }
        b.forward = !(gate?.rate ?? rate).isReverse
        if b.playing, !b.scrub {
            // Magic mattes: the source frames the next ticks show, through each clip's own time mapping. The timeline
            // is evaluated again only for a coming time that crosses a clip edge.
            b.matteAhead = MatteLookAhead.sourceTimes(after: t, frame: tl.format.frameDuration, rate: gate?.rate ?? rate,
                                                      count: Self.magicMatteLookAhead, requests: requests, in: tl,
                                                      sequences: { sequences[$0] }) {
                tl.videoLayers(at: $0, sequences: { sequences[$0] })
            }
        }
        b.proxy = Self.usesProxy(scrubbing: b.scrub, playing: b.playing, use: state.withLock { $0.proxyUse })
        (b.uncovered, b.holdExpired) = state.withLock { s in
            (s.lastHidden, s.holdStart.map { $0.time == t && ContinuousClock.now - $0.since >= s.holdLimit } ?? false)
        }
        func build(_ r: LayerRequest) -> RenderLayer {
            let cold = b.noFrame
            let l = layer(for: r, scale: scale, build: &b, tl.format, durations)
            if r.generator?.kind == GeneratorRef.solid || r.isAdjustment { b.solids += 1 }     // no picture of their own
            if r.inTransition, b.noFrame > cold { b.coldInTransition += 1 }
            if b.noFrame > cold { b.coldKeys.insert(ShownKey(r)) }
            return l
        }
        // Hidden layers: the cover's layer is built first; only when it comes out as a picture (its exact frame or a
        // stand-in of the same clip, still opaque and of the known size) are the layers under it left out. A cover that
        // is loading, offline or damaged is a placeholder that hides nothing: everything is drawn then.
        let everyRequest = requests
        var hidden = Set<Int>(), cover: (index: Int, layer: RenderLayer, shown: Time?)?
        // The plan leaves hidden layers out only while this tick does: with a cover that is not drawn as a picture
        // (loading, offline, damaged) the layers below are planned like any other.
        var planCull = true
        let known = knownOpaque().pictures
        if !known.isEmpty {
            let picture = occlusionPicture(known, proxy: b.proxy)
            let o = LayerOcclusion.evaluate(requests, canvas: tl.format, picture: picture)
            if let c = o.cover {
                let l = build(requests[c])
                cover = (c, l, b.shown)
                b.shown = nil       // stays the bottom drawn layer's frame
                // The frame really drawn (the exact one, or a stand-in of the clip or of its proxy/original twin).
                let drawn = b.shownByClip[ShownKey(requests[c])]?.frame.media
                if case .frame = l.content, let p = picture(requests[c]), let drawn,
                   opaqueSources.withLock({ $0.pictures[drawn] }) == p { hidden = o.hidden } else { planCull = false }
            }
        }
        let hiddenKeys = Set(hidden.map { ShownKey(everyRequest[$0]) })
        if !hidden.isEmpty { requests = requests.indices.filter { !hidden.contains($0) }.map { requests[$0] } }
        for (i, r) in everyRequest.enumerated() where !hidden.contains(i) {
            if let cover, cover.index == i {
                b.layers.append(cover.layer)
                if b.shown == nil { b.shown = cover.shown }
            } else {
                b.layers.append(build(r))
            }
        }
        state.withLock { $0.afterLayers }?()
        profile.layers = b.layers.count; profile.missing = b.missing; profile.noFrame = b.noFrame
        profile.hidden = hidden.count
        // Start gate: this tick has every exact frame (or waited long enough): the clock starts here, at `t`; this tick
        // still composites as paused, the next one plays on.
        let planRate = gate?.rate ?? rate
        if let gate {
            let limit = state.withLock { $0.startGateLimit }
            let ready = b.missing == 0 && b.noFrame == 0
                && framesCached(tl, sequences: sequences, after: t, count: Self.startGateAhead, scale: scale, proxy: b.proxy,
                                reverse: gate.rate.isReverse)
            if ready || ContinuousClock.now - gate.since >= limit {
                openStartGate(at: t, gate: gate)
            }
        }

        // Every layer has no picture at all yet (far seek into undecoded media): keep showing the last presented frame
        // instead of a black placeholder; `incomplete` makes the next ticks retry until the decode lands. Bounded: a
        // decode that never lands falls through to the placeholder composite. One cold layer among others composites.
        // A clip that just came out from under its cover and has no close frame holds like a cold transition side.
        if Self.shouldHold(noFrame: b.noFrame, layers: b.layers.count, solids: b.solids,
                           coldInTransition: b.coldInTransition + b.coldUncovered,
                           hasLast: lastTime != nil, playing: !rate.isPaused && !edge,
                           moved: t != lastTime || !b.coldKeys.isSubset(of: snap.13)) {
            let wall = ContinuousClock.now
            let hold = state.withLock { s -> Bool in
                if s.holdStart?.time != t { s.holdStart = (t, wall) }
                return wall - s.holdStart!.since < s.holdLimit
            }
            if hold {
                profile.held = true
                profile.build = ContinuousClock.now - buildStart
                sp.endInterval("build", buildState)
                state.withLock { s in s.renderedGeneration = generation; s.incomplete = true }
                prefetch(timeline: tl, epoch: snap.14, at: t, rate: edge ? .zero : planRate, scale: scale, misses: b.misses,
                         scrubbing: b.scrub, cull: planCull, layersAtPlayhead: atPlayhead)
                return TickOutcome(presented: false, time: t, stoppedAtEdge: edge, position: position, clock: now, playing: clockRuns)
            }
        } else if b.noFrame == 0 {
            state.withLock { $0.holdStart = nil }
        }

        // A playing tick claims its frame before it composites: a pause parks on the newest claimed frame. One that the
        // main actor overtook (pause, seek, play) presents nothing: what it read is no longer the position.
        let playingTick = !rate.isPaused && !edge && gate == nil
        var handedBefore: Time?
        let overtaken = state.withLock { s -> Bool in
            guard clockSerial.load(ordering: .relaxed) == serial else { return playingTick }
            handedBefore = s.handed
            s.handed = playingTick ? t : nil
            return false
        }
        if overtaken {
            profile.build = ContinuousClock.now - buildStart
            sp.endInterval("build", buildState)
            return nil
        }

        // Composite + present
        var presented = false
        let failures = state.withLock { $0.renderFailures }
        var buildEnded = false
        func endBuild() {
            guard !buildEnded else { return }
            buildEnded = true
            profile.build = ContinuousClock.now - buildStart
            sp.endInterval("build", buildState)
        }
        defer { endBuild() }
        if let target = target(&g, format: tl.format), let cb = g.queue.makeCommandBuffer() {
            var encodeStart = ContinuousClock.now
            do {
                let captions = beyond ? [] : captionNodes(tl, at: t, build: &b)
                // Color page compare: Before draws the bypassed clips ungraded; Split composites them ungraded apart and
                // copies the left half over the graded picture.
                let bypass = state.withLock { $0.colorBypass }
                let ungraded = bypass.flatMap { ungradedLayers(b.layers, requests: requests, bypass: $0) }
                var split: [RenderNode]?
                var nodes: [RenderNode]
                if let ungraded, bypass?.isSplit == true {
                    nodes = RenderNode.tree(requests: requests, layers: b.layers) + captions
                    split = RenderNode.tree(requests: requests, layers: ungraded) + captions
                } else {
                    nodes = RenderNode.tree(requests: requests, layers: ungraded ?? b.layers) + captions
                }
                // The real composite failed repeatedly: show the "damaged" placeholder instead of staying black.
                if failures >= Self.fallbackAfter {
                    nodes = [.layer(RenderLayer(content: .placeholder(.damaged), transform: ClipTransform()))]
                    split = nil
                    b.unavailable += 1
                }
                if captureNodes.load(ordering: .relaxed) { lastNodes.withLock { $0 = (nodes, tl.format) } }
                endBuild()
                encodeStart = ContinuousClock.now
                let encodeState = sp.beginInterval("encode", id: tickID)
                defer { sp.endInterval("encode", encodeState) }
                g.compositor.gradesAtDisplaySize = previewGrade
                let backdrop: Compositor.Background = state.withLock { $0.transparencyGrid } ? .transparent : .black
                try g.compositor.render(nodes: nodes, format: tl.format, into: target, commandBuffer: cb, background: backdrop)
                if let split, let other = splitTarget(&g, format: tl.format) {
                    try g.compositor.render(nodes: split, format: tl.format, into: other, commandBuffer: cb, background: backdrop)
                    let w = ColorBypass.splitWidth(target.width)
                    if w > 0, let blit = cb.makeBlitCommandEncoder() {
                        blit.copy(from: other, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                  sourceSize: MTLSize(width: w, height: target.height, depth: 1), to: target,
                                  destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                        blit.endEncoding()
                    }
                } else {
                    g.splitTarget = nil     // a full canvas texture is only kept while Split is showing
                }
                if let presenter {
                    if let drawable { presenter.present(target, zoom: zoom, drawable: drawable, commandBuffer: cb) }
                    else { presenter.present(target, zoom: zoom, commandBuffer: cb) }
                }
                presented = true
            } catch {
                presented = false
            }
            if presented {
                let all = pendingCapture.withLock { c -> [FrameCaptureEncoder] in defer { c = [:] }; return Array(c.values) }
                for encode in all { if let done = encode(target, cb) { cb.addCompletedHandler { _ in done() } } }
            }
            profile.encode = ContinuousClock.now - encodeStart
            let shownAt = t
            cb.addCompletedHandler { [weak self] cb in
                let gpu = Duration.seconds(max(0, cb.gpuEndTime - cb.gpuStartTime))
                self?.lastProfile.withLock { p in if p?.time == shownAt, p?.gpu == nil { p?.gpu = gpu } }
            }
            cb.commit()
            if presenter == nil {
                let w0 = ContinuousClock.now
                cb.waitUntilCompleted()
                profile.gpuWait = ContinuousClock.now - w0
                profile.gpu = .seconds(max(0, cb.gpuEndTime - cb.gpuStartTime))
            }
            if presented { lastTexture.withLock { $0 = RenderedTexture(texture: target) } }
        }

        profile.presented = presented
        profile.missing = b.missing
        let isNew = t != lastTime
        let playing = !rate.isPaused && !edge
        // A/V drift: audio clock after the composite vs the frame just presented.
        var drift = Time.zero
        if presented && playing && audioMaster {
            let d = clock.now() - position
            drift = d.isNegative ? -d : d
        }
        state.withLock { s in
            if drift > s.stats.maxAVDrift { s.stats.maxAVDrift = drift }
            // A composite that failed (texture allocation, encoder) is retried by the next ticks, not only after an edit;
            // a persistent failure gives up after `maxRenderRetries` so a paused loop does not spin.
            // The counter belongs to one generation: an edit or any other invalidation starts a fresh series of attempts.
            if s.failureGeneration != generation { s.failureGeneration = generation; s.renderFailures = 0 }
            if presented { s.renderFailures = 0 } else { s.renderFailures += 1 }
            if !presented && s.renderFailures == Self.maxRenderRetries + 1 {
                Self.log.error("composite failed \(Self.maxRenderRetries, privacy: .public) times in a row: giving up until the next change")
            }
            if presented || s.renderFailures > Self.maxRenderRetries { s.renderedGeneration = generation }
            // Given up: the frame on screen is a stale one, not this generation's (Export Frame must not take it).
            if !presented && s.renderFailures > Self.maxRenderRetries { s.lastComplete = false }
            s.incomplete = b.waiting
            // The composite failed: its frame was not handed over after all.
            if !presented, playingTick, clockSerial.load(ordering: .relaxed) == serial { s.handed = handedBefore }
            guard presented else { return }
            s.lastTime = t
            s.lastPreviewGrade = previewGrade
            s.lastComplete = b.missing == 0 && b.noFrame == 0
            s.lastUnavailable = b.unavailable > 0
            s.lastPresentedZoom = zoom
            // A composite with a cold layer was presented (the hold ran out): a later cold spell holds afresh.
            if b.noFrame > 0 { s.holdStart = nil }
            s.lastCold = b.coldKeys
            s.lastHidden = hiddenKeys
            s.stats.presentedFrames += 1
            if b.noFrame > 0 { s.stats.placeholderComposites += 1 }
            s.stats.lastShownPTS = b.shown
            // Frames of a tick that overlapped a relink or proxy change may come from the old file: not kept as stand-ins.
            guard s.sourceEpoch == snap.12 else { return }
            // A hidden clip keeps no stand-in: what it showed before the cover is not its picture when it comes back.
            let clips = Set(requests.map(ShownKey.init))
            lastShownByClip.withLock { m in
                m.merge(b.shownByClip) { _, new in new }
                m = m.filter { clips.contains($0.key) }
            }
            // A drop is a playing frame shown without its exact picture; a paused seek/step waiting for decode is not.
            if isNew && b.missing > 0 && playing && !stepPending { s.stats.droppedFrames += 1 }
            if let p = s.pendingStep, p.target == t, b.missing == 0 {
                if p.scrub { s.stats.scrubLatencies.append(ContinuousClock.now - p.start) }
                else { s.stats.stepLatencies.append(ContinuousClock.now - p.start) }
                s.pendingStep = nil
            }
        }

        let prefetchStart = ContinuousClock.now
        prefetch(timeline: tl, epoch: snap.14, at: t, rate: edge ? .zero : planRate, scale: scale, misses: b.misses,
                 scrubbing: b.scrub, cull: planCull, layersAtPlayhead: atPlayhead)
        profile.prefetch = ContinuousClock.now - prefetchStart
        if presented && Self.warmsTextures {
            let next = warmSteps.withLock { $0.next(after: t, forward: b.forward, playing: b.playing && !edge, frame: fd) }
            if !next.isEmpty {
                warmNextTextures(tl, sequences: sequences, at: next, scale: scale, proxy: b.proxy, compositor: g.compositor)
            }
        }
        return TickOutcome(presented: presented, time: t, stoppedAtEdge: edge, position: position, clock: clockRead, playing: clockRuns)
    }

    /// Frames after the start frame the start gate also waits for (the first GOP of a second layer often lands later).
    static let startGateAhead = 5

    /// Whether the `count` grid frames after `t` (in play direction) have every decodable layer's exact frame cached.
    /// Layers of media not opened yet, offline or damaged do not block (the tick shows what it can).
    private func framesCached(_ tl: Timeline, sequences: [Timeline.ID: Timeline], after t: Time, count: Int,
                              scale: DecodeScale, proxy useProxy: Bool, reverse: Bool, includingStart: Bool = false) -> Bool {
        let fd = tl.format.frameDuration
        let picture = occlusionPicture(knownOpaque().pictures, proxy: useProxy)     // hidden layers are not waited for
        for k in (includingStart ? 0 : 1)...max(1, count) {
            let u = reverse ? t - fd * Int64(k) : t + fd * Int64(k)
            guard u >= .zero, u < tl.duration else { break }
            let layers = Self.visible(tl.videoLayers(at: u, sequences: { sequences[$0] }), canvas: tl.format, picture: picture)
            for r in layers where r.generator == nil && !r.isAdjustment {
                guard case .ready(let d) = media.known(r.media) else { continue }
                var src: (id: UUID, demuxer: any Demuxing) = (r.media, d)
                if useProxy, let p = proxy(for: r.media, original: d) { src = p }
                let index = src.demuxer.index
                guard index.count > 0 else { continue }
                let f = Self.frameIndex(r.sourceTime, in: index)
                if media.isDamaged(src.id, frame: f) { continue }
                if cache.frame(FrameKey(media: src.id, pts: index.entries[f].pts, scale: scale)) == nil { return false }
            }
        }
        return true
    }

    /// Render thread: asks the main actor to start the held clock at `t` (`takeStartGateOpen`). Never starts the clock
    /// here: a pause or seek on the main actor in between must win, and audio starts on the main actor.
    private func openStartGate(at t: Time, gate: StartGate) {
        let notify = state.withLock { s -> Bool in
            guard let g = s.startGate, g.token == gate.token else { return false }
            let fresh = s.pendingOpen?.token != g.token
            s.pendingOpen = (g.token, t, g.rate)
            return fresh
        }
        if notify { gateOpener.call() }
    }

    private static let log = Logger(subsystem: "de.paulherter.SequenceStudio", category: "text")
    private let textStandIns = TextStandIns()
    let lookPreview = LookPreviewState()

    /// Renders the first raster of a text on a background task (never on the render or main thread) and redraws.
    func prewarmText(_ ref: GeneratorRef) {
        TextGenerator.warmInBackground(ref) { [weak self] in self?.invalidate() }   // table shared with Follow's measure
    }

    /// Text generator layer, animation folded into the transform. A raster that is not ready yet is requested in the
    /// background and the layer stays invisible until then (the loop keeps re-rendering while `waiting`).
    private func textLayer(_ r: LayerRequest, _ ref: GeneratorRef, canvas: SequenceFormat, durations: [Clip.ID: Time],
                           build b: inout LayerBuild) -> RenderLayer {
        func invisible() -> RenderLayer {
            var tr = r.transform; tr.opacity = 0
            return RenderLayer(content: .placeholder(.loading), transform: tr)
        }
        let ref = lookPreview.text(ref, container: r.groups.last?.clip ?? r.clip, layer: r.clip)   // Look hover preview (display only)
        if TextGenerator.layoutFailed(ref) { return invisible() }
        // A raster still being rendered (size drag, typing) keeps the clip's last one on screen instead of blinking out.
        let shown = textStandIns.resolve(clip: r.clip, group: r.groups.last?.clip, ref: ref, isCached: { TextGenerator.isCached(ref: $0) })
        if shown != ref { prewarmText(ref); b.waiting = true }
        guard let ref = shown else { return invisible() }
        let dur = r.clipDuration ?? durations[r.clip] ?? r.localTime
        let frame: TextFrame?
        // An in-between frame of a text animator is the painted part only, which is what makes it cheap enough to draw
        // ahead. The compositor draws it as a part of the whole box (`contentPart`): the whole box's size and transform,
        // so the picture is the whole-box frame's (the export's) under any scale and rotation, and whatever reads the
        // layer's rectangle (corner radius, crop, masks, blur, blend) reads the whole one.
        let cropped = cropsTextClips.withLock { $0 }
        do {
            frame = try TextGenerator.frame(ref: ref, localTime: r.localTime, clipDuration: dur, canvas: canvas, scale: 1,
                                            cropped: cropped, wait: b.textWait)
        } catch {
            Self.log.error("text frame failed: \(String(describing: error), privacy: .public)")
            TextGenerator.markLayoutFailed(ref)   // reported once, not on every tick
            return invisible()
        }
        guard let f = frame else { return invisible() }   // empty text
        // A text animator's next frames are rastered ahead, off this thread, in the direction the playhead travels.
        let step = b.forward ? canvas.frameDuration : .zero - canvas.frameDuration
        if cropped {
            TextGenerator.warmAnimatedInBackground(ref: ref, from: r.localTime + step, step: step, count: Self.animatedTextLookAhead,
                                                   clipDuration: dur)
        }
        if f.isPart {
            var layer = RenderLayer(content: .linearPremultiplied(f.buffer, width: f.wholeWidth, height: f.wholeHeight),
                                    transform: f.layerTransform(base: r.transform, canvas: canvas, whole: true),
                                    cornerRadius: r.cornerRadius)
            layer.contentPart = .init(x: f.partX, y: f.partY, wholeWidth: f.wholePixelWidth, wholeHeight: f.wholePixelHeight)
            return layer.withFootageFill(of: ref)
        }
        return RenderLayer(content: .linearPremultiplied(f.buffer, width: f.width, height: f.height),
                           transform: f.layerTransform(base: r.transform, canvas: canvas), cornerRadius: r.cornerRadius)
            .withFootageFill(of: ref)
    }

    /// Captions of the visible caption tracks at `t`, on top of the picture (Program monitor). Same rasters and the
    /// same placement as the export burn-in. Upcoming captions are prepared in the background; one that is still cold
    /// on its frame is rendered right here, never left out (it would blink for a frame).
    private func captionNodes(_ tl: Timeline, at t: Time, build b: inout LayerBuild) -> [RenderNode] {
        guard state.withLock({ $0.showCaptions }) else { return [] }
        // The look-ahead below draws what the ticks will ask for: the previewed Look's library and highlight too.
        let library = lookPreview.captionLibrary(over: captionLibrary())
        prewarmUpcomingCaptions(tl, after: t, library: library, forward: b.forward)
        // One slot per track: the caption showing, with its hand-over (ENGINE-NOTES "Caption hand-over"; the burn-in
        // asks the same `CaptionHandover`). One lookup for this frame and the look-ahead, prepared
        // by `setTimeline` (like `clipDurations`, it is the newest timeline's: an edit landing in this tick renders again).
        guard let lookup = state.withLock({ $0.captionLookup }), lookup.timeline == tl.id, !lookup.isEmpty else { return [] }
        prewarmAnimatedCaptions(tl, lookup, after: t, library: library, forward: b.forward)
        let slots = lookup.slots(at: t)
        guard !slots.isEmpty else { return [] }
        var out: [RenderNode] = []
        let cropped = cropsTextClips.withLock { $0 }
        /// One layer of `item` at clip time `local` of `duration`, its opacity times `opacity`.
        func layer(_ r: GeneratorRef, of item: CaptionItem, local: Time, duration: Time, opacity: Double = 1) -> RenderNode? {
            guard !TextGenerator.layoutFailed(r) else { return nil }
            guard let f = try? TextGenerator.frame(ref: r, localTime: local, clipDuration: duration,
                                                   canvas: tl.format.layoutFormat, scale: 1, cropped: cropped, wait: b.textWait) else {
                TextGenerator.markLayoutFailed(r)
                return nil
            }
            let base = ClipTransform(position: CaptionPreview.position(for: item, canvas: tl.format.layoutFormat, library: library))
            // A cropped in-between frame is drawn as a part of the whole caption raster, like a text clip's
            // (`textLayer`): the whole raster's quad and transform, read in place, so the picture is the whole-box
            // frame's under the look's scale and rotation, and only where the part can show is drawn.
            var tr = f.layerTransform(base: base, canvas: tl.format.layoutFormat, pivotAtText: true, whole: f.isPart)
            tr.opacity *= opacity
            guard f.isPart else {
                return .layer(RenderLayer(content: .linearPremultiplied(f.buffer, width: f.width, height: f.height), transform: tr))
            }
            var layer = RenderLayer(content: .linearPremultiplied(f.buffer, width: f.wholeWidth, height: f.wholeHeight), transform: tr)
            layer.contentPart = .init(x: f.partX, y: f.partY, wholeWidth: f.wholePixelWidth, wholeHeight: f.wholePixelHeight)
            return .layer(layer)
        }
        for s in slots {
            // The plain caption is one raster for the whole caption; the lit word is a second layer on top (the same two
            // layers the export burn-in draws). A lit layer that is not ready is skipped, never the caption.
            let karaoke = lookPreview.karaoke(tl.captionTrack(s.track)?.karaoke)
            guard let plan = try? CaptionPreview.plan(for: s.item, karaoke: karaoke, canvas: tl.format.layoutFormat, at: t, library: library,
                                                    held: s.held, forward: b.forward)
            else { continue }
            let ref = plan.plain
            if TextGenerator.layoutFailed(ref) { continue }
            // A raster that is not ready is rendered here, on the render thread: a caption left out of a frame blinks
            // (first play after a seek, every new caption). The look-ahead below makes this rare.
            guard renderCaptionNow(ref) else { continue }
            var local = t - s.item.range.start
            // Hand-over (`CaptionHandover.draw`, the one request the export burn-in makes too): no empty first frame
            // after an out look; the caption before stays under this one, at its end state, for what this one's
            // in-animation does not show yet (only while that runs: afterwards a tick asks for nothing here).
            if let tail = s.tail, let entering = CaptionPreview.animations(for: s.item, library: library) {
                let d = CaptionHandover.draw(previous: CaptionPreview.animations(for: tail, library: library), entering: entering,
                                             naturalClipTime: local, frameDuration: tl.format.frameDuration) { TextGenerator.units(ref: ref) }
                local = d.clipTime
                if d.tailOpacity > 0, let tp = try? CaptionPreview.plan(for: tail, karaoke: karaoke, canvas: tl.format.layoutFormat,
                                                                       at: t, library: library, held: true),
                   renderCaptionNow(tp.plain),
                   let node = layer(tp.plain, of: tail, local: s.tailDuration, duration: s.tailDuration, opacity: d.tailOpacity) {
                    out.append(node)
                    if let lit = tp.lit, renderCaptionNow(lit),
                       let n = layer(lit, of: tail, local: s.tailDuration, duration: s.tailDuration, opacity: d.tailOpacity) { out.append(n) }
                }
            }
            guard let plainNode = layer(ref, of: s.item, local: local, duration: s.duration) else { continue }
            out.append(plainNode)
            if let n = plan.next { prewarmText(n) }
            if let lit = plan.lit, renderCaptionNow(lit), let node = layer(lit, of: s.item, local: local, duration: s.duration) {
                out.append(node)
            }
        }
        return out
    }

    /// In-between frames of a text animator are rastered this many frames ahead of the playhead.
    static let animatedTextLookAhead = 4
    /// Source frames ahead of the shown one (in the playing direction) whose Magic mattes are prepared off the render
    /// thread (`MagicMatteStore.prepare`). Three masks: 15 mattes live, inside the store's LRU of 24.
    static let magicMatteLookAhead = 4
    /// Most a playing tick waits (all its text frames together) for frames the text lane is drawing; never over a frame.
    static let textWaitLimit = 0.04

    /// Captions whose look has a text animator (per character, word or line) need one raster per in-between frame: the
    /// frames the playhead reaches next (`forward`: the direction it travels) are rastered in the background, so the
    /// render thread finds them in the cache.
    private func prewarmAnimatedCaptions(_ tl: Timeline, _ lookup: CaptionSlotLookup, after t: Time,
                                         library: CaptionPresetLibrary, forward: Bool) {
        let step = tl.format.frameDuration
        guard step > .zero else { return }
        for k in 1...Self.animatedTextLookAhead {
            let at = forward ? t + step * Int64(k) : t - step * Int64(k)
            guard at >= .zero else { break }
            for a in lookup.slots(at: at) {
                let entering = CaptionPreview.animations(for: a.item, library: library)
                var local = at - a.item.range.start
                if let tail = a.tail, local < step * CaptionHandover.maxEnteringShiftFrames, let entering,
                   let prev = CaptionPreview.animations(for: tail, library: library) {
                    // The frame that is drawn at a hand-over after an out look (`CaptionHandover.enteringClipTime`), asked
                    // with the same units as the render path (the plain raster's, once cached), so both pick the same time.
                    let plain = try? CaptionPreview.plan(for: a.item, karaoke: lookPreview.karaoke(tl.captionTrack(a.track)?.karaoke),
                                                         canvas: tl.format.layoutFormat, at: at, library: library, held: a.held).plain
                    local = CaptionHandover.enteringClipTime(previous: prev, entering: entering, clipTime: local,
                                                             frameDuration: step) { plain.flatMap { TextGenerator.units(ref: $0) } }
                }
                // The caption before is drawn under this one at its end state while this one comes in (hand-over): when
                // its animator is not at rest there (a caption shorter than its animation), that raster is made ahead too.
                if let tail = a.tail, let entering, local < entering.entranceEnd,
                   let tailSet = CaptionPreview.animations(for: tail, library: library), tailSet.hasTextAnimator,
                   tailSet.animationOut == nil,
                   let tp = try? CaptionPreview.plan(for: tail, karaoke: lookPreview.karaoke(tl.captionTrack(a.track)?.karaoke), canvas: tl.format.layoutFormat,
                                                     at: at, library: library, held: true) {
                    for ref in [tp.plain, tp.lit].compactMap({ $0 }) {
                        TextGenerator.warmAnimatedInBackground(ref: ref, from: a.tailDuration, step: step,
                                                               clipDuration: a.tailDuration, includingEnd: true)
                    }
                }
                guard entering?.hasTextAnimator == true else { continue }
                guard let plan = try? CaptionPreview.plan(for: a.item, karaoke: lookPreview.karaoke(tl.captionTrack(a.track)?.karaoke), canvas: tl.format.layoutFormat,
                                                          at: at, library: library, held: a.held) else { continue }
                for ref in [plan.plain, plan.lit].compactMap({ $0 }) {
                    TextGenerator.warmAnimatedInBackground(ref: ref, from: local, step: step, clipDuration: a.duration)
                }
            }
        }
    }

    /// Caption rasters start this far ahead of their caption while the playhead moves towards them.
    static let captionLookAhead = Time(1, 1)

    /// Renders a caption raster synchronously when it is not cached yet (counted in the stats). False when it failed.
    private func renderCaptionNow(_ ref: GeneratorRef) -> Bool {
        if TextGenerator.isCached(ref: ref) { return true }
        if TextGenerator.layoutFailed(ref) { return false }
        let start = ContinuousClock.now
        do { try TextGenerator.prewarm(ref: ref) } catch {
            Self.log.error("caption raster failed: \(String(describing: error), privacy: .public)")
            TextGenerator.markLayoutFailed(ref)
            return false
        }
        let took = ContinuousClock.now - start
        state.withLock { s in
            s.stats.captionSyncRenders += 1
            if took > s.stats.maxCaptionSyncRender { s.stats.maxCaptionSyncRender = took }
        }
        return true
    }

    /// Prepares, in the background, the rasters of the captions that start within `captionLookAhead` after `t` (plain
    /// caption and its first lit word), so the frame where a caption appears does not have to render it. Playing
    /// backwards (`forward` false) a caption appears at its end: the ones that end within the look-ahead before `t`.
    private func prewarmUpcomingCaptions(_ tl: Timeline, after t: Time, library: CaptionPresetLibrary, forward: Bool) {
        func warm(_ item: CaptionItem, _ track: CaptionTrack, at: Time) {
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let plan = try? CaptionPreview.plan(for: item, karaoke: lookPreview.karaoke(track.karaoke), canvas: tl.format.layoutFormat,
                                                      at: at, library: library) else { return }
            prewarmText(plan.plain)
            if let lit = plan.lit { prewarmText(lit) }
        }
        let horizon = forward ? t + Self.captionLookAhead : t - Self.captionLookAhead
        let frame = tl.format.frameDuration
        for track in tl.captionTracks where track.isVisible {
            if forward {
                guard let i = track.items.firstIndex(where: { $0.range.start > t }) else { continue }
                for item in track.items[i...] {
                    if item.range.start > horizon { break }
                    warm(item, track, at: item.range.start)
                }
            } else {
                // Its last frame is the first one shown (the word lit there, not the first word): the last time before its
                // end on the frame grid the playhead walks from `t`, not a frame before an end that lies off the grid.
                guard frame > .zero, let i = track.items.lastIndex(where: { $0.range.end <= t }) else { continue }
                for item in track.items[...i].reversed() {
                    if item.range.end < horizon { break }
                    let first = t - frame * ((t - item.range.end).frameIndex(frameDuration: frame) + 1)
                    warm(item, track, at: max(item.range.start, first))
                }
            }
        }
    }

    /// Every clip id of the timeline and its nested sequences (stand-ins of clips that left are dropped).
    static func allClipIDs(_ tl: Timeline, sequences: [Timeline.ID: Timeline]) -> Set<Clip.ID> {
        var out = Set<Clip.ID>()
        for t in [tl] + Array(sequences.values) { for tr in t.tracks { for c in tr.clips { out.insert(c.id) } } }
        return out
    }

    /// The texts of the timeline and its nested sequences. With `time` (a time of `tl`): without the items of `tl`'s
    /// Graphics whose range does not contain it (the gate render uses, `isShown`), so nothing is rastered for an item that
    /// is not shown. Nested sequences run on their own time and keep every item with a range that can show.
    static func textRefs(_ tl: Timeline, sequences: [Timeline.ID: Timeline], at time: Time? = nil) -> Set<GeneratorRef> {
        var out = Set<GeneratorRef>()
        for (n, t) in ([tl] + Array(sequences.values)).enumerated() {
            for tr in t.tracks {
                for c in tr.clips {
                    if let g = c.generator, g.kind == GeneratorRef.text { out.insert(g) }
                    // GFX: text layers of graphics clips (not an item whose range is empty: it never shows).
                    for l in c.graphics?.layers ?? [] where l.range?.isEmpty != true {
                        if n == 0, let time, l.range != nil, !(c.timeline.contains(time) && l.isShown(atLocal: time - c.start)) { continue }
                        if case .text(let g) = l.content { out.insert(g) }
                    }
                }
            }
        }
        return out
    }

    /// Clip durations of text generators (their animations' out-anchor needs the clip length).
    static func textDurations(_ tl: Timeline, sequences: [Timeline.ID: Timeline]) -> [Clip.ID: Time] {
        var d: [Clip.ID: Time] = [:]
        for t in [tl] + Array(sequences.values) { for tr in t.tracks { for c in tr.clips where c.isGenerator { d[c.id] = c.source.duration } } }
        return d
    }

    /// The layer with the clip's effects (Crop, Rounded Corners, Gaussian Blur) and blend mode attached.
    private func layer(for r: LayerRequest, scale: DecodeScale, build b: inout LayerBuild,
                       _ format: SequenceFormat, _ durations: [Clip.ID: Time]) -> RenderLayer {
        baseLayer(for: r, scale: scale, build: &b, format, durations).applying(r)
    }

    private func baseLayer(for r: LayerRequest, scale: DecodeScale, build b: inout LayerBuild,
                           _ format: SequenceFormat, _ durations: [Clip.ID: Time]) -> RenderLayer {
        func placeholder(_ k: PlaceholderKind) -> RenderLayer {
            if k != .loading { b.unavailable += 1 }
            return RenderLayer(content: .placeholder(k), transform: r.transform, cornerRadius: r.cornerRadius)
        }
        if let g = r.generator, g.kind == GeneratorRef.solid {
            let grade = media.resolver.colorResolver?.pipeline(for: r.color, media: r.media, owner: r.clip)
            return RenderLayer.solid(payload: g.payload, transform: r.transform, colorPipeline: grade,
                                     cornerRadius: r.cornerRadius)
        }
        if let g = r.generator, g.kind == GeneratorRef.shape { return ShapeRenderer.layer(for: r) }
        if r.isAdjustment {
            // Lumetri on an Adjustment Layer grades the picture below it (no media: Rec.709 unless the grade overrides it).
            return RenderLayer.adjustment(transform: r.transform,
                                          colorPipeline: media.resolver.colorResolver?.pipeline(for: r.color, media: r.media, owner: r.clip))
        }
        if let g = r.generator, g.kind == GeneratorRef.dateStamp {
            // Date Stamp: the same text layer as a title, built from its spec (the raster changes at most once a second).
            guard let t = DateStampText.textRef(for: g) else { return placeholder(.offline) }
            return textLayer(r, t, canvas: format, durations: durations, build: &b)
        }
        if let g = r.generator, g.kind == GeneratorRef.lottie { return LottieRenderer.layer(for: r, canvas: format) }
        if let g = r.generator {
            return g.kind == GeneratorRef.text ? textLayer(r, g, canvas: format, durations: durations, build: &b) : placeholder(.offline)
        }
        // Never asks the resolver here (opening a file can block): a media not resolved yet is opened on a background queue
        // and the loop redraws when it is known; until then the layer counts as "no picture yet" (the last frame is held).
        let d: any Demuxing
        switch media.known(r.media) {
        case .unresolved:
            resolveSoon(r.media); b.noFrame += 1; b.waiting = true
            return placeholder(.loading)
        case .offline:
            return placeholder(.offline)
        case .still(let still):
            learnOpaque(r.media, nil, drawn: true)      // a still may carry alpha: never a cover
            var layer = RenderLayer(content: .frame(still.frame, colorHint: still.info), transform: r.transform,
                                    colorPipeline: media.resolver.colorResolver?.pipeline(for: r.color, media: r.media, owner: r.clip),
                                    cornerRadius: r.cornerRadius, nativeSize: (still.info.desqueezedWidth, still.info.height))
            // A still is one frame (index 0), segmented once per quality like a video frame.
            attachSubjectMatte(&layer, r, frame: still.buffer, rotation: still.info.rotation, source: r.media, frameIndex: 0,
                               ahead: [], build: &b)
            if !r.effects.magicMattes.isEmpty {
                // One picture, no source time. An Anonymize cover takes the matte tracked on it, else the whole frame.
                layer.mattes = magicStore.mattes(for: r.effects, pts: 0, frameWidth: Double(still.info.displayWidth),
                                                 warped: r.gyro != nil, still: true, wait: false)
            }
            return layer
        case .ready(let demuxer):
            d = demuxer
        }
        // W9.9: a ready proxy is decoded under its own key (`sid`); a damaged proxy frame falls back to the original.
        var src: (id: UUID, demuxer: any Demuxing) = (r.media, d)
        if b.proxy, let p = proxy(for: r.media, original: d),
           !media.isDamaged(p.id, frame: Self.frameIndex(r.sourceTime, in: p.demuxer.index)) {
            src = p
        }
        let sid = src.id
        let index = src.demuxer.index
        guard index.count > 0 else { return placeholder(.damaged) }
        let f = Self.frameIndex(r.sourceTime, in: index)
        let key = FrameKey(media: sid, pts: index.entries[f].pts, scale: scale)
        var frame = cache.frame(key)
        if frame == nil {
            // The frame to wait for. Keyframe scrub: the sync frame, and any cached frame between it and the target is as
            // good (closer to the target; a GOP decode that delivered part of the way).
            var want = f
            if b.scrub {
                want = PrefetchPlanner.scrubFrame(for: f, in: index)
                if let n = cache.nearest(media: sid, atOrBefore: key.pts, scale: scale), n.pts >= index.entries[want].pts { frame = n }
            }
            if frame == nil {
                if media.isDamaged(sid, frame: want) { return placeholder(.damaged) }
                b.missing += 1; b.waiting = true; b.misses.append((sid, want))
                if b.uncovered.contains(ShownKey(r)), !b.holdExpired {
                    frame = closeFrame(for: r, sid: sid, target: key.pts, within: index.entries[f].duration, scale: scale)
                    if frame == nil { b.coldUncovered += 1 }
                } else {
                    frame = fallbackFrame(for: r, sid: sid, target: key.pts, scale: scale)
                }
            }
        }
        guard let frame else { b.noFrame += 1; return placeholder(.loading) }
        if b.shown == nil { b.shown = frame.pts }
        b.shownByClip[ShownKey(r)] = ShownFrame(frame: frame, media: r.media)
        let info = sourceInfo(of: frame, media: r.media, demuxer: d)
        learnOpaque(frame.media, Self.opaquePicture(frame.pixelBuffer, info), drawn: true)
        // Frame Blending: the next source frame and the fractional position, when the source time lies between two frames.
        // The second frame must already be cached (the planner's window covers it); otherwise the first frame shows alone and
        // the missing one is requested, so the blend appears as soon as it is decoded without ever stalling the picture.
        // Gyroflow Stabilizer: the decoded frame warped by the camera's gyro data before anything else (same call as
        // export). Until the clip's analysis is ready the frame shows unwarped; the engine's observer redraws then.
        // A proxy frame is warped with the original's gyro data (same frame times; the engine scales smaller buffers).
        let gyro = r.gyro.flatMap { g in media.resolver.gyroWarper.map { (g, $0) } }
        func stabilised(_ f: SQFrame, pts: Time) -> SQFrame {
            guard let (g, warper) = gyro else { return f }
            return warper.warp(f.pixelBuffer, media: r.media, options: g, pts: pts, wait: false)
                .map { SQFrame(pixelBuffer: $0, presentationTime: f.presentationTime) } ?? f
        }
        let pixels = stabilised(frame.frame, pts: frame.pts)
        var blend: FrameBlend?
        // Source times of the other frames mixed into this one: an Anonymize cover takes all of them.
        var mixed: [Double] = []
        func seconds(_ t: Time) -> Double { Double(t.value) / Double(max(t.timescale, 1)) }
        if Self.blends(r, frame: frame, sid: sid, scrub: b.scrub, f: f, in: index) {
            let w = FrameBlend.weight(sourceTime: r.sourceTime, frameStart: index.entries[f].pts, frameDuration: index.entries[f].duration)
            if w > 0 {
                if let next = cache.frame(FrameKey(media: sid, pts: index.entries[f + 1].pts, scale: scale)), frame.pixelBuffer !== next.pixelBuffer {
                    mixed.append(seconds(next.pts))
                    blend = FrameBlend(next: stabilised(next.frame, pts: next.pts), weight: w,
                                       flow: Self.flowRequest(r, sid: sid, from: frame.pts, to: next.pts, playing: b.playing))
                } else {
                    b.misses.append((sid, f + 1))
                }
            }
        }
        // Video Denoise / Deflicker: the neighboring source frames from the cache (only for the exact frame `f`; a stand-in
        // shows plain). Playing or scrubbing: the fast filter with what is cached; paused: the full filter, waiting for its
        // window. Takes the place of Frame Blending.
        var temporal: TemporalFrames?
        if let filter = r.effects.temporal, frame.media == sid, frame.pts == index.entries[f].pts {
            let exact = !b.playing && !b.scrub
            var requests: [Int] = [], wait = false
            temporal = Self.temporalNeighbours(
                of: f, filter: filter, exact: exact, bounds: Self.temporalBounds(r, around: f, in: index),
                cached: { i in cache.frame(FrameKey(media: sid, pts: index.entries[i].pts, scale: scale)).map { stabilised($0.frame, pts: $0.pts) } },
                damaged: { media.isDamaged(sid, frame: $0) },
                request: { requests.append($0) }, wait: { wait = true })
            if !b.scrub { for i in requests { b.misses.append((sid, i)) } }
            if wait { b.waiting = true }
            blend = nil
            // The neighbors actually mixed: a run of frames on each side of `f`.
            let before = temporal?.before.count ?? 0, after = temporal?.after.count ?? 0
            mixed = ((f - before)..<f).map { seconds(index.entries[$0].pts) } + (f + 1..<f + 1 + after).map { seconds(index.entries[$0].pts) }
        }
        var layer = RenderLayer(content: .frame(pixels, colorHint: info), transform: r.transform,
                                colorPipeline: media.resolver.colorResolver?.pipeline(for: r.color, media: r.media, owner: r.clip),
                                cornerRadius: r.cornerRadius, nativeSize: (info.desqueezedWidth, info.height), blend: blend)
        layer.temporal = temporal
        if r.effects.needsSubjectMatte {
            // The frame actually shown (a scrub or nearest stand-in may differ from `f`) keys the smoother.
            let shown = Self.frameIndex(frame.pts, in: index)
            var ahead: [(CVPixelBuffer, Int)] = []
            if b.playing {
                for k in 1...2 {
                    let n = shown + (b.forward ? k : -k)
                    guard index.entries.indices.contains(n),
                          let next = cache.frame(FrameKey(media: sid, pts: index.entries[n].pts, scale: scale)) else { break }
                    ahead.append((stabilised(next.frame, pts: next.pts).pixelBuffer, n))
                }
            }
            attachSubjectMatte(&layer, r, frame: pixels.pixelBuffer, rotation: info.rotation, source: sid, frameIndex: shown,
                               pts: Double(frame.pts.value) / Double(max(frame.pts.timescale, 1)), ahead: ahead, build: &b)
        }
        if !r.effects.magicMattes.isEmpty {
            // Magic masks only read their tracked mattes (decoded and edged once per frame, then from the store's LRU).
            // An Anonymize cover takes every frame in the mix (the box around them under optical flow; too many: the
            // whole frame) and never waits here: until its file is read and its grown matte made, the whole frame.
            let fw = Double(info.displayWidth)
            let many = mixed.count > MagicMatteStore.maxNeighbors
            // Playing: the mattes of the frames the next ticks show (`MatteLookAhead`: by the clip's own time mapping, so
            // reversed and retimed clips prepare the right ones) are decoded and edged on the store's background queue,
            // so this thread only reads them; paused or scrubbing it decodes the one frame itself.
            let playing = b.playing && !b.scrub
            if playing, let times = b.matteAhead[r.clip] {
                let coming = MatteLookAhead.frames(times, shown: Self.frameIndex(frame.pts, in: index), in: index)
                magicStore.prepare(for: r.effects, pts: coming, frameWidth: fw)
            }
            layer.mattes = magicStore.mattes(for: r.effects, pts: seconds(frame.pts), frameWidth: fw, warped: r.gyro != nil || many,
                                             neighbors: many ? [] : mixed, spanning: blend?.flow != nil, wait: false, playing: playing)
        }
        return layer
    }

    /// Playback form of the layer requests: motion-blur samples thinned to `MotionBlurSamples.playbackMaxSamples`.
    static func thinnedForPlayback(_ requests: [LayerRequest]) -> [LayerRequest] {
        requests.map { r in
            guard let mb = r.motionBlur, mb.transforms.count > MotionBlurSamples.playbackMaxSamples else { return r }
            var t = r
            t.motionBlur = mb.thinned(to: MotionBlurSamples.playbackMaxSamples)
            return t
        }
    }

    /// Video Denoise / Deflicker / Trails neighbors of source frame `f` (nearest first on each side) from the frame cache: the
    /// filter's own window when `exact`, the fast window otherwise (playing, scrubbing). A neighbor that is not cached ends
    /// its side; it is requested (not while scrubbing), and an exact frame keeps the loop waiting for it.
    static func temporalNeighbours(of f: Int, filter: TemporalFilter, exact: Bool, bounds: ClosedRange<Int>,
                                   cached: (Int) -> SQFrame?, damaged: (Int) -> Bool,
                                   request: (Int) -> Void, wait: () -> Void) -> TemporalFrames {
        let use = exact ? filter : filter.degraded(.fast)
        let n = TemporalWindow.neighbours(center: f, before: use.reachBack, after: use.reachAhead,
                                          lower: bounds.lowerBound, upper: bounds.upperBound)
        func side(_ idx: [Int]) -> [SQFrame] {
            var out: [SQFrame] = []
            for i in idx {
                if let pb = cached(i) { out.append(pb); continue }
                if damaged(i) { break }
                request(i)
                if exact { wait() }
                break
            }
            return out
        }
        return TemporalFrames(filter: use, before: side(n.before), after: side(n.after))
    }

    /// Source frames a temporal filter may read for layer `r` shown at frame `f`: the clip's source range (`sourceStart`
    /// ..< `sourceEnd`), widened to `f` itself (a transition showing a handle frame), within the media.
    static func temporalBounds(_ r: LayerRequest, around f: Int, in index: SampleIndex) -> ClosedRange<Int> {
        var lo = 0, hi = index.count - 1
        if let s = r.sourceStart { lo = frameIndex(s, in: index) }
        if let e = r.sourceEnd {
            hi = frameIndex(e, in: index)
            if hi > 0, index.entries[hi].pts >= e { hi -= 1 }
        }
        lo = min(lo, f); hi = max(hi, f)
        return lo...max(lo, hi)
    }

    /// Optical flow for a layer that mixes `from` with `to` (nil for Frame Blending). The pair's flow is cached by the
    /// compositor; a settled frame measures at export quality (the same pixels as export), playback the faster estimate.
    static func flowRequest(_ r: LayerRequest, sid: UUID, from: Time, to: Time, playing: Bool) -> OpticalFlowRequest? {
        guard r.interpolation == .opticalFlow else { return nil }
        return OpticalFlowRequest(key: FlowPairKey(media: sid, from: from, to: to, variant: r.gyro?.hashValue ?? 0),
                                  quality: playing ? .faster : .better)
    }

    /// Frame Blending mixes frame `f` with `f + 1`: only when the layer shows exactly frame `f` of its decoded source. A
    /// stand-in (the clip's last picture, a nearby cached frame, the proxy/original twin) is drawn alone (FB-H2).
    static func blends(_ r: LayerRequest, frame: DecodedFrame, sid: UUID, scrub: Bool, f: Int, in index: SampleIndex) -> Bool {
        !scrub && r.interpolation.mixesFrames && frame.media == sid && frame.pts == index.entries[f].pts && f + 1 < index.count
            && (r.sourceEnd.map { index.entries[f + 1].pts < $0 } ?? true)
    }

    /// The person matte for a subject-masked layer (never runs Vision here). First the precomputed matte of that source
    /// frame (`pts`, s); when it is not there yet the clip's range is queued for precompute and the scheduler segments
    /// the shown frame: fast while playing or scrubbing, balanced for a settled frame; a settled frame keeps the loop
    /// rendering until its own matte landed.
    private func attachSubjectMatte(_ layer: inout RenderLayer, _ r: LayerRequest, frame pb: CVPixelBuffer, rotation: Int,
                                    source: UUID, frameIndex: Int, pts: Double? = nil, ahead: [(CVPixelBuffer, Int)],
                                    build b: inout LayerBuild) {
        guard r.effects.needsSubjectMatte else { return }
        if let pts, let m = precomputedSubjectMatte(r, pts: pts) { layer.subjectMatte = m; return }
        let q = Self.subjectQuality(playing: b.playing, scrubbing: b.scrub)
        let res = subjects.matte(for: pb, rotationDegrees: rotation, key: .init(clip: r.clip, source: source),
                                 frameIndex: frameIndex, quality: q, ahead: ahead)
        layer.subjectMatte = res.matte
        if !res.exact && !b.playing { b.waiting = true }
    }

    /// The stored person matte of `r`'s media at source second `pts`, nil when not computed yet (then asks for the clip's
    /// source range, from `pts` on). Never reads a matte file here: a key not loaded yet is loaded by the precompute.
    private func precomputedSubjectMatte(_ r: LayerRequest, pts: Double) -> SubjectMatte? {
        let url = subjectFiles.withLock { f -> URL?? in f[r.media] } ?? {
            let u = media.resolver.fileURL(for: r.media)
            subjectFiles.withLock { $0[r.media] = .some(u) }
            return u
        }()
        guard let url else { return nil }
        let store = subjectPrecompute.store
        // The precompute reads the original file, so it deinterlaces as that file's decoder does (the media item's
        // setting); the key names the field order, read and request agree on it.
        let fields = media.deinterlace(r.media)
        let key = SubjectMattePrecompute.cacheKey(media: r.media, path: url.path, deinterlace: fields)
        if store.isLoaded(key), let m = store.matte(key: key, pts: pts, feather: 0, expansion: 0, frameWidth: 1) { return m }
        let fd = 1.0 / 24
        let local = Double(r.localTime.value) / Double(max(r.localTime.timescale, 1))
        let from = max(0, pts - local - fd)
        let to = r.sourceEnd.map { Double($0.value) / Double(max($0.timescale, 1)) } ?? pts + 60
        subjectPrecompute.request(media: r.media, url: url, from: from, to: max(to, pts), start: pts, deinterlace: fields)
        return nil
    }

    static func subjectQuality(playing: Bool, scrubbing: Bool) -> PersonSegmenter.Quality {
        playing || scrubbing ? .fast : .balanced
    }

    /// Media of the clips with a subject mask in the timeline and its nested sequences (their precompute goes on).
    static func subjectMaskMedia(_ tl: Timeline, sequences: [Timeline.ID: Timeline]) -> Set<UUID> {
        var out = Set<UUID>()
        for t in [tl] + Array(sequences.values) { for tr in t.tracks { for c in tr.clips where c.hasSubjectMask { out.insert(c.media) } } }
        return out
    }

    /// Clips with a subject mask in the timeline and its nested sequences (their matte state is kept).
    static func subjectMaskClips(_ tl: Timeline, sequences: [Timeline.ID: Timeline]) -> Set<UUID> {
        var out = Set<UUID>()
        for t in [tl] + Array(sequences.values) { for tr in t.tracks { for c in tr.clips where c.hasSubjectMask { out.insert(c.id) } } }
        return out
    }

    /// FB-H: the picture while the wanted frame decodes. Never off the path between what the clip showed last and the
    /// target: a backward drag into a cold GOP keeps the last picture (or a cached frame between it and the target)
    /// instead of jumping to the cached start of the clip and back. Sources: `sid` and its proxy/original twin (a release
    /// after a proxy scrub keeps the proxy picture until the original lands). No picture of this clip yet: the nearest
    /// earlier cached frame.
    private func fallbackFrame(for r: LayerRequest, sid: UUID, target: Time, scale: DecodeScale) -> DecodedFrame? {
        var sources = [sid]
        if sid == r.media { if let p = media.existingProxyID(for: sid) { sources.append(p) } } else { sources.append(r.media) }
        let last = lastShownByClip.withLock { $0[ShownKey(r)] }.flatMap { $0.media == r.media ? $0.frame : nil }
        var best: DecodedFrame?
        for id in sources {
            if let last, last.pts > target {
                // Moving backward: the earliest cached frame at or after the target, not past the last picture.
                if let c = cache.nearest(media: id, atOrAfter: target, scale: scale), c.pts <= last.pts,
                   best.map({ c.pts < $0.pts }) ?? true { best = c }
            } else if let c = cache.nearest(media: id, atOrBefore: target, scale: scale),
                      last.map({ c.pts >= $0.pts }) ?? true, best.map({ c.pts > $0.pts }) ?? true {
                best = c
            }
        }
        return best ?? last
    }

    /// The stand-in of a clip that was hidden until now: a cached frame of `sid` (or its proxy/original twin) at most
    /// `uncoveredStandInFrames` source frames before the target, nil otherwise.
    private func closeFrame(for r: LayerRequest, sid: UUID, target: Time, within frameDuration: Time, scale: DecodeScale) -> DecodedFrame? {
        var sources = [sid]
        if sid == r.media { if let p = media.existingProxyID(for: sid) { sources.append(p) } } else { sources.append(r.media) }
        let limit = frameDuration * Int64(Self.uncoveredStandInFrames)
        var best: DecodedFrame?
        for id in sources {
            if let c = cache.nearest(media: id, atOrBefore: target, scale: scale), target - c.pts <= limit,
               best.map({ c.pts > $0.pts }) ?? true { best = c }
        }
        return best
    }

    private let resolvePending = Mutex<Set<UUID>>([])

    /// Opens `first` (if given) and every other media of the timeline that is not resolved yet, on the resolve queue (ordered
    /// in the submit chain, so `waitForDecodes` covers it), then replans the decode window around the playhead and redraws.
    /// Opening everything ahead of time means a clip added during playback, or the next cut, never starts cold.
    private func resolveSoon(_ first: UUID?) {
        let (shown, standby, use) = state.withLock { ($0.mediaIDs, $0.standbyIDs, $0.proxyUse) }
        // The angles an Angles piece does not show come last: opening them now spares the first live switch to one a
        // held picture (or the placeholder, when the open outlasts the hold) while its file opens on the switch.
        // shortcut: standby media are opened, not decoded; the first switch still waits for one GOP decode at the
        // playhead. Upgrade (decode the standby angles' GOP at the playhead while paused) if the maintainer still sees a hold.
        let originals = shown + standby
        // Proxies too, when they may be used (the resolver only reports finished ones).
        let all = originals + (use == .off ? [] : originals.map { media.proxyID(for: $0) })
        let candidates = (first.map { [$0] } ?? []) + all.filter { $0 != first }
        let ids = candidates.filter { id in
            guard case .unresolved = media.known(id) else { return false }
            return resolvePending.withLock { $0.insert(id).inserted }
        }
        guard !ids.isEmpty else { return }
        let queue = resolveQueue
        submitChain.withLock { last in
            let prev = last
            last = Task { [weak self] in
                await prev?.value
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    queue.async {
                        for id in ids { self?.media.resolve(id) }
                        c.resume()
                    }
                }
                guard let self else { return }
                resolvePending.withLock { $0.subtract(ids) }
                occlusionChanged()
                if let (tl, scale, epoch) = state.withLock({ s in s.timeline.map { ($0, s.schedulerScale, s.timelineEpoch) } }) {
                    state.withLock { $0.lastJobs = [] }
                    prefetch(timeline: tl, epoch: epoch, at: Self.gridTime(clock.now(), tl), rate: clock.rate, scale: scale, misses: [])
                }
                invalidate()
            }
        }
    }

    /// Frame showing `sourceTime`; before the first frame -> 0, at/after the end -> last. Requires a non-empty index.
    static func frameIndex(_ sourceTime: Time, in index: SampleIndex) -> Int { index.clampedFrame(at: sourceTime) }

    private func target(_ g: inout GPU, format: SequenceFormat) -> MTLTexture? {
        if let t = g.target, t.width == format.width, t.height == format.height { return t }
        g.target = makeTarget(format)
        return g.target
    }

    private func splitTarget(_ g: inout GPU, format: SequenceFormat) -> MTLTexture? {
        if let t = g.splitTarget, t.width == format.width, t.height == format.height { return t }
        g.splitTarget = makeTarget(format)
        return g.splitTarget
    }

    private func makeTarget(_ format: SequenceFormat) -> MTLTexture? {
        guard format.width > 0, format.height > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: format.width,
                                                         height: format.height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// The layers with the bypassed clips' grade replaced by their ungraded color (source interpretation kept); nil when
    /// no layer of this frame is bypassed. Served under a slot of its own per clip, so switching Before / After never
    /// evicts the graded pipeline.
    private func ungradedLayers(_ layers: [RenderLayer], requests: [LayerRequest], bypass: ColorBypass) -> [RenderLayer]? {
        var out = layers
        var changed = false
        for (i, r) in requests.enumerated() where i < out.count && bypass.bypasses(r.clip) && out[i].colorPipeline != nil {
            out[i].colorPipeline = media.resolver.colorResolver?.pipeline(for: r.color.ungraded, media: r.media,
                                                                          owner: Self.bypassOwner(r.clip))
            changed = true
        }
        return changed ? out : nil
    }

    /// Resolver slot of a clip's ungraded pipeline (distinct from the clip's own slot).
    static func bypassOwner(_ clip: UUID) -> UUID { ColorBypass.ungradedOwner(clip) }

    // MARK: Prefetch

    /// Plans the decode window around `t` and submits it (deduplicated); also used by seek on the main actor so a
    /// random access starts decoding before the next display tick.
    /// Main-actor entry. Never calls the resolver on the caller's thread: when every media is already resolved the
    /// window is planned right here; otherwise resolving + planning run on `resolveQueue` (ordered in the submit chain,
    /// so `waitForDecodes` covers it).
    func prefetch(at t: Time, rate: PlaybackRate) {
        guard let (tl, scale, ids, epoch) = state.withLock({ s in s.timeline.map { ($0, s.schedulerScale, s.mediaIDs, s.timelineEpoch) } })
        else { return }
        let at = Self.gridTime(t, tl)
        if ids.allSatisfy({ media.resolvedDemuxer($0) != nil || media.isKnownOffline($0) }) {
            prefetch(timeline: tl, epoch: epoch, at: at, rate: rate, scale: scale, misses: [], resolve: false)
            return
        }
        let queue = resolveQueue
        submitChain.withLock { last in
            let prev = last
            last = Task { [weak self] in
                await prev?.value
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    queue.async {
                        self?.prefetch(timeline: tl, epoch: epoch, at: at, rate: rate, scale: scale, misses: [], resolve: true)
                        c.resume()
                    }
                }
            }
        }
    }

    /// The prefetch window's per-frame layer sources, kept between ticks (PLAYBACK-PERF "Prefetch window memo").
    private let planMemo = PlanSourceMemo()
    /// `SQ_PLAYBACK_WARM=0`: hidden layers get no sync-frame decode while playing (bench A/B only).
    static let warmsHiddenLayers = ProcessInfo.processInfo.environment["SQ_PLAYBACK_WARM"] != "0"
    /// `SQ_PLAN_MEMO=0` plans every window frame afresh (bench A/B only).
    static let planMemoEnabled = ProcessInfo.processInfo.environment["SQ_PLAN_MEMO"] != "0"

    /// `SQ_TEXTURE_WARM=0`: the next frame's plane textures are made by the draw (bench A/B only).
    static let warmsTextures = ProcessInfo.processInfo.environment["SQ_TEXTURE_WARM"] != "0"
    private let textureWarmQueue = DispatchQueue(label: "SQPlayback.textureWarm", qos: .userInteractive)
    private let textureWarmBusy = Atomic<Bool>(false)
    /// Warms skipped because the previous one was still running (tests).
    let textureWarmsSkipped = Atomic<Int>(0)
    /// Tests: runs on the warm queue at the start of each warm.
    var textureWarmHook: (@Sendable () -> Void)?
    private let warmSteps = Mutex(WarmSteps())

    /// The next presented frame's time, from the steps between the last presented playing frames: the step depends on
    /// rate, timeline fps and display rate together (2x on a 30 fps timeline at 60 Hz is 1 frame a tick, 1x at 120 fps is
    /// 2 frames), so it is observed, not computed. Two different recent steps (an uneven J/L rate) give both guesses; no
    /// step yet (first frame, direction change, a seek, a jump of more than 8 frames) gives none: no warm, not a wrong one.
    struct WarmSteps {
        private var last: Time?
        private var forward = true
        private var steps: [Time] = []

        mutating func next(after t: Time, forward: Bool, playing: Bool, frame fd: Time) -> [Time] {
            defer { last = playing ? t : nil; self.forward = forward }
            guard playing, let last, self.forward == forward else { steps = []; return [] }
            let step = forward ? t - last : last - t
            guard step > .zero, step <= fd * 8 else { steps = []; return [] }
            steps = Array((steps + [step]).suffix(2))
            var out: [Time] = []
            for s in steps.reversed() {
                let u = forward ? t + s : t - s
                if !out.contains(u) { out.append(u) }
            }
            return out
        }
    }

    /// Playing: the plane textures of the next presented frame's cached frames (`WarmSteps`) are made on
    /// `textureWarmQueue` while this frame is on the GPU, so the next draw finds them made (`Compositor.warmPlaneTextures`:
    /// the IOSurface kernel calls of a new CVMetalTexture, 0.3-0.7 ms per 4K frame, leave the render thread). Exact cached
    /// frames of plain video layers only (no gyro warp: that layer draws the warped copy); hidden layers are left out like
    /// in the plan. A guess the draw does not use costs the render thread nothing. One warm at a time: a tick that finds
    /// one running skips its own.
    private func warmNextTextures(_ tl: Timeline, sequences: [Timeline.ID: Timeline], at times: [Time],
                                  scale: DecodeScale, proxy useProxy: Bool, compositor: Compositor) {
        guard textureWarmBusy.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
            textureWarmsSkipped.add(1, ordering: .relaxed)
            return
        }
        textureWarmQueue.async { [weak self] in
            guard let self else { return }
            defer { self.textureWarmBusy.store(false, ordering: .releasing) }
            self.textureWarmHook?()
            let lastFrame = Self.lastFrame(tl)
            let known = self.knownOpaque().pictures
            let picture = known.isEmpty ? nil : self.occlusionPicture(known, proxy: useProxy)
            var requests: [LayerRequest] = []
            for u in times where !u.isNegative && u <= lastFrame {
                let stack = tl.videoLayers(at: u, sequences: { sequences[$0] })
                requests += picture.map { Self.visible(stack, canvas: tl.format, picture: $0) } ?? stack
            }
            var buffers: [SQFrame] = []
            for r in requests where r.generator == nil && !r.isAdjustment && r.gyro == nil {
                guard case .ready(let d) = self.media.known(r.media) else { continue }
                var src: (id: UUID, demuxer: any Demuxing) = (r.media, d)
                if useProxy, let p = self.proxy(for: r.media, original: d) { src = p }
                let index = src.demuxer.index
                guard index.count > 0 else { continue }
                let f = Self.frameIndex(r.sourceTime, in: index)
                if let frame = self.cache.frame(FrameKey(media: src.id, pts: index.entries[f].pts, scale: scale)) {
                    buffers.append(frame.frame)
                }
            }
            if !buffers.isEmpty { compositor.warmPlaneTextures(buffers) }
        }
    }

    /// Plane textures the draws made and the ones warmed ahead, after any running warm finished (tests, bench).
    func planeTextureCounts() -> (drawn: Int, warmed: Int) {
        textureWarmQueue.sync {}
        let c = compositorRef.compositor
        return (c.planeTextureCreates, c.warmedPlaneTextures)
    }

    /// Plane textures the draws made so far, without waiting for a running warm (tests).
    var planeTexturesDrawn: Int { compositorRef.compositor.planeTextureCreates }

    /// Resolver calls requested from the main actor run here (may block on opening an asset).
    private let resolveQueue = DispatchQueue(label: "SQPlayback.resolve", qos: .userInitiated)

    /// `scrubbing`: the mode the tick built its layers (and `misses`) in; nil = read the current one. A tick passes its
    /// snapshot so a mode switch between the snapshot and here cannot plan misses of one mode with the other's rules.
    /// `epoch`: the `timelineEpoch` `tl` was read with; the window memo is used only while it is still current (the
    /// sequences read here belong to it).
    private func prefetch(timeline tl: Timeline, epoch: UInt64, at t: Time, rate: PlaybackRate, scale: DecodeScale,
                          misses: [(UUID, Int)], resolve: Bool = false, scrubbing snapped: Bool? = nil, cull: Bool = true,
                          layersAtPlayhead: [LayerRequest]? = nil) {
        let (ids, base, sequences, current, use, power, refining, velocity, currentEpoch, loops, loopBounds) = state.withLock {
            // Resting or slow drag (`refine` at `t`): the exact window, as the tick plans it.
            ($0.mediaIDs, $0.placements, $0.sequences, $0.scrubbing && $0.refine != t, $0.proxyUse, $0.power,
             $0.scrubbing && $0.refine == t, $0.scrubVelocity, $0.timelineEpoch,
             $0.lead.loops, $0.lead.bounds)
        }
        let scrubbing = snapped ?? current
        // W9.9: media with a usable proxy are planned against the proxy's index and decoded under its key (`sub`).
        let proxied = Self.usesProxy(scrubbing: scrubbing, playing: !rate.isPaused, use: use)
        var indexes: [UUID: SampleIndex] = [:]
        var sub: [UUID: UUID] = [:]
        for id in ids {
            guard let d = resolve ? media.demuxer(id) : media.resolvedDemuxer(id) else { continue }
            if proxied, let p = proxy(for: id, original: d) { indexes[id] = p.demuxer.index; sub[id] = p.id } else { indexes[id] = d.index }
        }
        // Proxy frames are placed where their original's frames are (eviction distance, ruler cache strip).
        let origins = media.origins
        var placements: Placements
        if origins.isEmpty {
            placements = base
        } else {
            placements = { @Sendable (k: FrameKey) -> [Time] in
                guard let o = origins[k.media] else { return base(k) }
                return base(FrameKey(media: o, pts: k.pts, scale: k.scale))
            }
        }
        let cache = self.cache
        if scrubbing {
            prefetchScrub(timeline: tl, sequences: sequences, at: t, scale: scale, misses: misses, indexes: indexes, sub: sub,
                          placements: placements, cull: cull, proxied: proxied)
            return
        }
        let running: DecodeScheduler? = state.withLock { $0.schedulerScale == scale ? $0.scheduler : nil }
        let isCached: (UUID, Int) -> Bool = { m, i in
            guard let idx = indexes[m], i < idx.count else { return true }
            return cache.frame(FrameKey(media: sub[m] ?? m, pts: idx.entries[i].pts, scale: scale)) != nil
        }
        var windowPlanner = power.planner(planner)
        var windowRate = rate
        // Slow drag (exact frames inside a scrub gesture): the window only looks the way the drag goes (GOPs behind it
        // would only delay the one it needs next), and each layer's keyframe goes first as a quick picture.
        if refining, velocity != 0 {
            windowRate = PlaybackRate(velocity > 0 ? 1 : -1)
            windowPlanner.lookahead = windowPlanner.pausedRadius
            windowPlanner.behind = tl.format.frameDuration
        }
        let isRunning: (UUID, ClosedRange<Int>) -> Bool = { m, r in running?.isRunning(media: sub[m] ?? m, frames: r) ?? false }
        // Playing, hidden layers are not decoded: the window plans what the ticks will draw, and a layer coming out
        // from under its cover is planned like a clip that starts there. Paused, everything at the playhead is decoded
        // (only the draw leaves hidden layers out), so an edit that uncovers a layer shows its exact frame at once.
        let opaque = knownOpaque()
        let culls = cull && !rate.isPaused && !opaque.pictures.isEmpty
        let canvas = tl.format
        let picture = occlusionPicture(opaque.pictures, proxy: proxied)
        let visible = { (u: Time) -> [LayerRequest] in
            let all = tl.videoLayers(at: u, sequences: { sequences[$0] })
            return culls ? Self.visible(all, canvas: canvas, picture: picture) : all
        }
        let evaluate = { (u: Time) in PrefetchPlanner.sources(visible(u)) }
        let memoRevision = culls ? opaque.revision &* 4 &+ (proxied ? 3 : 1) : 0
        // Looping: the window does not run past the loop's end; what is left of it continues at the other end, so the
        // frames after the wrap are decoded before the clock gets there (the sound does not wait for them).
        var wrap: (planner: PrefetchPlanner, playhead: Time)?
        if loops, !rate.isPaused, !refining, let r = Self.loopRegion(tl, bounds: loopBounds), t >= r.start, t < r.end {
            let speed = rate.magnitude
            let reach = Time.scaled(windowPlanner.lookahead, by: Int64(speed.num), over: Int64(speed.den))
            let room = rate.isReverse ? t - r.start : r.end - tl.format.frameDuration - t
            if room < reach {
                var second = windowPlanner
                second.behind = .zero
                second.lookahead = min(Time.scaled(reach - room, by: Int64(speed.den), over: Int64(speed.num)), windowPlanner.lookahead)
                windowPlanner.lookahead = Time.scaled(room, by: Int64(speed.den), over: Int64(speed.num))
                wrap = (second, rate.isReverse ? r.end - tl.format.frameDuration : r.start)
                // The frames at the other end count as ahead of the playhead, not as far behind it (eviction).
                let length = rate.isReverse ? r.start - r.end : r.end - r.start
                let inner = placements
                placements = { @Sendable (k: FrameKey) -> [Time] in
                    let at = inner(k)
                    return at + at.compactMap { $0 >= r.start && $0 < r.end ? $0 + length : nil }
                }
            }
        }
        let firstPlanner = windowPlanner
        func plan(_ sources: (Time) -> [PlanSource]) -> [Job] {
            var jobs = firstPlanner.jobs(timeline: tl, playhead: t, rate: windowRate, indexes: indexes, cached: isCached,
                                         maxFrames: cache.capacityFrames, running: isRunning, sources: sources)
            guard let wrap else { return jobs }
            let more = wrap.planner.jobs(timeline: tl, playhead: wrap.playhead, rate: windowRate, indexes: indexes, cached: isCached,
                                         maxFrames: cache.capacityFrames, running: isRunning, sources: sources)
            for var j in more where !jobs.contains(where: { $0.media == j.media && $0.frames == j.frames }) {
                j.priority = jobs.count
                jobs.append(j)
            }
            return jobs
        }
        // A timeline read before the last setTimeline (its sequences differ from the ones read above) skips the memo.
        let planned = epoch == currentEpoch && Self.planMemoEnabled ? planMemo.withSources(epoch: epoch, revision: memoRevision, evaluate: evaluate, plan) : plan(evaluate)
        var jobs = Self.remap(planned, sub)
        if refining {
            let keys = Self.remap(planner.scrubJobs(timeline: tl, sequences: sequences, playhead: t, indexes: indexes, layers: visible, cached: isCached), sub)
                .filter { k in !jobs.contains { $0.media == k.media && $0.frames == k.frames } }
            if !keys.isEmpty {
                jobs = keys + jobs.map { var j = $0; j.priority += keys.count; return j }
            }
        }
        // Hidden layers stay warm while playing: the sync frame of the GOP they are in, one frame per GOP, behind
        // everything else. Their decoder stays open at the playhead and a picture of the right place exists should
        // the layer be uncovered (edit during playback) before its exact frame is decoded.
        if culls, Self.warmsHiddenLayers {
            // The tick's own list at `t` when it read the same timeline (same epoch: same sequences).
            let all = (epoch == currentEpoch ? layersAtPlayhead : nil) ?? tl.videoLayers(at: t, sequences: { sequences[$0] })
            let hidden = LayerOcclusion.evaluate(all, canvas: canvas, picture: picture).hidden
            for i in hidden.sorted() {
                let m = all[i].media
                guard let idx = indexes[m], idx.count > 0 else { continue }
                let f = Self.frameIndex(all[i].sourceTime, in: idx)
                let r = PrefetchPlanner.scrubRange(for: f, in: idx)
                let sid = sub[m] ?? m
                if isCached(m, r.upperBound) || media.isDamaged(sid, frame: r.upperBound) { continue }
                if jobs.contains(where: { $0.media == sid && $0.frames.overlaps(r) }) { continue }
                jobs.append(Job(media: sid, frames: r, priority: jobs.count, finishesWhenDropped: true))
            }
        }
        // Misses the planner does not see (nested sequences): their GOP goes first.
        var urgent: [Job] = []
        for (m, f) in misses where !media.isDamaged(m, frame: f) {
            guard let idx = media.resolvedDemuxer(m)?.index else { continue }
            let gop = idx.gop(containing: f)
            if !jobs.contains(where: { $0.media == m && $0.frames == gop }) && !urgent.contains(where: { $0.media == m && $0.frames == gop }) {
                var job = Job(media: m, frames: gop, priority: urgent.count)
                job.neededFrom = Self.missNeededFrom(f, reverse: rate.isReverse)
                urgent.append(job)
            }
        }
        if !urgent.isEmpty {
            jobs = urgent + jobs.map { var j = $0; j.priority += urgent.count; return j }
        }
        cache.setFocus(playhead: t, direction: rate.isPaused ? 0 : (rate.isReverse ? -1 : 1), scale: scale, placements: placements)
        let scheduler: DecodeScheduler? = state.withLock { s in
            guard s.schedulerScale == scale, Self.needsPost(last: s.lastJobs, new: jobs) else { return nil }
            s.lastJobs = jobs
            return s.scheduler
        }
        if let scheduler { post(jobs, to: scheduler) }
    }

    /// Keyframe-only scrub: one single-frame job per layer (planner), plus the scrub frames of misses the planner does not
    /// see (nested sequences), first. No window: the drag replans on every move.
    private func prefetchScrub(timeline tl: Timeline, sequences: [Timeline.ID: Timeline], at t: Time, scale: DecodeScale,
                               misses: [(UUID, Int)], indexes: [UUID: SampleIndex], sub: [UUID: UUID],
                               placements: @escaping Placements, cull: Bool, proxied: Bool) {
        let cache = self.cache
        let velocity = state.withLock { $0.scrubVelocity }
        let known = knownOpaque().pictures, canvas = tl.format
        let picture = occlusionPicture(known, proxy: proxied)
        let culls = cull && !known.isEmpty
        let visible = { (u: Time) -> [LayerRequest] in
            let all = tl.videoLayers(at: u, sequences: { sequences[$0] })
            return culls ? Self.visible(all, canvas: canvas, picture: picture) : all
        }
        var jobs = Self.remap(planner.scrubJobs(timeline: tl, sequences: sequences, playhead: t, indexes: indexes,
                                                velocity: velocity, layers: visible, cached: { m, i in
            guard let idx = indexes[m], i < idx.count else { return true }
            return cache.frame(FrameKey(media: sub[m] ?? m, pts: idx.entries[i].pts, scale: scale)) != nil
        }), sub)
        var urgent: [Job] = []
        // Every frame on screen now (or being decoded for it), as cache keys: placed at the playhead below.
        var wanted = Set<FrameKey>()
        for layer in visible(t) where layer.generator == nil {
            guard let idx = indexes[layer.media], idx.count > 0 else { continue }
            let k = PrefetchPlanner.scrubFrame(for: Self.frameIndex(layer.sourceTime, in: idx), in: idx)
            wanted.insert(FrameKey(media: sub[layer.media] ?? layer.media, pts: idx.entries[k].pts, scale: scale))
        }
        for (m, k) in misses where !media.isDamaged(m, frame: k) {
            guard let idx = indexes[m] ?? media.resolvedDemuxer(m)?.index, k < idx.count else { continue }
            let r = PrefetchPlanner.scrubRange(for: k, in: idx)
            wanted.insert(FrameKey(media: m, pts: idx.entries[r.upperBound].pts, scale: scale))
            guard !jobs.contains(where: { $0.media == m && $0.frames == r }),
                  !urgent.contains(where: { $0.media == m && $0.frames == r }) else { continue }
            urgent.append(Job(media: m, frames: r, priority: urgent.count, finishesWhenDropped: true))
        }
        if !urgent.isEmpty {
            jobs = urgent + jobs.map { Job(media: $0.media, frames: $0.frames, priority: $0.priority + urgent.count, finishesWhenDropped: true) }
        }
        cache.setFocus(playhead: t, direction: 0, scale: scale,
                       placements: Self.scrubPlacements(placements, wanted: wanted, playhead: t))
        let scheduler: DecodeScheduler? = state.withLock { s in
            guard s.schedulerScale == scale, Self.needsPost(last: s.lastJobs, new: jobs) else { return nil }
            s.lastJobs = jobs
            return s.scheduler
        }
        if let scheduler { post(jobs, to: scheduler) }
    }

    /// A planned queue goes to the scheduler when it differs from the last posted one (`neededFrom` aside), or when one
    /// of its jobs needs frames from earlier than the posted job did (seek, then reverse or a step back).
    static func needsPost(last: [Job], new: [Job]) -> Bool {
        if last != new { return true }
        return zip(last, new).contains { DecodeScheduler.widens($1.neededFrom, $0.neededFrom) }
    }

    /// First frame a miss job needs: forward/paused the missed frame on; reverse play goes on to earlier frames of the
    /// GOP, so it needs the whole GOP (a seek start would be widened again on every tick).
    static func missNeededFrom(_ f: Int, reverse: Bool) -> Int? { reverse ? nil : f }

    /// Planner jobs (keyed by the timeline's media) moved to the proxy keys they were planned for.
    static func remap(_ jobs: [Job], _ sub: [UUID: UUID]) -> [Job] {
        guard !sub.isEmpty else { return jobs }
        return jobs.map { var j = $0; j.media = sub[$0.media] ?? $0.media; return j }
    }

    /// Scrub focus: a frame on screen now that has no timeline placement of its own (a keyframe before the clip's
    /// in-point, or a hold clip's keyframe) is placed at the playhead, so eviction keeps it instead of dropping it first.
    static func scrubPlacements(_ base: @escaping Placements, wanted: Set<FrameKey>, playhead: Time) -> Placements {
        guard !wanted.isEmpty else { return base }
        return { key in
            let p = base(key)
            return p.isEmpty && wanted.contains(key) ? [playhead] : p
        }
    }

    // MARK: Timeline helpers

    /// Every (clip color, media) of the picture clips, nested sequences included, for warming the color LUTs. A
    /// keyframed grade contributes its color at the clip start and at every Color key time (a keyed section switch can
    /// change which LUTs are used; the values themselves need no warm-up). The timeline is the variant view, so variant
    /// overrides are already applied.
    static func colorLayers(_ tl: Timeline, sequences: [Timeline.ID: Timeline]) -> [(color: ClipColor, media: UUID)] {
        var out: [(color: ClipColor, media: UUID)] = []
        // An Angles piece only shows its active angle (`angleView`), so a sequence is walked once per shown angle.
        var visited = Set<[String]>()
        func walk(_ t: Timeline, angle: Int?) {
            guard visited.insert([t.id.uuidString, angle.map(String.init) ?? ""]).inserted else { return }
            for track in t.tracks where track.kind == .video {
                for c in track.clips where c.isEnabled && (!c.isGenerator || c.isAdjustment) {
                    if let s = c.sequence {
                        if let inner = sequences[s] { walk(c.angleView(of: inner), angle: c.angle?.index) }
                        continue
                    }
                    var times: Set<Time> = [.zero]
                    for fx in c.effects where fx.isColor {
                        for p in fx.parameters.values where p.isAnimated { for k in p.track.keys { times.insert(k.time) } }
                        if let r = fx.colorRange { times.insert(r.start) }   // a range grade's own LUT/look starts there
                    }
                    var seen: [ClipColor] = []
                    for time in times.sorted() {
                        let color = c.renderColor(atLocal: time)
                        if !seen.contains(color) { seen.append(color); out.append((color, c.media)) }
                    }
                    // A masked Color effect is graded by the compositor under its own identity (its LUTs load here too).
                    if c.effects.contains(where: { $0.isColor && !$0.maskInput.isEmpty }) {
                        for time in times.sorted() {
                            for g in c.effects(at: c.start + time).segments.compactMap(\.grade) {
                                let color = Compositor.maskedGradeColor(g)
                                if !seen.contains(color) { seen.append(color); out.append((color, Compositor.maskedGradeMedia)) }
                            }
                        }
                    }
                }
            }
        }
        walk(tl, angle: nil)
        return out
    }

    static func mediaIDs(_ tl: Timeline, sequences: [Timeline.ID: Timeline]) -> [UUID] {
        var out = Set<UUID>()
        var visited: Set<Timeline.ID> = [tl.id]
        // An Angles clip (F7.16) plays one angle of its sequence: only that angle's media counts, once per
        // (sequence, angle). `path` keeps a sequence that contains itself from looping.
        struct ShownAngle: Hashable { var sequence: Timeline.ID; var index: Int }
        var shownAngles = Set<ShownAngle>()
        func walk(_ t: Timeline, path: Set<Timeline.ID>) {
            for track in t.tracks where track.kind == .video {
                for c in track.clips where c.isEnabled && !c.isGenerator {
                    guard let s = c.sequence else { out.insert(c.media); continue }
                    guard !path.contains(s), let inner = sequences[s] else { continue }
                    if let angle = c.angle {
                        guard shownAngles.insert(ShownAngle(sequence: s, index: angle.index)).inserted else { continue }
                        walk(c.angleView(of: inner), path: path.union([s]))
                    } else if visited.insert(s).inserted {
                        walk(inner, path: path.union([s]))
                    }
                }
            }
        }
        walk(tl, path: [tl.id])
        // Render-cache segments play as media of their own: they must be opened and planned like any clip, or nothing reads ahead.
        for span in tl.renderCacheSpans { out.insert(span.media) }
        return Array(out)
    }

    /// F7.16: the media of the angles the Angles pieces do not show (picture angles; sound is opened by the audio
    /// engine). Nothing here is decoded or planned: these files are only opened ahead of a switch. `shown`: `mediaIDs`.
    static func standbyMediaIDs(_ tl: Timeline, sequences: [Timeline.ID: Timeline], shown: [UUID]? = nil) -> [UUID] {
        let shown = Set(shown ?? mediaIDs(tl, sequences: sequences))
        var out: [UUID] = []
        var seen = shown
        var walked = Set<Timeline.ID>()
        // Every video clip of an Angles sequence, nested sequences inside it included (once each, loops cut).
        func all(_ t: Timeline, path: Set<Timeline.ID>) {
            for track in t.tracks where track.kind == .video {
                for c in track.clips where c.isEnabled && !c.isGenerator {
                    guard let s = c.sequence else { if seen.insert(c.media).inserted { out.append(c.media) }; continue }
                    if !path.contains(s), let inner = sequences[s] { all(inner, path: path.union([s])) }
                }
            }
        }
        func walk(_ t: Timeline, path: Set<Timeline.ID>) {
            for track in t.tracks where track.kind == .video {
                for c in track.clips where c.isEnabled {
                    guard let s = c.sequence, !path.contains(s), let inner = sequences[s] else { continue }
                    if c.angle != nil {
                        if walked.insert(s).inserted { all(inner, path: path.union([s])) }
                    } else {
                        walk(inner, path: path.union([s]))
                    }
                }
            }
        }
        walk(tl, path: [tl.id])
        return out
    }

    /// FrameKey -> top-level timeline time of the first clip showing that source frame (`placements(...).first`).
    static func mapping(_ tl: Timeline, sequences: [Timeline.ID: Timeline] = [:]) -> Mapping {
        let p = placements(tl, sequences: sequences)
        return { p($0).first }
    }

    /// FrameKey -> top-level timeline time of every clip instance showing that source frame (eviction distance is the
    /// nearest one: one media on V1-V3 or a loop copy shares its frames instead of having them evicted as "far away").
    /// Frames of media used inside a nested sequence map through the nested clip (inner time -> outer time), so they are
    /// not "unplaceable". Order: direct clips by track, then nested clips.
    /// `shownFrame(media, sourceTime)`: pts of the source frame shown at that source time (nil = unknown). An in point that
    /// lies inside a source frame (29.97 fps media on a 30 fps timeline) shows a frame that starts before it: that frame
    /// is placed at the clip start, or a full cache would not keep it and the clip's first frame would play without it.
    static func placements(_ tl: Timeline, sequences: [Timeline.ID: Timeline] = [:],
                           shownFrame: @escaping @Sendable (UUID, Time) -> Time? = { _, _ in nil }) -> Placements {
        func build(_ t: Timeline, visiting: Set<Timeline.ID>) -> Placements {
            let video = t.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { $0.isEnabled && !$0.isGenerator }
            let byMedia = Dictionary(grouping: video.filter { !$0.isNested }, by: \.media)
            let nested: [(clip: Clip, inner: Placements)] = video.compactMap { c in
                guard let s = c.sequence, !visiting.contains(s), let inner = sequences[s] else { return nil }
                return (c, build(c.angleView(of: inner), visiting: visiting.union([s])))   // only the angle it shows
            }
            // Frame shown at each clip's in point, looked up once per clip (eviction scores every cached frame x clip);
            // unknown (media not resolved yet) is asked again next time.
            let known = InPointFrames()
            @Sendable func inPointFrame(_ c: Clip) -> Time? {
                if let t = known.frames.withLock({ $0[c.id] }) { return t }
                guard let t = shownFrame(c.media, c.source.start) else { return nil }
                known.frames.withLock { $0[c.id] = t }
                return t
            }
            return { key in
                var out: [Time] = []
                for c in byMedia[key.media] ?? [] {
                    if let h = c.holdFrame { if key.pts == h { out.append(c.start) }; continue }     // a held clip shows one frame
                    if c.source.contains(key.pts) { out.append(c.timelineTime(forSource: key.pts)) }
                    else if key.pts < c.source.start, !c.reversed, c.speedKeys == nil, inPointFrame(c) == key.pts {
                        out.append(c.start)
                    }
                }
                for (c, inner) in nested {
                    for tIn in inner(key) {
                        if let h = c.holdFrame { if tIn == h { out.append(c.start) }; continue }
                        if c.source.contains(tIn) { out.append(c.timelineTime(forSource: tIn)) }
                    }
                }
                return out
            }
        }
        return build(tl, visiting: [tl.id])
    }

    // MARK: Main-actor reporting (render thread)

    /// Merges the outcome into the pending report (presented/stoppedAtEdge are OR-ed, time is the latest presented
    /// one); ticks that neither presented nor stopped are ignored. Returns true when the caller must schedule a
    /// main-actor hop (none pending yet).
    func publish(_ o: TickOutcome) -> Bool {
        guard o.presented || o.stoppedAtEdge || o.playing else { return false }
        return state.withLock { s in
            // A tick from before a pause, a seek or a play: the host was told the new position already.
            if o.playing || o.stoppedAtEdge, o.serial != clockSerial.load(ordering: .relaxed) { return false }
            // A playing tick reports the clock frame whether or not it presented: at an end the picked frame holds
            // (it led there) while the clock still walks up to it, and the host stops or wraps by this position.
            if o.playing {
                if !o.presented, !o.stoppedAtEdge, o.position == s.publishedPosition { return false }
                s.publishedPosition = o.position
            } else {
                s.publishedPosition = nil
            }
            if var m = s.lastOutcome {
                if o.presented { m.time = o.time; m.presented = true }
                if o.presented || o.playing { m.position = o.position; m.clock = o.clock }
                m.playing = m.playing || o.playing
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
///
/// Q-PERF2 recs 1-2: each tick returns the cadence it wants. While playing the link runs at the sequence rate
/// (`FramePacing`); after `idleTicksToPause` idle ticks the link pauses (no wakeups while nothing changes) until `wake()`.
final class DisplayLinkDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    struct Cadence: Sendable { var range: FramePacing.Range; var idle: Bool }
    typealias Tick = @Sendable (_ drawable: CAMetalDrawable, _ presentAt: Double) -> Cadence

    static let idleTicksToPause = 2

    private struct LayerBox: @unchecked Sendable { let layer: CAMetalLayer }
    private struct RunLoopBox: @unchecked Sendable { let runLoop: CFRunLoop }
    private struct LinkBox: @unchecked Sendable { let link: CAMetalDisplayLink }
    private struct State {
        var stopped = false
        var runLoop: RunLoopBox?
        var link: LinkBox?
        var onTick: Tick?
        /// Render thread only (callback), kept here to avoid a second lock.
        var range: FramePacing.Range?
        var idleTicks = 0
        var paused = false
        /// Bumped by every `wake()`: a tick that saw a wake after it started never pauses (no lost invalidation).
        var wakes: UInt64 = 0
        var pauseCount = 0
    }
    private let state: Mutex<State>

    private let onPause: (@Sendable () -> Void)?

    init(layer: CAMetalLayer, onPause: (@Sendable () -> Void)? = nil, onTick: @escaping Tick) {
        state = Mutex(State(onTick: onTick))
        self.onPause = onPause
        super.init()
        let box = LayerBox(layer: layer)
        let thread = Thread { [self] in
            let link = CAMetalDisplayLink(metalLayer: box.layer)
            link.delegate = self
            let r = FramePacing.interactive
            link.preferredFrameRateRange = CAFrameRateRange(minimum: r.minimum, maximum: r.maximum, preferred: r.preferred)
            link.add(to: .current, forMode: .default)
            state.withLock { $0.runLoop = RunLoopBox(runLoop: CFRunLoopGetCurrent()); $0.link = LinkBox(link: link); $0.range = r }
            while !state.withLock({ $0.stopped }) {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            link.invalidate()
            state.withLock { $0.runLoop = nil; $0.link = nil }
        }
        thread.name = "SQPlayback.render"
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

    /// Something changed (any thread): resumes a link paused while idle, on the render thread.
    func wake() {
        let resume = state.withLock { s -> (RunLoopBox, LinkBox)? in
            s.wakes &+= 1
            guard s.paused, !s.stopped, let rl = s.runLoop, let l = s.link else { return nil }
            s.paused = false; s.idleTicks = 0
            return (rl, l)
        }
        guard let (rl, l) = resume else { return }
        CFRunLoopPerformBlock(rl.runLoop, CFRunLoopMode.defaultMode.rawValue) { l.link.isPaused = false }
        CFRunLoopWakeUp(rl.runLoop)
    }

    /// Times the link paused itself (diagnostics, tests).
    var pauseCount: Int { state.withLock { $0.pauseCount } }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let (tick, wakes) = state.withLock { ($0.onTick, $0.wakes) }
        guard let tick else { return }
        let c = tick(update.drawable, update.targetPresentationTimestamp)
        let (setRange, paused) = state.withLock { s -> (Bool, Bool) in
            defer { s.range = c.range }
            var paused = false
            if c.idle {
                s.idleTicks += 1
                if s.idleTicks >= Self.idleTicksToPause, s.wakes == wakes, !s.paused {
                    s.paused = true; s.pauseCount += 1
                    link.isPaused = true
                    paused = true
                }
            } else {
                s.idleTicks = 0
            }
            return (s.range != c.range, paused)
        }
        if paused { onPause?() }
        if setRange {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: c.range.minimum, maximum: c.range.maximum, preferred: c.range.preferred)
        }
    }
}
