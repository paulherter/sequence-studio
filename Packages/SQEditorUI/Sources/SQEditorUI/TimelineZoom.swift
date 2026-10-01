import CoreGraphics
import Foundation

/// Pure zoom maths of the timeline (no AppKit): steps, gains, anchoring, limits, the zoom bar. Scale is points per second.
public enum TimelineZoom {
    /// One `=` / `-` press (Premiere's steps are coarse). From fit to frame level takes `steps(from:to:)` presses.
    public static let keyStep: Double = 2.5
    /// Option + two-finger scroll: scale = exp(delta * gain). A normal swipe (~300 pt) covers the whole range.
    public static let preciseScrollGain: Double = 0.02
    /// Option + mouse wheel notch (deltas of ~1 per notch).
    public static let wheelGain: Double = 0.2
    /// Pinch: scale *= exp(magnification * gain). One full pinch (magnification ~1) is ~90x.
    public static let pinchGain: Double = 4.5
    /// Whole-sequence view never goes below this absolute scale.
    public static let floorPointsPerSecond: Double = 0.02
    /// Most zoomed in: this many frames across the content width.
    public static let framesAcrossAtMax: Double = 4
    /// Hard cap in points per frame (huge windows).
    public static let maxPointsPerFrame: Double = 400

    public static func scrollFactor(delta: Double, precise: Bool) -> Double {
        exp(delta * (precise ? preciseScrollGain : wheelGain))
    }

    public static func pinchFactor(magnification: Double) -> Double { exp(magnification * pinchGain) }

    /// Allowed scale range. `fit` is the scale that shows the whole sequence; zooming out stops a little beyond it.
    public static func limits(fit: Double, viewportWidth: Double, frameSeconds: Double) -> ClosedRange<Double> {
        let hi = max(min(viewportWidth / framesAcrossAtMax, maxPointsPerFrame) / frameSeconds, floorPointsPerSecond)
        let lo = min(max(fit * 0.5, floorPointsPerSecond), hi)
        return lo...hi
    }

    public static func clamp(_ pps: Double, to r: ClosedRange<Double>) -> Double { min(max(pps, r.lowerBound), r.upperBound) }

    /// Scroll offset after a scale change that keeps the time under `anchorX` (content coordinates, 0 = left edge of
    /// the content area) fixed.
    public static func anchoredScroll(oldScale: Double, newScale: Double, scrollX: Double, anchorX: Double) -> Double {
        let seconds = (anchorX + scrollX) / oldScale
        return seconds * newScale - anchorX
    }

    /// Key presses (`keyStep` each) needed to go from `from` to `to` (rounded up).
    public static func steps(from: Double, to: Double) -> Int {
        guard from > 0, to > from else { return 0 }
        return Int((log(to / from) / log(keyStep)).rounded(.up))
    }

    public static func isFit(scale: Double, fit: Double) -> Bool { abs(scale - fit) <= fit * 0.001 }

    // MARK: Zoom bar

    /// Visible part of the sequence as fractions (0...1) of the bar track. `extent` = seconds the bar represents.
    public static func handles(scrollX: Double, viewport: Double, scale: Double, extent: Double) -> (lo: Double, hi: Double) {
        guard extent > 0, scale > 0 else { return (0, 1) }
        let a = max(scrollX / scale / extent, 0), b = min((scrollX + viewport) / scale / extent, 1)
        return (min(a, b), b)
    }

    /// Seconds the bar spans: the sequence, or further when the view already shows more.
    public static func barExtent(contentSeconds: Double, scrollX: Double, viewport: Double, scale: Double) -> Double {
        max(contentSeconds, (scrollX + viewport) / max(scale, 1e-9), 1e-6)
    }

    /// Result of dragging a bar handle to `fraction` while the other edge stays: new scale and scroll.
    public static func dragHandle(lower: Bool, fraction: Double, scrollX: Double, viewport: Double, scale: Double,
                                  extent: Double, range: ClosedRange<Double>) -> (scale: Double, scrollX: Double) {
        let start = scrollX / scale, end = (scrollX + viewport) / scale
        let minSpan = viewport / range.upperBound, maxSpan = viewport / range.lowerBound
        let t = fraction * extent
        var lo = start, hi = end
        if lower { lo = min(max(t, end - maxSpan), end - minSpan) } else { hi = min(max(t, start + minSpan), start + maxSpan) }
        let newScale = clamp(viewport / (hi - lo), to: range)
        return (newScale, lo * newScale)
    }
}

/// `\` remembers where you were: fit whole sequence, press again to return (Premiere).
public struct ZoomFitToggle: Sendable, Equatable {
    public var previous: (scale: Double, scrollX: Double)?

    public init() {}
    public static func == (a: ZoomFitToggle, b: ZoomFitToggle) -> Bool { a.previous?.scale == b.previous?.scale && a.previous?.scrollX == b.previous?.scrollX }

    public enum Action: Equatable { case fit, restore(scale: Double, scrollX: Double) }

    /// At fit with a remembered level: restore it. Otherwise remember the current level and fit.
    public mutating func press(scale: Double, scrollX: Double, fit: Double) -> Action {
        if TimelineZoom.isFit(scale: scale, fit: fit), let p = previous {
            previous = nil
            return .restore(scale: p.scale, scrollX: p.scrollX)
        }
        if !TimelineZoom.isFit(scale: scale, fit: fit) { previous = (scale, scrollX) }
        return .fit
    }
}
