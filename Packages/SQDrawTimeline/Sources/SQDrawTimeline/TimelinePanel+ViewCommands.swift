import Foundation
import SQCore
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// Menu and key commands that need the timeline view's own state (toggles, edge selection, heights, zoom), translated
/// from the Mac AppController+Commands / +TimelineOps and EditorPanels (`setEditMode`, `editMarker`). The edits
/// themselves stay the session's.
extension TimelinePanel {
    /// Defaults key of the track height preset (the Mac `EditorPanels` uses the same).
    public static let heightModeDefaultsKey = "sq.trackHeightMode"
    /// Defaults key of Fit All Tracks to Height.
    public static let fitTracksDefaultsKey = "sq.fitTracksToHeight"

    /// The Mac status line when an edge command finds no selected edit.
    static let needEditLine = "Select an edit first (click a clip edge). Opt+Cmd+Left/Right slips the clip."

    /// Check marks of the timeline's View and Sequence toggles (the Mac `validateTimelineOpItem`): snapping, linked
    /// selection, Fast Cut, Fit All Tracks and the thumbnail mode.
    @MainActor public func viewChecks(session s: EditorSession) -> Set<EditorCommand> {
        var out: Set<EditorCommand> = []
        if toolState.snapping { out.insert(.toggleSnapping) }
        if toolState.linkedSelection { out.insert(.toggleLinkedSelection) }
        if s.activeTimeline?.editMode == .magnetic { out.insert(.toggleMagnetic) }
        if geometry.fitAllTracks { out.insert(.toggleFitTracks) }
        if let c = ThumbnailModeChoice(rawValue: thumbnailMode.rawValue) { out.insert(.thumbnailMode(c)) }
        return out
    }

    /// Runs `c` when it is a view command: nil = not one of them (the host goes on), "" = done, else a status line.
    /// `zooms`: the zoom commands go to the timeline (`CommandRouting.zoomTarget` is `.timeline`); else they pass on.
    /// `ownsDelete`: the timeline (or nothing) has the focus, so Delete may close the selected gap; another panel keeps it.
    @MainActor public mutating func runViewCommand(_ c: EditorCommand, session s: EditorSession, zooms: Bool = true,
                                                  host: TimelineHost? = nil, ownsDelete: Bool = true,
                                                  defaults: UserDefaults = .standard) -> String? {
        let edges = interaction.edgeSelection
        func trim(_ n: Int, moveFallback: Bool) -> String {
            if let e = edges { s.trimEdges(e, frames: n); return StepStatus.line("Trim", frames: n) }
            // Fast Cut: Opt+Left/Right with a main-track clip and no edit selected is Move Clip Left / Right.
            if moveFallback, s.fastCutCommandEnabled(n < 0 ? .moveClipLeft : .moveClipRight) { return s.moveSelectedMainClips(n) }
            return Self.needEditLine
        }
        switch c {
        case .tool(let tool):
            toolState.select(tool)
            return SQL10n.string(EditorCommand.tool(tool).title)
        case .slipKeyframesStayTool:
            toolState.selectSlipKeyframesStay()
            return SQL10n.string(EditorCommand.slipKeyframesStayTool.title)
        case .delete, .rippleDelete:
            // A selected gap closes (the Mac `deleteSelectedGap`, after a selected transition); clips go on to the host.
            guard ownsDelete, gesture == nil, s.selectedTransition == nil, s.selection.isEmpty, s.captionSelection.isEmpty,
                  let gap = interaction.gapSelection else { return nil }
            s.closeGap(gap)
            return ""
        case .toggleSnapping:
            toolState.snapping.toggle()
            toolState.storeToggles(defaults)
            _ = s.setSnapping(toolState.snapping)                    // saved with the sequence, one undo step
            return toolState.snapping ? "Snapping on" : "Snapping off"
        case .toggleLinkedSelection:
            toolState.linkedSelection.toggle()
            s.linkedSelection = toolState.linkedSelection
            _ = s.setLinkedSelection(toolState.linkedSelection)      // saved with the sequence, one undo step
            toolState.storeToggles(defaults)
            return toolState.linkedSelection ? "Linked Selection on" : "Linked Selection off"
        case .thumbnailMode(let choice):
            guard let m = ThumbnailMode(rawValue: choice.rawValue) else { return "" }
            thumbnailMode = m
            // `ThumbnailPrefs.mode` with the given defaults (the Mac menu writes the same key and tells the other views).
            defaults.set(m.rawValue, forKey: ThumbnailPrefs.modeKey)
            NotificationCenter.default.post(name: ThumbnailPrefs.didChange, object: nil)
            return ""
        case .toggleMagnetic:
            return setEditMode(s.activeTimeline?.editMode == .magnetic ? .normal : .magnetic, session: s)
        case .zoomIn, .zoomOut, .zoomFit:
            guard zooms else { return nil }
            c == .zoomIn ? zoomIn() : c == .zoomOut ? zoomOut() : zoomToFit()
            follow.userScrolled(whilePlaying: isPlaying)
            return ""
        case .videoTracksTaller: sizeTracks(.video, direction: 1, defaults: defaults)
        case .videoTracksShorter: sizeTracks(.video, direction: -1, defaults: defaults)
        case .audioTracksTaller: sizeTracks(.audio, direction: 1, defaults: defaults)
        case .audioTracksShorter: sizeTracks(.audio, direction: -1, defaults: defaults)
        case .allTracksTaller: sizeTracks(nil, direction: 1, defaults: defaults)
        case .allTracksShorter: sizeTracks(nil, direction: -1, defaults: defaults)
        case .toggleFitTracks: setFitsTracks(!geometry.fitAllTracks, defaults: defaults)
        case .minimizeAllTracks: applyManualHeights(TrackSizing.minimizedAll(rows: rows), defaults: defaults)
        case .expandAllTracks: applyManualHeights(TrackSizing.expandedAll, defaults: defaults)
        case .trackHeightSmall: setHeightMode(.small, defaults: defaults)
        case .trackHeightMedium: setHeightMode(.medium, defaults: defaults)
        case .trackHeightLarge: setHeightMode(.large, defaults: defaults)
        case .trackHeightAuto: setHeightMode(.auto, defaults: defaults)
        case .selectLeftEdge, .selectRightEdge:
            guard let sel = s.edgeSelectionOfSelection(c == .selectLeftEdge ? .head : .tail) else { return "Select a clip first." }
            interaction.setEdgeSelection(sel)
        case .toggleTrimType:
            guard let sel = edges else { return Self.needEditLine }
            interaction.setEdgeSelection(EdgeEdits.cycled(sel, in: timeline))   // regular, ripple, rolling
        case .trimBackward: return trim(-1, moveFallback: true)
        case .trimForward: return trim(1, moveFallback: true)
        case .trimBackward5: return trim(-StepStatus.large, moveFallback: false)
        case .trimForward5: return trim(StepStatus.large, moveFallback: false)
        case .extendEdit:
            guard let e = edges else { return Self.needEditLine }
            s.extendEdit(e)
        case .saveAsTemplate: return Self.open(.saveTemplate, host)
        case .createAnglesClip: return Self.open(.createAnglesClip, host)
        case .toggleAnimationZones:
            guard let host else { return "Select a title clip first." }
            TimelineMenus.toggleZones(session: s, host: host)
        case .editMarker:
            guard let id = s.markerAtPlayhead() else { return "No marker at the playhead." }
            return Self.open(.marker(id), host)
        case .addMarker:
            // The Mac (AppController+Commands): M on a marker that is already there opens its editor.
            guard let r = s.markAtPlayhead() else { return "" }
            return r.openEdit ? Self.open(.marker(r.id), host) : ""
        case .addAndEditMarker:
            guard let r = s.markAtPlayhead() else { return "" }
            return Self.open(.marker(r.id), host)
        default:
            return nil
        }
        return ""
    }

    /// "" when the host opened `r`, else the missing editor's status line.
    @MainActor static func open(_ r: TimelineEditorRequest, _ host: TimelineHost?) -> String {
        host?.open?(r) == true ? "" : r.unavailable
    }

    /// Normal | Fast Cut (the Mac `EditorPanels.setEditMode`): one undo step and the mode's status line.
    @MainActor public mutating func setEditMode(_ mode: TimelineEditMode, session s: EditorSession) -> String {
        guard s.setTimelineEditMode(mode) else { return "" }
        return mode == .magnetic ? "Fast Cut: the main track closes gaps, clips above and below stay attached" : "Normal: classic tracks"
    }

    /// Open, sequence switch, Undo / Redo: the sequence's saved Snapping and Linked Selection drive the timeline (the
    /// Mac `EditorPanels` on `.project`). Call after `sync`.
    @MainActor public mutating func syncToggles(session s: EditorSession) {
        guard let t = s.activeTimeline,
              toolState.snapping != t.snappingOn || toolState.linkedSelection != t.linkedSelectionOn else { return }
        var st = toolState
        st.snapping = t.snappingOn
        st.linkedSelection = t.linkedSelectionOn
        toolState = st
        s.linkedSelection = t.linkedSelectionOn
    }

    /// The track height preset and Fit All Tracks the user picked last (the Mac `EditorPanels` reads the same keys).
    public mutating func loadHeightPrefs(_ defaults: UserDefaults = .standard) {
        geometry.heightMode = TrackHeightMode(rawValue: defaults.string(forKey: Self.heightModeDefaultsKey) ?? "") ?? .medium
        geometry.fitAllTracks = defaults.bool(forKey: Self.fitTracksDefaultsKey)
        clampScroll()
    }

    /// Height commands: one step taller (+1) or shorter (-1) for the tracks of `kind` (nil = all).
    mutating func sizeTracks(_ kind: TrackKind?, direction: Int, defaults: UserDefaults) {
        applyManualHeights(TrackSizing.stepped(rows: rows, kind: kind, direction: direction), defaults: defaults)
    }

    /// Track height preset (Small / Medium / Large / Auto): clears per-track overrides and keeps the mode.
    mutating func setHeightMode(_ m: TrackHeightMode, defaults: UserDefaults) {
        geometry.heightMode = m
        applyManualHeights([:], defaults: defaults)
        defaults.set(m.rawValue, forKey: Self.heightModeDefaultsKey)
    }

    /// Fit All Tracks: heights follow the panel height. Turning it off keeps the heights as drawn (nothing jumps).
    mutating func setFitsTracks(_ on: Bool, defaults: UserDefaults) {
        guard on != geometry.fitAllTracks else { return }
        if on { geometry.fitAllTracks = true; clampScroll() }
        else { applyHeights(TrackSizing.frozen(rows)) }               // turns the flag off
        defaults.set(on, forKey: Self.fitTracksDefaultsKey)
        persistHeights()
    }

    /// A manual height change: Fit All Tracks goes off first (kept in the defaults), the heights are kept per sequence.
    mutating func applyManualHeights(_ h: [Track.ID: CGFloat], defaults: UserDefaults) {
        if geometry.fitAllTracks { defaults.set(false, forKey: Self.fitTracksDefaultsKey) }
        applyHeights(h)
        persistHeights()
    }
}
