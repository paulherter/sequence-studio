import Darwin
import Synchronization
import SSCore

/// Timeline clock. Positions are rational `Time`; no floating point anywhere in the API.
///
/// Model: a clock holds an anchor `(position, elapsed-at-anchor)` and a rate. `now()` is
/// `anchorPosition + (elapsed - anchorElapsed) * rate`, evaluated exactly in rational arithmetic.
/// Changing the rate, seeking, starting or stopping re-anchors, so position is always continuous
/// across a rate change and `now()` never jumps.
public protocol PlaybackClock: Sendable {
    /// Current timeline position (not snapped). Safe to call from any thread.
    func now() -> Time
    var rate: PlaybackRate { get }
    /// Re-anchors at `position` and runs at `rate` (rate 0 holds the position).
    func start(at position: Time, rate: PlaybackRate)
    /// Holds the clock (rate 0) and returns the position where it stopped.
    @discardableResult func stop() -> Time
    /// Keeps the current position, continues at `rate`. Atomic re-anchor.
    func setRate(_ rate: PlaybackRate)
    /// Jumps to `position`, keeping the current rate. Atomic re-anchor.
    func seek(to position: Time)
}

/// `delta * rate`, exact. Rational product reduced by `Time`'s normalizing init.
func scaled(_ delta: Time, by rate: PlaybackRate) -> Time {
    if rate.num == 0 || delta.value == 0 { return .zero }
    let num = Int128(delta.value) * Int128(rate.num)
    let den = Int128(delta.timescale) * Int128(rate.den)
    let g = gcd128(num.magnitude, UInt128(den))
    return Time(Int64(num / Int128(g)), Int64(den / Int128(g)))
}

private func gcd128(_ a: UInt128, _ b: UInt128) -> UInt128 {
    var (a, b) = (a, b)
    while b != 0 { (a, b) = (b, a % b) }
    return max(a, 1)
}

/// Rounds `t` to the nearest multiple of 1/`timescale` (ties away from zero). Explicit, documented rounding.
func rounded(_ t: Time, toTimescale timescale: Int64) -> Time {
    let n = Int128(t.value) * Int128(timescale)
    let d = Int128(t.timescale)
    let half = d / 2
    let q = n >= 0 ? (n + half) / d : -((-n + half) / d)
    return Time(Int64(q), timescale)
}

/// State shared by both clocks: anchor position, elapsed time at the anchor, rate.
private struct Anchor {
    var position: Time = .zero
    var elapsedAtAnchor: Time = .zero
    var rate: PlaybackRate = .zero

    func position(atElapsed elapsed: Time) -> Time {
        position + scaled(elapsed - elapsedAtAnchor, by: rate)
    }
}

/// Test clock: time only moves when `advance(by:)` is called. Fully exact.
public final class ManualClock: PlaybackClock {
    private struct State { var anchor = Anchor(); var elapsed: Time = .zero }
    private let state = Mutex(State())

    public init(position: Time = .zero, rate: PlaybackRate = .zero) {
        state.withLock { $0.anchor = Anchor(position: position, elapsedAtAnchor: .zero, rate: rate) }
    }

    /// Advances wall time by `delta` (>= 0). Position moves by `delta * rate`.
    public func advance(by delta: Time) {
        precondition(!delta.isNegative, "ManualClock cannot run backwards in wall time")
        state.withLock { $0.elapsed += delta }
    }

    public func now() -> Time { state.withLock { $0.anchor.position(atElapsed: $0.elapsed) } }
    public var rate: PlaybackRate { state.withLock { $0.anchor.rate } }

    public func start(at position: Time, rate: PlaybackRate) {
        state.withLock { $0.anchor = Anchor(position: position, elapsedAtAnchor: $0.elapsed, rate: rate) }
    }

    @discardableResult public func stop() -> Time {
        state.withLock { s in
            let p = s.anchor.position(atElapsed: s.elapsed)
            s.anchor = Anchor(position: p, elapsedAtAnchor: s.elapsed, rate: .zero)
            return p
        }
    }

    public func setRate(_ rate: PlaybackRate) {
        state.withLock { s in
            let p = s.anchor.position(atElapsed: s.elapsed)
            s.anchor = Anchor(position: p, elapsedAtAnchor: s.elapsed, rate: rate)
        }
    }

    public func seek(to position: Time) {
        state.withLock { s in
            s.anchor = Anchor(position: position, elapsedAtAnchor: s.elapsed, rate: s.anchor.rate)
        }
    }
}

/// Wall-clock based clock driven by `mach_continuous_time` (keeps counting across system sleep).
///
/// Exactness: host ticks are converted to integer nanoseconds with `Int128` math
/// (`ticks * numer / denom`, truncated to whole ns once, at the tick source), then the elapsed time is the
/// exact rational `ns / 1_000_000_000` and `now()` is exact rational arithmetic from there.
/// The only rounding: when the clock re-anchors mid-run (`setRate`, `stop`) the scaled elapsed delta
/// (elapsed ns x rate) is rounded to the nearest nanosecond (|error| <= 0.5 ns); the anchor position itself
/// stays exact, and a paused clock is never rounded. The timescale therefore stays bounded by
/// lcm(anchor timescale, 1e9) over any number of rate changes. `start(at:)` and `seek(to:)` keep the
/// caller's position exactly.
public final class HostClock: PlaybackClock {
    private static let nsScale: Int64 = 1_000_000_000
    private let state = Mutex(Anchor())
    private let nanoseconds: @Sendable () -> Int64

    public convenience init() { self.init(nanosecondSource: Self.hostNanoseconds) }

    /// Test seam: injectable monotonic nanosecond source.
    init(nanosecondSource: @escaping @Sendable () -> Int64) {
        self.nanoseconds = nanosecondSource
    }

    private static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (info.numer, info.denom)
    }()

    @Sendable private static func hostNanoseconds() -> Int64 {
        let tb = timebase
        let ns = Int128(mach_continuous_time()) * Int128(tb.numer) / Int128(tb.denom)
        return Int64(ns)
    }

    private func elapsed() -> Time { Time(nanoseconds(), Self.nsScale) }

    /// Re-anchor position: the anchor stays exact; only the scaled elapsed delta is rounded to 1 ns,
    /// and not at all while paused (delta is zero then).
    private func reanchoredPosition(_ a: Anchor, at e: Time) -> Time {
        a.position + rounded(scaled(e - a.elapsedAtAnchor, by: a.rate), toTimescale: Self.nsScale)
    }

    // The tick is read inside the lock in every method, so ticks are observed in lock order and
    // a concurrent re-anchor can never make `now()` go backwards.

    public func now() -> Time {
        state.withLock { $0.position(atElapsed: elapsed()) }
    }

    public var rate: PlaybackRate { state.withLock { $0.rate } }

    public func start(at position: Time, rate: PlaybackRate) {
        state.withLock { $0 = Anchor(position: position, elapsedAtAnchor: elapsed(), rate: rate) }
    }

    @discardableResult public func stop() -> Time {
        state.withLock { s in
            let e = elapsed()
            let p = reanchoredPosition(s, at: e)
            s = Anchor(position: p, elapsedAtAnchor: e, rate: .zero)
            return p
        }
    }

    public func setRate(_ rate: PlaybackRate) {
        state.withLock { s in
            let e = elapsed()
            let p = reanchoredPosition(s, at: e)
            s = Anchor(position: p, elapsedAtAnchor: e, rate: rate)
        }
    }

    public func seek(to position: Time) {
        state.withLock { s in
            s = Anchor(position: position, elapsedAtAnchor: elapsed(), rate: s.rate)
        }
    }
}
