import AppKit
import SQCore

/// Source patching (MON-30 / TL-44): while a source is loaded, a column left of the track badges shows where the
/// source's video ("V") and audio ("A") go for Insert / Overwrite. Click a chip: that stream on / off. Drag it onto
/// another track of its kind: patched there. Track targeting (the badge) is separate and unchanged.
extension TimelineView {
    /// Track a stream's chip sits on: its patched track, shown even while disconnected.
    func patchChipTrack(_ kind: TrackKind) -> Track.ID? {
        guard let p = sourcePatch else { return nil }
        var on = p
        on[kind].isConnected = true
        return timeline.patchedTrack(on, kind: kind)
    }

    func patchState(for id: Track.ID) -> TrackHeaderView.PatchState {
        guard let p = sourcePatch else { return TrackHeaderView.PatchState() }
        var state = TrackHeaderView.PatchState(column: true, dropHighlight: patchDropTrack == id)
        for kind in [TrackKind.video, .audio] where sourcePatchStreams.contains(kind) && patchChipTrack(kind) == id {
            state.chip = (kind, p[kind].isConnected)
        }
        return state
    }

    /// Caption and Mix rows move their badge and name by the same amount as the track headers.
    var patchColumnOffset: CGFloat {
        sourcePatch == nil ? 0 : TrackHeaderView.patchWidth + TrackHeaderView.patchGap - 2
    }

    func sourcePatchChanged() {
        positionHeaders(apply: true)
        needsDisplay = true
    }

    /// The track of `kind` whose header row is under a window point; nil off the header column or on another kind.
    func patchTrack(_ kind: TrackKind, atWindow p: NSPoint) -> Track.ID? {
        let q = convert(p, from: nil)
        guard q.x >= TimelineGeometry.toolColumnWidth, q.x <= TimelineGeometry.contentOriginX,
              q.y >= TimelineGeometry.rulerHeight else { return nil }
        return layoutRows().first { $0.kind == kind && q.y >= $0.y && q.y < $0.maxY }?.track
    }

    func patchDragged(_ kind: TrackKind, window p: NSPoint, ended: Bool, both: Bool = false) {
        let hit = patchTrack(kind, atWindow: p)
        if ended {
            patchDropTrack = nil
            if let hit {
                if both, let move = onSourcePatchMoveBoth { move(kind, hit) } else { onSourcePatchMove?(kind, hit) }
            }
        } else {
            patchDropTrack = hit
        }
    }
}
