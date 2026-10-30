import Foundation

/// Which side of an edit Trim mode changes. `.outgoing` ripples the end of the clip before the edit, `.incoming` ripples
/// the start of the clip after it, `.roll` moves the edit itself (sequence length unchanged).
public enum TrimSide: Sendable, Hashable, CaseIterable {
    case outgoing, incoming, roll

    /// Ctrl+T in Trim mode: outgoing -> incoming -> roll -> outgoing; sides the edit does not have are skipped.
    public func next(in p: TrimPoint) -> TrimSide {
        let order: [TrimSide] = [.outgoing, .incoming, .roll]
        let i = order.firstIndex(of: self) ?? 0
        for k in 1...order.count {
            let s = order[(i + k) % order.count]
            if p.supports(s) { return s }
        }
        return self
    }
}

/// An edit point as Trim mode sees it: the clip ending and the clip starting at `time` on one track. A clip edge next to
/// a gap has only one side.
public struct TrimPoint: Sendable, Hashable {
    public var track: Track.ID
    public var outgoing: Clip.ID?
    public var incoming: Clip.ID?
    public var time: Time
    public init(track: Track.ID, outgoing: Clip.ID?, incoming: Clip.ID?, time: Time) {
        self.track = track; self.outgoing = outgoing; self.incoming = incoming; self.time = time
    }

    public func supports(_ side: TrimSide) -> Bool {
        switch side {
        case .outgoing: outgoing != nil
        case .incoming: incoming != nil
        case .roll: outgoing != nil && incoming != nil
        }
    }

    /// The side a double-click picks: the one the pointer is on (`before` = left of the edit); a roll is never the default.
    public func defaultSide(pointerBefore before: Bool) -> TrimSide {
        if before, outgoing != nil { return .outgoing }
        if !before, incoming != nil { return .incoming }
        return outgoing != nil ? .outgoing : .incoming
    }
}

extension Timeline {
    /// The edit point on `track` at `cut` (a clip ends and/or starts there); nil when neither does.
    public func trimPoint(at cut: Time, on track: Track.ID) -> TrimPoint? {
        guard let tr = tracks.first(where: { $0.id == track }) else { return nil }
        let out = tr.clips.first { $0.timeline.end == cut }, inc = tr.clips.first { $0.start == cut }
        guard out != nil || inc != nil else { return nil }
        return TrimPoint(track: track, outgoing: out?.id, incoming: inc?.id, time: cut)
    }

    /// The edit point nearest to `t` on the given tracks (nil = every unlocked track). Real cuts beat lone clip edges at
    /// the same distance; further ties go to the upper track. The sequence start is not an edit point.
    public func nearestTrimPoint(to t: Time, tracks ids: [Track.ID]? = nil) -> TrimPoint? {
        func dist(_ a: Time) -> Time { a > t ? a - t : t - a }
        var best: (p: TrimPoint, d: Time, cut: Bool)?
        for tr in tracks where !tr.isLocked && (ids?.contains(tr.id) ?? true) {
            var times = Set<Time>()
            for c in tr.clips { times.insert(c.start); times.insert(c.timeline.end) }
            for time in times.sorted() where time > .zero {
                guard let p = trimPoint(at: time, on: tr.id) else { continue }
                let d = dist(time), isCut = p.outgoing != nil && p.incoming != nil
                if let b = best, !(d < b.d || (d == b.d && isCut && !b.cut)) { continue }
                best = (p, d, isCut)
            }
        }
        return best?.p
    }

    /// The same edit after it moved: its clips keep their IDs, so time (and track) are re-read from them. A side whose clip
    /// is gone becomes nil; nil overall when no clip is left or when both still exist but no longer touch on one track.
    public func resolved(_ p: TrimPoint) -> TrimPoint? {
        func find(_ id: Clip.ID?) -> (track: Track.ID, clip: Clip)? {
            guard let id else { return nil }
            for tr in tracks { if let c = tr.clips.first(where: { $0.id == id }) { return (tr.id, c) } }
            return nil
        }
        let out = find(p.outgoing), inc = find(p.incoming)
        var r = p
        r.outgoing = out?.clip.id; r.incoming = inc?.clip.id
        switch (out, inc) {
        case let (o?, i?):
            guard o.track == i.track, o.clip.timeline.end == i.clip.start else { return nil }
            r.track = o.track; r.time = i.clip.start
        case let (o?, nil): r.track = o.track; r.time = o.clip.timeline.end
        case let (nil, i?): r.track = i.track; r.time = i.clip.start
        default: return nil
        }
        return r
    }

    /// Frame times the two-up monitor shows: the last frame of the outgoing clip and the first frame of the incoming one
    /// (nil for a side the edit does not have).
    public func trimFrames(_ p: TrimPoint) -> (outgoing: Time?, incoming: Time?) {
        let all = tracks.flatMap(\.clips)
        let out = p.outgoing.flatMap { id in all.first { $0.id == id } }.map { $0.timeline.end - frameDuration }
        let inc = p.incoming.flatMap { id in all.first { $0.id == id } }?.start
        return (out, inc)
    }

    /// Moves the edit `delta` later (negative = earlier) in the given mode and returns how far the edge actually moved:
    /// whole frames only (rounded toward zero), clamped by media handles and neighbors so a clip keeps at least one
    /// frame, 0 when blocked. One call is one atomic edit; linked partners follow. `.outgoing` / `.incoming` ripple,
    /// `.roll` keeps the sequence length. `.clipNotFound` when the point or the side's clips are gone or no longer
    /// adjacent (roll), `.trackLocked` for a locked track.
    @discardableResult
    public mutating func trimEdit(_ p: TrimPoint, side: TrimSide, by delta: Time) throws -> Time {
        guard let r = resolved(p), r.supports(side) else { throw EditError.clipNotFound }
        let all = tracks.flatMap(\.clips)
        func clip(_ id: Clip.ID?) -> Clip? { id.flatMap { i in all.first { $0.id == i } } }
        let fd = frameDuration
        func whole(_ t: Time) -> Time {                       // toward zero, in whole frames
            t < .zero ? -(fd * (-t).frameIndex(frameDuration: fd)) : fd * t.frameIndex(frameDuration: fd)
        }
        func floorFrames(_ t: Time) -> Time { fd * max(0, t.frameIndex(frameDuration: fd)) }
        var d = whole(delta)
        let one = fd
        switch side {
        case .outgoing:
            guard let o = clip(r.outgoing) else { throw EditError.clipNotFound }
            if let room = o.tailRoom { d = min(d, floorFrames(room)) }
            d = max(d, min(.zero, o.minimumDuration(frame: one) - o.duration))       // a clip under one frame (or its zones): no shortening, never a reversal
            guard d != .zero else { return .zero }
            return try magneticRippleTrim(o.id, edge: .tail, by: d)      // Normal: plain ripple trim
        case .incoming:
            guard let i = clip(r.incoming) else { throw EditError.clipNotFound }
            if let h = i.headHandle { d = max(d, -floorFrames(h)) }
            d = min(d, max(.zero, i.duration - i.minimumDuration(frame: one)))
            guard d != .zero else { return .zero }
            return try magneticRippleTrim(i.id, edge: .head, by: d)
        case .roll:
            guard let o = clip(r.outgoing), let i = clip(r.incoming) else { throw EditError.clipNotFound }
            if let room = o.tailRoom { d = min(d, floorFrames(room)) }
            if let h = i.headHandle { d = max(d, -floorFrames(h)) }
            d = min(d, max(.zero, i.duration - i.minimumDuration(frame: one)))
            d = max(d, min(.zero, o.minimumDuration(frame: one) - o.duration))
            guard d != .zero else { return .zero }
            return try magneticRoll(o.id, by: d)
        }
    }
}
