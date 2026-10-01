import Foundation

extension Timeline {
    /// Click on a track's target button. Plain click flips that track. Shift-click sets every track of the same kind to
    /// the state the clicked one is switching to. Option-click targets only that track of its kind (the others of the
    /// kind go off); on the only targeted track it does nothing. Locked tracks may still be (un)targeted.
    public mutating func toggleTarget(_ id: Track.ID, shift: Bool = false, option: Bool = false) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let kind = tracks[i].kind
        if option {
            for j in tracks.indices where tracks[j].kind == kind { tracks[j].isTargeted = j == i }
        } else if shift {
            let on = !tracks[i].isTargeted
            for j in tracks.indices where tracks[j].kind == kind { tracks[j].isTargeted = on }
        } else {
            tracks[i].isTargeted.toggle()
        }
    }
}
