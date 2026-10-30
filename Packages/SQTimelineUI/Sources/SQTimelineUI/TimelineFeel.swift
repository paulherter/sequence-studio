import Foundation

/// How the timeline answers trackpad scroll, pinch and playback (docs/research/FCP-TIMELINE-SCROLL-ZOOM.md).
/// `.normal` is the Premiere-like behavior every sequence had before Fast Cut; `.fastCut` is the Final Cut feel a
/// magnetic (Fast Cut) sequence gets. `TimelineView.feel` holds it; whoever owns the sequence's edit mode sets it with
/// `TimelineFeel.forMagnetic(_:)`.
public struct TimelineFeel: Sendable, Equatable {
    public enum PlaybackFollow: Sendable, Equatable {
        /// The view jumps a page when the playhead reaches the right edge (`TimelineFollow.pageScroll`).
        case page
        /// The playhead runs to the center, then stays there while the content scrolls under it
        /// (`TimelineFollow.continuousScroll`, Final Cut's "Continuous Scrolling").
        case continuous
    }

    /// Trackpad pixel deltas are multiplied by this (1 = the content stays under the fingers).
    public var trackpadScrollGain: Double
    /// Axis rule for trackpad gestures.
    public var axisRule: ScrollAxisLock.Rule
    /// Elastic overscroll past the ends with a spring back (trackpad only; mouse wheels clamp).
    public var rubberBand: Bool
    /// A vertical trackpad swipe scrolls time when there is no vertical room (Premiere-ish). Off: it does nothing.
    public var verticalSwipeScrollsTime: Bool
    /// Two-finger double tap (smart magnify) zooms to fit the whole sequence.
    public var doubleTapFits: Bool
    /// Scroll policy while playing.
    public var playbackFollow: PlaybackFollow

    public init(trackpadScrollGain: Double = ScrollTuning.trackpadScrollGain, axisRule: ScrollAxisLock.Rule = .lockPerGesture,
                rubberBand: Bool = false, verticalSwipeScrollsTime: Bool = true, doubleTapFits: Bool = false,
                playbackFollow: PlaybackFollow = .page) {
        self.trackpadScrollGain = trackpadScrollGain
        self.axisRule = axisRule
        self.rubberBand = rubberBand
        self.verticalSwipeScrollsTime = verticalSwipeScrollsTime
        self.doubleTapFits = doubleTapFits
        self.playbackFollow = playbackFollow
    }

    /// Today's behavior, unchanged.
    public static let normal = TimelineFeel()

    /// Final Cut feel: 1:1 tracking, free diagonal pans, rubber band ends, double tap fits. Playback pages like Final
    /// Cut's default; `.continuous` is ready for a toggle.
    public static let fastCut = TimelineFeel(trackpadScrollGain: 1, axisRule: .predominant, rubberBand: true,
                                             verticalSwipeScrollsTime: false, doubleTapFits: true, playbackFollow: .page)

    /// The feel for a sequence's edit mode (magnetic = Fast Cut).
    public static func forMagnetic(_ magnetic: Bool) -> TimelineFeel { magnetic ? .fastCut : .normal }
}

/// Elastic overscroll maths (pure). Positions are scroll offsets in points; `dimension` is the viewport size along
/// the axis, which bounds how far the content can be pulled past its end.
public enum RubberBand {
    /// Apple's scroll-view constant: a small pull past the end moves the content at about this fraction of the fingers.
    public static let coefficient: Double = 0.55
    /// Spring-back duration (seconds).
    public static let springDuration: Double = 0.3

    /// Displayed overscroll for a finger overscroll `x` (sign kept): `(1 - 1 / (|x| c / d + 1)) d`, always below `d`.
    public static func damp(_ x: Double, dimension d: Double) -> Double {
        guard d > 0 else { return 0 }
        let y = (1 - 1 / (abs(x) * coefficient / d + 1)) * d
        return x < 0 ? -y : y
    }

    /// Inverse of `damp` (finger overscroll that shows `y`); `y` is limited to just under `d`.
    public static func undamp(_ y: Double, dimension d: Double) -> Double {
        guard d > 0 else { return 0 }
        let a = min(abs(y), d * 0.999_999)
        let x = (1 / (1 - a / d) - 1) * d / coefficient
        return y < 0 ? -x : x
    }

    /// Finger position behind a displayed `position` (equal inside `range`).
    static func raw(_ position: Double, range: ClosedRange<Double>, dimension: Double) -> Double {
        if position < range.lowerBound { return range.lowerBound - undamp(range.lowerBound - position, dimension: dimension) }
        if position > range.upperBound { return range.upperBound + undamp(position - range.upperBound, dimension: dimension) }
        return position
    }

    /// Displayed position for a finger position `raw`.
    static func displayed(_ raw: Double, range: ClosedRange<Double>, dimension: Double) -> Double {
        if raw < range.lowerBound { return range.lowerBound - damp(range.lowerBound - raw, dimension: dimension) }
        if raw > range.upperBound { return range.upperBound + damp(raw - range.upperBound, dimension: dimension) }
        return raw
    }

    /// Scrolls a displayed position by a finger delta: plain inside `range`, damped past its ends, and exactly
    /// reversible (pulling back by the same delta returns to the same place).
    public static func scroll(position: Double, by delta: Double, range: ClosedRange<Double>, dimension: Double) -> Double {
        displayed(raw(position, range: range, dimension: dimension) + delta, range: range, dimension: dimension)
    }

    /// The end of `range` an overscrolled position springs back to, nil inside the range.
    public static func edge(of position: Double, range: ClosedRange<Double>) -> Double? {
        if position < range.lowerBound { return range.lowerBound }
        if position > range.upperBound { return range.upperBound }
        return nil
    }

    /// Spring-back state at `progress` (0...1 of `springDuration`): ease-out from `from` to `to`, endpoints exact.
    public static func springBack(from: Double, to: Double, progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        if p >= 1 { return to }
        if p <= 0 { return from }
        return from + (to - from) * Theme.Motion.Curve.easeOut.value(p)
    }
}

/// One scroll axis with rubber-band ends, fed every scroll event (pure). Fingers pull past an end with damping and
/// spring back on release; a momentum tail that runs into an end bounces once (up to `maxMomentumBounce`) and the
/// rest of that tail is dropped; a mouse wheel (no phase) clamps hard.
public struct ElasticAxis: Sendable, Equatable {
    /// True after a spring back was asked for, until the next gesture: the rest of the momentum tail is ignored.
    public private(set) var swallowingMomentum = false
    public init() {}

    /// Furthest a momentum tail may carry the content past an end (points).
    public static func maxMomentumBounce(dimension: Double) -> Double { dimension * 0.05 }

    /// New displayed position for `delta` (scroll-offset direction), and whether the view should start a spring back.
    public mutating func step(position: Double, delta: Double, range: ClosedRange<Double>, dimension: Double,
                              phase: ScrollZoomState.Phase, momentumPhase: ScrollZoomState.Phase) -> (position: Double, springBack: Bool) {
        if momentumPhase != .none {
            if swallowingMomentum {
                if momentumPhase == .ended || momentumPhase == .cancelled { swallowingMomentum = false }
                return (position, false)
            }
            var p = RubberBand.scroll(position: position, by: delta, range: range, dimension: dimension)
            if momentumPhase == .ended || momentumPhase == .cancelled {
                return (p, RubberBand.edge(of: p, range: range) != nil)
            }
            if let e = RubberBand.edge(of: p, range: range) {
                let cap = Self.maxMomentumBounce(dimension: dimension)
                if abs(p - e) >= cap {
                    p = e + (p < e ? -cap : cap)
                    swallowingMomentum = true
                    return (p, true)
                }
            }
            return (p, false)
        }
        switch phase {
        case .none:
            swallowingMomentum = false
            return (min(max(position + delta, range.lowerBound), range.upperBound), false)
        case .mayBegin, .began:
            swallowingMomentum = false
            return (RubberBand.scroll(position: position, by: delta, range: range, dimension: dimension), false)
        case .changed, .stationary:
            return (RubberBand.scroll(position: position, by: delta, range: range, dimension: dimension), false)
        case .ended, .cancelled:
            let p = RubberBand.scroll(position: position, by: delta, range: range, dimension: dimension)
            let out = RubberBand.edge(of: p, range: range) != nil
            swallowingMomentum = out
            return (p, out)
        }
    }
}
