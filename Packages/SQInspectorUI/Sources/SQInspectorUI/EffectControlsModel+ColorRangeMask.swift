import Foundation
import SQCore

/// v87 Color range mask UI: adding one and the edits of its rows (color, tolerance, softness). Evaluation is in SQCore /
/// SQRender. Each edit is one undo step; a drag inside a gesture (`beginGesture` ... `endGesture`) coalesces into one.
extension EffectControlsModel {
    /// Color range masks of the clip (their rows differ: a color, tolerance and softness instead of a path, no Feather / Expansion).
    public var colorRangeMaskIDs: Set<ClipMask.ID> {
        Set(clip?.masks.filter { $0.source == .colorRange }.map(\.id) ?? [])
    }

    /// Adds a Color range mask keying `key`, one undo step "Add Mask"; selects it. Returns its id.
    @discardableResult
    public func addColorRangeMask(key: ColorRangeKey = .default) -> ClipMask.ID? {
        guard var c = workingClip, c.kind == .video else { return nil }
        let m = ClipMask.makeColorRange(key: key)
        c.masks.append(m)
        commit(c, "Add Mask")
        selectedSection = .mask(m.id)
        return m.id
    }

    /// The key of a Color range mask (nil for any other mask).
    public func colorRange(of id: ClipMask.ID) -> ColorRangeKey? {
        guard let m = clip?.mask(id), m.source == .colorRange else { return nil }
        return m.colorRange
    }

    /// Changes the key of a Color range mask, one undo step (inside a gesture it joins the gesture's step).
    public func setMaskColorRange(_ id: ClipMask.ID, _ key: ColorRangeKey) {
        guard var c = workingClip, let m = c.mask(id), m.source == .colorRange, m.colorRange != key else { return }
        c.updateMask(id) { $0.colorRange = key }
        commit(c, "Change Mask Color Range")
    }
}
