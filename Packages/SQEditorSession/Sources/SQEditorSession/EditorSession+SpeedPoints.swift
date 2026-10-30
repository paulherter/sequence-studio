import Foundation
import SQCore

/// Speed points at the playhead (Clip > Add Speed Point, no default key; the same on the speed band's menu) and the keyframe
/// easing commands on them.
extension EditorSession {
    /// The selected video clip the playhead is strictly inside (a point at an edge changes nothing).
    private var speedPointTarget: (clip: Clip, local: Time)? {
        let ph = playhead
        guard let c = remappableSelection.first(where: { $0.start < ph && ph < $0.timeline.end }) else { return nil }
        return (c, ph - c.start)
    }

    /// Add Speed Point is available: a selected video clip under the playhead that has no point on that frame.
    public var canAddSpeedPoint: Bool {
        guard let t = speedPointTarget, let fd = activeTimeline?.frameDuration else { return false }
        return SpeedKeys.of(t.clip).addingKey(at: t.local, frameDuration: fd) != nil
    }

    /// Adds a point that changes nothing at the playhead of the selected clip (the Effect Controls diamond's key). Drag it
    /// sideways on the speed band to make the span before it faster or slower.
    @discardableResult
    public func addSpeedPointAtPlayhead() -> Bool {
        guard let t = speedPointTarget else { return false }
        return addSpeedKey(clip: t.clip.id, atLocal: t.local)
    }

    /// Easy Ease / Ease In / Ease Out on the speed point (or transition) at the playhead of the selected clip: the same
    /// curves and sides as the keyframe commands. A plain point between two speeds opens a short transition first.
    /// False when the playhead is not on a point or transition that changes speed.
    @discardableResult
    public func easeSpeedPointAtPlayhead(_ curve: EasingCurve, side: EaseSide) -> Bool {
        guard let t = speedPointTarget, let fd = activeTimeline?.frameDuration else { return false }
        let k = SpeedKeys.of(t.clip)
        guard k.easingPoint(atLocal: t.local, curve: curve, side: side, frameDuration: fd) != nil else { return false }
        return attempt("Speed Transition Curve") {
            try $0.magneticEditSpeedKeys(t.clip.id, keepingKeys: true) { $0.easingPoint(atLocal: t.local, curve: curve, side: side, frameDuration: fd) }
        }
    }

    /// True when the playhead sits on a speed point or transition of the selected clip that easing can act on.
    public func speedPointAcceptsEase(_ curve: EasingCurve, side: EaseSide) -> Bool {
        guard let t = speedPointTarget, let fd = activeTimeline?.frameDuration else { return false }
        return SpeedKeys.of(t.clip).easingPoint(atLocal: t.local, curve: curve, side: side, frameDuration: fd) != nil
    }
}
