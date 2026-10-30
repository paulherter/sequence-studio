import Foundation
import SQCore

/// Commands the Final Cut key import and the menus needed without a default key: Play from Start, Toggle All Targets,
/// Select Left / Right Edge, Edit Marker, Add and Edit Marker.
extension EditorSession {
    // MARK: Play from Start

    /// The playhead goes to the sequence start and plays forward (a running playback restarts from there).
    public func playFromStart() {
        guard activeTimeline != nil else { return }
        if isPlaying { stopPlayback() }
        seek(to: .zero)
        apply(shuttle: .setRate(.forward))
    }

    // MARK: Targets

    /// Toggle All Targets: every track of the sequence is targeted, or, when all already are, none (one undo step).
    public var canToggleAllTargets: Bool { !(activeTimeline?.tracks.isEmpty ?? true) }

    /// The state the next Toggle All Targets sets: true = all on.
    public var toggleAllTargetsTurnsOn: Bool { activeTimeline?.tracks.contains { !$0.isTargeted } ?? false }

    @discardableResult
    public func toggleAllTargets() -> Bool {
        guard canToggleAllTargets else { return false }
        let on = toggleAllTargetsTurnsOn
        attempt(TrackToggleNames.targetAll) { t in for i in t.tracks.indices { t.tracks[i].isTargeted = on } }
        return true
    }

    /// Toggle Video / Audio Targets: the same for the tracks of one kind (one undo step). False when there is none.
    public func canToggleTargets(of kind: TrackKind) -> Bool { activeTimeline?.tracks.contains { $0.kind == kind } ?? false }

    @discardableResult
    public func toggleTargets(of kind: TrackKind) -> Bool {
        guard let t = activeTimeline, canToggleTargets(of: kind) else { return false }
        let on = t.tracks.contains { $0.kind == kind && !$0.isTargeted }
        attempt(TrackToggleNames.targetAll) { t in for i in t.tracks.indices where t.tracks[i].kind == kind { t.tracks[i].isTargeted = on } }
        return true
    }

    /// Target track N (1-based) of a kind by key: toggles that track's target. False when the sequence has no such track.
    private func nthTrack(_ kind: TrackKind, _ n: Int) -> Track? {
        guard n >= 1, let t = activeTimeline else { return nil }
        let ofKind = t.tracks.filter { $0.kind == kind }
        return n <= ofKind.count ? ofKind[n - 1] : nil
    }

    public func canToggleTrackTarget(_ kind: TrackKind, _ n: Int) -> Bool { nthTrack(kind, n) != nil }

    @discardableResult
    public func toggleTrackTarget(_ kind: TrackKind, _ n: Int) -> Bool {
        guard let track = nthTrack(kind, n) else { return false }
        toggleTracks(of: track.id, .target, allOfKind: false)
        return true
    }

    /// Lock / unlock the targeted tracks: all become locked unless they already are, then all unlock (one undo step).
    public var canToggleLockOfTargets: Bool { activeTimeline?.tracks.contains(where: \.isTargeted) ?? false }

    @discardableResult
    public func toggleLockOfTargets() -> Bool {
        guard let t = activeTimeline, canToggleLockOfTargets else { return false }
        let on = t.tracks.contains { $0.isTargeted && !$0.isLocked }
        attempt(on ? "Lock Tracks" : "Unlock Tracks") { t in
            for i in t.tracks.indices where t.tracks[i].isTargeted { t.tracks[i].isLocked = on }
        }
        return true
    }

    // MARK: Edge selection

    /// Select Left / Right Edge: the head (tail) edges of the selected clips as an edge selection for the trim keys.
    /// nil when no clip is selected. Not rippling: the Trim keys then behave like the Selection tool's edge drag.
    public func edgeSelectionOfSelection(_ edge: ClipEdge) -> EdgeSelection? {
        guard let t = activeTimeline, !selection.isEmpty else { return nil }
        let ids = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }.map(\.id)
        guard !ids.isEmpty else { return nil }
        return EdgeSelection(edges: ids.map { EdgeRef(clip: $0, edge: edge) })
    }

    public var canSelectEdgeOfSelection: Bool { edgeSelectionOfSelection(.head) != nil }

    // MARK: Markers

    /// The marker the Edit Marker command opens: one on the playhead frame, else a range marker that covers it.
    public func markerAtPlayhead() -> Marker.ID? {
        guard let t = activeTimeline else { return nil }
        if let m = t.markers.first(where: { $0.time == playhead }) { return m.id }
        return t.markers.first { $0.duration > .zero && $0.time <= playhead && playhead < $0.time + $0.duration }?.id
    }

    public var canEditMarkerAtPlayhead: Bool { markerAtPlayhead() != nil }
}
