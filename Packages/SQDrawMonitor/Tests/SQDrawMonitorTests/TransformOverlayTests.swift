import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit
@testable import SQDrawMonitor

@MainActor
@Suite struct TransformOverlayTests {
    /// A full-frame 1920x1080 picture shown at 960x540 (view scale 0.5).
    let rect = CGRect(x: 100, y: 50, width: 960, height: 540)

    func overlay() -> (TransformOverlay, Recorder) {
        let o = TransformOverlay()
        o.isShown = true
        o.mediaPixelSize = CGSize(width: 1920, height: 1080)
        let r = Recorder()
        o.onTransform = { phase, t in r.events.append((phase, t)) }
        o.onCrop = { phase, edge, v in r.crops.append((phase, edge, v)) }
        o.onPathEdit = { phase, e in r.paths.append((phase, e)) }
        o.onDragCanceled = { r.canceled += 1 }
        return (o, r)
    }

    final class Recorder {
        var events: [(TransformOverlay.Phase, ClipTransform)] = []
        var crops: [(TransformOverlay.Phase, CropEdge, Double)] = []
        var paths: [(TransformOverlay.Phase, TransformOverlay.PathEdit)] = []
        var canceled = 0
    }

    @Test func bodyDragMovesThePositionInSequencePixels() {
        let (o, r) = overlay()
        let start = CGPoint(x: rect.midX + 100, y: rect.midY + 50)
        #expect(o.mouseDown(start, modifiers: [], canvasRect: rect))
        o.mouseDragged(CGPoint(x: start.x + 20, y: start.y + 10))
        o.mouseUp(CGPoint(x: start.x + 20, y: start.y + 10))
        #expect(r.events.map(\.0) == [.began, .changed, .ended])
        #expect(r.events.last?.1.position == Vec2(40, 20))
        #expect(!o.isDragging)
    }

    @Test func shiftLocksTheMoveToTheDominantAxis() {
        let (o, r) = overlay()
        o.modifiersNow = { .shift }
        let start = CGPoint(x: rect.midX + 100, y: rect.midY + 50)
        _ = o.mouseDown(start, modifiers: [], canvasRect: rect)
        o.mouseDragged(CGPoint(x: start.x + 30, y: start.y + 5))
        #expect(r.events.last?.1.position == Vec2(60, 0))
    }

    @Test func moveSnapsToTheCanvasCenter() {
        let (o, r) = overlay()
        o.snapTargets = SnapGuides.targets(canvas: CGSize(width: 1920, height: 1080), others: [])
        let start = CGPoint(x: rect.midX + 100, y: rect.midY + 50)
        _ = o.mouseDown(start, modifiers: [], canvasRect: rect)
        o.mouseDragged(CGPoint(x: start.x + 2, y: start.y))   // 4 px in sequence space: within 6 view px
        #expect(r.events.last?.1.position == Vec2(0, 0))
        var c = Canvas(width: 1200, height: 700, atlas: nil, scale: 1)
        o.draw(&c, canvasRect: rect, theme: DrawTheme())   // guides drawn while dragging, no crash
    }

    @Test func cornerHandleScalesUniformlyAboutTheAnchor() {
        let (o, r) = overlay()
        let corner = CGPoint(x: rect.maxX, y: rect.maxY)
        #expect(o.mouseDown(corner, modifiers: [], canvasRect: rect))
        o.mouseDragged(CGPoint(x: corner.x + 48, y: corner.y + 27))
        o.mouseUp(CGPoint(x: corner.x + 48, y: corner.y + 27))
        let t = try! #require(r.events.last?.1)
        #expect(abs(t.scale.x - 1.1) < 1e-6 && abs(t.scale.y - 1.1) < 1e-6)
        #expect(t.position == .zero)
    }

    @Test func hoverCursorsMatchTheMacOverlay() {
        let (o, _) = overlay()
        #expect(o.hoverCursor(at: CGPoint(x: rect.maxX, y: rect.maxY), canvasRect: rect) == .resizeDiagonalDown)
        #expect(o.hoverCursor(at: CGPoint(x: rect.minX, y: rect.minY), canvasRect: rect) == .resizeDiagonalDown)
        #expect(o.hoverCursor(at: CGPoint(x: rect.maxX, y: rect.minY), canvasRect: rect) == .resizeDiagonalUp)
        #expect(o.hoverCursor(at: CGPoint(x: rect.maxX, y: rect.midY), canvasRect: rect) == .resizeLeftRight)
        #expect(o.hoverCursor(at: CGPoint(x: rect.midX, y: rect.minY), canvasRect: rect) == .resizeUpDown)
        #expect(o.hoverCursor(at: CGPoint(x: rect.maxX + 10, y: rect.minY - 10), canvasRect: rect) == .rotateTopRight)
        #expect(o.hoverCursor(at: CGPoint(x: rect.minX - 10, y: rect.maxY + 10), canvasRect: rect) == .rotateBottomLeft)
        #expect(o.hoverCursor(at: CGPoint(x: rect.midX + 40, y: rect.midY + 30), canvasRect: rect) == .move)
    }

    @Test func outsideACornerRotates() {
        let (o, r) = overlay()
        let p = CGPoint(x: rect.maxX + 10, y: rect.minY - 10)
        #expect(o.mouseDown(p, modifiers: [], canvasRect: rect))
        o.mouseDragged(CGPoint(x: rect.maxX + 10, y: rect.minY + 30))
        let t = try! #require(r.events.last?.1)
        #expect(t.rotation > 0)
        #expect(t.position == .zero && t.scale == Vec2(1, 1))
    }

    @Test func altDragOnThePictureMovesTheAnchorOnly() {
        let (o, r) = overlay()
        let start = CGPoint(x: rect.midX + 100, y: rect.midY + 50)
        _ = o.mouseDown(start, modifiers: .option, canvasRect: rect)
        o.mouseDragged(CGPoint(x: start.x + 10, y: start.y))
        let t = try! #require(r.events.last?.1)
        #expect(t.anchor == Vec2(20, 0) && t.position == Vec2(20, 0))
    }

    @Test func escapeCancelsTheDrag() {
        let (o, r) = overlay()
        _ = o.mouseDown(CGPoint(x: rect.midX + 100, y: rect.midY), modifiers: [], canvasRect: rect)
        o.mouseDragged(CGPoint(x: rect.midX + 150, y: rect.midY))
        #expect(o.cancelDrag())
        #expect(r.canceled == 1)
        o.mouseUp(CGPoint(x: rect.midX + 150, y: rect.midY))
        #expect(r.events.last?.0 == .changed)   // no ended after the cancel
        #expect(!o.cancelDrag())
    }

    @Test func pressesBesideTheLayerFallThrough() {
        let (o, r) = overlay()
        o.transform.scale = Vec2(0.5, 0.5)
        #expect(!o.mouseDown(CGPoint(x: rect.minX + 20, y: rect.midY), modifiers: [], canvasRect: rect))
        o.isShown = false
        #expect(!o.mouseDown(CGPoint(x: rect.midX + 50, y: rect.midY), modifiers: [], canvasRect: rect))
        #expect(r.events.isEmpty)
    }

    @Test func cropModeDragsAnEdgeAndHasNoScaleHandles() {
        let (o, r) = overlay()
        o.cropInsets = CropInsets(left: 0, top: 0, right: 0, bottom: 0)
        let left = CGPoint(x: rect.minX, y: rect.midY)
        #expect(o.mouseDown(left, modifiers: [], canvasRect: rect))
        o.mouseDragged(CGPoint(x: rect.minX + 96, y: rect.midY))
        o.mouseUp(CGPoint(x: rect.minX + 96, y: rect.midY))
        #expect(r.crops.map(\.0) == [.began, .changed, .ended])
        #expect(r.crops.last?.1 == .left)
        #expect(abs((r.crops.last?.2 ?? 0) - 0.1) < 1e-6)
        // A corner is no scale handle in crop mode: the press moves the picture.
        _ = o.mouseDown(CGPoint(x: rect.maxX - 1, y: rect.maxY - 1), modifiers: [], canvasRect: rect)
        o.mouseDragged(CGPoint(x: rect.maxX + 9, y: rect.maxY - 1))
        #expect(r.events.last?.1.scale == Vec2(1, 1))
        #expect(r.events.last?.1.position == Vec2(20, 0))
    }

    @Test func motionPathKeyDragEditsThatKey() {
        let (o, r) = overlay()
        var track = KeyframeTrack<Vec2>()
        track.insert(Keyframe(time: .zero, value: Vec2(-400, 0)))
        track.insert(Keyframe(time: Time(1, 1), value: Vec2(400, 0)))
        o.positionTrack = track
        let first = try! #require(track.keys.first)
        let p = CGPoint(x: rect.midX - 200, y: rect.midY)
        #expect(o.mouseDown(p, modifiers: [], canvasRect: rect))
        o.mouseDragged(CGPoint(x: p.x, y: p.y + 50))
        o.mouseUp(CGPoint(x: p.x, y: p.y + 50))
        #expect(r.paths.map(\.0) == [.began, .changed, .ended])
        #expect(r.paths.last?.1.key == first.id)
        #expect(r.paths.last?.1.position == Vec2(-400, 100))
    }

    @Test func monitorPanelRoutesPressesToTheOverlayAndEscCancels() {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        let p = MonitorPanel(model: m)
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        let (o, r) = (p.overlay, Recorder())
        o.isShown = true
        o.mediaPixelSize = CGSize(width: 1920, height: 1080)
        o.onTransform = { phase, t in r.events.append((phase, t)) }
        o.onDragCanceled = { r.canceled += 1 }
        let c = p.canvasRect
        _ = p.handle(.mouseDown(x: Float(c.midX + 40), y: Float(c.midY + 20), modifiers: []))
        #expect(p.isDragging)
        _ = p.handle(.mouseDragged(x: Float(c.midX + 60), y: Float(c.midY + 20)))
        #expect(r.events.last?.0 == .changed)
        #expect(p.handle(.keyDown(.escape, modifiers: [])))
        #expect(r.canceled == 1 && !p.isDragging)
    }
}
