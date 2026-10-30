import Foundation

extension Clip {
    /// What the timeline draws for a piece of an Angles clip: the piece as if it were a plain media clip of the active
    /// angle (that angle's media, and the stretch of its file the piece plays), so thumbnails and waveforms show the angle
    /// that plays. `inner` is the Angles sequence. nil = not an Angles piece, or the active angle has no single plain
    /// clip under the whole piece (the caller draws it flat).
    /// shortcut: one clip of the active angle must cover the piece at normal speed; a piece over a cut or retimed angle
    /// clip draws flat. Upgrade when angle tracks are edited after creation.
    public func angleProxy(inner: Timeline) -> Clip? {
        guard isAnglesClip, speed == .normal, !reversed, speedKeys == nil, holdFrame == nil else { return nil }
        let shown = angleView(of: inner)
        let last = max(source.start, source.end - Time(1, source.start.timescale))
        for track in shown.tracks where track.kind == kind {
            guard let ic = track.clips.first(where: { $0.timeline.contains(source.start) }) else { continue }
            guard ic.timeline.contains(last), ic.sequence == nil, ic.generator == nil, !ic.isStill, ic.speed == .normal,
                  !ic.reversed, ic.speedKeys == nil, ic.holdFrame == nil else { return nil }
            var p = self
            p.media = ic.media
            p.sequence = nil
            p.angle = nil
            p.source = TimeRange(start: ic.source.start + (source.start - ic.start), duration: source.duration)
            p.mediaDuration = ic.mediaDuration
            return p
        }
        return nil
    }
}

extension Timeline {
    /// For the multi-angle view: what each angle (video track, bottom first) shows at `t` of this Angles sequence, as its
    /// media and the time in that file. nil = the angle has no picture there.
    public func angleFrames(at t: Time, frameDuration: Time) -> [(media: UUID, time: Time)?] {
        tracks.filter { $0.kind == .video }.map { track in
            guard let c = track.clips.first(where: { $0.isEnabled && $0.timeline.contains(t) && $0.sequence == nil && $0.generator == nil })
            else { return nil }
            return (c.media, c.sourceTime(at: t, frameDuration: frameDuration))
        }
    }
}

extension Clip {
    /// The time in the Angles sequence that the piece shows at timeline time `t` (pieces play at normal speed).
    public func angleInnerTime(at t: Time) -> Time { source.start + (t - start) }
}
