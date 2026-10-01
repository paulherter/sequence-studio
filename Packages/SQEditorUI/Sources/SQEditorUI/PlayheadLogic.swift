import CoreGraphics
import SQCore

/// Timeline scroll policy during playback (docs/DECISIONS.md: page-wise follow, manual scroll wins).
/// The playhead pages the view when it reaches an edge; once the user scrolls or zooms while playing, the view stays
/// where they put it until playback is started again.
public struct TimelineFollow: Sendable, Equatable {
    public private(set) var manualScrollWins = false
    public init() {}

    /// Play was pressed. A playhead that is off screen at that moment means the user is looking elsewhere on purpose.
    public mutating func playbackStarted(playheadVisible: Bool) { manualScrollWins = !playheadVisible }

    /// The viewport changed by the user (wheel, drag, zoom). Only a change during playback overrides the follow.
    public mutating func userScrolled(whilePlaying: Bool) { if whilePlaying { manualScrollWins = true } }

    /// New `scrollX` when the view must page, nil when it stays. `viewLeft`/`viewRight` bound the content area in view
    /// coordinates; the playhead lands `margin` points from the left edge after a page.
    public func pageScroll(playheadX: CGFloat, scrollX: CGFloat, viewLeft: CGFloat, viewRight: CGFloat,
                           margin: CGFloat = 24) -> CGFloat? {
        guard !manualScrollWins else { return nil }
        guard playheadX > viewRight - 12 || playheadX < viewLeft else { return nil }
        return scrollX + (playheadX - viewLeft) - margin
    }
}

/// Shift while dragging the playhead: it sticks to clip edges, markers and time 0 (Premiere).
public enum PlayheadSnap {
    public static let thresholdPoints: CGFloat = 10

    public static func resolve(_ t: Time, timeline: Timeline, geometry: TimelineGeometry) -> (time: Time, hit: SnapPoint?) {
        let points = timeline.snapPoints(excluding: [], playhead: nil, markers: timeline.markers.map(\.time))
        return snap(t, to: points, threshold: geometry.snapThreshold(points: thresholdPoints),
                    frameDuration: geometry.frameDuration)
    }
}
