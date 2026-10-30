import Foundation
import SQCore

// FB-T3: the Custom curve of a motion effect (Move, Zoom, Pop, Fade, Shake), edited in the effect itself with the same
// curve popover as keyframes (button next to the Curve pop-up). Editing selects Custom; the Hold chip selects Hold.

extension EffectControlsModel {
    /// The motion effect `effect` on the shown clip, if it has a Curve.
    func motionCurveEffect(_ effect: ClipEffect.ID) -> ClipEffect? {
        guard let e = clip?.effects.first(where: { $0.id == effect }), e.isMotionPreset,
              EffectCatalog.param(e.kind, ClipEffect.motionCurveKey) != nil else { return nil }
        return e
    }

    /// The curve the editor shows: the Custom bezier when Custom is picked, else the picked curve's shape where it has one.
    public func motionCurveShape(_ effect: ClipEffect.ID) -> EaseShape? {
        guard let e = motionCurveEffect(effect) else { return nil }
        let kind = MotionCurve(rawValue: Int((e.parameters[ClipEffect.motionCurveKey]?.value ?? 0).rounded())) ?? .premiereDefault
        // Same curves `MotionCurve.ease` evaluates, so the editor starts from what plays.
        func bez(_ c: EasingCurve) -> EaseShape { EaseShape(interpolation: .bezier, out: c.outHandle, in: c.inHandle) }
        switch kind {
        case .hold: return .hold
        case .linear, .autoBezier: return .linear
        case .premiereDefault: return bez(.premiereDefault)
        case .continuousBezier: return bez(.easeInOut)
        case .easeIn: return bez(.easeIn)
        case .easeOut: return bez(.easeOut)
        case .easeOut100: return bez(.easeOut100)
        case .easeIn100: return bez(.easeIn100)
        case .fastStart: return bez(.fastStart)
        // Custom, and the families that are not one bezier: the effect's own Custom curve.
        default: return (e.customCurve ?? .default).shape
        }
    }

    /// Writes `shape` as the effect's Custom curve and picks Custom (Hold picks Hold). A drag is one undo step.
    public func setMotionCurve(_ effect: ClipEffect.ID, shape: EaseShape) {
        guard var c = workingClip, let i = c.effects.firstIndex(where: { $0.id == effect }), c.effects[i].isMotionPreset else { return }
        if shape.interpolation.isHold {
            c.effects[i].parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(MotionCurve.hold.rawValue))
        } else {
            c.effects[i].setCustomCurve(CubicBezierEase(shape))
            c.effects[i].parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(MotionCurve.custom.rawValue))
        }
        commit(c, "Edit Curves")
    }
}

/// The curve popover's source for one motion effect's Curve.
@MainActor
public final class MotionCurveEaseSource: EaseCurveSource {
    public let model: EffectControlsModel
    public let effect: ClipEffect.ID

    public init(model: EffectControlsModel, effect: ClipEffect.ID) { self.model = model; self.effect = effect }

    public var easeReading: EaseReading { model.motionCurveShape(effect).map { .common($0) } ?? .empty }
    public func applyEaseShape(_ shape: EaseShape) { model.setMotionCurve(effect, shape: shape) }
    public func beginGesture() { model.beginGesture() }
    public func endGesture() { model.endGesture() }
    public var sessionEasingCurves: [EasingCurve] { model.easingLibrary.userCurves }
    public func observeEaseInputs() { _ = model.clip }
    public var emptyEaseHint: String { "Select a motion effect" }
}
