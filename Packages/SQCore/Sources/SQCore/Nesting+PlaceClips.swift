import Foundation

/// Placing a sequence as its individual clips instead of one nested clip (Premiere's "Insert and overwrite sequences as
/// nests or individual clips" switched to individual clips). Reuses the paste path: copies get new IDs, links and bundles
/// survive between copies, missing tracks are created, transitions between copied clips come along.
extension Project {
    /// A sequence's clips ready to place: the clipboard plus the length the sequence occupies (its In/Out range, or the
    /// whole sequence), both on the host's frame grid.
    public struct SequenceClips: Sendable {
        public var clipboard: TimelineClipboard
        /// Span a placement occupies (and an insert ripples by), from the range start; includes leading and trailing gaps.
        public var span: Time
    }

    /// The clips of `sequence` cut to its In/Out when set (clips crossing a mark are cropped), positions relative to the
    /// range start, edges snapped to the host's `frameDuration` (start up, end down; clips that vanish are dropped).
    /// Clips on hidden video tracks and muted audio tracks are left out. Transitions survive only between uncropped clips.
    /// nil for an unknown sequence or when nothing lies in the range.
    public func sequenceClips(of sequence: Timeline.ID, hostFrameDuration fd: Time) -> SequenceClips? {
        guard let t = timeline(sequence) else { return nil }
        let raw = t.inOut.flatMap { $0.duration > .zero ? $0 : nil } ?? TimeRange(start: .zero, duration: t.duration)
        // Every cut point snaps once, to the nearest host frame, so the end of a clip and the start of its neighbor stay
        // the same value (no gaps or overlaps at off-grid cuts) and transitions at the cut survive.
        let rs = raw.start.snapped(to: fd), re = raw.end.snapped(to: fd)
        guard re > rs else { return nil }
        let rawRange = TimeRange(start: raw.start, end: raw.end)
        var entries: [TimelineClipboard.Entry] = []
        var whole: Set<Clip.ID> = []
        for kind in [TrackKind.video, .audio] {
            for (lane, track) in t.tracks.filter({ $0.kind == kind }).enumerated() {
                if kind == .video, !track.isVisible { continue }
                if kind == .audio, track.isMuted { continue }
                for c in track.clips {
                    guard c.timeline.intersection(rawRange) != nil else { continue }
                    let inside = c.timeline.start >= raw.start && c.timeline.end <= raw.end
                    guard let cut = inside ? c : c.cropped(to: rawRange) else { continue }
                    let s = max(cut.start.snapped(to: fd), rs), e = min(cut.timeline.end.snapped(to: fd), re)
                    guard e > s else { continue }      // only a clip that truly collapses to nothing is dropped
                    var kept = cut
                    if kept.speedKeys == nil, kept.start != s || kept.timeline.end != e {
                        let len = kept.speed.scale(e - s)       // sub-frame stretch so the clip fills exactly [s, e)
                        if kept.reversed { kept.source.start = kept.source.end - len }
                        kept.source.duration = len
                    }
                    kept.start = s
                    if inside { whole.insert(c.id) }
                    entries.append(.init(clip: kept, offset: s - rs, lane: lane))
                }
            }
        }
        guard !entries.isEmpty else { return nil }
        let present = Set(entries.map(\.clip.id))
        let kept = t.tracks.flatMap(\.transitions).filter { tr in
            [tr.outgoing, tr.incoming].compactMap { $0 }.allSatisfy { whole.contains($0) && present.contains($0) }
        }
        return SequenceClips(clipboard: TimelineClipboard(entries: entries, transitions: kept,
                                                          pictureTrackLanes: t.pictureTrackLanes(
                                                              for: entries.map(\.clip),
                                                              copied: Set(t.tracks.filter { $0.kind == .video && $0.isVisible }.map(\.id)))),
                             span: re - rs)
    }

    /// Like `placeSequences`, but each sequence lands as its own clips, one after another from `time`, as an overwrite or
    /// an insert (ripples by the whole span). Tracks: without `videoTrack` the clips keep their lanes (V1 -> V1, A2 -> A2);
    /// with it the sequence's first video lane lands on that track (audio on the matching audio track) and the rest keep
    /// their offsets; `newTrack` puts the first lane on a new track of that kind (audio: only the audio clips). In Fast Cut
    /// attached clips follow their hosts (`placeSequenceClips(_:at:lanes:insert:)`). Same refusals as `placeSequences` (`.nestingCycle`,
    /// `.timelineNotFound`, `.emptyClip`); one edit, a refusal changes nothing. Returns the end of the last sequence.
    @discardableResult
    public mutating func placeSequenceClips(_ ids: [Timeline.ID], in host: Timeline.ID, at time: Time, videoTrack: Track.ID? = nil,
                                            newTrack: TrackKind? = nil, mode: ThreePointMode) throws -> Time {
        guard let hostTimeline = timeline(host) else { throw EditError.timelineNotFound }
        guard !ids.isEmpty else { throw EditError.emptyClip }
        for id in ids {
            guard timeline(id) != nil else { throw EditError.emptyClip }
            if wouldCreateCycle(nesting: id, in: host) { throw EditError.nestingCycle }
        }
        let fd = hostTimeline.frameDuration
        var boards: [SequenceClips] = []
        for id in ids {
            guard var sc = sequenceClips(of: id, hostFrameDuration: fd) else { throw EditError.emptyClip }
            if newTrack == .audio {
                sc.clipboard.entries = sc.clipboard.entries.filter { $0.clip.kind == .audio }
                let kept = Set(sc.clipboard.entries.map(\.clip.id))
                sc.clipboard.transitions = sc.clipboard.transitions.filter {
                    [$0.outgoing, $0.incoming].compactMap { $0 }.allSatisfy(kept.contains)
                }
                guard !sc.clipboard.isEmpty else { throw EditError.emptyClip }
            }
            boards.append(sc)
        }
        var end = time
        try edit(host) { tl in
            var at = time.snapped(to: fd)
            var lanes: [TrackKind: Int]?
            if let kind = newTrack {
                let id = tl.addTrack(kind: kind)
                lanes = tl.laneLanes(forDrop: id, in: boards[0].clipboard)
            } else if let v = videoTrack {
                lanes = tl.laneLanes(forDrop: v, in: boards[0].clipboard)
            }
            for sc in boards {
                let place = at
                try tl.placeSequenceClips(sc, at: place, lanes: lanes, insert: mode == .insert)
                at = (place + sc.span).ceiled(to: fd)
            }
            end = at
        }
        return end
    }
}

extension Timeline {
    /// The lane (per kind) the lowest used lane of the sequence lands on when it is dropped on `track` (the `to` of `paste`).
    /// A video track also decides the audio lane (same ordinal); an audio track only the audio one.
    func laneLanes(forDrop track: Track.ID, in cb: TimelineClipboard) -> [TrackKind: Int]? {
        guard let t = self.track(track) else { return nil }
        let same = tracks.filter { $0.kind == t.kind }
        guard let index = same.firstIndex(where: { $0.id == track }) else { return nil }
        var out: [TrackKind: Int] = [:]
        if cb.lowestLane(t.kind) != nil { out[t.kind] = index }      // the first used lane lands on the track, offsets stay
        if t.kind == .video, cb.lowestLane(.audio) != nil { out[.audio] = index }
        return out
    }

    /// One sequence placed at `place`: overwrite, or insert that opens a gap of the whole `span` first (so leading and
    /// trailing gaps of the sequence ripple too) and then fills it. Fast Cut: runs in `magneticEdit`; an insert landing on
    /// the main track opens it (at most at its end, no hole), attached clips follow their hosts; anything else is an
    /// overwrite there and the attached clips stay on their frame (the new clips yield to them off the main track).
    mutating func placeSequenceClips(_ sc: Project.SequenceClips, at place: Time, lanes: [TrackKind: Int]?, insert: Bool) throws {
        let cb = sc.clipboard
        guard isFastCut, let mi = mainTrackIndex else {
            guard insert else { _ = try paste(cb, at: place, lanes: lanes); return }
            try openSpan(sc.span, at: place, for: cb, lanes: lanes)
            try paste(cb, at: place, lanes: lanes)
            return
        }
        let onMain = landingTracks(of: cb, lanes: lanes).contains(mi)
        let at = onMain ? min(place, mainTrackEnd) : place
        if insert && onMain {
            try magneticEdit { t in
                try t.openSpan(sc.span, at: at, for: cb, lanes: lanes)
                try t.paste(cb, at: at, lanes: lanes)
            }
        } else {
            try magneticEdit(stay: .all) { _ = try $0.paste(cb, at: at, lanes: lanes) }
        }
    }

    /// Pushes everything at or after `t` later by `length` on the tracks the clipboard lands on and on every ripple track
    /// (clips crossing `t` are split), like `insert`. Refuses locked target tracks.
    mutating func openSpan(_ length: Time, at t: Time, for cb: TimelineClipboard, lanes: [TrackKind: Int]?) throws {
        let t = max(t.ceiled(to: frameDuration), .zero)
        let targets = landingTracks(of: cb, lanes: lanes)
        if targets.contains(where: { tracks[$0].isLocked }) { throw EditError.trackLocked }
        var work = tracks
        var relinks: [UUID: UUID] = [:]
        for i in work.indices where targets.contains(i) || work[i].followsRipple {
            try work[i].split(at: t, relinks: &relinks)
            work[i].shift(from: t, by: length)
        }
        tracks = work
        openCaptionGap(at: t, by: length)
    }

    /// Indices of the tracks the clipboard's clips land on (lanes beyond the existing tracks are not there yet).
    func landingTracks(of cb: TimelineClipboard, lanes: [TrackKind: Int]?) -> Set<Int> {
        var targets = Set<Int>()
        for k in [TrackKind.video, .audio] {
            guard let low = cb.lowestLane(k) else { continue }
            let shift = (lanes?[k] ?? low) - low
            let same = tracks.indices.filter { tracks[$0].kind == k }
            for e in cb.entries where e.clip.kind == k {
                let lane = max(e.lane + shift, 0)
                if lane < same.count { targets.insert(same[lane]) }
            }
        }
        return targets
    }
}
