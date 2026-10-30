import AppKit
import SQCore

/// Thin strip under a layer name in the Graphics layer list (DESIGN.md "KeyTickStrip"): one tick per key of the layer across
/// the clip, the item's range as a bar behind them, a playhead line, a click seeks. No graph. Pure geometry in `positions` / `time(atX:width:duration:)`.
@MainActor
public final class KeyTickStrip: NSView {
    public static let height: CGFloat = 4
    /// Clip-local key times and the clip length.
    public var times: [Time] = [] { didSet { if oldValue != times { needsDisplay = true } } }
    public var duration: Time = .zero { didSet { if oldValue != duration { needsDisplay = true } } }
    /// The part of the clip the item shows in (clip-local); nil when it shows over the whole clip.
    public var range: TimeRange? { didSet { if oldValue != range { needsDisplay = true } } }
    /// Clip-local playhead; nil outside the clip.
    public var playhead: Time? { didSet { if oldValue != playhead { needsDisplay = true } } }

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }   // the list takes the click

    /// The geometry lives in the portable `KeyTickMath` (shared with the draw-list Graphics panel).
    nonisolated static func fraction(_ t: Time, in duration: Time) -> Double { KeyTickMath.fraction(t, in: duration) }
    public nonisolated static func positions(times: [Time], duration: Time, width: CGFloat) -> [CGFloat] {
        KeyTickMath.positions(times: times, duration: duration, width: width)
    }
    public nonisolated static func time(atX x: CGFloat, width: CGFloat, duration: Time) -> Time {
        KeyTickMath.time(atX: x, width: width, duration: duration)
    }
    public nonisolated static func rangeSpan(_ r: TimeRange, duration: Time, width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        KeyTickMath.rangeSpan(r, duration: duration, width: width)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        if let r = range, duration.value > 0, w > 0 {
            let span = Self.rangeSpan(r, duration: duration, width: w)
            NSColor(cgColor: ItemLanes.barFill)?.setFill()       // the same fill as the item's bar in its timeline lane
            NSRect(x: span.x, y: 1, width: span.width, height: max(bounds.height - 2, 1)).fill()
        }
        Theme.Colors.accent.setFill()
        for x in Self.positions(times: times, duration: duration, width: w) {
            NSRect(x: min(max(x - 1, 0), max(w - 2, 0)), y: 1, width: 2, height: max(bounds.height - 2, 1)).fill()
        }
        if let p = playhead, duration.value > 0 {
            Theme.Colors.playhead.setFill()
            let x = CGFloat(Self.fraction(p, in: duration)) * w
            Theme.PlayheadSkin.lineFrame(centerX: min(max(x, 1), max(w - 1, 1)), height: bounds.height).fill()
        }
    }
}
