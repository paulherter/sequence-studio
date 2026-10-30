import AppKit
import SQCore
import SQTimelineUI
import SQUIKit

/// The Marker List panel (`MarkerIndexView`) and the timeline's thumbnail frames for the Head and Tail / Continuous modes.
extension EditorPanels {
    func wireMarkerList() {
        markerListView.onGo = { [weak self] t in self?.session.seek(to: t) }
        markerListView.onExportCSV = { [weak self] in self?.onCommand?(.exportMarkersCSV) }
        timelineView.thumbnailFrame = { [weak self] id, t in
            guard let self, let ref = session.project.media(id) else { return nil }
            return clipThumbnails.frame(for: ref, at: t)
        }
    }

    /// Keeps the list in step with the sequence. Reloading is cheap (a sort of the markers), done on project changes only;
    /// the row of the playhead follows every playhead change.
    func syncMarkerList(_ change: EditorSession.Change) {
        guard let tl = session.activeTimeline else { return }
        if change.contains(.project) { markerListView.reload(tl) }
        if change.contains(.project) || change.contains(.playhead) { markerListView.follow(playhead: session.playhead) }
    }
}
