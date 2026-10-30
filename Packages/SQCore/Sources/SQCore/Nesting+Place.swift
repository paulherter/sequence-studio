import Foundation

/// Placing whole sequences into another sequence (Project panel drag, Insert / Overwrite): each becomes a nested clip.
extension Project {
    /// Length of `sequence` as a nested clip in a host with `frameDuration`: whole host frames (nearest, at least one),
    /// never longer than the sequence itself (a 30 fps sequence of 10 s plays 10 s in a 25 fps host).
    public func nestedLength(of sequence: Timeline.ID, hostFrameDuration fd: Time) -> Time? {
        guard let t = timeline(sequence), t.duration > .zero else { return nil }
        var d = t.duration.snapped(to: fd)
        if d > t.duration { d = fd * max(1, t.duration.frameIndex(frameDuration: fd)) }
        return d > .zero ? d : fd
    }

    /// Places `ids` one after another at `time` in `host` (a video clip and, when the sequence has audio, a linked audio
    /// clip each). Drop rule for tracks like media (`Timeline.dropTargets`): V2 -> A2, missing audio tracks are created;
    /// `newTrack` creates a track of that kind first (audio ghost: audio only). One edit: a refusal changes nothing.
    /// Throws `.nestingCycle` when a sequence is the host or contains it (transitively), `.timelineNotFound` for an unknown
    /// host, `.emptyClip` for an unknown or empty sequence. Returns the end of the last placed clip.
    @discardableResult
    public mutating func placeSequences(_ ids: [Timeline.ID], in host: Timeline.ID, at time: Time, videoTrack: Track.ID? = nil,
                                        newTrack: TrackKind? = nil, mode: ThreePointMode) throws -> Time {
        guard timeline(host) != nil else { throw EditError.timelineNotFound }
        guard !ids.isEmpty else { throw EditError.emptyClip }
        for id in ids {
            guard timeline(id) != nil else { throw EditError.emptyClip }
            if wouldCreateCycle(nesting: id, in: host) { throw EditError.nestingCycle }
        }
        var end = time
        let snapshot = self
        try edit(host) { tl in
            let fd = tl.frameDuration
            var at = time.snapped(to: fd)
            var pointer = videoTrack
            var audioOnly = false
            if let kind = newTrack { pointer = tl.addTrack(kind: kind); audioOnly = kind == .audio }
            for id in ids {
                guard var clips = snapshot.sequenceClips(of: id, at: .zero),
                      let len = snapshot.nestedLength(of: id, hostFrameDuration: fd) else { throw EditError.emptyClip }
                if audioOnly { clips = clips.filter { $0.kind == .audio } }
                guard !clips.isEmpty else { throw EditError.emptyClip }
                let hasVideo = clips.contains { $0.kind == .video }, hasAudio = clips.contains { $0.kind == .audio }
                var targets: [Track.ID] = []
                let d = tl.dropTargets(pointer: pointer, hasVideo: hasVideo, hasAudio: hasAudio)
                if let v = d.video { targets.append(v) }
                if let a = d.audio { targets.append(a) } else if let n = d.newAudioOrdinal { targets.append(tl.ensureAudioTrack(atOrdinal: n)) }
                var placements: [(clip: Clip, track: Track.ID)] = []
                for var c in clips {
                    c.source = TimeRange(start: .zero, duration: len)
                    guard let tid = targets.first(where: { tl.track($0)?.kind == c.kind }) else { throw EditError.clipNotFound }
                    placements.append((c, tid))
                }
                let place = at
                let run: (inout Timeline) throws -> Void = { t in
                    if mode == .insert { try t.insert(placements, at: place) } else { try t.overwrite(placements, at: place) }
                }
                // Fast Cut: onto the main track or attached off it, like any source edit (`fastCutSourceEdit`).
                if tl.isFastCut { try tl.fastCutSourceEdit(placements, at: place, mode: mode) } else { try run(&tl) }
                at = (at + len).snapped(to: fd)
            }
            end = at
        }
        return end
    }
}
