#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Fast Cut skimmer (Final Cut's skimmer, our name: hover playhead): a second, yellow line follows the pointer over the
/// tracks (never in the ruler, no head) and shows that frame in the Program monitor while the main playhead stays put.
/// Pure rules; `TimelineView+Skimmer` draws it and reports it to the host.
@MainActor public enum Skimmer {
    /// Line thickness: the same 2 pt as every playhead line, so it reads as a playhead, in its own color.
    public static let width: CGFloat = Theme.PlayheadSkin.lineWidth

    /// Why the skimmer is not shown right now.
    public struct Context: Equatable, Sendable {
        public var isFastCut: Bool
        /// A drag (clip, edge, scrub, marker, zoom box ...) is in flight.
        public var isDragging: Bool
        public var isPlaying: Bool
        /// The razor tool shows its own hover guide.
        public var isRazor: Bool
        public init(isFastCut: Bool, isDragging: Bool, isPlaying: Bool, isRazor: Bool) {
            self.isFastCut = isFastCut; self.isDragging = isDragging; self.isPlaying = isPlaying; self.isRazor = isRazor
        }
        var allowsSkimming: Bool { isFastCut && !isDragging && !isPlaying && !isRazor }
    }

    /// The pointer is over the track lanes: right of the headers, below the ruler, above the zoom bar.
    public static func isOverTracks(_ p: CGPoint, viewHeight: CGFloat, zoomBarHeight: CGFloat) -> Bool {
        p.x >= TimelineGeometry.contentOriginX && p.y >= TimelineGeometry.rulerHeight && p.y < viewHeight - zoomBarHeight
    }

    /// Sequence time the skimmer shows for a pointer (frame-snapped, same mapping as a ruler scrub without Shift); nil
    /// when it is hidden: not Fast Cut, a gesture or playback running, the razor tool, or the pointer off the tracks.
    public static func time(pointer: CGPoint?, context: Context, viewHeight: CGFloat, zoomBarHeight: CGFloat,
                            geometry: TimelineGeometry) -> Time? {
        guard context.allowsSkimming, let p = pointer,
              isOverTracks(p, viewHeight: viewHeight, zoomBarHeight: zoomBarHeight) else { return nil }
        return geometry.time(atX: p.x)
    }

    /// The line over the tracks (the ruler has none).
    public static func lineRect(x: CGFloat, viewHeight: CGFloat, zoomBarHeight: CGFloat) -> CGRect {
        Theme.PlayheadSkin.lineFrame(centerX: x, y: TimelineGeometry.rulerHeight,
                               height: max(viewHeight - zoomBarHeight - TimelineGeometry.rulerHeight, 0))
    }
}
