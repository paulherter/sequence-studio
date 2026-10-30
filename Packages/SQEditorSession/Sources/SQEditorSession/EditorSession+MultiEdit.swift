import Foundation
import SQCore
import SQText

// MARK: Text section

extension EditorSession {
    /// The selected text clips (as displayed) when several clips are selected and all of them are text; else empty.
    public var selectedTextClips: [Clip] {
        let clips = selectedEditClips
        return clips.count > 1 && clips.allSatisfy({ $0.generator?.kind == GeneratorRef.text }) ? clips : []
    }

    /// Dotted paths of the text fields ("text", "style.size", "style.shadow") that differ between the selected text clips:
    /// the Text section shows those fields empty.
    public var textMixedPaths: Set<String> {
        let templates = selectedTextClips.compactMap { $0.generator.flatMap { try? TextGenerator.decode($0).0 } }
        return (try? CodableMerge.differingPaths(templates)) ?? []
    }

    /// Text section edit with several text clips selected: `primary` goes from `old` to `new`, every other selected text
    /// clip gets only the fields that changed (its other fields keep their own values). ONE undo step; edits of one
    /// gesture merge. `forcing`: template paths ("style.italic") copied even when unchanged on `primary` (a mixed field
    /// set to the shown clip's own value).
    public func updateTextClips(primary: Clip.ID, from old: TextTemplate, to new: TextTemplate,
                                animations: AnimationSet?, oldAnimations: AnimationSet?, continuesGesture: Bool,
                                forcing: Set<String> = []) {
        let clips = selectedTextClips
        guard clips.contains(where: { $0.id == primary }) else {
            updateTextClip(primary, template: new, animations: animations, continuesGesture: continuesGesture)
            return
        }
        let none = AnimationSet(in: nil, out: nil)
        var edits: [Clip] = []
        do {
            for c in clips {
                guard var g = c.generator else { continue }
                let ref: GeneratorRef
                if c.id == primary {
                    ref = try TextGenerator.makeRef(template: new, animations: animations)
                } else {
                    let (t, a) = try TextGenerator.decode(g)
                    let carried = try CodableMerge.carry(from: old, to: new, into: t, forcing: forcing)
                    let anims = animations == oldAnimations ? a
                        : try CodableMerge.carry(from: oldAnimations ?? none, to: animations ?? none, into: a ?? none)
                    ref = try TextGenerator.makeRef(template: carried, animations: anims)
                }
                g.payload = ref.payload; g.payloadVersion = ref.payloadVersion
                var e = c; e.generator = g
                edits.append(e)
            }
        } catch { setError(Self.message(for: error)); return }
        if !continuesGesture { gestureCounter += 1 }
        let v = activeVariantID
        attempt("Edit Text", coalescing: "texts:\(gestureCounter)") { t in
            for e in edits {
                // In a format variant the text is edited as that variant shows it (W5.1), else it is the shared base text.
                if let v { try t.applyDisplayedEdit(e, variant: v, conformsPicture: true) } else { try t.replaceClip(e) }
            }
        }
    }
}

/// Multi-select editing (Premiere): with several clips selected Effect Controls and the Text section edit all of them.
extension EditorSession {
    /// The clips an Effect Controls / Text edit goes to, as the active variant shows them: one per selected clip, a linked
    /// A/V pair counted once by its video clip; ordered by start, then track (top of the list first). Empty when a
    /// selected clip is not in the active sequence.
    public var selectedEditClips: [Clip] {
        guard let t = activeTimeline, !selection.isEmpty else { return [] }
        var picked: [(clip: Clip, track: Int)] = []
        for (i, tr) in t.tracks.enumerated() { for c in tr.clips where selection.contains(c.id) { picked.append((c, i)) } }
        guard picked.count == selection.count else { return [] }
        // A linked group shows its picture clip (the audio of a selected pair edits through it, like one clip).
        var out: [(clip: Clip, track: Int)] = []
        var seenLinks: Set<UUID> = []
        let linkedPicture = Set(picked.filter { $0.clip.kind != .audio }.compactMap(\.clip.link))
        for p in picked {
            if let l = p.clip.link {
                if p.clip.kind == .audio, linkedPicture.contains(l) { continue }
                if !seenLinks.insert(l).inserted { continue }
            }
            out.append(p)
        }
        return out.sorted { ($0.clip.start, $0.track) < ($1.clip.start, $1.track) }.map { displayedClip($0.clip) }
    }

    /// Effect Controls edit of several clips as displayed: ONE undo step. Edits of one gesture merge.
    public func replaceDisplayedClips(_ clips: [Clip], name: String, continuesGesture: Bool) {
        guard clips.count > 1 else {
            if let c = clips.first { replaceDisplayedClip(c, name: name, continuesGesture: continuesGesture) }
            return
        }
        if !continuesGesture { gestureCounter += 1 }
        let v = activeVariantID
        let conforms = v.map { v in clips.map { project.conformsPicture(of: $0, in: v) } } ?? []
        attempt(name, coalescing: "clips:\(gestureCounter)") { t in
            for (i, c) in clips.enumerated() {
                if let v { try t.applyDisplayedEdit(c, variant: v, conformsPicture: conforms[i]) } else { try t.replaceClip(c) }
            }
        }
    }
}
