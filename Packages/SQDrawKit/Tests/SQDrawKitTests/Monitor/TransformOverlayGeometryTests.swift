import Foundation
import SQCore
import Testing
@testable import SQDrawKit

private func geo(_ t: ClipTransform = .identity, aspect: Double = 16.0 / 9) -> TransformOverlayGeometry {
    // 1920x1080 sequence shown at half size, view origin offset by 10 px.
    TransformOverlayGeometry(sequenceSize: CGSize(width: 1920, height: 1080),
                             viewRect: CGRect(x: 10, y: 10, width: 960, height: 540),
                             mediaAspect: aspect, transform: t)
}
private func close(_ a: CGPoint, _ b: CGPoint, _ e: CGFloat = 0.001) -> Bool { abs(a.x - b.x) < e && abs(a.y - b.y) < e }

@Suite struct TransformOverlayGeometryTests {
    @Test func identityQuadFillsCanvas() {
        let q = geo().quad
        #expect(close(q[0], CGPoint(x: 10, y: 10)))
        #expect(close(q[2], CGPoint(x: 970, y: 550)))
    }

    @Test func portraitMediaIsPillarboxed() {
        let s = geo(aspect: 9.0 / 16).fittedSize
        #expect(abs(s.height - 1080) < 0.001 && abs(s.width - 607.5) < 0.001)
    }

    @Test func positionAndScaleMoveQuad() {
        let t = ClipTransform(position: Vec2(100, -50), scale: Vec2(0.5, 0.5))
        let q = geo(t).quad
        // canvas center (490,280) + (50,-25); half size 240x135.
        #expect(close(q[0], CGPoint(x: 540 - 240, y: 255 - 135)))
    }

    @Test func rotationIsClockwiseAboutAnchor() {
        let g = geo(ClipTransform(rotation: 90))
        // top-left corner (-960,-540) rotated 90 deg clockwise (y down) = (540, -960) -> view (270, -480) from center.
        #expect(close(g.quad[0], CGPoint(x: 490 + 270, y: 280 - 480)))
    }

    @Test func anchorOffsetPivotsScale() {
        let t = ClipTransform(position: .zero, scale: Vec2(2, 2), anchor: Vec2(-960, -540))
        let g = geo(t)
        #expect(close(g.quad[0], CGPoint(x: 490, y: 280)))
        #expect(close(g.quad[2], CGPoint(x: 490 + 1920, y: 280 + 1080)))
    }

    @Test func hitPriority() {
        let g = geo()
        #expect(g.hitTest(CGPoint(x: 490, y: 280)) == .anchor)                        // the anchor wins at the picture center
        #expect(g.hitTest(CGPoint(x: 498, y: 284)) == .anchor)                        // within 10 pt of the crosshair
        #expect(g.hitTest(CGPoint(x: 490, y: 280), anchorAlways: false) == .body)
        #expect(g.hitTest(CGPoint(x: 520, y: 280)) == .body)                          // beyond the anchor radius: move
        #expect(geo(ClipTransform(anchor: Vec2(400, 0))).hitTest(CGPoint(x: 490, y: 280)) == .anchor)
        #expect(g.hitTest(CGPoint(x: 12, y: 12)) == .handle(.topLeft))
        #expect(g.hitTest(CGPoint(x: 490, y: 11)) == .handle(.top))
        #expect(g.hitTest(CGPoint(x: 300, y: 200)) == .body)
        #expect(g.hitTest(CGPoint(x: 0, y: 0)) == .rotate(.topLeft))
        #expect(g.hitTest(CGPoint(x: 1100, y: 700)) == nil)
    }

    @Test func moveAndAxisLock() {
        let g = geo()
        let t = g.moved(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 150, y: 110))
        #expect(t.position == Vec2(100, 20))
        let l = g.moved(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 150, y: 110), lockAxis: true)
        #expect(l.position == Vec2(100, 0))
    }

    @Test func cornerScaleKeepsAnchorFixedAndFollowsPointer() {
        let g = geo()
        let h = g.viewPoint(of: .bottomRight)
        let t = g.scaled(handle: .bottomRight, from: h, to: CGPoint(x: h.x - 240, y: h.y - 135))
        #expect(abs(t.scale.x - 0.5) < 1e-9 && abs(t.scale.y - 0.5) < 1e-9)
        #expect(t.position == .zero)
    }

    @Test func optionPivotsOnOppositeCorner() {
        let g = geo()
        let h = g.viewPoint(of: .bottomRight)
        let t = g.scaled(handle: .bottomRight, from: h, to: CGPoint(x: h.x - 480, y: h.y - 270),
                         modifiers: .init(option: true))
        #expect(abs(t.scale.x - 0.5) < 1e-9)
        let q = geo(t).quad
        #expect(close(q[0], g.quad[0]))
        #expect(close(q[2], CGPoint(x: 490, y: 280)))
    }

    @Test func uniformScaleOffEdgesScaleOneAxisAndCornersAreFree() {
        let g = geo()
        let free = TransformOverlayGeometry.ScaleModifiers(uniformScale: false)
        let r = g.viewPoint(of: .right)
        let e = g.scaled(handle: .right, from: r, to: CGPoint(x: r.x - 240, y: r.y + 50), modifiers: free)
        #expect(abs(e.scale.x - 0.5) < 1e-9 && e.scale.y == 1)
        let tp = g.viewPoint(of: .top)
        let v = g.scaled(handle: .top, from: tp, to: CGPoint(x: tp.x + 80, y: tp.y + 135), modifiers: free)
        #expect(abs(v.scale.y - 0.5) < 1e-9 && v.scale.x == 1)
        let c = g.viewPoint(of: .bottomRight)
        let f = g.scaled(handle: .bottomRight, from: c, to: CGPoint(x: c.x - 240, y: c.y), modifiers: free)
        #expect(abs(f.scale.x - 0.5) < 1e-9 && f.scale.y == 1)                       // corner changes both freely
        let shifted = g.scaled(handle: .bottomRight, from: c, to: CGPoint(x: c.x - 240, y: c.y),
                               modifiers: .init(shift: true, uniformScale: false))
        #expect(abs(shifted.scale.x - shifted.scale.y) < 1e-9 && shifted.scale.x < 1)  // Shift locks the proportions
        let sideShift = g.scaled(handle: .right, from: r, to: CGPoint(x: r.x - 240, y: r.y),
                                 modifiers: .init(shift: true, uniformScale: false))
        #expect(abs(sideShift.scale.x - 0.5) < 1e-9 && abs(sideShift.scale.y - 0.5) < 1e-9)
    }

    @Test func uniformScaleOnEveryHandleScalesBothAxes() {
        let g = geo()
        for h in TransformOverlayGeometry.Handle.allCases {
            let p = g.viewPoint(of: h)
            let c = g.viewPoint(fromLocal: .zero)
            // Drag the handle halfway toward the center along its own direction.
            let t = g.scaled(handle: h, from: p, to: CGPoint(x: p.x + (c.x - p.x) / 2, y: p.y + (c.y - p.y) / 2))
            #expect(abs(t.scale.x - t.scale.y) < 1e-9, "\(h)")
            #expect(abs(t.scale.x - 0.5) < 1e-6, "\(h)")
            #expect(t.position == .zero, "\(h)")
        }
    }

    @Test func uniformEdgeDragFollowsItsAxisOnly() {
        let g = geo()
        let r = g.viewPoint(of: .right)
        let t = g.scaled(handle: .right, from: r, to: CGPoint(x: r.x - 240, y: r.y + 300))   // vertical wobble is ignored
        #expect(abs(t.scale.x - 0.5) < 1e-9 && abs(t.scale.y - 0.5) < 1e-9)
    }

    @Test func scaleClampsPositive() {
        let g = geo()
        let c = g.viewPoint(of: .bottomRight)
        let t = g.scaled(handle: .bottomRight, from: c, to: CGPoint(x: c.x - 2000, y: c.y - 2000))
        #expect(t.scale.x == TransformOverlayGeometry.minimumScale)
    }

    @Test func scaleOfRotatedLayer() {
        let g = geo(ClipTransform(rotation: 30))
        let h = g.viewPoint(of: .right)
        let a = g.anchorViewPoint
        let t = g.scaled(handle: .right, from: h, to: CGPoint(x: h.x - (h.x - a.x) / 2, y: h.y - (h.y - a.y) / 2))
        #expect(abs(t.scale.x - 0.5) < 1e-9 && t.position == .zero)
    }

    @Test func rotateAndSnap() {
        let g = geo()
        let c = g.anchorViewPoint
        let t = g.rotated(from: CGPoint(x: c.x + 100, y: c.y), to: CGPoint(x: c.x, y: c.y + 100))
        #expect(abs(t.rotation - 90) < 1e-9)
        let s = g.rotated(from: CGPoint(x: c.x + 100, y: c.y),
                          to: CGPoint(x: c.x + 100, y: c.y + 30), snap: true)   // ~16.7 deg
        #expect(s.rotation == 0)                                                    // 45-degree steps
        let s2 = g.rotated(from: CGPoint(x: c.x + 100, y: c.y), to: CGPoint(x: c.x + 100, y: c.y + 80), snap: true)   // ~38.7 deg
        #expect(s2.rotation == 45)
    }

    @Test func rotateRingSitsOutsideEachCornerHandle() {
        let g = geo()
        let corners: [(TransformOverlayGeometry.Handle, CGPoint, CGVector)] = [
            (.topLeft, CGPoint(x: 10, y: 10), CGVector(dx: -1, dy: -1)), (.topRight, CGPoint(x: 970, y: 10), CGVector(dx: 1, dy: -1)),
            (.bottomRight, CGPoint(x: 970, y: 550), CGVector(dx: 1, dy: 1)), (.bottomLeft, CGPoint(x: 10, y: 550), CGVector(dx: -1, dy: 1)),
        ]
        for (h, c, out) in corners {
            let n = sqrt(2.0)
            func at(_ d: CGFloat) -> CGPoint { CGPoint(x: c.x + out.dx * d / n, y: c.y + out.dy * d / n) }
            #expect(g.hitTest(at(3)) == .handle(h))                      // on the handle
            #expect(g.hitTest(at(10)) == .rotate(h))                     // zone starts just outside it ...
            #expect(g.hitTest(at(19)) == .rotate(h))                     // ... and reaches 20 pt
            #expect(g.hitTest(at(24)) == nil)                            // beyond: the monitor below
        }
    }

    @Test func rotateCursorNotAlongTheEdgesOnTheWayToTheCorner() {
        let g = geo()                                                    // quad (10,10)...(970,550), view y down
        // Just outside the top edge, 12 pt from the corner horizontally: beside the edge, no rotate zone.
        #expect(g.hitTest(CGPoint(x: 22, y: 4)) == nil)
        #expect(g.hitTest(CGPoint(x: 4, y: 22)) == nil)                  // same beside the left edge
        #expect(g.hitTest(CGPoint(x: 976, y: 540)) == nil)               // bottom right, beside the right edge
        // Past the corner on both axes: rotate.
        #expect(g.hitTest(CGPoint(x: 4, y: 4)) == .rotate(.topLeft))
        #expect(g.hitTest(CGPoint(x: 976, y: 556)) == .rotate(.bottomRight))
    }

    @Test func rotateRingFollowsRotatedLayer() {
        let g = geo(ClipTransform(rotation: 45))
        let c = g.viewPoint(of: .topLeft), centre = g.viewPoint(fromLocal: .zero)
        let len = hypot(c.x - centre.x, c.y - centre.y)
        let ux = (c.x - centre.x) / len, uy = (c.y - centre.y) / len
        #expect(g.hitTest(CGPoint(x: c.x + ux * 16, y: c.y + uy * 16)) == .rotate(.topLeft))
    }

    @Test func handleViewAngleTurnsWithTheObject() {
        let g = geo()
        #expect(abs(g.viewAngle(of: .right)) < 1e-6)
        #expect(abs(g.viewAngle(of: .bottom) - 90) < 1e-6)
        let r = geo(ClipTransform(rotation: 90))
        #expect(abs(r.viewAngle(of: .right) - 90) < 1e-6)
    }

    @Test func rotationContinuesPastHalfTurn() {
        let g = geo()
        let c = g.anchorViewPoint
        let start = CGPoint(x: c.x + 100, y: c.y)
        let t = g.rotated(from: start, to: CGPoint(x: c.x - 100, y: c.y - 1), continuingFrom: 170)
        #expect(t.rotation > 180 && t.rotation < 181)   // continues past 180 instead of wrapping to -179
        let u = g.rotated(from: start, to: CGPoint(x: c.x - 100, y: c.y + 1), continuingFrom: 179)
        #expect(u.rotation > 179 && u.rotation < 180)
    }

    @Test func anchorMoveKeepsPictureStill() {
        let t0 = ClipTransform(position: Vec2(30, 20), scale: Vec2(0.7, 1.3), rotation: 40, anchor: Vec2(10, -5))
        let g = geo(t0)
        let a = g.anchorViewPoint
        let t1 = g.anchorMoved(from: a, to: CGPoint(x: a.x + 60, y: a.y - 25))
        let before = g.quad, after = geo(t1).quad
        for i in 0..<4 { #expect(close(before[i], after[i], 0.0001)) }
        #expect(t1.anchor != t0.anchor)
        #expect(close(geo(t1).anchorViewPoint, CGPoint(x: a.x + 60, y: a.y - 25)))
    }

    @Test func motionPathKeysHandlesAndDrags() {
        let k1 = Keyframe(time: .zero, value: Vec2(-100, 0), outTangent: Vec2(50, 100))
        let k2 = Keyframe(time: Time(1, 1), value: Vec2(100, 0), inTangent: Vec2(-50, 100))
        let track = KeyframeTrack(keys: [k1, k2])
        let m = MotionPathGeometry(track: track, sequenceSize: CGSize(width: 1920, height: 1080),
                                   viewRect: CGRect(x: 0, y: 0, width: 960, height: 540), samplesPerSegment: 8)
        #expect(m.segments.count == 1 && m.segments[0].count == 8)
        #expect(close(m.keys[0].point, CGPoint(x: 430, y: 270)))
        #expect(close(m.keys[0].outHandle, CGPoint(x: 455, y: 320)))
        #expect(m.hitTest(CGPoint(x: 431, y: 271)) == .key(k1.id))
        #expect(m.hitTest(CGPoint(x: 455, y: 320)) == .outTangent(k1.id))
        #expect(m.hitTest(CGPoint(x: 10, y: 10)) == nil)
        #expect(m.keyValue(at: CGPoint(x: 480, y: 270)) == Vec2(0, 0))
        let tg = m.tangents(forKey: k1.id, dragging: .outTangent(k1.id), to: CGPoint(x: 480, y: 270),
                            independent: false, current: (.zero, Vec2(50, 100)))
        #expect(tg.out == Vec2(100, 0) && tg.in == Vec2(-100, 0))
    }

    @Test func uniformScaleNearMinimumKeepsProportions() {
        let g = geo(ClipTransform(scale: Vec2(2, 0.5)))
        let c = g.viewPoint(of: .bottomRight)
        let t = g.scaled(handle: .bottomRight, from: c, to: CGPoint(x: c.x - 5000, y: c.y - 5000))
        #expect(t.scale.y >= TransformOverlayGeometry.minimumScale - 1e-12)
        #expect(abs(t.scale.x / t.scale.y - 4) < 1e-6)
        let z = geo(ClipTransform(scale: Vec2(1, 0)))
        let zt = z.scaled(handle: .right, from: z.viewPoint(of: .right), to: CGPoint(x: 100, y: 100))
        #expect(zt.scale.x >= TransformOverlayGeometry.minimumScale && zt.scale.y >= TransformOverlayGeometry.minimumScale)
    }
}
