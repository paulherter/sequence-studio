import Foundation
import SQCore

/// Time Remapping on the session: speed band edits (one undo step per drag), key deletion, Remove Speed Ramp.
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
            attempt("Speed Ramp", coalescing: "remap:\(e.clip):\(gestureCounter)") { try $0.magneticEditSpeedKeys(e.clip, keepingKeys: e.keepingKeys) { _ in e.keys } }
        case .ended: break
        }
    }

    /// Esc during a speed band drag: the sequence goes back to `original` (its state at `.began`), which drops the drag's
    /// undo step (the coalesced step returns to its start, `History.commit`); the gesture ends.
    public func cancelSpeedEdit(clip: Clip.ID, restoring original: Timeline) {
        attempt("Speed Ramp", coalescing: "remap:\(clip):\(gestureCounter)") { $0 = original }
        endGesture()
    }

    /// Delete on a key or a transition of the band.
    @discardableResult
    public func deleteSpeedKey(clip: Clip.ID, hit: SpeedBandKeyHit) -> Bool {
        guard let fd = activeTimeline?.frameDuration else { return false }
        return attempt(hit.title) { try $0.magneticEditSpeedKeys(clip) { SpeedBand.deleting(hit.band, from: $0, frameDuration: fd) } }
    }

    /// Effect Controls diamond: a speed key at clip-local `local` holding the speed evaluated there (nothing plays
    /// differently; the user then sets the speed on the band or the speed graph). False on a frame that already is a key or
    /// outside the clip.
    @discardableResult
    public func addSpeedKey(clip id: Clip.ID, atLocal local: Time) -> Bool {
        guard let tl = activeTimeline, let c = tl.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }) else { return false }
        let fd = tl.frameDuration
        func withKey(_ k: SpeedKeys) -> SpeedKeys? { k.addingKey(at: local, frameDuration: fd)?.keys }
        guard withKey(SpeedKeys.of(c)) != nil else { return false }
        return attempt("Add Speed Keyframe") { try $0.magneticEditSpeedKeys(id, keepingKeys: true) { withKey($0) } }
    }

    /// Effect Controls Speed field on a keyed clip: the speed at clip-local `local` becomes `v` (a key is added there when
    /// the frame has none). Ramps to the neighbor keys follow with their ease; timeline lengths stay. The changes of one
    /// field gesture (`beginSpeedGesture`) are one undo step. A value whose source would run past the media (or below 0)
    /// is refused (false): the clip never silently shortens.
    @discardableResult
    public func setSpeedKeyValue(clip id: Clip.ID, atLocal local: Time, to v: ClipSpeed) -> Bool {
        guard let tl = activeTimeline, tl.tracks.lazy.flatMap(\.clips).contains(where: { $0.id == id }) else { return false }
        let fd = tl.frameDuration
        return attempt("Speed", coalescing: speedGestureKey) {
            try $0.magneticEditSpeedKeys(id, keepingKeys: true, refuseShortening: true) { $0.settingKeySpeed(atLocal: local, to: v, frameDuration: fd) }
        }
    }

    /// Segment index of the speed transition the Speed row edits at clip-local `local`: the ramp under the playhead,
    /// else the next one, else the previous one. nil without any ramp.
    public func speedTransitionSegment(clip id: Clip.ID, atLocal local: Time) -> Int? {
        guard let k = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.speedKeys else { return nil }
        let starts = k.boundaries
        let ramps = k.segments.indices.filter { k.segments[$0].isRamp }
        if let under = ramps.first(where: { starts[$0] <= local && local < starts[$0 + 1] }) { return under }
        return ramps.first(where: { starts[$0] >= local }) ?? ramps.last
    }

    /// Effect Controls diamond on a key: removes the key at `boundary` (segments merge to their average speed).
    @discardableResult
    public func removeSpeedKey(clip id: Clip.ID, boundary: Int) -> Bool {
        guard let k = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.speedKeys,
              k.removingKey(atBoundary: boundary) != nil else { return false }
        return attempt("Remove Speed Keyframe") { try $0.magneticEditSpeedKeys(id) { $0.removingKey(atBoundary: boundary) } }
    }

    /// The speed curve of ramp `segment` of a remapped clip (`.linear` for a straight ramp); nil when that is no ramp.
    public func speedRampEase(clip id: Clip.ID, segment i: Int) -> EaseShape? {
        guard let c = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }), let k = c.speedKeys,
              k.segments.indices.contains(i), k.segments[i].isRamp else { return nil }
        return k.ease(ofSegment: i)
    }

    /// Sets the Bezier curve of a speed transition (the curve popover). The clip keeps its length; linked audio follows.
    /// Calls with `continuesGesture` coalesce with the previous one (one undo step per handle drag).
    @discardableResult
    /// An unchanged curve (or no ramp at `segment`) records nothing and returns false.
    public func setSpeedRampEase(_ shape: EaseShape, clip id: Clip.ID, segment i: Int, continuesGesture: Bool = false) -> Bool {
        guard let k = activeTimeline?.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.speedKeys,
              let edited = k.settingEase(shape, ofSegment: i), edited != k else { return false }
        if !continuesGesture { gestureCounter += 1 }
        return attempt("Speed Transition Curve", coalescing: "remapEase:\(id):\(i):\(gestureCounter)") {
            try $0.magneticEditSpeedKeys(id) { $0.settingEase(shape, ofSegment: i) }
        }
    }

    /// Clip > Remove Speed Ramp: the selected remapped clips play at 100 % over the source they used (Premiere: the effect
    /// and all its keyframes go, the clip length follows).
    @discardableResult
    public func removeTimeRemapping() -> Bool {
        let ids = retimableSelection.filter { $0.speedKeys != nil }.map(\.id)
        guard !ids.isEmpty else { return false }
        return attempt("Remove Speed Ramp") { t in
            for id in ids where t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id })?.speedKeys != nil {
                try t.magneticEditSpeedKeys(id) { k in
                    let h = k.hull
                    return SpeedKeys(constant: .normal, reversed: false, duration: h.duration, origin: h.start)
                }
            }
        }
    }
}
