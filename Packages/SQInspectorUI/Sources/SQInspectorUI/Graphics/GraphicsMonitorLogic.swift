#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore

/// Snapping of graphic layers on the Program monitor: frame edges, frame center and the safe margins (the same
/// `SnapGuides` targets the clip overlay uses). All values are canvas px of the graphic (offset from its center, y down).
public enum GraphicsSnap {
    /// The frame's snap lines in the graphic's canvas space, or nil when the graphic is rotated (the frame lines are no
    /// longer axis-aligned there, so nothing snaps). The frame is the sequence canvas; the graphic's Motion maps it back.
    public static func targets(canvas: Vec2, mapping: GraphicsCanvasMapping, safeAreas: [SafeArea] = SafeArea.allCases) -> SnapGuides.Targets? {
        let t = mapping.transform
        guard abs(t.rotation.truncatingRemainder(dividingBy: 360)) < 1e-9 else { return nil }
        let sx = abs(t.scale.x) > 1e-9 ? t.scale.x : 1e-9, sy = abs(t.scale.y) > 1e-9 ? t.scale.y : 1e-9
        let seq = SnapGuides.targets(canvas: CGSize(width: canvas.x, height: canvas.y), others: [], safeAreas: safeAreas)
        return SnapGuides.Targets(xs: seq.xs.map { ($0 - t.position.x) / sx + t.anchor.x },
                                  ys: seq.ys.map { ($0 - t.position.y) / sy + t.anchor.y })
    }

    /// View points as canvas px: the same on-screen distance stays the same however far the graphic is scaled down.
    /// `viewScale`: view points per sequence px.
    public static func threshold(viewPoints: Double, viewScale: Double, mapping: GraphicsCanvasMapping) -> Double {
        let s = max(abs(mapping.transform.scale.x), abs(mapping.transform.scale.y), 1e-9)
        return viewPoints / (max(viewScale, 1e-9) * s)
    }

    /// A single dragged point (a resize handle) pulled onto the nearest line.
    public static func snapPoint(_ p: Vec2, targets: SnapGuides.Targets, threshold: Double) -> (point: Vec2, guides: SnapGuides.Result) {
        let r = SnapGuides.snap(point: p, targets: targets, threshold: threshold)
        return (Vec2(p.x + r.dx, p.y + r.dy), r)
    }
}

/// One move drag: follows the pointer, pulls the selection's box (edges and center) onto the snap lines. Returns the
/// canvas delta still to apply, so the caller's incremental `translate` ends exactly on the snapped position.
public struct GraphicsMoveSnapper {
    private let startBox: GraphicsRect
    private let start: Vec2
    private let targets: SnapGuides.Targets?
    private let threshold: Double
    private var applied = Vec2.zero

    public init(startBox: GraphicsRect, start: Vec2, targets: SnapGuides.Targets?, threshold: Double) {
        self.startBox = startBox; self.start = start; self.targets = targets; self.threshold = threshold
    }

    public mutating func step(to q: Vec2, snapping: Bool) -> (delta: Vec2, guides: SnapGuides.Result) {
        let raw = q - start
        var want = raw
        var guides = SnapGuides.Result.none
        if snapping, let targets {
            let box = CGRect(x: startBox.minX + raw.x, y: startBox.minY + raw.y, width: startBox.width, height: startBox.height)
            guides = SnapGuides.snap(box: box, targets: targets, threshold: threshold)
            want = Vec2(raw.x + guides.dx, raw.y + guides.dy)
        }
        let delta = want - applied
        applied = want
        return (delta, guides)
    }
}

extension GraphicsDocument {
    /// The topmost visible layer under `p` when it is an unlocked text layer (what the Type tool edits); nil otherwise,
    /// also when something else lies above the text.
    public func textLayer(at p: Vec2, atLocal t: Time, text: GraphicsTextMeasure?) -> UUID? {
        guard let id = hitTest(p, atLocal: t, text: text), let l = layer(id), !l.isLocked, case .text = l.content else { return nil }
        return id
    }
}
