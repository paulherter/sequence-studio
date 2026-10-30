import Foundation
import SQCore

/// Pure enablement predicates for selection-driven timeline commands (menu items and key routing).
/// Each mirrors the guard of the matching handler so a disabled item never flashes a "select first" message.
extension EditorSession {
    /// Nudge and Slide: need at least one selected clip.
    public var canNudgeOrSlideSelection: Bool { !selection.isEmpty && activeTimeline != nil }

    /// Select Next / Previous Clip: the last (first) selected clip has a neighbour on its track.
    public func canSelectAdjacentClip(forward: Bool) -> Bool {
        guard let t = activeTimeline else { return false }
        let picked = t.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        guard let from = forward ? picked.max(by: { $0.timeline.end < $1.timeline.end }) : picked.min(by: { $0.start < $1.start })
        else { return false }
        return t.neighbourClip(of: from.id, forward: forward) != nil
    }

    /// Go to Selected Clip Start / End: the selection has an extent.
    public var canGoToSelectedClipEdge: Bool { activeTimeline?.extent(of: selection) != nil }

    /// Trim to Range: a non-empty In/Out range and a selection.
    public var canTrimSelectionToRange: Bool {
        guard !selection.isEmpty, let r = activeTimeline?.inOut else { return false }
        return !r.isEmpty
    }

    /// Unlink: at least one selected clip carries a link.
    public var canUnlinkSelection: Bool {
        guard let t = activeTimeline, !selection.isEmpty else { return false }
        return t.tracks.flatMap(\.clips).contains { selection.contains($0.id) && $0.link != nil }
    }

    /// Solo: a selected clip (or its linked partner) lies on an audio track.
    public var canSoloSelectedTracks: Bool {
        guard !selection.isEmpty, var t = activeTimeline else { return false }
        return t.toggleSolo(forClips: selection) != nil
    }

    /// Mute: same reach as Solo.
    public var canMuteSelectedTracks: Bool { canSoloSelectedTracks }

    /// Detach Audio: a selected video clip has linked audio on an unlocked track.
    public var canDetachAudioSelection: Bool {
        guard !selection.isEmpty, var t = activeTimeline, let ids = try? t.detachAudio(of: selection) else { return false }
        return !ids.isEmpty
    }

    /// Join Cuts: a through edit exists in the selection (the whole sequence when nothing is selected).
    public var canJoinCuts: Bool {
        guard let t = activeTimeline else { return false }
        let scope: Set<Clip.ID>? = selection.isEmpty ? nil : selection
        return !t.throughEdits(selection: scope).isEmpty
    }
}
