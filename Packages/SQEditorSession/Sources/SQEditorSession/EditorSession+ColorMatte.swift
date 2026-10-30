import Foundation
import SQCore

/// Color Matte clips: a flat color layer, an ordinary clip (see `ColorMatte.swift` in SQCore).
extension EditorSession {
    /// Places a Color Matte at `time` (default: playhead) on `track`, else on the topmost unlocked video track that is free
    /// there. One undo step; selects the new clip. A refusal goes to `lastError`.
    @discardableResult
    public func addColorMatte(_ color: ColorMatteColor, name: String = "Color Matte", at time: Time? = nil,
                              track: Track.ID? = nil, duration: Time = Time(5, 1)) -> Clip.ID? {
        guard let t = activeTimeline, let tl = activeTimelineID else { setError("Open a sequence first."); return nil }
        let start = (time ?? playhead).snapped(to: t.frameDuration)
        let duration = max(duration.snapped(to: t.frameDuration), t.frameDuration)
        guard let chosen = Self.generatorTrack(in: t, for: TimeRange(start: start, duration: duration), preferred: track) else {
            setError("There is no video track for the color matte."); return nil
        }
        var newID: Clip.ID?
        do {
            try perform("Add Color Matte") { p in
                newID = try p.addColorMatte(color, name: name, in: tl, at: start, track: chosen, duration: duration)
            }
        } catch { setError(Self.message(for: error)); return nil }
        if let newID { select(clips: [newID]) }
        return newID
    }

    /// Sets a Color Matte's color. Calls of one gesture (`continuesGesture`: the picker drag) merge into one undo step.
    public func setColorMatte(_ id: Clip.ID, _ color: ColorMatteColor, continuesGesture: Bool = false) {
        if !continuesGesture { gestureCounter += 1 }
        guard activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.matteColor != color else { return }
        do {
            try perform("Edit Color Matte", coalescing: "matte:\(id):\(gestureCounter)") { try $0.setColorMatte(clipID: id, color) }
        } catch { setError(Self.message(for: error)) }
    }
}
