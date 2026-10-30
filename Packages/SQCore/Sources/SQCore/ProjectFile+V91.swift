import Foundation

// v91: Snapping and Linked Selection are saved per sequence (`Timeline.snappingOn`, `linkedSelectionOn`) and changed by
// undoable steps. Both default to on and are stored only when off, so a file where both are on keeps the lowest version
// that holds its content (byte-identical). A v90 build would forget the toggles on the next save; at v91 it refuses the
// file with `ProjectFileError.newerVersion`. Identity step: both keys are optional on decode.

extension Project {
    /// Any sequence has Snapping or Linked Selection switched off: the file must be v91.
    public var containsV91Content: Bool { timelines.contains { !$0.snappingOn || !$0.linkedSelectionOn } }
}

extension Timeline {
    /// Snapping of this sequence (default on; saved from v91 only when off).
    public var snappingOn: Bool {
        get { snappingOffStore != true }
        set { snappingOffStore = newValue ? nil : true }
    }

    /// Linked Selection of this sequence (default on; saved from v91 only when off).
    public var linkedSelectionOn: Bool {
        get { linkedSelectionOffStore != true }
        set { linkedSelectionOffStore = newValue ? nil : true }
    }

    /// Delete Track (Sequence menu, key): removes the targeted tracks with their clips in one mutation (one undo step).
    /// Locked tracks are refused; the lowest track of each kind and a Fast Cut main track stay (a sequence always keeps
    /// one video and one audio track). Throws `trackLocked` when a targeted track is locked, `noTrackToDelete` when
    /// nothing is left to remove. Returns the removed IDs.
    @discardableResult
    public mutating func deleteTargetedTracks() throws -> [Track.ID] {
        var keep = Set<Track.ID>()
        for kind in [TrackKind.video, .audio] { if let t = tracks.first(where: { $0.kind == kind }) { keep.insert(t.id) } }
        if let m = mainTrackID { keep.insert(m) }
        let targeted = tracks.filter { $0.isTargeted && !keep.contains($0.id) }
        guard !targeted.isEmpty else { throw EditError.noTrackToDelete }
        if targeted.contains(where: \.isLocked) { throw EditError.trackLocked }
        for t in targeted { try removeTrack(t.id) }
        return targeted.map(\.id)
    }
}
