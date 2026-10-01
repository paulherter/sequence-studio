import CoreGraphics
import Foundation
import SQCore

/// The visible part of the clip in the Effect Controls keyframe area (clip-local seconds). Lanes, ruler, clip bar,
/// speed graph and zoom bar all map time through the same viewport, so they always line up. Pure value type.
public struct KeyframeViewport: Sendable, Equatable {
    public var start: Double
    public var span: Double

    public init(start: Double, span: Double) { self.start = start; self.span = span }

    public static func full(duration: Double) -> KeyframeViewport { KeyframeViewport(start: 0, span: max(duration, 0)) }

    public var end: Double { start + span }
    public var range: ClosedRange<Double> { start ... max(start, end) }

    public func isFull(duration: Double) -> Bool { start <= 1e-9 && span >= duration - 1e-9 }

    /// Span in 1...duration (never below `minSpan`), start so the window stays inside the clip.
    public func clamped(duration: Double, minSpan: Double) -> KeyframeViewport {
        guard duration > 0 else { return .full(duration: 0) }
        let s = min(max(span, min(minSpan, duration)), duration)
        let st = min(max(start, 0), duration - s)
        return KeyframeViewport(start: st, span: s)
    }

    /// `factor` > 1 zooms in, < 1 out. The anchor keeps its position on screen.
    public func zoomed(by factor: Double, around anchor: Double, duration: Double, minSpan: Double) -> KeyframeViewport {
        guard factor > 0, factor.isFinite, span > 0 else { return self }
        let frac = min(max((anchor - start) / span, 0), 1)
        let newSpan = span / factor
        return KeyframeViewport(start: anchor - frac * newSpan, span: newSpan).clamped(duration: duration, minSpan: minSpan)
    }

    public func panned(by seconds: Double, duration: Double, minSpan: Double) -> KeyframeViewport {
        KeyframeViewport(start: start + seconds, span: span).clamped(duration: duration, minSpan: minSpan)
    }

    /// Scrolls just enough to bring `seconds` into view (a small margin from the edges).
    public func revealing(_ seconds: Double, duration: Double, minSpan: Double) -> KeyframeViewport {
        let margin = span * 0.1
        if seconds < start + margin { return KeyframeViewport(start: seconds - margin, span: span).clamped(duration: duration, minSpan: minSpan) }
        if seconds > end - margin { return KeyframeViewport(start: seconds + margin - span, span: span).clamped(duration: duration, minSpan: minSpan) }
        return self
    }

    // MARK: Zoom scrollbar (two round handles, Premiere)

    /// Handle positions as fractions of the clip (0...1).
    public func handles(duration: Double) -> (lo: Double, hi: Double) {
        guard duration > 0 else { return (0, 1) }
        return (min(max(start / duration, 0), 1), min(max(end / duration, 0), 1))
    }

    /// Dragging the left handle: the right edge stays.
    public func settingLowerHandle(_ fraction: Double, duration: Double, minSpan: Double) -> KeyframeViewport {
        let e = end
        let lo = min(max(fraction * duration, 0), e - min(minSpan, duration))
        return KeyframeViewport(start: lo, span: e - lo).clamped(duration: duration, minSpan: minSpan)
    }

    /// Dragging the right handle: the left edge stays.
    public func settingUpperHandle(_ fraction: Double, duration: Double, minSpan: Double) -> KeyframeViewport {
        let hi = min(max(fraction * duration, start + min(minSpan, duration)), duration)
        return KeyframeViewport(start: start, span: hi - start).clamped(duration: duration, minSpan: minSpan)
    }

    /// Moves the window (size unchanged) so its centre sits at `fraction` of the clip.
    public func centered(onFraction fraction: Double, duration: Double, minSpan: Double) -> KeyframeViewport {
        KeyframeViewport(start: fraction * duration - span / 2, span: span).clamped(duration: duration, minSpan: minSpan)
    }
}

/// Shift-snapping of the Effect Controls playhead to keyframes.
public enum KeyframeSnap {
    /// Pointer distance (points) within which the playhead sticks to a keyframe.
    public static let thresholdPoints: CGFloat = 8

    /// The candidate nearest to `t` when it lies within `thresholdSeconds`, else `t`. Returns an exact candidate time.
    public static func snapped(_ t: Time, candidates: [Time], thresholdSeconds: Double) -> Time {
        let ts = Double(t.value) / Double(t.timescale)
        var best: (Time, Double)?
        for c in candidates {
            let d = abs(Double(c.value) / Double(c.timescale) - ts)
            if d <= thresholdSeconds, best == nil || d < best!.1 { best = (c, d) }
        }
        return best?.0 ?? t
    }
}

/// Width of the properties column (left of the divider) and its limits. Persisted by the panel.
public enum EffectControlsSplit {
    public static let defaultWidth: CGFloat = 364
    public static let minLabelWidth: CGFloat = 324
    public static let minLanesWidth: CGFloat = 160
    public static let defaultsKey = "effectControls.labelWidth"

    /// `width` limited to [minLabelWidth, total - minLanesWidth]; never wider than the panel itself.
    public static func clamp(_ width: CGFloat, total: CGFloat) -> CGFloat {
        let upper = max(minLabelWidth, total - minLanesWidth)
        return min(min(max(width, minLabelWidth), upper), max(total, 0))
    }

    public static func load(from d: UserDefaults = .standard) -> CGFloat {
        let v = d.double(forKey: defaultsKey)
        return v >= Double(minLabelWidth) && v.isFinite ? CGFloat(v) : defaultWidth
    }

    public static func save(_ width: CGFloat, to d: UserDefaults = .standard) { d.set(Double(width), forKey: defaultsKey) }
}

/// Axis lock of a speed / value graph handle drag.
public enum GraphAxisLock {
    /// Movement (points) before the direction is decided; the handle does not move until then.
    public static let decisionDistance: CGFloat = 5
    /// Vertical only when the movement is clearly vertical: |dy| at least this many times |dx|.
    public static let verticalRatio: CGFloat = 1.5

    public static func decide(dx: CGFloat, dy: CGFloat) -> GraphGestureState.Axis? {
        guard hypot(dx, dy) >= decisionDistance else { return nil }
        return abs(dy) >= verticalRatio * abs(dx) ? .vertical : .horizontal
    }
}

/// The few axis labels of the graph: top and bottom of the visible range (Premiere style), not one per grid line.
public enum GraphAxisLabels {
    public struct Label: Equatable, Sendable {
        public enum Place: Sendable { case top, bottom }
        public var place: Place
        public var value: Double
    }

    public static func labels(fit: GraphFit) -> [Label] {
        [Label(place: .top, value: fit.value.upperBound), Label(place: .bottom, value: fit.value.lowerBound)]
    }

    public static func format(_ v: Double, scale: Double = 1) -> String {
        let x = v * scale
        let a = abs(x)
        if a >= 100 { return String(format: "%.0f", x) }
        if a >= 1 { return String(format: "%.1f", x) }
        return String(format: "%.2f", x)
    }
}
