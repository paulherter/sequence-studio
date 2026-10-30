import Foundation
import SQCore
import SQTimelineUI

/// Playback follow and Undo reveal, translated from the Mac `EditorPanels` (`followPlayhead`, `revealInTimeline`):
/// Normal pages, Fast Cut follows continuously (`TimelineFeel`), a scroll by the user during playback wins.
extension TimelinePanel {
    /// Call once per frame after `sync` with the transport state. Play pressed with the playhead off screen means the
    /// user looks elsewhere on purpose: no follow until the next play.
    public mutating func followPlayback(playing: Bool) {
        if playing != followWasPlaying {
            followWasPlaying = playing
            if playing {
                let x = geometry.x(for: playhead)
                follow.playbackStarted(playheadVisible: x >= TimelineGeometry.contentOriginX && x <= size.width)
            }
        }
        guard playing, gesture == nil, size.width > 0 else { return }
        let feel = TimelineFeel.forMagnetic(timeline.editMode == .magnetic)
        guard let target = follow.scroll(mode: feel.playbackFollow, playheadX: geometry.x(for: playhead),
                                         scrollX: geometry.scrollX, viewLeft: TimelineGeometry.contentOriginX,
                                         viewRight: size.width) else { return }
        geometry.scrollX = target
        clampScroll()
    }

    /// Undo / Redo (`.reveal`): an affected range off screen scrolls in, its start 10% of the width from the left.
    /// Zoom stays as it is.
    public mutating func reveal(_ r: TimeRange) {
        let left = TimelineGeometry.contentOriginX, right = size.width
        let x0 = geometry.x(for: r.start), x1 = geometry.x(for: r.end)
        guard x1 < left || x0 > right else { return }
        geometry.scrollX += x0 - left - (right - left) * 0.1
        clampScroll()
    }
}
