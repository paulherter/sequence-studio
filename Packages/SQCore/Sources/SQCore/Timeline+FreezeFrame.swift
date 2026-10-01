import Foundation

extension Clip {
    /// Static copy of the animation at timeline time `t`: what a held frame shows (no keys).
    func frozenAnimation(at t: Time) -> ClipAnimation {
        var a = animation
        let tr = transform(at: t)
        a.position = AnimatedProperty(tr.position)
        a.scale = AnimatedProperty(tr.scale)
        a.rotation = AnimatedProperty(tr.rotation)
        a.opacity = AnimatedProperty(tr.opacity)
        a.anchor = AnimatedProperty(tr.anchor)
        return a
    }

    /// A held clip: shows source frame `frame` for `duration` from `start`. Everything that makes the picture look the way
    /// it did at `at` (transform, effects, colour, blend) is frozen as static values.
    func holding(frame: Time, at t: Time, start: Time, duration: Time) -> Clip {
        var h = self
        h.id = UUID()
        h.link = nil
        h.start = start
        h.source = TimeRange(start: frame, duration: duration)
        h.speed = .normal
        h.reversed = false
        h.holdFrame = frame
        h.animation = frozenAnimation(at: t)
        h.effects = effects.map { e in
            var f = e
            f.parameters = e.parameters.mapValues { AnimatedProperty($0.value(atLocal: t - self.start)) }
            return f
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
        let hold = target.clip.holding(frame: held, at: t, start: t, duration: duration)
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
        var hold = target.clip.holding(frame: held, at: t, start: t, duration: piece.timeline.duration)
        hold.id = piece.id
        hold.link = piece.link
        work[target.track].replace(hold)
        tracks = work
        return hold.id
    }
}
