import Foundation
import SQCore

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

    /// Applies a new instance of the effect `kind` to the given video clips (a second Gaussian Blur is a second instance).
    @discardableResult
    public func addEffect(kind: String, to ids: Set<Clip.ID>) -> Bool {
        guard EffectCatalog.spec(for: kind) != nil, !ids.isEmpty,
              activeTimeline?.tracks.flatMap(\.clips).contains(where: { ids.contains($0.id) && $0.kind == .video }) == true
        else { return false }
        return attempt("Add \(EffectCatalog.title(for: kind))") { t in
            var changed = false
            for id in ids {
                guard var c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), c.kind == .video,
                      c.addEffect(kind: kind) != nil else { continue }
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
        return attempt("Add Frame Hold") { _ = try $0.addFrameHold(of: id, at: t) }
    }

    /// Insert Frame Hold Segment: the clip splits at the playhead and a held copy of that frame is inserted.
    @discardableResult
    public func insertFrameHold(duration: Time = EditorSession.defaultFrameHoldDuration) -> Bool {
        guard let id = commandClips(kind: .video).first(where: { $0.timeline.contains(playhead) })?.id else { return false }
        let t = playhead
        return attempt("Insert Frame Hold Segment") { _ = try $0.insertFrameHold(of: id, at: t, duration: duration) }
    }

    // MARK: Paste Attributes (Cmd+Opt+V)

    /// True when a copied clip can lend its attributes to something that is selected.
    public var canPasteAttributes: Bool {
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
    public func pasteAttributes() -> Bool {
        guard canPasteAttributes, let cb = clipboard else { return false }
        let targets = Array(selection)
        return attempt("Paste Attributes") { t in
            var total = 0
            for kind in [TrackKind.video, .audio] {
                guard let source = cb.entries.first(where: { $0.clip.kind == kind })?.clip else { continue }
                total += (try? t.pasteAttributes(from: source, to: targets)) ?? 0
            }
            if total == 0 { throw EditError.emptyClip }
        }
    }
}
