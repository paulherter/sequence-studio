import Foundation
import SQCore

/// Round 2 timeline verbs: Q/W variants, Duplicate, Enable/Disable, lane moves, marker drag, target modifiers.
/// One undo step per call.
extension EditorSession {
    /// Q / W with Shift (rolling) or Option (plain trim, gap stays). `.ripple` is `rippleTrimToPlayhead`.
    public func trimToPlayhead(_ edge: ClipEdge, mode: PlayheadTrimMode) {
        if mode == .ripple { rippleTrimToPlayhead(edge); return }
        let at = playhead
        let side = edge == .head ? "Previous" : "Next"
        let name = mode == .roll ? "Roll Trim \(side) Edit" : "Trim \(side) Edit"
        attempt(name) { _ = try $0.trimToPlayhead(edge, at: at, tracks: nil, mode: mode) }
    }

    /// Shift+Cmd+/: copies the selected clips right after the selection; the copies become the selection.
    public func duplicateSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        var made: [Clip.ID] = []
        if attempt("Duplicate", { made = try $0.duplicate(ids) }) { select(clips: Set(made)) }
    }

    /// Shift+Cmd+E: disables the selected clips (and their linked partners), or enables them when one is disabled.
    public func toggleEnabledSelection() {
        guard !selection.isEmpty, let t = activeTimeline else { return }
        let ids = selection
        let anyOff = t.tracks.flatMap(\.clips).contains { ids.contains($0.id) && !$0.isEnabled }
        attempt(anyOff ? "Enable Clip" : "Disable Clip") { _ = try $0.toggleEnabled(ids) }
    }

    /// Opt+Up / Opt+Down: moves the selected clips one track. Returns false when the outermost lane blocks it.
    @discardableResult
    public func moveSelectionLane(up: Bool) -> Bool {
        guard !selection.isEmpty else { return false }
        let ids = selection
        var moved = false
        attempt(up ? "Move Clip Up" : "Move Clip Down") { moved = try $0.moveToLane(ids, up: up) }
        return moved
    }

    /// Ruler drag of a marker flag (one step per drag).
    public func moveMarker(_ id: Marker.ID, to time: Time) {
        attempt("Move Marker") { $0.moveMarker(id, to: time) }
    }

    /// Click on a track target button with Shift / Option.
    public func toggleTarget(_ id: Track.ID, shift: Bool, option: Bool) {
        attempt("Toggle Track Target") { $0.toggleTarget(id, shift: shift, option: option) }
    }
}
