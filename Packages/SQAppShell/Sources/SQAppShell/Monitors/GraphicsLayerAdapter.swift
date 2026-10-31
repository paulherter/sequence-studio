import Foundation
import SQCore
import SQDrawMonitor
import SQEditorSession
import SQInspectorUI

/// The Graphics editor as the Program monitor's layer overlay sees it (GraphicsOverlayView's mapping and snapping, in
/// sequence px): outlines and handles through the graphic's Motion, hits and edits in the graphic's canvas space.
@MainActor
final class GraphicsLayerAdapter: GraphicsLayerSource {
    private let editor: () -> GraphicsEditor?
    private var snapper: GraphicsMoveSnapper?

    init(editor: @escaping () -> GraphicsEditor?) { self.editor = editor }

    private func outline(_ l: GraphicsLayer, _ g: GraphicsEditor, _ map: GraphicsCanvasMapping) -> GraphicsLayerOutline? {
        guard let cs = l.corners(atLocal: g.localTime, text: g.textMeasure), cs.count == 4 else { return nil }
        return GraphicsLayerOutline(id: l.id, corners: cs.map(map.sequenceOffset(fromCanvas:)), isSelected: g.selectedLayers.contains(l.id))
    }

    var outlines: [GraphicsLayerOutline] {
        guard let g = editor(), g.document != nil, let map = g.mapping else { return [] }
        return g.outlinedLayers.compactMap { outline($0, g, map) }
    }

    var handled: GraphicsLayerOutline? {
        guard let g = editor(), let l = g.handledLayer, !l.isLocked, let map = g.mapping else { return nil }
        return outline(l, g, map)
    }

    var selection: Set<UUID> { editor()?.selectedLayers ?? [] }
    var isDrawing: Bool { editor()?.isDrawing ?? false }

    func layer(atSequence p: Vec2) -> UUID? {
        guard let g = editor(), let map = g.mapping else { return nil }
        return g.shownDocument?.hitTest(map.canvasPoint(fromSequence: p), atLocal: g.localTime, text: g.textMeasure)
    }

    func layer(below current: UUID?, atSequence p: Vec2) -> UUID? {
        guard let g = editor(), let map = g.mapping else { return nil }
        return g.shownDocument?.hitBelow(current, at: map.canvasPoint(fromSequence: p), atLocal: g.localTime, text: g.textMeasure)
    }

    func layers(inSequenceRect a: Vec2, _ b: Vec2) -> Set<UUID> {
        guard let g = editor(), let map = g.mapping else { return [] }
        let ca = map.canvasPoint(fromSequence: a), cb = map.canvasPoint(fromSequence: b)
        let r = GraphicsRect(minX: min(ca.x, cb.x), minY: min(ca.y, cb.y), maxX: max(ca.x, cb.x), maxY: max(ca.y, cb.y))
        return g.shownDocument?.layers(touching: r, atLocal: g.localTime, text: g.textMeasure) ?? []
    }

    func select(_ ids: Set<UUID>) { editor()?.select(ids) }
    func beginGesture() { editor()?.beginGesture() }
    func addPath(_ points: [Vec2]) {
        guard let g = editor(), let map = g.mapping else { return }
        g.addPath(points.map(map.canvasPoint(fromSequence:)))
    }

    // MARK: Snapping (canvas space of the graphic, guides back in sequence px)

    private func targets(_ g: GraphicsEditor, _ map: GraphicsCanvasMapping) -> SnapGuides.Targets? {
        GraphicsSnap.targets(canvas: g.canvas, mapping: map)
    }

    private func threshold(_ map: GraphicsCanvasMapping, _ viewScale: Double) -> Double {
        GraphicsSnap.threshold(viewPoints: TransformOverlay.snapDistance, viewScale: viewScale, mapping: map)
    }

    private func guides(_ r: SnapGuides.Result, _ map: GraphicsCanvasMapping) -> GraphicsLayerGuides {
        GraphicsLayerGuides(vertical: r.verticalLines.map { map.sequenceOffset(fromCanvas: Vec2($0, 0)).x },
                            horizontal: r.horizontalLines.map { map.sequenceOffset(fromCanvas: Vec2(0, $0)).y })
    }

    func beginMove(atSequence p: Vec2, viewScale: Double) {
        guard let g = editor(), let map = g.mapping else { snapper = nil; return }
        let q = map.canvasPoint(fromSequence: p)
        let shown = g.shownDocument
        let box = g.selectedLayers.compactMap { shown?.bounds(of: $0, atLocal: g.localTime, text: g.textMeasure) }
            .reduce(nil as GraphicsRect?) { acc, r in acc.map { $0.union(r) } ?? r }
        snapper = GraphicsMoveSnapper(startBox: box ?? GraphicsRect(minX: q.x, minY: q.y, maxX: q.x, maxY: q.y), start: q,
                                      targets: targets(g, map), threshold: threshold(map, viewScale))
    }

    func move(toSequence p: Vec2, snapping: Bool) -> GraphicsLayerGuides {
        guard let g = editor(), let map = g.mapping, var s = snapper else { return .none }
        let r = s.step(to: map.canvasPoint(fromSequence: p), snapping: snapping)
        snapper = s
        g.translateSelected(by: r.delta)
        return guides(r.guides, map)
    }

    func resize(_ id: UUID, corner: GraphicsCorner, toSequence p: Vec2, snapping: Bool, keepAspect: Bool,
                viewScale: Double) -> GraphicsLayerGuides {
        guard let g = editor(), let map = g.mapping else { return .none }
        var target = map.canvasPoint(fromSequence: p)
        var result = SnapGuides.Result.none
        // Shift keeps the aspect, which moves the edge away from the snapped point: no snapping then.
        if snapping, !keepAspect, let t = targets(g, map) {
            let r = GraphicsSnap.snapPoint(target, targets: t, threshold: threshold(map, viewScale))
            target = r.point; result = r.guides
        }
        g.resize(id, corner: corner, to: target, keepAspect: keepAspect)
        return guides(result, map)
    }
}
