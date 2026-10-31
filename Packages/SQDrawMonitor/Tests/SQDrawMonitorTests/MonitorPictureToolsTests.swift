import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
@testable import SQDrawMonitor

/// Create tool, caption press, Dynamic Zoom / Step window editors and the angle tiles on the canvas monitor.
@MainActor
@Suite struct MonitorPictureToolsTests {
    func panel(_ mode: MonitorMode = .program) -> MonitorPanel {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: mode)
        m.duration = Time(250, 25)
        let p = MonitorPanel(model: m)
        p.sequenceSize = CGSize(width: 1920, height: 1080)
        p.hasPicture = true
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        draw(p)
        return p
    }

    func draw(_ p: MonitorPanel) {
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        p.draw(&c)
    }

    func down(_ p: MonitorPanel, _ a: CGPoint) { _ = p.handle(.mouseDown(x: Float(a.x), y: Float(a.y), modifiers: [])) }
    func drag(_ p: MonitorPanel, _ a: CGPoint) { _ = p.handle(.mouseDragged(x: Float(a.x), y: Float(a.y))) }
    func up(_ p: MonitorPanel, _ a: CGPoint) { _ = p.handle(.mouseUp(x: Float(a.x), y: Float(a.y))) }

    func at(_ p: MonitorPanel, _ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        let c = p.canvasRect
        return CGPoint(x: c.minX + c.width * fx, y: c.minY + c.height * fy)
    }

    // MARK: Create tool

    @Test func cursorsFollowTheToolAndStayDuringDrags() {
        let p = panel()
        let c = at(p, 0.5, 0.5)
        func cursor(_ e: InputEvent) -> DrawCursor? { HostHover.shared.beginEvent(e); _ = p.handle(e); return HostHover.shared.cursor }
        var now = 0.0
        p.clock = { now }
        p.onCreateShape = { _, _, _ in }
        p.createModeNow = { .rectangle }
        #expect(cursor(.mouseMoved(x: Float(c.x), y: Float(c.y))) == .crosshair)
        #expect(cursor(.mouseDown(x: Float(c.x), y: Float(c.y), modifiers: [])) == .crosshair)
        #expect(cursor(.mouseDragged(x: Float(c.x + 30), y: Float(c.y + 30))) == .crosshair)
        _ = p.handle(.mouseUp(x: Float(c.x + 30), y: Float(c.y + 30)))
        p.createModeNow = { .text }
        #expect(cursor(.mouseMoved(x: Float(c.x), y: Float(c.y))) == nil)
        p.createModeNow = { nil }
        now = 5
        p.handToolOn = { true }
        #expect(cursor(.mouseDown(x: Float(c.x), y: Float(c.y), modifiers: [])) == .closedHand)
        #expect(cursor(.mouseDragged(x: Float(c.x + 5), y: Float(c.y))) == .closedHand)
        #expect(cursor(.mouseUp(x: Float(c.x + 5), y: Float(c.y))) == .openHand)
    }

    @Test func createDragMakesARectangleInSequencePixels() {
        let p = panel()
        p.createModeNow = { .rectangle }
        var shapes: [(ShapeKind, Vec2, Vec2)] = []
        var picks = 0
        p.onCreateShape = { shapes.append(($0, $1, $2)) }
        p.onPickClip = { _ in picks += 1 }
        down(p, at(p, 0.25, 0.25))
        drag(p, at(p, 0.75, 0.75))
        #expect(p.isDragging)
        draw(p)
        up(p, at(p, 0.75, 0.75))
        #expect(shapes.count == 1)
        #expect(shapes[0].0 == .rectangle)
        #expect(abs(shapes[0].1.x + 480) < 3 && abs(shapes[0].1.y + 270) < 3)
        #expect(abs(shapes[0].2.x - 480) < 3 && abs(shapes[0].2.y - 270) < 3)
        #expect(picks == 0)
        #expect(!p.isDragging)
    }

    @Test func createClickMakesNothingAndShiftMakesASquare() {
        let p = panel()
        p.createModeNow = { .ellipse }
        var shapes: [(ShapeKind, Vec2, Vec2)] = []
        p.onCreateShape = { shapes.append(($0, $1, $2)) }
        down(p, at(p, 0.5, 0.5)); up(p, at(p, 0.5, 0.5))
        #expect(shapes.isEmpty)                              // a click makes nothing
        p.overlay.modifiersNow = { [.shift] }
        let a = at(p, 0.3, 0.3)
        down(p, a)
        drag(p, CGPoint(x: a.x + 100, y: a.y + 40))
        up(p, CGPoint(x: a.x + 100, y: a.y + 40))
        #expect(shapes.count == 1 && shapes[0].0 == .ellipse)
        let size = shapes[0].2 - shapes[0].1
        #expect(abs(size.x - size.y) < 0.5)                  // Shift: a circle
    }

    @Test func freehandStrokeAndEscCancel() {
        let p = panel()
        p.createModeNow = { .draw }
        var strokes: [([Vec2], Double)] = []
        p.onCreateStroke = { strokes.append(($0, $1)) }
        let a = at(p, 0.4, 0.4)
        down(p, a)
        for i in 1...10 { drag(p, CGPoint(x: a.x + CGFloat(i) * 5, y: a.y + CGFloat(i * i) * 0.5)) }
        up(p, CGPoint(x: a.x + 50, y: a.y + 50))
        #expect(strokes.count == 1)
        #expect(strokes[0].0.count >= 5)
        #expect(strokes[0].1 > CreateToolDrag.strokeTolerance)   // view tolerance in sequence px (the view shrinks it)
        down(p, a)
        drag(p, CGPoint(x: a.x + 60, y: a.y))
        #expect(p.handle(.keyDown(.escape, modifiers: [])))
        up(p, CGPoint(x: a.x + 60, y: a.y))
        #expect(strokes.count == 1)
    }

    // MARK: Captions

    @Test func captionDragMovesWithSnapAndDoubleClickEdits() {
        let p = panel()
        var now = 10.0
        p.clock = { now }
        var began: [Vec2] = [], moves: [(Vec2, Double)] = [], ended = 0, edits = 0, picks = 0
        p.captionHitTest = { $0.y > 300 }                     // the caption sits in the lower part of the picture
        p.onCaptionDragBegan = { began.append($0); return true }
        p.onCaptionDragMoved = { moves.append(($0, $1)); return .none }
        p.onCaptionDragEnded = { ended += 1 }
        p.onCaptionDoubleClick = { _ in edits += 1 }
        p.onPickClip = { _ in picks += 1 }
        let a = at(p, 0.5, 0.9)
        down(p, a)
        drag(p, CGPoint(x: a.x + 1, y: a.y))                 // under 3 pt: still a click
        #expect(moves.isEmpty)
        drag(p, CGPoint(x: a.x + 40, y: a.y))
        up(p, CGPoint(x: a.x + 40, y: a.y))
        #expect(began.count == 1 && ended == 1 && picks == 0)
        let k = p.canvasRect.width / 1920
        #expect(abs(moves.last!.0.x - Double(40 / k)) < 0.5)
        #expect(abs(moves.last!.1 - TransformOverlay.snapDistance / Double(k)) < 0.01)
        now += 1
        down(p, a); up(p, a)
        now += 0.2
        down(p, a); up(p, a)
        #expect(edits == 1)
        down(p, at(p, 0.5, 0.2)); up(p, at(p, 0.5, 0.2))      // not on the caption: the pick
        #expect(picks == 1)
    }

    // MARK: Dynamic Zoom / Step window

    func layer(_ p: MonitorPanel) -> ZoomEditGeometry {
        ZoomEditGeometry(layer: TransformOverlayGeometry(sequenceSize: p.sequenceSize, viewRect: p.canvasRect,
                                                         mediaAspect: 16.0 / 9, transform: .identity))
    }

    @Test func zoomEditDragsTheEndWindowAndDoneCloses() {
        let p = panel()
        let z = ZoomEditOverlay()
        z.geometry = layer(p)
        z.end = .centred(zoom: 2)
        var phases: [ZoomEditOverlay.Phase] = [], last: ZoomRect?, done = 0
        z.onChange = { ph, _, e in phases.append(ph); last = e }
        z.onDone = { done += 1 }
        p.zoomEdit = z
        draw(p)
        let center = z.geometry.centre(of: z.end)
        down(p, center)
        drag(p, CGPoint(x: center.x + p.canvasRect.width * 0.1, y: center.y))
        up(p, CGPoint(x: center.x + p.canvasRect.width * 0.1, y: center.y))
        #expect(phases == [.began, .changed, .ended])
        #expect(abs((last?.x ?? 0) - 0.35) < 0.01)            // moved right by a tenth of the picture
        #expect(abs(z.start.x) < 1e-9)
        let d = CGPoint(x: z.doneRect.midX, y: z.doneRect.midY)
        down(p, d); up(p, d)
        #expect(done == 1)
        #expect(p.handle(.keyDown(.escape, modifiers: [])))   // Esc closes too
        #expect(done == 2)
    }

    @Test func zoomEditSwallowsAPressOutsideItsWindows() {
        let p = panel()
        let z = ZoomEditOverlay()
        z.geometry = layer(p)
        z.start = .centred(zoom: 2)
        z.end = .centred(zoom: 4)
        var picks = 0
        p.onPickClip = { _ in picks += 1 }
        p.zoomEdit = z
        draw(p)
        // A corner of the picture outside both windows: the transform overlay and the clip pick never see it (the Mac
        // overlay view covers the picture).
        #expect(z.geometry.hitTest(at(p, 0.05, 0.9), start: z.start, end: z.end) == nil)
        down(p, at(p, 0.05, 0.9)); up(p, at(p, 0.05, 0.9))
        #expect(picks == 0)
        #expect(p.zoomEdit != nil)
    }

    @Test func zoomFieldScrubSetsTheEndZoom() {
        let p = panel()
        let z = ZoomEditOverlay()
        z.geometry = layer(p)
        z.end = .centred(zoom: 1.25)
        var ends: [ZoomRect] = []
        z.onChange = { _, _, e in ends.append(e) }
        p.zoomEdit = z
        draw(p)
        let f = CGPoint(x: z.fieldRect.midX, y: z.fieldRect.midY)
        down(p, f)
        drag(p, CGPoint(x: f.x + 20, y: f.y))
        up(p, CGPoint(x: f.x + 20, y: f.y))
        #expect((ends.last?.zoom ?? 0) > 1.25)
    }

    @Test func stepWindowMovesAndPassesOtherPressesOn() {
        let p = panel()
        let s = StepWindowOverlay()
        s.geometry = StepWindowEditGeometry(layer: layer(p))
        var phases: [StepWindowOverlay.Phase] = [], picks = 0
        s.onChange = { ph, _ in phases.append(ph) }
        p.onPickClip = { _ in picks += 1 }
        p.stepWindowEdit = s
        let c = s.geometry.centerPoint(s.stepWindow)
        down(p, c)
        drag(p, CGPoint(x: c.x + 30, y: c.y))
        up(p, CGPoint(x: c.x + 30, y: c.y))
        #expect(phases == [.began, .changed, .ended])
        #expect(s.stepWindow != StepWindow())
        down(p, at(p, 0.02, 0.02)); up(p, at(p, 0.02, 0.02))
        #expect(picks == 1)
    }

    // MARK: Angles

    @Test func angleTilePressPicksThatAngle() {
        let p = panel(.source)
        p.model.sourceItems = [.init(id: UUID(), name: "Angles")]
        p.model.angleTiles = (0..<4).map { AngleTile(name: "Cam \($0 + 1)", picture: .init(slot: 0), isActive: $0 == 0) }
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        draw(p)
        var picked: [Int] = []
        p.model.onPickAngle = { picked.append($0) }
        let cells = p.angleCells
        #expect(cells.count == 4)
        let q = CGPoint(x: cells[3].midX, y: cells[3].midY)
        down(p, q); up(p, q)
        #expect(picked == [3])
    }

    // MARK: Loupe

    @Test func colorLoupeReadsTheCenterAndFlipsAtTheEdges() {
        let side = ColorLoupe.side
        var px = [SIMD3<UInt8>](repeating: .zero, count: side * side)
        px[(side / 2) * side + side / 2] = SIMD3(12, 200, 7)
        let l = ColorLoupe(width: side, height: side, pixels: px)
        #expect(l.readout == "R 12  G 200  B 7")
        let b = CGRect(x: 0, y: 0, width: 800, height: 500)
        let near = ColorLoupe.frame(size: l.size, pointer: CGPoint(x: 100, y: 100), in: b)
        #expect(near.minX > 100 && near.minY > 100)                 // below right of the pointer
        let edge = ColorLoupe.frame(size: l.size, pointer: CGPoint(x: 790, y: 490), in: b)
        #expect(edge.maxX < 790 && edge.maxY < 490)                 // flipped above left near the corner
        #expect(b.contains(edge))
        var c = Canvas(width: 800, height: 500, atlas: nil, scale: 1)
        l.draw(&c, pointer: CGPoint(x: 100, y: 100), in: b, theme: DrawTheme())
    }
}
