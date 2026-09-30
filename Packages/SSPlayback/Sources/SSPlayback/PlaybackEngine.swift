import Foundation
import Metal
import QuartzCore
import SSCore
import SSMedia
import SSRender

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
    public var quality: DecodeScale = .full { didSet { loop.setQuality(quality) } }
    /// Program monitor zoom used by the present path. A change re-presents the current frame (no decode).
    public var viewerZoom: ViewerZoom = .fit { didSet { if viewerZoom != oldValue { loop.setZoom(viewerZoom) } } }
    /// Called with the new position after a frame was presented (coalesced, at most display rate).
    public var onPositionChange: (@MainActor (Time) -> Void)?

    let loop: RenderLoop
    private let device: MTLDevice
    private var timeline: Timeline?
    private var sequences: [Timeline.ID: Timeline] = [:]
    private var driver: DisplayLinkDriver?
    private let switching: SwitchingClock
    /// Audio output (nil = video only). Also the source of the timeline meter (`meterSnapshot()`).
    public let audio: (any AudioPlaying)?
    private var prepareFailed = false
    private var audioPrepared = false
    /// Between `beginScrub` and `endScrub` (drags play grains).
    private var scrubbing = false
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

    isolated deinit { driver?.stop() }

    /// Value snapshot; cheap, called after every edit. Swaps the composite source, never flushes the frame cache.
    public func setTimeline(_ timeline: Timeline) { setTimeline(timeline, sequences: [:]) }

    /// Variant with the project's other sequences, so nested clips resolve (`Project.timelines` by ID).
    public func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        self.timeline = timeline
        self.sequences = sequences
        loop.setTimeline(timeline, sequences: sequences)
        audio?.setTimeline(timeline, sequences: sequences)
        selectClock(mayPrepare: false)
    }

    /// nil = headless (render offscreen, see `lastRenderedTexture`).
    public func attach(_ layer: CAMetalLayer?) {
        driver?.stop(); driver = nil
        guard let layer else { loop.setPresenter(nil); return }
        loop.setPresenter(Presenter(device: device, layer: layer))
        driver = DisplayLinkDriver(layer: layer) { [weak self, weak loop] drawable in
            guard let loop, let o = loop.tick(drawable: drawable), loop.publish(o) else { return }
            Task { @MainActor [weak self] in
                guard let self, let o = self.loop.takeOutcome() else { return }
                self.apply(o)
            }
        }
    }

    public func play(_ rate: PlaybackRate = .init(1, 1)) {
        guard !rate.isPaused else { pause(); return }
        stopScrubAudio()                                   // the play path owns the output from here
        if audioUnavailable { prepareFailed = false; switching.clearAudioFailure() }   // retry
        selectClock(mayPrepare: true)
        let start = gridNow()
        loop.clock.start(at: start, rate: rate)
        self.rate = rate
        loop.invalidate()
        loop.prefetch(at: start, rate: rate)
    }

    public func pause() {
        loop.clock.stop()
        loop.clock.seek(to: gridNow())
        rate = .zero
        loop.invalidate()
    }

    /// Frame containing `t` (floored to the grid, clamped to the timeline); shown as soon as it is decoded.
    public func seek(to t: Time) {
        let target = timeline.map { RenderLoop.gridTime(t, $0) } ?? t
        loop.clock.seek(to: target)
        loop.beginStep(target: target)
        loop.prefetch(at: target, rate: rate)
    }

    /// ± frames from the current clock position; pauses playback first. Plays one audio grain of the new frame
    /// (one frame, at least 40 ms) in step direction when the timeline is audible.
    public func step(_ frames: Int) {
        if !rate.isPaused { pause() }
        guard let tl = timeline else { return }
        let from = gridNow()
        let to = RenderLoop.gridTime(from + tl.format.frameDuration * Int64(frames), tl)
        seek(to: to)
        scrubOutput(tl)?.step(from: from, to: to)
    }

    /// Start of a scrub gesture: pauses playback; drags until `endScrub` play audio grains (ARCHITECTURE §7).
    public func beginScrub() {
        if !rate.isPaused { pause() }
        scrubbing = true
        guard let tl = timeline, let audio, let s = scrubOutput(tl) else { return }
        s.begin(at: gridNow(), hostNanos: audio.hostNanoseconds())
    }

    /// Seeks (video) and, inside a scrub gesture, plays a grain at `t` in the drag direction.
    public func scrub(to t: Time) {
        seek(to: t)
        guard scrubbing, let tl = timeline, let audio, let s = scrubOutput(tl) else { return }
        let clamped = min(max(t, .zero), tl.duration)
        s.scrub(to: clamped, hostNanos: audio.hostNanoseconds())
    }

    /// End of the gesture: scrub audio fades out (5 ms).
    public func endScrub() { stopScrubAudio() }

    public var stats: PlaybackStats { loop.stats }

    /// Last composited frame (rgba16Float, sequence size, working linear). Headless readback for tests/bench.
    public var lastRenderedTexture: MTLTexture? { loop.lastRendered?.texture }

    /// One render-loop iteration, synchronously (headless tests / bench). Returns true when a frame was presented.
    @discardableResult public func tick() -> Bool {
        guard let o = loop.tick() else { return false }
        apply(o)
        return o.presented
    }

    /// Suspends until every requested decode has finished and landed in the cache.
    public func waitForDecodes() async { await loop.waitForDecodes() }

    // MARK: Test hooks

    /// `decode` calls made by all decoders so far.
    var decodeCalls: Int { loop.decodeCounter.value }
    var cacheCount: Int { loop.cache.count }

    // MARK: Private

    /// Audio clock when the timeline is audible and the output is up, else the injected clock. A switch hands the
    /// position and rate over (the old clock stops).
    /// Only `play()` may prepare (bring the hardware up); `setTimeline` switches to audio only if it already is.
    private func selectClock(mayPrepare: Bool) {
        guard let audio else { return }
        let audible = !audioUnavailable && timeline.map { Self.isAudible($0, sequences: sequences) } == true
        if audible && !switching.isAudio {
            if !audioPrepared {
                guard mayPrepare else { return }
                do { try audio.prepare(); audioPrepared = true } catch { prepareFailed = true; return }
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
        guard let audio, let s = audio.scrubAudio, !audioUnavailable, Self.isAudible(tl, sequences: sequences) else { return nil }
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

    private func apply(_ o: TickOutcome) {
        if o.stoppedAtEdge { rate = .zero }
        guard o.presented, o.time != position else { return }
        position = o.time
        onPositionChange?(o.time)
    }
}
