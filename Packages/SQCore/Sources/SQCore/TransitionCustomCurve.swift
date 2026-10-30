import Foundation

// "Custom" easing of a transition: a hand-drawn bezier (the same editor shape as keyframe / speed graphs) stored in the
// transition's / layer's / preset's `EasingCurve`. No format change: `EasingCurve` already encodes interpolation + both handles.

extension EasingCurve {
    /// The curves the Transition controls offer by name (hold would turn it into a cut at the end).
    public static let transitionPresets: [EasingCurve] = [.linear, .easeInOut, .easeIn, .easeOut, .fastStart, .fastEnd,
                                                         .easeOut100, .easeIn100, .overshoot]

    /// Fixed id: equal shapes give equal curves, so nothing churns while a handle is dragged.
    private static let transitionCustomID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!

    /// A hand-drawn curve for a transition. nil for hold.
    public static func transitionCustom(_ shape: EaseShape) -> EasingCurve? {
        guard !shape.interpolation.isHold else { return nil }
        return EasingCurve(id: transitionCustomID, shape: shape, name: "Custom")
    }

    /// What an edit of the curve editor stores: the named preset when the shape matches one, else a custom curve. nil for hold.
    public static func transitionCurve(for shape: EaseShape) -> EasingCurve? {
        guard let custom = transitionCustom(shape) else { return nil }
        return custom.matchingTransitionPreset ?? custom
    }

    /// The named preset with this curve's shape, nil when it is a custom curve.
    public var matchingTransitionPreset: EasingCurve? {
        EasingCurve.transitionPresets.first { $0.shape.isApproximatelyEqual(to: shape) }
    }

    public var isCustomForTransition: Bool { matchingTransitionPreset == nil }

    /// Incoming weight of a dissolve at normalized time `t`. A drawn curve may overshoot (free Y); a mix weight must not.
    public func mixWeight(_ t: Double) -> Double { min(max(progress(t), 0), 1) }
}
