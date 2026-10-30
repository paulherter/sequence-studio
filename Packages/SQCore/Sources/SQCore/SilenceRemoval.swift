import Foundation

/// Pause shortening ("Remove Silences"): turns detected pauses into frame-aligned ripple cuts that leave a fixed pad
/// of the pause on each side. A timeline edit; the media is never changed. Always run by an explicit command.
public enum SilenceRemoval {
    /// Cuts for `silences` (timeline time). Each pause loses everything except `padding` at both ends; the cut is
    /// shrunk to whole frames (start rounded up, end rounded down) so no cut lands between frames. Pauses that leave
    /// less than one frame to cut are dropped. Sorted, non-overlapping.
    public static func cuts(silences: [TimeRange], padding: Time, frameDuration: Time) -> [TimeRange] {
        var out: [TimeRange] = []
        for s in silences.sorted(by: { $0.start < $1.start }) {
            let a = ceilFrame(s.start + padding, frameDuration), b = FadeKeys.snapDown(s.end - padding, frameDuration)
            guard b - a >= frameDuration else { continue }
            if let last = out.last, a < last.end { continue }
            out.append(TimeRange(start: a, duration: b - a))
        }
        return out
    }

    /// Cuts sorted, overlapping or touching ones joined, clamped to start at 0, empty ones dropped.
    public static func normalized(_ cuts: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        for c in cuts.sorted(by: { $0.start < $1.start }) {
            let a = max(c.start, .zero), b = c.end
            guard b > a else { continue }
            if let last = out.last, a <= last.end {
                out[out.count - 1] = TimeRange(start: last.start, duration: max(last.end, b) - last.start)
            } else {
                out.append(TimeRange(start: a, duration: b - a))
            }
        }
        return out
    }

    private static func ceilFrame(_ t: Time, _ frame: Time) -> Time {
        let n = t.frameIndex(frameDuration: frame)
        let f = frame * n
        return f == t ? f : frame * (n + 1)
    }
}

extension Clip {
    /// Timeline range that plays the source range `r` (through speed and direction), clamped to the clip.
    public func timelineRange(forSource r: TimeRange) -> TimeRange? {
        let a = timelineTime(forSource: r.start), b = timelineTime(forSource: r.end)
        let lo = max(min(a, b), start), hi = min(max(a, b), timeline.end)
        return hi > lo ? TimeRange(start: lo, duration: hi - lo) : nil
    }
}

extension Timeline {
    /// Ripple-deletes every cut on `tracks` (and every sync-locked track, like Extract). All or nothing. Cuts are
    /// processed from the end so earlier ones keep their position. Returns the total time removed. Runs as one sweep
    /// (`extractAll`) when the cuts do not overlap and every sync-locked track is targeted; otherwise one extract per cut.
    @discardableResult
    public mutating func removeCuts(_ cuts: [TimeRange], tracks ids: [Track.ID]) throws -> Time {
        let sorted = cuts.sorted { $0.start < $1.start }
        if !sorted.isEmpty, let targets = try? targetIndices(ids), batchRippleApplies(sorted, targets: targets) {
            return try extractAll(SilenceRemoval.normalized(sorted), targets: targets)
        }
        var work = self
        var removed = Time.zero
        for c in cuts.sorted(by: { $0.start > $1.start }) {
            removed = removed + (try work.extract(c, tracks: ids))
        }
        self = work
        return removed
    }
}

extension Timeline {
    /// "Remove Silences": ripple-deletes every cut through the whole sequence, one edit, all or nothing. Cut are the
    /// tracks of `clips` and of their linked partners (a locked one refuses the edit), plus every sync-locked unlocked
    /// track: what lies inside a cut there (music, B-roll) is cut too, so everything after a cut moves by exactly its
    /// length and stays in sync. A clip a cut splits or moves takes the tracks of its linked partners along too (a
    /// locked one refuses the edit), so B-roll sound on a track without sync lock stays with its picture. Tracks without sync lock and locked tracks are not touched. Cuts may be unsorted or
    /// overlap; parts after the end of all affected content are ignored. One sweep over all cuts (`extractAll`), the same
    /// result as one Extract per cut from the last to the first. Returns the total time removed.
    @discardableResult
    public mutating func removeSilences(_ cuts: [TimeRange], around clips: Set<Clip.ID>, joinFade: Time = .zero) throws -> Time {
        let links = Set(tracks.flatMap(\.clips).filter { clips.contains($0.id) }.compactMap(\.link))
        var ids = Set<Track.ID>()
        for t in tracks {
            let owns = t.clips.contains { clips.contains($0.id) || ($0.link.map(links.contains) ?? false) }
            if owns || t.followsRipple { ids.insert(t.id) }
        }
        let normalized = SilenceRemoval.normalized(cuts)
        // Every clip on a cut track that a cut splits or moves (it ends after the first cut starts) takes its linked
        // partners along, even on tracks without sync lock, until no new track joins. A locked one refuses the edit.
        if let first = normalized.first?.start {
            var grew = true
            while grew {
                let moved = Set(tracks.filter { ids.contains($0.id) }.flatMap(\.clips)
                    .filter { $0.timeline.end > first }.compactMap(\.link))
                grew = false
                for t in tracks where !ids.contains(t.id) && t.clips.contains(where: { $0.link.map(moved.contains) ?? false }) {
                    if t.isLocked { throw EditError.trackLocked }
                    ids.insert(t.id); grew = true
                }
            }
        }
        let end = tracks.filter { ids.contains($0.id) }.map(\.end).max() ?? .zero
        let clamped = normalized.compactMap { c -> TimeRange? in
            let b = min(c.end, end)
            return b > c.start ? TimeRange(start: c.start, duration: b - c.start) : nil
        }
        guard !clamped.isEmpty else { return .zero }
        // Every sync-locked unlocked track is among the cut tracks, so the cuts close in one sweep and always completely.
        let targets = try targetIndices(tracks.map(\.id).filter(ids.contains))
        let removed = try extractAll(clamped, targets: targets)
        if joinFade > .zero { softenJoins(afterCutting: clamped, tracks: ids, length: joinFade) }
        return removed
    }

    /// A short fade out and fade in on both sides of every join the cuts left on the audio tracks `ids` (a hard cut
    /// in the middle of a signal clicks; the padding next to the pause is quiet, so the fade is not heard). A fade a
    /// clip already has at that edge is kept when it is longer. `cuts` are sorted, non-overlapping, in time before the edit.
    mutating func softenJoins(afterCutting cuts: [TimeRange], tracks ids: Set<Track.ID>, length: Time) {
        var joins: [Time] = []
        var removedBefore = Time.zero
        for c in cuts {
            joins.append(c.start - removedBefore)
            removedBefore = removedBefore + c.duration
        }
        let fd = frameDuration
        for id in tracks.filter({ ids.contains($0.id) && $0.kind == .audio }).map(\.id) {
            for t in joins {
                guard let track = tracks.first(where: { $0.id == id }),      // fresh: an earlier join may have changed a clip
                      let a = track.clips.first(where: { $0.timeline.end == t && !$0.isGenerator }),
                      let b = track.clips.first(where: { $0.start == t && !$0.isGenerator }) else { continue }
                var out = a, inn = b
                out.setAudioFadeOut(max(length, a.audioFadeOut), frameDuration: fd)
                inn.setAudioFadeIn(max(length, b.audioFadeIn), frameDuration: fd)
                _ = try? replaceClip(out); _ = try? replaceClip(inn)
            }
        }
    }
}
