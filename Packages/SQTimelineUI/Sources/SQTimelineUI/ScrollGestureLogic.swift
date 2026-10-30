import Foundation

/// Tuning of timeline scrolling, in one place.
public enum ScrollTuning {
    /// Horizontal trackpad pixel deltas are multiplied by this (Premiere-like reach per swipe).
    public static let trackpadScrollGain: Double = 1.6
    /// One mouse-wheel notch in points (a notch reports ~1 pt).
    public static let wheelNotch: Double = 48
    /// A trackpad gesture decides its axis once the accumulated movement passes this many points.
    public static let axisLockThreshold: Double = 2
    /// Vertical wins only when |dy| exceeds |dx| times this; diagonal-ish swipes stay horizontal.
    public static let verticalBias: Double = 1.5
    /// Predominant-axis rule (Fast Cut): one axis locks only when it moved this many times further than the other;
    /// anything in between is a free diagonal pan (AppKit scroll-view style).
    public static let predominantRatio: Double = 2
    /// Scroll events this long after a pinch ends still count as pinch residue.
    public static let pinchTail: TimeInterval = 0.25

    /// Scroll distance for one event after axis lock/pinch filtering. Positive result = content moves with the fingers
    /// (callers negate for scroll offsets).
    public static func scrollAmounts(dx: Double, dy: Double, precise: Bool, horizontalOnly: Bool) -> (x: Double, y: Double) {
        scrollAmounts(dx: dx, dy: dy, precise: precise, horizontalOnly: horizontalOnly, feel: .normal)
    }

    /// As above with the gain and vertical-swipe rule of `feel`. A trackpad swipe in a feel where vertical motion does
    /// not scroll time drops the vertical part when there is no vertical room; mouse wheels always map it onto time.
    public static func scrollAmounts(dx: Double, dy: Double, precise: Bool, horizontalOnly: Bool,
                                     feel: TimelineFeel) -> (x: Double, y: Double) {
        let kx = precise ? feel.trackpadScrollGain : wheelNotch
        let ky = precise ? 1.0 : wheelNotch
        if horizontalOnly {
            if precise && !feel.verticalSwipeScrollsTime { return (dx * kx, 0) }
            return ((abs(dx) > abs(dy) ? dx : dy) * kx, 0)
        }
        return (dx * kx, dy * ky)
    }
}

/// Per-gesture axis lock for trackpad scrolling: the first movement of a gesture picks horizontal or vertical, the
/// other axis is dropped until the gesture (including its momentum tail) ends. Mouse wheel events (no phase) pass.
/// `.predominant` (Fast Cut) locks only a clearly straight start and leaves a diagonal start free in both axes.
public struct ScrollAxisLock: Sendable, Equatable {
    public enum Axis: Sendable, Equatable { case horizontal, vertical, free }
    public enum Rule: Sendable, Equatable {
        /// Every gesture picks one axis; diagonal-ish starts count as horizontal (`ScrollTuning.verticalBias`).
        case lockPerGesture
        /// Lock only when one axis dominates by `ScrollTuning.predominantRatio`, else pan freely.
        case predominant
    }

    public var rule: Rule
    public private(set) var axis: Axis?
    private var accX = 0.0, accY = 0.0
    public init(rule: Rule = .lockPerGesture) { self.rule = rule }

    public mutating func filter(phase: ScrollZoomState.Phase, momentumPhase: ScrollZoomState.Phase,
                                dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        if momentumPhase != .none {
            if momentumPhase == .began || momentumPhase == .changed || momentumPhase == .stationary {
                let r = apply(dx: dx, dy: dy)
                return r
            }
            let r = apply(dx: dx, dy: dy)               // ended / canceled: last tail event
            reset()
            return r
        }
        switch phase {
        case .none:
            reset()
            return (dx, dy)                             // mouse wheel: stateless
        case .mayBegin, .began:
            reset()
            return apply(dx: dx, dy: dy)
        case .changed, .stationary, .ended, .cancelled:
            return apply(dx: dx, dy: dy)
        }
    }

    private mutating func reset() { axis = nil; accX = 0; accY = 0 }

    private mutating func apply(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        if axis == nil {
            accX += dx; accY += dy
            guard max(abs(accX), abs(accY)) > ScrollTuning.axisLockThreshold else { return (0, 0) }
            axis = Self.pick(accX: accX, accY: accY, rule: rule)
            // Release what was held back, on the chosen axis only.
            return Self.pass(axis, dx: accX, dy: accY)
        }
        return Self.pass(axis, dx: dx, dy: dy)
    }

    static func pick(accX: Double, accY: Double, rule: Rule) -> Axis {
        switch rule {
        case .lockPerGesture:
            return abs(accY) > abs(accX) * ScrollTuning.verticalBias ? .vertical : .horizontal
        case .predominant:
            if abs(accX) >= abs(accY) * ScrollTuning.predominantRatio { return .horizontal }
            if abs(accY) >= abs(accX) * ScrollTuning.predominantRatio { return .vertical }
            return .free
        }
    }

    private static func pass(_ axis: Axis?, dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        switch axis {
        case .vertical: return (0, dy)
        case .free: return (dx, dy)
        case .horizontal, nil: return (dx, 0)
        }
    }
}

/// While a pinch (magnify) is active, and shortly after, the vertical part of scroll events is residue of the pinch.
public struct PinchScrollGuard: Sendable, Equatable {
    private var active = false
    private var endedAt: TimeInterval?
    public init() {}

    /// Feed every magnify event; `now` is a monotonic clock in seconds.
    public mutating func magnify(phase: ScrollZoomState.Phase, now: TimeInterval) {
        switch phase {
        case .began, .changed, .mayBegin, .stationary:
            active = true; endedAt = nil
        case .ended, .cancelled:
            active = false; endedAt = now
        case .none:
            active = true; endedAt = now           // a phase-less magnify: treat as an instant gesture
        }
    }

    public func suppressesVertical(now: TimeInterval) -> Bool {
        if active { return true }
        if let e = endedAt { return now - e < ScrollTuning.pinchTail }
        return false
    }
}
