import Foundation
import SQUIKit
import SQCore

/// Split edit (J / L cut) and "Whoosh at selected cuts" (SQCore Timeline+SplitEdit.swift, Timeline+Whoosh.swift).
extension EditorSession {
    /// Moves only the audio or only the video edit point of the cut nearest to the playhead (on that side's tracks) to the
    /// playhead: a roll, so nothing later shifts and the sequence length stays. One undo step. Returns whether anything moved.
    @discardableResult
    public func splitEditToPlayhead(_ side: SplitEditSide) -> Bool {
        guard let t = activeTimeline else { return false }
        let at = playhead
        guard let cut = t.nearestCut(to: at, side: side) else {
            setError(SQL10n.format("No cut on %@ tracks to split.", SQL10n.string(side == .audio ? "audio" : "video")))
            return false
        }
        guard cut != at else { return false }
        return attempt(side == .audio ? "Split Edit Audio" : "Split Edit Video") { _ = try $0.splitEdit(cut: cut, side: side, to: at) }
    }

    public var splitEditEnabled: Bool { activeTimeline != nil }

    /// Keyboard nudge of one half of the cut nearest to the playhead (on that side's tracks) by `frames` (negative =
    /// earlier): the audio edit of a J / L cut moves while the picture stays, or the other way round. A roll like
    /// `splitEditToPlayhead`, one undo step, the playhead stays so repeated presses keep working on the same cut.
    /// The move is clamped by media handles; nothing moves (false, with a message) when there is no room.
    @discardableResult
    public func nudgeSplitEdit(_ side: SplitEditSide, frames: Int) -> Bool {
        guard frames != 0, let t = activeTimeline else { return false }
        let name = side == .audio ? "audio" : "video"
        guard let cut = t.nearestCut(to: playhead, side: side) else {
            setError(SQL10n.format("No cut on %@ tracks to nudge.", SQL10n.string(name)))
            return false
        }
        let target = cut + Time(Int64(frames) * t.frameDuration.value, t.frameDuration.timescale)
        var probe = t
        guard let moved = try? probe.splitEdit(cut: cut, side: side, to: target), moved != .zero else {
            setError(SQL10n.format("No room to move the %@ edit.", SQL10n.string(name)))
            return false
        }
        return attempt(side == .audio ? "Nudge Audio Edit" : "Nudge Video Edit") { _ = try $0.splitEdit(cut: cut, side: side, to: target) }
    }

    /// Fallback length of a J / L offset (a quarter second); `AudioRoleDefaults` holds the per-role values.
    public static let defaultSplitEditOffset = Time(1, 4)

    /// J / L cut by a fixed offset instead of to the playhead: the audio edit of the cut nearest to the playhead moves
    /// `offset` earlier (`.jCut`, audio leads the picture) or later (`.lCut`, audio trails), rounded to whole frames
    /// (at least one). The picture edit and the playhead stay, so repeated presses keep growing the same split. One undo
    /// step, clamped by media handles; false (with a message) when there is no cut or no room.
    @discardableResult
    public func offsetSplitEdit(_ kind: JLCut, by explicit: Time? = nil, defaults: AudioRoleDefaults = .load()) -> Bool {
        guard let t = activeTimeline else { return false }
        let fd = t.frameDuration
        // No explicit offset: the role of the audio clip after the cut picks it (dialogue 0.25 s, music / voice-over 0.5 s).
        let offset = explicit ?? {
            let cut = t.nearestCut(to: playhead, side: .audio)
            let tag = cut.flatMap { c in t.tracks.lazy.filter { $0.kind == .audio }
                .compactMap { tr in tr.clips.first(where: { $0.start == c }).flatMap { tr.role(of: $0) } }.first }
            return defaults.splitOffset(for: tag, frameDuration: fd)
        }()
        let exact = Double(offset.value) * Double(fd.timescale) / (Double(offset.timescale) * Double(fd.value))
        let frames = max(1, Int(exact.rounded()))
        return nudgeSplitEdit(.audio, frames: kind == .jCut ? -frames : frames)
    }

    /// "Whoosh at Selected Cuts": a copy of the audio `media` centered on each cut in `cuts`, on free audio tracks (a new one
    /// when none is free), tagged SFX. One undo step. Returns whether anything was placed.
    @discardableResult
    public func addWhoosh(media id: MediaRef.ID, atCuts cuts: [Time]) -> Bool {
        guard let ref = project.media(id), let total = ref.info?.duration ?? ref.duration, total > .zero else { return false }
        guard !cuts.isEmpty else { setError("Select a cut (an edge, or clips next to each other) first."); return false }
        var proto = Clip(name: ref.name, media: ref.id, kind: .audio, source: TimeRange(start: .zero, duration: total),
                         start: .zero, mediaDuration: total)
        proto.audioTag = .sfx
        return attempt("Whoosh at Cuts") { _ = try $0.placeCentred(proto, onCuts: cuts) }
    }

    /// The cuts the selection points at: the times of the given selected edges that are cuts, else the cuts around the selected clips.
    public func selectedCuts(edges: [EdgeRef]) -> [Time] {
        guard let t = activeTimeline else { return [] }
        if !edges.isEmpty {
            return Array(Set(edges.compactMap { t.cutTime(ofClip: $0.clip, edge: $0.edge) })).sorted()
        }
        return t.cuts(ofClips: selection)
    }
}
