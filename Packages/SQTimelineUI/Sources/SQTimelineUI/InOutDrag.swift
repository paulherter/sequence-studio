#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Dragging the In/Out band in the ruler: the ends trim, the middle moves the whole range. Pure math, tested.
public enum InOutDrag {
    public enum Part: Sendable, Equatable {
        case start, end, body

        /// The part the edit logic needs so an In-only or Out-only mark is never inferred from the range.
        public var markedPart: MarkedRangeDragPart {
            switch self {
            case .start: .inEdge
            case .end: .outEdge
            case .body: .body
            }
        }
    }

    /// Pointer distance from an end that still grabs the end (the band's 2 pt edge plus slack).
    public static let edgeZone: CGFloat = 5

    /// Which part of the band the pointer at `x` grabs; nil outside the band (ends reach `edgeZone` past it).
    public static func part(atX x: CGFloat, range: TimeRange, geometry: TimelineGeometry) -> Part? {
        let x0 = geometry.x(for: range.start), x1 = geometry.x(for: range.end)
        guard x >= x0 - edgeZone, x <= x1 + edgeZone else { return nil }
        if x1 - x0 <= 2 * edgeZone { return x < (x0 + x1) / 2 ? .start : .end }     // a narrow band: split in halves, no body
        if x <= x0 + edgeZone { return .start }
        if x >= x1 - edgeZone { return .end }
        return .body
    }

    /// The range after dragging `part` of `original` from `downTime` to `time` (frame aligned by the caller). Never before
    /// zero, never shorter than one frame; a moved body keeps its length.
    public static func target(part: Part, original: TimeRange, downTime: Time, time: Time, frameDuration: Time) -> TimeRange {
        switch part {
        case .start:
            let s = min(max(time, .zero), original.end - frameDuration)
            return TimeRange(start: s, end: original.end)
        case .end:
            let e = max(time, original.start + frameDuration)
            return TimeRange(start: original.start, end: e)
        case .body:
            let s = max(original.start + (time - downTime), .zero)
            return TimeRange(start: s, duration: original.duration)
        }
    }
}
