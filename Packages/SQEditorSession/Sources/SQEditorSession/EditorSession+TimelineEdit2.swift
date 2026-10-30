import Foundation
import SQCore

/// Round 2 timeline verbs: Q/W variants, Duplicate, Enable/Disable, lane moves, marker drag, target modifiers.
/// One undo step per call.
extension EditorSession {
    /// Q / W with Shift (rolling) or Option (plain trim, gap stays). `.ripple` is `rippleTrimToPlayhead`. Fast Cut: V1
    /// never keeps a gap (`magneticTrimToPlayhead`: Option ripples V1, attached clips under the playhead trim in place).
    public func trimToPlayhead(_ edge: ClipEdge, mode: PlayheadTrimMode) {
        if mode == .ripple { rippleTrimToPlayhead(edge); return }
        let at = editPoint
        let side = edge == .head ? "Previous" : "Next"
        let name = mode == .roll ? "Roll Trim \(side) Edit" : "Trim \(side) Edit"
        let keep = keepAttachedHeld
        attempt(name) { tl in
            let ids = Self.playheadTrimTracks(in: tl)
            if tl.isFastCut { _ = try tl.magneticTrimToPlayhead(edge, at: at, mode: mode, keepAttached: keep) }
            else { _ = try tl.trimToPlayhead(edge, at: at, tracks: ids, mode: mode) }
        }
    }

    /// Tracks Q / W (and their Shift / Option variants) act on: unlocked and enabled (a hidden video track or a muted
    /// audio track is skipped, so an edge trim never changes a track the editor switched off). `nil` when that is every
    /// unlocked track (the core default), or when nothing is enabled (so the verb still reports what it always did).
    static func playheadTrimTracks(in t: Timeline) -> [Track.ID]? {
        let unlocked = t.tracks.filter { !$0.isLocked }
        let enabled = unlocked.filter { $0.kind == .video ? $0.isVisible : !$0.isMuted }
        guard !enabled.isEmpty, enabled.count != unlocked.count else { return nil }
        return enabled.map(\.id)
    }

    /// Shift+Cmd+/: copies the selected clips right after the selection; the copies become the selection. Fast Cut: main
    /// clips are inserted after the last selected main clip with their attached clips (`magneticDuplicate`).
    public func duplicateSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        var made: [Clip.ID] = []
        if attempt("Duplicate", { made = try $0.magneticDuplicate(ids) }) { select(clips: Set(made)) }
    }

    /// Shift+Cmd+E: disables the selected clips (and their linked partners), or enables them when one is disabled.
    public func toggleEnabledSelection() {
        guard !selection.isEmpty, let t = activeTimeline else { return }
        let ids = selection
        // The name follows what the toggle really does to the linked group.
        var probe = t
        let enabling = (try? probe.toggleEnabled(ids)) ?? false
        attempt(enabling ? "Enable Clip" : "Disable Clip") { _ = try $0.toggleEnabled(ids) }
    }

    /// Selected clips when they are all Adjustment Layers; empty for any other selection (Extend to Sequence End targets).
    public var selectedAdjustmentLayers: [Clip] {
        guard let t = activeTimeline else { return [] }
        let clips = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        return !clips.isEmpty && clips.allSatisfy(\.isAdjustment) ? clips : []
    }

    /// Check state of Clip > Extend to Sequence End: every selected layer carries the flag.
    public var selectionExtendsToSequenceEnd: Bool {
        let l = selectedAdjustmentLayers
        return !l.isEmpty && l.allSatisfy(\.extendsToSequenceEnd)
    }

    /// Clip > Extend to Sequence End: switches the flag for the selected Adjustment Layers (off when all were on, else on).
    /// One undo step; the layers are extended inside it.
    public func toggleExtendToSequenceEndSelection() {
        let layers = selectedAdjustmentLayers
        guard !layers.isEmpty else { return }
        let on = !selectionExtendsToSequenceEnd
        let ids = layers.map(\.id)
        perform(on ? "Extend to Sequence End" : "Stop Extending to Sequence End") { p in
            for id in ids { p.setExtendToSequenceEnd(on, clip: id) }
        }
    }

    /// Opt+Up / Opt+Down: moves the selected clips one track. Returns false when the outermost lane blocks it. Fast Cut
    /// (`magneticMoveToLane`): main-track clips going up are lifted off the main track (a spacer stays); attached video
    /// clips right above V1 going down are put on the main track (partners stay); other clips change lane and re-attach.
    @discardableResult
    public func moveSelectionLane(up: Bool) -> Bool {
        guard !selection.isEmpty, let t = activeTimeline else { return false }
        let ids = selection
        var moved = false
        let name = !t.isFastCut ? (up ? "Move Clip Up" : "Move Clip Down")
            : ids.contains(where: t.isOnMainTrack) ? "Lift off Main Track"
            : up ? "Move Clip Up" : "Move Clip Down"
        attempt(name) { tl in moved = try tl.magneticMoveToLane(ids, up: up) }
        return moved
    }

    /// Ruler drag of a marker flag (one step per drag).
    public func moveMarker(_ id: Marker.ID, to time: Time) {
        attempt("Move Marker") { $0.moveMarker(id, to: time) }
    }

    /// Click on a track target button with Shift / Option.
    public func toggleTarget(_ id: Track.ID, shift: Bool, option: Bool) {
        attempt(TrackToggleNames.targetAll) { $0.toggleTarget(id, shift: shift, option: option) }
    }
}

extension Timeline {
    /// Status-line tail for a limited ripple ("limited by clip on V3"); nil when the edit was applied in full.
    /// Callers prefix the verb: "Trim limited by clip on V3".
    func clampMessage(_ outcome: EditOutcome) -> String? { outcome.clampReason.map(describe) }
}
