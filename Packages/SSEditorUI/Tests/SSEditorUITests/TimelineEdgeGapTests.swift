import CoreGraphics
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1, 24)

/// 4 pt per frame: frame f is at x = 162 + 4 f. V1 y42..<74.
private func X(_ f: Double) -> CGFloat { 162 + CGFloat(f) * 4 }
private let yV1: CGFloat = 70

private func mk(_ start: Int64, _ frames: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: fd * 50, duration: fd * frames),
         start: fd * start, mediaDuration: fd * 200)
}

private struct Fixture {
    var c1 = mk(0, 20), c2 = mk(20, 20), c3 = mk(60, 20)
    var timeline: Timeline {
        Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c1, c2, c3]), Track(kind: .video)])
    }
    func interaction() -> TimelineInteraction {
        var i = TimelineInteraction(timeline: timeline, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: .selection, snapping: false, linkedSelection: true)
        return i
    }
}

private func drag(_ i: inout TimelineInteraction, from a: CGPoint, to b: CGPoint, _ m: GestureModifiers = []) -> TimelineCommit? {
    i.mouseDown(a, modifiers: m)
    i.mouseDragged(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), modifiers: m)
    i.mouseDragged(b, modifiers: m)
    return i.mouseUp(b, modifiers: m)
}

private func click(_ i: inout TimelineInteraction, _ p: CGPoint, _ m: GestureModifiers = []) {
    i.mouseDown(p, modifiers: m)
    i.mouseUp(p, modifiers: m)
}

@Suite struct TimelineEdgeGapTests {
    @Test func clickOnEdgeSelectsTheEdgeNotTheClip() {
        let f = Fixture()
        var i = f.interaction()
        click(&i, CGPoint(x: X(40) - 1, y: yV1))
        #expect(i.selection.isEmpty)
        #expect(i.edgeSelection == EdgeSelection(edges: [EdgeRef(clip: f.c2.id, edge: .tail)], ripple: false))
        click(&i, CGPoint(x: X(40) - 1, y: yV1), .command)
        #expect(i.edgeSelection?.ripple == true)
        click(&i, CGPoint(x: X(30), y: yV1))
        #expect(i.edgeSelection == nil)
        #expect(i.selection == [f.c2.id])
    }

    @Test func commandDragOnAnEdgeRipplesLaterClips() throws {
        let f = Fixture()
        var i = f.interaction()
        let c = try #require(drag(&i, from: CGPoint(x: X(40) - 1, y: yV1), to: CGPoint(x: X(35) - 1, y: yV1), .command))
        #expect(c.undoName == "Ripple Trim")
        let v1 = c.timeline.tracks[0].clips
        #expect(v1[1].timeline.end == fd * 35)
        #expect(v1[2].start == fd * 55)
    }

    @Test func plainDragOnAnEdgeTrimsWithoutRipple() throws {
        let f = Fixture()
        var i = f.interaction()
        let c = try #require(drag(&i, from: CGPoint(x: X(40) - 1, y: yV1), to: CGPoint(x: X(35) - 1, y: yV1)))
        #expect(c.undoName == "Trim Clip")
        #expect(c.timeline.tracks[0].clips[2].start == fd * 60)
    }

    @Test func shiftClickingBothSidesOfAnEditRollsIt() throws {
        let f = Fixture()
        var i = f.interaction()
        click(&i, CGPoint(x: X(20) - 1, y: yV1))                 // c1 tail
        i.mouseDown(CGPoint(x: X(20) + 1, y: yV1), modifiers: .shift)   // + c2 head
        i.mouseUp(CGPoint(x: X(20) + 1, y: yV1), modifiers: .shift)
        #expect(i.edgeSelection?.edges.count == 2)
        let c = try #require(drag(&i, from: CGPoint(x: X(20) + 1, y: yV1), to: CGPoint(x: X(25) + 1, y: yV1)))
        #expect(c.undoName == "Roll Edit")
        let v1 = c.timeline.tracks[0].clips
        #expect(v1[0].timeline.end == fd * 25 && v1[1].start == fd * 25)
    }

    @Test func clickOnAGapSelectsItAndClickElsewhereClearsIt() {
        let f = Fixture()
        var i = f.interaction()
        click(&i, CGPoint(x: X(50), y: yV1))
        #expect(i.gapSelection?.range == TimeRange(start: fd * 40, end: fd * 60))
        click(&i, CGPoint(x: X(10), y: yV1))
        #expect(i.gapSelection == nil)
    }

    @Test func optionDragCopiesAndSelectsTheCopy() throws {
        let f = Fixture()
        var i = f.interaction()
        let c = try #require(drag(&i, from: CGPoint(x: X(70), y: yV1), to: CGPoint(x: X(90), y: yV1), .option))
        #expect(c.undoName == "Copy Clip")
        let v1 = c.timeline.tracks[0].clips
        #expect(v1.count == 4)
        #expect(v1.contains { $0.id == f.c3.id && $0.start == fd * 60 })
        let copy = try #require(v1.first { $0.start == fd * 80 })
        #expect(c.selection == [copy.id])
    }

    @Test func edgeEditsTrimRollAndExtend() {
        let f = Fixture()
        let t = f.timeline
        let tail = EdgeRef(clip: f.c1.id, edge: .tail), head = EdgeRef(clip: f.c2.id, edge: .head)
        #expect(EdgeEdits.trim(EdgeSelection(edges: [tail]), by: fd * -1, in: t) == [.trim(f.c1.id, edge: .tail, by: fd * -1)])
        #expect(EdgeEdits.trim(EdgeSelection(edges: [tail], ripple: true), by: fd, in: t) == [.rippleTrim(f.c1.id, edge: .tail, by: fd)])
        #expect(EdgeEdits.trim(EdgeSelection(edges: [tail, head]), by: fd * 5, in: t) == [.roll(f.c1.id, by: fd * 5)])
        #expect(EdgeEdits.extend(EdgeSelection(edges: [head]), to: fd * 25, in: t) == [.trim(f.c2.id, edge: .head, by: fd * 5)])
        #expect(EdgeEdits.trim(EdgeSelection(edges: [tail]), by: .zero, in: t).isEmpty)
    }
}
