import Foundation
import SQCore
import SQText

/// Clip-level look commands: apply an effect, fade preset, frame hold, Paste Attributes. One undo step each.
extension EditorSession {
    /// Length of the fade presets (Fade In / Fade Out), clamped to half the clip.
    public static let defaultFadeDuration = Time(1, 1)
    /// Length of an inserted frame hold segment (Premiere: two seconds).
    public static let defaultFrameHoldDuration = Time(2, 1)

    /// Clips a clip command works on: the selection, else the clips under the playhead on the targeted video tracks
    /// (all video tracks when none is targeted).
    public func commandClipsForMenu(kind: TrackKind? = nil) -> [Clip] { commandClips(kind: kind) }

    func commandClips(kind: TrackKind? = nil) -> [Clip] {
        guard let t = activeTimeline else { return [] }
        let all = t.tracks.flatMap(\.clips).filter { kind == nil || $0.kind == kind }
        if !selection.isEmpty { return all.filter { selection.contains($0.id) } }
        let tracks = t.tracks.filter { kind == nil || $0.kind == kind }
        let targeted = tracks.filter(\.isTargeted)
        return (targeted.isEmpty ? tracks : targeted).flatMap(\.clips).filter { $0.timeline.contains(playhead) }
    }

    // MARK: Apply effect

    /// Clips an effect dropped on `hit` goes to: the whole selection when `hit` is part of it, else just `hit`.
    public func effectDropTargets(hit: Clip.ID) -> Set<Clip.ID> {
        selection.contains(hit) ? selection : [hit]
    }

    /// Applies a new instance of the effect `kind` to the given video clips (a second Gaussian Blur is a second instance).
    /// `kind` may also be the row id of a built-in stack preset (film look, Voice, motion or keying preset): it goes through
    /// the one preset path (`applyStackPreset`), still one undo step.
    @discardableResult
    public func addEffect(kind: String, to ids: Set<Clip.ID>) -> Bool {
        if TextPresetCatalog.isTextPresetID(kind) { return addTextPreset(id: kind, to: ids) }
        if EffectStackPresets.preset(rowID: kind) != nil { return !ids.isEmpty && applyStackPreset(kind, to: ids) }
        if ClipEffect.isAudioKind(kind) { return addAudioEffect(kind: kind, to: ids) }
        if kind == ClipEffect.stabilizeKind { return addStabilizer(to: ids) }
        guard EffectCatalog.spec(for: kind) != nil, !ids.isEmpty,
              activeTimeline?.tracks.flatMap(\.clips).contains(where: { ids.contains($0.id) && $0.kind == .video }) == true
        else { return false }
        let motion = project.styleKit?.motion          // W8.3: new motion effects start at the kit's duration and curve
        let defaults = effectDefaults                  // FB-W: the user's default of the kind, else factory
        return attempt("Add \(EffectCatalog.title(for: kind))") { t in
            var changed = false
            for id in ids {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), c.kind == .video else { continue }
                guard c.addEffect(kind: kind, motionDefaults: motion, defaults: defaults) != nil else { continue }
                try t.replaceClip(c)
                changed = true
            }
            if !changed { throw EditError.wrongTrackKind }
        }
    }

    /// The audio clips an audio effect for `ids` lands on: audio clips themselves, and the linked audio of video clips.
    public func audioEffectTargets(for ids: Set<Clip.ID>) -> Set<Clip.ID> {
        let clips = activeTimeline?.tracks.flatMap(\.clips) ?? []
        let links = Set(clips.filter { ids.contains($0.id) && $0.kind != .audio }.compactMap(\.link))
        return Set(clips.filter { $0.kind == .audio && (ids.contains($0.id) || $0.link.map(links.contains) == true) }.map(\.id))
    }

    /// AUDIO-FX: adds an audio effect at the end of each target's stack (see `audioEffectTargets`): one undo step.
    private func addAudioEffect(kind: String, to ids: Set<Clip.ID>) -> Bool {
        let targets = audioEffectTargets(for: ids)
        guard EffectCatalog.spec(for: kind) != nil, !targets.isEmpty else { return false }
        let defaults = effectDefaults
        return attempt("Add \(EffectCatalog.title(for: kind))") { t in
            var changed = false
            for id in targets {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { continue }
                guard c.addEffect(kind: kind, defaults: defaults) != nil else { continue }
                try t.replaceClip(c)
                changed = true
            }
            if !changed { throw EditError.wrongTrackKind }
        }
    }

    // MARK: Fade (video opacity keys)

    /// Fade In / Fade Out preset on the selected video clips: Opacity keys at the clip's head or tail.
    @discardableResult
    public func fadeVideo(_ edge: ClipEdge, duration: Time = EditorSession.defaultFadeDuration) -> Bool {
        let ids = commandClips(kind: .video).map(\.id)
        guard !ids.isEmpty else { return false }
        return attempt(edge == .head ? "Fade In" : "Fade Out") { try $0.fadeVideo(ids, edge: edge, duration: duration) }
    }

    // MARK: Frame hold

    /// Add Frame Hold: from the playhead to the end of the clip, the picture is frozen on the frame at the playhead.
    @discardableResult
    public func addFrameHold() -> Bool {
        guard let id = commandClips(kind: .video).first(where: { $0.timeline.contains(playhead) })?.id else { return false }
        let t = playhead
        return attempt("Add Frame Hold") { _ = try $0.magneticAddFrameHold(of: id, at: t) }
    }

    /// Insert Frame Hold Segment: the clip splits at the playhead and a held copy of that frame is inserted.
    @discardableResult
    public func insertFrameHold(duration: Time = EditorSession.defaultFrameHoldDuration) -> Bool {
        guard let id = commandClips(kind: .video).first(where: { $0.timeline.contains(playhead) })?.id else { return false }
        let t = playhead
        return attempt("Insert Frame Hold Segment") { _ = try $0.magneticInsertFrameHold(of: id, at: t, duration: duration) }
    }

    // MARK: Paste Attributes (Cmd+Opt+V)

    /// The groups the Paste Attributes dialog offers: those of the copied clip kinds that a selected clip can take.
    public var pasteAttributeChoices: [PasteAttributeGroup] {
        if let b = builtInClipboard { return canPasteAttributes ? [b.group] : [] }
        guard canPasteAttributes, let cb = clipboard, let t = activeTimeline else { return [] }
        let copiedIDs = Set(cb.entries.map(\.clip.id))
        let targetKinds = Set(t.tracks.flatMap(\.clips).filter { selection.contains($0.id) && !copiedIDs.contains($0.id) }.map(\.kind))
        let copiedKinds = Set(cb.entries.map(\.clip.kind)).intersection(targetKinds)
        return PasteAttributeGroup.allCases.filter { copiedKinds.contains($0.kind) }
    }

    /// True when a copied clip can lend its attributes to something that is selected.
    public var canPasteAttributes: Bool {
        if let b = builtInClipboard { return builtInTargets(b).isEmpty == false }
        guard let cb = clipboard, let t = activeTimeline else { return false }
        let kinds = Set(cb.entries.map(\.clip.kind))
        let copiedIDs = Set(cb.entries.map(\.clip.id))
        return t.tracks.flatMap(\.clips).contains { c in
            selection.contains(c.id) && kinds.contains(c.kind) && !copiedIDs.contains(c.id)
        }
    }

    /// Motion, Opacity, Volume and the other effects of the copied clip onto the selected clips (same kind). Motion,
    /// Opacity and Volume replace the target's; other effects are added behind the existing ones.
    @discardableResult
    public func pasteAttributes(groups: Set<PasteAttributeGroup> = Set(PasteAttributeGroup.allCases), scaleTimes: Bool = false) -> Bool {
        if let b = builtInClipboard { return pasteBuiltIn(b, groups: groups, scaleTimes: scaleTimes) }
        guard canPasteAttributes, let cb = clipboard, !groups.isEmpty else { return false }
        let targets = Array(selection)
        return attempt("Paste Settings") { t in
            var total = 0
            for kind in [TrackKind.video, .audio] {
                guard let entry = cb.entries.first(where: { $0.clip.kind == kind }) else { continue }
                total += (try? t.pasteAttributes(from: entry.clip, to: targets, groups: groups, scaleTimes: scaleTimes,
                                                 sourceLane: entry.lane, pictureLanes: cb.pictureLanes)) ?? 0
            }
            if total == 0 { throw EditError.emptyClip }
        }
    }

    /// Grade From Previous Clip (`back` 1) / From Clip Before Previous (`back` 2) for every selected clip. One undo step.
    @discardableResult
    public func gradeFromPreviousClip(back: Int = 1) -> Bool {
        // Deterministic order: by track, then start, so adjacent selected clips chain the same way every time.
        var order: [Clip.ID: (Int, Time)] = [:]
        for (ti, tr) in (activeTimeline?.tracks ?? []).enumerated() { for c in tr.clips { order[c.id] = (ti, c.start) } }
        let ids = selection.sorted {
            let a = order[$0] ?? (Int.max, .zero), b = order[$1] ?? (Int.max, .zero)
            return a.0 != b.0 ? a.0 < b.0 : a.1 < b.1
        }
        guard !ids.isEmpty else { return false }
        return attempt("Grade From Previous Clip") { t in
            for id in ids { try t.gradeFromPreviousClip(id, back: back) }
        }
    }

    /// Grade All From This Camera: the one selected clip's Color effects go onto every other clip of the sequence
    /// whose footage has the same camera signature. One undo step. Returns the number of clips graded (0 = refused,
    /// reported through the session error).
    @discardableResult
    public func gradeAllFromCamera() -> Int {
        guard selection.count == 1, let id = selection.first else { setError("Select one clip to grade its camera."); return 0 }
        var infos: [UUID: CameraSignature] = [:]
        for m in project.media { if let s = CameraSignature(m.info) { infos[m.id] = s } }
        var count = 0
        let ok = attempt("Grade All From This Camera") { t in
            count = try t.gradeAllFromCamera(of: id) { infos[$0] }
        }
        return ok ? count : 0
    }
}
