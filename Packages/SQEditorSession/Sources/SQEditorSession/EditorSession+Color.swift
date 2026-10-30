import Foundation
import SQCore

/// The color clipboard: the Color effects of the last clip the user copied from the color panel (keys and the effect
/// switch included; empty = no grade). Per app run.
@MainActor
public final class ColorClipboard {
    public static let shared = ColorClipboard()
    public private(set) var effects: [ClipEffect]?
    /// The copied clip's Color Graph (nil: it had none; a paste then turns the target's graph off).
    public private(set) var graph: ColorGraph?
    public var hasColor: Bool { effects != nil }
    public func copy(_ fx: [ClipEffect], graph: ColorGraph? = nil) { effects = fx; self.graph = graph }

    /// Eight grade memories (slots 1...8, per app run): a snapshot of the clipboard. Loading one puts it on the
    /// clipboard, so the normal paste (Replace or Add on top) places it.
    public static let memorySlots = 8
    public private(set) var memories: [Int: (effects: [ClipEffect], graph: ColorGraph?)] = [:]
    public func hasMemory(_ slot: Int) -> Bool { memories[slot] != nil }
    /// Saves the clipboard's grade into `slot`; false when the clipboard is empty or the slot is out of range.
    @discardableResult
    public func saveMemory(_ slot: Int) -> Bool {
        guard (1...Self.memorySlots).contains(slot), let e = effects else { return false }
        memories[slot] = (e, graph)
        return true
    }
    @discardableResult
    public func loadMemory(_ slot: Int) -> Bool {
        guard let m = memories[slot] else { return false }
        copy(m.effects, graph: m.graph)
        return true
    }
}

extension EditorSession {
    /// Pastes the Color effects `fx` (keys and switches kept) onto the selected picture clips (or `ids`), in place of
    /// theirs: one undo step for all of them. Clips that take no color (audio, nested sequences, text and other
    /// generators: the renderer does not grade them) are skipped. The target keeps its footage interpretation. A
    /// "Linked" target grades its source's clips too (same rule as a panel edit, `Project.prepareSourceGradeEdit`).
    /// Returns how many clips changed.
    @discardableResult
    /// `graph`: `.some` = the copied clip's Color Graph goes along (`Clip.applyCopiedGraph`: the target looks like the
    /// copy, Pro or Simple); nil = the target's graph stays as it is.
    public func pasteColor(effects fx: [ClipEffect], graph: ColorGraph?? = nil, to ids: Set<Clip.ID>? = nil,
                           onTop: Bool = false) -> Int {
        func comparable(_ e: [ClipEffect]) -> [ClipEffect] { e.map { var c = $0; c.id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)); return c } }
        return sourceLinkedColorEdit("Paste Color", ids ?? selection) { clip in
            let before = clip
            if onTop { clip.addColorGradeOnTop(fx) }   // add on top: the target's graph stays as it is
            else {
                if comparable(clip.colorGradeEffects) != comparable(fx) { clip.replaceColorGrade(with: fx) }
                if case .some(let g) = graph { clip.applyCopiedGraph(g) }
            }
            return clip != before
        }
    }

    /// Edits the picture clips `ids` of the active sequence with `body` in one undo step, each one first joined to its
    /// source's grade while "Linked" (`Project.prepareSourceGradeEdit`), links propagated from the edited clips. Returns
    /// how many clips `body` changed; nothing is committed when none.
    private func sourceLinkedColorEdit(_ name: String, _ ids: Set<Clip.ID>, _ body: (inout Clip) -> Bool) -> Int {
        guard let tl = activeTimelineID, let t = activeTimeline else { return 0 }
        let order = t.tracks.filter { $0.kind == .video }.flatMap(\.clips)
            .filter { ids.contains($0.id) && $0.acceptsColor }.map(\.id)
        // Dry run: nothing to commit when no clip changes.
        let any = order.contains { id in
            guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { return false }
            return body(&c)
        }
        guard any else { return 0 }
        var changed = 0
        do {
            try perform(name) { p in
                for id in order { p.prepareSourceGradeEdit(id) }
                let mid = p
                changed = 0
                try p.edit(tl) { t in
                    for id in order {
                        guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), body(&c) else { continue }
                        try t.replaceClip(c)
                        changed += 1
                    }
                }
                // The edited clips are the sources of their links (the clips that joined above changed too).
                p.propagateGradeLinks(from: mid)
            }
        } catch {
            setError(Self.message(for: error))
            return 0
        }
        return changed
    }

    /// Pastes a static grade (its Color effects; the neutral default = no grade).
    @discardableResult
    public func pasteColor(_ other: ClipColor, to ids: Set<Clip.ID>? = nil) -> Int {
        let fx = other.effects == ClipColor.defaultEffects ? [] : other.effects.map(ClipEffect.colorGrade)
        return pasteColor(effects: fx, to: ids)
    }

    /// The panel's Reset: the clip's Color effects are removed (keys included) and the embedded camera LUT is used
    /// again; the source interpretation stays. While "Linked", its source's clips are reset with it (same rule as a
    /// panel edit). One undo step; nothing when the clip has no grade.
    @discardableResult
    public func resetColor(of id: Clip.ID) -> Bool {
        sourceLinkedColorEdit("Reset Color", [id]) { clip in
            let before = clip
            clip.replaceColorGrade(with: [])
            clip.colorGraph = nil
            clip.footageColor.useEmbeddedLUT = true
            return clip != before
        } > 0
    }
}

// MARK: - Grade links and range grades (COLOR-GRADE-LINKS)

extension EditorSession {
    /// Links the selected picture clips (plus `source`) to `source`'s grade: one undo step. nil when fewer than two
    /// clips can take color.
    @discardableResult
    public func linkGrades(source: Clip.ID, with ids: Set<Clip.ID>? = nil) -> UUID? {
        let targets = ids ?? selection
        var link: UUID?
        perform("Link Grades") { link = $0.linkGrades(targets, source: source) }
        return link
    }

    /// Links every picture clip of `id`'s media in the project to `id`'s grade (one undo step).
    @discardableResult
    public func linkAllClipsOfSource(_ id: Clip.ID) -> UUID? {
        var link: UUID?
        perform("Link Grades") { link = $0.linkAllClipsOfSource(id) }
        return link
    }

    /// Takes `ids` (default: the selection) out of their grade links; each keeps its grade.
    @discardableResult
    public func unlinkGrades(_ ids: Set<Clip.ID>? = nil) -> Bool {
        let targets = ids ?? selection
        guard project.timelines.contains(where: { $0.tracks.contains { $0.clips.contains { targets.contains($0.id) && $0.gradeLink != nil } } })
        else { return false }
        perform("Unlink Grades") { _ = $0.unlinkGrades(targets) }
        return true
    }

    /// The clips sharing `id`'s grade (empty when it is not linked).
    public func gradeLinkMembers(of id: Clip.ID) -> [Clip.ID] { project.gradeLinkMembers(of: id) }

    /// The clip-local range a new range grade on `clip` covers: the sequence In/Out where it overlaps the clip, else from
    /// the playhead (or the clip start when the playhead is outside it) to the clip end.
    func rangeGradeSpan(for clip: Clip) -> TimeRange {
        if let io = activeTimeline?.inOut, let x = io.intersection(clip.timeline), x.duration > .zero {
            return TimeRange(start: x.start - clip.start, duration: x.duration)
        }
        let from = clip.timeline.contains(playhead) ? playhead - clip.start : .zero
        return TimeRange(start: from, end: clip.duration)
    }

    /// Adds a range grade to `id` (see `rangeGradeSpan`): one undo step. Returns the new Color effect's id.
    @discardableResult
    public func addRangeGrade(to id: Clip.ID) -> ClipEffect.ID? {
        guard var clip = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
              let fx = clip.addRangeGrade(rangeGradeSpan(for: clip)) else { return nil }
        return attempt("Add Range Grade") { try $0.replaceClip(clip) } ? fx : nil
    }

    /// Sets the range of Color effect `effect` on `id` to the In/Out span (`rangeGradeSpan`), or to the whole clip.
    @discardableResult
    public func setColorRange(of effect: ClipEffect.ID, in id: Clip.ID, wholeClip: Bool) -> Bool {
        guard var clip = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
              clip.setColorRange(effect, wholeClip ? nil : rangeGradeSpan(for: clip)) else { return false }
        return attempt(wholeClip ? "Grade Whole Clip" : "Set Grade Range") { try $0.replaceClip(clip) }
    }
}

// MARK: - Color target bar (DECISIONS 2026-10-03 "Color grading UI")

extension EditorSession {
    private func findClip(_ id: Clip.ID, in t: Timeline) -> Clip? { t.tracks.lazy.flatMap(\.clips).first { $0.id == id } }

    /// A Color panel edit of clip `id`: while the clip is "Linked", its source's clips first join its grade
    /// (`Project.prepareSourceGradeEdit`), then `body` edits the clip; links propagate. One undo step; edits of one
    /// gesture (`continuesGesture`) merge. False when `body` refuses (nothing changes) or nothing changed.
    @discardableResult
    public func editClipColor(_ id: Clip.ID, name: String = "Color", continuesGesture: Bool,
                              _ body: (inout Clip) -> Bool) -> Bool {
        guard let tl = activeTimelineID else { return false }
        if !continuesGesture { gestureCounter += 1 }
        return commitColorEdit(name, key: "clip:\(id):\(gestureCounter)", prepare: { p in
            p.prepareSourceGradeEdit(id)
            return (tl, id)
        }, body: body)
    }

    /// A Color panel edit of the Timeline grade of the active sequence: the grade layer is created on the first edit
    /// (`Project.ensureSequenceGrade`) and reused after, in the same undo step as the edit.
    @discardableResult
    public func editSequenceGrade(name: String = "Timeline Grade", continuesGesture: Bool,
                                  _ body: (inout Clip) -> Bool) -> Bool {
        guard let tl = activeTimelineID else { return false }
        if !continuesGesture { gestureCounter += 1 }
        return commitColorEdit(name, key: "sequenceGrade:\(tl):\(gestureCounter)", prepare: { p in
            (tl, try p.ensureSequenceGrade(in: tl))
        }, body: body)
    }

    private struct ColorEditRefused: Error {}

    private func commitColorEdit(_ name: String, key: String,
                                 prepare: (inout Project) throws -> (Timeline.ID, Clip.ID),
                                 body: (inout Clip) -> Bool) -> Bool {
        let before = history.current
        do {
            try perform(name, coalescing: key) { p in
                let (tl, id) = try prepare(&p)
                let mid = p
                try p.edit(tl) { t in
                    guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { throw EditError.clipNotFound }
                    guard body(&c) else { throw ColorEditRefused() }
                    try t.replaceClip(c)
                }
                // The edited clip is the source of its link (the clips that joined in `prepare` changed too).
                p.propagateGradeLinks(from: mid)
            }
        } catch is ColorEditRefused {
            return false
        } catch {
            setError(Self.message(for: error))
            return false
        }
        return history.current != before
    }

    /// The target bar's "Linked" switch for clip `id` (one undo step). See `Project.setGradeLinkedToSource`.
    @discardableResult
    public func setGradeLinkedToSource(_ id: Clip.ID, _ on: Bool) -> Bool {
        guard project.timelines.contains(where: { findClip(id, in: $0) != nil }) else { return false }
        var p = project
        guard p.setGradeLinkedToSource(id, on) else { return false }
        perform(on ? "Link Grade to Source" : "Unlink Grade") { _ = $0.setGradeLinkedToSource(id, on) }
        return true
    }

    /// Pastes Color effects onto the Timeline grade (created when missing): one undo step.
    @discardableResult
    public func pasteSequenceGrade(effects fx: [ClipEffect], graph: ColorGraph?? = nil, onTop: Bool = false) -> Bool {
        editSequenceGrade(name: "Paste Color", continuesGesture: false) { c in
            let before = c
            if onTop { c.addColorGradeOnTop(fx) } else {
                c.replaceColorGrade(with: fx)
                if case .some(let g) = graph { c.applyCopiedGraph(g) }
            }
            return c != before
        }
    }
}

// MARK: - Interpret As on many clips

extension EditorSession {
    /// Sets "Interpret As" (nil = Automatic) on every clip in `ids` that is not already set to it: one undo step.
    /// Returns how many clips changed (0 = no step).
    @discardableResult
    public func setInterpretation(_ space: ColorSpaceID?, for ids: [Clip.ID]) -> Int {
        guard let timeline = activeTimeline else { return 0 }
        let wanted = Set(ids)
        let targets = timeline.tracks.flatMap(\.clips).filter { wanted.contains($0.id) && $0.footageColor.source != space }.map(\.id)
        guard !targets.isEmpty else { return 0 }
        let done = attempt("Interpret As") { t in
            for id in targets {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { continue }
                c.footageColor.source = space
                try t.replaceClip(c)
            }
        }
        return done ? targets.count : 0
    }
}
