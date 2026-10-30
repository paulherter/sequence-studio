import Foundation
import SQCore

/// Speed keys in Effect Controls: the Speed row behaves like every keyframable row (diamond at the playhead, previous / next
/// key). A speed key is a boundary of the clip's speed track (Time Remapping); the first diamond click turns remapping on.
extension EffectControlsModel {
    /// Clip-local times of the speed keys (interior boundaries of the speed track), ascending.
    public var speedKeyTimes: [Time] {
        guard let k = clip?.speedKeys else { return [] }
        let b = k.boundaries
        return b.count > 2 ? Array(b[1..<(b.count - 1)]) : []
    }

    /// Only video clips carry speed keys (the band is video only); audio and stills show the plain Speed field.
    public var speedKeysAvailable: Bool { clip?.kind == .video && speedSession != nil }

    public var speedIsAnimated: Bool { !speedKeyTimes.isEmpty }

    public func speedKeyBoundary(atLocal t: Time) -> Int? {
        speedKeyTimes.firstIndex(of: t.snapped(to: frameDuration)).map { $0 + 1 }
    }

    public func previousSpeedKeyTime() -> Time? {
        let l = localPlayhead
        return speedKeyTimes.last { $0 < l }.map { $0 + (clip?.start ?? .zero) }
    }

    public func nextSpeedKeyTime() -> Time? {
        let l = localPlayhead
        return speedKeyTimes.first { $0 > l }.map { $0 + (clip?.start ?? .zero) }
    }

    public func speedKeyControlState() -> KeyframeControlState {
        KeyframeControlState.resolve(animated: speedIsAnimated, onKey: speedKeyBoundary(atLocal: localPlayhead) != nil,
                                     hasPrevious: previousSpeedKeyTime() != nil, hasNext: nextSpeedKeyTime() != nil,
                                     playheadInRange: playheadInClip)
    }

    public func goToPreviousSpeedKey() { if let t = previousSpeedKeyTime() { revealPlayhead(t); onSeek?(t) } }
    public func goToNextSpeedKey() { if let t = nextSpeedKeyTime() { revealPlayhead(t); onSeek?(t) } }

    /// The diamond: a key at the playhead is removed, otherwise one is added (speed stays as it is). One undo step.
    @discardableResult
    public func toggleSpeedKeyAtPlayhead() -> Bool {
        guard speedKeysAvailable, playheadInClip, let id = clip?.id, let s = speedSession else { return false }
        if let b = speedKeyBoundary(atLocal: localPlayhead) { return s.removeSpeedKey(clip: id, boundary: b) }
        return s.addSpeedKey(clip: id, atLocal: localPlayhead)
    }

    /// The left switch of the Speed row. On -> off (keys exist) asks first, then removes the ramp through the menu command's
    /// path (Clip > Remove Speed Ramp, one undo step). Off -> on adds the first key at the playhead like every other row.
    @discardableResult
    public func toggleSpeedAnimation(confirmRemoval: Bool = false) -> StopwatchOutcome {
        guard speedKeysAvailable, let s = speedSession else { return .unavailable }
        if speedIsAnimated {
            guard confirmRemoval else { return .needsConfirmation }
            return s.removeTimeRemapping() ? .removed : .unavailable
        }
        return toggleSpeedKeyAtPlayhead() ? .added : .unavailable
    }

    /// True when the speed track has a transition between two different key values (something to ease).
    public var speedHasTransition: Bool { clip?.speedKeys?.segments.contains { $0.isRamp } ?? false }

    /// The curve source of the transition under (else after, else before) the playhead: the same ease editor every
    /// keyframe uses, writing the ramp's Bezier through the session (one undo step per drag).
    public func speedCurveSource() -> SpeedRampEaseSource? {
        guard let s = speedSession, let c = clip,
              let i = s.speedTransitionSegment(clip: c.id, atLocal: localPlayhead) else { return nil }
        return SpeedRampEaseSource(session: s, clip: c.id, segment: i)
    }
}
