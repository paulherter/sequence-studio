import SQUIKit
import Foundation
import SQCore

/// FB-B3 Color Match (Premiere Lumetri "Match"): a reference frame's statistics are stored with the Color effect;
/// Match solves the Color Wheels that bring the clip's frame to them. The host samples the Program frame (`onColorMatch`).
public enum ColorMatchRequest: Sendable, Equatable { case setReference, match }

extension EffectControlsModel {
    /// The stored reference of a Color effect.
    public func colorMatchReference(_ effect: ClipEffect.ID) -> ColorMatchReference? {
        clip?.effects.first { $0.id == effect }?.colorData.match
    }

    /// The Color effect as edited at the playhead (keyframed wheels evaluated there).
    func colorMatchEffect(_ effect: ClipEffect.ID) -> ColorEffect? {
        guard let c = clip, let e = c.effects.first(where: { $0.id == effect }), e.isColor else { return nil }
        return e.colorEffect(atLocal: c.colorEditTime(atPlayhead: playhead, frameDuration: frameDuration), id: 1)
    }

    /// Why Match cannot run (nil = it can). `source` defaults to the clip's own interpretation (else Rec. 709).
    public func colorMatchBlock(_ effect: ClipEffect.ID, source: ColorSpaceID? = nil) -> String? {
        guard let e = colorMatchEffect(effect) else { return SQL10n.string("No Color effect.") }
        if clip.map({ $0.colorEditTime(atPlayhead: playhead, frameDuration: frameDuration) == nil }) ?? true {
            return SQL10n.string("Park the playhead on this clip to match it.")
        }
        let src = source ?? clip.flatMap { c in colorSourceOf?(c) ?? c.color.source } ?? .rec709
        return ColorMatchSolver.blockReason(effect: e, source: src,
                                            reference: colorMatchReference(effect)).map(ColorBlockText.localized)
    }

    /// Stores (or with nil removes) the reference of a Color effect. One undo step.
    public func setColorMatchReference(_ effect: ClipEffect.ID, _ ref: ColorMatchReference?) {
        guard var c = workingClip, let i = c.effects.firstIndex(where: { $0.id == effect }), c.effects[i].isColor else { return }
        var g = c.effects[i].colorData
        guard g.match != ref else { return }
        g.match = ref
        c.effects[i].grade = g
        commit(c, ref == nil ? "Clear Match Reference" : "Set Match Reference")
    }

    /// The clip's frame as shown (display-encoded samples) is matched to the reference: Color Wheels and Wheels Saturation
    /// are set (keyed at the playhead when they are keyframed). One undo step. False when blocked or nothing changes.
    @discardableResult
    public func applyColorMatch(_ effect: ClipEffect.ID, display: [SIMD3<Float>], source: ColorSpaceID? = nil) -> Bool {
        guard colorMatchBlock(effect, source: source) == nil, let ref = colorMatchReference(effect),
              let e = colorMatchEffect(effect),
              let w = ColorMatchSolver.solve(display: display, current: e.wheels, reference: ref.stats),
              var c = workingClip, let i = c.effects.firstIndex(where: { $0.id == effect }) else { return false }
        let t = c.colorEditTime(atPlayhead: playhead, frameDuration: frameDuration)
        var ne = c.effects[i].colorEffect(atLocal: t, id: 1)
        ne.wheels = w
        c.effects[i].setColorEffect(ne, atLocal: t)
        commit(c, "Match Color")
        return true
    }

    /// The Match row's buttons: the host samples the Program frame and calls back into the model.
    public func requestColorMatch(_ effect: ClipEffect.ID, _ request: ColorMatchRequest) {
        onColorMatch?(effect, request)
    }
}
