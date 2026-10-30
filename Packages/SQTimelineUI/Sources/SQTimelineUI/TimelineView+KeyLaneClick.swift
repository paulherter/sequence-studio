import AppKit
import SQCore

extension TimelineView {
    /// Finds the key under a point of a clip's key lane: (clip, section, clip rect, point, geometry) -> timeline time of the key.
    /// KeyLanes lives with Effect Controls above this module and installs it from `setKeyLaneSection`.
    public static var keyLaneHitTester: (@MainActor (Clip, EffectSection, CGRect, CGPoint, TimelineGeometry) -> Time?)?

    /// A press on a diamond of the key lane (clip, timeline time of the key, Shift extends). The host selects those keys
    /// in Effect Controls; the nudge keys then move them like keys picked there.
    public var onKeyLaneClick: ((Clip.ID, Time, _ extend: Bool) -> Void)? {
        get { keyLaneClickHandler }
        set { keyLaneClickHandler = newValue }
    }

    /// Reports a press on a key glyph of the lane of a selected clip; true when it was one (the press is consumed).
    func beginKeyLaneClick(at p: CGPoint, event: NSEvent) -> Bool {
        guard let section = keyLaneSection, let test = Self.keyLaneHitTester, onKeyLaneClick != nil,
              toolState.timelineTool == .selection,
              let row = geometry.rows(for: timeline).first(where: { p.y >= $0.y && p.y < $0.maxY }),
              let track = timeline.track(row.track), !track.isLocked,
              let clip = track.clips.first(where: { selection.contains($0.id)
                  && geometry.x(for: $0.timeline.start) - 6 <= p.x && p.x < geometry.x(for: $0.timeline.end) + 6 })
        else { return false }
        let x0 = geometry.x(for: clip.timeline.start), x1 = geometry.x(for: clip.timeline.end)
        guard let t = test(clip, section, CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height), p, geometry) else { return false }
        onPointerDown?()
        if !selectedLineKeys.isEmpty { onLineKeyClick?(nil, false) }
        keyLaneKeysActive = true
        onKeyLaneClick?(clip.id, t, event.modifierFlags.contains(.shift))
        return true
    }
}
