import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit
@testable import SQDrawMonitor

/// Masks on the canvas overlay (the mask half of the Mac TransformOverlayView): handles, pen, move, Esc, Mask tool.
@MainActor
@Suite struct MonitorMaskOverlayTests {
    /// A full-frame 1920x1080 layer shown at 960x540: frame fraction (x, y) sits at (100 + 960 x, 50 + 540 y).
    let rect = CGRect(x: 100, y: 50, width: 960, height: 540)
    let maskID = UUID()

    final class Recorder {
        var vertex: [(TransformOverlay.Phase, Int, Vec2)] = []
        var edits: [(TransformOverlay.Phase, MaskHandleEdit)] = []
        var selected: [ClipMask.ID] = []
        var toolClicks: [Vec2] = []
        var shapes: [(MaskShapeKind, MaskPath)] = []
        var transforms = 0
        var canceled = 0
    }

    func overlay() -> (TransformOverlay, Recorder) {
        let o = TransformOverlay()
        o.isShown = true
        o.mediaPixelSize = CGSize(width: 1920, height: 1080)
        o.masks = [MaskOverlay(id: maskID, path: .rectangle(Vec2(0.25, 0.25), Vec2(0.75, 0.75)), active: true)]
        let r = Recorder()
        o.onMaskVertex = { phase, _, i, p in r.vertex.append((phase, i, p)) }
        o.onMaskEdit = { phase, e in r.edits.append((phase, e)) }
        o.onMaskSelect = { r.selected.append($0) }
        o.onMaskToolClick = { p, _ in r.toolClicks.append(p) }
        o.onMaskShapeDrawn = { k, p in r.shapes.append((k, p)) }
        o.onTransform = { _, _ in r.transforms += 1 }
        o.onDragCanceled = { r.canceled += 1 }
        return (o, r)
    }

    func view(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + 960 * x, y: rect.minY + 540 * y) }
    func near(_ a: Vec2, _ b: Vec2) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }

    /// The Magic tool reports where the pointer rests on the layer (frame fraction), once per change, nil when it leaves.
    @Test func theMagicToolReportsTheHoverPointOnTheLayer() {
        let (o, _) = overlay()
        var seen: [Vec2?] = []
        o.onMaskToolHover = { seen.append($0) }
        o.pointerMoved(view(0.5, 0.5), canvasRect: rect)
        #expect(seen.isEmpty, "Selection tool: no hover")
        o.maskTool = .pen
        o.pointerMoved(view(0.5, 0.5), canvasRect: rect)
        #expect(seen.isEmpty, "only Magic hovers")
        o.maskTool = .magic
        o.pointerMoved(view(0.5, 0.5), canvasRect: rect)
        o.pointerMoved(view(0.5, 0.5), canvasRect: rect)
        #expect(seen.count == 1 && seen[0].map { near($0, Vec2(0.5, 0.5)) } == true)
        o.pointerMoved(CGPoint(x: 5, y: 5), canvasRect: rect)
        #expect(seen.count == 2 && seen[1] == nil)
        o.pointerMoved(CGPoint(x: 6, y: 6), canvasRect: rect)
        #expect(seen.count == 2, "still off the layer")
    }

    /// The Add | Remove switch top left of the picture: only with Magic, it takes the press (no pick) and keeps its mode.
    @Test func magicAddRemoveSwitchTakesItsPressAndKeepsTheMode() {
        let (o, r) = overlay()
        let add = CGPoint(x: 120, y: 60), remove = CGPoint(x: 200, y: 60)
        o.maskTool = .pen
        #expect(o.magicSwitchHit(remove, in: rect) != nil)           // geometry only; the pen tool does not use it
        #expect(!o.hits(remove, canvasRect: rect) || r.toolClicks.isEmpty)
        o.maskTool = .magic
        #expect(o.mouseDown(remove, modifiers: [], canvasRect: rect))
        #expect(o.magicSubtract && r.toolClicks.isEmpty)
        #expect(o.mouseDown(add, modifiers: [], canvasRect: rect))
        #expect(!o.magicSubtract && r.toolClicks.isEmpty)
        #expect(o.mouseDown(view(0.5, 0.5), modifiers: [], canvasRect: rect))
        #expect(r.toolClicks.count == 1)
    }

    @Test func vertexDragSelectsTheMaskAndMovesThePoint() throws {
        let (o, r) = overlay()
        let i = try #require(o.masks[0].path.vertices.firstIndex { near($0.point, Vec2(0.25, 0.25)) })
        #expect(o.mouseDown(view(0.25, 0.25), modifiers: [], canvasRect: rect))
        o.mouseDragged(view(0.3, 0.35))
        o.mouseUp(view(0.3, 0.35))
        #expect(r.selected == [maskID])
        #expect(r.vertex.map(\.0) == [.began, .changed, .ended])
        #expect(r.vertex.allSatisfy { $0.1 == i })
        #expect(near(r.vertex.last!.2, Vec2(0.3, 0.35)))
        #expect(r.transforms == 0)
    }

    @Test func ctrlClickRemovesAVertexAndAltClickTogglesSmooth() throws {
        let (o, r) = overlay()
        let i = try #require(o.masks[0].path.vertices.firstIndex { near($0.point, Vec2(0.75, 0.25)) })
        _ = o.mouseDown(view(0.75, 0.25), modifiers: .command, canvasRect: rect)
        #expect(!o.isDragging)
        #expect(r.edits.map(\.0) == [.began, .ended])
        #expect(r.edits.last?.1 == .remove(maskID, vertex: i))
        _ = o.mouseDown(view(0.75, 0.25), modifiers: .option, canvasRect: rect)
        #expect(r.edits.last?.1 == .toggleSmooth(maskID, vertex: i))
    }

    @Test func dragInsideMovesTheWholeMaskAndEscPutsItBack() {
        let (o, r) = overlay()
        let before = o.masks
        #expect(o.mouseDown(view(0.5, 0.5), modifiers: [], canvasRect: rect))
        o.mouseDragged(view(0.6, 0.5))
        guard case .move(let id, let delta)? = r.edits.last?.1 else { Issue.record("no move"); return }
        #expect(id == maskID && near(delta, Vec2(0.1, 0)))
        #expect(o.masks != before)
        #expect(o.cancelDrag())
        #expect(o.masks == before)
        #expect(r.canceled == 1)
    }

    @Test func pressOnTheOutlineAddsAVertexAndPullsItsHandle() {
        let (o, r) = overlay()
        let count = o.masks[0].path.vertices.count
        #expect(o.mouseDown(view(0.5, 0.25), modifiers: [], canvasRect: rect))
        #expect(o.masks[0].path.vertices.count == count + 1)
        o.mouseDragged(view(0.55, 0.25))
        o.mouseUp(view(0.55, 0.25))
        guard case .pen(_, _, _, let handle, _)? = r.edits.last?.1 else { Issue.record("no pen edit"); return }
        #expect(r.edits.last?.0 == .ended)
        #expect(near(handle, Vec2(0.05, 0)))
    }

    @Test func rectangleToolDragDrawsOneShapeAndNoTransform() {
        let (o, r) = overlay()
        o.masks = []
        o.maskTool = .rectangle
        #expect(o.mouseDown(view(0.1, 0.1), modifiers: [], canvasRect: rect))
        o.mouseDragged(view(0.2, 0.3))
        #expect(o.drawPreview != nil)
        o.mouseUp(view(0.2, 0.3))
        #expect(r.shapes.count == 1 && r.shapes.first?.0 == .rectangle)
        #expect(r.toolClicks.isEmpty && r.transforms == 0)
        #expect(o.drawPreview == nil)
    }

    @Test func penToolClickReportsTheFramePoint() {
        let (o, r) = overlay()
        o.maskTool = .pen
        #expect(o.mouseDown(view(0.1, 0.9), modifiers: [], canvasRect: rect))
        o.mouseUp(view(0.1, 0.9))
        #expect(r.toolClicks.count == 1 && near(r.toolClicks[0], Vec2(0.1, 0.9)))
        // Off the layer the tool takes nothing: the press falls through to the monitor.
        #expect(!o.mouseDown(CGPoint(x: 50, y: 20), modifiers: [], canvasRect: rect))
    }

    @Test func shapeToolClickInsideAnotherMaskSelectsIt() {
        let (o, r) = overlay()
        o.maskTool = .ellipse
        o.masks[0].active = false   // the active mask's inside moves it; another mask's inside selects it
        _ = o.mouseDown(view(0.5, 0.5), modifiers: [], canvasRect: rect)
        o.mouseUp(view(0.5, 0.5))
        #expect(r.toolClicks.isEmpty)
        #expect(r.selected.last == maskID)
    }

    @Test func maskOutlineAndVerticesAreDrawn() {
        let (o, _) = overlay()
        var c = Canvas(width: 1200, height: 700, atlas: nil, scale: 1)
        o.draw(&c, canvasRect: rect, theme: DrawTheme())
        let withMasks = c.list.quads.count
        o.masks = []
        var d = Canvas(width: 1200, height: 700, atlas: nil, scale: 1)
        o.draw(&d, canvasRect: rect, theme: DrawTheme())
        #expect(withMasks > d.list.quads.count + 4)
    }

    /// Mask Tint: the coverage slot stretched over the layer under the outlines, only with the Mask tool on; a turned
    /// layer gets none (the image quad is axis-aligned).
    @Test func theMaskTintCoversTheLayerWhileTheMaskToolIsOn() {
        let (o, _) = overlay()
        o.maskTintSlot = 1
        func tints() -> [DrawQuad] {
            var c = Canvas(width: 1200, height: 700, atlas: nil, scale: 1)
            o.draw(&c, canvasRect: rect, theme: DrawTheme())
            return c.list.quads.filter { $0.kind == DrawQuad.Kind.image.rawValue }
        }
        #expect(tints().isEmpty)                                   // Selection tool
        o.maskTool = .magic
        let q = tints()
        #expect(q.count == 1 && q.first?.pad == 1)
        #expect(q.first.map { abs($0.x - 100) < 0.01 && abs($0.y - 50) < 0.01 && abs($0.w - 960) < 0.01 && abs($0.h - 540) < 0.01 } == true)
        #expect(q.first.map { ($0.u0, $0.v0, $0.u1, $0.v1) == (0, 0, 1, 1) } == true)
        #expect(q.first.map { abs($0.r - DrawTheme().yellow.r) < 0.001 && $0.a == 1 } == true)
        var t = o.transform
        t.rotation = 30
        o.transform = t
        #expect(tints().isEmpty)
        o.transform.rotation = 0
        o.maskTintSlot = nil
        #expect(tints().isEmpty)
    }

    @Test func transparencyGridNeedsTheOptionAndAPictureWithAlpha() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        let was = m.showsTransparencyGrid
        defer { m.setShowsTransparencyGrid(was) }
        m.setShowsTransparencyGrid(true)
        let p = MonitorPanel(model: m)
        #expect(!p.showsCheckerboard)
        p.pictureHasAlpha = true
        #expect(p.showsCheckerboard)
        m.setShowsTransparencyGrid(false)
        #expect(!p.showsCheckerboard)
    }
}
