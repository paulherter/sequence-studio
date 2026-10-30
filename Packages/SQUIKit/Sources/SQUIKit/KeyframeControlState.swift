import Foundation

// Portable (Windows too): the keyframe control vocabulary every Controls row maps its model onto; the AppKit views
// (`KeyframeControls`, `KeyframeToggleView`) draw it on the Mac, SQDrawKit draws it elsewhere.

/// Keyframe state shown by the animate ring (DESIGN-SPEC §4, `KeyframeToggleView.drawRing`).
/// The ring lives in the row (F11: one animate control per row), never inside a ScrubField.
public enum ScrubKeyframeState: Sendable, Equatable {
    case none       // property not animated: gray ring, hollow diamond
    case onKey      // playhead on a keyframe: accent-filled ring, white diamond
    case between    // animated, playhead between keys: accent ring, gray diamond
}

/// What the keyframe control of one property shows (INTERACTION-AUDIT §2). Pure, so every panel maps its model the
/// same way: not animated = gray ring, no navigation; animated = accent ring plus prev / diamond / next, the ring and
/// the diamond filled while the playhead sits on a key.
public struct KeyframeControlState: Sendable, Equatable {
    public var ring: ScrubKeyframeState
    /// Prev / diamond / next are shown only while the property is animated.
    public var showsNavigation: Bool
    public var canGoPrevious: Bool
    public var canGoNext: Bool
    /// Add / remove a key at the playhead (false while the playhead is outside the clip).
    public var canToggleKey: Bool
    /// The diamond is filled (playhead on a key).
    public var keyIsOn: Bool

    public init(ring: ScrubKeyframeState, showsNavigation: Bool, canGoPrevious: Bool, canGoNext: Bool,
                canToggleKey: Bool, keyIsOn: Bool) {
        self.ring = ring; self.showsNavigation = showsNavigation
        self.canGoPrevious = canGoPrevious; self.canGoNext = canGoNext
        self.canToggleKey = canToggleKey; self.keyIsOn = keyIsOn
    }

    /// Not animated: gray ring, nothing else.
    public static let off = KeyframeControlState(ring: .none, showsNavigation: false, canGoPrevious: false,
                                                 canGoNext: false, canToggleKey: false, keyIsOn: false)

    /// - animated: the property has keyframes; onKey: the playhead is on one of them;
    /// - hasPrevious / hasNext: a key exists before / after the playhead; playheadInRange: the playhead is inside the clip.
    public static func resolve(animated: Bool, onKey: Bool, hasPrevious: Bool, hasNext: Bool,
                               playheadInRange: Bool) -> KeyframeControlState {
        guard animated else { return .off }
        let on = onKey && playheadInRange
        return KeyframeControlState(ring: on ? .onKey : .between, showsNavigation: true, canGoPrevious: hasPrevious,
                                    canGoNext: hasNext, canToggleKey: playheadInRange, keyIsOn: on)
    }
}
