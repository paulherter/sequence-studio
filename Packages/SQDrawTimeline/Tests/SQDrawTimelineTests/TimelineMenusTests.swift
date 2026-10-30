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

/// A session on V1 (two clips), V2, A1 and a 1000 x 400 pt panel synced to it.
@MainActor private func setup() -> (TimelinePanel, EditorSession, Timeline) {
    let t = Timeline(name: "t", frameDuration: fd,
                     tracks: [Track(kind: .video, clips: [clip(0, 50), clip(100, 50)]), Track(kind: .video), Track(kind: .audio)])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    let tl = s.activeTimeline!
    p.sync(timeline: tl, selection: s.selection, playhead: s.playhead, selectedTransition: nil, labels: LabelResolver())
    return (p, s, tl)
}

private func titles(_ items: [SQMenuItem]?) -> [String] { (items ?? []).map(\.title) }

@MainActor @Suite struct TimelineMenusTests {
    @Test func rightPressAsksForTheMenuWithoutAGesture() {
        var (p, _, t) = setup()
        let row = p.rows.first { $0.track == t.tracks[0].id }!
        let c = t.tracks[0].clips[0]
        let pt = CGPoint(x: ((p.geometry.x(for: c.start) + p.geometry.x(for: c.timeline.end)) / 2).rounded(), y: (row.y + row.height * 0.7).rounded())
        let a = p.handle(.mouseDown(x: Float(pt.x), y: Float(pt.y), modifiers: .secondary))
        #expect(a == [.contextMenu(at: pt)])
        #expect(!p.isDragging)
        #expect(p.handle(.mouseUp(x: Float(pt.x), y: Float(pt.y))).isEmpty)
    }

    @Test func clipMenuSelectsTheClipAndRunsCommandsThroughTheHost() {
        var (p, s, t) = setup()
        let row = p.rows.first { $0.track == t.tracks[0].id }!
        let c = t.tracks[0].clips[0]
        let pt = CGPoint(x: (p.geometry.x(for: c.start) + p.geometry.x(for: c.timeline.end)) / 2, y: row.y + row.height * 0.7)
        let host = TimelineHost()
        var ran: [EditorCommand] = []
        host.command = { ran.append($0) }
        let items = TimelineMenus.items(at: pt, panel: &p, session: s, host: host)
        #expect(s.selection == [c.id])
        #expect(titles(items).contains("Cut") && titles(items).contains("Ripple Delete"))
        items?.first { $0.title == "Cut" }?.action?()
        #expect(ran == [.cut])
    }

    @Test func headerMenuAddsDeletesAndRenamesTracks() async {
        var (p, s, t) = setup()
        let row = p.rows.first { $0.track == t.tracks[1].id }!
        let pt = CGPoint(x: TimelineGeometry.toolColumnWidth + 20, y: row.y + 4)
        let host = TimelineHost()
        host.prompt = { _ in "Titles" }
        let items = TimelineMenus.items(at: pt, panel: &p, session: s, host: host) ?? []
        let n = s.activeTimeline!.tracks.count
        items.first { $0.title.hasPrefix("Add Video Track") }?.action?()
        #expect(s.activeTimeline!.tracks.count == n + 1)
        items.first { $0.title.hasPrefix("Rename") }?.action?()
        for _ in 0..<20 where s.activeTimeline!.track(t.tracks[1].id)?.name != "Titles" { await Task.yield() }
        #expect(s.activeTimeline!.track(t.tracks[1].id)?.name == "Titles")
        items.first { $0.title.hasPrefix("Delete Track") }?.action?()
        #expect(s.activeTimeline!.track(t.tracks[1].id) == nil)
    }

    @Test func rulerMenuAddsAMarkerAndMissingEditorsReportStatus() {
        var (p, s, _) = setup()
        let host = TimelineHost()
        var lines: [String] = []
        host.status = { lines.append($0) }
        let items = TimelineMenus.items(at: CGPoint(x: TimelineGeometry.contentOriginX + 100, y: 10), panel: &p, session: s, host: host)
        #expect(titles(items).first == "Add Marker")
        items?.first?.action?()
        #expect(s.activeTimeline!.markers.count == 1)
        #expect(TimelineSessionBridge.apply(.editMarker(s.activeTimeline!.markers[0].id), to: s, host: host)
                == TimelineEditorRequest.marker(s.activeTimeline!.markers[0].id).unavailable)
        host.open = { _ in true }
        #expect(TimelineSessionBridge.apply(.openInSource(UUID()), to: s, host: host) == nil)
    }
}
