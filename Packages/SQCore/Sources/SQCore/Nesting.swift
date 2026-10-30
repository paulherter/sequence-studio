import Foundation

/// Nested sequences: a clip whose `sequence` is set plays another timeline of the project.
extension Project {
    public func timeline(_ id: Timeline.ID) -> Timeline? { timelines.first { $0.id == id } }

    /// Sequences nested directly in `id` (one level).
    public func nestedSequences(of id: Timeline.ID) -> Set<Timeline.ID> {
        guard let t = timeline(id) else { return [] }
        return Set(t.tracks.flatMap(\.clips).compactMap(\.sequence))
    }

    /// Every sequence reachable from `id` through nesting (not including `id` unless it is on a cycle).
    public func reachableSequences(from id: Timeline.ID) -> Set<Timeline.ID> {
        var seen = Set<Timeline.ID>()
        var stack = Array(nestedSequences(of: id))
        while let n = stack.popLast() {
            if seen.insert(n).inserted { stack.append(contentsOf: nestedSequences(of: n)) }
        }
        return seen
    }

    /// True if `host` may not contain `sequence`: it is the same sequence or contains `host` somewhere inside.
    public func wouldCreateCycle(nesting sequence: Timeline.ID, in host: Timeline.ID) -> Bool {
        sequence == host || reachableSequences(from: sequence).contains(host)
    }

    /// True if no sequence contains itself, directly or indirectly.
    public var isNestingAcyclic: Bool { timelines.allSatisfy { !reachableSequences(from: $0.id).contains($0.id) } }

    /// Runs any timeline edit on a copy and commits it only if the result is valid: throws the edit's own
    /// error, or `.nestingCycle` when a nested clip would make `id` contain itself. Use this for every edit
    /// that can place clips (insert, overwrite, paste, move between tracks).
    public mutating func edit(_ id: Timeline.ID, _ body: (inout Timeline) throws -> Void) throws {
        guard let i = timelines.firstIndex(where: { $0.id == id }) else { throw EditError.timelineNotFound }
        var work = self
        // A nested clip's media is the inner sequence as it is now, not as it was when nested.
        for ti in work.timelines[i].tracks.indices {
            for var c in work.timelines[i].tracks[ti].clips {
                guard let inner = c.sequence, let d = timeline(inner)?.duration, c.mediaDuration != d else { continue }
                c.mediaDuration = d
                work.timelines[i].tracks[ti].replace(c)
            }
        }
        try body(&work.timelines[i])
        work.timelines[i].pruneTransitions()
        if work.reachableSequences(from: id).contains(id) { throw EditError.nestingCycle }
        self = work
    }

    /// Clips for placing `sequence` into another timeline at `start`: a video clip and, if the sequence has audio
    /// tracks with clips, a linked audio clip. Plays the whole sequence (0 ... duration). Nil for an unknown or
    /// empty sequence. Place them with `edit(_:_:)` so cycles are refused.
    public func sequenceClips(of sequence: Timeline.ID, at start: Time) -> [Clip]? {
        guard let t = timeline(sequence), t.duration > .zero else { return nil }
        let range = TimeRange(start: .zero, duration: t.duration)
        let hasAudio = t.tracks.contains { $0.kind == .audio && !$0.clips.isEmpty }
        let link: UUID? = hasAudio ? UUID() : nil
        func make(_ kind: TrackKind) -> Clip {
            var c = Clip(name: t.name, media: sequence, kind: kind, source: range, start: start, link: link,
                         mediaDuration: t.duration, sequence: sequence)
            c.angle = t.angles?.firstChoice(for: kind)      // an Angles sequence is placed as an Angles clip
            return c
        }
        return hasAudio ? [make(.video), make(.audio)] : [make(.video)]
    }

    // MARK: Nest

    /// Combine: replaces the selected clips (and their linked partners) with one nested-sequence clip.
    /// - The new sequence has the outer timeline's format, one track per involved track (same kind, name and
    ///   flags, in the same order) and the clips shifted so the earliest starts at 0.
    /// - The outer timeline gets a nested video clip on the lowest involved video track and, if audio was nested,
    ///   a linked nested audio clip on the lowest involved audio track, both covering earliest start ... latest end.
    /// - The sequence is filed in the bin of the outer sequence (root if it has none) and named
    ///   "Combined NN" unless `name` is given.
    /// Throws `.trackLocked` if a clip is on a locked track, `.collision` if another (unselected) clip on a
    /// target track lies inside the nested span, `.clipNotFound` / `.timelineNotFound` / `.emptyClip` otherwise.
    /// Returns the new sequence's ID.
    @discardableResult
    public mutating func nest(clips ids: [Clip.ID], in timelineID: Timeline.ID, name: String? = nil) throws -> Timeline.ID {
        guard let ti = timelines.firstIndex(where: { $0.id == timelineID }) else { throw EditError.timelineNotFound }
        guard !ids.isEmpty else { throw EditError.emptyClip }
        var tl = timelines[ti]
        var selected = Set<Clip.ID>()
        for id in ids { for m in try tl.linkedGroup(id) { selected.insert(m.clip.id) } }

        let involved = tl.tracks.indices.filter { i in tl.tracks[i].clips.contains { selected.contains($0.id) } }
        if involved.contains(where: { tl.tracks[$0].isLocked }) { throw EditError.trackLocked }
        let picked = involved.flatMap { i in tl.tracks[i].clips.filter { selected.contains($0.id) } }
        guard let s = picked.map(\.start).min(), let e = picked.map({ $0.timeline.end }).max() else {
            throw EditError.clipNotFound
        }
        let span = TimeRange(start: s, end: e)

        // Inner sequence.
        var inner: [Track] = []
        var trackIDs: [Track.ID: Track.ID] = [:]
        for i in involved {
            let t = tl.tracks[i]
            var clips: [Clip] = []
            for var c in t.clips where selected.contains(c.id) { c.start = c.start - s; clips.append(c) }
            // Transitions between nested clips (and fades on them) go inside; one that joins a nested clip to a clip
            // left outside has no counterpart there and is dropped (below).
            let carried = t.transitions.filter { tr in
                (tr.outgoing.map(selected.contains) ?? true) && (tr.incoming.map(selected.contains) ?? true)
            }
            inner.append(Track(kind: t.kind, clips: clips, syncLock: t.syncLock, name: t.name, isVisible: t.isVisible,
                               isMuted: t.isMuted, isSolo: t.isSolo, height: t.height, transitions: carried))
            trackIDs[t.id] = inner[inner.count - 1].id
        }
        let seqID = UUID()
        let seqName = name ?? nextNestedName()
        var seq = Timeline(id: seqID, name: seqName, format: tl.format, tracks: inner)
        // The inner sequence gets the outer variants (same ids), so the nested clips keep their overrides and the
        // variant picture stays the same (Evaluation renders the inner sequence in the variant of the same id).
        seq.variants = tl.variants
        // Picture masks follow their matte track inside; one whose track stays outside reads nothing.
        seq.remapPictureMasks(trackIDs: trackIDs)
        // Fast Cut attachments inside keep a host nested along; one whose host stays outside is dropped.
        seq.dropAttachmentsToMissingHosts()

        // Outer timeline: remove the clips, place the nested clip(s).
        for i in involved { for id in selected { tl.tracks[i].remove(id) } }
        let videoTarget = involved.first { tl.tracks[$0].kind == .video }
        let audioTarget = involved.first { tl.tracks[$0].kind == .audio }
        let link: UUID? = (videoTarget != nil && audioTarget != nil) ? UUID() : nil
        var nestedVideo: Clip.ID?
        for (target, kind) in [(videoTarget, TrackKind.video), (audioTarget, .audio)] {
            guard let target else { continue }
            if tl.tracks[target].clips.contains(where: { $0.timeline.overlaps(span) }) { throw EditError.collision }
            let c = Clip(name: seqName, media: seqID, kind: kind, source: TimeRange(start: .zero, duration: span.duration),
                         start: s, link: link, mediaDuration: span.duration, sequence: seqID)
            try tl.tracks[target].overwrite(c)
            if kind == .video { nestedVideo = c.id }
        }
        // Outside clips attached to a nested clip now belong to the nested clip (the rest keep their hosts).
        if let nestedVideo {
            tl.remapAttachments(Dictionary(uniqueKeysWithValues: selected.map { ($0, nestedVideo) }), keepUnmapped: true)
        }

        // Transitions naming a removed clip would dangle; only those go (others, even inactive ones, stay).
        for i in involved {
            tl.tracks[i].transitions.removeAll { tr in
                tr.outgoing.map(selected.contains) == true || tr.incoming.map(selected.contains) == true
            }
        }
        timelines[ti] = tl
        timelines.append(seq)
        let bin = rootBin.parent(of: .sequence(timelineID)) ?? rootBin.id
        rootBin.modify(bin) { $0.children.append(.sequence(seqID)) }
        return seqID
    }

    private func nextNestedName() -> String {
        let names = Set(timelines.map(\.name))
        var n = 1
        while names.contains(String(format: "Combined %02d", n)) { n += 1 }
        return String(format: "Combined %02d", n)
    }

    // MARK: Evaluation

    /// `Timeline.videoLayers(at:)` with nested clips resolved against this project's timelines.
    public func videoLayers(at t: Time, in timeline: Timeline.ID) -> [LayerRequest] {
        self.timeline(timeline)?.videoLayers(at: t, sequences: { self.timeline($0) }) ?? []
    }

    /// `Timeline.audioSegments(in:)` with nested clips resolved against this project's timelines.
    public func audioSegments(in range: TimeRange, of timeline: Timeline.ID) -> [AudioSegment] {
        self.timeline(timeline)?.audioSegments(in: range, sequences: { self.timeline($0) }) ?? []
    }
}
