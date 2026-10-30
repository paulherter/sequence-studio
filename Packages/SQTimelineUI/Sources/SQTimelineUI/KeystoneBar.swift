import Foundation
import SQCore

/// Keystone drags as a string: the payload JSON (self-contained, so the drop ghost knows its length). The Mac puts it on
/// the pasteboard (KeystoneSupport.swift), the shared toolkit hands it to the timeline panel directly.
public enum KeystoneDrag {
    public static func string(for keystone: Keystone) -> String? {
        (try? keystone.payload()).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func keystone(from string: String) -> Keystone? {
        try? Keystone(payload: Data(string.utf8), version: Keystone.payloadVersion)
    }
}

/// The bar of the keystone applied last, drawn along the bottom of its clip in the timeline; its edges stretch it.
/// Portable: the Mac `TimelineView` and the shared-toolkit timeline panel read the same geometry.
public struct KeystoneBar: Sendable, Hashable {
    public enum Edge: Sendable { case start, end }

    public var clip: Clip.ID
    public var span: KeystoneSpan
    public var name: String
    public init(clip: Clip.ID, span: KeystoneSpan, name: String) { self.clip = clip; self.span = span; self.name = name }

    public static let height: CGFloat = 12
    public static let edgeSlop: CGFloat = 5
    /// Rows lower than this show no bar (too little room above the clip name).
    public static let minimumRowHeight: CGFloat = 34

    /// The bar inside a clip drawn in `row` (bottom strip).
    public static func rect(span: KeystoneSpan, clipStart: Time, row: TrackRow, geometry: TimelineGeometry) -> CGRect {
        let x0 = geometry.x(for: clipStart + span.start), x1 = geometry.x(for: clipStart + span.end)
        return CGRect(x: x0, y: row.maxY - height - 2, width: max(x1 - x0, 2), height: height)
    }

    /// Which edge of the bar is under `p` (a few points either side; within the bar's height).
    public static func edge(at p: CGPoint, barRect r: CGRect) -> Edge? {
        guard p.y >= r.minY - 2, p.y <= r.maxY + 2 else { return nil }
        if abs(p.x - r.minX) <= edgeSlop { return .start }
        if abs(p.x - r.maxX) <= edgeSlop { return .end }
        return nil
    }

    /// `span` with `edge` dragged to clip-local `t`: the other edge stays, the result stays inside the clip and is at least
    /// `minimum` long.
    public static func dragged(_ span: KeystoneSpan, edge: Edge, toLocal t: Time, clipDuration: Time, minimum: Time) -> KeystoneSpan {
        var r = span
        switch edge {
        case .end:
            let end = min(max(t, span.start + minimum), max(clipDuration, span.start + minimum))
            r.duration = end - span.start
        case .start:
            let start = max(min(t, span.end - minimum), .zero)
            r.start = start
            r.duration = span.end - start
        }
        return r
    }
}

/// State of one keystone edge drag (the Mac `TimelineView.keystoneDrag`, the shared panel's gesture).
public struct KeystoneEdgeDrag: Sendable {
    public var bar: KeystoneBar
    public var edge: KeystoneBar.Edge
    /// The clip before the drag: every update restretches from it, so the preview never accumulates rounding.
    public var original: Clip
    public var current: KeystoneSpan
    public init(bar: KeystoneBar, edge: KeystoneBar.Edge, original: Clip, current: KeystoneSpan) {
        self.bar = bar; self.edge = edge; self.original = original; self.current = current
    }
}
