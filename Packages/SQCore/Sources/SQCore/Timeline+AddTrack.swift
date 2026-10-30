import Foundation

extension Timeline {
    /// Appends a track of `kind`: a new top video track (V n+1) or a new bottom audio track (A n+1). The first track of
    /// its kind becomes the edit target. This is what dropping onto a ghost track does.
    @discardableResult
    public mutating func addTrack(kind: TrackKind) -> Track.ID {
        let t = Track(kind: kind, isTargeted: !tracks.contains { $0.kind == kind })
        tracks.append(t)
        return t.id
    }
}
