import AppKit
import SQCore
import SQEditorUI

/// Source patching (MON-30): the timeline's patch column follows the clip loaded in the Source view and the session's
/// patch of the active sequence; chip clicks and drags go to the session.
extension EditorPanels {
    func wireSourcePatch() {
        timelineView.onSourcePatchClick = { [weak self] kind in self?.session.toggleSourcePatch(kind) }
        timelineView.onSourcePatchMove = { [weak self] kind, track in self?.session.patchSource(kind, to: track) }
        timelineView.onSourcePatchSolo = { [weak self] kind in self?.session.soloSourcePatch(kind) }
        timelineView.onSourcePatchMoveBoth = { [weak self] kind, track in self?.session.patchSourceBoth(kind, to: track) }
        source.onMediaChange = { [weak self] in self?.syncSourcePatch() }
    }

    func syncSourcePatch() {
        guard let id = source.mediaID, let ref = session.project.media(id), session.activeTimeline != nil else {
            timelineView.sourcePatch = nil; return
        }
        var kinds: Set<TrackKind> = []
        if ref.info?.video != nil || ref.info == nil { kinds.insert(.video) }
        if ref.info?.audio != nil { kinds.insert(.audio) }
        timelineView.sourcePatchStreams = kinds
        timelineView.sourcePatch = session.sourcePatch
    }
}
