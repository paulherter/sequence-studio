import Foundation

/// Source patching (Premiere's source track buttons) is separate from track targeting. Patches (`Track.isSourcePatched`)
/// decide where Insert / Overwrite from the Source monitor lands (`sourceEditTargets`). Targets (`Track.isTargeted`) keep
/// deciding paste, add edit, navigation and match frame. The first patched video track receives the source's video, the
/// first patched audio track its audio.
extension Timeline {
    /// Click on a track's source-patch button. Same modifier rules as `toggleTarget`: plain click flips that track,
    /// Shift-click sets every track of the kind to the state the clicked one is switching to, Option-click patches only
    /// that track of its kind.
    public mutating func togglePatch(_ id: Track.ID, shift: Bool = false, option: Bool = false) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let kind = tracks[i].kind
        if option {
            for j in tracks.indices where tracks[j].kind == kind { tracks[j].isSourcePatched = j == i }
        } else if shift {
            let on = !tracks[i].isSourcePatched
            for j in tracks.indices where tracks[j].kind == kind { tracks[j].isSourcePatched = on }
        } else {
            tracks[i].isSourcePatched.toggle()
        }
    }

    /// Patched tracks of `kind`, bottom to top as stored.
    public func patchedTracks(_ kind: TrackKind) -> [Track.ID] {
        tracks.filter { $0.kind == kind && $0.isSourcePatched }.map(\.id)
    }

    /// Sets every patch to the track's current target state (what an older file gets on open).
    public mutating func resetPatchesToTargets() {
        for i in tracks.indices { tracks[i].isSourcePatched = tracks[i].isTargeted }
    }
}
