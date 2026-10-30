import Foundation
import SQCore

/// Effect instances in Effect Controls: fx toggle for the fixed sections, reorder, duplicate, cut / clear, blend mode.
/// Every function is one `commit` = one undo step.
extension EffectControlsModel {
    // MARK: fx toggle of Motion and Opacity

    /// Motion, Opacity and every applied effect have an fx toggle; Volume does not (audio has its own side).
    public func hasFXToggle(_ s: EffectSection) -> Bool { s != .volume && s != .speed }

    // MARK: Reorder and duplicate

    /// Position of an effect section among the applied effects (0 = first = evaluated first); nil for fixed sections.
    public func effectIndex(_ s: EffectSection) -> Int? {
        guard let id = s.effectID else { return nil }
        return clip?.effects.firstIndex { $0.id == id }
    }

    /// Moves an applied effect to list position `index` (clamped). The list order is the evaluation order, so the picture
    /// changes accordingly. Returns false when nothing moved.
    @discardableResult
    public func moveEffect(_ s: EffectSection, toIndex index: Int) -> Bool {
        guard let id = s.effectID, var c = clip, c.moveEffect(id, to: index) else { return false }
        commit(c, "Reorder Effects")
        return true
    }

    /// A second instance with the same values right behind the original.
    @discardableResult
    public func duplicateEffect(_ s: EffectSection) -> Bool {
        guard let id = s.effectID, var c = clip, c.duplicateEffect(id) != nil else { return false }
        commit(c, "Duplicate Effect")
        return true
    }

    /// Where a header dragged to `y` (content coordinates) lands among the effect headers, given each header's vertical
    /// midpoint in list order. Pure: the view feeds it the row geometry.
    public static func dropIndex(forY y: CGFloat, midpoints: [CGFloat], dragging from: Int) -> Int {
        var target = 0
        for (i, m) in midpoints.enumerated() where i != from && y > m { target += 1 }
        return min(target, max(midpoints.count - 1, 0))
    }

    // MARK: Cut and Clear (effect header menu)

    /// Cut: copy the effect, then remove it.
    @discardableResult
    public func cutEffect(_ s: EffectSection) -> Bool {
        guard canRemoveEffect(s), copyEffect(s) else { return false }
        lastCopyWasKeys = false
        return removeEffect(s)
    }

    /// The effect copy button of a header menu: Paste then pastes the effect, not keys.
    public func markEffectCopied() { lastCopyWasKeys = false }

    // MARK: Blend mode

    public var blendMode: BlendMode { clip?.blendMode ?? .normal }

    public func setBlendMode(_ m: BlendMode) {
        guard var c = clip, c.kind == .video, c.blendMode != m || isBlendModeMixed else { return }
        c.blendMode = m
        // Multi-select: every selected picture clip gets the mode, one undo step.
        let others = isMulti ? (peerGestureBase ?? peers).map { p -> Clip in
            var o = p
            if o.kind == .video { o.blendMode = m }
            return o
        } : nil
        commit(c, "Change Blend Mode", peers: others)
    }
}

// MARK: Speed section (clip retime through the session, one undo step each)

extension EffectControlsModel {
    /// Constant speed of the shown clip in percent (100 = normal).
    public var speedPercent: Double {
        guard let c = clip else { return 100 }
        // Animated speed: the field shows the speed at the playhead (like every keyframed row).
        if let k = c.speedKeys, speedIsAnimated {
            let last = max(k.duration - frameDuration, .zero)
            return k.speedValue(at: min(max(localPlayhead, .zero), last)) * 100
        }
        return Double(c.speed.num) / Double(c.speed.den) * 100
    }
    public var isReversed: Bool { clip?.reversed ?? false }
    public var keepsPitch: Bool { clip?.keepsPitch ?? true }

    public func setSpeedPercent(_ percent: Double) {
        guard let c = clip, percent.isFinite, percent > 0 else { return }
        // Animated speed: the value is set at the playhead (a key appears there), neighbors ramp with their ease. The
        // playhead is clamped into the clip, so a typed value never falls through to the constant-speed path (which would
        // rescale the whole track). With several clips selected only the shown clip takes the value.
        if speedIsAnimated {
            speedSession?.setSpeedKeyValue(clip: c.id, atLocal: min(max(localPlayhead, .zero), max(c.duration - frameDuration, .zero)),
                                           to: ClipSpeed(percent: percent))
            return
        }
        speedSession?.applySpeed(SpeedChange(speed: ClipSpeed(percent: percent)))
    }
    public func beginSpeedGesture() { speedSession?.beginSpeedGesture() }
    public func endSpeedGesture() { speedSession?.endSpeedGesture() }
    public func setReversedClip(_ on: Bool) { speedSession?.setReversed(on) }
    /// How the frames between two source frames are filled (the Speed dialog's choice; one undo step).
    public var timeInterpolation: TimeInterpolation { clip?.timeInterpolation ?? .frameSampling }
    public func setTimeInterpolation(_ t: TimeInterpolation) { speedSession?.applySpeed(SpeedChange(timeInterpolation: t)) }
    public func setKeepsPitchClip(_ on: Bool) { speedSession?.applySpeed(SpeedChange(keepsPitch: on)) }
    func resetSpeed() { speedSession?.applySpeed(SpeedChange(speed: .normal, reversed: false, keepsPitch: true, timeInterpolation: .frameSampling)) }
}

// MARK: Color Key eyedropper (portable half; the Mac monitor sampler is EffectControlsModel+KeyPick.swift)

extension EffectControlsModel {
    /// The Key Hue row of a Color Key effect.
    public static func isKeyHue(_ p: EffectProperty) -> Bool {
        guard case .fx(_, let kind, let key) = p else { return false }
        return kind == ClipEffect.ultraKeyKind && key == ClipEffect.keyHueKey
    }

    static let keyPickGrayNotice = "That spot is gray or black: pick a spot of the screen color."

    /// Sets Key Hue to the hue of a linear-light sample (one undo step); a gray or black spot only shows the notice.
    public func applyKeyColor(_ p: EffectProperty, linear rgb: SIMD3<Float>) {
        guard Self.isKeyHue(p) else { return }
        guard let hue = KeyColorPick.hue(fromLinear: rgb) else { onNotice?(Self.keyPickGrayNotice); return }
        _ = setValue(p, to: hue)
    }

    /// An sRGB-encoded sample (a screen pick) as linear light, for `applyKeyColor`.
    public static func linear(fromSRGB r: Double, _ g: Double, _ b: Double) -> SIMD3<Float> {
        func lin(_ v: Double) -> Float {
            let c = min(max(v, 0), 1)
            return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
        }
        return SIMD3(lin(r), lin(g), lin(b))
    }
}
