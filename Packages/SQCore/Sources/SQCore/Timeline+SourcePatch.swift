import Foundation

// Source patching (MON-30 / TL-44). Where Insert / Overwrite put the Source view's video and audio is decided by the
// patch, not by track targeting: targeting stays for paste, match frame and the playhead edits (Cmd+K, Up/Down, X).
// The patch is stored per sequence (v88, `Timeline.sourcePatch`) and changes are undo steps; the timeline resolves it.

/// Where one source stream (video or audio) goes.
public struct SourcePatchSlot: Sendable, Hashable, Codable {
    /// The patched track; nil means the first track of the kind (V1 / A1). A track that no longer exists falls back too.
    public var track: Track.ID?
    /// Off: this stream is not placed (b-roll video without its audio).
    public var isConnected: Bool

    public init(track: Track.ID? = nil, isConnected: Bool = true) {
        self.track = track
        self.isConnected = isConnected
    }
}

extension SourcePatchSlot {
    fileprivate func withConnected() -> SourcePatchSlot { SourcePatchSlot(track: track, isConnected: true) }
}

/// The source patch of one sequence: a slot for the source video and one for the source audio.
public struct SourcePatch: Sendable, Hashable, Codable {
    public var video: SourcePatchSlot
    public var audio: SourcePatchSlot

    public init(video: SourcePatchSlot = SourcePatchSlot(), audio: SourcePatchSlot = SourcePatchSlot()) {
        self.video = video
        self.audio = audio
    }

    public subscript(kind: TrackKind) -> SourcePatchSlot {
        get { kind == .video ? video : audio }
        set { if kind == .video { video = newValue } else { audio = newValue } }
    }

    /// Click on a patch chip: disconnect, or connect again to the same track.
    public mutating func toggleConnection(_ kind: TrackKind) { self[kind].isConnected.toggle() }

    /// Chip dragged onto a track: patched there and connected. A track of the other kind (or unknown) changes nothing.
    public mutating func patch(_ kind: TrackKind, to id: Track.ID, in timeline: Timeline) {
        guard timeline.track(id)?.kind == kind else { return }
        self[kind] = SourcePatchSlot(track: id, isConnected: true)
    }

    /// Option+click on a chip: only this stream stays connected (solo); clicking it again connects both.
    public mutating func solo(_ kind: TrackKind) {
        let other: TrackKind = kind == .video ? .audio : .video
        if self[kind].isConnected && !self[other].isConnected {
            self[other].isConnected = true
        } else {
            self[kind].isConnected = true
            self[other].isConnected = false
        }
    }

    /// Shift+drag of a chip: `kind` goes to `id` and the other stream moves by the same number of tracks of its kind
    /// (clamped to the first / last track), so the pair keeps its distance. Connection states stay as they are, except
    /// that the dragged stream connects.
    public mutating func patchBoth(_ kind: TrackKind, to id: Track.ID, in timeline: Timeline) {
        guard timeline.track(id)?.kind == kind else { return }
        let other: TrackKind = kind == .video ? .audio : .video
        let mine = timeline.tracks.filter { $0.kind == kind }, theirs = timeline.tracks.filter { $0.kind == other }
        let from = timeline.patchedTrack(SourcePatch(video: self.video.withConnected(), audio: self.audio.withConnected()), kind: kind)
        let otherNow = timeline.patchedTrack(SourcePatch(video: self.video.withConnected(), audio: self.audio.withConnected()), kind: other)
        if let fi = mine.firstIndex(where: { $0.id == from }), let ti = mine.firstIndex(where: { $0.id == id }),
           let oi = theirs.firstIndex(where: { $0.id == otherNow }), !theirs.isEmpty {
            let ni = min(max(oi + (ti - fi), 0), theirs.count - 1)
            self[other].track = theirs[ni].id
        }
        self[kind].track = id
        self[kind].isConnected = true
    }
}

extension Timeline {
    /// This sequence's source patch (default: video to V1, audio to A1, both connected). Saved with the project (v88);
    /// the default stores nothing, so untouched sequences encode as before.
    /// A slot whose track no longer exists (deleted) reads as the default track, so a stale ID never keeps the file at v88.
    public var sourcePatch: SourcePatch {
        get {
            guard var p = sourcePatchStore else { return SourcePatch() }
            for kind in [TrackKind.video, .audio] {
                if let id = p[kind].track, track(id)?.kind != kind { p[kind].track = nil }
            }
            return p
        }
        set { sourcePatchStore = newValue == SourcePatch() ? nil : newValue }
    }

    /// After tracks were copied with new ids (`map`: old -> new): the patch follows its tracks; one not copied falls back.
    mutating func remapSourcePatch(trackIDs map: [Track.ID: Track.ID]) {
        guard var p = sourcePatchStore else { return }
        for kind in [TrackKind.video, .audio] { p[kind].track = p[kind].track.flatMap { map[$0] } }
        sourcePatch = p
    }

    /// The track a slot points at: its own track while it exists (and is of the kind), else the first track of the kind.
    /// nil when the slot is disconnected or the sequence has no track of that kind.
    public func patchedTrack(_ patch: SourcePatch, kind: TrackKind) -> Track.ID? {
        let slot = patch[kind]
        guard slot.isConnected else { return nil }
        if let id = slot.track, track(id)?.kind == kind { return id }
        return tracks.first { $0.kind == kind }?.id
    }

    /// Destination tracks of a Source Insert / Overwrite: the patched video track, then the patched audio track. Audio
    /// patched by default into a sequence without audio tracks creates A1 (same undo step as the edit). A stream that is
    /// disconnected, not offered by the media or not chosen in `streams` is left out. nil when nothing is left to place.
    public mutating func sourcePatchTargets(_ patch: SourcePatch, hasVideo: Bool, hasAudio: Bool,
                                            streams: SourceStreams = .both) -> [Track.ID]? {
        var out: [Track.ID] = []
        if hasVideo, streams.includesVideo, let v = patchedTrack(patch, kind: .video) { out.append(v) }
        if hasAudio, streams.includesAudio, patch.audio.isConnected {
            if let a = patchedTrack(patch, kind: .audio) { out.append(a) } else { out.append(ensureAudioTrack(atOrdinal: 0)) }
        }
        return out.isEmpty ? nil : out
    }
}
