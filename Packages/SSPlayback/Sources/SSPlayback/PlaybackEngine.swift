import Foundation
import Metal
import QuartzCore
import SSCore
import SSMedia
import SSRender

/// Program/Source monitor playback (video path; audio joins in E-11). API per ARCHITECTURE §6.
///
/// The main actor posts snapshots (timeline, quality, seeks) into the render loop's `Mutex<RenderState>`; the render
/// loop runs on a dedicated render thread (`CAMetalDisplayLink`) while a layer is attached, or one iteration per
/// `tick()` call when headless (tests, bench). Decoding runs in `DecodeScheduler` jobs on per-media serial queues.
@MainActor public final class PlaybackEngine {
    /// Last presented frame, on the sequence frame grid.
    public private(set) var position: Time = .zero
    public private(set) var rate: PlaybackRate = .zero
    /// Program monitor quality: decode size. A change keys new frames by the new scale (the others stay cached).
    public var quality: DecodeScale = .full { didSet { loop.setQuality(quality) } }
    /// Called with the new position after a frame was presented (coalesced, at most display rate).
    public var onPositionChange: (@MainActor (Time) -> Void)?

    let loop: RenderLoop
    private let device: MTLDevice
    private var timeline: Timeline?
    private var driver: DisplayLinkDriver?

    /// `clock` defaults to a `HostClock`; tests pass a `ManualClock` and drive the loop with `tick()`.
    public init(device: MTLDevice, media: MediaResolver, clock: any PlaybackClock = HostClock(),
                cache: FrameCache<DecodedFrame> = FrameCache()) throws {
        self.device = device
        loop = try RenderLoop(device: device, resolver: media, clock: clock, cache: cache)
    }

    // No deinit cleanup needed beyond the driver: `attach(nil)` stops it; the thread holds only the loop.

    /// Value snapshot; cheap, called after every edit. Swaps the composite source, never flushes the frame cache.
    public func setTimeline(_ timeline: Timeline) { setTimeline(timeline, sequences: [:]) }

    /// Variant with the project's other sequences, so nested clips resolve (`Project.timelines` by ID).
    public func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        self.timeline = timeline
        loop.setTimeline(timeline, sequences: sequences)
    }

    /// nil = headless (render offscreen, see `lastRenderedTexture`).
    public func attach(_ layer: CAMetalLayer?) {
        driver?.stop(); driver = nil
        guard let layer else { loop.setPresenter(nil); return }
        loop.setPresenter(Presenter(device: device, layer: layer))
        let loop = self.loop
        driver = DisplayLinkDriver(layer: layer) { [weak self] drawable in
            guard let o = loop.tick(drawable: drawable), loop.publish(o) else { return }
            Task { @MainActor [weak self] in
                guard let self, let o = self.loop.takeOutcome() else { return }
                self.apply(o)
            }
        }
    }

    public func play(_ rate: PlaybackRate = .init(1, 1)) {
        guard !rate.isPaused else { pause(); return }
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

    /// Exact frame (floored to the grid, clamped to the timeline); shown as soon as it is decoded.
    public func seek(to t: Time) {
        let target = timeline.map { RenderLoop.gridTime(t, $0) } ?? t
        loop.clock.seek(to: target)
        loop.beginStep(target: target)
        loop.prefetch(at: target, rate: rate)
    }

    /// ± frames from the current clock position; pauses playback first. (Audio grain: E-12.)
    public func step(_ frames: Int) {
        if !rate.isPaused { pause() }
        guard let tl = timeline else { return }
        seek(to: gridNow() + tl.format.frameDuration * Int64(frames))
    }

    // Scrub: video only for now (E-12 adds the audio grains).
    public func beginScrub() { if !rate.isPaused { pause() } }
    public func scrub(to t: Time) { seek(to: t) }
    public func endScrub() {}

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
