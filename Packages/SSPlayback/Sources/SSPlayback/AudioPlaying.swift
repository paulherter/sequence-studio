import Synchronization
import SSCore

/// Peak and RMS of one channel over the last metered buffer (linear, 1 = full scale).
public struct AudioMeterLevel: Sendable, Equatable {
    public var peak: Float
    public var rms: Float
    public init(peak: Float = 0, rms: Float = 0) { self.peak = peak; self.rms = rms }
}

/// Timeline audio meter reading (pre-TimePitch, i.e. the mixed timeline signal). `sequence` counts metered buffers.
public struct AudioMeterSnapshot: Sendable, Equatable {
    public var left = AudioMeterLevel()
    public var right = AudioMeterLevel()
    public var sequence = 0
    public init() {}
}

/// The last render call that consumed audio: `consumedFrames` after it, frames it consumed (`quantum`, timeline frames)
/// and the host time (`hostNanoseconds()` base) when it ran. The clock interpolates between calls with it.
public struct AudioRenderStamp: Sendable, Equatable {
    public var frames: Int64 = 0
    public var quantum: Int64 = 0
    public var hostNanos: Int64 = 0
    public init(frames: Int64 = 0, quantum: Int64 = 0, hostNanos: Int64 = 0) {
        self.frames = frames; self.quantum = quantum; self.hostNanos = hostNanos
    }
}

/// Audio output as seen by `AudioClock` and `PlaybackEngine` (ARCHITECTURE §7). `AudioEngine` is the real
/// implementation (AVAudioEngine); `ManualAudio` models the feeder/ring protocol for headless tests.
///
/// Only `AudioClock` should call `setRate`/`seek`/`start`/`stop` while it is the engine's clock: it owns the anchor and
/// relies on every flush being one it requested.
public protocol AudioPlaying: AnyObject, Sendable {
    /// Mixer rate (48 kHz): the rate of `consumedFrames` and of the feeder's timeline frames.
    var sampleRate: Int { get }
    func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline])
    /// Brings the output up (hardware, feeder thread). Idempotent. May block (hardware start): call it off the render
    /// path. Throws when there is no usable output device.
    func prepare() throws
    /// Output pulls from the ring (after the pending seek is primed). Never blocks.
    func start()
    /// Output fades out (5 ms) and then renders silence; the ring is no longer consumed. Never blocks.
    func stop()
    /// Direction for the next `seek` and speed (|rate|) for TimePitch; updates `outputLatency`. Does not flush.
    func setRate(_ rate: PlaybackRate)
    /// Restarts production at `position` in the current direction (feeder seek -> ring flush, 5 ms crossfade).
    /// Returns the feeder generation (see `flushed`).
    @discardableResult func seek(to position: Time) -> Int
    /// Feeder flush bookkeeping: (generation applied, ring epoch issued for it, `outputLatencySamples` valid from it).
    var flushed: (generation: Int, epoch: Int, latency: Int) { get }
    /// Ring consumer acknowledgement: latest applied flush epoch and `consumedFrames` at that moment.
    var consumedAtEpoch: (epoch: Int, frames: Int64) { get }
    /// Timeline frames delivered to the output since creation (the audio master clock counter).
    var consumedFrames: Int64 { get }
    /// Last consuming render call (for interpolation between calls and the stall watchdog).
    var lastRender: AudioRenderStamp { get }
    /// Monotonic host time in nanoseconds, same base as `lastRender.hostNanos`.
    func hostNanoseconds() -> Int64
    /// Output-side latency (TimePitch at the current rate + device presentation) in output time, unscaled by rate.
    var outputLatency: Time { get }
    /// Render calls that found the ring short while playing (after priming).
    var underrunCount: Int { get }
    func meterSnapshot() -> AudioMeterSnapshot
    /// Called (any thread, no locks held) after the output was restarted underneath, e.g. a device configuration change:
    /// the clock re-seeks at its current position.
    func setRestartHandler(_ handler: (@Sendable () -> Void)?)
    /// Scrub/step grain player on the same output (E-12), nil when the output has none. Usable once `prepare()` succeeded.
    var scrubAudio: ScrubAudio? { get }
}

extension AudioPlaying {
    public var scrubAudio: ScrubAudio? { nil }
}

/// Headless `AudioPlaying`: models the feeder (flush on seek, generation, latency M) and the ring consumer
/// (flush acknowledgement, consumed counter) plus a manual host time. Nothing moves unless the test calls
/// `render(frames:)` / `applyFlush()` / `advanceTime(nanoseconds:)`.
public final class ManualAudio: AudioPlaying {
    private struct State {
        var generation = 0, epoch = 0
        var flushed = (generation: 0, epoch: 0, latency: 0)
        var ack = (epoch: 0, frames: Int64(0))
        var consumed: Int64 = 0
        var stamp = AudioRenderStamp()
        var nanos: Int64 = 0
        var playing = false
        var prepared = false
        var prepareFails: Bool
        var rate: PlaybackRate = .zero
        var lastSeek: Time?
        var latencySamples: Int
        var outputLatency: Time
        var timePitchLatency: Time
        var timeline: Timeline?
        var meter = AudioMeterSnapshot()
        var restart: (@Sendable () -> Void)?
    }
    private let state: Mutex<State>
    public let sampleRate: Int
    /// When true (default), `render` applies a pending feeder flush first (the feeder is always ahead).
    public let autoFlush: Bool

    /// Scrub grains (tests render `scrubAudio.voice` by hand); nil = no scrub audio.
    public let scrubAudio: ScrubAudio?

    /// `timePitchLatency` is added to `outputLatency` while |rate| != 1 (TimePitch not bypassed).
    public init(sampleRate: Int = 48_000, latencySamples: Int = 0, outputLatency: Time = .zero, timePitchLatency: Time = .zero,
                autoFlush: Bool = true, failsToPrepare: Bool = false, scrub: ScrubAudio? = nil) {
        self.sampleRate = sampleRate; self.autoFlush = autoFlush; self.scrubAudio = scrub
        state = Mutex(State(prepareFails: failsToPrepare, latencySamples: latencySamples, outputLatency: outputLatency,
                            timePitchLatency: timePitchLatency))
    }

    public struct Unavailable: Error {}

    // MARK: test controls

    /// Feeder side: applies the latest seek (issues a ring epoch, publishes `flushed` with the current M).
    public func applyFlush() {
        state.withLock { s in
            guard s.flushed.generation != s.generation else { return }
            s.epoch += 1
            s.flushed = (s.generation, s.epoch, s.latencySamples)
        }
    }

    /// Consumer side: one render call of `frames` timeline frames at the current host time. Applies an issued flush
    /// (acknowledgement), then counts the frames as consumed while playing. With `advance` (default) host time then moves
    /// by the call's duration (`frames / (|rate| x sampleRate)`, rounded up to whole ns), i.e. the next call is due.
    public func render(frames: Int, advance: Bool = true) {
        if autoFlush { applyFlush() }
        state.withLock { s in
            guard s.playing else { return }
            if s.ack.epoch < s.epoch { s.ack = (s.epoch, s.consumed) }
            s.consumed += Int64(frames)
            s.stamp = AudioRenderStamp(frames: s.consumed, quantum: Int64(frames), hostNanos: s.nanos)
            if advance, !s.rate.isPaused {
                let m = s.rate.magnitude
                let num = Int128(frames) * 1_000_000_000 * Int128(m.den), den = Int128(sampleRate) * Int128(m.num)
                s.nanos += Int64((num + den - 1) / den)
            }
        }
    }

    public func advanceTime(nanoseconds: Int64) { state.withLock { $0.nanos += nanoseconds } }

    /// Feeder latency M (samples) adopted at the next flush.
    public func setLatencySamples(_ m: Int) { state.withLock { $0.latencySamples = m } }
    public func setOutputLatency(_ t: Time) { state.withLock { $0.outputLatency = t } }
    public func setFailsToPrepare(_ f: Bool) { state.withLock { $0.prepareFails = f } }
    /// Invokes the restart handler, as a device configuration change would.
    public func simulateRestart() { state.withLock { $0.restart }?() }

    public var isPlaying: Bool { state.withLock { $0.playing } }
    public var isPrepared: Bool { state.withLock { $0.prepared } }
    public var currentRate: PlaybackRate { state.withLock { $0.rate } }
    public var lastSeek: Time? { state.withLock { $0.lastSeek } }
    public var timeline: Timeline? { state.withLock { $0.timeline } }

    // MARK: AudioPlaying

    public func setTimeline(_ timeline: Timeline, sequences: [Timeline.ID: Timeline]) {
        state.withLock { $0.timeline = timeline }
        scrubAudio?.setTimeline(timeline, sequences: sequences)
    }
    public func prepare() throws {
        try state.withLock { s in
            if s.prepareFails { throw Unavailable() }
            s.prepared = true
        }
    }
    public func start() { state.withLock { $0.playing = true } }
    public func stop() { state.withLock { $0.playing = false } }
    public func setRate(_ rate: PlaybackRate) { state.withLock { $0.rate = rate } }
    @discardableResult public func seek(to position: Time) -> Int {
        state.withLock { s in s.generation += 1; s.lastSeek = position; return s.generation }
    }
    public var flushed: (generation: Int, epoch: Int, latency: Int) { state.withLock { $0.flushed } }
    public var consumedAtEpoch: (epoch: Int, frames: Int64) { state.withLock { $0.ack } }
    public var consumedFrames: Int64 { state.withLock { $0.consumed } }
    public var lastRender: AudioRenderStamp { state.withLock { $0.stamp } }
    public func hostNanoseconds() -> Int64 { state.withLock { $0.nanos } }
    public var outputLatency: Time {
        state.withLock { s in s.outputLatency + (s.rate.magnitude == .forward || s.rate.isPaused ? .zero : s.timePitchLatency) }
    }
    public var underrunCount: Int { 0 }
    public func meterSnapshot() -> AudioMeterSnapshot { state.withLock { $0.meter } }
    public func setRestartHandler(_ handler: (@Sendable () -> Void)?) { state.withLock { $0.restart = handler } }
}
