import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }

private func item(_ name: String, _ range: TimeRange?) -> GraphicsLayer {
    var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
    l.name = name
    l.range = range
    return l
}

/// V1 with a 10 s Graphic at 2 s holding "low" (bottom) and "top", V2 empty, A1 below; a 1200 x 500 pt panel synced to
/// the session, behind a host whose `panel` reaches it.
@MainActor private final class Rig {
    var p = TimelinePanel()
    let s: EditorSession
    let host = TimelineHost()
    let graphic: Clip.ID
    var picked: (Clip.ID, Set<UUID>)?

    init() throws {
        let v = Track(kind: .video), v2 = Track(kind: .video), a = Track(kind: .audio)
        let t = Timeline(name: "T", frameDuration: fd, tracks: [v, v2, a])
        var project = Project(name: "P", timelines: [t])
        graphic = try project.addGraphicsClip(in: t.id, at: Time(2, 1), track: v.id, duration: Time(10, 1),
                                              layers: [item("low", nil), item("top", TimeRange(start: Time(2, 1), end: Time(4, 1)))])
        s = EditorSession(project: project)
        p.layout(DrawRect(x: 0, y: 0, w: 1200, h: 500), scale: 1)
        host.panel = { [unowned self] change in change(&p) }
        host.itemSelection = { [unowned self] clip, items in picked = (clip, items) }
        sync()
    }

    func sync() {
        p.sync(timeline: s.activeTimeline!, selection: s.selection, playhead: s.playhead, selectedTransition: nil,
               labels: LabelResolver())
    }

    @discardableResult
    func run(_ actions: [TimelineAction]) -> [String] {
        let lines = actions.compactMap { TimelineSessionBridge.apply($0, to: s, host: host) }
        sync()
        return lines
    }

    func send(_ e: InputEvent) { run(p.handle(e)) }

    var clip: Clip { s.activeTimeline!.tracks.flatMap(\.clips).first { $0.id == graphic }! }
    var layers: [GraphicsLayer] { clip.graphics!.layers }
    var row: TrackRow { p.rows.first { $0.track == s.activeTimeline!.tracks[0].id }! }
    func x(_ t: Time) -> Float { Float(p.geometry.x(for: t)) }
    /// Middle of lane `index` (0 = the top item).
    func laneY(_ index: Int) -> Float { Float(row.maxY + (CGFloat(index) + 0.5) * ItemLaneMetrics.laneHeight) }

    func open() {
        let c = clip
        let r = ItemLaneMetrics.chevronRect(rect: CGRect(x: p.geometry.x(for: c.timeline.start), y: row.y,
                                                         width: p.geometry.width(of: c.timeline.duration), height: row.height),
                                            visible: p.itemLaneContent)!
        send(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []))
        send(.mouseUp(x: Float(r.midX), y: Float(r.midY)))
    }
}

@MainActor @Suite("TimelineItemLanes") struct TimelineItemLanesTests {
    @Test func chevronOpensTheLanesAndMakesRoom() throws {
        let r = try Rig()
        #expect(r.p.openItemLanes.isEmpty && r.row.laneSpace == 0)
        r.open()
        #expect(r.p.openItemLanes == [r.graphic])
        #expect(r.row.laneSpace == 2 * ItemLaneMetrics.laneHeight)
        var list = DrawList(width: 1200, height: 500)
        r.p.draw(into: &list, atlas: nil)
        #expect(!list.quads.isEmpty)
        r.open()
        #expect(r.p.openItemLanes.isEmpty && r.row.laneSpace == 0)
    }

    @Test func barMoveIsOneUndoStepAndSelectsTheItem() throws {
        let r = try Rig()
        r.open()
        let top = r.layers[1].id, y = r.laneY(0)
        let start = r.x(Time(2, 1) + Time(3, 1))                      // middle of "top"'s bar (2 s...4 s in the clip)
        r.send(.mouseDown(x: start, y: y, modifiers: []))
        #expect(r.picked?.0 == r.graphic && r.picked?.1 == [top])
        #expect(r.s.selection == [r.graphic])
        #expect(r.p.itemSelection.items == [top])
        let to = r.x(Time(2, 1) + Time(6, 1))
        r.send(.mouseDragged(x: (start + to) / 2, y: y))
        r.send(.mouseDragged(x: to, y: y))
        r.send(.mouseUp(x: to, y: y))
        let moved = try #require(r.layers[1].range)
        #expect(moved.duration == Time(2, 1))
        #expect(moved.start > Time(2, 1))
        #expect(r.s.undo())
        r.sync()
        #expect(r.layers[1].range == TimeRange(start: Time(2, 1), end: Time(4, 1)))
    }

    @Test func escapeDuringABarDragPutsTheRangeBack() throws {
        let r = try Rig()
        r.open()
        let y = r.laneY(0), start = r.x(Time(5, 1))
        r.send(.mouseDown(x: start, y: y, modifiers: []))
        r.send(.mouseDragged(x: r.x(Time(8, 1)), y: y))
        #expect(r.layers[1].range != TimeRange(start: Time(2, 1), end: Time(4, 1)))
        r.run(r.p.key(.escape, modifiers: []) ?? [])
        #expect(r.layers[1].range == TimeRange(start: Time(2, 1), end: Time(4, 1)))
        #expect(!r.p.isDragging)
    }

    @Test func commandDDuplicatesTheSelectedItem() throws {
        let r = try Rig()
        r.open()
        r.send(.mouseDown(x: r.x(Time(5, 1)), y: r.laneY(0), modifiers: []))
        r.send(.mouseUp(x: r.x(Time(5, 1)), y: r.laneY(0)))
        let keyed = r.p.key(.character("d"), modifiers: .command)
        let out = try #require(keyed)
        r.run(out)
        #expect(r.layers.count == 3)
        #expect(r.row.laneSpace == 3 * ItemLaneMetrics.laneHeight)
        #expect(r.p.itemSelection.items.count == 1 && !r.p.itemSelection.items.contains(r.layers[1].id))
        let plain = r.p.key(.character("d"), modifiers: [])
        #expect(plain == nil)
    }

    @Test func laneNameDragReorders() throws {
        let r = try Rig()
        r.open()
        let x = Float(TimelineGeometry.toolColumnWidth + 30)
        let low = r.layers[0].id
        // "low" is the bottom lane (index 1); drag its name above the top lane.
        r.send(.mouseDown(x: x, y: r.laneY(1), modifiers: []))
        r.send(.mouseDragged(x: x, y: r.laneY(1) - 10))
        r.send(.mouseDragged(x: x, y: Float(r.row.maxY + 1)))
        r.send(.mouseUp(x: x, y: Float(r.row.maxY + 1)))
        #expect(r.layers.last?.id == low)
    }

    @Test func laneNameDragOntoAFreeTrackMakesANewGraphic() throws {
        let r = try Rig()
        r.open()
        let x = Float(TimelineGeometry.toolColumnWidth + 30)
        let v2 = r.p.rows.first { $0.track == r.s.activeTimeline!.tracks[1].id }!
        r.send(.mouseDown(x: x, y: r.laneY(0), modifiers: []))
        r.send(.mouseDragged(x: r.x(Time(5, 1)), y: Float(v2.y + v2.height / 2)))
        r.send(.mouseUp(x: r.x(Time(5, 1)), y: Float(v2.y + v2.height / 2)))
        let t = r.s.activeTimeline!
        #expect(t.tracks[1].clips.count == 1 && t.tracks[1].clips[0].isGraphics)
        #expect(r.layers.count == 1)
        #expect(r.s.selection == [t.tracks[1].clips[0].id])
    }
}
