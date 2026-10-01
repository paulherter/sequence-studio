import Foundation

/// Constant clip speed edits (Premiere's Clip > Speed/Duration and the Rate Stretch tool).
///
/// Model: `Clip.source` is the part of the media used, `Clip.speed` how fast it plays, so the clip's timeline
/// duration is `source.duration / speed`. Every edit here keeps the timeline duration a whole number of frames and
/// chooses the source range to fit it (`source.duration = frames * frameDuration * speed`, exact rational), so
/// edit points never drift.
extension Timeline {
    /// Clips that can be retimed: media clips. Nested sequences, generators and stills have no constant speed yet.
    public static func canRetime(_ c: Clip) -> Bool { !c.isNested && !c.isGenerator && !c.isStill }

    /// Whole frames of `t` (nearest).
    private func frames(_ t: Time) -> Int64 { t.snapped(to: frameDuration).frameIndex(frameDuration: frameDuration) }

    private func retimeGroup(_ id: Clip.ID) throws -> [Member] {
        let group = try linkedGroup(id)
        if group.contains(where: { tracks[$0.track].isLocked }) { throw EditError.trackLocked }
        if group.contains(where: { !Self.canRetime($0.clip) }) { throw EditError.speedUnsupported }
        return group
    }

    /// Sets the speed (and optionally direction / pitch handling) of a clip and its linked partners.
    ///
    /// The source range (in/out) is kept; the clip's timeline length becomes `source.duration / speed`, rounded to
    /// whole frames (the source range follows by at most half a frame). Start stays.
    /// - `ripple == false`: a clip that grows only grows into free space; where a neighbour is in the way, the clip is
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
        let oldEnd = primary.timeline.end

        // Frame count shared by the group: the most restrictive member.
        var n = Int64.max
        for m in group {
            var c = m.clip
            if let r = reversed { c.reversed = r }
            var want = max(frames(holdingDuration ? c.duration : speed.unscale(c.source.duration)), 1)
            let perFrame = speed.scale(fd)
            // Media limits (the anchor end of the range stays, the other end moves).
            if c.reversed {
                // start' = end - dur >= 0
                want = min(want, max(frameFloor(c.source.end, perFrame), 1))
            } else if let md = c.mediaDuration {
                want = min(want, max(frameFloor(md - c.source.start, perFrame), 1))
            }
            if !ripple {
                let next = tracks[m.track].clips.filter { !ids.contains($0.id) && $0.start >= c.timeline.end }
                    .min { $0.start < $1.start }
                if let next { want = min(want, max(floorFrames(next.start - c.start), 1)) }
            }
            n = min(n, want)
        }

        let newDuration = fd * n
        var work = tracks
        for m in group {
            var c = m.clip
            if let r = reversed { c.reversed = r }
            if let k = keepsPitch { c.keepsPitch = k }
            c.speed = speed
            let srcDur = speed.scale(newDuration)
            if c.reversed { c.source.start = c.source.end - srcDur }
            c.source.duration = srcDur
            c.rescaleKeys(from: m.clip.duration, to: newDuration, mirror: c.reversed != m.clip.reversed)
            work[m.track].replace(c)
        }
        let change = newDuration - primary.duration
        if ripple, change != .zero {
            var pivot: [Int: Time] = [:]
            for i in involved { pivot[i] = oldEnd }
            for m in group { pivot[m.track] = m.clip.timeline.end }
            var shift = change
            if shift < .zero {
                for i in involved {
                    if let room = tracks[i].leftRoom(pivot: pivot[i]!, excluding: ids) { shift = max(shift, .zero - room) }
                }
            }
            for i in involved { work[i].shift(from: pivot[i]!, by: shift, excluding: ids) }
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

    /// Floor of `t / per` in whole frames when `per` is the source time of one timeline frame.
    private func frameFloor(_ t: Time, _ per: Time) -> Int64 { t.frameIndex(frameDuration: per) }

    /// Sets the clip's timeline duration (frame-snapped, at least one frame); the speed becomes
    /// `source.duration / duration` (clamped to 1 % ... 10000 %). Same options as `setSpeed`.
    @discardableResult
    public mutating func setDuration(_ id: Clip.ID, to duration: Time, reversed: Bool? = nil, keepsPitch: Bool? = nil,
                                     ripple: Bool = false) throws -> Time {
        guard let c = find(id)?.clip else { throw EditError.clipNotFound }
        let d = max(frames(duration), 1)
        let target = frameDuration * d
        let src = c.source.duration
        let speed = ClipSpeed(num: src.value * target.timescale, den: src.timescale * target.value)
        return try setSpeed(id, to: speed, reversed: reversed, keepsPitch: keepsPitch, ripple: ripple)
    }

    /// Rate Stretch: moves an edge like a trim, but the source range stays and the speed changes so the clip
    /// fills the new length. The clip can only grow into free space (neighbours and time 0 limit it); nothing ripples.
    /// `delta` is the edge movement in timeline time (tail + = longer, head + = shorter). Returns how far the edge moved.
    @discardableResult
    public mutating func rateStretch(_ id: Clip.ID, edge: ClipEdge, by delta: Time) throws -> Time {
        let group = try retimeGroup(id)
        let fd = frameDuration
        let ids = Set(group.map(\.clip.id))
        let primary = group[0].clip
        let change = edge == .tail ? delta : .zero - delta
        var n = max(frames(primary.duration + change), 1)
        // Room in free space.
        for m in group {
            let c = m.clip
            let others = tracks[m.track].clips.filter { !ids.contains($0.id) }
            if edge == .tail {
                if let next = others.filter({ $0.start >= c.timeline.end }).min(by: { $0.start < $1.start }) {
                    n = min(n, max(floorFrames(next.start - c.start), 1))
                }
            } else {
                let prevEnd = others.filter { $0.timeline.end <= c.start }.map { $0.timeline.end }.max() ?? .zero
                n = min(n, max(floorFrames(c.timeline.end - prevEnd), 1))
            }
        }
        // Speed from the primary's source range; the clamp may change the length again.
        let tl = fd * n
        let src = primary.source.duration
        let speed = ClipSpeed(num: src.value * tl.timescale, den: src.timescale * tl.value)
        n = max(frames(speed.unscale(src)), 1)
        // The clamp (and rounding) may have changed the length again: neighbours and media limit it once more.
        let perFrame = speed.scale(fd)
        for m in group {
            let c = m.clip
            let others = tracks[m.track].clips.filter { !ids.contains($0.id) }
            if edge == .tail {
                if let next = others.filter({ $0.start >= c.timeline.end }).min(by: { $0.start < $1.start }) {
                    n = min(n, max(floorFrames(next.start - c.start), 1))
                }
            } else {
                let prevEnd = others.filter { $0.timeline.end <= c.start }.map { $0.timeline.end }.max() ?? .zero
                n = min(n, max(floorFrames(c.timeline.end - prevEnd), 1))
            }
            if c.reversed { n = min(n, max(frameFloor(c.source.end, perFrame), 1)) }
            else if let md = c.mediaDuration { n = min(n, max(frameFloor(md - c.source.start, perFrame), 1)) }
        }
        let newDuration = fd * n
        let applied = edge == .tail ? newDuration - primary.duration : primary.duration - newDuration
        if applied == .zero && speed == primary.speed { return .zero }
        var work = tracks
        for m in group {
            var c = m.clip
            c.speed = speed
            let srcDur = speed.scale(newDuration)
            if c.reversed { c.source.start = c.source.end - srcDur }
            c.source.duration = srcDur
            c.rescaleKeys(from: m.clip.duration, to: newDuration, mirror: false)
            if edge == .head { c.start = m.clip.timeline.end - newDuration }
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

    public init(speed: ClipSpeed? = nil, duration: Time? = nil, reversed: Bool? = nil, keepsPitch: Bool? = nil,
                ripple: Bool = false, holdingDuration: Bool = false) {
        self.speed = speed; self.duration = duration; self.reversed = reversed; self.keepsPitch = keepsPitch
        self.ripple = ripple; self.holdingDuration = holdingDuration
    }
}

extension Timeline {
    /// Applies `change` to the clip (and its linked partners). Returns the change of the clip's timeline duration.
    @discardableResult
    public mutating func apply(_ change: SpeedChange, to id: Clip.ID) throws -> Time {
        guard let c = find(id)?.clip else { throw EditError.clipNotFound }
        if let d = change.duration {
            return try setDuration(id, to: d, reversed: change.reversed, keepsPitch: change.keepsPitch, ripple: change.ripple)
        }
        return try setSpeed(id, to: change.speed ?? c.speed, reversed: change.reversed, keepsPitch: change.keepsPitch,
                            ripple: change.ripple, holdingDuration: change.holdingDuration)
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
