import Foundation

/// Constant clip speed edits (Premiere's Clip > Speed/Duration and the Rate Stretch tool).
///
/// Model: `Clip.source` is the part of the media used, `Clip.speed` how fast it plays, so the clip's timeline
/// duration is `source.duration / speed`. Every edit here keeps the timeline duration a whole number of frames and
/// chooses the source range to fit it (`source.duration = frames * frameDuration * speed`, exact rational), so
/// edit points never drift.
extension Timeline {
    /// Clips that can be retimed: media clips and nested sequences (their length is the inner sequence's duration, refreshed
    /// with `refreshNestedDurations` before the edit). Generators (text) and stills have no time axis.
    public static func canRetime(_ c: Clip) -> Bool { !c.isGenerator && !c.isStill }

    /// Brings the inner-duration limit (`mediaDuration`) of nested clips up to date: it is derived from the inner sequence at
    /// edit time, because a stored value goes stale when the inner sequence is edited. `inner` = the sequence's current duration.
    public mutating func refreshNestedDurations(_ inner: (Timeline.ID) -> Time?) {
        for ti in tracks.indices {
            for c in tracks[ti].clips {
                guard let seq = c.sequence, let d = inner(seq), d != c.mediaDuration else { continue }
                var n = c
                n.mediaDuration = d
                tracks[ti].replace(n)
            }
        }
    }

    /// Whole frames of `t` (nearest).
    private func frames(_ t: Time) -> Int64 { t.snapped(to: frameDuration).frameIndex(frameDuration: frameDuration) }

    func retimeGroup(_ id: Clip.ID) throws -> [Member] {
        let group = try linkedGroup(id)
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        if group.contains(where: { !Self.canRetime($0.clip) }) { throw EditError.speedUnsupported }
        return group
    }

    /// Sets the speed (and optionally direction / pitch handling) of a clip and its linked partners.
    ///
    /// The source range (in/out) is kept; the clip's timeline length becomes `source.duration / speed`, rounded to
    /// whole frames (the source range follows by at most half a frame). Start stays.
    /// - `ripple == false`: a clip that grows only grows into free space; where a neighbor is in the way, the clip is
    ///   truncated (shows less source) like Premiere. A clip that shrinks leaves a gap.
    /// - `ripple == true` (Ripple Edit, Shifting Trailing Clips): later clips on every ripple track shift by the change,
    ///   like a ripple trim; shortening closes only as far as nothing collides.
    /// - `holdingDuration`: keeps the timeline length and changes the source range instead (the speed and duration
    ///   fields of Premiere's dialog unlinked): the clip shows more or less of its media, limited by the media.
    /// Returns the change of the clip's timeline duration.
    @discardableResult
    public mutating func setSpeed(_ id: Clip.ID, to speed: ClipSpeed, reversed: Bool? = nil, keepsPitch: Bool? = nil,
                                  ripple: Bool = false, holdingDuration: Bool = false) throws -> Time {
        let group = try retimeGroup(id)
        let fd = frameDuration
        let ids = Set(group.map(\.clip.id))
        let involvedAll = ripple ? Set(group.map(\.track)).union(tracks.indices.filter { tracks[$0].followsRipple }) : Set(group.map(\.track))
        let involved = involvedAll.sorted()
        let primary = group[0].clip
        // Tracks without a member shift from the earliest member end (the edit point), not from the clicked clip's end:
        // a partner moved alone sits elsewhere, and later clips (and split-edit partners) behind the earliest end follow.
        let oldEnd = group.map(\.clip.timeline.end).min() ?? primary.timeline.end

        // Frame count per member: each keeps its own source range (a linked partner may be longer than the clip), limited
        // by its own media and neighbor.
        var lengths: [Clip.ID: Time] = [:]
        for m in group {
            var c = m.clip
            if let r = reversed { c.reversed = r }
            var want = max(frames(holdingDuration ? c.duration : speed.unscale(c.retimeSpan)), 1)
            if let k = c.speedKeys { want = frames(k.clampedDuration(fd * want, frameDuration: fd)) }
            let perFrame = speed.scale(fd)
            // Media limits (the anchor end of the range stays, the other end moves). A remapped clip keeps the source it
            // visits, so only its length changes: no media limit.
            // Less than one timeline frame of media left at this speed: refuse rather than run past the media.
            if let room = Self.mediaFrames(c, perFrame: perFrame) {
                guard room >= 1 else { throw EditError.insufficientMedia }
                want = min(want, room)
            }
            if !ripple {
                let next = tracks[m.track].clips.filter { !ids.contains($0.id) && $0.start >= c.timeline.end }
                    .min { $0.start < $1.start }
                if let next { want = min(want, max(floorFrames(next.start - c.start), 1)) }
            }
            lengths[c.id] = fd * want
        }
        func length(_ id: Clip.ID) throws -> Time {
            guard let l = lengths[id] else { throw EditError.clipNotFound }
            return l
        }

        var work = tracks
        for m in group {
            let newDuration = try length(m.clip.id)
            var c = m.clip
            if let r = reversed { c.reversed = r }
            if let k = keepsPitch { c.keepsPitch = k }
            if let keys = c.speedKeys {
                // Remapped: the whole shape plays faster or slower; Reverse flips every segment.
                var scaled = keys.scaled(toDuration: newDuration, frameDuration: fd)
                if c.reversed != m.clip.reversed {
                    let end = scaled.endPosition
                    scaled.segments = scaled.segments.reversed().map {
                        // An eased ramp played backwards is its curve rotated 180°: out and in swap (span unchanged).
                        SpeedSegment(duration: $0.duration, from: $0.to, to: $0.from, reversed: !$0.reversed,
                                     ease: $0.ease.map { EaseShape(interpolation: .bezier, out: $0.in, in: $0.out) })
                    }
                    scaled.origin = end
                }
                guard let fit = scaled.fitting(media: c.mediaDuration, frameDuration: fd) else { throw EditError.collision }
                c.setSpeedKeys(fit)
                c.rescaleKeys(from: m.clip.duration, to: newDuration, mirror: c.reversed != m.clip.reversed)
                work[m.track].replace(c)
                continue
            }
            c.speed = speed
            let srcDur = speed.scale(newDuration)
            if c.reversed { c.source.start = c.source.end - srcDur }
            c.source.duration = srcDur
            c.rescaleKeys(from: m.clip.duration, to: newDuration, mirror: c.reversed != m.clip.reversed)
            work[m.track].replace(c)
        }
        let change = try length(primary.id) - primary.duration
        // Ripple: every track shifts by the same amount so trailing clips keep sync. Members of one group change in the
        // same direction; the largest growth (or the smallest shrink) is the one that collides with nothing.
        let shiftWanted = try group.map { try length($0.clip.id) - $0.clip.duration }.max() ?? change
        if ripple, shiftWanted != .zero {
            var pivot: [Int: Time] = [:]
            for i in involved { pivot[i] = oldEnd }
            var own: [Int: Time] = [:]          // several members on one track: the latest end, whichever was clicked
            for m in group { own[m.track] = max(own[m.track] ?? m.clip.timeline.end, m.clip.timeline.end) }
            for (i, e) in own { pivot[i] = e }
            // Split edits (J/L cuts): a straddling clip whose linked partner shifts moves with it, like a ripple trim.
            pivot = Self.followingStraddlers(tracks, pivot, excluding: ids)
            var shift = shiftWanted
            if shift < .zero {
                for i in involved {
                    if let room = tracks[i].leftRoom(pivot: pivot[i] ?? oldEnd, excluding: ids) { shift = max(shift, .zero - room) }
                }
            }
            for i in involved { work[i].shift(from: pivot[i] ?? oldEnd, by: shift, excluding: ids) }
            guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
            tracks = work
            if shift < .zero { closeCaptionSpan(TimeRange(start: oldEnd + shift, duration: .zero - shift)) }
            else { openCaptionGap(at: oldEnd, by: shift) }
        } else {
            guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
            tracks = work
        }
        return change
    }

    private func floorFrames(_ t: Time) -> Int64 { t.frameIndex(frameDuration: frameDuration) }

    /// Whole timeline frames of media the clip can show at `perFrame` source time per frame, from its anchored edge
    /// (source end when reversed, source start forward). nil = no limit (remapped clip, or unknown media length).
    private static func mediaFrames(_ c: Clip, perFrame: Time) -> Int64? {
        if c.speedKeys != nil { return nil }
        if c.reversed { return c.source.end.frameIndex(frameDuration: perFrame) }       // start' = end - dur >= 0
        return c.mediaDuration.map { ($0 - c.source.start).frameIndex(frameDuration: perFrame) }
    }

    /// Sets the clip's timeline duration (frame-snapped, at least one frame); the speed becomes
    /// `source.duration / duration` (clamped to 1 % ... 10000 %). Same options as `setSpeed`.
    @discardableResult
    public mutating func setDuration(_ id: Clip.ID, to duration: Time, reversed: Bool? = nil, keepsPitch: Bool? = nil,
                                     ripple: Bool = false) throws -> Time {
        guard let c = find(id)?.clip else { throw EditError.clipNotFound }
        let d = max(frames(duration), 1)
        let target = frameDuration * d
        let speed = ClipSpeed(source: c.retimeSpan, over: target)
        return try setSpeed(id, to: speed, reversed: reversed, keepsPitch: keepsPitch, ripple: ripple)
    }

    /// Rate Stretch: moves an edge like a trim, but the source range stays and the speed changes so the clip
    /// fills the new length. The clip can only grow into free space (neighbors and time 0 limit it); nothing ripples.
    /// `delta` is the edge movement in timeline time (tail + = longer, head + = shorter). Returns how far the edge moved.
    @discardableResult
    public mutating func rateStretch(_ id: Clip.ID, edge: ClipEdge, by delta: Time) throws -> Time {
        let group = try retimeGroup(id)
        let fd = frameDuration
        let ids = Set(group.map(\.clip.id))
        let primary = group[0].clip
        let change = edge == .tail ? delta : .zero - delta
        /// The group at primary length `n` frames: one speed (from the primary's source range), each member's own length
        /// (`its source / speed`, whole frames). Nil when a member would leave its free space.
        func layout(_ n: Int64) -> (speed: ClipSpeed, lengths: [Clip.ID: Time])? {
            let tl = fd * n
            let speed = ClipSpeed(source: primary.retimeSpan, over: tl)
            let perFrame = speed.scale(fd)
            var lengths: [Clip.ID: Time] = [:]
            for m in group {
                let c = m.clip
                // The primary gets exactly `n` unless the speed range clamped the speed.
                var k = max(frames(speed.unscale(c.retimeSpan)), 1)
                if let keys = c.speedKeys { k = keys.clampedDuration(fd * k, frameDuration: fd).frameIndex(frameDuration: fd) }
                // Media: the source kept may round up past the media end by part of a frame; it is cut to whole frames.
                // Under one frame of media at this speed: this length does not fit (a longer one, slower, may).
                if let room = Self.mediaFrames(c, perFrame: perFrame) {
                    if room < 1 { return nil }
                    k = min(k, room)
                }
                let others = tracks[m.track].clips.filter { !ids.contains($0.id) }
                if edge == .tail {
                    if let next = others.filter({ $0.start >= c.timeline.end }).min(by: { $0.start < $1.start }),
                       k > max(floorFrames(next.start - c.start), 1) { return nil }
                } else {
                    let prevEnd = others.filter { $0.timeline.end <= c.start }.map { $0.timeline.end }.max() ?? .zero
                    if k > max(floorFrames(c.timeline.end - prevEnd), 1) { return nil }
                }
                lengths[c.id] = fd * k
            }
            return (speed, lengths)
        }
        // The longest primary length up to the request at which every member fits (fitting only gets easier as the group
        // shrinks: every member gets shorter and needs less room).
        let wanted = max(frames(primary.duration + change), 1)
        var plan = layout(wanted)
        let current = max(frames(primary.duration), 1)
        if plan == nil, wanted < current, layout(current) != nil {
            // Shrinking can only fail on media (a partner runs out at the higher speed), which eases as the length grows:
            // the shortest length between the request and now that fits.
            var lo = wanted, hi = current
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if layout(mid) != nil { hi = mid } else { lo = mid + 1 }
            }
            plan = layout(hi)
        }
        if plan == nil {
            var lo: Int64 = 1, hi = wanted
            if wanted > current, layout(current) != nil { lo = current }   // growing: the current length still fits
            var best = layout(lo)
            while lo < hi {
                let mid = lo + (hi - lo + 1) / 2
                if let p = layout(mid) { best = p; lo = mid } else { hi = mid - 1 }
            }
            plan = best
        }
        guard let plan, let newDuration = plan.lengths[primary.id] else { throw EditError.collision }
        let speed = plan.speed
        let applied = edge == .tail ? newDuration - primary.duration : primary.duration - newDuration
        if applied == .zero && speed == primary.speed && primary.speedKeys == nil { return .zero }
        var work = tracks
        for m in group {
            var c = m.clip
            guard let length = plan.lengths[c.id] else { throw EditError.collision }
            if let keys = c.speedKeys {
                let scaled = keys.scaled(toDuration: length, frameDuration: fd)
                c.setSpeedKeys(scaled.fitting(media: c.mediaDuration, frameDuration: fd) ?? scaled)
            } else {
                c.speed = speed
                let srcDur = speed.scale(length)
                if c.reversed { c.source.start = c.source.end - srcDur }
                c.source.duration = srcDur
            }
            c.rescaleKeys(from: m.clip.duration, to: length, mirror: false)
            if edge == .head { c.start = m.clip.timeline.end - length }
            work[m.track].replace(c)
        }
        guard work.allSatisfy(\.isConsistent) else { throw EditError.collision }
        tracks = work
        return applied
    }
}

/// One Speed/Duration dialog result (or script/replay step): what to change on a clip and its linked partners.
public struct SpeedChange: Sendable, Equatable {
    /// New speed. Ignored when `duration` is set.
    public var speed: ClipSpeed?
    /// New timeline duration; the speed follows (Premiere: the duration field).
    public var duration: Time?
    public var reversed: Bool?
    public var keepsPitch: Bool?
    /// Ripple Edit, Shifting Trailing Clips.
    public var ripple: Bool
    /// Speed typed with the link between speed and duration broken: the clip keeps its length and shows more or less media.
    public var holdingDuration: Bool
    /// Time Interpolation (Frame Sampling / Frame Blending), stored on the clip. nil = unchanged.
    public var timeInterpolation: TimeInterpolation?

    public init(speed: ClipSpeed? = nil, duration: Time? = nil, reversed: Bool? = nil, keepsPitch: Bool? = nil,
                ripple: Bool = false, holdingDuration: Bool = false, timeInterpolation: TimeInterpolation? = nil) {
        self.timeInterpolation = timeInterpolation
        self.speed = speed; self.duration = duration; self.reversed = reversed; self.keepsPitch = keepsPitch
        self.ripple = ripple; self.holdingDuration = holdingDuration
    }
}

extension Timeline {
    /// Applies `change` to the clip (and its linked partners). Returns the change of the clip's timeline duration.
    @discardableResult
    public mutating func apply(_ change: SpeedChange, to id: Clip.ID) throws -> Time {
        guard let c = find(id)?.clip else { throw EditError.clipNotFound }
        var work = self
        let result: Time
        if let d = change.duration {
            result = try work.setDuration(id, to: d, reversed: change.reversed, keepsPitch: change.keepsPitch, ripple: change.ripple)
        } else {
            result = try work.setSpeed(id, to: change.speed ?? c.averageSpeed, reversed: change.reversed, keepsPitch: change.keepsPitch,
                                       ripple: change.ripple, holdingDuration: change.holdingDuration)
        }
        if let ti = change.timeInterpolation { try work.setTimeInterpolation(id, ti) }
        self = work
        return result
    }

    /// Time Interpolation of a clip and its linked partners.
    public mutating func setTimeInterpolation(_ id: Clip.ID, _ ti: TimeInterpolation) throws {
        let group = try retimeGroup(id)
        for m in group where m.clip.timeInterpolation != ti {
            var c = m.clip
            c.timeInterpolation = ti
            tracks[m.track].replace(c)
        }
    }

    /// Applies `change` to every clip of `ids` (a linked pair counts once). Refuses the whole edit when any clip cannot be
    /// retimed or a track is locked; the timeline is unchanged then.
    public mutating func apply(_ change: SpeedChange, to ids: [Clip.ID]) throws {
        var work = self
        var done = Set<Clip.ID>()
        for id in ids where !done.contains(id) {
            done.formUnion(try work.linkedGroup(id).map(\.clip.id))
            try work.apply(change, to: id)
        }
        self = work
    }
}
