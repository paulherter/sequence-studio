import Foundation
import Testing
@testable import SQCore

/// Mask pen handles (tangents, add / delete vertex, corner <-> smooth, move the whole mask) and mask tracking keys.
@Suite struct MaskPathEditingTests {
    func clip(_ masks: [ClipMask] = []) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: Time(10, 1))
        c.masks = masks
        return c
    }

    func close(_ a: Vec2, _ b: Vec2, _ eps: Double = 1e-9) -> Bool { (a - b).length < eps }

    // MARK: Splitting a segment

    @Test func splittingAStraightSegmentAddsACornerOnTheLine() {
        let p = MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1)).splitting(segment: 0, at: 0.25)
        #expect(p.vertices.count == 5)
        #expect(close(p.vertices[1].point, Vec2(0.25, 0)))
        #expect(p.vertices[1].isCorner)
        #expect(p.polygon().count == 5)
    }

    @Test func splittingACurveKeepsItsShape() {
        let e = MaskPath.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.2, 0.2))
        let p = e.splitting(segment: 1, at: 0.5)
        #expect(p.vertices.count == 5)
        // The new vertex lies on the circle, and the curve through it still is the circle.
        let v = p.vertices[2].point
        #expect(abs((v - Vec2(0.5, 0.5)).length - 0.2) < 0.001)
        for q in p.polygon() { #expect(abs((q - Vec2(0.5, 0.5)).length - 0.2) < 0.001) }
        // Neighbors' tangents shrink to the halves.
        #expect(close(p.vertices[1].outTangent, e.vertices[1].outTangent * 0.5))
        #expect(close(p.vertices[3].inTangent, e.vertices[2].inTangent * 0.5))
    }

    @Test func splittingTheClosingSegmentAppendsAtTheEnd() {
        let p = MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1)).splitting(segment: 3, at: 0.5)
        #expect(p.vertices.count == 5)
        #expect(close(p.vertices[4].point, Vec2(0, 0.5)))
        #expect(close(p.vertices[0].point, Vec2(0, 0)))
    }

    @Test func nearestSegmentFindsTheEdgeUnderThePointer() throws {
        let p = MaskPath.rectangle(Vec2(0.25, 0.25), Vec2(0.75, 0.75))
        let hit = try #require(p.nearestSegment(to: Vec2(0.5, 0.26), frame: Vec2(100, 100)))
        #expect(hit.segment == 0)
        #expect(abs(hit.t - 0.5) < 0.01)
        #expect(abs(hit.distance - 1) < 0.01)
        let right = try #require(p.nearestSegment(to: Vec2(0.76, 0.375), frame: Vec2(100, 100)))
        #expect(right.segment == 1 && abs(right.t - 0.25) < 0.01)
    }

    // MARK: Vertices and tangents

    @Test func removingAVertexKeepsAtLeastThree() {
        let r = MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1))
        let three = r.removingVertex(1)
        #expect(three?.vertices.count == 3)
        #expect(three?.removingVertex(0) == nil)
        #expect(r.removingVertex(9) == nil)
    }

    @Test func togglingSmoothGivesTangentsAlongTheNeighboursAndBack() {
        let r = MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1))
        let s = r.togglingSmooth(0)
        let v = s.vertices[0]
        #expect(!v.isCorner)
        // Tangent direction parallel to the chord from the previous (0,1) to the next (1,0) vertex, opposite sides.
        #expect(abs(v.outTangent.x + v.inTangent.x) < 1e-9 && abs(v.outTangent.y + v.inTangent.y) < 1e-9)
        #expect(v.outTangent.x > 0 && v.outTangent.y < 0)
        #expect(s.togglingSmooth(0).vertices[0].isCorner)
    }

    @Test func draggingATangentMirrorsUnlessIndependent() {
        var p = MaskPath.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.2, 0.2))
        p.setTangent(0, out: true, to: Vec2(0.3, 0.1), independent: false)
        #expect(p.vertices[0].outTangent == Vec2(0.3, 0.1))
        #expect(close(p.vertices[0].inTangent, Vec2(-0.3, -0.1)))
        p.setTangent(0, out: false, to: Vec2(0, 0.2), independent: true)
        #expect(p.vertices[0].inTangent == Vec2(0, 0.2) && p.vertices[0].outTangent == Vec2(0.3, 0.1))
    }

    // MARK: Clip editing over keys

    @Test func insertingAVertexChangesEveryKeySoTheyStillBlend() {
        var m = ClipMask.make(.rectangle, name: "M")
        m.path.track.insert(Keyframe(time: .zero, value: .rectangle(Vec2(0, 0), Vec2(0.5, 0.5))))
        m.path.track.insert(Keyframe(time: Time(2, 1), value: .rectangle(Vec2(0.5, 0.5), Vec2(1, 1))))
        var c = clip([m])
        c.insertMaskVertex(m.id, segment: 0, at: 0.5)
        let keys = c.mask(m.id)!.path.track.keys
        #expect(keys.allSatisfy { $0.value.vertices.count == 5 })
        let mid = c.mask(m.id)!.path.value(atLocal: Time(1, 1))
        #expect(close(mid.vertices[1].point, Vec2(0.5, 0.25)))
        let removed = c.removeMaskVertex(m.id, 1)
        #expect(removed)
        #expect(c.mask(m.id)!.path.track.keys.allSatisfy { $0.value.vertices.count == 4 })
    }

    @Test func insertingIntoAStaticPathChangesTheValue() {
        let m = ClipMask.make(.rectangle, name: "M")
        var c = clip([m])
        c.insertMaskVertex(m.id, segment: 2, at: 0.5)
        #expect(c.mask(m.id)!.path.value.vertices.count == 5)
        #expect(!c.mask(m.id)!.path.isAnimated)
    }

    // MARK: Pen: click-drag on the outline places a vertex and pulls its handles

    @Test func placingAVertexWithoutADragIsAPlainSplit() {
        let r = MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1))
        #expect(r.placingVertex(segment: 0, at: 0.5, handle: .zero, independent: false) == r.splitting(segment: 0, at: 0.5))
    }

    @Test func draggingWhilePlacingPullsMirroredHandlesAndOptionBreaksThem() {
        let r = MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1))
        let p = r.placingVertex(segment: 0, at: 0.5, handle: Vec2(0.2, -0.1), independent: false)
        #expect(p.vertices.count == 5)
        #expect(close(p.vertices[1].point, Vec2(0.5, 0)))
        #expect(close(p.vertices[1].outTangent, Vec2(0.2, -0.1)) && close(p.vertices[1].inTangent, Vec2(-0.2, 0.1)))
        let q = r.placingVertex(segment: 0, at: 0.5, handle: Vec2(0.2, -0.1), independent: true)
        #expect(close(q.vertices[1].outTangent, Vec2(0.2, -0.1)) && q.vertices[1].inTangent == .zero)
    }

    @Test func placingAVertexOnAClipAddsItToEveryKeyAndShapesTheShownPath() {
        var m = ClipMask.make(.rectangle, name: "M")
        m.path.track.insert(Keyframe(time: .zero, value: .rectangle(Vec2(0, 0), Vec2(0.5, 0.5))))
        m.path.track.insert(Keyframe(time: Time(2, 1), value: .rectangle(Vec2(0.5, 0.5), Vec2(1, 1))))
        var c = clip([m])
        c.placeMaskVertex(m.id, segment: 0, at: 0.5, handle: Vec2(0.1, 0), independent: false, atLocal: .zero)
        let keys = c.mask(m.id)!.path.track.keys.sorted { $0.time < $1.time }
        #expect(keys.allSatisfy { $0.value.vertices.count == 5 })
        #expect(close(keys[0].value.vertices[1].outTangent, Vec2(0.1, 0)))
        #expect(keys[1].value.vertices[1].isCorner)   // other keys only get the point
    }

    // MARK: Tracking

    @Test func boundsAndTrackedPathFollowTheBox() {
        let p = MaskPath.rectangle(Vec2(0.2, 0.2), Vec2(0.4, 0.6))
        let b = p.bounds
        #expect(close(b.center, Vec2(0.3, 0.4)) && close(b.size, Vec2(0.2, 0.4)))
        let moved = p.tracked(from: b, to: MaskTrackBox(center: Vec2(0.5, 0.5), size: Vec2(0.4, 0.4)), scale: true)
        #expect(close(moved.vertices[0].point, Vec2(0.3, 0.3)))
        #expect(close(moved.vertices[2].point, Vec2(0.7, 0.7)))
        let shifted = p.tracked(from: b, to: MaskTrackBox(center: Vec2(0.5, 0.5), size: Vec2(0.4, 0.4)), scale: false)
        #expect(close(shifted.vertices[0].point, Vec2(0.4, 0.3)))
    }

    @Test func trackTimesStepFramesToTheClipEdge() {
        let c = clip()
        let fd = Time(1, 2)
        #expect(c.maskTrackTimes(fromLocal: Time(3, 1), forward: true, frameDuration: fd) == [Time(3, 1), Time(7, 2)])
        #expect(c.maskTrackTimes(fromLocal: Time(1, 1), forward: false, frameDuration: fd) == [Time(1, 1), Time(1, 2), .zero])
        #expect(c.maskTrackTimes(fromLocal: Time(9, 1), forward: true, frameDuration: fd).isEmpty)
    }

    @Test func applyingATrackKeysEveryFrameAndReplacesKeysInTheSpan() {
        var m = ClipMask.make(.rectangle, name: "M")
        let start = MaskPath.rectangle(Vec2(0.1, 0.1), Vec2(0.3, 0.3))
        m.path = AnimatedProperty(start)
        m.path.track.insert(Keyframe(time: Time(1, 2), value: .rectangle(Vec2(0.8, 0.8), Vec2(0.9, 0.9))))   // replaced
        m.path.track.insert(Keyframe(time: Time(3, 1), value: start))                                        // kept (outside)
        var c = clip([m])
        let times = [Time.zero, Time(1, 2), Time(1, 1), Time(3, 2)]
        let b0 = MaskTrackBox(center: Vec2(0.2, 0.2), size: Vec2(0.2, 0.2))
        let boxes: [MaskTrackBox?] = [b0, MaskTrackBox(center: Vec2(0.3, 0.2), size: Vec2(0.2, 0.2)),
                                      MaskTrackBox(center: Vec2(0.4, 0.2), size: Vec2(0.2, 0.2)), nil]
        // The tracked shape is the one shown at the first time, before the old keys in the span are replaced.
        let n = c.applyMaskTrack(m.id, times: times, boxes: boxes, scale: true)
        #expect(n == 3)
        let keys = c.mask(m.id)!.path.track.keys.sorted { $0.time < $1.time }
        #expect(keys.map(\.time) == [.zero, Time(1, 2), Time(1, 1), Time(3, 1)])
        let shown0 = keys[0].value
        #expect(close(keys[1].value.vertices[0].point, shown0.vertices[0].point + Vec2(0.1, 0)))
        #expect(close(keys[2].value.vertices[0].point, shown0.vertices[0].point + Vec2(0.2, 0)))
    }

    @Test func applyingATrackWithoutResultsChangesNothing() {
        let m = ClipMask.make(.rectangle, name: "M")
        var c = clip([m])
        let before = c
        let n = c.applyMaskTrack(m.id, times: [.zero], boxes: [nil], scale: true)
        #expect(n == 0)
        #expect(c == before)
    }

    @Test func backwardTrackKeysOnlyTheTrackedSpan() {
        var m = ClipMask.make(.rectangle, name: "M")
        m.path.track.insert(Keyframe(time: Time(3, 1), value: m.path.value))
        var c = clip([m])
        let b = c.mask(m.id)!.path.value(atLocal: Time(1, 1)).bounds
        let n = c.applyMaskTrack(m.id, times: [Time(1, 1), Time(1, 2)], boxes: [b, b], scale: false)
        #expect(n == 2)
        #expect(c.mask(m.id)!.path.track.keys.map(\.time).sorted() == [Time(1, 2), Time(1, 1), Time(3, 1)])
    }
}
