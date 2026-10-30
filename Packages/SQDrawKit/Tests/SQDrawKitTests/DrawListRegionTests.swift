import Testing
@testable import SQDrawKit

@Suite struct DrawListRegionTests {
    @Test func extendedCanvasKeepsQuadsRightOfTheOldEdge() {
        var l = DrawList(width: 100, height: 50)
        l.extendCanvas(width: 300, height: 80)
        l.fill(DrawRect(x: 150, y: 10, w: 40, h: 20), .white)
        #expect(l.width == 300 && l.height == 80)
        #expect(l.quads.count == 1)
        #expect(l.quads[0].clipX1 == 300)
    }

    @Test func regionMovesQuadsToItsOriginAndDropsOutsiders() {
        var l = DrawList(width: 100, height: 50)
        l.extendCanvas(width: 300, height: 80)
        l.fill(DrawRect(x: 10, y: 5, w: 20, h: 10), .white)           // main window
        l.fill(DrawRect(x: 150, y: 10, w: 40, h: 20), .white)         // floating window at x 120
        let r = l.region(DrawRect(x: 120, y: 0, w: 100, h: 60))
        #expect(r.width == 100 && r.height == 60)
        #expect(r.quads.count == 1)
        #expect(r.quads[0].x == 30 && r.quads[0].y == 10)
        #expect(r.quads[0].clipX0 == 0 && r.quads[0].clipX1 == 100)
    }

    @Test func regionCutsClipsAndMovesSegmentEnds() {
        var l = DrawList(width: 100, height: 50)
        l.extendCanvas(width: 300, height: 80)
        l.pushClip(DrawRect(x: 130, y: 0, w: 50, h: 40))
        l.fill(DrawRect(x: 100, y: 0, w: 200, h: 40), .white)
        l.segment(140, 10, 170, 20, width: 2, .white)
        let r = l.region(DrawRect(x: 120, y: 0, w: 100, h: 60))
        #expect(r.quads.count == 2)
        #expect(r.quads[0].clipX0 == 10 && r.quads[0].clipX1 == 60)
        #expect(r.quads[1].u0 == 20 && r.quads[1].u1 == 50 && r.quads[1].v0 == 10)
    }
}
