import Foundation
import SQCore
import Testing
@testable import SQDrawKit

private func geo(_ t: ClipTransform = .identity) -> StepWindowEditGeometry {
    StepWindowEditGeometry(layer: ZoomEditGeometry(layer: TransformOverlayGeometry(
        sequenceSize: CGSize(width: 1920, height: 1080), viewRect: CGRect(x: 10, y: 10, width: 960, height: 540),
        mediaAspect: 16.0 / 9, transform: t)))
}
private func close(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.01) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }

@Suite struct StepWindowEditGeometryTests {
    @Test func windowAndPictureSpacesRoundTrip() {
        let g = geo()
        var w = StepWindow(shape: .rectangle)
        w.centerX = 0.3; w.centerY = 0.6; w.rotation = 33
        for q in [Vec2(0, 0), Vec2(0.2, -0.1), Vec2(-0.5, 0.3)] {
            let back = g.window(fromUV: g.uv(fromWindow: q, w), w)
            #expect(abs(back.x - q.x) < 1e-9 && abs(back.y - q.y) < 1e-9)
        }
    }

    @Test func handlesSitOnTheShapeAtIdentity() {
        let g = geo()
        var w = StepWindow()                       // ellipse 50 % x 50 % at the center
        w.centerX = 0.5; w.centerY = 0.5
        #expect(close(g.centerPoint(w), CGPoint(x: 490, y: 280)))
        #expect(close(g.edgePoint(.right, w)!, CGPoint(x: 490 + 0.25 * 960, y: 280)))
        #expect(close(g.edgePoint(.top, w)!, CGPoint(x: 490, y: 280 - 0.25 * 540)))
        let r = g.rotatePoint(w)
        #expect(abs(r.x - 490) < 0.01 && abs(r.y - (280 - 0.25 * 540 - StepWindowEditGeometry.rotateOffset)) < 0.01)
    }

    @Test func rotationTurnsTheHandlesClockwise() {
        let g = geo()
        var w = StepWindow(shape: .rectangle)
        w.rotation = 90                            // the right edge now points down on screen
        let right = g.edgePoint(.right, w)!
        let c = g.centerPoint(w)
        #expect(abs(right.x - c.x) < 0.01 && right.y > c.y)
    }

    @Test func hitTestOrdersRotateEdgeCenterBody() {
        let g = geo()
        let w = StepWindow(shape: .rectangle)
        #expect(g.hitTest(g.rotatePoint(w), w) == .rotate)
        #expect(g.hitTest(g.edgePoint(.left, w)!, w) == .edge(.left))
        #expect(g.hitTest(g.centerPoint(w), w) == .center)
        #expect(g.hitTest(CGPoint(x: 490 + 100, y: 280 + 60), w) == .body)
        #expect(g.hitTest(CGPoint(x: 20, y: 20), w) == nil)
    }

    @Test func linearHasNoEdgesOrBody() {
        let g = geo()
        let w = StepWindow(shape: .linear)
        #expect(g.edgePoint(.right, w) == nil)
        #expect(g.hitTest(CGPoint(x: 490, y: 280 + 80), w) == nil)
        #expect(g.hitTest(g.centerPoint(w), w) == .center)
        #expect(g.hitTest(g.rotatePoint(w), w) == .rotate)
    }

    @Test func movingKeepsTheWindowOnThePicture() {
        let g = geo()
        let w = StepWindow()
        let press = g.centerPoint(w)
        let moved = g.dragged(.center, from: press, to: CGPoint(x: press.x + 96, y: press.y - 54), base: w)
        #expect(abs(moved.centerX - 0.6) < 1e-4 && abs(moved.centerY - 0.4) < 1e-4)
        #expect(moved.width == w.width && moved.softness == w.softness && moved.shape == w.shape)
        let off = g.dragged(.body, from: press, to: CGPoint(x: 5000, y: -5000), base: w)
        #expect(off.centerX == 1 && off.centerY == 0)
    }

    @Test func edgesResizeAroundTheCenterAndClamp() {
        let g = geo()
        let w = StepWindow(shape: .rectangle)
        let right = g.edgePoint(.right, w)!
        let wide = g.dragged(.edge(.right), from: right, to: CGPoint(x: right.x + 96, y: right.y), base: w)
        #expect(abs(wide.width - 0.7) < 1e-4 && wide.height == w.height && wide.centerX == w.centerX)
        let top = g.edgePoint(.top, w)!
        let tall = g.dragged(.edge(.top), from: top, to: CGPoint(x: top.x, y: top.y - 54), base: w)
        #expect(abs(tall.height - 0.7) < 1e-4)
        let tiny = g.dragged(.edge(.right), from: right, to: g.centerPoint(w), base: w)
        #expect(tiny.width == StepWindowEditGeometry.sizeRange.lowerBound)
        let huge = g.dragged(.edge(.right), from: right, to: CGPoint(x: 9000, y: 280), base: w)
        #expect(huge.width == StepWindowEditGeometry.sizeRange.upperBound)
    }

    @Test func rotateHandleSetsTheAngleFromTheCenter() {
        let g = geo()
        let w = StepWindow(shape: .rectangle)
        let c = g.centerPoint(w)
        let east = g.dragged(.rotate, from: g.rotatePoint(w), to: CGPoint(x: c.x + 200, y: c.y), base: w)
        #expect(abs(east.rotation - 90) < 1e-3)
        let up = g.dragged(.rotate, from: g.rotatePoint(w), to: CGPoint(x: c.x, y: c.y - 200), base: w)
        #expect(abs(up.rotation) < 1e-3)
        let south = g.dragged(.rotate, from: g.rotatePoint(w), to: CGPoint(x: c.x + 1, y: c.y + 200), base: w)
        #expect(abs(abs(south.rotation) - 180) < 1)
    }

    @Test func mappingFollowsTheClipTransform() {
        let t = ClipTransform(position: Vec2(200, 100), scale: Vec2(0.5, 0.5), rotation: 0)
        let g = geo(t)
        let w = StepWindow()
        let c = g.centerPoint(w)
        // 1920 px sequence -> 960 px view: offset (200, 100) is (100, 50) view points from the canvas center.
        #expect(close(c, CGPoint(x: 490 + 100, y: 280 + 50)))
        let e = g.edgePoint(.right, w)!
        #expect(abs((e.x - c.x) - 0.25 * 960 * 0.5) < 0.01)
    }
}
