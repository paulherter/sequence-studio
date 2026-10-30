import Foundation

/// Short ease for key, zoom-tool click and `\` zoom changes (pure; the view drives it with a 60 Hz timer).
/// The scale is interpolated in log space so every frame is the same zoom ratio apart, which keeps the anchored time
/// exact: scrollX comes from `TimelineZoom.anchoredScroll` for the interpolated scale each frame.
public struct ZoomAnimation: Sendable, Equatable {
    public static let duration: Double = Theme.Motion.fast
    public static let frameRate: Double = 60
    /// Frames a full animation takes at `frameRate`.
    public static var frameCount: Int { Int((duration * frameRate).rounded()) }

    public enum Mode: Sendable, Equatable {
        /// The time under this x (content coordinates, 0 = left edge of the content area) stays fixed.
        case anchored(x: Double)
        /// No anchor (fit / restore): the time at the left edge moves linearly from start to end.
        case free
    }

    public var fromScale: Double, toScale: Double
    public var fromScroll: Double, toScroll: Double
    public var mode: Mode

    public init(fromScale: Double, fromScroll: Double, toScale: Double, toScroll: Double, mode: Mode) {
        self.fromScale = fromScale; self.fromScroll = fromScroll
        self.toScale = toScale; self.toScroll = toScroll
        self.mode = mode
    }

    /// Ease-out cubic (`Theme.Motion.Curve.easeOut`): fast start, soft landing. 0 -> 0, 1 -> 1, monotonic.
    public static func ease(_ t: Double) -> Double { Theme.Motion.Curve.easeOut.value(t) }

    /// State at `progress` (0...1 of the duration, linear time). Endpoints are exact.
    public func state(progress: Double) -> (scale: Double, scrollX: Double) {
        let p = min(max(progress, 0), 1)
        if p >= 1 { return (toScale, toScroll) }
        if p <= 0 { return (fromScale, fromScroll) }
        let e = Self.ease(p)
        let scale = fromScale * pow(toScale / fromScale, e)
        switch mode {
        case .anchored(let x):
            return (scale, TimelineZoom.anchoredScroll(oldScale: fromScale, newScale: scale, scrollX: fromScroll, anchorX: x))
        case .free:
            let a = fromScroll / fromScale, b = toScroll / toScale
            return (scale, (a + (b - a) * e) * scale)
        }
    }

    /// Progress after `elapsed` seconds.
    public static func progress(elapsed: Double) -> Double { min(max(elapsed / duration, 0), 1) }
}

/// Decides whether a `scrollWheel` event zooms. Option/Cmd zooms; if the key is released while the trackpad momentum
/// tail still runs, the tail keeps zooming (instead of turning into a sideways scroll), until the momentum ends.
public struct ScrollZoomState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case none, mayBegin, began, changed, stationary, ended, cancelled }

    public private(set) var zooming = false
    public init() {}

    /// Feed every scroll event; returns true when it is a zoom event.
    public mutating func isZoom(phase: Phase, momentumPhase: Phase, modifierHeld: Bool) -> Bool {
        if momentumPhase != .none {
            // Momentum tail: the modifier no longer matters, the gesture's decision stands.
            let result = zooming
            if momentumPhase == .ended || momentumPhase == .cancelled { zooming = false }
            return result
        }
        switch phase {
        case .none:
            zooming = false                      // mouse wheel: stateless
            return modifierHeld
        case .mayBegin, .began:
            zooming = modifierHeld
            return zooming
        case .changed, .stationary:
            zooming = modifierHeld               // releasing the key with fingers down returns to scrolling
            return zooming
        case .ended, .cancelled:
            // Fingers lifted: the momentum tail (if any) follows this decision; the key may already be up.
            return zooming
        }
    }
}

/// Playhead line hit-test in the track area (drag it like the ruler scrub).
/// Priority: the line wins only when the pointer is within `tolerance` of it; everywhere else clips, trim handles
/// and the rest keep the click, so a trim handle 5 pt from the line still trims. A handle within the 4 pt band
/// loses to the playhead (the line is exactly hit).
public enum PlayheadHit {
    public static let tolerance: Double = 4

    /// `contentLeft`/`contentTop`/`contentBottom`: the track area in view coordinates (below the ruler, right of the headers).
    public static func isOnLine(pointX: Double, pointY: Double, playheadX: Double,
                                contentLeft: Double, contentTop: Double, contentBottom: Double) -> Bool {
        guard pointX >= contentLeft, pointY >= contentTop, pointY < contentBottom else { return false }
        return abs(pointX - playheadX) <= tolerance
    }
}
