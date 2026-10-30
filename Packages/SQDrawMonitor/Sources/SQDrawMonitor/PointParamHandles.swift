import Foundation
import SQCore
import SQEditorSession

/// A point parameter (an effect's center, a shape corner, ...) shown as a draggable handle in the Program monitor.
/// `offset` is in sequence px from the canvas center, y down (same space as `ClipTransform.position`).
public struct PointHandle: Sendable, Equatable, Identifiable {
    public var id: String
    public var offset: Vec2
    public init(id: String, offset: Vec2) { self.id = id; self.offset = offset }
}

/// Pure geometry for point-parameter handles: view <-> offset mapping, hit test, snapped drag.
public struct PointHandleGeometry: Sendable, Equatable {
    public struct Snap: Sendable, Equatable {
        public var targets: SnapGuides.Targets
        /// Snap distance in view points.
        public var viewThreshold: Double
        public init(targets: SnapGuides.Targets, viewThreshold: Double) { self.targets = targets; self.viewThreshold = viewThreshold }
    }
    public struct DragResult: Sendable, Equatable {
        public var offset: Vec2
        public var guides: SnapGuides.Result
    }

    public var sequenceSize: CGSize
    public var viewRect: CGRect
    public static let hitRadius: CGFloat = 8

    public init(sequenceSize: CGSize, viewRect: CGRect) { self.sequenceSize = sequenceSize; self.viewRect = viewRect }

    public var viewScale: Double { sequenceSize.width > 0 ? Double(viewRect.width / sequenceSize.width) : 1 }

    public func viewPoint(fromOffset o: Vec2) -> CGPoint {
        CGPoint(x: viewRect.midX + CGFloat(o.x * viewScale), y: viewRect.midY + CGFloat(o.y * viewScale))
    }
    public func offset(fromView p: CGPoint) -> Vec2 {
        Vec2(Double(p.x - viewRect.midX) / viewScale, Double(p.y - viewRect.midY) / viewScale)
    }

    /// Offset <-> 0...1 canvas coordinates (top-left origin), the usual stored form of a point parameter.
    public func normalized(_ o: Vec2) -> Vec2 {
        Vec2(o.x / Double(sequenceSize.width) + 0.5, o.y / Double(sequenceSize.height) + 0.5)
    }
    public func offset(fromNormalized n: Vec2) -> Vec2 {
        Vec2((n.x - 0.5) * Double(sequenceSize.width), (n.y - 0.5) * Double(sequenceSize.height))
    }

    /// Nearest handle within `radius` of `p`.
    public func hitTest(_ p: CGPoint, handles: [PointHandle], radius: CGFloat = PointHandleGeometry.hitRadius) -> String? {
        var best: (String, CGFloat)?
        for h in handles {
            let c = viewPoint(fromOffset: h.offset)
            let d = CGFloat(hypot(Double(c.x - p.x), Double(c.y - p.y)))
            if d <= radius, d < (best?.1 ?? .infinity) { best = (h.id, d) }
        }
        return best?.0
    }

    /// New offset for `handle` dragged from `grab` (where the mouse went down) to `p`. The point keeps its distance to
    /// the cursor; Shift (`lockAxis`) keeps the dominant axis of the movement; `snap` pulls it onto the guide targets.
    public func dragged(_ handle: PointHandle, grabbedAt grab: CGPoint, to p: CGPoint, lockAxis: Bool = false,
                        snap: Snap?) -> DragResult {
        var dx = Double(p.x - grab.x) / viewScale, dy = Double(p.y - grab.y) / viewScale
        if lockAxis { if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 } }
        var o = Vec2(handle.offset.x + dx, handle.offset.y + dy)
        guard let snap, viewScale > 0 else { return DragResult(offset: o, guides: .none) }
        let r = SnapGuides.snap(point: o, targets: snap.targets, threshold: snap.viewThreshold / viewScale)
            .locking(x: lockAxis && dx == 0, y: lockAxis && dy == 0)
        o = Vec2(o.x + r.dx, o.y + r.dy)
        return DragResult(offset: o, guides: r)
    }
}

/// Point parameters are px from the layer's center in its own (unscaled, unrotated) frame; on the canvas they follow the
/// clip's transform like any layer point: `offset = position + R(rotation) * S(scale) * (local - anchor)`.
public enum PointHandleMapping {
    /// Group Transform (an ungrouped Group's Motion) works in canvas px, not in the clip's frame: its Position and Anchor
    /// handles sit at their value (px from the canvas center) and its Scale has no handle.
    public static func hasHandle(kind: String, key: String) -> Bool {
        kind != ClipEffect.groupTransformKind || key != ClipEffect.groupScaleKey
    }
    public static func isCanvasSpace(kind: String) -> Bool { kind == ClipEffect.groupTransformKind }

    public static func offset(kind: String, local l: Vec2, transform t: ClipTransform) -> Vec2 {
        isCanvasSpace(kind: kind) ? l : offset(forLocal: l, transform: t)
    }
    public static func local(kind: String, offset o: Vec2, transform t: ClipTransform) -> Vec2 {
        isCanvasSpace(kind: kind) ? o : local(forOffset: o, transform: t)
    }

    public static func offset(forLocal l: Vec2, transform t: ClipTransform) -> Vec2 {
        let d = Vec2((l.x - t.anchor.x) * t.scale.x, (l.y - t.anchor.y) * t.scale.y)
        let a = t.rotation * .pi / 180
        return Vec2(t.position.x + d.x * cos(a) - d.y * sin(a), t.position.y + d.x * sin(a) + d.y * cos(a))
    }

    public static func local(forOffset o: Vec2, transform t: ClipTransform) -> Vec2 {
        let a = -t.rotation * .pi / 180
        let d = Vec2(o.x - t.position.x, o.y - t.position.y)
        let r = Vec2(d.x * cos(a) - d.y * sin(a), d.x * sin(a) + d.y * cos(a))
        let sx = abs(t.scale.x) > 1e-9 ? t.scale.x : 1, sy = abs(t.scale.y) > 1e-9 ? t.scale.y : 1
        return Vec2(r.x / sx + t.anchor.x, r.y / sy + t.anchor.y)
    }

    // MARK: Corner Warp

    /// Corner Warp stores each corner as an offset (px) from the picture's own corner; its handle sits at the warped corner.
    public static func isCornerOffset(kind: String) -> Bool { kind == ClipEffect.cornerPinKind }

    /// The unwarped corner of parameter `key` in layer-local px from the layer center (y down); nil for a non-corner key.
    public static func cornerBase(key: String, frame: CGSize) -> Vec2? {
        let hw = Double(frame.width) / 2, hh = Double(frame.height) / 2
        switch key {
        case ClipEffect.cornerPinTopLeftKey: return Vec2(-hw, -hh)
        case ClipEffect.cornerPinTopRightKey: return Vec2(hw, -hh)
        case ClipEffect.cornerPinBottomRightKey: return Vec2(hw, hh)
        case ClipEffect.cornerPinBottomLeftKey: return Vec2(-hw, hh)
        default: return nil
        }
    }

    /// Local position of the warped corner for the stored offset `value`.
    public static func cornerLocal(key: String, value: Vec2, frame: CGSize) -> Vec2 {
        let b = cornerBase(key: key, frame: frame) ?? .zero
        return Vec2(b.x + value.x, b.y + value.y)
    }

    /// Stored offset for a handle dragged to layer-local position `local`.
    public static func cornerValue(key: String, local: Vec2, frame: CGSize) -> Vec2 {
        let b = cornerBase(key: key, frame: frame) ?? .zero
        return Vec2(local.x - b.x, local.y - b.y)
    }
}
