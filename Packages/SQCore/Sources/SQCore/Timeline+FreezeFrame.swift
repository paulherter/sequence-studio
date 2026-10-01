import Foundation

extension Clip {
    /// Static copy of the raw animation values at timeline time `t` (the stored values, whatever the fx toggles say).
    func frozenAnimation(at t: Time) -> ClipAnimation {
        var a = animation
        let l = t - start
        a.position = AnimatedProperty(animation.position.value(atLocal: l))
        a.scale = AnimatedProperty(animation.scale.value(atLocal: l))
        a.rotation = AnimatedProperty(animation.rotation.value(atLocal: l))
        a.opacity = AnimatedProperty(animation.opacity.value(atLocal: l))
        a.anchor = AnimatedProperty(animation.anchor.value(atLocal: l))
        return a
    }

    /// A held clip: shows source frame `frame` for `duration` from `start`. Like Premiere's Frame Hold (Hold Filters off) it
    /// freezes the picture only: Motion, Opacity and effect keys keep animating, so a Fade Out at the tail survives. Keys
    /// stay on the same timeline frames (`keepsAnimation`). An inserted segment (`keepsAnimation` false) is a pause in
    /// time, so it shows the values of the original at `t` as static ones. The fx toggles and the blend mode are kept.
    func holding(frame: Time, at t: Time, start newStart: Time, duration: Time, keepsAnimation: Bool) -> Clip {
        var h = self
        h.id = UUID()
        h.link = nil
        h.start = newStart
        h.source = TimeRange(start: frame, duration: duration)
        h.speed = .normal
        h.speedKeys = nil
        h.reversed = false
        h.holdFrame = frame
        if keepsAnimation {
            h.animation = animation.shifted(by: start - newStart)
            h.effects = effects.map { $0.shifted(by: start - newStart) }
        } else {
            h.animation = frozenAnimation(at: t)
            h.effects = effects.map { e in
                var f = e
                f.parameters = e.parameters.mapValues { AnimatedProperty($0.value(atLocal: t - self.start)) }
                return f
            }
        }
        return h
    }
}

extension Timeline {
    /// The video clip a frame hold works on: `clipID` when given, else the topmost video clip under `t`.
    private func holdTarget(_ clipID: Clip.ID?, at t: Time) throws -> Member {
        if let id = clipID {
            guard let m = find(id) else { throw EditError.clipNotFound }
            guard m.clip.kind == .video, !m.clip.isGenerator else { throw EditError.wrongTrackKind }
            guard m.clip.timeline.contains(t) else { throw EditError.clipNotFound }
            return m
        }
        for i in tracks.indices.reversed() where tracks[i].kind == .video {
            if let c = tracks[i].clips.first(where: { $0.timeline.contains(t) }), !c.isGenerator { return Member(track: i, clip: c) }
        }
        if tracks.contains(where: { $0.kind == .video }) == false { throw EditError.wrongTrackKind }
        throw EditError.clipNotFound
    }

    /// Insert Frame Hold Segment: cuts the clip at `t` and inserts a held copy of the frame shown there, `duration` long;
    /// everything after ripples later on all ripple tracks (like an insert edit). One undo step. Returns the held clip.
    @discardableResult
    public mutating func insertFrameHold(of clipID: Clip.ID? = nil, at time: Time, duration: Time) throws -> Clip.ID {
        guard duration > .zero else { throw EditError.emptyClip }
        let t = time.snapped(to: frameDuration)
        let target = try holdTarget(clipID, at: t)
        if tracks[target.track].isLocked { throw EditError.trackLocked }
        let held = target.clip.sourceTime(at: t, frameDuration: frameDuration)
        let hold = target.clip.holding(frame: held, at: t, start: t, duration: duration, keepsAnimation: false)
        var work = tracks
        var relinks: [UUID: UUID] = [:]
        for i in work.indices where i == target.track || work[i].followsRipple {
            try work[i].split(at: t, relinks: &relinks)
            work[i].shift(from: t, by: duration)
        }
        try work[target.track].overwrite(hold, relinks: &relinks)
        tracks = work
        openCaptionGap(at: t, by: duration)
        return hold.id
    }

    /// Add Frame Hold: from `t` to the end of the clip the picture is frozen on the frame shown at `t`. The length of the
    /// clip and everything around it stay as they are. One undo step. Returns the held clip.
    @discardableResult
    public mutating func addFrameHold(of clipID: Clip.ID? = nil, at time: Time) throws -> Clip.ID {
        let t = time.snapped(to: frameDuration)
        let target = try holdTarget(clipID, at: t)
        if tracks[target.track].isLocked { throw EditError.trackLocked }
        let held = target.clip.sourceTime(at: t, frameDuration: frameDuration)
        var work = tracks
        var relinks: [UUID: UUID] = [:]
        try work[target.track].split(at: t, relinks: &relinks)
        guard let piece = work[target.track].clips.first(where: { $0.start == t && $0.timeline.end == target.clip.timeline.end }) else {
            throw EditError.clipNotFound
        }
        var hold = target.clip.holding(frame: held, at: t, start: t, duration: piece.timeline.duration, keepsAnimation: true)
        hold.id = piece.id
        hold.link = piece.link
        work[target.track].replace(hold)
        tracks = work
        return hold.id
    }
}
