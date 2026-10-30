import Foundation
import Testing
@testable import SQCore

/// GFX: corner handles of the Program monitor (resize keeps the opposite corner where it is).
@Suite struct GraphicsResizeTests {
    private func rect(_ w: Double, _ h: Double, at pos: Vec2) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.setShapeSize(width: w, height: h)
        l.animation.position = AnimatedProperty(pos)
        return l
    }

    private func near(_ a: Vec2, _ b: Vec2, _ eps: Double = 1e-6) -> Bool { abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }

    @Test func cornersFollowMotion() throws {
        let l = rect(200, 100, at: Vec2(10, 20))
        let c = try #require(l.corners(atLocal: .zero))
        #expect(near(c[0], Vec2(-90, -30)) && near(c[1], Vec2(110, -30)) && near(c[2], Vec2(110, 70)) && near(c[3], Vec2(-90, 70)))
    }

    @Test func resizeKeepsOppositeCorner() throws {
        var d = GraphicsDocument()
        let id = d.add(rect(200, 100, at: .zero))
        d.resize(id, corner: .bottomRight, to: Vec2(150, 100), atLocal: .zero)
        let l = try #require(d.layer(id))
        let st = try #require(l.shapeStyle(atLocal: .zero))
        #expect(st.width == 250 && st.height == 150)
        #expect(l.animation.position.value == Vec2(25, 25))
        #expect(d.bounds(of: id, atLocal: .zero) == GraphicsRect(minX: -100, minY: -50, maxX: 150, maxY: 100))
    }

    @Test func resizeUnderRotationScaleAndAnchor() throws {
        var d = GraphicsDocument()
        var l = rect(200, 100, at: Vec2(30, -40))
        l.animation.rotation = AnimatedProperty(30)
        l.animation.scale = AnimatedProperty(Vec2(2, 1.5))
        l.animation.anchor = AnimatedProperty(Vec2(10, 5))
        let id = d.add(l)
        let before = try #require(d.layer(id)?.corners(atLocal: .zero))
        let target = before[2] + Vec2(40, 25)
        d.resize(id, corner: .bottomRight, to: target, atLocal: .zero)
        let after = try #require(d.layer(id)?.corners(atLocal: .zero))
        #expect(near(after[0], before[0], 1e-6))
        #expect(near(after[2], target, 1e-6))
    }

    @Test func topLeftCornerAndMinimumSize() throws {
        var d = GraphicsDocument()
        let id = d.add(rect(200, 100, at: .zero))
        // Dragged past the opposite corner: clamped at 1 px, the bottom-right corner stays.
        d.resize(id, corner: .topLeft, to: Vec2(500, 500), atLocal: .zero)
        let c = try #require(d.layer(id)?.corners(atLocal: .zero))
        #expect(near(c[2], Vec2(100, 50)))
        #expect(d.layer(id)?.shapeStyle(atLocal: .zero)?.width == 1)
    }

    @Test func keepAspectScalesBothSides() throws {
        var d = GraphicsDocument()
        let id = d.add(rect(200, 100, at: .zero))
        d.resize(id, corner: .bottomRight, to: Vec2(300, 60), atLocal: .zero, keepAspect: true)
        let st = try #require(d.layer(id)?.shapeStyle(atLocal: .zero))
        #expect(abs(st.width / st.height - 2) < 1e-9)
        let c = try #require(d.layer(id)?.corners(atLocal: .zero))
        #expect(near(c[0], Vec2(-100, -50)))
    }

    @Test func lineResizesLengthOnly() throws {
        var d = GraphicsDocument()
        var l = GraphicsLayer.shape(.line, canvasWidth: 1920, canvasHeight: 1080)
        l.setShapeSize(width: 400, height: 0)
        let id = d.add(l)
        let h0 = try #require(d.layer(id)?.shapeStyle(atLocal: .zero)?.height)
        d.resize(id, corner: .bottomRight, to: Vec2(300, 400), atLocal: .zero)
        let st = try #require(d.layer(id)?.shapeStyle(atLocal: .zero))
        #expect(st.width == 500 && st.height == h0)
    }

    @Test func textScalesUniformly() throws {
        var d = GraphicsDocument()
        let id = d.add(GraphicsLayer.text(GeneratorRef(kind: GeneratorRef.text, payload: Data([1])), name: "T"))
        let measure: GraphicsTextMeasure = { _, _ in GraphicsRect(minX: -40, minY: -20, maxX: 60, maxY: 20) }
        let before = try #require(d.layer(id)?.corners(atLocal: .zero, text: measure))
        // Twice the diagonal from the fixed top-left corner.
        d.resize(id, corner: .bottomRight, to: before[0] + (before[2] - before[0]) * 2, atLocal: .zero, text: measure)
        let l = try #require(d.layer(id))
        #expect(near(l.animation.scale.value, Vec2(2, 2)))
        let after = try #require(l.corners(atLocal: .zero, text: measure))
        #expect(near(after[0], before[0]))
    }

    @Test func keyedPropertiesGetKeysAndLockedLayersStay() throws {
        var d = GraphicsDocument()
        var l = rect(200, 100, at: .zero)
        l.animation.position.toggleKeyframing(atLocal: .zero)
        let id = d.add(l)
        d.resize(id, corner: .bottomRight, to: Vec2(150, 100), atLocal: Time(1, 1))
        let pos = try #require(d.layer(id)?.animation.position)
        #expect(pos.track.keys.count == 2)
        #expect(pos.value(atLocal: Time(1, 1)) == Vec2(25, 25))

        var locked = rect(200, 100, at: .zero)
        locked.isLocked = true
        let lid = d.add(locked)
        d.resize(lid, corner: .bottomRight, to: Vec2(150, 100), atLocal: .zero)
        #expect(d.layer(lid)?.shapeStyle(atLocal: .zero)?.width == 200)
    }
}
