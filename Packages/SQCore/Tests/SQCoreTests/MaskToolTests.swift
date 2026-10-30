import Foundation
import Testing
@testable import SQCore

// The Mask tool's clicks on the Program monitor: Magic picks, Pen points, shapes placed where clicked.

@Suite struct MaskToolTests {
    private func clip() -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(5, 1)), start: .zero)
    }

    @Test func magicClickStartsAMaskThenAddsAndSubtracts() throws {
        var c = clip()
        let t = Time(3, 1)
        let id0 = c.magicClick(nil, at: Vec2(0.3, 0.4), subtract: false, sourceTime: t)
        let id = try #require(id0)
        #expect(c.masks.count == 1 && c.masks[0].source == .magic && c.masks[0].name == "Mask (1)")
        let a = c.magicClick(id, at: Vec2(0.6, 0.4), subtract: false, sourceTime: t)
        let b = c.magicClick(id, at: Vec2(0.6, 0.5), subtract: true, sourceTime: t)
        #expect(a == id && b == id)
        let pts = try #require(c.mask(id)?.magic?.points)
        #expect(pts.map(\.subtract) == [false, false, true])
        // The cache key follows the pick: a changed pick never reads the old mattes.
        #expect(c.masks.count == 1)
    }

    /// A click on another frame corrects the pick there (Track applies it from that frame on); the pick's frame stays.
    @Test func magicClickOnAnotherFrameAddsACorrection() throws {
        var c = clip()
        let id0 = c.magicClick(nil, at: Vec2(0.3, 0.4), subtract: false, sourceTime: Time(3, 1))
        let id = try #require(id0)
        let before = c.mask(id)!.magic!.cacheKey(media: c.media)
        _ = c.magicClick(id, at: Vec2(0.5, 0.5), subtract: false, sourceTime: Time(4, 1))
        _ = c.magicClick(id, at: Vec2(0.6, 0.5), subtract: true, sourceTime: Time(4, 1))
        let pts = try #require(c.mask(id)?.magic?.points)
        #expect(pts.map(\.sourceTime) == [Time(3, 1), Time(4, 1), Time(4, 1)])
        #expect(pts.map(\.subtract) == [false, false, true])
        #expect(c.mask(id)?.magic?.anchorTime == Time(3, 1))
        #expect(c.mask(id)!.magic!.cacheKey(media: c.media) != before)
    }

    @Test func subtractWithoutAPickDoesNothing() {
        var c = clip()
        let r = c.magicClick(nil, at: Vec2(0.3, 0.4), subtract: true, sourceTime: Time(3, 1))
        #expect(r == nil)
        #expect(c.masks.isEmpty)
    }

    @Test func penClicksBuildAPath() throws {
        var c = clip()
        let id = c.penClick(nil, at: Vec2(0.2, 0.2), atLocal: .zero)
        #expect(c.mask(id)?.path.value.vertices.count == 1)
        _ = c.penClick(id, at: Vec2(0.8, 0.2), atLocal: .zero)
        _ = c.penClick(id, at: Vec2(0.5, 0.8), atLocal: .zero)
        let v = try #require(c.mask(id)?.path.value.vertices)
        #expect(v.map(\.point) == [Vec2(0.2, 0.2), Vec2(0.8, 0.2), Vec2(0.5, 0.8)])
        #expect(c.mask(id)?.kind == .bezier && c.mask(id)?.source == .path)
    }

    @Test func shapeIsPlacedAroundTheClick() throws {
        var c = clip()
        let id = c.addShapeMask(.ellipse, at: Vec2(0.25, 0.75))
        let m = try #require(c.mask(id))
        let poly = m.path.value.polygon()
        let cx = poly.map(\.x).reduce(0, +) / Double(poly.count), cy = poly.map(\.y).reduce(0, +) / Double(poly.count)
        #expect(abs(cx - 0.25) < 0.01 && abs(cy - 0.75) < 0.01)
        #expect(m.kind == .ellipse && m.feather.value == ClipMask.defaultFeather)
    }
}
