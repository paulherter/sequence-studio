import Foundation
import Testing
import SQCore
import SQDrawKit
import SQEditorSession
import SQUIKit
@testable import SQDrawMonitor

@MainActor
@Suite struct MonitorPickAndPointTests {
    func panel() -> MonitorPanel {
        let m = MonitorPanelModel(frameDuration: Time(1, 25), mode: .program)
        m.duration = Time(250, 25)
        m.hasSequence = true
        let p = MonitorPanel(model: m)
        p.layout(DrawRect(x: 0, y: 0, w: 800, h: 500), scale: 1)
        return p
    }

    @Test func clickOnThePictureReportsItsSequencePosition() {
        let p = panel()
        var picked: [Vec2] = []
        p.onPickClip = { picked.append($0) }
        let r = p.canvasRect
        _ = p.handle(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []))
        _ = p.handle(.mouseUp(x: Float(r.midX), y: Float(r.midY)))
        #expect(picked.count == 1)
        #expect(abs(picked[0].x) < 2 && abs(picked[0].y) < 2)
        // A quarter of the way in from the top left is a quarter of the frame from the center.
        _ = p.handle(.mouseDown(x: Float(r.minX + r.width / 4), y: Float(r.minY + r.height / 4), modifiers: []))
        #expect(picked.count == 2)
        #expect(abs(picked[1].x + 480) < 4 && abs(picked[1].y + 270) < 4)
    }

    @Test func clickOnTheTransformBoxDoesNotPick() {
        let p = panel()
        var picked = 0
        p.onPickClip = { _ in picked += 1 }
        p.overlay.isShown = true
        p.overlay.mediaPixelSize = CGSize(width: 1920, height: 1080)
        let r = p.canvasRect
        _ = p.handle(.mouseDown(x: Float(r.midX + 30), y: Float(r.midY + 30), modifiers: []))
        _ = p.handle(.mouseUp(x: Float(r.midX + 30), y: Float(r.midY + 30)))
        #expect(picked == 0)
    }

    @Test func clickPositionIsNilInTheLetterbox() {
        let m = MonitorViewMapping(viewSize: CGSize(width: 800, height: 800), backingScale: 1,
                                   sequenceSize: CGSize(width: 1920, height: 1080), zoom: .fit)
        #expect(m.clickPosition(CGPoint(x: 400, y: 50)) == nil)
        #expect(m.clickPosition(CGPoint(x: 400, y: 400)) == Vec2(0, 0))
    }

    /// A full-frame 1920x1080 picture shown at 960x540 (view scale 0.5).
    let rect = CGRect(x: 100, y: 50, width: 960, height: 540)

    @Test func pointHandleDragReportsOffsetsAndWinsOverTheBox() {
        let o = TransformOverlay()
        o.isShown = true
        o.mediaPixelSize = CGSize(width: 1920, height: 1080)
        o.pointHandles = [PointHandle(id: "fx|center", offset: Vec2(100, 50))]
        var events: [(TransformOverlay.Phase, String, Vec2)] = []
        var transforms = 0
        o.onPointHandle = { events.append(($0, $1, $2)) }
        o.onTransform = { _, _ in transforms += 1 }
        let at = CGPoint(x: rect.midX + 50, y: rect.midY + 25)       // the handle in view points
        #expect(o.mouseDown(at, modifiers: [], canvasRect: rect))
        o.mouseDragged(CGPoint(x: at.x + 10, y: at.y + 5))
        #expect(o.displayedPoints.first?.offset == Vec2(120, 60))
        o.mouseUp(CGPoint(x: at.x + 10, y: at.y + 5))
        #expect(events.map(\.0) == [.began, .changed, .ended])
        #expect(events.allSatisfy { $0.1 == "fx|center" })
        #expect(events.last?.2 == Vec2(120, 60))
        #expect(transforms == 0)
        #expect(o.displayedPoints.first?.offset == Vec2(100, 50))     // the host writes the value back
    }

    @Test func escCancelsAPointDrag() {
        let o = TransformOverlay()
        o.isShown = true
        o.pointHandles = [PointHandle(id: "a", offset: .zero)]
        var canceled = 0
        o.onDragCanceled = { canceled += 1 }
        #expect(o.mouseDown(CGPoint(x: rect.midX, y: rect.midY), modifiers: [], canvasRect: rect))
        o.mouseDragged(CGPoint(x: rect.midX + 40, y: rect.midY))
        #expect(o.cancelDrag())
        #expect(canceled == 1 && o.displayedPoints.first?.offset == .zero)
    }
}
