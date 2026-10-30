import Foundation
import Testing
@testable import SQCore

/// Monitor selection: locked layers are not picked, deep select walks the stack under the pointer.
@Suite struct GraphicsMonitorPickTests {
    private func rect(_ name: String) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.name = name
        return l
    }
    private let t = Time(0, 30)
    private let p = Vec2(0, 0)

    @Test func aLockedLayerIsNotPickedAndTheOneBelowIs() {
        var d = GraphicsDocument()
        let a = d.add(rect("a")), b = d.add(rect("b"))
        #expect(d.hitTest(p, atLocal: t) == b)
        d.layers[d.index(of: b)!].isLocked = true
        #expect(d.hitTest(p, atLocal: t) == a)
        #expect(d.hitStack(p, atLocal: t) == [a])
    }

    @Test func deepSelectWalksDownAndWraps() {
        var d = GraphicsDocument()
        let a = d.add(rect("a")), b = d.add(rect("b")), c = d.add(rect("c"))
        #expect(d.hitStack(p, atLocal: t) == [c, b, a])
        #expect(d.hitBelow(nil, at: p, atLocal: t) == c)
        #expect(d.hitBelow(c, at: p, atLocal: t) == b)
        #expect(d.hitBelow(a, at: p, atLocal: t) == c)
        #expect(d.hitBelow(UUID(), at: p, atLocal: t) == c)
        #expect(d.hitBelow(nil, at: Vec2(99999, 0), atLocal: t) == nil)
    }

    @Test func neighborSkipsHiddenAndLockedLayers() {
        var d = GraphicsDocument()
        let a = d.add(rect("a")), b = d.add(rect("b")), c = d.add(rect("c"))
        #expect(d.neighbor(of: a, up: true) == b)
        d.layers[d.index(of: b)!].isLocked = true
        #expect(d.neighbor(of: a, up: true) == c)
        #expect(d.neighbor(of: c, up: true) == nil)
        #expect(d.neighbor(of: c, up: false) == a)
        #expect(d.neighbor(of: a, up: false) == nil)
    }
}

@Suite struct GraphicsLayerStepTests {
    @Test func stepsFromTheSelectionEdgeOrStartsAtTheEnd() {
        var d = GraphicsDocument()
        func make() -> GraphicsLayer { GraphicsLayer.shape(.rectangle, canvasWidth: 100, canvasHeight: 100) }
        let a = d.add(make()), b = d.add(make()), c = d.add(make())
        #expect(d.stepTarget(from: [], up: true) == c)
        #expect(d.stepTarget(from: [], up: false) == a)
        #expect(d.stepTarget(from: [b], up: true) == c)
        #expect(d.stepTarget(from: [a, b], up: true) == c)
        #expect(d.stepTarget(from: [a, b], up: false) == nil)
        #expect(d.stepTarget(from: [c], up: true) == nil)
    }
}

@Suite struct GraphicsMarqueeTests {
    @Test func marqueeTakesTouchedUnlockedLayersOnly() {
        var d = GraphicsDocument()
        func make() -> GraphicsLayer { GraphicsLayer.shape(.rectangle, canvasWidth: 100, canvasHeight: 100) }
        let a = d.add(make()), b = d.add(make())
        let t = Time(0, 30)
        let near = GraphicsRect(minX: -1, minY: -1, maxX: 1, maxY: 1)
        #expect(d.layers(touching: near, atLocal: t) == [a, b])
        d.layers[d.index(of: b)!].isLocked = true
        #expect(d.layers(touching: near, atLocal: t) == [a])
        #expect(d.layers(touching: GraphicsRect(minX: 9000, minY: 9000, maxX: 9100, maxY: 9100), atLocal: t).isEmpty)
    }
}
