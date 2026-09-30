import Foundation

/// Rational playback speed. Negative = reverse, `.zero` = paused. Always stored reduced with `den > 0`.
public struct PlaybackRate: Sendable, Hashable {
    public private(set) var num: Int32
    public private(set) var den: Int32

    public init(_ num: Int32, _ den: Int32 = 1) {
        precondition(den != 0, "PlaybackRate denominator must not be zero")
        var n = Int64(num), d = Int64(den)
        if d < 0 { n = -n; d = -d }
        var a = abs(n), b = d
        while b != 0 { (a, b) = (b, a % b) }
        if a > 1 { n /= a; d /= a }
        if n == 0 { d = 1 }
        self.num = Int32(clamping: n)
        self.den = Int32(clamping: d)
    }

    public static let zero = PlaybackRate(0)
    public static let forward = PlaybackRate(1)
    public static let reverse = PlaybackRate(-1)

    public var isPaused: Bool { num == 0 }
    public var isReverse: Bool { num < 0 }
    public var isForward: Bool { num > 0 }
    /// Absolute speed (always >= 0).
    public var magnitude: PlaybackRate { PlaybackRate(num.magnitude > Int32.max.magnitude ? Int32.max : abs(num), den) }
    public var negated: PlaybackRate { PlaybackRate(-num, den) }

    /// Scales the magnitude by `factor`, keeping the sign.
    func scaled(by factor: Int32) -> PlaybackRate { PlaybackRate(num * factor, den) }
    func isLess(thanMagnitude other: Int32) -> Bool { Int64(abs(num)) < Int64(other) * Int64(den) }
}

public enum ShuttleKey: Sendable, Hashable { case j, k, l }

public enum ShuttleAction: Sendable, Equatable {
    case setRate(PlaybackRate)
    case step(Int)          // frames, signed
    case none
}

/// J/K/L shuttle state machine (Premiere behaviour).
///
/// - L: 1, 2, 4, 8 on repeated presses (capped at 8). J mirrors. The opposite key restarts at ±1.
/// - K: stop. While K is held:
///   - press of L/J is a tap: `.step(±1)` frame immediately;
///   - if the L/J key is still held after the UI's hold threshold (~0.25 s), the UI calls
///     `holdElapsed(_:)` which returns `.setRate(±1/4)`; releasing L/J then returns `.setRate(.zero)`.
/// - Choice: releasing K while a slow-mode L/J is still held resumes at ±1 (simple, documented).
///   Releasing K otherwise does nothing (stays paused).
public struct Shuttle: Sendable, Equatable {
    public private(set) var rate: PlaybackRate = .zero
    private var kHeld = false
    private var held: Set<ShuttleKey> = []       // L/J currently down
    private var slow: Set<ShuttleKey> = []       // L/J promoted to slow mode by hold

    public init() {}

    /// Playback was stopped by something other than K (a click in the timeline, the transport button).
    public mutating func stopped() { rate = .zero }

    public mutating func press(_ key: ShuttleKey) -> ShuttleAction {
        switch key {
        case .k:
            kHeld = true
            return setRate(.zero)
        case .l, .j:
            let dir: Int32 = key == .l ? 1 : -1
            held.insert(key)
            if kHeld { return .step(Int(dir)) }
            let same = dir > 0 ? rate.isForward : rate.isReverse
            if !same { return setRate(PlaybackRate(dir)) }
            if rate.isLess(thanMagnitude: 1) { return setRate(PlaybackRate(dir)) }
            if !rate.isLess(thanMagnitude: 8) { return setRate(rate) }
            return setRate(rate.scaled(by: 2))
        }
    }

    public mutating func release(_ key: ShuttleKey) -> ShuttleAction {
        switch key {
        case .k:
            kHeld = false
            // Resume from slow mode if L/J is still held.
            if slow.contains(.l) { slow.remove(.l); return setRate(.forward) }
            if slow.contains(.j) { slow.remove(.j); return setRate(.reverse) }
            return .none
        case .l, .j:
            held.remove(key)
            if slow.remove(key) != nil { return setRate(.zero) }
            return .none
        }
    }

    /// Called by the UI when L/J has stayed down with K held past the hold threshold.
    public mutating func holdElapsed(_ key: ShuttleKey) -> ShuttleAction {
        guard kHeld, key != .k, held.contains(key) else { return .none }
        slow.insert(key)
        return setRate(PlaybackRate(key == .l ? 1 : -1, 4))
    }

    private mutating func setRate(_ r: PlaybackRate) -> ShuttleAction {
        rate = r
        return .setRate(r)
    }
}
