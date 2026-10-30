import CoreGraphics
import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct GraphicsMonitorTests {
    private let canvas = Vec2(1920, 1080)
    private let identity = GraphicsCanvasMapping(transform: ClipTransform())

    // MARK: Snap maths

    @Test func targetsHoldFrameEdgesCentreAndSafeMargins() throws {
        let t = try #require(GraphicsSnap.targets(canvas: canvas, mapping: identity))
        for x in [-960.0, 0, 960, -864, 864, -768, 768] { #expect(t.xs.contains(x)) }
        for y in [-540.0, 0, 540, -486, 486, -432, 432] { #expect(t.ys.contains(y)) }
    }

    @Test func targetsFollowAMovedAndScaledGraphicAndStopWhenRotated() throws {
        let m = GraphicsCanvasMapping(transform: ClipTransform(position: Vec2(100, 0), scale: Vec2(0.5, 0.5)))
        let t = try #require(GraphicsSnap.targets(canvas: canvas, mapping: m, safeAreas: []))
        // sequence x = 100 + 0.5 * canvas x, so the frame center (sequence 0) is canvas x = -200
        #expect(t.xs.contains(-200))
        let r = GraphicsCanvasMapping(transform: ClipTransform(rotation: 10))
        #expect(GraphicsSnap.targets(canvas: canvas, mapping: r) == nil)
    }

    @Test func moveSnapsBoxCentreToFrameCentreWithinThreshold() throws {
        let t = try #require(GraphicsSnap.targets(canvas: canvas, mapping: identity))
        var s = GraphicsMoveSnapper(startBox: GraphicsRect(minX: -100, minY: -50, maxX: 100, maxY: 50), start: .zero, targets: t, threshold: 6)
        let r = s.step(to: Vec2(4, 300), snapping: true)
        #expect(r.delta.x == 0)
        #expect(r.delta.y == 300)
        #expect(r.guides.verticalLines.contains(0))
    }

    @Test func moveDeltasAddUpToTheSnappedTotal() throws {
        let t = try #require(GraphicsSnap.targets(canvas: canvas, mapping: identity, safeAreas: []))
        var s = GraphicsMoveSnapper(startBox: GraphicsRect(minX: -100, minY: -50, maxX: 100, maxY: 50), start: .zero, targets: t, threshold: 6)
        var total = Vec2.zero
        for x in [50.0, 300, 4, 3] { total = total + s.step(to: Vec2(x, 0), snapping: true).delta }
        #expect(total.x == 0)
    }

    @Test func disabledSnappingFollowsThePointerExactly() throws {
        let t = try #require(GraphicsSnap.targets(canvas: canvas, mapping: identity))
        var s = GraphicsMoveSnapper(startBox: GraphicsRect(minX: -100, minY: -50, maxX: 100, maxY: 50), start: .zero, targets: t, threshold: 6)
        let a = s.step(to: Vec2(4, 0), snapping: true)
        let b = s.step(to: Vec2(4, 0), snapping: false)
        #expect(a.delta.x + b.delta.x == 4)
        #expect(b.guides.verticalLines.isEmpty)
    }

    @Test func cornerSnapsToSafeMargin() throws {
        let t = try #require(GraphicsSnap.targets(canvas: canvas, mapping: identity))
        let r = GraphicsSnap.snapPoint(Vec2(-866, 100), targets: t, threshold: 6)
        #expect(r.point.x == -864)
        #expect(r.point.y == 100)
    }

    @Test func thresholdIsViewPointsOverScale() {
        let m = GraphicsCanvasMapping(transform: ClipTransform(scale: Vec2(0.5, 0.5)))
        #expect(GraphicsSnap.threshold(viewPoints: 6, viewScale: 0.25, mapping: m) == 48)
    }

    // MARK: Hit testing

    private func measure() -> GraphicsTextMeasure {
        { _, _ in GraphicsRect(minX: -100, minY: -20, maxX: 100, maxY: 20) }
    }

    private func textRef() throws -> GeneratorRef {
        try TextGenerator.makeRef(template: TextTemplate(name: "T", text: "Hello", style: CaptionPresetLibrary.builtIn.style(for: "title")),
                                  animations: nil)
    }

    @Test func topmostTextLayerOnly() throws {
        var doc = GraphicsDocument()
        let text = doc.add(GraphicsLayer.text(try textRef()))
        #expect(doc.textLayer(at: .zero, atLocal: .zero, text: measure()) == text)
        #expect(doc.textLayer(at: Vec2(500, 0), atLocal: .zero, text: measure()) == nil)
        _ = doc.add(GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080))
        // a shape above the text is the topmost hit: the Type tool then creates a new layer
        #expect(doc.textLayer(at: .zero, atLocal: .zero, text: measure()) == nil)
    }

    @Test func lockedTextLayerIsNotEdited() throws {
        var doc = GraphicsDocument()
        let id = doc.add(GraphicsLayer.text(try textRef()))
        doc.update(id) { $0.isLocked = true }
        #expect(doc.textLayer(at: .zero, atLocal: .zero, text: measure()) == nil)
    }

    // MARK: Editor: add at a point, commit as one undo step

    private func editor() -> (EditorSession, GraphicsEditor) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        return (s, e)
    }

    @Test func addTextAtPointCentresTheLayerThere() throws {
        let (_, e) = editor()
        let id = try #require(e.addText(at: Vec2(200, -100)))
        #expect(e.selectedLayers == [id])
        let l = try #require(e.document?.layer(id))
        let c = try #require(l.bounds(atLocal: e.localTime, text: e.textMeasure))
        #expect(abs(c.midX - 200) < 1 && abs(c.midY + 100) < 1)
    }

    @Test func addAreaTextKeepsTheBoxAndCentresIt() throws {
        let (_, e) = editor()
        let id = try #require(e.addText(at: Vec2(200, -100), box: TextBox(width: 400, height: 150)))
        #expect(e.textTemplate?.box == TextBox(width: 400, height: 150))
        let l = try #require(e.document?.layer(id))
        let c = try #require(l.bounds(atLocal: e.localTime, text: e.textMeasure))
        #expect(abs(c.midX - 200) < 1 && abs(c.midY + 100) < 1)
    }

    @Test func newTextThenTypingFoldsIntoOneUndoStep() throws {
        let (s, e) = editor()
        let depth = s.undoDepth
        let id = try #require(e.addText(at: .zero))
        e.beginGesture()
        e.updateText("Edit Text") { $0.text = "H" }
        e.updateText("Edit Text") { $0.text = "Hi" }
        s.foldUndo(fromDepth: depth, name: "Add Text")
        #expect(s.undoDepth == depth + 1)
        #expect(e.textTemplate?.text == "Hi")
        s.undo()
        e.sync()
        #expect(e.document?.layer(id) == nil)
    }

    @Test func textEditStopsApplyingWhenSelectionOrLayerChanges() throws {
        let (_, e) = editor()
        let a = try #require(e.addText(at: .zero))
        let clip = try #require(e.clip?.id)
        #expect(e.isEditingValid(layer: a, clip: clip))
        let b = try #require(e.addText(at: Vec2(10, 10)))
        #expect(!e.isEditingValid(layer: a, clip: clip))
        e.select([a])
        #expect(e.isEditingValid(layer: a, clip: clip))
        e.select([a, b])
        #expect(!e.isEditingValid(layer: a, clip: clip))
        e.select([a])
        #expect(!e.isEditingValid(layer: a, clip: Clip.ID()))
        e.discardNewLayer(rewindingTo: 0)
        #expect(!e.isEditingValid(layer: a, clip: clip))
    }

    @Test func editingExistingTextIsOneUndoStep() throws {
        let (s, e) = editor()
        _ = e.addText(at: .zero)
        let depth = s.undoDepth
        e.beginGesture()
        e.updateText("Edit Text") { $0.text = "A" }
        e.updateText("Edit Text") { $0.text = "AB" }
        #expect(s.undoDepth == depth + 1)
    }

    @Test func emptyNewTextIsWithdrawnWithoutATrace() throws {
        let (s, e) = editor()
        let depth = s.undoDepth
        let id = try #require(e.addText(at: .zero))
        e.discardNewLayer(rewindingTo: depth)
        #expect(s.undoDepth == depth)
        #expect(e.document?.layer(id) == nil)
        #expect(e.selectedLayers.isEmpty)
    }

    /// Deleting every character must not move the field: the empty text keeps the layer's position (it fell back to the
    /// canvas-sized group, so the caret jumped to the top of the monitor).
    @Test func emptyTextKeepsItsEditTargetAtTheLayer() throws {
        let (_, e) = editor()
        let id = try #require(e.addText(at: Vec2(300, 50)))
        e.beginGesture()
        e.updateText("Edit Text") { $0.text = "" }
        let target = try #require(e.textEditTarget(for: id))
        #expect(abs(target.displayTransform.position.x - 300) < 40)
        #expect(abs(target.displayTransform.position.y - 50) < 40)
        #expect(target.size.height > 0 && target.size.width > 0)
    }

    @Test func editTargetSitsOnTheLayer() throws {
        let (_, e) = editor()
        let id = try #require(e.addText(at: Vec2(300, 50)))
        let target = try #require(e.textEditTarget(for: id))
        #expect(target.isText && !target.isGraphics)
        #expect(abs(target.displayTransform.position.x - 300) < 1)
        #expect(abs(target.displayTransform.position.y - 50) < 1)
        #expect(abs(target.displayTransform.scale.x - 1) < 1e-6)
    }

    /// Type tool click on empty canvas while another track is targeted and holds footage under the playhead: the new
    /// text layer and its Graphic stay selected after the monitor re-shows the frame, and the edit target exists.
    @Test func newTextStaysSelectedWithAnotherTrackTargeted() throws {
        let fd = Time(1, 30)
        let footage = Clip(name: "f", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 300),
                           start: .zero, mediaDuration: fd * 500)
        let tl = Timeline(name: "Main", frameDuration: fd, tracks: [Track(kind: .video, clips: [footage], isTargeted: true), Track(kind: .video)])
        let s = EditorSession(project: Project(name: "P", timelines: [tl]))
        let e = GraphicsEditor(session: s)
        let gid = try #require(s.addGraphicsClip(duration: fd * 90, neverOverwrite: true))
        e.sync()
        let id = try #require(e.addText(at: .zero))
        s.seek(to: s.playhead)
        e.sync()
        #expect(s.selection == [gid])
        #expect(e.isEditingValid(layer: id, clip: gid))
        #expect(e.textEditTarget(for: id) != nil)
    }

    /// Delete on a selected shape or text layer removes only the layer, one undo step brings it back.
    @Test func deleteSelectedLayerIsOneUndoStep() throws {
        let (s, e) = editor()
        let id = try #require(e.addText(at: .zero))
        let clipID = try #require(e.clip?.id)
        let depth = s.undoDepth
        e.deleteSelected()
        #expect(e.document?.layer(id) == nil && e.clip?.id == clipID && e.selectedLayers.isEmpty)
        #expect(s.undoDepth == depth + 1)
        s.undo(); e.sync()
        #expect(e.document?.layer(id) != nil)
    }
}
