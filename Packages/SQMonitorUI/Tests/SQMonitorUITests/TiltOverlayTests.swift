import CoreGraphics
import Foundation
import SQCore
import Testing
@testable import SQMonitorUI

// The transform overlay follows a tilted layer: its quad and handles sit where the compositor draws the corners, and
// the drag reducers read the pointer back through the tilt. At 0 / 0 nothing changes.
@Suite struct TiltOverlayTests {
    private let seq = CGSize(width: 1920, height: 1080)
    private func geo(_ t: ClipTransform) -> TransformOverlayGeometry {
        TransformOverlayGeometry(sequenceSize: seq, viewRect: CGRect(x: 0, y: 0, width: 960, height: 540),
                                 mediaAspect: 16.0 / 9, transform: t)
    }

    @Test func untiltedQuadIsTheFlatOne() {
        let t = ClipTransform(position: Vec2(40, -20), scale: Vec2(0.5, 0.5), rotation: 15)
        let a = geo(t), b = geo(ClipTransform(position: t.position, scale: t.scale, rotation: t.rotation, tiltX: 0, tiltY: 0))
        #expect(a.quad == b.quad)
        #expect(a.quad[0] == a.viewPoint(fromOffset: a.flatOffset(fromLocal: Vec2(-960, -540), t)))
    }

    @Test func tiltedQuadFollowsTheSharedProjection() {
        let t = ClipTransform(position: Vec2(100, 50), scale: Vec2(0.5, 0.5), tiltY: 50)
        let g = geo(t)
        let s = g.fittedSize
        let f = g.tiltFocal(t)
        let corner = Vec2(Double(s.width) / 2, Double(s.height) / 2)
        let flat = Vec2(corner.x * 0.5, corner.y * 0.5)
        let want = t.position + PerspectiveTilt.project(flat, tiltX: 0, tiltY: 50, focal: f)
        let got = g.offset(fromLocal: corner, t)
        #expect(abs(got.x - want.x) < 1e-9 && abs(got.y - want.y) < 1e-9)
        // The anchor stays at the position and the far (right) edge is shorter than the near one.
        #expect(g.anchorViewPoint == g.viewPoint(fromOffset: t.position))
        let q = g.quad
        #expect(abs(q[1].y - q[2].y) < abs(q[0].y - q[3].y))
    }

    @Test func bodyHitFollowsTheTiltedQuad() {
        let g = geo(ClipTransform(scale: Vec2(0.5, 0.5), tiltY: 70))
        #expect(g.hitTest(g.viewPoint(fromLocal: Vec2(300, 100)), anchorAlways: false) == .body)
        // A point of the flat quad's far corner region that the tilt has left empty.
        let flat = geo(ClipTransform(scale: Vec2(0.5, 0.5)))
        let corner = flat.quad[1]
        let p = CGPoint(x: corner.x - 9, y: corner.y + 9)
        #expect(flat.hitTest(p, anchorAlways: false) == .body)
        #expect(g.hitTest(p, anchorAlways: false) != .body)
    }

    @Test func scalingAHandleWhileTiltedGrowsByTheRightFactor() {
        let t = ClipTransform(scale: Vec2(0.5, 0.5), tiltY: 40)
        let g = geo(t)
        let start = g.viewPoint(of: .right)
        // Pulling the handle to where the layer point at twice the distance lands doubles the scale.
        let far = g.viewPoint(fromOffset: g.offset(fromLocal: Vec2(Double(g.fittedSize.width), 0), t))
        let out = g.scaled(handle: .right, from: start, to: far)
        #expect(abs(out.scale.x - 1.0) < 1e-6)
        #expect(out.tiltY == 40 && out.position == t.position)
    }

    @Test func anchorDragWhileTiltedKeepsThePictureAndFollowsThePointer() {
        let t = ClipTransform(position: Vec2(60, -30), scale: Vec2(0.5, 0.5), rotation: 10, tiltX: 30, tiltY: 20)
        let g = geo(t)
        let to = CGPoint(x: g.anchorViewPoint.x + 24, y: g.anchorViewPoint.y - 12)
        let m = g.anchorMoved(from: g.anchorViewPoint, to: to)
        #expect(m.anchor != t.anchor && m.tiltX == 30 && m.tiltY == 20 && m.scale == t.scale)
        // The corners stay close to where they were (the pivot move is a small perspective change).
        let g2 = geo(m)
        let s = g.fittedSize
        var worst = 0.0
        for c in [Vec2(-1, -1), Vec2(1, -1), Vec2(1, 1), Vec2(-1, 1)] {
            let l = Vec2(c.x * Double(s.width) / 2, c.y * Double(s.height) / 2)
            let a = g.offset(fromLocal: l, t), b = g2.offset(fromLocal: l, m)
            worst = max(worst, hypot(a.x - b.x, a.y - b.y))
        }
        #expect(worst < 16)   // a pivot move cannot be exactly invisible under perspective
        // The new anchor sits near the pointer.
        let want = g.offset(fromView: to)
        #expect(hypot(m.position.x - want.x, m.position.y - want.y) < 6)
    }

    @Test func anchorDragFlatIsUnchanged() {
        let f = geo(ClipTransform())
        let to = CGPoint(x: f.anchorViewPoint.x + 20, y: f.anchorViewPoint.y)
        let m = f.anchorMoved(from: f.anchorViewPoint, to: to)
        #expect(m.position.x > 0 && m.anchor.x > 0)
    }

    @Test func optionScalingWhileTiltedKeepsThePivotOnScreen() {
        let t = ClipTransform(position: Vec2(20, 10), scale: Vec2(0.5, 0.5), tiltX: 25, tiltY: 40)
        let g = geo(t)
        let start = g.viewPoint(of: .right)
        let to = CGPoint(x: start.x + 40, y: start.y)
        let out = g.scaled(handle: .right, from: start, to: to, modifiers: .init(option: true))
        #expect(out.scale.x > t.scale.x)
        // The left edge midpoint (the pivot) stays put, the handle lands on the pointer.
        let g2 = geo(out)
        let s = g.fittedSize
        let pivotL = Vec2(-Double(s.width) / 2, 0), handleL = Vec2(Double(s.width) / 2, 0)
        let p0 = g.offset(fromLocal: pivotL, t), p1 = g2.offset(fromLocal: pivotL, out)
        #expect(hypot(p0.x - p1.x, p0.y - p1.y) < 1e-6)
        let h = g2.viewPoint(fromOffset: g2.offset(fromLocal: handleL, out))
        #expect(hypot(h.x - to.x, h.y - to.y) < 0.05)
    }

    @Test func optionScalingNearTheTiltLimitStaysFiniteAndKeepsThePivot() {
        for tilt in [80.0, -80.0, 88.0] {
            let t = ClipTransform(position: Vec2(30, -10), scale: Vec2(0.6, 0.6), tiltX: tilt / 2, tiltY: tilt)
            let g = geo(t)
            for h in [TransformOverlayGeometry.Handle.right, .left, .topRight] {
                let start = g.viewPoint(of: h)
                for dx in [-60.0, 25, 90] {
                    let to = CGPoint(x: start.x + CGFloat(dx), y: start.y + CGFloat(dx) / 3)
                    let out = g.scaled(handle: h, from: start, to: to, modifiers: .init(option: true))
                    #expect(out.scale.x.isFinite && out.scale.y.isFinite && out.position.x.isFinite && out.position.y.isFinite)
                    #expect(out.scale.x > 0 && out.scale.y > 0)
                    // The pivot (opposite handle) keeps its screen place.
                    let g2 = geo(out)
                    let pv = g.localPoint(of: h)
                    let pivotL = Vec2(h.direction.x != 0 ? -pv.x : t.anchor.x, h.direction.y != 0 ? -pv.y : t.anchor.y)
                    let a = g.offset(fromLocal: pivotL, t), b = g2.offset(fromLocal: pivotL, out)
                    #expect(hypot(a.x - b.x, a.y - b.y) < 1e-6)
                }
            }
        }
    }
}
