import Foundation
import SQCore
import Testing
@testable import SQDrawKit

private func geo(_ t: ClipTransform = .identity) -> ZoomEditGeometry {
    ZoomEditGeometry(layer: TransformOverlayGeometry(sequenceSize: CGSize(width: 1920, height: 1080),
                                                     viewRect: CGRect(x: 10, y: 10, width: 960, height: 540),
                                                     mediaAspect: 16.0 / 9, transform: t))
}
private func close(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.001) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }

@Suite struct ZoomEditGeometryTests {
    @Test func normalisedAndViewPointsRoundTripThroughMotion() {
        let t = ClipTransform(position: Vec2(120, -40), scale: Vec2(0.6, 0.6), rotation: 20)
        let g = geo(t)
        for n in [Vec2(0, 0), Vec2(0.3, 0.8), Vec2(1, 1)] {
            let back = g.normalised(g.viewPoint(n))
            #expect(abs(back.x - n.x) < 1e-9 && abs(back.y - n.y) < 1e-9)
        }
    }

    @Test func fullWindowCoversTheCanvasAtIdentity() {
        let q = geo().quad(of: .full)
        #expect(close(q[0], CGPoint(x: 10, y: 10)) && close(q[2], CGPoint(x: 970, y: 550)))
    }

    @Test func cornersWinOverBodiesAndTheEndWindowOverTheStart() {
        let g = geo()
        let s = ZoomRect.full, e = ZoomRect.centred(zoom: 2)
        #expect(g.hitTest(CGPoint(x: 11, y: 11), start: s, end: e) == .corner(.start, .topLeft))
        #expect(g.hitTest(g.corner(.topLeft, of: e), start: s, end: e) == .corner(.end, .topLeft))
        #expect(g.hitTest(g.viewPoint(Vec2(0.5, 0.5)), start: s, end: e) == .body(.end))
        #expect(g.hitTest(g.viewPoint(Vec2(0.1, 0.5)), start: s, end: e) == .body(.start))
        #expect(g.hitTest(CGPoint(x: -50, y: -50), start: s, end: e) == nil)
    }

    @Test func draggingTheBodyMovesTheWindowByTheNormalisedDistance() {
        let g = geo()
        let e = ZoomRect.centred(zoom: 2)
        let a = g.viewPoint(Vec2(0.5, 0.5)), b = g.viewPoint(Vec2(0.6, 0.55))
        let out = g.dragged(.body(.end), from: a, to: b, base: (.full, e))
        #expect(abs(out.end.x - 0.35) < 1e-9 && abs(out.end.y - 0.3) < 1e-9 && out.start == .full)
    }

    @Test func draggingACornerResizesAroundTheOppositeCorner() {
        let g = geo()
        let e = ZoomRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let out = g.dragged(.corner(.end, .bottomRight), from: g.corner(.bottomRight, of: e), to: g.viewPoint(Vec2(0.9, 0.9)),
                            base: (.full, e))
        #expect(abs(out.end.x - 0.25) < 1e-9 && abs(out.end.width - 0.65) < 1e-9)
        #expect(out.end.zoom > 1.5)
    }
}

