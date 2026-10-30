import CoreGraphics
import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

@Suite struct MaskOverlayGeometryTests {
    @Test func mapsFrameFractionsThroughTheQuadAndBack() {
        // A 200 x 100 layer at (50, 20), rotated 90 degrees clockwise: top-left, top-right, bottom-right, bottom-left.
        let q = [CGPoint(x: 150, y: 20), CGPoint(x: 150, y: 220), CGPoint(x: 50, y: 220), CGPoint(x: 50, y: 20)]
        let g = MaskOverlayGeometry(quad: q)
        #expect(g.viewPoint(Vec2(0, 0)) == q[0])
        #expect(g.viewPoint(Vec2(1, 1)) == q[2])
        #expect(g.viewPoint(Vec2(0.5, 0.5)) == CGPoint(x: 100, y: 120))
        let back = g.framePoint(CGPoint(x: 75, y: 70))!
        #expect(abs(back.x - 0.25) < 1e-9 && abs(back.y - 0.75) < 1e-9)
    }

    @Test func degenerateQuadHasNoInverse() {
        let p = CGPoint(x: 10, y: 10)
        #expect(MaskOverlayGeometry(quad: [p, p, p, p]).framePoint(p) == nil)
    }

    @Test func hitsTheNearestVertexWithinTheRadius() {
        let g = MaskOverlayGeometry(quad: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)])
        let m = [MaskOverlay(id: UUID(), path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))]
        let hit = g.hitVertex(CGPoint(x: 81, y: 79), masks: m)
        #expect(hit?.mask == 0 && hit?.vertex == 2)
        #expect(g.hitVertex(CGPoint(x: 50, y: 50), masks: m) == nil)
    }
}

@MainActor @Suite struct EffectControlsMaskTests {
    final class Log { var edits: [(Clip, String, Bool)] = [] }

    func rig() -> (EffectControlsModel, Log) {
        let clip = Clip(name: "c", media: UUID(), kind: .video,
                        source: TimeRange(start: .zero, duration: Time(10, 1)), start: Time(5, 1))
        let m = EffectControlsModel(); let log = Log()
        m.onEdit = { c, n, co in log.edits.append((c, n, co)) }
        m.setClip(clip); m.playhead = Time(6, 1)
        return (m, log)
    }

    @Test func addAndRemoveMasks() throws {
        let (m, log) = rig()
        let a = try #require(m.addMask(.rectangle))
        let b = try #require(m.addMask(.ellipse))
        #expect(m.clip!.masks.map(\.name) == ["Mask (1)", "Mask (2)"])
        #expect(m.clip!.masks[1].kind == .ellipse)
        #expect(m.maskOverlays.map(\.id) == [a, b])
        m.removeMask(a)
        #expect(m.clip!.masks.map(\.id) == [b])
        #expect(log.edits.map(\.1) == ["Add Mask", "Add Mask", "Delete Mask"])
        m.removeAllMasks()
        #expect(m.clip!.masks.isEmpty && log.edits.last?.1 == "Delete Masks")
    }

    @Test func subjectMasksHaveNoFrameHandles() throws {
        let (m, _) = rig()
        let a = try #require(m.addMask(.rectangle))
        var c = try #require(m.clip)
        c.masks.append(ClipMask.makeSubject(name: "Subject"))
        m.setClip(c)
        // W9.8: the person matte has no path to drag; only the rectangle shows outline and vertices.
        #expect(m.maskOverlays.map(\.id) == [a])
    }

    @Test func draggingAVertexIsOneUndoStepFromTheGestureBase() throws {
        let (m, log) = rig()
        let id = try #require(m.addMask(.rectangle))
        let start = m.clip!.mask(id)!.path.value
        m.beginGesture()
        m.moveMaskVertex(id, index: 0, to: Vec2(0.1, 0.1))
        m.moveMaskVertex(id, index: 0, to: Vec2(0.05, 0.12))
        m.endGesture()
        let p = m.clip!.mask(id)!.path.value
        #expect(p.vertices[0].point == Vec2(0.05, 0.12))
        #expect(Array(p.vertices.dropFirst()) == Array(start.vertices.dropFirst()))
        #expect(log.edits.suffix(2).map(\.2) == [false, true])          // second call coalesces into the first
    }

    @Test func animatedPathGetsAKeyAtThePlayhead() throws {
        let (m, _) = rig()
        let id = try #require(m.addMask(.rectangle))
        m.setMaskPathAnimated(id, true)
        m.playhead = Time(8, 1)
        m.moveMaskVertex(id, index: 1, to: Vec2(0.9, 0.1))
        let keys = m.clip!.mask(id)!.path.track.keys
        #expect(keys.map(\.time) == [Time(1, 1), Time(3, 1)])
        #expect(m.maskOverlays[0].path.vertices[1].point == Vec2(0.9, 0.1))
        // Outside the clip an animated path is not written.
        m.playhead = Time(30, 1)
        m.moveMaskVertex(id, index: 1, to: Vec2(0.5, 0.5))
        #expect(m.clip!.mask(id)!.path.track.keys.count == 2)
    }
}

@Suite struct PasteAttributesMaskTests {
    func clip(_ masks: [ClipMask]) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        c.masks = masks
        return c
    }

    @Test func masksPasteWithTheOpacityGroupOnly() {
        let src = clip([ClipMask(path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))])
        let keep = ClipMask(path: .ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.1, 0.1)))
        let dst = clip([keep])
        let withOpacity = dst.pastingAttributes(from: src, groups: [.opacity])
        #expect(withOpacity.masks.map(\.path.value) == src.masks.map(\.path.value))
        let motionOnly = dst.pastingAttributes(from: src, groups: [.motion, .effects])
        #expect(motionOnly.masks == [keep])
    }
}
