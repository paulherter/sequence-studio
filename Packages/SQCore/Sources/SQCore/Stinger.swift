import Foundation

// N6b Stinger transition, project side: picking a Library clip and the file version gate (v38).

extension Project {
    /// Makes cut transition `id` a Stinger playing media `media`: the transition takes the clip's length (whole frames)
    /// and its picture is scaled to fit the sequence frame. Throws `.clipNotFound` for unknown media or transition,
    /// `.wrongTrackKind` for media without a picture, `.timelineNotFound`, `.trackLocked`, `.notACut`.
    public mutating func setStinger(transition id: Transition.ID, media: MediaRef.ID, cutFraction: Double,
                                    in timeline: Timeline.ID) throws {
        guard let m = self.media(media) else { throw EditError.clipNotFound }
        if let info = m.info, info.video == nil { throw EditError.wrongTrackKind }
        try edit(timeline) { t in
            let fd = t.format.frameDuration
            let scale = m.info?.video.map { t.format.fitScale(width: $0.displayWidth, height: $0.displayHeight) }
            try t.setStinger(id, TransitionStinger(media: media, cutFraction: cutFraction, scale: scale))
            if let d = m.info?.duration ?? m.duration, d > .zero {
                try t.setTransition(id, duration: fd * max(1, d.frameIndex(frameDuration: fd)))
            }
        }
    }

    /// Any timeline holds a Stinger transition (kind or clip): the file must be v38.
    public var containsStinger: Bool {
        timelines.contains { $0.tracks.contains { $0.transitions.contains { $0.kind.isStinger || $0.stinger != nil } } }
    }
}
