import Foundation
import SQCore

extension RenderNode {
    /// W7.1 motion blur of one leaf layer: one copy per sub-frame transform, each at 1/n of the layer's opacity, summed as
    /// premultiplied color in a transparent `format` image (a `.pair` whose second side holds all copies after the first:
    /// that side is drawn additively), then composited with the layer's blend mode. The caller's adjustments to the
    /// request's transform (a text box offset, say) are carried onto every sample.
    static func motionBlurred(_ layer: RenderLayer, request: LayerRequest, samples mb: MotionBlurSamples) -> RenderNode {
        let n = Double(mb.transforms.count)
        let base = request.transform, actual = layer.transform
        func ratio(_ a: Double, _ b: Double) -> Double { b != 0 ? a / b : 1 }
        let copies: [RenderNode] = mb.transforms.map { s in
            var l = layer
            var t = s
            if actual != base {
                t.position = s.position + (actual.position - base.position)
                t.scale = Vec2(s.scale.x * ratio(actual.scale.x, base.scale.x), s.scale.y * ratio(actual.scale.y, base.scale.y))
                t.rotation = s.rotation + (actual.rotation - base.rotation)
                t.anchor = s.anchor + (actual.anchor - base.anchor)
                t.tiltX = s.tiltX + (actual.tiltX - base.tiltX); t.tiltY = s.tiltY + (actual.tiltY - base.tiltY)
            }
            t.opacity = min(max(actual.opacity, 0), 1) / n
            l.transform = t
            l.blendMode = .normal
            return .layer(l)
        }
        let node = RenderNode.pair(format: mb.format, first: [copies[0]], second: Array(copies.dropFirst()))
        return layer.blendMode == .normal ? node : .blended(node, layer.blendMode)
    }
}
