import Foundation
import SQCore

/// Effect instances in Effect Controls: fx toggle for the fixed sections, reorder, duplicate, cut / clear, blend mode.
/// Every function is one `commit` = one undo step.
extension EffectControlsModel {
    // MARK: fx toggle of Motion and Opacity

    /// Motion, Opacity and every applied effect have an fx toggle; Volume does not (audio has its own side).
    public func hasFXToggle(_ s: EffectSection) -> Bool { s != .volume }

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
        guard copyEffect(s) else { return false }
        lastCopyWasKeys = false
        return removeEffect(s)
    }

    /// The effect copy button of a header menu: Paste then pastes the effect, not keys.
    public func markEffectCopied() { lastCopyWasKeys = false }

    // MARK: Blend mode

    public var blendMode: BlendMode { clip?.blendMode ?? .normal }

    public func setBlendMode(_ m: BlendMode) {
        guard var c = clip, c.kind == .video, c.blendMode != m else { return }
        c.blendMode = m
        commit(c, "Change Blend Mode")
    }
}
