import Foundation
import Metal
import QuartzCore
import SQCore
import SQMedia
import SQRender
import Synchronization

/// Program/Source monitor playback. API per ARCHITECTURE §6.
///
/// Audio (E-11): with an `AudioPlaying` (the app passes `AudioEngine(media:)`), a timeline with audible audio
/// (`audioSegments` non-empty: some unmuted/solo track has clips) plays through it and the engine runs on its
/// `AudioClock` (video follows audio). Otherwise, or when the audio output cannot start, the injected clock drives.
/// The output is prepared lazily in `play()` (hardware start may block briefly), never from `setTimeline`. If it fails,
/// or the clock's watchdog sees the output stall (no audio consumed for 250 ms), playback continues on the injected
/// clock at the current position and `audioUnavailable` is set; the next `play()` retries.
///
/// The main actor posts snapshots (timeline, quality, seeks) into the render loop's `Mutex<RenderState>`; the render
/// loop runs on a dedicated render thread (`CAMetalDisplayLink`) while a layer is attached, or one iteration per
/// `tick()` call when headless (tests, bench). Decoding runs in `DecodeScheduler` jobs on per-media serial queues.
@MainActor public final class PlaybackEngine {
    /// Start time of the last presented frame, on the sequence frame grid. After `seek(to: t)` this is `t` floored to
    /// the grid: exactly `t` when `t` is a frame boundary, else the start of the frame containing `t` (e.g. 1 s on a
    /// 59.94 fps grid is frame 59 = 0.9843 s). This is the frame on screen.
    public private(set) var position: Time = .zero
    public private(set) var rate: PlaybackRate = .zero
    /// Program monitor quality: decode size. A change keys new frames by the new scale (the others stay cached).
    /// The user's choice; the decode size actually used may be smaller under `powerPolicy`.
    /// While Export Frame waits (`isExportingFrame`) the change applies when it ends.
    public var quality: DecodeScale = .full {
        didSet { if !isExportingFrame { loop.setQuality(powerPolicy.viewerScale(quality)) } }
    }
    /// Q-PERF2 rec 3: thermal / Low Power policy (the app feeds it from `PowerMonitor`). Serious heat caps the decode at
    /// half size and halves the prefetch lookahead. Monitors only: export never reads it.
    public var powerPolicy: PowerPolicy = .normal {
        didSet {
            guard powerPolicy != oldValue else { return }
            loop.setPowerPolicy(powerPolicy)
            if !isExportingFrame { loop.setQuality(powerPolicy.viewerScale(quality)) }
        }
    }
    /// The decode size in use (`quality` capped by `powerPolicy`).
    public var effectiveQuality: DecodeScale { powerPolicy.viewerScale(quality) }
    /// Program monitor zoom used by the present path. A change re-presents the current frame (no decode).
    public var viewerZoom: ViewerZoom = .fit { didSet { if viewerZoom != oldValue { loop.setZoom(viewerZoom) } } }
    /// Captions drawn over the picture in the monitor (Premiere: Closed Captions Display). Export is not affected.
    public var showsTransparencyGrid = false { didSet { if showsTransparencyGrid != oldValue { loop.setTransparencyGrid(showsTransparencyGrid) } } }
    public var showsCaptions = true { didSet { if showsCaptions != oldValue { loop.setShowCaptions(showsCaptions) } } }
    /// The project's style kit for the monitor's caption styles (W8.3). Per engine, so two open projects with different kits
    /// each draw their own; the export is handed its kit explicitly.
    public var captionStyleKit: StyleKit? { didSet { if captionStyleKit != oldValue { loop.setCaptionKit(captionStyleKit) } } }
    /// The project predates the Inter built-in caption styles (`Project.usesLegacyBuiltInFont`): Helvetica built-ins.
    public var captionLegacyFont = false { didSet { if captionLegacyFont != oldValue { loop.setCaptionLegacyFont(captionLegacyFont) } } }
    /// Called with the new position after a frame was presented (coalesced, at most display rate).
    public var onPositionChange: (@MainActor (Time) -> Void)?

    let loop: RenderLoop
    private let device: MTLDevice
    private var timeline: Timeline?
    private var sequences: [Timeline.ID: Timeline] = [:]
    /// `isAudible` of the current timeline, computed once per `setTimeline` (it walks every clip; scrub and step events
    /// arrive per mouse event).
    private var timelineAudible = false
    private var driver: DisplayLinkDriver?
    private var probeTicker: PlayProbe.Ticker?
    private let switching: SwitchingClock
    /// Audio output (nil = video only). Also the source of the timeline meter (`meterSnapshot()`).
    public let audio: (any AudioPlaying)?
    private var prepareFailed = false
    private var audioPrepared = false
    /// Between `beginScrub` and `endScrub` (drags play grains).
    private var scrubbing = false
    /// Audio scrubbing (Premiere preference, off by default): off = dragging the playhead and stepping stay silent.
    public var audioScrubbing = false
    /// `audio.prepare()` failed or the output stalled: running on the injected clock until the next `play()` retries.
    public var audioUnavailable: Bool { prepareFailed || switching.audioFailed }

    /// `clock` defaults to a `HostClock`; tests pass a `ManualClock` and drive the loop with `tick()`.
    /// `audio`: nil = video only; tests pass a `ManualAudio`.
    public init(device: MTLDevice, media: MediaResolver, clock: any PlaybackClock = HostClock(),
                cache: FrameCache<DecodedFrame> = FrameCache(), audio: (any AudioPlaying)? = nil) throws {
        self.device = device
        self.audio = audio
        switching = SwitchingClock(host: clock, audio: audio.map { AudioClock(audio: $0) })
        loop = try RenderLoop(device: device, resolver: media, clock: switching, cache: cache)
    }

    /// True while the audio clock drives playback.
    public var usesAudioClock: Bool { switching.isAudio }

    isolated deinit { driver?.stop(); probeTicker?.stop() }

    /// Value snapshot; cheap, called after every edit. Swaps the composite source, never flushes the frame cache.
    public func setTimeline(_ timeline: Timeline) { setTimeline(timeline, sequences: [:]) }

    /// Variant with the project's other sequences, so nested clips resolve (`Project.timelines` by ID).
    public func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        self.timeline = timeline
        self.sequences = sequences
        timelineAudible = Self.isAudible(timeline, sequences: sequences)
        loop.setTimeline(shownToLoop(timeline), sequences: sequences)
        audio?.setTimeline(timeline, sequences: sequences)
        selectClock(mayPrepare: false)
        if prewarmsAudio { prewarmAudio() }
    }

    /// The host asks for the audio output to be brought up after the timeline is set, off the main thread, so the first
    /// play (and the first audio scrub) do not wait ~150 ms for the hardware start on the main thread. A failure is left
    /// to the play path, which retries and reports it.
    public var prewarmsAudio = false
    private var prewarmStarted = false

    private func prewarmAudio() {
        guard let audio, timelineAudible, !audioPrepared, !prepareFailed, !prewarmStarted else { return }
        prewarmStarted = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard (try? audio.prepare()) != nil else { return }
            await MainActor.run { self?.audioPrepared = true }
        }
    }

    /// Color page Before / After / Split: the clips in `bypass` are drawn without their grade, in playback and on the
    /// paused frame (redrawn at once). nil = After (graded). Monitor only: the project and the export never see it.
    public private(set) var colorBypass: ColorBypass?
    public func setColorBypass(_ bypass: ColorBypass?) {
        let value = bypass?.isEmpty == true ? nil : bypass
        guard value != colorBypass else { return }
        let hadSpans = timeline?.renderCacheSpans.isEmpty == false
        colorBypass = value
        // Preview render cache spans show the graded picture: a bypass reads the real clips instead.
        if hadSpans, let timeline { loop.setTimeline(shownToLoop(timeline), sequences: sequences) }
        loop.setColorBypass(value)
    }

    /// Spans are read only where the cache file holds what the monitor shows: no color bypass, and the SDR display view
    /// (the file holds clamped Rec.709; Display P3 and the HDR views show colors and highlights it does not keep).
    private func shownToLoop(_ t: Timeline) -> Timeline {
        guard !t.renderCacheSpans.isEmpty, colorBypass != nil || cacheDisplayView() != .sdr else { return t }
        var copy = t; copy.renderCacheSpans = []; return copy
    }

    /// The display view the span gate checks (tests pin it). The app re-pushes the timeline after a view change.
    var cacheDisplayView: () -> DisplayView = { DisplayView.current }

    /// Preview render cache, pending-writes tier: frames of a segment that just went live, put into the frame cache under
    /// the segment's media ID so they show without opening and decoding the file. Kept only at full decode quality (the
    /// frames are full size); a lower viewer quality decodes the file as before.
    public func seedFrames(_ frames: [DecodedFrame]) {
        guard effectiveQuality == .full, !frames.isEmpty else { return }
        for f in frames { loop.cache.insert(f, for: FrameKey(media: f.media, pts: f.pts, scale: .full)) }
        loop.invalidate()
    }

    /// When ready proxies are decoded instead of the originals (W9.9): scrubbing by default, paused frames never.
    public var proxyUse: ProxyUse {
        get { loop.proxyUse }
        set { loop.setProxyUse(newValue) }
    }

    /// The resolver's proxies of these media appeared, changed or went away: reopened on the next use (originals untouched).
    public func proxiesChanged(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        loop.proxiesChanged(ids)
        if let tl = timeline { loop.prefetch(at: RenderLoop.gridTime(loop.clock.now(), tl), rate: rate) }
    }

    /// These media were relinked to other files while online: forget their opened files, decoders and cached frames so the
    /// viewer shows the new file, and the audio output (playback feeder and scrub mixer) reopens their sources.
    public func mediaChanged(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        audio?.mediaChanged(ids)
        audio?.scrubAudio?.mediaChanged(ids)
        loop.mediaChanged(ids)
        if let tl = timeline { loop.prefetch(at: RenderLoop.gridTime(loop.clock.now(), tl), rate: rate) }
    }

    /// nil = headless (render offscreen, see `lastRenderedTexture`).
    public func attach(_ layer: CAMetalLayer?) {
        let detaching = driver != nil && layer == nil
        driver?.stop(); driver = nil
        probeTicker?.stop(); probeTicker = nil
        loop.setWaker(nil)
        loop.setGateOpener { [weak self] in Task { @MainActor [weak self] in self?.performStartGateOpen() } }
        if !manualPlayStart { loop.startsOnDisplay = layer != nil }
        if detaching {                                             // no ticks any more: do not keep audio held
            if let o = loop.forceStartGateOpen() { loop.clock.start(at: o.at, rate: o.rate) }
            startPlayStartClock(hostNow: CACurrentMediaTime(), force: true)
        }
        guard let layer else { loop.setPresenter(nil); return }
        loop.setPresenter(Presenter(device: device, layer: layer))
        let body: @Sendable (CAMetalDrawable?, Double) -> DisplayLinkDriver.Cadence = { [weak self, weak loop] drawable, presentAt in
            guard let loop else { return .init(range: FramePacing.interactive, idle: false) }
            // Diagnostics only (`presentProbe`, `PlayProbe`): the handler must be on the drawable before the tick presents it.
            let slot = loop.presentProbeOn.load(ordering: .relaxed) ? loop.presentProbe.withLock { $0 }.map(PresentProbe.Slot.init) : nil
            let seekGoal = PlayProbe.enabled ? PlayProbe.shared.awaitingFrame : nil
            let glass = seekGoal == nil ? nil : PlayProbe.GlassSlot()
            if let glass, let drawable { drawable.addPresentedHandler { d in glass.presented(at: d.presentedTime) } }
            if let slot, let drawable { drawable.addPresentedHandler { d in slot.presented(at: d.presentedTime) } }
            let tickStart = slot == nil ? 0 : CACurrentMediaTime()
            let outcome = loop.tick(drawable: drawable, presentAt: presentAt)
            if let goal = seekGoal, let o = outcome, o.presented, o.time == goal {
                PlayProbe.shared.note(.firstFrame)
                if !loop.isScrubbing, loop.settled(at: o.time) {
                    PlayProbe.shared.note(.exact)
                    glass?.arm()
                }
            }
            if let slot {
                if let o = outcome, o.presented {
                    slot.commit(.init(time: Double(o.time.value) / Double(max(o.time.timescale, 1)), target: presentAt, presented: 0,
                                      tickStart: tickStart, tickDuration: CACurrentMediaTime() - tickStart,
                                      clock: Double(o.clock.value) / Double(max(o.clock.timescale, 1)),
                                      playing: o.playing && !o.stoppedAtEdge))
                } else {
                    slot.discard()
                }
            }
            if let o = outcome {
                if o.presented && !o.stoppedAtEdge && o.playing { loop.notePresent(at: presentAt) }
                if loop.publish(o) {
                    let published = PlayProbe.enabled ? PlayProbe.now() : 0
                    Task { @MainActor [weak self] in
                        guard let self, let o = self.loop.takeOutcome() else { return }
                        if PlayProbe.enabled { Self.probeApply(o, publishedAt: published) }
                        self.apply(o)
                    }
                }
            }
            let c = loop.cadence()
            return .init(range: c.range, idle: c.idle)
        }
        if PlayProbe.headless {
            // Probe on a locked screen / hidden window (no display link ticks): a 60 Hz timer ticks without a drawable.
            probeTicker = PlayProbe.Ticker { body(nil, CACurrentMediaTime() + 1.0 / 60) }
            loop.setWaker {}
            return
        }
        let d = DisplayLinkDriver(layer: layer, onPause: { [weak loop] in loop?.scheduleIdleTrim() }) { drawable, presentAt in body(drawable, presentAt) }
        driver = d
        loop.setWaker { [weak d] in d?.wake() }
    }

    /// Diagnostics: records when each playing frame reached the glass (nil = off, the default; the tick reads one cached flag, no lock).
    public var presentProbe: PresentProbe? {
        get { loop.presentProbe.withLock { $0 } }
        set { loop.presentProbe.withLock { $0 = newValue }; loop.presentProbeOn.store(newValue != nil, ordering: .relaxed) }
    }

    /// Times the display link paused itself while idle (diagnostics).
    var driverPauseCount: Int { driver?.pauseCount ?? 0 }

    /// Re-presents the current frame from the cache (the viewer was resized; the present path fits it to the new size).
    public func redraw() { loop.invalidate() }

    /// Ignored while Export Frame waits for its frame (`isExportingFrame`).
    public func play(_ rate: PlaybackRate = .init(1, 1)) {
        guard !isExportingFrame else { return }
        guard !rate.isPaused else { pause(); return }
        stopScrubAudio()                                   // the play path owns the output from here
        loop.setScrubbing(false)
        if audioUnavailable { prepareFailed = false; switching.clearAudioFailure() }   // retry
        selectClock(mayPrepare: true)
        let start = gridNow()
        // Starts now, or once the start frame is decoded (start gate); the limit runs here, independent of ticks.
        if let gate = loop.play(at: start, rate: rate) { watchStartGate(gate) }
        watchPlayStart()
        self.rate = rate
        loop.resetPacing()
        loop.invalidate()
        loop.prefetch(at: start, rate: rate)
    }

    /// Start gate (on by default): play waits, clock and audio held, until the frame at the playhead is decoded (at most
    /// 1 s) instead of running ahead with placeholders. Off: play starts the clock at once (clock/audio tests).
    public var waitsForStartFrame: Bool {
        get { loop.startGateEnabled }
        set { loop.startGateEnabled = newValue }
    }

    /// The play range the host stops or wraps at ("Play In to Out", Loop over a range; nil = the whole sequence). While
    /// playing the picture leads the clock by the display lead (`DisplayLead`); it never leads out of this range.
    public var playRange: TimeRange? {
        get { loop.leadBounds }
        set { loop.leadBounds = newValue }
    }

    /// Loop: playback wraps inside `playRange` (or the whole sequence) by itself, in both directions, and never stops at
    /// its ends; the reported position wraps with it. The engine does it rather than the host because the picture leads
    /// the clock: a host wrapping at the reported position comes a display lead too late, and the first frames after
    /// the wrap would never be shown.
    public var loops: Bool {
        get { loop.loops }
        set { loop.loops = newValue; loop.invalidate() }
    }

    /// Tests: play starts are timed to the display without a layer, and without timers: `tick(presentAt:hostNow:)`
    /// starts the clock when the laid-out time is reached.
    func startOnDisplayManually() { manualPlayStart = true; loop.startsOnDisplay = true }
    private var manualPlayStart = false
    private var playStartWatch: Task<Void, Never>?

    /// Starts the clock of a waiting play start (`PlayStart`) when its time is reached, or now with `force`.
    @discardableResult
    private func startPlayStartClock(hostNow: Double, force: Bool = false) -> Bool {
        guard let o = loop.takePlayStart(hostNow: hostNow, force: force) else { return false }
        loop.clock.start(at: o.at, rate: o.rate)
        loop.invalidate()
        return true
    }

    /// One task per play start: sleeps until the laid-out start time (or the limit when the display link does not tick)
    /// and starts the clock. A seek lays the start out again; the task follows it.
    private func watchPlayStart() {
        playStartWatch?.cancel(); playStartWatch = nil
        guard !manualPlayStart, loop.isStartingPlay else { return }
        playStartWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled, let wait = self?.loop.playStartWait(hostNow: CACurrentMediaTime()) {
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(min(wait, 0.25)))
                    continue
                }
                self?.startPlayStartClock(hostNow: CACurrentMediaTime(), force: true)
                return
            }
        }
    }

    /// Phase lock (on by default, `FramePhaseLock`): playing frame changes kept midway between ticks. Off: bench A/B.
    public var locksFramePhase: Bool {
        get { loop.locksFramePhase }
        set { loop.locksFramePhase = newValue }
    }

    /// Main actor: starts the clock the render thread found ready (dropped when a pause or seek came in between).
    func performStartGateOpen() {
        if let o = loop.takeStartGateOpen() {
            if !loop.beginPlayStart(at: o.at, rate: o.rate) { loop.clock.start(at: o.at, rate: o.rate) }
            loop.invalidate()
        }
        // A play start the render thread laid out (or one without a display time: now).
        startPlayStartClock(hostNow: manualPlayStart ? -.infinity : CACurrentMediaTime())
        if !manualPlayStart { watchPlayStart() }
    }

    /// The start gate's limit, without ticks: after it the clock starts at the held position.
    private func watchStartGate(_ id: UInt64) {
        Task { @MainActor [weak self] in
            while let left = self?.loop.startGateRemaining(id: id) {
                if left > .zero { try? await Task.sleep(for: left); continue }
                guard let self, let o = self.loop.forceStartGateOpen(id: id) else { return }
                if self.loop.beginPlayStart(at: o.at, rate: o.rate) { self.watchPlayStart() }
                else { self.loop.clock.start(at: o.at, rate: o.rate) }
                self.loop.invalidate()
                return
            }
        }
    }

    public func pause() {
        playStartWatch?.cancel(); playStartWatch = nil
        let wasPlaying = !rate.isPaused
        // Stays on the last frame handed to the display (`RenderLoop.park`); returns without waiting for a tick.
        let at = loop.park()
        rate = .zero
        loop.invalidate()
        // Reported last, paused: a host that treats a position near the end of a playing engine as "reached the end"
        // must not do so for a pause.
        if wasPlaying, at != position {
            position = at
            onPositionChange?(at)
        }
    }

    /// Frame containing `t` (floored to the grid, clamped to the timeline); shown as soon as it is decoded.
    public func seek(to t: Time) { seek(to: t, refine: false) }

    /// `refine`: inside a scrub gesture, show the exact frame at once (slow drag). Set together with the step, so the
    /// synchronous prefetch below never plans the keyframe-only queue first (that canceled the running GOP decode).
    private func seek(to t: Time, refine: Bool, velocity: Int = 0) {
        guard !isExportingFrame else { return }            // Export Frame holds the playhead while it waits
        let target = timeline.map { RenderLoop.gridTime(t, $0) } ?? t
        // One step with the clock move: a render tick never sees the new position with the previous refine.
        loop.beginStep(target: target, refine: refine, velocity: velocity, seekClock: true,
                       beyondEnd: timeline.map { RenderLoop.isBeyondEnd(t, $0) } ?? false)
        loop.prefetch(at: target, rate: rate)
        if PlayProbe.enabled { PlayProbe.shared.note(.request, target: target) }
    }

    /// ± frames from the current clock position; pauses playback first. Plays one audio grain of the new frame
    /// (one frame, at least 40 ms) in step direction when the timeline is audible.
    public func step(_ frames: Int) {
        guard !isExportingFrame else { return }
        if !rate.isPaused { pause() }
        guard let tl = timeline else { return }
        let from = gridNow()
        let to = RenderLoop.gridTime(from + tl.format.frameDuration * Int64(frames), tl)
        seek(to: to)
        scrubOutput(tl)?.step(from: from, to: to)
    }

    /// Start of a scrub gesture: pauses playback; drags until `endScrub` play audio grains (ARCHITECTURE §7) and decode
    /// only keyframes (W6.6: the sync frame at or before each position; the exact frame follows on release).
    public func beginScrub() {
        guard !isExportingFrame else { return }
        if !rate.isPaused { pause() }
        scrubbing = true
        lastScrubTarget = nil
        loop.setScrubbing(true)
        guard let tl = timeline, let audio, let s = scrubOutput(tl) else { return }
        s.begin(at: gridNow(), hostNanos: audio.hostNanoseconds())
    }

    /// FB-H: a scrub gesture that rests this long at one position decodes and shows the exact frame there (nil: only on
    /// release). Moving on drops back to keyframes.
    public var scrubRefineDelay: Duration? = .milliseconds(120)
    private var refineTask: Task<Void, Never>?
    /// Scrub latency: a move of at most this many sequence frames from the previous scrub position is a slow drag and
    /// shows the exact frame at once (no rest delay). Keyframes alone would hold one picture for a whole GOP (0.5-1 s of
    /// long-GOP footage); a slow drag continues the GOP decode it already started. 0: off.
    public var slowScrubFrames = 2
    /// Scrub latency: while dragging, the next keyframe in the drag direction is decoded behind the current one.
    public var prefetchesScrubDirection = true
    private var lastScrubTarget: Time?

    /// Seeks (video) and, inside a scrub gesture, plays a grain at `t` in the drag direction.
    public func scrub(to t: Time) {
        guard !isExportingFrame else { return }
        var slow = false, velocity = 0
        if loop.isScrubbing, let tl = timeline {
            let target = RenderLoop.gridTime(t, tl)
            let fd = tl.format.frameDuration
            if let prev = lastScrubTarget, fd > .zero {
                let move = Int(clamping: (target - prev).frameIndex(frameDuration: fd))
                slow = slowScrubFrames > 0 && abs(move) <= slowScrubFrames
                if prefetchesScrubDirection { velocity = move }
            }
            lastScrubTarget = target
        }
        seek(to: t, refine: slow, velocity: velocity)
        refineTask?.cancel(); refineTask = nil
        // Also after a slow move: it already shows the exact frame, but the rest drops its forward-only window.
        if loop.isScrubbing, let delay = scrubRefineDelay {
            let target = gridNow()
            refineTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.loop.refineScrub(at: target)
            }
        }
        guard scrubbing, let tl = timeline, let audio, let s = scrubOutput(tl) else { return }
        let clamped = min(max(t, .zero), tl.duration)
        s.scrub(to: clamped, hostNanos: audio.hostNanoseconds())
    }

    /// End of the gesture: scrub audio fades out (5 ms); the exact frame at the playhead is decoded and shown.
    public func endScrub() {
        refineTask?.cancel(); refineTask = nil
        stopScrubAudio()
        guard loop.isScrubbing else { return }
        loop.setScrubbing(false)
        seek(to: loop.state.withLock { $0.beyondEnd } ? (timeline?.duration ?? gridNow()) : gridNow())
    }

    public var stats: PlaybackStats { loop.stats }

    /// Phases of the last render iteration that composited or held (profiling, docs/PLAYBACK-PERF.md).
    public var lastTickProfile: TickProfile? { loop.lastProfile.withLock { $0 } }
    /// Media layers under an opaque picture that fills the canvas are not decoded or drawn (same picture; on by default,
    /// `SQ_PLAYBACK_CULL=0` or false draws everything: bench A/B and tests).
    public var cullsHiddenLayers: Bool {
        get { loop.cullsHidden.load(ordering: .relaxed) }
        set { loop.cullsHidden.store(newValue, ordering: .relaxed); loop.invalidate() }
    }
    /// Profiling: keep the node tree of each composite so `lastComposite` can hand it to a bench.
    public var capturesComposite: Bool {
        get { loop.captureNodes.load(ordering: .relaxed) }
        set { loop.captureNodes.store(newValue, ordering: .relaxed) }
    }
    public var lastComposite: (nodes: [RenderNode], format: SequenceFormat)? { loop.lastNodes.withLock { $0 } }

    /// Timeline spans whose frames are in the cache (the ruler's cache strip); a pure query, empty without a timeline.
    public var cacheGeneration: Int { loop.cache.generation }

    public func cachedRanges() -> [TimeRange] {
        guard let tl = timeline else { return [] }
        return loop.cache.cachedRanges(frameDuration: tl.format.frameDuration)
    }

    /// Last composited frame (rgba16Float, sequence size, working linear). Headless readback for tests/bench.
    public var lastRenderedTexture: MTLTexture? { loop.lastRendered?.texture }

    /// Export Frame: renders the frame at the playhead with every layer decoded at full size (whatever the viewer
    /// quality, and on weak Macs whose previews decode at half), hands that composite to `body` (copy it there: the
    /// next tick reuses the texture), then goes back to the viewer quality. Pauses playback first.
    ///
    /// While it waits the playhead is held: play, seeks, steps and scrubs are ignored, quality and power changes are
    /// applied when it ends, and a second call is refused (`.busy`, so only one save sheet). It never hangs: a decode
    /// that does not finish within `fullSizeFrameTimeout` ends in `.timedOut`, a frame that cannot complete (offline or
    /// damaged media, a failed render) in `.incomplete`, a canceled task in `.canceled`; the quality is always restored.
    public func withFullSizeFrame(_ body: (FullSizeFrameResult) -> Void) async {
        guard !isExportingFrame else { body(.failed(.busy)); return }
        isExportingFrame = true
        loop.setLookPreview(nil)                       // a hover preview never lands in the exported picture
        if !rate.isPaused { pause() }
        let at = gridNow()
        loop.setQuality(.full, exact: true)
        defer {
            isExportingFrame = false
            loop.setQuality(effectiveQuality)          // also applies a quality or power change made meanwhile
        }
        loop.prefetch(at: at, rate: .zero)
        let deadline = ContinuousClock.now + fullSizeFrameTimeout
        var stalled = 0
        while true {
            if Task.isCancelled { body(.failed(.cancelled)); return }
            let decodes = decodeCalls
            let settled = await Self.waitForDecodes(loop, until: deadline)
            if Task.isCancelled { body(.failed(.cancelled)); return }
            _ = tick()
            if loop.frameComplete(at: at), let tex = lastRenderedTexture { body(.frame(tex)); return }
            if !settled || ContinuousClock.now >= deadline { body(.failed(.timedOut)); return }
            // Nothing left to decode and still not complete: a few more ticks (a resolve or decode they queue resets
            // this), then report it rather than spin or export a placeholder.
            stalled = decodeCalls == decodes ? stalled + 1 : 0
            if stalled >= 5 { body(.failed(.incomplete)); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// True while `withFullSizeFrame` waits for its full-size frame.
    public private(set) var isExportingFrame = false
    /// `withFullSizeFrame` gives up after this long (wall clock).
    var fullSizeFrameTimeout: Duration = .seconds(5)

    /// `loop.waitForDecodes()` with a wall-clock limit (and task cancellation): false when the limit came first. The wait
    /// itself cannot be canceled; it keeps running detached and ends with the decodes.
    private static func waitForDecodes(_ loop: RenderLoop, until deadline: ContinuousClock.Instant) async -> Bool {
        let once = ResumeOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                once.set(c)
                let timer = Task {
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    once.resume(false)
                }
                Task {
                    await loop.waitForDecodes()
                    timer.cancel()
                    once.resume(true)
                }
            }
        } onCancel: { once.resume(false) }
    }

    /// Asynchronous readback of the finished composite (eyedropper, Auto, thumbnails): see `FrameCaptureEncoder`.
    /// Coalesced per `key` (a newer request with the same key replaces the pending one); never blocks the caller.
    public func requestFrameCapture(key: String, _ encode: @escaping FrameCaptureEncoder) { loop.requestCapture(key: key, encode) }

    /// One render-loop iteration, synchronously (headless tests / bench). Returns true when a frame was presented.
    @discardableResult public func tick() -> Bool {
        guard let o = loop.tick() else { return false }
        performStartGateOpen()                  // headless: the open this tick asked for, on the main actor
        apply(o)
        return o.presented
    }

    /// Tests: one iteration as the display link runs it, its frame shown at host time `presentAt`.
    func tick(presentAt: Double, hostNow: Double) -> TickOutcome? {
        if manualPlayStart { startPlayStartClock(hostNow: hostNow) }
        guard let o = loop.tick(presentAt: presentAt, hostNow: hostNow) else { return nil }
        performStartGateOpen()
        if loop.publish(o), let m = loop.takeOutcome() { apply(m) }
        return o
    }

    /// Suspends until every requested decode has finished and landed in the cache.
    public func waitForDecodes() async { await loop.waitForDecodes() }

    /// Decode jobs run by all decoders so far (profiling: one job is a GOP or the part of it a window needs).
    public var decodeJobCount: Int { loop.decodeCounter.value }

    // MARK: Test hooks

    /// `decode` calls made by all decoders so far.
    var decodeCalls: Int { loop.decodeCounter.value }
    /// Ranges requested by decode calls number `since` and later, in call order (only the most recent ones are kept).
    func decodeRanges(since: Int) -> [ClosedRange<Int>] { loop.decodeCounter.ranges(since: since) }
    /// Whether the frame of `media` at `pts` (full scale) is in the cache.
    func cachedFrame(media: UUID, pts: Time) -> Bool { loop.cache.frame(FrameKey(media: media, pts: pts, scale: .full)) != nil }
    var cacheCount: Int { loop.cache.count }

    // MARK: Private

    /// Audio clock when the timeline is audible and the output is up, else the injected clock. A switch hands the
    /// position and rate over (the old clock stops).
    /// Only `play()` may prepare (bring the hardware up); `setTimeline` switches to audio only if it already is.
    private func selectClock(mayPrepare: Bool) {
        guard let audio else { return }
        let audible = !audioUnavailable && timelineAudible
        if audible && !switching.isAudio {
            if !audioPrepared {
                guard mayPrepare else { return }
                let p0 = PlayProbe.enabled ? PlayProbe.now() : 0
                do { try audio.prepare(); audioPrepared = true } catch { prepareFailed = true; return }
                if PlayProbe.enabled { PlayProbe.shared.stage("audio.prepare %.1f", (PlayProbe.now() - p0) * 1000) }
            }
            switching.useAudio(true)
        } else if !audible && switching.isAudio {
            switching.useAudio(false)
        }
    }

    /// Some unmuted (solo-respecting) audio track has a clip anywhere in the timeline.
    nonisolated static func isAudible(_ tl: Timeline, sequences: [Timeline.ID: Timeline]) -> Bool {
        guard tl.duration > .zero else { return false }
        return !tl.audioSegments(in: TimeRange(start: .zero, duration: tl.duration), sequences: { sequences[$0] }).isEmpty
    }

    /// Scrub grains are played only when the output has a scrub voice, the timeline is audible and the output is up
    /// (prepared here on first use, like `play()`; a failure marks the audio unavailable until the next `play()`).
    private func scrubOutput(_ tl: Timeline) -> ScrubAudio? {
        guard audioScrubbing, let audio, let s = audio.scrubAudio, !audioUnavailable, timelineAudible else { return nil }
        if !audioPrepared {
            do { try audio.prepare(); audioPrepared = true } catch { prepareFailed = true; return nil }
        }
        return s
    }

    private func stopScrubAudio() {
        scrubbing = false
        audio?.scrubAudio?.stop()
    }

    private func gridNow() -> Time {
        let now = loop.clock.now()
        return timeline.map { RenderLoop.gridTime(now, $0) } ?? now
    }

    /// `SQ_PLAY_PROBE`: the main-thread end of a publish (hop delay while playing; the exact frame of a pending jump).
    private static func probeApply(_ o: TickOutcome, publishedAt: Double) {
        let now = PlayProbe.now()
        if o.playing { PlayProbe.shared.recordApplyDelay(ms: (now - publishedAt) * 1000) }
        if PlayProbe.shared.awaitingApply {
            PlayProbe.shared.note(.applied, now: now)
            if PlayProbe.headless { PlayProbe.shared.glass(at: now) }      // no drawable: the apply is the last stage
        }
    }

    private func apply(_ o: TickOutcome) {
        if o.stoppedAtEdge { rate = .zero }
        // A stop at the edge is reported even when no new frame was presented, so the host can leave "playing".
        // The clock's frame, not the picked one: while playing the picture leads by the display lead (`DisplayLead`).
        // A playing tick reports it whether or not it presented (the picture holds at an end before the clock is there).
        let moved = (o.presented || o.playing) && o.position != position
        guard moved || o.stoppedAtEdge else { return }
        if moved { position = o.position }
        onPositionChange?(position)
    }
}

/// What `PlaybackEngine.withFullSizeFrame` hands its body.
public enum FullSizeFrameResult {
    /// The composite at the playhead, every layer decoded at full size (copy it inside the body).
    case frame(MTLTexture)
    case failed(FullSizeFrameFailure)
}

public enum FullSizeFrameFailure: Error, Sendable, Equatable {
    /// Another Export Frame is still waiting for its frame.
    case busy
    /// The decodes did not finish in time.
    case timedOut
    /// The frame cannot complete (offline or damaged media, a render that keeps failing).
    case incomplete
    /// The waiting task was canceled.
    case cancelled
}

/// Resumes a continuation exactly once, whichever side comes first (also before the continuation is known).
private final class ResumeOnce: Sendable {
    private struct State { var c: CheckedContinuation<Bool, Never>?; var early: Bool?; var done = false }
    private let state = Mutex(State())
    func set(_ c: CheckedContinuation<Bool, Never>) {
        let early = state.withLock { s -> Bool? in
            guard let v = s.early, !s.done else { s.c = c; return nil }
            s.done = true
            return v
        }
        if let early { c.resume(returning: early) }
    }
    func resume(_ value: Bool) {
        let c = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            guard !s.done else { return nil }
            guard let c = s.c else { if s.early == nil { s.early = value }; return nil }
            s.done = true; s.c = nil
            return c
        }
        c?.resume(returning: value)
    }
}
