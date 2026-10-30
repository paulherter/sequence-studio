import Foundation
import Testing
@testable import SQCore

/// Option-drag in the layer list: the originals stay, copies land at the drop position.
@Suite struct GraphicsDragCopyTests {
    private func rect(_ name: String) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.name = name
        return l
    }

    @Test func copyLandsAtTheDropIndexAndTheOriginalStays() {
        var d = GraphicsDocument()
        let a = d.add(rect("a")), b = d.add(rect("b")), c = d.add(rect("c"))       // bottom first
        // Index 3 of the list without the moving layer (here: all others, 2) = top.
        let copies = d.copy([a], toIndex: 2, group: nil)
        #expect(copies.count == 1)
        #expect(d.layers.map(\.id) == [a, b, c, copies[0]])
        #expect(d.layer(copies[0])?.name == "a copy")
    }

    @Test func copyToTheBottomAndBetween() {
        var d = GraphicsDocument()
        let a = d.add(rect("a")), b = d.add(rect("b")), c = d.add(rect("c"))
        let bottom = d.copy([c], toIndex: 0, group: nil)
        #expect(d.layers.map(\.id) == [bottom[0], a, b, c])
        var e = GraphicsDocument()
        let x = e.add(rect("x")), y = e.add(rect("y")), z = e.add(rect("z"))
        let mid = e.copy([z], toIndex: 1, group: nil)                              // rest = [x, y]: between them
        #expect(e.layers.map(\.id) == [x, mid[0], y, z])
    }

    @Test func copyIntoAGroupJoinsItAndOutOfAGroupLeaves() throws {
        var d = GraphicsDocument()
        let a = d.add(rect("a")), b = d.add(rect("b")), c = d.add(rect("c"))
        let gid = d.group([b, c], name: "G")
        let g = try #require(gid)
        let into = d.copy([a], toIndex: 1, group: g)                               // rest = [b, c]
        #expect(d.layer(into[0])?.group == g && d.layer(a)?.group == nil)
        #expect(d.layers.map(\.id) == [a, b, into[0], c])
        let out = d.copy([c], toIndex: 0, group: nil)
        #expect(d.layer(out[0])?.group == nil && d.layer(c)?.group == g)           // the original keeps its group
    }

    @Test func copyingAWholeGroupMakesANewGroup() throws {
        var d = GraphicsDocument()
        let a = d.add(rect("a")), b = d.add(rect("b")), c = d.add(rect("c"))
        let gid = d.group([b, c], name: "G")
        let g = try #require(gid)
        let copies = d.copy([b, c], toIndex: 0, group: g)
        #expect(copies.count == 2 && d.groups.count == 2)
        let ng = try #require(d.layer(copies[0])?.group)
        #expect(ng != g && d.layer(copies[1])?.group == ng && d.group(ng)?.name == "G copy")
        #expect(d.layers.map(\.id) == copies + [a, b, c])
        #expect(d.layer(b)?.group == g && d.layer(c)?.group == g)
    }
}
