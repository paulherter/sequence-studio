import Foundation
import Testing
@testable import SQCore

/// W6.7 MasksV1: clip masks (Opacity masks), keyframable path / feather / opacity / expansion, invert, modes.
@Suite struct MasksTests {
    func clip(_ masks: [ClipMask] = []) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: Time(10, 1))
        c.masks = masks
        return c
    }

    // MARK: Shapes and flattening

    @Test func rectangleFlattensToItsFourCorners() {
        let p = MaskPath.rectangle(Vec2(0.25, 0.25), Vec2(0.75, 0.5))
        #expect(p.vertices.count == 4)
        let want: [Vec2] = [Vec2(0.25, 0.25), Vec2(0.75, 0.25), Vec2(0.75, 0.5), Vec2(0.25, 0.5)]
        let got = p.polygon()
        #expect(got == want)
    }

    @Test func ellipseFlattensCloseToTheTrueEllipse() {
        let p = MaskPath.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.2, 0.1))
        #expect(p.vertices.count == 4)
        let poly = p.polygon()
        #expect(poly.count == 4 * MaskPath.curveSubdivisions)
        for v in poly {
            let e = ((v.x - 0.5) / 0.2) * ((v.x - 0.5) / 0.2) + ((v.y - 0.5) / 0.1) * ((v.y - 0.5) / 0.1)
            #expect(abs(e - 1) < 0.003)          // a 4-point bezier circle is within 0.03 % of the radius
        }
    }

    @Test func polygonOfAnEmptyPathIsEmpty() {
        #expect(MaskPath(vertices: []).polygon().isEmpty)
    }

    // MARK: Keyframes

    @Test func pathKeysInterpolateVertexByVertex() {
        var m = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(0.5, 0.5)))
        m.path.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: MaskPath.rectangle(Vec2(0, 0), Vec2(0.5, 0.5))),
                                            Keyframe(time: Time(2, 1), value: MaskPath.rectangle(Vec2(0.5, 0.5), Vec2(1, 1)))])
        let mid = m.path.value(atLocal: Time(1, 1))
        let want: [Vec2] = [Vec2(0.25, 0.25), Vec2(0.75, 0.25), Vec2(0.75, 0.75), Vec2(0.25, 0.75)]
        let got = mid.vertices.map(\.point)
        #expect(got == want)
    }

    @Test func pathsWithDifferentVertexCountsHoldUntilTheNextKey() {
        let a = MaskPath.rectangle(Vec2(0, 0), Vec2(0.5, 0.5))
        let b = MaskPath.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.1, 0.1))
        var three = b; three.vertices.removeLast()
        #expect(MaskPath.lerp(a, three, 0.5) == a)
        #expect(MaskPath.lerp(a, three, 1) == three)
    }

    @Test func featherOpacityAndExpansionAreKeyframable() {
        var m = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.feather.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0), Keyframe(time: Time(2, 1), value: 40)])
        m.opacity.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 100), Keyframe(time: Time(2, 1), value: 0)])
        m.expansion.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: -10), Keyframe(time: Time(2, 1), value: 10)])
        let s = m.shape(atLocal: Time(1, 1))
        #expect(s.feather == 20)
        #expect(s.opacity == 0.5)
        #expect(s.expansion == 0)
    }

    @Test func evaluatedValuesAreClamped() {
        var m = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.feather = AnimatedProperty(-5); m.opacity = AnimatedProperty(140)
        let s = m.shape(atLocal: .zero)
        #expect(s.feather == 0)
        #expect(s.opacity == 1)
    }

    // MARK: Clip evaluation

    @Test func clipEffectsCarryTheEnabledMasksInOrder() {
        var off = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(0.2, 0.2))); off.enabled = false
        let a = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(0.5, 0.5)))
        var b = ClipMask(path: .ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.1, 0.1))); b.mode = .subtract
        let fx = clip([a, off, b]).effects(at: Time(11, 1))
        #expect(fx.masks.count == 2)
        #expect(fx.masks.map(\.mode) == [.add, .subtract])
        #expect(!fx.isIdentity)
    }

    @Test func noMasksKeepsThePlainPath() {
        #expect(clip().effects(at: Time(11, 1)) == .none)
    }

    @Test func opacityToggleOffSwitchesMasksOff() {
        var c = clip([ClipMask(path: .rectangle(Vec2(0, 0), Vec2(0.5, 0.5)))])
        c.opacityEnabled = false
        #expect(c.effects(at: Time(11, 1)).masks.isEmpty)
    }

    @Test func maskKeysAreClipLocal() {
        var m = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.opacity.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0), Keyframe(time: Time(2, 1), value: 100)])
        let c = clip([m])
        #expect(c.effects(at: Time(11, 1)).masks.first?.opacity == 0.5)      // local 1 s
    }

    // MARK: Coverage (CPU reference of the compositor)

    func shape(_ p: MaskPath, feather: Double = 0, expansion: Double = 0, opacity: Double = 1, inverted: Bool = false,
               mode: MaskMode = .add) -> MaskShape {
        MaskShape(polygon: p.polygon(), feather: feather, expansion: expansion, opacity: opacity, inverted: inverted, mode: mode)
    }
    let frame = Vec2(100, 100)
    func cov(_ masks: [MaskShape], _ x: Double, _ y: Double) -> Double {
        MaskCoverage.coverage(at: Vec2(x, y), masks: masks, frame: frame, pixel: 1)
    }

    @Test func hardEdgeCoverageIsOneInsideZeroOutsideHalfOnTheEdge() {
        let m = [shape(.rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))]
        #expect(cov(m, 50, 50) == 1)
        #expect(cov(m, 5, 5) == 0)
        #expect(abs(cov(m, 20, 50) - 0.5) < 1e-9)
    }

    @Test func featherRampsAcrossTheEdgeCentredOnIt() {
        let m = [shape(.rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)), feather: 20)]
        #expect(abs(cov(m, 20, 50) - 0.5) < 1e-9)
        #expect(cov(m, 31, 50) == 1)           // 10 px inside: fully kept
        #expect(cov(m, 9, 50) == 0)            // 10 px outside: gone
        let a = cov(m, 25, 50), b = cov(m, 15, 50)
        #expect(a > 0.5 && a < 1 && b > 0 && b < 0.5)
        #expect(abs(a + b - 1) < 1e-9)         // symmetric ramp
    }

    @Test func expansionGrowsAndShrinksTheShape() {
        let r = MaskPath.rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8))
        let grown = shape(r, expansion: 10), shrunk = shape(r, expansion: -10)
        let a = cov([grown], 12, 50), b = cov([shrunk], 28, 50)
        #expect(a == 1)
        #expect(b == 0)
    }

    @Test func invertAndOpacity() {
        let r = MaskPath.rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8))
        let inv = shape(r, inverted: true), quarter = shape(r, opacity: 0.25)
        let a = cov([inv], 50, 50), b = cov([inv], 5, 5), c = cov([quarter], 50, 50)
        #expect(a == 0)
        #expect(b == 1)
        #expect(c == 0.25)
    }

    @Test func modesCombineInOrder() {
        let big = MaskPath.rectangle(Vec2(0.1, 0.1), Vec2(0.9, 0.9))
        let small = MaskPath.rectangle(Vec2(0.4, 0.4), Vec2(0.6, 0.6))
        let left = MaskPath.rectangle(Vec2(0.0, 0.0), Vec2(0.5, 1.0))
        // Add = union, Subtract cuts a hole, Intersect keeps the overlap, Difference keeps one or the other.
        let sBig = shape(big), sSmall = shape(small), sLeft = shape(left)
        let subSmall = shape(small, mode: .subtract), interLeft = shape(left, mode: .intersect)
        let diffLeft = shape(left, mode: .difference)
        let union = cov([sSmall, sLeft], 25, 50)
        let hole = cov([sBig, subSmall], 50, 50), ring = cov([sBig, subSmall], 20, 50)
        let iOut = cov([sBig, interLeft], 75, 50), iIn = cov([sBig, interLeft], 25, 50)
        let dBoth = cov([sBig, diffLeft], 25, 50), dOne = cov([sBig, diffLeft], 75, 50)
        let firstSubOut = cov([subSmall], 20, 50), firstSubIn = cov([subSmall], 50, 50)
        #expect(union == 1)
        #expect(hole == 0)
        #expect(ring == 1)
        #expect(iOut == 0)
        #expect(iIn == 1)
        #expect(dBoth == 0)
        #expect(dOne == 1)
        // A first Subtract mask starts from the whole frame (Premiere).
        #expect(firstSubOut == 1)
        #expect(firstSubIn == 0)
    }

    @Test func firstIntersectStartsFromTheFullFrameAndFirstDifferenceActsLikeAdd() {
        // After Effects: a first Intersect (like Subtract) works on the whole frame, so it shows its own area; a first
        // Difference starts from nothing, so it shows its own area too (same as Add).
        let small = MaskPath.rectangle(Vec2(0.4, 0.4), Vec2(0.6, 0.6))
        let inter = shape(small, mode: .intersect), diff = shape(small, mode: .difference)
        let iIn = cov([inter], 50, 50), iOut = cov([inter], 20, 50)
        let dIn = cov([diff], 50, 50), dOut = cov([diff], 20, 50)
        #expect(iIn == 1)
        #expect(iOut == 0)
        #expect(dIn == 1)
        #expect(dOut == 0)
        // A half-opacity first Intersect keeps half of the inside, nothing outside.
        let half = cov([shape(small, opacity: 0.5, mode: .intersect)], 50, 50)
        #expect(half == 0.5)
    }

    @Test func animatedPathWithAnEmptyStaticValueStillRenders() {
        var m = ClipMask(path: MaskPath(vertices: []))
        m.path.track.insert(Keyframe(time: .zero, value: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8))))
        let c = clip([m])
        #expect(c.maskShapes(atLocal: Time(1, 1)).count == 1)
        // And the other way round: a path that has fewer than two points at t is skipped.
        var e = ClipMask(path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))
        e.path.track.insert(Keyframe(time: .zero, value: MaskPath(vertices: [])))
        #expect(clip([e]).maskShapes(atLocal: Time(1, 1)).isEmpty)
    }

    // MARK: Paste Attributes

    @Test func pasteAttributesCarriesMasksWithOpacity() {
        var m = ClipMask(path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))
        m.feather.track.insert(Keyframe(time: Time(1, 1), value: 20))
        let src = clip([m])
        var dst = Clip(name: "d", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: Time(30, 1))
        dst.masks = [ClipMask(path: .ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.1, 0.1)))]
        let out = dst.pastingAttributes(from: src)
        #expect(out.masks.count == 1)
        #expect(out.masks[0].path.value == m.path.value)
        #expect(out.masks[0].id != m.id)                                         // a copy, not the same mask
        #expect(out.masks[0].feather.track.keys.map(\.time) == [Time(1, 1)])    // clip-local, like opacity keys
        // Pasting a clip without masks clears them, like Opacity replaces.
        #expect(out.pastingAttributes(from: clip()).masks.isEmpty)
    }

    @Test func coverageWorksInFramePixelsForNonSquareFrames() {
        let m = [shape(.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.5, 0.5)))]
        let wide = Vec2(200, 100)
        let a = MaskCoverage.coverage(at: Vec2(190, 50), masks: m, frame: wide, pixel: 1)
        let b = MaskCoverage.coverage(at: Vec2(100, 3), masks: m, frame: wide, pixel: 1)
        let c = MaskCoverage.coverage(at: Vec2(195, 5), masks: m, frame: wide, pixel: 1)
        #expect(a == 1)
        #expect(b == 1)
        #expect(c == 0)
    }

    // MARK: Edits keep keys on the same frames

    @Test func trimHeadShiftsMaskKeys() {
        var m = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.opacity.track = KeyframeTrack(keys: [Keyframe(time: Time(2, 1), value: 50)])
        var c = clip([m])
        c.extendHead(by: Time(-1, 1))
        #expect(c.masks[0].opacity.track.keys.first?.time == Time(1, 1))
        let cut = clip([m]).cropped(to: TimeRange(start: Time(11, 1), duration: Time(2, 1)))
        #expect(cut?.masks[0].opacity.track.keys.first?.time == Time(1, 1))
    }

    @Test func retimeRescalesMaskKeys() {
        var m = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.path.track = KeyframeTrack(keys: [Keyframe(time: Time(2, 1), value: MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1)))])
        var c = clip([m])
        c.rescaleKeys(from: Time(4, 1), to: Time(8, 1), mirror: false)
        #expect(c.masks[0].path.track.keys.first?.time == Time(4, 1))
    }

    @Test func insertedFrameHoldFreezesMasks() {
        var m = ClipMask(path: .rectangle(Vec2(0, 0), Vec2(1, 1)))
        m.feather.track = KeyframeTrack(keys: [Keyframe(time: .zero, value: 0), Keyframe(time: Time(2, 1), value: 20)])
        let h = clip([m]).holding(frame: Time(1, 1), at: Time(11, 1), start: Time(20, 1), duration: Time(1, 1), keepsAnimation: false)
        #expect(h.masks[0].feather.isAnimated == false)
        #expect(h.masks[0].feather.value == 10)
    }

    // MARK: Editing helpers

    @Test func setPathAtWritesAKeyOnlyWhenAnimated() {
        var c = clip([ClipMask(path: .rectangle(Vec2(0, 0), Vec2(0.5, 0.5)))])
        let id = c.masks[0].id
        let moved = MaskPath.rectangle(Vec2(0.1, 0.1), Vec2(0.6, 0.6))
        c.setMaskPath(id, moved, atLocal: Time(1, 1))
        let v1: MaskPath = c.masks[0].path.value
        #expect(v1 == moved)
        #expect(!c.masks[0].path.isAnimated)
        c.setMaskPathAnimated(id, true, atLocal: Time(1, 1))
        let t1: [Time] = c.masks[0].path.track.keys.map(\.time)
        #expect(t1 == [Time(1, 1)])
        let again = MaskPath.rectangle(Vec2(0.2, 0.2), Vec2(0.7, 0.7))
        c.setMaskPath(id, again, atLocal: Time(3, 1))
        let t2: [Time] = c.masks[0].path.track.keys.map(\.time)
        #expect(t2 == [Time(1, 1), Time(3, 1)])
        let v2: MaskPath = c.masks[0].path.value(atLocal: Time(3, 1))
        #expect(v2 == again)
        c.setMaskPathAnimated(id, false, atLocal: Time(3, 1))
        let v3: MaskPath = c.masks[0].path.value
        #expect(!c.masks[0].path.isAnimated)
        #expect(v3 == again)
    }

    @Test func toggleMaskPathKeyAddsThenRemovesAKeyAtTheTime() {
        var c = clip([ClipMask(path: .rectangle(Vec2(0, 0), Vec2(0.5, 0.5)))])
        let id = c.masks[0].id
        c.toggleMaskPathKey(id, atLocal: Time(1, 1))           // not animated: nothing to toggle
        #expect(!c.masks[0].path.isAnimated)
        c.setMaskPathAnimated(id, true, atLocal: Time(1, 1))
        c.setMaskPath(id, .rectangle(Vec2(0.2, 0.2), Vec2(0.7, 0.7)), atLocal: Time(3, 1))
        let shownAt2: MaskPath = c.masks[0].path.value(atLocal: Time(2, 1))
        c.toggleMaskPathKey(id, atLocal: Time(2, 1))           // adds a key with the shape shown there
        let times: [Time] = c.masks[0].path.track.keys.map(\.time)
        #expect(times == [Time(1, 1), Time(2, 1), Time(3, 1)])
        let v: MaskPath = c.masks[0].path.value(atLocal: Time(2, 1))
        #expect(v == shownAt2)
        c.toggleMaskPathKey(id, atLocal: Time(2, 1))           // removes it again
        let back: [Time] = c.masks[0].path.track.keys.map(\.time)
        #expect(back == [Time(1, 1), Time(3, 1)])
        c.toggleMaskPathKey(id, atLocal: Time(1, 1))
        c.toggleMaskPathKey(id, atLocal: Time(3, 1))           // last key: the shape there stays as the static value
        let last: MaskPath = c.masks[0].path.value
        #expect(!c.masks[0].path.isAnimated)
        #expect(last == .rectangle(Vec2(0.2, 0.2), Vec2(0.7, 0.7)))
    }

    @Test func movingAVertexMovesItsTangentsWithIt() {
        var p = MaskPath.ellipse(center: Vec2(0.5, 0.5), radius: Vec2(0.2, 0.2))
        let before = p.vertices[1]
        let target = Vec2(before.point.x + 0.1, before.point.y)
        p.moveVertex(1, to: target)
        let after = p.vertices[1]
        #expect(after.point == target)
        #expect(after.inTangent == before.inTangent)
        #expect(after.outTangent == before.outTangent)
    }

    @Test func nearestVertexHitTestInFramePixels() {
        let p = MaskPath.rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8))
        #expect(p.vertexIndex(near: Vec2(21, 19), frame: Vec2(100, 100), radius: 4) == 0)
        #expect(p.vertexIndex(near: Vec2(50, 50), frame: Vec2(100, 100), radius: 4) == nil)
    }

    // MARK: File

    @Test func masksRoundTripThroughTheProjectFile() throws {
        var m = ClipMask(name: "Mask 1", path: .ellipse(center: Vec2(0.5, 0.4), radius: Vec2(0.2, 0.3)))
        m.mode = .intersect; m.inverted = true; m.feather = AnimatedProperty(12); m.expansion = AnimatedProperty(-3)
        m.path.track = KeyframeTrack(keys: [Keyframe(time: Time(1, 2), value: MaskPath.rectangle(Vec2(0, 0), Vec2(1, 1)))])
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip([m])])])
        let data = try ProjectFile.encode(Project(name: "P", timelines: [tl]))
        let back = try ProjectFile.decode(data, migrations: ProjectFile.migrations)
        let got: [ClipMask] = back.timelines[0].tracks[0].clips[0].masks
        #expect(got == [m])
    }

    @Test func aClipWithoutMasksWritesNoMasksKey() throws {
        let data = try JSONEncoder().encode(clip())
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["masks"] == nil)
    }

    @Test func v32IsCurrentAndV31ToV32IsIdentity() throws {
        #expect(ProjectFile.currentVersion >= 32)
        #expect(ProjectFile.realMigrations[31] == nil)
        let obj: ProjectFile.JSONObject = ["formatVersion": 31, "project": ["name": "P"] as ProjectFile.JSONObject]
        let step = try #require(ProjectFile.migrations[31])
        let out = try step(obj)
        #expect(jsonEqual(out, obj))
    }

    @Test func aV31FileOpensWithoutMasks() throws {
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip()])])
        let data = try ProjectFile.encode(Project(name: "P", timelines: [tl]))
        var obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["formatVersion"] = 31
        let back = try ProjectFile.decode(try JSONSerialization.data(withJSONObject: obj), migrations: ProjectFile.migrations)
        #expect(back.timelines[0].tracks[0].clips[0].masks.isEmpty)
    }
}
