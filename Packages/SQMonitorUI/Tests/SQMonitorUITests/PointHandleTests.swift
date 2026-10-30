import CoreGraphics
import Foundation
import Testing
import SQCore
@testable import SQMonitorUI

@Suite struct SafeAreaSnapTests {
    private let canvas = CGSize(width: 1920, height: 1080)

    @Test func safeAreaTargetsAreCentredFractionsOfTheCanvas() {
        let t = SnapGuides.targets(canvas: canvas, others: [], safeAreas: [.title, .action])
        // Title 80 %: +-768 / +-432; Action 90 %: +-864 / +-486.
        #expect(t.xs.contains(-768) && t.xs.contains(768) && t.xs.contains(-864) && t.xs.contains(864))
        #expect(t.ys.contains(-432) && t.ys.contains(432) && t.ys.contains(-486) && t.ys.contains(486))
        // Canvas center and edges stay.
        #expect(t.xs.contains(0) && t.xs.contains(960) && t.ys.contains(-540))
    }

    @Test func defaultTargetsHaveNoSafeLines() {
        let t = SnapGuides.targets(canvas: canvas, others: [])
        #expect(t.xs.count == 3 && t.ys.count == 3)
    }

    @Test func layerEdgeSnapsToTitleSafe() {
        let t = SnapGuides.targets(canvas: canvas, others: [], safeAreas: [.title])
        // Layer 200 wide whose right edge is 3 px short of the title-safe line at x = 768.
        let box = CGRect(x: 565, y: -50, width: 200, height: 100)
        let r = SnapGuides.snap(box: box, targets: t, threshold: 6)
        #expect(r.dx == 3 && r.verticalLines == [768])
    }

    @Test func safeAreaRectIsCentred() {
        let r = SafeArea.title.rect(in: canvas)
        #expect(r == CGRect(x: -768, y: -432, width: 1536, height: 864))
    }
}

@Suite struct PointHandleGeometryTests {
    private let geo = PointHandleGeometry(sequenceSize: CGSize(width: 1920, height: 1080),
                                          viewRect: CGRect(x: 100, y: 50, width: 960, height: 540))

    @Test func viewPointAndBackRoundTrip() {
        let o = Vec2(480, -270)
        let p = geo.viewPoint(fromOffset: o)
        #expect(p == CGPoint(x: 580 + 240, y: 320 - 135))
        #expect(geo.offset(fromView: p) == o)
    }

    @Test func hitTestPicksNearestWithinRadius() {
        let hs = [PointHandle(id: "a", offset: Vec2(0, 0)), PointHandle(id: "b", offset: Vec2(20, 0))]
        // a at view (580, 320), b at (590, 320).
        #expect(geo.hitTest(CGPoint(x: 583, y: 320), handles: hs) == "a")
        #expect(geo.hitTest(CGPoint(x: 588, y: 320), handles: hs) == "b")
        #expect(geo.hitTest(CGPoint(x: 700, y: 320), handles: hs) == nil)
    }

    @Test func dragKeepsGrabOffset() {
        let h = PointHandle(id: "a", offset: Vec2(100, 100))
        let start = geo.viewPoint(fromOffset: h.offset)
        let grab = CGPoint(x: start.x + 3, y: start.y - 2)
        let r = geo.dragged(h, grabbedAt: grab, to: CGPoint(x: grab.x + 50, y: grab.y + 25), snap: nil)
        #expect(r.offset == Vec2(200, 150))
        #expect(r.guides == .none)
    }

    @Test func dragSnapsToCanvasCentre() {
        let h = PointHandle(id: "a", offset: Vec2(100, 100))
        let t = SnapGuides.targets(canvas: CGSize(width: 1920, height: 1080), others: [])
        let start = geo.viewPoint(fromOffset: h.offset)
        // Target offset (-4, 3) is within 6 view px (12 sequence px) of the center cross.
        let target = geo.viewPoint(fromOffset: Vec2(-4, 3))
        let r = geo.dragged(h, grabbedAt: start, to: target, snap: .init(targets: t, viewThreshold: 6))
        #expect(r.offset == Vec2(0, 0))
        #expect(r.guides.verticalLines == [0] && r.guides.horizontalLines == [0])
    }

    @Test func shiftLocksToDominantAxisAndDisablesSnapOnLockedAxis() {
        let h = PointHandle(id: "a", offset: Vec2(100, 100))
        let t = SnapGuides.targets(canvas: CGSize(width: 1920, height: 1080), others: [])
        let start = geo.viewPoint(fromOffset: h.offset)
        let r = geo.dragged(h, grabbedAt: start, to: CGPoint(x: start.x - 80, y: start.y + 2), lockAxis: true,
                            snap: .init(targets: t, viewThreshold: 6))
        #expect(r.offset.y == 100)
        #expect(r.guides.horizontalLines.isEmpty)
    }

    @Test func normalizedMapsCanvasToUnitSquare() {
        #expect(geo.normalized(Vec2(-960, -540)) == Vec2(0, 0))
        #expect(geo.normalized(Vec2(960, 540)) == Vec2(1, 1))
        #expect(geo.offset(fromNormalized: Vec2(0.5, 0.5)) == Vec2(0, 0))
        let back = geo.offset(fromNormalized: geo.normalized(Vec2(120, -60)))
        #expect(abs(back.x - 120) < 1e-9 && abs(back.y + 60) < 1e-9)
    }
}

@Suite struct CornerWarpHandleTests {
    let frame = CGSize(width: 1920, height: 1080)

    @Test func handleSitsAtTheWarpedCorner() {
        let l = PointHandleMapping.cornerLocal(key: ClipEffect.cornerPinBottomRightKey, value: Vec2(-100, 20), frame: frame)
        #expect(l == Vec2(860, 560))
        let zero = PointHandleMapping.cornerLocal(key: ClipEffect.cornerPinTopLeftKey, value: .zero, frame: frame)
        #expect(zero == Vec2(-960, -540))
    }

    @Test func dragWritesTheOffsetAndRoundTrips() {
        for key in [ClipEffect.cornerPinTopLeftKey, ClipEffect.cornerPinTopRightKey,
                    ClipEffect.cornerPinBottomRightKey, ClipEffect.cornerPinBottomLeftKey] {
            let v = Vec2(33, -17)
            let l = PointHandleMapping.cornerLocal(key: key, value: v, frame: frame)
            #expect(PointHandleMapping.cornerValue(key: key, local: l, frame: frame) == v)
        }
        #expect(PointHandleMapping.cornerBase(key: "other", frame: frame) == nil)
    }

    @Test func hitTestFindsTheWarpedCornerUnderTheTransform() {
        var t = ClipTransform.identity
        t.position = Vec2(10, 0)
        let l = PointHandleMapping.cornerLocal(key: ClipEffect.cornerPinTopRightKey, value: Vec2(-50, 40), frame: frame)
        let h = PointHandle(id: "a|k", offset: PointHandleMapping.offset(forLocal: l, transform: t))
        let geo = PointHandleGeometry(sequenceSize: frame, viewRect: CGRect(x: 0, y: 0, width: 960, height: 540))
        let p = geo.viewPoint(fromOffset: h.offset)
        #expect(geo.hitTest(CGPoint(x: p.x + 2, y: p.y), handles: [h]) == "a|k")
        #expect(geo.hitTest(CGPoint(x: p.x + 40, y: p.y), handles: [h]) == nil)
    }
}

@Suite struct PointHandleMappingTests {
    @Test func localToOffsetAndBackUnderTransform() {
        var t = ClipTransform.identity
        t.position = Vec2(100, 50); t.scale = Vec2(2, 2); t.rotation = 90
        // Local (10, 0) -> scaled (20, 0) -> rotated 90 deg clockwise (y down) (0, 20) -> + position.
        let o = PointHandleMapping.offset(forLocal: Vec2(10, 0), transform: t)
        #expect(abs(o.x - 100) < 1e-9 && abs(o.y - 70) < 1e-9)
        let l = PointHandleMapping.local(forOffset: o, transform: t)
        #expect(abs(l.x - 10) < 1e-9 && abs(l.y) < 1e-9)
    }

    @Test func anchorShiftsTheOrigin() {
        var t = ClipTransform.identity
        t.anchor = Vec2(5, 5)
        let o = PointHandleMapping.offset(forLocal: Vec2(5, 5), transform: t)
        #expect(o == .zero)
    }
}
