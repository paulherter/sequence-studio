import Foundation
import Testing
@testable import SQCore

// Drawing a Rectangle / Ellipse mask by dragging on the Program monitor (rubber band from mouse-down to the pointer;
// Shift = square / circle, Option = from the center).

@Suite struct MaskShapeDragTests {
    private let frame = Vec2(1920, 1080)

    private func bounds(_ p: MaskPath) -> (lo: Vec2, hi: Vec2) {
        let poly = p.polygon()
        return (Vec2(poly.map(\.x).min()!, poly.map(\.y).min()!), Vec2(poly.map(\.x).max()!, poly.map(\.y).max()!))
    }

    private func near(_ a: Vec2, _ b: Vec2, _ eps: Double = 1e-6) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }

    @Test func rectangleSpansFromPressToPointerInAnyDirection() {
        let d = MaskShapeDrag(kind: .rectangle, start: Vec2(0.6, 0.7))
        let p = d.path(to: Vec2(0.2, 0.3), square: false, fromCenter: false, frame: frame)
        #expect(p.vertices.count == 4)
        let b = bounds(p)
        #expect(near(b.lo, Vec2(0.2, 0.3)) && near(b.hi, Vec2(0.6, 0.7)))
    }

    @Test func ellipseFitsTheDraggedBox() {
        let d = MaskShapeDrag(kind: .ellipse, start: Vec2(0.1, 0.2))
        let p = d.path(to: Vec2(0.5, 0.6), square: false, fromCenter: false, frame: frame)
        #expect(p.vertices.count == 4)
        let b = bounds(p)
        #expect(near(b.lo, Vec2(0.1, 0.2), 1e-3) && near(b.hi, Vec2(0.5, 0.6), 1e-3))
    }

    @Test func shiftMakesASquareInFramePixels() {
        let d = MaskShapeDrag(kind: .rectangle, start: Vec2(0.5, 0.5))
        // Pointer further right than down: the larger side wins, the box grows toward the pointer.
        let b = bounds(d.path(to: Vec2(0.7, 0.6), square: true, fromCenter: false, frame: frame))
        let w = (b.hi.x - b.lo.x) * frame.x, h = (b.hi.y - b.lo.y) * frame.y
        #expect(abs(w - h) < 1e-6 && abs(w - 0.2 * 1920) < 1e-6)
        #expect(near(b.lo, Vec2(0.5, 0.5)))
        // Up-left drag: the square grows up and left.
        let q = bounds(d.path(to: Vec2(0.45, 0.2), square: true, fromCenter: false, frame: frame))
        #expect(abs(q.hi.x - 0.5) < 1e-9 && abs(q.hi.y - 0.5) < 1e-9)
        #expect(abs((q.hi.x - q.lo.x) * frame.x - (q.hi.y - q.lo.y) * frame.y) < 1e-6)
    }

    @Test func optionDrawsFromTheCentre() {
        let d = MaskShapeDrag(kind: .ellipse, start: Vec2(0.5, 0.5))
        let b = bounds(d.path(to: Vec2(0.6, 0.7), square: false, fromCenter: true, frame: frame))
        #expect(near(b.lo, Vec2(0.4, 0.3), 1e-3) && near(b.hi, Vec2(0.6, 0.7), 1e-3))
        let s = bounds(d.path(to: Vec2(0.6, 0.55), square: true, fromCenter: true, frame: frame))
        #expect(abs((s.hi.x - s.lo.x) * frame.x - (s.hi.y - s.lo.y) * frame.y) < 0.5)
        #expect(abs((s.lo.x + s.hi.x) / 2 - 0.5) < 1e-3 && abs((s.lo.y + s.hi.y) / 2 - 0.5) < 1e-3)
    }

    @Test func aPressWithoutADragIsAClick() {
        #expect(MaskShapeDrag.isClick(viewDistance: 0))
        #expect(MaskShapeDrag.isClick(viewDistance: 2.9))
        #expect(!MaskShapeDrag.isClick(viewDistance: 3))
    }

    @Test func addDrawnMaskStoresThePathOnce() throws {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
        let path = MaskShapeDrag(kind: .rectangle, start: Vec2(0.1, 0.1))
            .path(to: Vec2(0.3, 0.4), square: false, fromCenter: false, frame: frame)
        let a = c.addShapeMask(.rectangle, path: path)
        let b = c.addShapeMask(.ellipse, path: path)
        #expect(c.masks.count == 2 && a != b)
        let m = try #require(c.mask(a))
        #expect(m.kind == .rectangle && m.path.value == path && m.name == "Mask (1)" && m.feather.value == ClipMask.defaultFeather)
        #expect(c.mask(b)?.name == "Mask (2)")
    }
}
