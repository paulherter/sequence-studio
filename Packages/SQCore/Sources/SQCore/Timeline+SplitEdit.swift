import Foundation

/// Which half of a linked A/V cut a split edit (J / L cut) moves.
public enum SplitEditSide: Sendable, Hashable {
    case audio, video

    var trackKind: TrackKind { self == .audio ? .audio : .video }
}

extension Timeline {
    /// The cut (a clip ending where another starts on the same track) on the side's tracks nearest to `t`; `tracks` limits
    /// the search (nil = every unlocked track of that kind). nil when there is none.
    public func nearestCut(to t: Time, side: SplitEditSide, tracks ids: [Track.ID]? = nil) -> Time? {
        func dist(_ a: Time) -> Time { a > t ? a - t : t - a }
        var best: Time?
        for tr in tracks where tr.kind == side.trackKind && !tr.isLocked && (ids?.contains(tr.id) ?? true) {
            for c in tr.clips where tr.clips.contains(where: { $0.start == c.timeline.end }) {
                let cut = c.timeline.end
                if best == nil || dist(cut) < dist(best!) { best = cut }
            }
        }
        return best
    }

    /// Split edit (J / L cut): moves only the audio or only the video edit point of the cut at `cut` to `t`, as a roll on
    /// every unlocked track of that kind that has a cut there (or on `tracks` only), so the sequence length and everything
    /// later stay put (ripple-safe). The partner side keeps its edit: video at 10 s and audio at 8 s is a J-cut, audio at
    /// 12 s an L-cut. Clamped by media handles and to one frame left on each side; returns the applied move of the cut
    /// (negative = earlier). `.clipNotFound` when no track has a cut at `cut`, `.trackLocked` when all candidates are locked.
    @discardableResult
    public mutating func splitEdit(cut: Time, side: SplitEditSide, to t: Time, tracks ids: [Track.ID]? = nil) throws -> Time {
        var rows: [(track: Int, left: Clip, right: Clip)] = []
        var lockedHit = false
        for (i, tr) in tracks.enumerated() where tr.kind == side.trackKind && (ids?.contains(tr.id) ?? true) {
            guard let l = tr.clips.first(where: { $0.timeline.end == cut }),
                  let r = tr.clips.first(where: { $0.start == cut }) else { continue }
            if tr.isLocked { lockedHit = true; continue }
            rows.append((i, l, r))
        }
        guard !rows.isEmpty else { throw lockedHit ? EditError.trackLocked : EditError.clipNotFound }
        var d = t - cut
        let fd = frameDuration
        for r in rows {
            if d > .zero {
                if let room = r.left.tailRoom?.flooredToFrame(frameDuration) { d = min(d, room) }
                d = min(d, max(.zero, r.right.duration - r.right.minimumDuration(frame: fd)))
            } else if d < .zero {
                if let h = r.right.headHandle?.flooredToFrame(frameDuration) { d = max(d, .zero - h) }
                d = max(d, min(.zero, r.left.minimumDuration(frame: fd) - r.left.duration))
            }
        }
        guard d != .zero else { return .zero }
        var work = self.tracks
        for r in rows {
            var l = r.left, rt = r.right
            l.extendTail(by: d)
            rt.start += d; rt.extendHead(by: .zero - d)
            work[r.track].replace(l); work[r.track].replace(rt)
        }
        guard work.allSatisfy({ $0.isConsistent }) else { throw EditError.collision }
        self.tracks = work
        return d
    }
}
