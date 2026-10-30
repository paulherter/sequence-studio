import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import SQUIKit
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

private func clip(_ startFrame: Int64, _ frames: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: fd * frames), start: fd * startFrame)
}

/// V1 with one 100-frame clip, A1 with one; a 1000 x 400 pt panel synced to the session.
@MainActor private func setup() -> (TimelinePanel, EditorSession) {
    let t = Timeline(name: "t", frameDuration: fd,
                     tracks: [Track(kind: .video, clips: [clip(0, 100)]), Track(kind: .audio, clips: [clip(0, 100, kind: .audio)])])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    sync(&p, s)
    return (p, s)
}

@MainActor private func sync(_ p: inout TimelinePanel, _ s: EditorSession) {
    p.sync(timeline: s.activeTimeline!, selection: s.selection, playhead: s.playhead, selectedTransition: nil,
           labels: LabelResolver(), lineKeys: Set(s.selectedLineKeys.map(\.key)))
}

@MainActor private func run(_ p: inout TimelinePanel, _ s: EditorSession, _ e: InputEvent) -> [TimelineAction] {
    let a = p.handle(e)
    for x in a { TimelineSessionBridge.apply(x, to: s, host: nil) }
    return a
}

/// The clip on track `i` and its drawn rectangle.
@MainActor private func target(_ p: TimelinePanel, _ s: EditorSession, track i: Int) -> (Clip, CGRect) {
    let tr = s.activeTimeline!.tracks[i], c = tr.clips[0]
    let row = p.rows.first { $0.track == tr.id }!
    let x0 = p.geometry.x(for: c.start), x1 = p.geometry.x(for: c.timeline.end)
    return (c, CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height))
}

private func ev(_ x: CGFloat, _ y: CGFloat, _ kind: Int, _ m: InputModifiers = []) -> InputEvent {
    switch kind {
    case 0: .mouseDown(x: Float(x), y: Float(y), modifiers: m)
    case 1: .mouseDragged(x: Float(x), y: Float(y))
    default: .mouseUp(x: Float(x), y: Float(y))
    }
}

@MainActor @Suite struct TimelineBandsTests {
    @Test func volumeLineDragIsOneUndoStep() {
        var (p, s) = setup()
        let (c, rect) = target(p, s, track: 1)
        #expect(VolumeLine.isAvailable(rowHeight: rect.height))
        let lane = VolumeLine.lane(in: rect)
        let x = rect.midX.rounded(), y = VolumeLine.y(forDB: 0, in: lane).rounded()
        let a = run(&p, s, ev(x, y, 0))
        #expect(a.first == .select(clips: [c.id], captions: []))
        #expect(p.isDragging)
        _ = run(&p, s, ev(x, y + 10, 1))
        let last = run(&p, s, ev(x, y + 20, 2))
        #expect(last.last == .endGesture)
        let after = s.activeTimeline!.tracks[1].clips[0]
        #expect(after.volume(at: after.start) < 0.9)                    // the line went down
        s.undo()
        #expect(s.activeTimeline!.tracks[1].clips[0].volume(at: c.start) == c.volume(at: c.start))   // one step back to the start
    }

    @Test func escDuringBandDragPutsTheSessionBack() {
        var (p, s) = setup()
        let (c, rect) = target(p, s, track: 1)
        let lane = VolumeLine.lane(in: rect)
        let x = rect.midX.rounded(), y = VolumeLine.y(forDB: 0, in: lane).rounded()
        _ = run(&p, s, ev(x, y, 0))
        _ = run(&p, s, ev(x, y + 20, 1))
        #expect(s.activeTimeline!.tracks[1].clips[0] != c)            // the drag reached the session
        let esc = p.key(.escape, modifiers: []) ?? []
        for a in esc { TimelineSessionBridge.apply(a, to: s, host: nil) }
        #expect(esc.last == .endGesture)
        #expect(!p.isDragging)
        #expect(s.activeTimeline!.tracks[1].clips[0] == c)            // back to the start
        #expect(!s.canUndo)                                           // and no empty step left behind
    }

    @Test func fadeHandleDragAndItsMenu() {
        var (p, s) = setup()
        let (c, rect) = target(p, s, track: 1)
        let h = VolumeLine.fadeHandlePoints(clip: c, clipRect: rect).head
        #expect(p.fadeHandleHit(at: h)?.handle == .head)
        let host = TimelineHost()
        #expect(TimelineMenus.items(at: h, panel: &p, session: s, host: host)?.map(\.title) == FadeCurve.allCases.map(\.title))
        _ = run(&p, s, ev(h.x, h.y, 0))
        _ = run(&p, s, ev(h.x + 100, h.y, 1))
        #expect(run(&p, s, ev(h.x + 100, h.y, 2)).last == .endGesture)
        #expect(s.activeTimeline!.tracks[1].clips[0].audioFadeIn > .zero)
    }

    @Test func opacityLineShowsOffFullAndDrags() {
        var (p, s) = setup()
        var (c, rect) = target(p, s, track: 0)
        let lane = OpacityLine.lane(in: rect)
        let full = CGPoint(x: rect.midX.rounded(), y: OpacityLine.y(forOpacity: 1, in: lane).rounded())
        _ = run(&p, s, ev(full.x, full.y, 0, .command))
        if case .band? = p.gesture { Issue.record("a plain 100 % clip shows no line to take") }
        _ = run(&p, s, ev(full.x, full.y, 2))
        c.animation.opacity.value = 0.5
        s.replaceClip(c, name: "Opacity", continuesGesture: false)
        sync(&p, s)
        let half = CGPoint(x: rect.midX.rounded(), y: OpacityLine.y(forOpacity: 0.5, in: lane).rounded())
        _ = run(&p, s, ev(half.x, half.y, 0))
        guard case .band? = p.gesture else { Issue.record("the 50 % line missed the press"); return }
        _ = run(&p, s, ev(half.x, half.y + 8, 1))
        #expect(run(&p, s, ev(half.x, half.y + 8, 2)).last == .endGesture)
        #expect(s.activeTimeline!.tracks[0].clips[0].animation.opacity.value < 0.5)
    }

    @Test func speedBandDragAndMenus() {
        var (p, s) = setup()
        let (c, rect) = target(p, s, track: 0)
        p.speedBandClips = [c.id]
        let lane = ClipBodyMetrics.waveformRect(in: rect)
        let g = p.geometry
        let pts = SpeedBand.linePoints(keys: SpeedKeys.of(c), clipStart: c.start, lane: lane, x: { g.x(for: $0) })
        let pt = CGPoint(x: rect.midX.rounded(), y: pts[0].y.rounded())
        #expect(p.speedSegmentClip(at: pt) == c.id)
        let host = TimelineHost()
        #expect(TimelineMenus.items(at: pt, panel: &p, session: s, host: host)?.map(\.title) == ["Add Speed Point"])
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        #expect(!list.quads.isEmpty)
        let a = run(&p, s, ev(pt.x, pt.y, 0))
        guard case .speedEdit(_, _, .began, _)? = a.last else { Issue.record("no began"); return }
        _ = run(&p, s, ev(pt.x, pt.y - 15, 1))
        let end = run(&p, s, ev(pt.x, pt.y - 15, 2))
        guard case .speedEdit(_, _, .ended, _)? = end.last else { Issue.record("no ended"); return }
        #expect(s.activeTimeline!.tracks[0].clips[0].duration < c.duration)   // dragged up: faster, so shorter
    }

    @Test func escDuringSpeedBandDragPutsTheSessionBack() {
        var (p, s) = setup()
        let start = s.activeTimeline!
        let (c, rect) = target(p, s, track: 0)
        p.speedBandClips = [c.id]
        let lane = ClipBodyMetrics.waveformRect(in: rect)
        let g = p.geometry
        let pts = SpeedBand.linePoints(keys: SpeedKeys.of(c), clipStart: c.start, lane: lane, x: { g.x(for: $0) })
        let pt = CGPoint(x: rect.midX.rounded(), y: pts[0].y.rounded())
        _ = run(&p, s, ev(pt.x, pt.y, 0))
        let depth = s.undoDepth
        _ = run(&p, s, ev(pt.x, pt.y - 15, 1))
        #expect(s.activeTimeline!.tracks[0].clips[0].duration < c.duration)   // the drag reached the session
        let esc = p.key(.escape, modifiers: []) ?? []
        for a in esc { TimelineSessionBridge.apply(a, to: s, host: nil) }
        #expect(!p.isDragging)
        #expect(s.activeTimeline!.tracks.map(\.clips) == start.tracks.map(\.clips))   // back to the start
        #expect(s.undoDepth == depth)                                             // and no step left behind
        #expect(p.timeline.tracks[0].clips[0].duration == c.duration)
    }

    @Test func keyLanePressPicksTheKeyThroughTheHost() {
        var (p, s) = setup()
        let (c, rect) = target(p, s, track: 0)
        let lanes = FakeKeyLanes(time: c.start + fd * 50)
        p.keyLanes = lanes
        s.select(clips: [c.id])
        sync(&p, s)
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        #expect(lanes.drawn == [c.id])
        let pt = CGPoint(x: p.geometry.x(for: c.start + fd * 50), y: rect.maxY - 6)
        let a = p.handle(ev(pt.x, pt.y, 0, .shift))
        #expect(a == [.keyLaneClick(clip: c.id, time: c.start + fd * 50, extend: true)])
        let host = TimelineHost()
        var asked: TimelineEditorRequest?
        host.open = { asked = $0; return true }
        #expect(TimelineSessionBridge.apply(a[0], to: s, host: host) == nil)
        #expect(asked == .keyLaneKey(clip: c.id, time: c.start + fd * 50, extend: true))
    }
}

/// One key at `time` on every selected clip, its glyph in a 10 pt strip at the bottom of the clip.
private final class FakeKeyLanes: TimelineKeyLaneSource {
    let time: Time
    var drawn: [Clip.ID] = []
    init(time: Time) { self.time = time }
    func keyLane(clip: Clip, clipRect: CGRect, visible: CGRect, selected: Bool, geometry: TimelineGeometry) -> TimelineKeyLane? {
        guard selected else { return nil }
        drawn.append(clip.id)
        let lane = CGRect(x: clipRect.minX, y: clipRect.maxY - 11, width: clipRect.width, height: 10)
        return TimelineKeyLane(lane: lane, glyphs: [.init(center: CGPoint(x: geometry.x(for: time), y: lane.midY), selected: false)], glyphSize: 7)
    }
    func keyLaneHit(clip: Clip, clipRect: CGRect, at p: CGPoint, geometry: TimelineGeometry) -> Time? {
        abs(geometry.x(for: time) - p.x) <= 5.5 && p.y >= clipRect.maxY - 13 ? time : nil
    }
}
