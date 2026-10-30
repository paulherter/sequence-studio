import Foundation
import SQCore
import SQText

extension GraphicsEditor {
    /// A corner-handle drag on a text layer: the font size (tracking, line spacing, area box) follows the handle by the
    /// same factor the core resize would have scaled the layer by, Scale stays, and the opposite corner stays put.
    /// Nil when `id` is not an unlocked text layer or nothing changes (the caller then runs the plain resize).
    /// shortcut: a Follow-pinned text layer is edited as stored (not as drawn); upgrade when Follow resizes text boxes.
    static func resizingText(_ doc: GraphicsDocument, id: UUID, corner: GraphicsCorner, to p: Vec2, atLocal t: Time,
                             text: GraphicsTextMeasure?) -> GraphicsDocument? {
        guard var l = doc.layer(id), !l.isLocked, case .text(let ref) = l.content,
              let decoded = try? TextGenerator.decode(ref),
              let before = l.corners(atLocal: t, text: text) else { return nil }
        // The factor: what the core resize does to Scale (geometric mean of the axis ratios; edge handles stretch one axis).
        var probe = doc
        probe.resize(id, corner: corner, to: p, atLocal: t, text: text)
        guard let s0 = Optional(l.animation.scale.value(atLocal: t)), let s1 = probe.layer(id)?.animation.scale.value(atLocal: t),
              abs(s0.x) > 1e-9, abs(s0.y) > 1e-9 else { return nil }
        let f = abs((s1.x / s0.x) * (s1.y / s0.y)).squareRoot()
        guard f.isFinite, f > 0, abs(f - 1) > 1e-9 else { return nil }
        guard let new = try? TextGenerator.makeRef(template: decoded.0.resized(by: f), animations: decoded.1) else { return nil }
        l.content = .text(ref: new)
        if let after = l.corners(atLocal: t, text: text) {
            let k = corner.opposite.rawValue
            let d = before[k] - after[k]
            if d != .zero { l.animation.position.set(l.animation.position.value(atLocal: t) + d, atLocal: t) }
        }
        var out = doc
        out.update(id) { $0 = l }
        return out
    }
}
