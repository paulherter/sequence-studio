import Foundation

/// J cut: the next clip's audio starts before its picture. L cut: the previous clip's audio runs on over the next picture.
public enum JLCut: Sendable, Hashable { case jCut, lCut }

/// What one press of Cut Out does (Q-CUT1): the first press marks the start, the next one extracts start..playhead.
public enum CutOutStep: Sendable, Hashable {
    case markStart(Time)
    case extract(TimeRange)
}

extension Timeline {
    /// Cut Out: `pending` is the start marked by the previous press (nil = none). A press at or before the start
    /// begins a new span instead.
    public static func cutOutStep(pending: Time?, playhead: Time) -> CutOutStep {
        guard let p = pending, playhead > p else { return .markStart(playhead) }
        return .extract(TimeRange(start: p, end: playhead))
    }

    /// One key to close the gap under `t`: every unlocked track that has a gap there closes the part they all share,
    /// in one ripple (later clips on those tracks and sync-locked tracks move left). Returns the time closed; zero
    /// (nothing changed) when no track has a gap at `t`.
    @discardableResult
    public mutating func closeGapsAtPlayhead(at t: Time) throws -> Time {
        var ids: [Track.ID] = []
        var shared: TimeRange?
        for tr in tracks where !tr.isLocked {
            guard let g = gap(on: tr.id, at: t) else { continue }
            ids.append(tr.id)
            if let s = shared {
                shared = TimeRange(start: max(s.start, g.start), end: min(s.end, g.end))
            } else { shared = g }
        }
        guard let r = shared, !r.isEmpty, !ids.isEmpty else { return .zero }
        return try extract(r, tracks: ids)
    }

    /// The clips that start and end exactly at the two edit points (either order): the "piece" between two Cmd+K cuts.
    public func clips(between a: Time, and b: Time) -> [Clip.ID] {
        let lo = min(a, b), hi = max(a, b)
        return tracks.flatMap(\.clips).filter { $0.start == lo && $0.timeline.end == hi }.map(\.id)
    }

    /// J / L cut by direction (plain-key command): the audio edit of the nearest cut AHEAD of `t` (J) or BEHIND it (L)
    /// moves to `t`, as a roll (`splitEdit`). Throws `.clipNotFound` when there is no such cut.
    @discardableResult
    public mutating func splitEditJL(_ kind: JLCut, at t: Time) throws -> Time {
        var best: Time?
        for tr in tracks where tr.kind == .audio && !tr.isLocked {
            for c in tr.clips where tr.clips.contains(where: { $0.start == c.timeline.end }) {
                let cut = c.timeline.end
                guard kind == .jCut ? cut > t : cut < t else { continue }
                if best == nil || (kind == .jCut ? cut < best! : cut > best!) { best = cut }
            }
        }
        guard let cut = best else { throw EditError.clipNotFound }
        return try splitEdit(cut: cut, side: .audio, to: t)
    }
}
