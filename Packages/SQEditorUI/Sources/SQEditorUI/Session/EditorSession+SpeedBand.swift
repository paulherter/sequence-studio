import Foundation
import SQCore

/// Time Remapping on the session: speed band edits (one undo step per drag), key deletion, Remove Time Remapping.
extension EditorSession {
    /// Selected video clips that can show the speed band.
    public var remappableSelection: [Clip] {
        retimableSelection.filter { $0.kind == .video }
    }

    public var canToggleTimeRemapping: Bool { !remappableSelection.isEmpty }
    public var canRemoveTimeRemapping: Bool { retimableSelection.contains { $0.speedKeys != nil } }

    /// A drag on the speed band: every `changed` replaces the clip's speed track (computed from the track at mouse-down, so it
    /// is idempotent); all changes of one drag are one undo step.
    public func applySpeedEdit(_ e: SpeedEdit) {
        switch e.phase {
        case .began: gestureCounter += 1
        case .changed:
            attempt("Time Remapping", coalescing: "remap:\(e.clip):\(gestureCounter)") { try $0.editSpeedKeys(e.clip) { _ in e.keys } }
        case .ended: break
        }
    }

    /// Delete on a key or a transition of the band.
    @discardableResult
    public func deleteSpeedKey(clip: Clip.ID, hit: SpeedBandKeyHit) -> Bool {
        guard let fd = activeTimeline?.frameDuration else { return false }
        return attempt(hit.title) { try $0.editSpeedKeys(clip) { SpeedBand.deleting(hit.band, from: $0, frameDuration: fd) } }
    }

    /// Clip > Remove Time Remapping: the selected remapped clips play at 100 % over the source they used (Premiere: the effect
    /// and all its keyframes go, the clip length follows).
    @discardableResult
    public func removeTimeRemapping() -> Bool {
        let ids = retimableSelection.filter { $0.speedKeys != nil }.map(\.id)
        guard !ids.isEmpty else { return false }
        return attempt("Remove Time Remapping") { t in
            for id in ids where t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.speedKeys != nil {
                try t.editSpeedKeys(id) { k in
                    let h = k.hull
                    return SpeedKeys(constant: .normal, reversed: false, duration: h.duration, origin: h.start)
                }
            }
        }
    }
}
