import Foundation
import SSCore
import SSText

/// Text clips, captions and quick effects: each call is one undo step (continuing gestures merge).
extension EditorSession {
    /// Places a text layer at `time` (default: playhead) on `track`, else on the topmost unlocked video track that is
    /// free there. Selects the new clip. Returns its ID; a refusal is reported through `lastError`.
    @discardableResult
    public func addTextClip(template: TextTemplate, at time: Time? = nil, track: Track.ID? = nil,
                            duration: Time = Time(5, 1), position: Vec2? = nil) -> Clip.ID? {
        guard let t = activeTimeline else { return nil }
        let start = (time ?? playhead).snapped(to: t.frameDuration)
        let range = TimeRange(start: start, duration: duration)
        let chosen = track.flatMap { id in t.track(id).flatMap { $0.kind == .video ? id : nil } }
            ?? t.tracks.last { $0.kind == .video && !$0.isLocked && !$0.clips.contains { $0.timeline.overlaps(range) } }?.id
            ?? t.tracks.last { $0.kind == .video && !$0.isLocked }?.id
        guard let chosen, let tl = activeTimelineID else { setError("There is no video track for the text."); return nil }
        var newID: Clip.ID?
        do {
            let ref = try TextGenerator.makeRef(template: template, animations: nil)
            try perform("Add Text") { p in
                newID = try p.addGeneratorClip(kind: ref.kind, payload: ref.payload, payloadVersion: ref.payloadVersion,
                                               name: template.name, in: tl, at: start, track: chosen, duration: duration)
                if let position, let id = newID {
                    try p.edit(tl) { t in
                        guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { return }
                        c.animation.position = AnimatedProperty(position)
                        try t.replaceClip(c)
                    }
                }
            }
        } catch { setError(Self.message(for: error)); return nil }
        if let newID { select(clips: [newID]) }
        return newID
    }

    /// Removes a text clip that was left empty (Type tool: click-away without typing). Leaves a gap.
    @discardableResult
    public func discardTextClip(_ id: Clip.ID) -> Bool {
        let ok = attempt("Delete Empty Text") { t in try TimelineEdit.lift([id]).apply(to: &t) }
        if ok, selection.contains(id) { select(clips: selection.subtracting([id])) }
        return ok
    }

    /// Text or style edit of a generator clip. Edits of one gesture (`continuesGesture`) merge into one step.
    public func updateTextClip(_ id: Clip.ID, template: TextTemplate, animations: AnimationSet?, continuesGesture: Bool) {
        if !continuesGesture { gestureCounter += 1 }
        do {
            let ref = try TextGenerator.makeRef(template: template, animations: animations)
            try perform("Edit Text", coalescing: "text:\(id):\(gestureCounter)") {
                try $0.updateGenerator(clipID: id, payload: ref.payload, payloadVersion: ref.payloadVersion)
            }
        } catch { setError(Self.message(for: error)) }
    }

    /// Replaces the captions of the first caption track (created when missing) as one undo step.
    @discardableResult
    public func replaceCaptions(_ items: [CaptionItem]) -> Bool {
        attempt("Create Captions") { _ = try $0.replaceCaptions(items) }
    }

    /// Applies Rounded Corners to the selected picture clips that do not have it yet.
    @discardableResult
    public func addRoundedCorners(radius: Double = 24) -> Bool {
        addRoundedCorners(to: selection, radius: radius)
    }

    /// Same for the given clips (an effect dropped on one clip): one undo step.
    @discardableResult
    public func addRoundedCorners(to ids: Set<Clip.ID>, radius: Double = 24) -> Bool {
        guard !ids.isEmpty else { return false }
        return attempt("Add Rounded Corners") { t in
            var changed = false
            for id in ids {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), c.kind != .audio,
                      c.roundedCorners == nil else { continue }
                c.roundedCorners = .roundedCorners(radius: radius)
                try t.replaceClip(c)
                changed = true
            }
            if !changed { throw EditError.emptyClip }
        }
    }
}
