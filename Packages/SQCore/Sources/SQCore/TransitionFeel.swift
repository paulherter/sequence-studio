import Foundation

// Transition feel defaults (DECISIONS 2026-10-06 "Transition feel defaults", research in docs/research/TRANSITION-FEEL.md).
//
// A NEW transition gets a "factory look": a settling curve (a long ease-out, an overshoot where a physical move fits) written
// into the transition itself, plus a longer default length (`TransitionKind.presetDuration`). Nothing changes for what is
// already stored: a transition without an own curve / parameters keeps resolving to `TransitionKind.defaultEasing` and the
// parameter defaults, so old projects, presets and user defaults render exactly as before. The curves are ordinary
// `EasingCurve`s / `MotionCurve`s of the one easing vocabulary, editable with the one curve editor.

extension EasingCurve {
    /// Runs past the end by about 10 % and comes back (`MotionCurve.backOut`'s shape as one bezier): cubic-bezier(.34, 1.56, .64, 1).
    public static let overshoot = builtIn(13, "Overshoot", .bezier, out: EaseHandle(dx: 0.34, dy: 1.56), in: EaseHandle(dx: 0.36, dy: 0))
}

extension TransitionKind {
    /// Zoom In / Out: how far the picture zooms, percent (100 = no move).
    public static let zoomAmountKey = "amount"
    public static let zoomAmountSpec = EffectParamSpec(key: zoomAmountKey, title: "Amount", unit: "%",
                                                       defaultValue: 110, range: 100...200, step: 0.5, decimals: 1)

    public var isZoomThrough: Bool { self == .zoomIn || self == .zoomOut }

    /// Stores parameters in `Transition.params` (element transitions, Zoom In / Out's Amount).
    public var hasParams: Bool { !elementParams.isEmpty }

    /// The curve a new transition of this kind starts with. Dissolve weights get a soft S, moves a long ease-out
    /// (fast start, 90 % of the way in the first half, the rest settles), Spin overshoots. Kinds not named keep `defaultEasing`.
    public var factoryEasing: EasingCurve {
        switch self {
        case .crossDissolve, .lightNoise: .easeInOut
        case .push, .slide, .whip, .zoomPop, .iris, .crossZoom, .flash: .easeOut100
        // A rotation may swing past its rest; a slide, push or zoom of a full frame must not (it would show what is behind).
        case .spin: .overshoot
        default: defaultEasing
        }
    }

    /// The parameters a new transition of this kind starts with (`atHead`: on a clip's head = it plays in). nil = none.
    /// Move / Zoom arrive on a long ease-out and leave accelerating; Pop rises in 40 % of its length and settles over the
    /// rest (both halves smooth); Zoom In / Out store their Amount, which also selects the settling zoom (`zoomLayers`).
    public func factoryParams(atHead: Bool) -> [String: Double]? {
        switch self {
        case .move, .zoom:
            return [ClipEffect.motionCurveKey: Double((atHead ? MotionCurve.easeOut100 : .easeIn100).rawValue)]
        case .pop:
            return [ClipEffect.motionCurveKey: Double(MotionCurve.continuousBezier.rawValue),
                    ClipEffect.popFromKey: 85, ClipEffect.popPeakKey: 105, ClipEffect.popPeakAtKey: 40]
        case .zoomIn, .zoomOut:
            return [Self.zoomAmountKey: Self.zoomAmountSpec.defaultValue]
        default:
            return nil
        }
    }
}

extension Transition {
    /// Zoom In / Out: the stored Amount as a scale (1.1 = 110 %); nil = none stored (the older look, `TransitionRender.zoomAmount`).
    public var zoomAmount: Double? { Self.zoomAmount(kind, params) }

    static func zoomAmount(_ kind: TransitionKind, _ params: [String: Double]?) -> Double? {
        guard kind.isZoomThrough, let v = params?[TransitionKind.zoomAmountKey], v.isFinite else { return nil }
        let r = TransitionKind.zoomAmountSpec.range
        return min(max(v, r.lowerBound), r.upperBound) / 100
    }

    /// The transition carries a written look and it is exactly its kind's factory look (curve and parameters). One without
    /// an own curve and parameters (every older one) does not: nothing was written into it.
    public var carriesFactoryLook: Bool {
        guard easing != nil || params != nil else { return false }
        var f = self
        f.applyFactoryLook()
        return f.easing == easing && f.params == params
    }

    /// Makes this transition's look the factory look of its kind. `replacingEasing` false keeps an own curve.
    public mutating func applyFactoryLook(replacingEasing: Bool = true) {
        if replacingEasing {
            let f = kind.factoryEasing
            easing = kind.usesEasing && f != kind.defaultEasing ? f : nil
        }
        params = kind.factoryParams(atHead: outgoing == nil)
    }
}

extension TransitionLayer {
    public var zoomAmount: Double? { Transition.zoomAmount(kind, params) }

    public mutating func applyFactoryLook(replacingEasing: Bool = true) {
        if replacingEasing {
            let f = kind.factoryEasing
            easing = kind.usesEasing && f != kind.defaultEasing ? f : nil
        }
        params = kind.factoryParams(atHead: true)
    }

    /// Sets one parameter (clamped to its range); an unknown key or a value that is not finite changes nothing.
    public mutating func setParam(_ key: String, _ value: Double) {
        guard let spec = kind.elementParam(key), value.isFinite else { return }
        var p = params ?? [:]
        p[key] = min(max(value, spec.range.lowerBound), spec.range.upperBound)
        params = p
    }

    public var carriesFactoryLook: Bool {
        guard easing != nil || params != nil else { return false }
        var f = self
        f.applyFactoryLook()
        return f.easing == easing && f.params == params
    }

    /// Changes the kind as `Timeline.changeTransitionKind`.
    public mutating func changeKind(to new: TransitionKind) {
        guard new != kind else { return }
        let look = carriesFactoryLook, amount = params?[TransitionKind.zoomAmountKey]
        let zoom = kind.isZoomThrough && new.isZoomThrough
        kind = new
        params = nil
        if look { applyFactoryLook() } else if zoom, let amount { params = [TransitionKind.zoomAmountKey: amount] }
    }
}

extension Timeline {
    /// Gives transition `id` the factory look of its kind (a newly added transition, "Reset" without a user default).
    public mutating func applyFactoryLook(_ id: Transition.ID, replacingEasing: Bool = true) throws {
        guard let ti = tracks.firstIndex(where: { $0.transitions.contains { $0.id == id } }),
              let ni = tracks[ti].transitions.firstIndex(where: { $0.id == id }) else { throw EditError.clipNotFound }
        guard !tracks[ti].isLocked else { throw EditError.trackLocked }
        tracks[ti].transitions[ni].applyFactoryLook(replacingEasing: replacingEasing)
    }

    /// Changes the kind of transition `id` like `setTransition(kind:)` (the curve stays, the parameters go). Only a
    /// transition that carries exactly its old kind's factory look gets the new kind's; one without an own curve stays
    /// without (it keeps resolving to the kind's stored default, as before). Zoom In <-> Zoom Out keeps a stored Amount.
    public mutating func changeTransitionKind(_ id: Transition.ID, to kind: TransitionKind) throws {
        guard let old = transition(id)?.transition else { throw EditError.clipNotFound }
        try setTransition(id, kind: kind)
        guard old.kind != kind else { return }
        if old.carriesFactoryLook {
            try applyFactoryLook(id)
        } else if old.kind.isZoomThrough, kind.isZoomThrough, let amount = old.params?[TransitionKind.zoomAmountKey] {
            try setTransition(id, params: [TransitionKind.zoomAmountKey: amount])
        }
    }
}
