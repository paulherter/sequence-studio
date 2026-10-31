import Foundation
import Testing
import SQCore
import SQDrawKit
@testable import SQDrawMonitor

/// A fake graphic: two layers (a text near the center, a shape below it), edits recorded.
@MainActor
final class FakeLayers: GraphicsLayerSource {
    let text = UUID(), shape = UUID()
    var selection: Set<UUID> = []
    var isDrawing = false
    var moved = Vec2.zero
    var moveStart: Vec2?
    var gestures = 0
    var resized: [(UUID, GraphicsCorner, Vec2)] = []

    static func box(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double) -> [Vec2] {
        [Vec2(cx - w / 2, cy - h / 2), Vec2(cx + w / 2, cy - h / 2), Vec2(cx + w / 2, cy + h / 2), Vec2(cx - w / 2, cy + h / 2)]
    }
    var textBox: [Vec2] { Self.box(100, 0, 200, 80) }
    var shapeBox: [Vec2] { Self.box(-300, 0, 200, 200) }

    var outlines: [GraphicsLayerOutline] {
        [GraphicsLayerOutline(id: shape, corners: shapeBox, isSelected: selection.contains(shape)),
         GraphicsLayerOutline(id: text, corners: textBox, isSelected: selection.contains(text))]
    }
    var handled: GraphicsLayerOutline? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return outlines.first { $0.id == id }
    }
    func layer(atSequence p: Vec2) -> UUID? {
        if abs(p.x - 100) <= 100, abs(p.y) <= 40 { return text }
        if abs(p.x + 300) <= 100, abs(p.y) <= 100 { return shape }
        return nil
    }
    func layer(below current: UUID?, atSequence p: Vec2) -> UUID? { nil }
    func layers(inSequenceRect a: Vec2, _ b: Vec2) -> Set<UUID> {
        let lo = Vec2(min(a.x, b.x), min(a.y, b.y)), hi = Vec2(max(a.x, b.x), max(a.y, b.y))
        return Set(outlines.filter { o in
            let xs = o.corners.map(\.x), ys = o.corners.map(\.y)
            return xs.max()! >= lo.x && xs.min()! <= hi.x && ys.max()! >= lo.y && ys.min()! <= hi.y
        }.map(\.id))
    }
    func select(_ ids: Set<UUID>) { selection = ids }
    func beginGesture() { gestures += 1 }
    func beginMove(atSequence p: Vec2, viewScale: Double) { moveStart = p }
    func move(toSequence p: Vec2, snapping: Bool) -> GraphicsLayerGuides {
        moved = p - (moveStart ?? p)
        return .none
    }
    func resize(_ id: UUID, corner: GraphicsCorner, toSequence p: Vec2, snapping: Bool, keepAspect: Bool,
                viewScale: Double) -> GraphicsLayerGuides {
        resized.append((id, corner, p)); return .none
    }
    func addPath(_ points: [Vec2]) {}
}

@MainActor
@Suite struct GraphicsLayerOverlayTests {
    let canvas = CGRect(x: 100, y: 50, width: 960, height: 540)       // 0.5 view points per sequence px

    func make(_ f: FakeLayers) -> GraphicsLayerOverlay {
        let o = GraphicsLayerOverlay()
        o.source = f
        o.isShown = true
        o.sequenceSize = CGSize(width: 1920, height: 1080)
        return o
    }

    func at(_ q: Vec2) -> CGPoint { CGPoint(x: canvas.midX + q.x * 0.5, y: canvas.midY + q.y * 0.5) }

    @Test func clickOnTextSelectsOnlyThatLayer() {
        let f = FakeLayers(), o = make(f)
        #expect(o.mouseDown(at(Vec2(100, 0)), modifiers: [], canvasRect: canvas))
        #expect(f.selection == [f.text])
        o.mouseUp(at(Vec2(100, 0)))
        #expect(f.selection == [f.text])                   // a click without movement keeps the pick
    }

    @Test func dragMovesTheLayerBySequencePixels() {
        let f = FakeLayers(), o = make(f)
        _ = o.mouseDown(at(Vec2(100, 0)), modifiers: [], canvasRect: canvas)
        o.mouseDragged(at(Vec2(160, 30)))
        #expect(abs(f.moved.x - 60) < 1e-6 && abs(f.moved.y - 30) < 1e-6)
        #expect(f.gestures == 1)
        #expect(o.isDragging)
        o.mouseUp(at(Vec2(160, 30)))
        #expect(!o.isDragging)
    }

    @Test func cornerHandleOfTheSelectedLayerResizes() {
        let f = FakeLayers(), o = make(f)
        f.selection = [f.text]
        let corner = f.textBox[GraphicsCorner.allCases[2].rawValue]
        #expect(o.mouseDown(at(corner), modifiers: [], canvasRect: canvas))
        o.mouseDragged(at(Vec2(corner.x + 40, corner.y + 20)))
        #expect(f.resized.count == 1 && f.resized[0].0 == f.text && f.resized[0].1 == GraphicsCorner.allCases[2])
        #expect(abs(f.resized[0].2.x - (corner.x + 40)) < 1e-6)
    }

    @Test func shiftTogglesAndEmptyCanvasClearsOnlyWithASelection() {
        let f = FakeLayers(), o = make(f)
        let empty = at(Vec2(500, 300))
        #expect(!o.mouseDown(empty, modifiers: [], canvasRect: canvas))        // nothing selected: falls to the clip box
        f.selection = [f.shape]
        _ = o.mouseDown(at(Vec2(100, 0)), modifiers: [.shift], canvasRect: canvas)
        #expect(f.selection == [f.shape, f.text])
        o.mouseUp(at(Vec2(100, 0)))
        #expect(o.mouseDown(empty, modifiers: [], canvasRect: canvas))         // a selection owns the empty canvas
        o.mouseUp(empty)
        #expect(f.selection.isEmpty)
    }

    @Test func marqueeSelectsTouchedLayers() {
        let f = FakeLayers(), o = make(f)
        f.selection = [f.shape]
        let a = at(Vec2(-100, -200))
        _ = o.mouseDown(a, modifiers: [], canvasRect: canvas)
        o.mouseDragged(at(Vec2(400, 200)))
        #expect(f.selection == [f.text])
        o.mouseUp(at(Vec2(400, 200)))
    }

    @Test func hiddenOverlayTakesNothingAndMoveCursorOnlyOverTheSelectedLayer() {
        let f = FakeLayers(), o = make(f)
        f.selection = [f.text]
        #expect(o.hoverCursor(at: at(Vec2(100, 0)), canvasRect: canvas) == .move)
        #expect(o.hoverCursor(at: at(Vec2(-300, 0)), canvasRect: canvas) == nil)
        o.isShown = false
        #expect(!o.mouseDown(at(Vec2(100, 0)), modifiers: [], canvasRect: canvas))
    }

    @Test func panelRoutesALayerPressBeforeTheClipBox() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        let p = MonitorPanel(model: m)
        p.sequenceSize = CGSize(width: 1920, height: 1080)
        p.hasPicture = true
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        let f = FakeLayers()
        p.layerOverlay.source = f
        p.layerOverlay.isShown = true
        p.overlay.isShown = true                                  // the clip's own box covers the whole canvas
        p.overlay.transform = ClipTransform.identity
        var picks = 0
        p.onPickClip = { _ in picks += 1 }
        let r = p.canvasRect, k = Double(r.width) / 1920
        let pt = CGPoint(x: Double(r.midX) + 100 * k, y: Double(r.midY))
        _ = p.handle(.mouseDown(x: Float(pt.x), y: Float(pt.y), modifiers: []))
        #expect(f.selection == [f.text])
        #expect(p.layerOverlay.isDragging)
        #expect(!p.overlay.isDragging)
        _ = p.handle(.mouseUp(x: Float(pt.x), y: Float(pt.y)))
        #expect(picks == 0)
    }
}

/// The Hand tool on the Program picture (ProgramSurfaceView `.hand`): drag pans, double-click fits.
@MainActor
@Suite struct MonitorHandToolTests {
    func program() -> MonitorPanel {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        let p = MonitorPanel(model: m)
        p.sequenceSize = CGSize(width: 1920, height: 1080)
        p.hasPicture = true
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
        return p
    }

    @Test func dragPansTheZoomedPictureAndDoesNotPick() {
        let p = program()
        p.handToolOn = { true }
        var picks = 0
        p.onPickClip = { _ in picks += 1 }
        p.zoomGesture(.view(scale: 1, centerX: 0, centerY: 0))
        let a = CGPoint(x: p.slot.midX, y: p.slot.midY)
        _ = p.handle(.mouseDown(x: Float(a.x), y: Float(a.y), modifiers: []))
        #expect(p.isDragging)
        _ = p.handle(.mouseDragged(x: Float(a.x - 50), y: Float(a.y)))
        if case .view(_, let cx, _) = p.viewerZoom { #expect(cx > 0) } else { Issue.record("not panned") }
        _ = p.handle(.mouseUp(x: Float(a.x - 50), y: Float(a.y)))
        #expect(!p.isDragging)
        #expect(picks == 0)
    }

    @Test func doubleClickFitsThePicture() {
        var t = 0.0
        let p = program()
        p.clock = { t }
        p.handToolOn = { true }
        p.zoomGesture(.view(scale: 1, centerX: 100, centerY: 0))
        let a = CGPoint(x: p.slot.midX, y: p.slot.midY)
        for _ in 0..<2 {
            _ = p.handle(.mouseDown(x: Float(a.x), y: Float(a.y), modifiers: []))
            _ = p.handle(.mouseUp(x: Float(a.x), y: Float(a.y)))
            t += 0.1
        }
        #expect(p.viewerZoom.isFit)
    }
}
