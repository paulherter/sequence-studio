import Foundation

extension Project {
    /// Replace edit with a sequence (Option-drop of a sequence onto a clip): the clip plays `sequence` as a nested clip
    /// instead, keeping position, timeline length, track, link, speed, effects and keys. The linked partner of the other
    /// kind follows when the sequence has that stream. The sequence plays from its start for the clip's source length.
    /// Throws `.nestingCycle` (the sequence is or contains the host), `.insufficientMedia` (the sequence is shorter than
    /// the played range), `.wrongTrackKind` (an audio clip and a sequence without audio), `.speedUnsupported` (stills,
    /// held frames, speed-remapped clips, generators), `.trackLocked`, `.clipNotFound`. Nothing changes on a refusal.
    public mutating func replaceWithSequence(of clipID: Clip.ID, with sequence: Timeline.ID, in host: Timeline.ID) throws {
        guard let hi = timelines.firstIndex(where: { $0.id == host }), let seq = timeline(sequence) else {
            throw EditError.timelineNotFound
        }
        if wouldCreateCycle(nesting: sequence, in: host) { throw EditError.nestingCycle }
        let tl = timelines[hi]
        guard let ti = tl.tracks.firstIndex(where: { $0.clip(clipID) != nil }), let old = tl.tracks[ti].clip(clipID) else {
            throw EditError.clipNotFound
        }
        guard !tl.tracks[ti].isLocked else { throw EditError.trackLocked }
        guard !old.isGenerator, !old.isStill, old.holdFrame == nil, old.speedKeys == nil else { throw EditError.speedUnsupported }
        guard let make = sequenceClips(of: sequence, at: .zero) else { throw EditError.emptyClip }
        guard let len = nestedLength(of: sequence, hostFrameDuration: tl.frameDuration), seq.duration > .zero else {
            throw EditError.emptyClip
        }
        guard let proto = make.first(where: { $0.kind == old.kind }) else { throw EditError.wrongTrackKind }
        guard old.source.duration <= len else { throw EditError.insufficientMedia }

        func swap(_ c: Clip, with p: Clip) -> Clip {
            var n = c
            n.media = p.media; n.sequence = p.sequence; n.name = p.name; n.mediaDuration = p.mediaDuration
            n.angle = p.angle
            n.source.start = .zero
            n.footageColor = ClipFootageColor()
            n.markers = nil
            return n
        }
        var work = tl
        work.tracks[ti].replace(swap(old, with: proto))
        if let link = old.link {
            for pi in work.tracks.indices where pi != ti {
                guard let p = work.tracks[pi].clips.first(where: { $0.link == link && $0.kind != old.kind }),
                      let pp = make.first(where: { $0.kind == p.kind }) else { continue }
                guard !work.tracks[pi].isLocked else { throw EditError.trackLocked }
                guard p.source.duration <= len else { throw EditError.insufficientMedia }
                work.tracks[pi].replace(swap(p, with: pp))
            }
        }
        try edit(host) { $0 = work }
    }
}
