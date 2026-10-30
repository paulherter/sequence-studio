import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

/// V1 (a clip at 0-100), V2 with a 20-frame cross dissolve layer at frames 40-60 (cut at 50), on a 1000 x 400 pt panel.
@MainActor private func setup() throws -> (TimelinePanel, EditorSession, Clip.ID) {
    let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 100), start: .zero)
    let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c]), Track(kind: .video)])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    let id = try #require(s.addTransitionLayer(kind: .crossDissolve, track: t.tracks[1].id, start: fd * 40, duration: fd * 20, cut: fd * 50))
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    p.toolState.snapping = false
    sync(&p, s)
    return (p, s, id)
}

@MainActor private func sync(_ p: inout TimelinePanel, _ s: EditorSession) {
    p.sync(timeline: s.activeTimeline!, selection: s.selection, playhead: .zero, selectedTransition: nil, labels: LabelResolver())
}

/// Runs a press-drag-release, applying (and syncing) each step's actions like the host.
@MainActor private func drag(_ p: inout TimelinePanel, _ s: EditorSession, from a: CGFloat, to b: CGFloat, y: CGFloat,
                             _ m: InputModifiers = []) -> [TimelineAction] {
    var all = p.handle(.mouseDown(x: Float(a), y: Float(y), modifiers: m))
    for a in all { TimelineSessionBridge.apply(a, to: s) }
    sync(&p, s)
    for x in stride(from: a, through: b, by: (b - a) / 4) {
        let step = p.handle(.mouseDragged(x: Float(x), y: Float(y)))
        for a in step { TimelineSessionBridge.apply(a, to: s) }
        all += step
    }
    let up = p.handle(.mouseUp(x: Float(b), y: Float(y)))
    for a in up { TimelineSessionBridge.apply(a, to: s) }
    sync(&p, s)
    return all + up
}

@MainActor @Suite struct TransitionLayerTests {
    @Test func theCutMarkerMovesTheCutAsOneUndoStep() throws {
        var (p, s, id) = try setup()
        let row = p.rows.first { $0.track == s.activeTimeline!.tracks[1].id }!
        let y = row.y + row.height / 2, cx = p.geometry.x(for: fd * 50)
        s.select(clips: [])
        sync(&p, s)
        let acts = drag(&p, s, from: cx, to: p.geometry.x(for: fd * 54), y: y)  // 4 frames later
        #expect(acts.first == .select(clips: [id], captions: []))
        #expect(s.activeTimeline!.resolvedTransitionLayer(id)?.cut == fd * 54)
        s.undo()
        #expect(s.activeTimeline!.resolvedTransitionLayer(id)?.cut == fd * 50)
    }

    @Test func anEndResizesSymmetricallyAndAltMovesOnlyThatEnd() throws {
        var (p, s, id) = try setup()
        let row = p.rows.first { $0.track == s.activeTimeline!.tracks[1].id }!
        let y = row.y + row.height / 2, tail = p.geometry.x(for: fd * 60) - 1, out = p.geometry.x(for: fd * 63) - 1
        _ = drag(&p, s, from: tail, to: out, y: y)                      // 3 frames out on both sides
        let r = try #require(s.activeTimeline!.resolvedTransitionLayer(id))
        #expect(r.span == TimeRange(start: fd * 37, duration: fd * 26))
        s.undo()
        sync(&p, s)
        p.lastClick = nil                                                   // a new press, not a double-click
        _ = drag(&p, s, from: tail, to: out, y: y, [.option])
        let one = try #require(s.activeTimeline!.resolvedTransitionLayer(id))
        #expect(one.span == TimeRange(start: fd * 40, duration: fd * 23))
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        #expect(!list.quads.isEmpty)
    }
}
