import Foundation
import SQCore

/// W8.1 Jump cut to the alternate track (SQCore JumpCut.swift): one undo step.
extension EditorSession {
    /// Overlap in frames: `sq.jumpCut.overlapFrames` when set, else 0.3 s of the active sequence.
    public var jumpCutOverlapFrames: Int {
        if let n = UserDefaults.standard.object(forKey: "sq.jumpCut.overlapFrames") as? Int, n >= 0 { return n }
        return JumpCut.defaultOverlapFrames(frameDuration: activeTimeline?.format.frameDuration ?? Time(1, 30))
    }

    /// Cuts at the playhead (edit target rule) and moves the rest to the alternate track. The moved halves become the
    /// selection, so the next press cuts the same take again and sends it back. Returns whether anything changed.
    @discardableResult
    public func jumpCutAlternate(overlapFrames: Int? = nil) -> Bool {
        guard activeTimeline != nil else { return false }
        let at = playhead, sel = selection, n = overlapFrames ?? jumpCutOverlapFrames
        var moved: [Clip.ID] = []
        guard attempt("Jump Cut", { moved = try $0.jumpCutAlternate(at: at, selection: sel, overlapFrames: n) }) else { return false }
        select(clips: Set(moved))
        return true
    }

    /// Status-line text when a jump cut at the playhead cannot run, nil when it can.
    public var jumpCutRefusal: String? {
        guard let t = activeTimeline else { return "No sequence open." }
        if !t.jumpCutCandidates(at: playhead, selection: selection).isEmpty { return nil }
        if t.isJumpCut(at: playhead, selection: selection) { return "Already jump cut at the playhead. Move the playhead first." }
        return "No clip under the playhead to jump cut."
    }

    public var jumpCutEnabled: Bool {
        guard let t = activeTimeline else { return false }
        return !t.jumpCutCandidates(at: playhead, selection: selection).isEmpty
    }
}
