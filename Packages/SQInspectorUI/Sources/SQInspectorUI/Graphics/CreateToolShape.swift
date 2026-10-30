import Foundation
import SQCore

extension GraphicsCanvasMapping {
    /// The item box that shows as the upright box from `a` to `b` on the picture (sequence px): its center in the
    /// Graphic's canvas, its size with the clip's scale taken out, and the item rotation that undoes the clip's rotation.
    public func canvasBox(fromSequence a: Vec2, _ b: Vec2) -> (center: Vec2, size: Vec2, rotation: Double) {
        let center = canvasPoint(fromSequence: Vec2((a.x + b.x) / 2, (a.y + b.y) / 2))
        let rad = transform.rotation * .pi / 180
        let sx = max(abs(transform.scale.x), 1e-9), sy = max(abs(transform.scale.y), 1e-9)
        // How long a canvas unit along the item's own axes is on the picture (the same on both for a uniform scale).
        let along = (sx * cos(rad) * sx * cos(rad) + sy * sin(rad) * sy * sin(rad)).squareRoot()
        let across = (sx * sin(rad) * sx * sin(rad) + sy * cos(rad) * sy * cos(rad)).squareRoot()
        return (center, Vec2(abs(b.x - a.x) / max(along, 1e-9), abs(b.y - a.y) / max(across, 1e-9)), -transform.rotation)
    }
}

extension GraphicsEditor {
    /// The item a Create drag from `a` to `b` (sequence px, offsets from the picture center) makes in a Graphic shown
    /// through `mapping`: it lands where the drag's preview was, also when the clip is moved, scaled or rotated.
    public static func createdShape(_ kind: ShapeKind, from a: Vec2, to b: Vec2, mapping: GraphicsCanvasMapping, canvas: Vec2) -> GraphicsLayer {
        let w = Int(canvas.x), h = Int(canvas.y)
        if kind == .line || kind == .arrow {
            var l = GraphicsLayer.line(from: mapping.canvasPoint(fromSequence: a), to: mapping.canvasPoint(fromSequence: b), canvasWidth: w, canvasHeight: h)
            if kind == .arrow { l.content = .shape(kind: .arrow) }
            return l
        }
        let box = mapping.canvasBox(fromSequence: a, b)
        let rect = GraphicsRect(minX: box.center.x - box.size.x / 2, minY: box.center.y - box.size.y / 2,
                                maxX: box.center.x + box.size.x / 2, maxY: box.center.y + box.size.y / 2)
        var l = GraphicsLayer.shape(kind, box: rect, canvasWidth: w, canvasHeight: h)
        if box.rotation != 0 { l.animation.rotation = AnimatedProperty(box.rotation) }
        return l
    }
}
