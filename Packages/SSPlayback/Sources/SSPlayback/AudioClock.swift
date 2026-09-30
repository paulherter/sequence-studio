import Synchronization
import SSCore

/// Audio master clock (ARCHITECTURE §7): the position is derived from the frames the audio output actually consumed.
///
/// `position = anchor + direction x max(0, (heard - base - M) / sampleRate - outputLatency x |rate|)`
/// where `base` = `consumedAtEpoch.frames` of the flush that started this anchor, `M` = the feeder latency published
/// with that flush (`flushed.latency`) and `heard` interpolates between render calls: the last call's first frame plus
/// `|rate| x sampleRate x (host now - call time)`, clamped to the frames that call consumed (`lastRender`). So `now()`
/// moves smoothly instead of in callback-sized steps, and it never runs backwards within an anchor (mirrored in reverse).
/// Until the flush is acknowledged by the consumer (and the first audible sample has left the output) the clock holds at
/// the anchor: video waits for audio, never runs ahead. Arithmetic is exact rational on the 48 kHz grid; the only
/// roundings are the hardware latency measurement and the interpolation (whole frames).
///
/// Drives its `AudioPlaying`: `start`/`setRate`/`seek` while running restart the feeder at the new anchor (flush + 5 ms
/// crossfade), `stop` fades the output out. A seek while paused only moves the anchor; the next `start` restarts.
/// Control calls are serialised by their own lock and call the audio object outside the state lock, so `now()` (render
/// thread) only ever waits for short state updates.
///
/// Watchdog: `sample()` reports `stalled` when running and no render call consumed audio for `stallTimeout`.
public final class AudioClock: PlaybackClock {
    public static let stallTimeoutNanos: Int64 = 250_000_000

    private struct State {
        var anchor: Time = .zero
        var rate: PlaybackRate = .zero
        var generation = 0                  // feeder generation of the current anchor (.max while a restart is in flight)
        var base: Int64?                    // consumedAtEpoch.frames of its flush, once acknowledged
        var latency: Int64 = 0              // M valid for that flush
        var outputLatency: Time = .zero     // snapshot at the restart (TimePitch latency depends on the rate)
        var restartNanos: Int64 = 0
        var seenFrames: Int64 = 0
        var progressNanos: Int64 = 0
        var lastReturned: Time?             // monotonic guard within one anchor
    }
    private let state = Mutex(State())
    private let control = Mutex(())
    public let audio: any AudioPlaying
    private let sampleRate: Int64

    public init(audio: any AudioPlaying) {
        self.audio = audio
        sampleRate = Int64(audio.sampleRate)
        audio.setRestartHandler { [weak self] in self?.reanchor() }
    }

    public func now() -> Time { sample().position }

    /// Position plus the watchdog verdict, from one reading.
    public func sample() -> (position: Time, stalled: Bool) {
        let ns = audio.hostNanoseconds()
        return state.withLock { s in
            let p = position(&s, nanos: ns)
            let stalled = !s.rate.isPaused && s.generation != .max && ns - s.progressNanos > Self.stallTimeoutNanos
            return (p, stalled)
        }
    }

    public var rate: PlaybackRate { state.withLock { $0.rate } }

    public func start(at position: Time, rate: PlaybackRate) {
        control.withLock { _ in restart(at: position, rate: rate) }
    }

    @discardableResult public func stop() -> Time {
        control.withLock { _ in
            let ns = audio.hostNanoseconds()
            let (p, wasRunning) = state.withLock { s -> (Time, Bool) in
                let p = position(&s, nanos: ns), running = !s.rate.isPaused
                s.anchor = p; s.rate = .zero; s.base = nil; s.lastReturned = nil
                return (p, running)
            }
            if wasRunning { audio.stop() }
            return p
        }
    }

    public func setRate(_ rate: PlaybackRate) {
        control.withLock { _ in
            guard rate != state.withLock({ $0.rate }) else { return }
            restart(at: now(), rate: rate)
        }
    }

    public func seek(to position: Time) {
        control.withLock { _ in
            let r = state.withLock { $0.rate }
            if r.isPaused { state.withLock { $0.anchor = position; $0.lastReturned = nil } }
            else { restart(at: position, rate: r) }
        }
    }

    /// Output restarted underneath (device change): re-seek at the current position, keeping the rate.
    func reanchor() {
        control.withLock { _ in
            let r = state.withLock { $0.rate }
            guard !r.isPaused else { return }
            restart(at: now(), rate: r)
        }
    }

    // MARK: Private

    /// Under `control`. The audio calls run outside `state`; meanwhile the clock holds at the new anchor.
    private func restart(at position: Time, rate: PlaybackRate) {
        let wasRunning = state.withLock { s -> Bool in
            let running = !s.rate.isPaused
            s.anchor = position; s.rate = rate; s.base = nil; s.lastReturned = nil
            s.generation = .max
            return running
        }
        guard !rate.isPaused else {
            state.withLock { $0.generation = 0 }
            if wasRunning { audio.stop() }
            return
        }
        audio.setRate(rate)
        let gen = audio.seek(to: position)
        audio.start()
        let latency = audio.outputLatency, ns = audio.hostNanoseconds(), stamp = audio.lastRender
        state.withLock { s in
            s.generation = gen; s.outputLatency = latency
            s.restartNanos = ns; s.progressNanos = ns; s.seenFrames = stamp.frames
        }
    }

    private func position(_ s: inout State, nanos: Int64) -> Time {
        guard !s.rate.isPaused, s.generation != .max else { return s.anchor }
        let stamp = audio.lastRender
        if stamp.frames != s.seenFrames { s.seenFrames = stamp.frames; s.progressNanos = max(stamp.hostNanos, s.restartNanos) }
        if s.base == nil {
            let f = audio.flushed
            guard f.generation >= s.generation else { return s.anchor }        // feeder has not flushed yet
            let ack = audio.consumedAtEpoch
            guard ack.epoch >= f.epoch else { return s.anchor }                 // consumer has not applied the flush
            s.base = ack.frames; s.latency = Int64(f.latency)
        }
        let mag = s.rate.magnitude
        let consumed = audio.consumedFrames
        var heard = consumed
        if stamp.frames == consumed && stamp.quantum > 0 {
            heard = consumed - stamp.quantum
            let dt = nanos - stamp.hostNanos
            if dt > 0 {
                let f = Int128(dt) * Int128(mag.num) * Int128(sampleRate) / (Int128(mag.den) * 1_000_000_000)
                heard += min(stamp.quantum, Int64(clamping: f))
            }
        }
        let elapsed = Time(heard - s.base! - s.latency, sampleRate) - scaled(s.outputLatency, by: mag)
        guard elapsed > .zero else { return s.anchor }
        var p = s.rate.isReverse ? s.anchor - elapsed : s.anchor + elapsed
        if let last = s.lastReturned { p = s.rate.isReverse ? min(p, last) : max(p, last) }
        s.lastReturned = p
        return p
    }
}

/// The engine's clock: forwards to the host clock or the audio clock and hands the position over on a switch.
/// Control calls and switches are serialised (`ops`), so a `stop`/`seek` from the render thread never lands on a clock
/// that is being switched away. `now()` falls back to the host clock when the audio clock's watchdog reports a stall
/// (`audioFailed` is set until `clearAudioFailure()`).
final class SwitchingClock: PlaybackClock {
    private struct Current { var clock: any PlaybackClock; var audioFailed = false }
    private let current: Mutex<Current>
    private let ops = Mutex(())
    let host: any PlaybackClock
    let audio: AudioClock?

    init(host: any PlaybackClock, audio: AudioClock?) {
        self.host = host; self.audio = audio
        current = Mutex(Current(clock: host))
    }

    var isAudio: Bool { current.withLock { $0.clock is AudioClock } }
    var audioFailed: Bool { current.withLock { $0.audioFailed } }
    func clearAudioFailure() { current.withLock { $0.audioFailed = false } }

    /// Makes the audio clock (true) or the host clock (false) active, continuing at the old clock's position and rate.
    func useAudio(_ on: Bool) {
        ops.withLock { _ in
            guard let audio else { return }
            let from: any PlaybackClock = on ? host : audio, to: any PlaybackClock = on ? audio : host
            guard current.withLock({ ($0.clock as AnyObject) === (from as AnyObject) }) else { return }
            let r = from.rate
            let p = from.stop()
            to.start(at: p, rate: r)
            current.withLock { $0.clock = to }
        }
    }

    func now() -> Time {
        let c = current.withLock { $0.clock }
        guard let a = c as? AudioClock else { return c.now() }
        let (p, stalled) = a.sample()
        guard stalled else { return p }
        return ops.withLock { _ in
            guard current.withLock({ $0.clock is AudioClock }) else { return host.now() }
            let r = a.rate
            let at = a.stop()
            host.start(at: at, rate: r)
            current.withLock { $0.clock = host; $0.audioFailed = true }
            return at
        }
    }

    var rate: PlaybackRate { current.withLock { $0.clock }.rate }
    func start(at position: Time, rate: PlaybackRate) { ops.withLock { _ in current.withLock { $0.clock }.start(at: position, rate: rate) } }
    @discardableResult func stop() -> Time { ops.withLock { _ in current.withLock { $0.clock }.stop() } }
    func setRate(_ rate: PlaybackRate) { ops.withLock { _ in current.withLock { $0.clock }.setRate(rate) } }
    func seek(to position: Time) { ops.withLock { _ in current.withLock { $0.clock }.seek(to: position) } }
}
