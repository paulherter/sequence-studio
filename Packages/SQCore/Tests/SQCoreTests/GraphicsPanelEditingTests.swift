import Foundation
import Testing
@testable import SQCore

/// Graphics panel edits on the document: drag reorder into / out of groups, group names, align to the frame for several.
@Suite struct GraphicsPanelEditingTests {
    private func rect(_ w: Double, _ h: Double, at pos: Vec2) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.setShapeSize(width: w, height: h)
        l.animation.position = AnimatedProperty(pos)
        return l
    }

    @Test func dragIntoAGroupJoinsIt() throws {
        var d = GraphicsDocument()
        let a = d.add(rect(10, 10, at: .zero)), b = d.add(rect(10, 10, at: .zero)), c = d.add(rect(10, 10, at: .zero))
        let gid = d.group([b, c], name: "Group")
        let g = try #require(gid)
        d.move([a], toIndex: 1, group: g)                    // between b and c
        #expect(d.layers.map(\.id) == [b, a, c])
        #expect(d.layers.allSatisfy { $0.group == g })
    }

    @Test func dragOutOfAGroupLeavesItAndASingleMemberDissolvesIt() throws {
        var d = GraphicsDocument()
        let a = d.add(rect(10, 10, at: .zero)), b = d.add(rect(10, 10, at: .zero)), c = d.add(rect(10, 10, at: .zero))
        let gid = d.group([b, c], name: "Group")
        let g = try #require(gid)
        d.move([c], toIndex: 0, group: nil)
        #expect(d.layers.map(\.id) == [c, a, b])
        #expect(d.layer(c)?.group == nil)
        #expect(d.layer(b)?.group == nil)                    // one member left: the group is gone
        #expect(d.group(g) == nil)
    }

    @Test func moveIntoAnUnknownGroupMeansNoGroup() {
        var d = GraphicsDocument()
        let a = d.add(rect(10, 10, at: .zero)), b = d.add(rect(10, 10, at: .zero))
        d.move([a], toIndex: 1, group: UUID())
        #expect(d.layers.map(\.id) == [b, a])
        #expect(d.layer(a)?.group == nil)
    }

    @Test func severalLayersAlignToTheFrameEachOnItsOwn() throws {
        var d = GraphicsDocument()
        let a = d.add(rect(10, 10, at: .zero)), b = d.add(rect(20, 20, at: Vec2(100, 50)))
        let canvas = Vec2(1920, 1080)
        d.align([a, b], .left, canvas: canvas)                         // to the selection: the leftmost edge
        #expect(try #require(d.bounds(of: a, atLocal: .zero)).minX == -5)
        #expect(try #require(d.bounds(of: b, atLocal: .zero)).minX == -5)
        d.align([a, b], .left, canvas: canvas, toFrame: true)          // each to the frame's left edge
        #expect(try #require(d.bounds(of: a, atLocal: .zero)).minX == -960)
        #expect(try #require(d.bounds(of: b, atLocal: .zero)).minX == -960)
        d.align([a, b], .bottom, canvas: canvas, toFrame: true)
        #expect(try #require(d.bounds(of: a, atLocal: .zero)).maxY == 540)
        #expect(try #require(d.bounds(of: b, atLocal: .zero)).maxY == 540)
        d.align([a, b], .top, canvas: canvas)                          // the selection's top: b's top (520)
        #expect(try #require(d.bounds(of: a, atLocal: .zero)).minY == 520)
        #expect(try #require(d.bounds(of: b, atLocal: .zero)).minY == 520)
    }

    @Test func renameGroupTrimsAndRefusesEmpty() throws {
        var d = GraphicsDocument()
        let a = d.add(rect(10, 10, at: .zero)), b = d.add(rect(10, 10, at: .zero))
        let gid = d.group([a, b], name: "Group")
        let g = try #require(gid)
        d.renameGroup(g, "  Lower third ")
        #expect(d.group(g)?.name == "Lower third")
        d.renameGroup(g, "   ")
        #expect(d.group(g)?.name == "Lower third")
    }
}
