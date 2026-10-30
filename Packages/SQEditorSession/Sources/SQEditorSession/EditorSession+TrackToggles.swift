import SQCore

extension EditorSession {
    /// Track header toggle (visible, mute, solo, lock, sync lock, target). `allOfKind`: every track of the clicked
    /// track's kind takes the clicked track's new value, in one undo step.
    public func toggleTracks(of id: Track.ID, _ toggle: TrackToggle, allOfKind: Bool) {
        guard let track = activeTimeline?.track(id) else { return }
        let current: Bool
        switch toggle {
        case .visible: current = track.isVisible
        case .mute: current = track.isMuted
        case .solo: current = track.isSolo
        case .lock: current = track.isLocked
        case .target: current = track.isTargeted
        case .syncLock: current = track.syncLock
        }
        let on = !current
        let kind = track.kind
        let name = TrackToggleNames.name(toggle, turningOn: on, plural: allOfKind)
        attempt(name) { t in
            for i in t.tracks.indices where t.tracks[i].id == id || (allOfKind && t.tracks[i].kind == kind) {
                switch toggle {
                case .visible: t.tracks[i].isVisible = on
                case .mute: t.tracks[i].isMuted = on
                case .solo: t.tracks[i].isSolo = on
                case .lock: t.tracks[i].isLocked = on
                case .target: t.tracks[i].isTargeted = on
                case .syncLock: t.tracks[i].syncLock = on
                }
            }
        }
    }
}
