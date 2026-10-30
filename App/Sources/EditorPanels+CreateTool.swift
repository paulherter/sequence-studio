import AppKit
import SQCore
import SQEditorUI

/// Create tool (Text, Rectangle, Ellipse, Line, Draw): a drag on the Program monitor makes one item of a Graphic clip.
/// The item goes into the selected Graphic under the playhead, else into the Graphic under the playhead on the targeted
/// track (`Timeline.graphicCreateTarget`); with neither, a new Graphic clip is made at the playhead on the first free
/// video track, as long as new text. One undo step per item.
extension EditorPanels {
    /// The monitor tool of the Create slot in its current mode (nil for every other timeline tool).
    func createMonitorTool(for tool: TimelineTool) -> ProgramSurfaceView.Tool? {
        guard tool == .type else { return nil }
        let mode = timelineView.toolState.createMode
        return mode == .text ? .type : .create(mode)
    }

    func wireCreateTool() {
        surface.onCreateShape = { [weak self] kind, a, b in
            self?.createItem(named: "Add \(kind.title)") { map, canvas in
                GraphicsEditor.createdShape(kind, from: a, to: b, mapping: map, canvas: canvas)
            }
        }
        surface.onCreateStroke = { [weak self] points, tolerance in
            self?.createItem(named: "Draw") { map, _ in
                let scale = max(abs(map.transform.scale.x), 1e-6)
                return GraphicsEditor.strokeLayer(points.map(map.canvasPoint(fromSequence:)), tolerance: tolerance / scale)
            }
        }
    }

    /// Sequence > New Shape: the Create tool's item for a centered default drag (`GraphicsEditor.menuShapeDrag`).
    func createShapeAtCenter(_ kind: ShapeKind) {
        createItem(named: "Add \(kind.title)") { map, canvas in
            let drag = GraphicsEditor.menuShapeDrag(kind, canvas: canvas)
            return GraphicsEditor.createdShape(kind, from: drag.from, to: drag.to, mapping: map, canvas: canvas)
        }
    }

    /// The Graphic a new item goes into, selected when it was found through the targeted track. False: there is none.
    @discardableResult
    func adoptCreateTarget() -> Bool { graphics.adoptCreateTarget() }

    /// Adds the item `make` builds (from the Graphic's Motion at the playhead and the canvas size) as one undo step. A
    /// selected old text or shape clip is converted to a Graphic and takes it as a layer.
    private func createItem(named name: String, _ make: (GraphicsCanvasMapping, Vec2) -> GraphicsLayer?) {
        session.stopPlayback()
        if !graphics.addCreatedItem(named: name, make) {
            guard let layer = make(GraphicsCanvasMapping(transform: ClipTransform()), graphics.canvas) else { return }
            let seconds = Int64(AppSettings.load().defaultTextSeconds)
            // Never over footage: with no free video track at the playhead a new track goes on top (same undo step).
            guard session.addGraphicsClip(duration: Time(seconds, 1), layers: [layer], neverOverwrite: true) != nil else { return }
            graphics.sync()
            graphics.select([layer.id])
        }
        updateOverlay()
    }
}
