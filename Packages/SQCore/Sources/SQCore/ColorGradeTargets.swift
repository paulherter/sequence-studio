import Foundation

// Color target bar (DECISIONS 2026-10-03 "Color grading UI", variant E step 1).
//
// Source-linked grades: a picture clip is "Linked" by default, i.e. its grade is the grade of every clip of the same
// source file. The link itself is the COLOR-GRADE-LINKS `Clip.gradeLink` (denormalised copies, propagated after each
// edit); what is new is that the link forms on its own when a linked clip is edited (`prepareSourceGradeEdit`, run in
// the same undo step as the edit) and that "Linked" can be switched off per clip (`Clip.gradeIndependent`, v47).
//
// Who joins on an edit of clip X (not independent):
// - X has no link but other clips of its source share one: X adopts that shared grade first when it has no grade of
//   its own (or the same one); when X carries a different grade of its own it counts as independent (it is marked so)
//   and the edit changes only X. An old project's separately graded clips are never overwritten this way.
// - Every other unlinked, not independent clip of the source joins when it has no grade or the same grade as the
//   shared one; one graded differently keeps its grade and is marked independent.
// - Independent clips and clips in another link are never touched.
//
// The Timeline grade: one Adjustment Layer per sequence, marked by its generator payload (`GeneratorRef.sequenceGrade`,
// no new file field), on its own new top video track over the whole sequence. Created on the first Timeline edit,
// reused (and stretched to the sequence end) after.

extension Clip {
    /// "Linked" switched off in the Color target bar: this clip keeps its own grade, source linking skips it.
    public var gradeIndependent: Bool {
        get { gradeIndependentStore == true }
        set { gradeIndependentStore = newValue ? true : nil }
    }

    /// Takes part in source grade linking: a picture clip of media (no generator, adjustment layer or nested sequence).
    public var isSourceGradeable: Bool { acceptsColor && !isGenerator && !isNested }

    /// The sequence's Timeline grade layer (see `Project.ensureSequenceGrade`).
    public var isSequenceGrade: Bool { isAdjustment && generator?.payload == GeneratorRef.sequenceGradePayload }
}

extension GeneratorRef {
    /// Payload that marks an Adjustment Layer as the sequence's Timeline grade (the renderer ignores adjustment payloads).
    public static let sequenceGradePayload = Data("sq.sequenceGrade".utf8)
    public static var sequenceGrade: GeneratorRef { GeneratorRef(kind: adjustment, payload: sequenceGradePayload) }
}

extension Timeline {
    /// The Timeline grade layer of this sequence, nil before the first Timeline edit.
    public var sequenceGradeClip: Clip? {
        for t in tracks where t.kind == .video { if let c = t.clips.first(where: \.isSequenceGrade) { return c } }
        return nil
    }
}

extension Project {
    /// What an edit of a linked clip does to its source's other clips (see the file comment).
    struct SourceGradePlan {
        /// A member of the source's shared grade that `clip` adopts first (nil = it is the source itself or linked).
        var adoptFrom: Clip.ID?
        /// The link the edit belongs to after the plan (nil = a new one is made if anything joins).
        var link: UUID?
        var joiners: [Clip.ID] = []
        var keepOwn: [Clip.ID] = []
        /// `clip` carries its own grade next to a different shared one: it is independent, nothing joins.
        var selfIndependent = false
    }

    func sourceGradePlan(_ id: Clip.ID) -> SourceGradePlan? {
        guard let x = anyClip(id), x.isSourceGradeable, !x.gradeIndependent else { return nil }
        let siblings = allClips().filter { $0.id != id && $0.media == x.media && $0.isSourceGradeable && !$0.gradeIndependent }
        func same(_ a: [ClipEffect], _ b: [ClipEffect]) -> Bool { Clip.comparableGrade(a) == Clip.comparableGrade(b) }
        var plan = SourceGradePlan(link: x.gradeLink)
        var reference = x.baseGradeEffects
        if x.gradeLink == nil, let g = siblings.first(where: { $0.gradeLink != nil }) {
            guard x.baseGradeEffects.isEmpty || same(x.baseGradeEffects, g.baseGradeEffects) else {
                plan.selfIndependent = true
                return plan
            }
            plan.adoptFrom = g.id
            plan.link = g.gradeLink
            reference = g.baseGradeEffects
        }
        for s in siblings where s.gradeLink == nil {
            if s.baseGradeEffects.isEmpty || same(s.baseGradeEffects, reference) { plan.joiners.append(s.id) }
            else { plan.keepOwn.append(s.id) }
        }
        return plan
    }

    /// The target bar's "Linked" state: true when edits of `id` go to its source's shared grade. False for clips that
    /// have no source (adjustment layers, generators, nested sequences, audio) and for independent ones.
    public func isGradeLinkedToSource(_ id: Clip.ID) -> Bool {
        guard let p = sourceGradePlan(id) else { return false }
        return !p.selfIndependent
    }

    /// How many clips an edit of `id` grades (itself included): 1 when it is not linked.
    public func sourceGradeShareCount(_ id: Clip.ID) -> Int {
        guard let plan = sourceGradePlan(id), !plan.selfIndependent else { return 1 }
        var ids = Set(plan.joiners).union([id])
        if let l = plan.link { ids.formUnion(allClips().filter { $0.gradeLink == l }.map(\.id)) }
        return ids.count
    }

    /// Runs before a color edit of `id` (same undo step): forms the source link the edit goes to (see the file
    /// comment). True when something changed.
    @discardableResult
    public mutating func prepareSourceGradeEdit(_ id: Clip.ID) -> Bool {
        guard let plan = sourceGradePlan(id) else { return false }
        var changed = false
        func mark(_ ids: Set<Clip.ID>) {
            guard !ids.isEmpty else { return }
            forEachClipInPlace { c in
                guard ids.contains(c.id) else { return }
                c.gradeIndependent = true
                c.gradeLink = nil
            }
            changed = true
        }
        if plan.selfIndependent { mark([id]); return true }
        if let g = plan.adoptFrom, linkGrades([id], source: g) != nil { changed = true }
        mark(Set(plan.keepOwn))
        if !plan.joiners.isEmpty, linkGrades(Set(plan.joiners), source: id) != nil { changed = true }
        return changed
    }

    /// The target bar's "Linked" switch. Off: `id` leaves its link and keeps its grade; later edits change only it.
    /// On: it adopts the shared grade of its source again when one exists (else it is plain linked: the next edit links
    /// its source). False when nothing changed or `id` has no source.
    @discardableResult
    public mutating func setGradeLinkedToSource(_ id: Clip.ID, _ on: Bool) -> Bool {
        guard let x = anyClip(id), x.isSourceGradeable else { return false }
        if !on {
            guard !x.gradeIndependent || x.gradeLink != nil else { return false }
            forEachClipInPlace { c in
                guard c.id == id else { return }
                c.gradeIndependent = true
                c.gradeLink = nil
            }
            dissolveLonelyGradeLinks()    // a link left with one member is no link
            return true
        }
        guard x.gradeIndependent else { return false }
        forEachClipInPlace { c in if c.id == id { c.gradeIndependent = false } }
        // Adopt the source's shared grade: a linked sibling's, else (its link dissolved when this clip left) a graded one's.
        let siblings = allClips().filter { $0.id != id && $0.media == x.media && $0.isSourceGradeable && !$0.gradeIndependent }
        if let g = siblings.first(where: { $0.gradeLink != nil }) ?? siblings.first(where: { !$0.baseGradeEffects.isEmpty }) {
            linkGrades([id], source: g.id)
        }
        return true
    }

    /// Any clip with "Linked" switched off: the file needs v47.
    public var containsIndependentGrades: Bool { allClips().contains(where: \.gradeIndependent) }

    // MARK: Timeline grade

    /// The Timeline grade layer of `timeline`: created on a new top video track over the whole sequence when it does not
    /// exist, else returned. An existing layer is kept on top (its track moves above video tracks added later, when it
    /// holds nothing else) and its end follows the sequence end when the sequence grew and its track is free there. Its
    /// start never moves, so clip-local keys and ranges stay where they are and a deliberate trim of its start is kept;
    /// nothing changes while coverage and order are already right (a slider drag touches only the grade).
    /// Throws `.timelineNotFound`, or `.emptyClip` for a sequence without clips.
    @discardableResult
    public mutating func ensureSequenceGrade(in timeline: Timeline.ID) throws -> Clip.ID {
        guard let ti = timelines.firstIndex(where: { $0.id == timeline }) else { throw EditError.timelineNotFound }
        let t = timelines[ti]
        let end = t.tracks.flatMap(\.clips).filter { !$0.isSequenceGrade }.map(\.timeline.end).max() ?? .zero
        if let g = t.sequenceGradeClip,
           var tr = t.tracks.firstIndex(where: { $0.clips.contains { $0.id == g.id } }) {
            // Keep it the topmost video track.
            if let lastVideo = t.tracks.lastIndex(where: { $0.kind == .video }), lastVideo > tr,
               timelines[ti].tracks[tr].clips.count == 1, !timelines[ti].tracks[tr].isLocked {
                let track = timelines[ti].tracks.remove(at: tr)
                timelines[ti].tracks.insert(track, at: lastVideo)
                tr = lastVideo
            }
            let track = timelines[ti].tracks[tr]
            guard g.timeline.end < end, !track.isLocked,
                  !track.clips.contains(where: { $0.id != g.id && $0.timeline.start < end && $0.timeline.end > g.timeline.end })
            else { return g.id }
            var c = g
            c.source = TimeRange(start: g.source.start, duration: end - g.start)
            timelines[ti].tracks[tr].replace(c)
            return g.id
        }
        guard end > .zero else { throw EditError.emptyClip }
        let track = timelines[ti].addTrack(kind: .video)
        return try addGeneratorClip(kind: GeneratorRef.adjustment, payload: GeneratorRef.sequenceGradePayload,
                                    name: "Timeline Grade", in: timeline, at: .zero, track: track, duration: end)
    }
}
