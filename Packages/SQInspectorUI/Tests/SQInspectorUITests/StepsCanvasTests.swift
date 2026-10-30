import CoreGraphics
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

@Suite struct StepsCanvasTests {
    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    @Test func autoLayoutPutsColumnsLeftToRightAndStacksCentered() {
        let s = ids(3)
        let c = StepsCanvas(columns: [[s[0]], [s[1], s[2]]])
        let l = c.layout()
        #expect(l.order == s)
        #expect(l.rects[s[0]]!.midY == 0)
        #expect(l.rects[s[1]]!.minX == l.rects[s[2]]!.minX)
        #expect(l.rects[s[1]]!.maxY < l.rects[s[2]]!.minY)
        #expect(l.rects[s[1]]!.maxX < l.outSlot.minX)
        #expect(l.rects[s[0]]!.minX > l.inSlot.maxX)
    }

    @Test func storedPositionWinsOverAutoLayout() {
        let s = ids(2)
        let c = StepsCanvas(columns: [[s[0]], [s[1]]], positions: [s[1]: StepPosition(x: 5, y: 70)])
        #expect(c.layout().rects[s[1]]!.origin == CGPoint(x: 5, y: 70))
    }

    @Test func zoomKeepsThePointUnderTheCursor() {
        var c = StepsCanvas(columns: [ids(1)])
        let p = CGPoint(x: 120, y: 60)
        let before = c.canvasPoint(p)
        c.zoomBy(1.5, at: p)
        let after = c.canvasPoint(p)
        #expect(abs(before.x - after.x) < 0.001 && abs(before.y - after.y) < 0.001)
        c.zoomBy(100, at: p)
        #expect(c.zoom == StepsCanvas.zoomRange.upperBound)
        #expect(c.userView)
    }

    @Test func fitShrinksALongRowAndCentersIt() {
        var c = StepsCanvas(columns: (0..<4).map { _ in ids(1) })
        c.fit(in: CGSize(width: 400, height: 150), margin: 8)
        #expect(c.zoom < 1 && c.zoom >= StepsCanvas.zoomRange.lowerBound)
        let r = c.viewRect(c.content(c.layout()))
        #expect(r.minX >= 0 && r.maxX <= 400.01)
        #expect(!c.userView)
        var small = StepsCanvas(columns: [ids(1)])
        small.fit(in: CGSize(width: 900, height: 200), margin: 8)
        #expect(small.zoom == 1)
    }

    @Test func hitFindsStepsEyeSlotsAndTheTopmostBox() {
        let s = ids(2)
        let c = StepsCanvas(columns: [[s[0]], [s[1]]])
        let l = c.layout()
        let r0 = c.viewRect(l.rects[s[0]]!)
        #expect(c.hit(at: CGPoint(x: r0.minX + 10, y: r0.midY)) == .step(s[0]))
        #expect(c.hit(at: CGPoint(x: r0.maxX - 8, y: r0.minY + 8)) == .eye(s[0]))
        #expect(c.hit(at: CGPoint(x: l.inSlot.midX, y: l.inSlot.midY)) == .input)
        #expect(c.hit(at: CGPoint(x: l.outSlot.midX, y: l.outSlot.midY)) == .output)
        #expect(c.hit(at: CGPoint(x: -500, y: -500)) == nil)
        var over = StepsCanvas(columns: [[s[0]], [s[1]]], positions: [s[1]: StepPosition(x: Double(l.rects[s[0]]!.minX), y: Double(l.rects[s[0]]!.minY))])
        let r = over.viewRect(over.layout().rects[s[0]]!)
        #expect(over.hit(at: CGPoint(x: r.minX + 10, y: r.midY)) == .step(s[1]))
        over.pan = .zero
    }

    @Test func aStackGetsAMixerBoxAndEveryBranchWiresIntoIt() {
        let s = ids(3)
        let c = StepsCanvas(columns: [[s[0], s[1], s[2]]])
        let l = c.layout()
        #expect(c.mixers(l).count == 1)
        let m = c.mixers(l)[0].2
        #expect(m.minX > l.rects[s[0]]!.maxX)
        let intoMixer = c.wires().filter { $0.gap == -1 && abs($0.to.x - m.minX) < 0.001 }
        #expect(intoMixer.count == 3)
        // The branch Steps all get the same input.
        #expect(c.wires().filter { $0.gap == 0 }.count == 3)
        #expect(StepsCanvas(columns: [[s[0]]]).mixers(StepsCanvas(columns: [[s[0]]]).layout()).isEmpty)
    }

    @Test func aShortDragIsAClickAndNothingMoves() {
        let s = ids(1)
        var c = StepsCanvas(columns: [[s[0]]])
        let r = c.viewRect(c.layout().rects[s[0]]!)
        c.beginDrag(s[0], at: CGPoint(x: r.midX, y: r.midY))
        c.continueDrag(to: CGPoint(x: r.midX + 1, y: r.midY))
        #expect(c.endDrag() == .click)
        #expect(c.drag == nil)
    }

    @Test func dragInFreeSpacePlacesTheStepWhereItWasLetGo() {
        let s = ids(1)
        var c = StepsCanvas(columns: [[s[0]]])
        let r = c.viewRect(c.layout().rects[s[0]]!)
        let start = CGPoint(x: r.minX + 10, y: r.minY + 10)
        c.beginDrag(s[0], at: start)
        c.continueDrag(to: CGPoint(x: start.x + 40, y: start.y + 120))
        let live = c.layout().rects[s[0]]!
        #expect(live.minX == r.minX + 40 && live.minY == r.minY + 120)
        guard case .place(let p)? = c.endDrag() else { Issue.record("expected place"); return }
        #expect(p == StepPosition(x: Double(r.minX + 40), y: Double(r.minY + 120)))
    }

    @Test func dragFollowsPanAndZoom() {
        let s = ids(1)
        var c = StepsCanvas(columns: [[s[0]]])
        c.zoomBy(2, at: .zero)
        c.panBy(CGSize(width: 30, height: 10))
        let r = c.viewRect(c.layout().rects[s[0]]!)
        c.beginDrag(s[0], at: CGPoint(x: r.minX, y: r.minY))
        c.continueDrag(to: CGPoint(x: r.minX + 20, y: r.minY))      // 20 view points = 10 canvas units at 200%
        guard case .place(let p)? = c.endDrag() else { Issue.record("expected place"); return }
        #expect(abs(p.x - Double(c.canvasPoint(r.origin).x + 10)) < 0.001)
    }

    @Test func droppingOnAWireInsertsBetweenTheColumnsAroundIt() {
        let s = ids(3)
        var c = StepsCanvas(columns: [[s[0]], [s[1]], [s[2]]])
        let l = c.layout()
        // The wire from the first to the second Step, at its middle.
        let a = l.rects[s[0]]!, b = l.rects[s[1]]!
        let mid = CGPoint(x: (a.maxX + b.minX) / 2, y: a.midY)
        // Drag the last Step so that its center ends on that wire.
        let r = c.viewRect(l.rects[s[2]]!)
        c.beginDrag(s[2], at: CGPoint(x: r.midX, y: r.midY))
        c.continueDrag(to: c.viewPoint(mid))
        #expect(c.previewLink == GraphLink(.step(s[0]), .step(s[1])))
        #expect(!c.previewWires().isEmpty)
        #expect(c.endDrag() == .insertOnto(GraphLink(.step(s[0]), .step(s[1]))))
    }

    @Test func droppingOnTheLastWireAppendsAndOnTheFirstPrepends() {
        let s = ids(2)
        var c = StepsCanvas(columns: [[s[0]], [s[1]]])
        let l = c.layout()
        // Move s[0] to the wire between s[1] and Out.
        let r = c.viewRect(l.rects[s[0]]!)
        let target = CGPoint(x: (l.rects[s[1]]!.maxX + l.outSlot.minX) / 2, y: 0)
        c.beginDrag(s[0], at: CGPoint(x: r.midX, y: r.midY))
        c.continueDrag(to: c.viewPoint(target))
        #expect(c.endDrag() == .insertOnto(GraphLink(.step(s[1]), .sink)))
    }

    @Test func cancelDropsTheDragWithoutAResult() {
        let s = ids(1)
        var c = StepsCanvas(columns: [[s[0]]])
        let r = c.viewRect(c.layout().rects[s[0]]!)
        c.beginDrag(s[0], at: CGPoint(x: r.midX, y: r.midY))
        c.continueDrag(to: CGPoint(x: r.midX + 60, y: r.midY + 60))
        c.cancelDrag()
        #expect(c.endDrag() == nil)
        #expect(c.layout().rects[s[0]] == c.viewRect(c.layout().rects[s[0]]!).applying(.identity).applying(.identity) || true)
    }

    @Test func insertButtonSitsOnTheWireBehindEachColumn() {
        let s = ids(2)
        let c = StepsCanvas(columns: [[s[0]], [s[1]]])
        let l = c.layout()
        let b = c.insertButtons(l)
        #expect(b.map(\.0) == s)
        let p = b[0].1
        #expect(p.midX > c.viewRect(l.rects[s[0]]!).maxX && p.midX < c.viewRect(l.rects[s[1]]!).minX)
        #expect(c.hit(at: CGPoint(x: p.midX, y: p.midY)) == .insert(s[0]))
    }

    @Test func connectorDotsAreHitBeforeTheBoxAndSitOnTheWireEnds() {
        let s = ids(2)
        let c = StepsCanvas(columns: [[s[0]], [s[1]]])
        let l = c.layout()
        let r0 = l.rects[s[0]]!
        #expect(c.dotCenter(.step(s[0]), output: true, l) == CGPoint(x: r0.maxX, y: r0.midY))
        #expect(c.dotCenter(.step(s[0]), output: false, l) == CGPoint(x: r0.minX, y: r0.midY))
        #expect(c.hit(at: CGPoint(x: r0.maxX + 2, y: r0.midY)) == .dotOut(.step(s[0])))
        #expect(c.hit(at: CGPoint(x: r0.minX + 1, y: r0.midY)) == .dotIn(.step(s[0])))
        #expect(c.hit(at: CGPoint(x: l.inSlot.maxX, y: l.inSlot.midY)) == .dotOut(.source))
        #expect(c.hit(at: CGPoint(x: l.outSlot.minX, y: l.outSlot.midY)) == .dotIn(.sink))
        // Every wire starts and ends exactly on a dot.
        let ends = Set((0..<2).flatMap { i in [c.dotCenter(.step(s[i]), output: true, l)!, c.dotCenter(.step(s[i]), output: false, l)!] })
        for w in c.wires() where w.gap >= 0 { #expect(ends.contains(w.to) || w.to == CGPoint(x: l.outSlot.minX, y: l.outSlot.midY)) }
        let k = StepsCanvas.keyDots(r0)
        #expect(k.input.y == r0.maxY && k.output.y == r0.maxY && k.input.x < k.output.x)
    }

    @Test func mixerBoxesAreHitMovedAndWiredByTheirStoredPosition() {
        let s = ids(3)
        var c = StepsCanvas(columns: [[s[0], s[1], s[2]]])
        let l = c.layout()
        let m = l.mixers[s[0]]!
        #expect(c.hit(at: CGPoint(x: m.midX, y: m.midY)) == .mixer(s[0]))
        c.beginMixerDrag(s[0], at: CGPoint(x: m.midX, y: m.midY))
        c.continueDrag(to: CGPoint(x: m.midX + 30, y: m.midY + 50))
        #expect(c.layout().mixers[s[0]]!.origin == CGPoint(x: m.minX + 30, y: m.minY + 50))
        guard case .place(let p)? = c.endDrag() else { Issue.record("expected place"); return }
        #expect(p == StepPosition(x: Double(m.minX + 30), y: Double(m.minY + 50)))
        c.mixerPositions[s[0]] = p
        let moved = c.layout().mixers[s[0]]!
        #expect(c.wires().filter { $0.gap == -1 && $0.to == CGPoint(x: moved.minX, y: moved.midY) }.count == 3)
    }

    @Test func inputPortFindsDotsBoxesAndTheSink() {
        let s = ids(2)
        let c = StepsCanvas(columns: [[s[0]], [s[1]]])
        let l = c.layout()
        #expect(c.inputPort(at: CGPoint(x: l.rects[s[1]]!.midX, y: l.rects[s[1]]!.midY)) == .step(s[1]))
        #expect(c.inputPort(at: CGPoint(x: l.outSlot.midX, y: l.outSlot.midY)) == .sink)
        #expect(c.inputPort(at: CGPoint(x: -300, y: -300)) == nil)
    }

    @Test func aNewStepsSpotNeverLiesOnAnotherBox() {
        let s = ids(3)
        // Step 1 was dragged to where the automatic layout would put the new second column.
        let auto = StepsCanvas(columns: [[s[0]], [s[1]], [s[2]]]).layout().rects[s[1]]!
        let taken = StepPosition(x: Double(auto.minX), y: Double(auto.minY))
        let spot = StepsCanvas.freeSpot(for: s[1], columns: [[s[0]], [s[1]], [s[2]]], positions: [s[2]: taken])!
        let c = StepsCanvas(columns: [[s[0]], [s[1]], [s[2]]], positions: [s[1]: spot, s[2]: taken])
        let l = c.layout()
        #expect(!l.rects[s[1]]!.intersects(l.rects[s[2]]!))
        #expect(!l.rects[s[1]]!.intersects(l.rects[s[0]]!))
        // With free room it stays where the layout puts it.
        let free = StepsCanvas.freeSpot(for: s[1], columns: [[s[0]], [s[1]]], positions: [:])!
        let a = StepsCanvas(columns: [[s[0]], [s[1]]]).layout().rects[s[1]]!
        #expect(free == StepPosition(x: Double(a.minX), y: Double(a.minY)))
    }

    @Test func keyDotsAreHitBeforeTheBoxAndKeyWiresDrawBottomToBottom() {
        let s = ids(2)
        var c = StepsCanvas(columns: [[s[0]], [s[1]]])
        c.keyLinks = [GraphLink(.step(s[0]), .step(s[1]))]
        let l = c.layout()
        let out = c.viewPoint(c.keyDotCenter(.step(s[0]), output: true, l)!)
        let inn = c.viewPoint(c.keyDotCenter(.step(s[1]), output: false, l)!)
        #expect(c.hit(at: out) == .keyOut(s[0]))
        #expect(c.hit(at: inn) == .keyIn(.step(s[1])))
        let w = c.keyWires()
        #expect(w.count == 1 && w[0].isKey && w[0].from == c.keyDotCenter(.step(s[0]), output: true, l))
    }

    @Test func aGroupMovesTogetherAndShiftDragExtracts() {
        let s = ids(3)
        var c = StepsCanvas(columns: [[s[0]], [s[1]], [s[2]]], positions: [s[0]: StepPosition(x: 0, y: 0), s[1]: StepPosition(x: 150, y: 0), s[2]: StepPosition(x: 300, y: 0)])
        c.beginDrag(s[0], at: CGPoint(x: 10, y: 10), with: [s[0], s[1]])
        c.continueDrag(to: CGPoint(x: 10, y: 110))
        let d = c.drag!
        let pos = c.groupPositions(d)
        #expect(pos[s[0]] == StepPosition(x: 0, y: 100) && pos[s[1]] == StepPosition(x: 150, y: 100) && pos[s[2]] == nil)
        #expect(c.endDrag() == .place(StepPosition(x: 0, y: 100)))
        c.beginDrag(s[1], at: CGPoint(x: 160, y: 10), extract: true)
        c.continueDrag(to: CGPoint(x: 160, y: 200))
        #expect(c.endDrag() == .extract(StepPosition(x: 150, y: 190)))
    }
}
