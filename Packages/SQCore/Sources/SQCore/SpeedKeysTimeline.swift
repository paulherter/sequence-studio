import Foundation

extension SpeedKeys {
    /// Cuts frames off the tail until every source time the track visits lies inside `0 ... media` (nil = unbounded above).
    /// Returns nil when not even one frame fits.
    func fitting(media: Time?, frameDuration fd: Time) -> SpeedKeys? {
        var k = self
        var steps = 0
        while true {
            let h = k.hull
            if h.start >= .zero, media.map({ h.end <= $0 }) ?? true { return k }
            guard k.duration > fd, steps < 100_000 else { return nil }
            k = k.extendedTail(by: .zero - fd)
            steps += 1
        }
    }

    /// A single constant segment as the plain constant-speed fields of a clip (`speedKeys` nil), or nil for a real track.
    var asConstant: (speed: ClipSpeed, reversed: Bool, source: TimeRange)? {
        guard segments.count == 1, !segments[0].isRamp else { return nil }
        let s = segments[0], span = s.from.scale(duration)
        return (s.from, s.reversed, s.reversed ? TimeRange(start: origin - span, duration: span)
                                               : TimeRange(start: origin, duration: span))
    }
}

extension Timeline {
    /// Applies a speed-track edit to a clip and its linked partners (video and audio get the same segments, each its own
    /// origin) as one change. `edit` receives the clip's track (a constant clip is one segment) and returns the new track, or
    /// nil for "nothing to do". The result is normalised; a single constant segment turns the clip back into a constant-speed
    /// clip (`speedKeys == nil`), so a track that was edited back to one speed equals an untouched clip.
    ///
    /// The clip's start stays. A clip that grows only grows into free space (neighbours stop it, like Rate Stretch); the media
    /// limits the tail the same way. Clip-local keyframes and effect keys stay on their timeline frames: only a constant speed
    /// change scales them (Premiere keeps effect keyframes in sequence time when the speed changes inside the clip).
    /// Returns the change of the clip's timeline duration.
    @discardableResult
    public mutating func editSpeedKeys(_ id: Clip.ID, _ edit: (SpeedKeys) -> SpeedKeys?) throws -> Time {
        let group = try retimeGroup(id)
        let fd = frameDuration
        let primary = group[0].clip
        let base = SpeedKeys.of(primary)
        guard let edited = edit(base)?.normalized() else { return .zero }
        let ids = Set(group.map(\.clip.id))

        // Shared length: the most restrictive member (free space after the clip).
        var limit = edited.duration
        for m in group {
            if let next = tracks[m.track].clips.filter({ !ids.contains($0.id) && $0.start >= m.clip.timeline.end })
                .min(by: { $0.start < $1.start }) {
                limit = min(limit, max(next.start - m.clip.start, fd))
            }
        }
        var shared = edited
        let n = max(limit.frameIndex(frameDuration: fd), 1)
        if shared.duration > fd * n { shared = shared.sliced(from: .zero, to: fd * n) }

        var tracksOut: [(Int, Clip, SpeedKeys)] = []
        var newDuration = shared.duration
        for m in group {
            let own = SpeedKeys.of(m.clip)
            let k = SpeedKeys(segments: shared.segments, origin: own.origin + (shared.origin - base.origin))
            guard let fit = k.fitting(media: m.clip.mediaDuration, frameDuration: fd) else { throw EditError.collision }
            newDuration = min(newDuration, fit.duration)
            tracksOut.append((m.track, m.clip, fit))
        }
        var work = tracks
        for (track, clip, keys) in tracksOut {
            var c = clip
            let k = keys.duration > newDuration ? keys.sliced(from: .zero, to: newDuration) : keys
            if let plain = k.asConstant {
                c.speedKeys = nil
                c.speed = plain.speed; c.reversed = plain.reversed; c.source = plain.source
            } else {
                c.setSpeedKeys(k)
            }
            work[track].replace(c)
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        return newDuration - primary.duration
    }
}
