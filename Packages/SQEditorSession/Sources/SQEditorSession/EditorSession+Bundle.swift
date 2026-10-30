import Foundation
import SQCore

/// Bundle / Unbundle (Premiere's Clip > Group, v57), Make Subclip and Edit Original targets.
extension EditorSession {
    // MARK: Bundle

    /// Clip > Bundle is enabled with two or more units selected (a linked group or an existing bundle counts once);
    /// Unbundle with any bundled clip.
    public var bundleMenuState: (canBundle: Bool, canUnbundle: Bool) {
        guard let t = activeTimeline else { return (false, false) }
        let clips = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        let units = Set(clips.map { $0.bundle ?? $0.link ?? $0.id })
        return (units.count >= 2, clips.contains { $0.bundle != nil })
    }

    /// Opt+Cmd+G: bundles the selected clips (and their linked partners); the whole bundle becomes the selection.
    @discardableResult
    public func bundleSelection() -> Bool {
        guard bundleMenuState.canBundle else { return false }
        let ids = selection
        var made: UUID?
        guard attempt("Bundle") { made = try $0.bundle(ids) }, let b = made, let t = activeTimeline else { return false }
        select(clips: Set(t.tracks.flatMap(\.clips).filter { $0.bundle == b }.map(\.id)))
        return true
    }

    /// Opt+Shift+Cmd+G: breaks up every bundle a selected clip belongs to. The clips stay selected.
    @discardableResult
    public func unbundleSelection() -> Bool {
        guard bundleMenuState.canUnbundle else { return false }
        let ids = selection
        return attempt("Unbundle") { _ = try $0.unbundle(ids) }
    }

    // MARK: Make Subclip

    /// Clip > Make Subclip: the In/Out range of `media` (an open end runs to the media's edge) becomes a new Project item
    /// filed after it. Needs an In or an Out. Returns the new item, nil (with `lastError` set) when refused.
    @discardableResult
    public func makeSubclip(of media: MediaRef.ID, name: String? = nil) -> MediaRef.ID? {
        guard let ref = project.media(media) else { return nil }
        let marks = project.sourceMarks(for: media)
        guard !marks.isEmpty else { setError("Set an In or Out point in the Source monitor first."); return nil }
        let total = ref.duration ?? marks.markOut ?? .zero
        guard let range = Timeline.sourceEditRange(marks: marks, total: total) else {
            setError("The In to Out range is empty."); return nil
        }
        var made: MediaRef.ID?
        do { try perform("Make Subclip") { made = try $0.makeSubclip(of: media, range: range, name: name) } }
        catch { setError(Self.message(for: error)); return nil }
        return made
    }

    // MARK: Edit Original

    /// Files of the selected timeline clips that have media (text, generators and nested sequences have none), each once,
    /// in track order. The app opens them in their default app (Clip > Edit Original).
    /// Media of the selected clips that have a file, each once, in track order (Reveal in Project).
    public var mediaOfSelection: [MediaRef.ID] {
        guard let t = activeTimeline else { return [] }
        var seen = Set<MediaRef.ID>(), out: [MediaRef.ID] = []
        for c in t.tracks.flatMap(\.clips) where selection.contains(c.id) && !c.isGenerator && !c.isNested {
            guard project.media(c.media) != nil, seen.insert(c.media).inserted else { continue }
            out.append(c.media)
        }
        return out
    }

    public var originalFilesOfSelection: [String] {
        guard let t = activeTimeline else { return [] }
        var seen = Set<String>(), out: [String] = []
        for c in t.tracks.flatMap(\.clips) where selection.contains(c.id) && !c.isGenerator && !c.isNested {
            guard let m = project.media(c.media), seen.insert(m.path).inserted else { continue }
            out.append(m.path)
        }
        return out
    }
}

// MARK: Join Cuts

extension EditorSession {
    /// Sequence > Join Cuts: merges the through edits (blade leftovers) at the selected clips, or on the whole timeline when
    /// nothing is selected, in one undo step. Returns how many cuts went; 0 changes nothing and adds no undo step.
    @discardableResult
    public func joinCutsInSelection() -> Int {
        guard let t = activeTimeline else { return 0 }
        let scope: Set<Clip.ID>? = selection.isEmpty ? nil : selection
        guard !t.throughEdits(selection: scope).isEmpty else { return 0 }
        var n = 0
        // Fast Cut: clips attached to a joined right half re-attach to the joined clip (`magneticJoin`).
        guard attempt("Join Cuts", { n = try $0.magneticJoin(selection: scope) }) else { return 0 }
        return n
    }
}
