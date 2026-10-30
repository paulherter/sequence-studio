import Foundation

/// Audit C18: one audio role. A clip's role is its own tag (`Clip.audioTag`, Clip > Audio Options > Tag), else the role of the
/// track it sits on (`Track.audioRole`). Live Ducking, Bake Live Duck to Keys (Auto Duck) and Match Loudness read this; nothing
/// is stored. Voice Chain stays on the track role: it is the track bus's effect chain, which a single clip cannot pick.
extension Track {
    /// `clip.audioTag ?? audioRole` (the clip is assumed to sit on this track).
    public func role(of clip: Clip) -> AudioTag? { clip.audioTag ?? audioRole }
}

extension Timeline {
    /// The clip's tag, else the role of the track holding it (by id); a clip not in this sequence has only its tag.
    public func role(of clip: Clip) -> AudioTag? {
        if let tag = clip.audioTag { return tag }
        return tracks.first { $0.clips.contains { $0.id == clip.id } }?.audioRole
    }
}
