import Foundation
import SQCore
import SQText

/// Text clips, captions and quick effects: each call is one undo step (continuing gestures merge).
extension EditorSession {
    /// Places a text layer at `time` (default: playhead) on `track`, else on the topmost unlocked video track that is
    /// free there. Selects the new clip. Returns its ID; a refusal is reported through `lastError`.
    @discardableResult
    public func addTextClip(template: TextTemplate, at time: Time? = nil, track: Track.ID? = nil,
                            duration: Time = Time(5, 1), position: Vec2? = nil,
                            neverOverwrite: Bool = false) -> Clip.ID? {
        guard let t = activeTimeline else { return nil }
        let start = (time ?? playhead).snapped(to: t.frameDuration)
        // 5 s is not a whole number of frames at 29.97: the clip ends on a frame like everything else on the timeline.
        let duration = max(duration.snapped(to: t.frameDuration), t.frameDuration)
        let range = TimeRange(start: start, duration: duration)
        guard let tl = activeTimelineID else { setError("There is no video track for the text."); return nil }
        // `neverOverwrite`: when no unlocked video track is free over the range, a new video track goes on top (same undo step).
        let freeTrack = Self.generatorTrack(in: t, for: range, preferred: track, allowOverwrite: !neverOverwrite)
        let newTrack = freeTrack == nil && neverOverwrite && track == nil ? Track(kind: .video) : nil
        guard let chosen = freeTrack ?? newTrack?.id else {
            setError("There is no video track for the text."); return nil
        }
        var newID: Clip.ID?
        do {
            let ref = try TextGenerator.makeRef(template: template, animations: nil)
            try perform("Add Text") { p in
                if let newTrack { try p.edit(tl) { $0.tracks.append(newTrack) } }
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

    /// Places a tone (1 kHz, -12 dB) at the playhead on the targeted audio track that is free there, else the last unlocked
    /// audio track. Selects the clip.
    @discardableResult
    public func addToneClip(_ spec: ToneSpec = .default, duration: Time = Time(5, 1)) -> Clip.ID? {
        guard let t = activeTimeline, let tl = activeTimelineID else { return nil }
        let start = playhead.snapped(to: t.frameDuration)
        let duration = max(duration.snapped(to: t.frameDuration), t.frameDuration)
        let range = TimeRange(start: start, duration: duration)
        let audio = t.tracks.filter { $0.kind == .audio && !$0.isLocked }
        // Never over other sound: when no audio track is free over the range, a new one is added (same undo step).
        let free = (audio.first { $0.isTargeted && !$0.clips.contains { $0.timeline.overlaps(range) } }
                    ?? audio.first { !$0.clips.contains { $0.timeline.overlaps(range) } })?.id
        let fresh = free == nil ? Track(kind: .audio) : nil
        guard let chosen = free ?? fresh?.id else { return nil }
        var newID: Clip.ID?
        do {
            try perform("Add Tone") { p in
                if let fresh { try p.edit(tl) { $0.tracks.append(fresh) } }
                newID = try p.addToneClip(spec, in: tl, at: start, track: chosen, duration: duration)
            }
        }
        catch { setError(Self.message(for: error)); return nil }
        if let newID { select(clips: [newID]) }
        return newID
    }

    /// Where a new generator clip (text, shape, graphic) goes: `preferred` when it is a video track, else the lowest unlocked
    /// video track that is free over `range` and lies above every clip overlapping `range` (so it shows on top of the
    /// picture without climbing to the top of the stack), else (`allowOverwrite`) the topmost unlocked video track.
    /// Nil when nothing qualifies and overwriting is not allowed: the caller adds a track.
    static func generatorTrack(in t: Timeline, for range: TimeRange, preferred: Track.ID?, allowOverwrite: Bool = true) -> Track.ID? {
        if let id = preferred, let tr = t.track(id), tr.kind == .video { return id }
        let video = t.tracks.filter { $0.kind == .video }
        let floor = video.lastIndex { $0.clips.contains { $0.timeline.overlaps(range) } }.map { $0 + 1 } ?? 0
        return video.dropFirst(floor).first { !$0.isLocked }?.id
            ?? (allowOverwrite ? video.last { !$0.isLocked }?.id : nil)
    }

    /// Removes a text clip that was left empty (Type tool: click-away without typing). With `depth` (the undo depth
    /// before the clip was added) the add and any edits are withdrawn without a trace: no undo entry, no redo entry.
    /// Without it the clip is lifted (gap) as one undo step.
    @discardableResult
    public func discardTextClip(_ id: Clip.ID, rewindingTo depth: Int? = nil) -> Bool {
        if let depth, history.undoDepth > depth {
            rewindUndo(toDepth: depth)
            if selection.contains(id) { select(clips: selection.subtracting([id])) }
            return true
        }
        let ok = attempt("Delete Empty Text") { t in try TimelineEdit.lift([id]).apply(to: &t) }
        if ok, selection.contains(id) { select(clips: selection.subtracting([id])) }
        return ok
    }

    /// Undo depth now, to be passed to `discardTextClip` / `foldUndo` later.
    public var undoDepth: Int { history.undoDepth }

    /// Text or style edit of a generator clip. Edits of one gesture (`continuesGesture`) merge into one step.
    public func updateTextClip(_ id: Clip.ID, template: TextTemplate, animations: AnimationSet?, continuesGesture: Bool) {
        if !continuesGesture { gestureCounter += 1 }
        do {
            let ref = try TextGenerator.makeRef(template: template, animations: animations)
            // In a format variant the text is edited as that variant shows it: an overridden generator keeps the edit
            // in the override (W5.1), else it is the shared base text.
            if let v = activeVariantID, let c = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
               var g = displayedClip(c).generator {
                var edited = displayedClip(c)
                g.payload = ref.payload
                g.payloadVersion = ref.payloadVersion
                edited.generator = g
                try performTimeline("Edit Text", coalescing: "text:\(id):\(gestureCounter)") {
                    try $0.applyDisplayedEdit(edited, variant: v, conformsPicture: true)
                }
                return
            }
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
