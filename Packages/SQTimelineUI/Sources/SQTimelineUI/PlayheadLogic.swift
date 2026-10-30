#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Timeline scroll policy during playback (the design notes: page-wise follow, manual scroll wins).
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

    /// Continuous follow (Final Cut): the playhead runs to the center of the content area, then the content scrolls
    /// under it. A playhead left of the view (loop back) is brought to the center too. Never scrolls before time 0.
    public func continuousScroll(playheadX: CGFloat, scrollX: CGFloat, viewLeft: CGFloat, viewRight: CGFloat) -> CGFloat? {
        guard !manualScrollWins else { return nil }
        let centre = (viewLeft + viewRight) / 2
        guard playheadX > centre || playheadX < viewLeft else { return nil }
        let target = max(scrollX + playheadX - centre, 0)
        return target == scrollX ? nil : target
    }

    /// The scroll for `mode` (nil: stay).
    public func scroll(mode: TimelineFeel.PlaybackFollow, playheadX: CGFloat, scrollX: CGFloat,
                       viewLeft: CGFloat, viewRight: CGFloat) -> CGFloat? {
        switch mode {
        case .page: return pageScroll(playheadX: playheadX, scrollX: scrollX, viewLeft: viewLeft, viewRight: viewRight)
        case .continuous: return continuousScroll(playheadX: playheadX, scrollX: scrollX, viewLeft: viewLeft, viewRight: viewRight)
        }
    }
}

/// Shift while dragging the playhead: it sticks to clip edges, markers and time 0 (Premiere).
public enum PlayheadSnap {
    public static let thresholdPoints: CGFloat = 10

    public static func resolve(_ t: Time, timeline: Timeline, geometry: TimelineGeometry,
                               beatLevel: BeatSnapLevel = .everyBeat) -> (time: Time, hit: SnapPoint?) {
        let points = timeline.snapPoints(excluding: [], playhead: nil, markers: timeline.markerSnapTimes(beatLevel: beatLevel))
        return snap(t, to: points, threshold: geometry.snapThreshold(points: thresholdPoints),
                    frameDuration: geometry.frameDuration)
    }
}
