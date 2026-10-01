import Foundation

/// A clip frame matched back to its media (F) and the way back (Shift+R).
public struct MatchedFrame: Sendable, Hashable {
    public var clip: Clip
    public var media: MediaRef.ID
    /// Time inside the media that the playhead shows.
    public var sourceTime: Time
}

extension Timeline {
    /// Match Frame: the clip the Source Monitor should load for the playhead `t`. A selected clip under the playhead
    /// wins, then the topmost targeted track, then the topmost video track, then any audio track. Generators and
    /// nested sequences have no media to match and are skipped.
    public func matchFrame(at t: Time, selected: Set<Clip.ID> = []) -> MatchedFrame? {
        func hit(_ track: Track) -> Clip? {
            track.clips.first { $0.timeline.contains(t) && !$0.isGenerator && !$0.isNested }
        }
        func frame(_ c: Clip) -> MatchedFrame { MatchedFrame(clip: c, media: c.media, sourceTime: c.source.start + (t - c.start)) }
        if !selected.isEmpty {
            for tr in tracks.reversed() { if let c = hit(tr), selected.contains(c.id) { return frame(c) } }
        }
        let ordered = tracks.filter { $0.kind == .video }.reversed() + tracks.filter { $0.kind == .audio }
        for tr in ordered where tr.isTargeted { if let c = hit(tr) { return frame(c) } }
        for tr in ordered { if let c = hit(tr) { return frame(c) } }
        return nil
    }

    /// Reverse Match Frame: the sequence time that shows `sourceTime` of `media`. Prefers a selected clip, then one under
    /// the playhead, then the clip whose used range is nearest to the playhead. nil when the media is not used there.
    public func reverseMatchFrame(media: MediaRef.ID, sourceTime: Time, playhead: Time, selected: Set<Clip.ID> = []) -> Time? {
        let all = tracks.flatMap(\.clips).filter { $0.media == media && !$0.isGenerator && !$0.isNested
            && $0.source.start <= sourceTime && sourceTime < $0.source.end }
        guard !all.isEmpty else { return nil }
        func at(_ c: Clip) -> Time { c.start + (sourceTime - c.source.start) }
        let pick = all.first { selected.contains($0.id) }
            ?? all.first { $0.timeline.contains(playhead) }
            ?? all.min { distance(at($0), playhead) < distance(at($1), playhead) }
        return pick.map(at)
    }
}

private func distance(_ a: Time, _ b: Time) -> Time {
    let d = a - b
    return d.isNegative ? -d : d
}
