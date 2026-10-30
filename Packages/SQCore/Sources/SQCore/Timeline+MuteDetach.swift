import Foundation

extension Timeline {
    /// Mute of the audio tracks that hold the given clips or their linked partners (same reach as `toggleSolo`). All of
    /// them already muted: Mute goes off for them; otherwise it goes on. Returns the new state, nil when no audio track
    /// was involved.
    @discardableResult
    public mutating func toggleMute(forClips ids: Set<Clip.ID>) -> Bool? {
        let links = Set(tracks.flatMap(\.clips).filter { ids.contains($0.id) }.compactMap(\.link))
        var touched: [Int] = []
        for (i, t) in tracks.enumerated() where t.kind == .audio {
            if t.clips.contains(where: { ids.contains($0.id) || ($0.link.map(links.contains) ?? false) }) { touched.append(i) }
        }
        guard !touched.isEmpty else { return nil }
        let on = !touched.allSatisfy { tracks[$0].isMuted }
        for i in touched { tracks[i].isMuted = on }
        return on
    }

    /// Detach Audio: the audio clips linked to the given video clips lose their link and become independent clips that
    /// stay where they are on the audio track. Returns the detached audio clip IDs (empty when nothing was linked).
    /// Throws when an affected track is locked; the timeline is unchanged then.
    @discardableResult
    public mutating func detachAudio(of ids: Set<Clip.ID>) throws -> [Clip.ID] {
        var videoLinks = Set<UUID>()
        for t in tracks where t.kind == .video {
            for c in t.clips where ids.contains(c.id) { if let l = c.link { videoLinks.insert(l) } }
        }
        guard !videoLinks.isEmpty else { return [] }
        var audio: [Clip.ID] = []
        for t in tracks where t.kind == .audio {
            for c in t.clips { if let l = c.link, videoLinks.contains(l) { audio.append(c.id) } }
        }
        guard !audio.isEmpty else { return [] }
        var copy = self
        try copy.unlink(Set(audio))
        self = copy
        return audio
    }
}
