import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

private func clip(_ name: String, at start: Int, frames: Int = 100) -> Clip {
    Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * Int64(frames)), start: fd * Int64(start))
}

/// Fast Cut: V1 host (0...100), V2 title attached to it at its own start (20...60).
@MainActor private func setup() -> (TimelinePanel, EditorSession, host: Clip.ID, title: Clip.ID) {
    let host = clip("host", at: 0)
    var title = clip("title", at: 20, frames: 40)
    title.attachment = ClipAttachment(host: host.id, point: .zero)
    var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [host]), Track(kind: .video, clips: [title])])
    t.editMode = .magnetic
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    p.sync(timeline: s.activeTimeline!, selection: s.selection, playhead: s.playhead, selectedTransition: nil, labels: LabelResolver())
    return (p, s, host.id, title.id)
}

@MainActor @Suite struct TimelineFastCutTests {
    @Test func attachThreadDragSetsTheAttachPointAsOneUndoStep() throws {
        var (p, s, _, title) = setup()
        let tl = p.timeline
        let row = try #require(p.rows.first { $0.track == tl.tracks[1].id })
        let x = p.geometry.x(for: fd * 20)
        // The thread's grab zone (the Mac `AttachPointDrag.hit`), then a drag 10 frames right.
        let y = try #require(stride(from: row.y, to: row.maxY, by: 1).first {
            AttachPointDrag.hit(at: CGPoint(x: x, y: $0), in: tl, geometry: p.geometry) == title })
        _ = p.handle(.mouseDown(x: Float(x), y: Float(y), modifiers: []))
        #expect(p.isDragging)
        let x2 = Float(p.geometry.x(for: fd * 30))
        _ = p.handle(.mouseDragged(x: x2, y: Float(y)))
        let a = p.handle(.mouseUp(x: x2, y: Float(y)))
        guard case .setAttachPoint(let id, let time)? = a.first else { Issue.record("no attach action: \(a)"); return }
        #expect(id == title)
        #expect(TimelineSessionBridge.apply(a[0], to: s) == "Attach point set.")
        #expect(s.activeTimeline!.tracks[1].clips[0].attachment?.point == time - fd * 20)
        s.undo()
        #expect(s.activeTimeline!.tracks[1].clips[0].attachment?.point == .zero)
    }

    @Test func commandOptionClickSetsTheAttachPointAtTheClick() throws {
        var (p, _, _, title) = setup()
        let row = try #require(p.rows.first { $0.track == p.timeline.tracks[1].id })
        let x = p.geometry.x(for: fd * 45)
        let a = p.handle(.mouseDown(x: Float(x), y: Float(row.y + row.height / 2), modifiers: [.command, .option]))
        #expect(a.contains(.setAttachPoint(clip: title, time: p.geometry.time(atX: x))))
    }

    @Test func fastCutMarksAndOverlaysDraw() {
        var (p, s, host, title) = setup()
        var empty = DrawList(width: 1000, height: 400)
        p.draw(into: &empty, atlas: nil)
        p.sync(timeline: s.activeTimeline!, selection: [title], playhead: s.playhead, selectedTransition: nil, labels: LabelResolver())
        p.gradeOutline = [host]
        p.analysisProgress = [host: 0.5]
        p.trackWeakSpans = { $0.id == host ? [MagicTrackHealth.Span(start: 0.4, end: 2)] : nil }
        var marked = DrawList(width: 1000, height: 400)
        p.draw(into: &marked, atlas: nil)
        // Host tint and bracket, grade outline, progress strip and weak stretch add geometry.
        #expect(marked.quads.count > empty.quads.count)
    }

    @Test func weakStretchClickSeeksToItsStart() throws {
        var (p, _, host, _) = setup()
        p.trackWeakSpans = { $0.id == host ? [MagicTrackHealth.Span(start: 1, end: 2)] : nil }
        let row = try #require(p.rows.first { $0.track == p.timeline.tracks[0].id })
        let x = p.geometry.x(for: fd * 37)
        let band = TrackConfidenceStrip.hitBand(clipRect: CGRect(x: p.geometry.x(for: .zero), y: row.y,
                                                                 width: p.geometry.x(for: fd * 100) - p.geometry.x(for: .zero), height: row.height))
        let a = p.handle(.mouseDown(x: Float(x), y: Float(band.midY), modifiers: []))
        guard case .seek(let t)? = a.last else { Issue.record("no seek: \(a)"); return }
        #expect(t == fd * 25)
    }

    @Test func holdSFlipsSnappingOnlyDuringADrag() {
        var (p, _, _, _) = setup()
        #expect(p.key(.character("s"), modifiers: []) == nil || p.snapping == p.toolState.snapping)
        let before = p.snapping
        let row = p.rows[0]
        _ = p.handle(.mouseDown(x: Float(p.geometry.x(for: fd * 50)), y: Float(row.y + row.height / 2), modifiers: []))
        _ = p.key(.character("s"), modifiers: [])
        #expect(p.snapping == !before)
        _ = p.setSnapInverted(false)
        #expect(p.snapping == before)
    }

    @Test func trackHeightsAreKeptPerSequence() throws {
        let defaults = try #require(UserDefaults(suiteName: "sq.test.trackHeights.\(UUID().uuidString)"))
        let store = TrackHeightStore(defaults: defaults)
        var (p, s, _, _) = setup()
        p.heightStore = store
        let id = p.timeline.tracks[0].id
        let row = p.rows[0]
        // Header double-click toggles the row height and keeps it.
        let y = Float(row.y + row.height / 2)
        // A spot of the header that is not a button (the Mac header's background).
        let hx = try #require(stride(from: CGFloat(2), to: TimelineGeometry.contentOriginX, by: 2).first { x in
            p.headerHit(CGPoint(x: x, y: CGFloat(y))) == nil && p.geometry.hitTest(CGPoint(x: x, y: CGFloat(y)), in: p.timeline) == .header(row.track) })
        let x = Float(hx)
        _ = p.handle(.mouseDown(x: x, y: y, modifiers: []))
        _ = p.handle(.mouseUp(x: x, y: y))
        _ = p.handle(.mouseDown(x: x, y: y, modifiers: []))
        _ = p.handle(.mouseUp(x: x, y: y))
        let kept = store.load(p.timeline.id)
        #expect(kept[id] != nil)
        // A fresh panel on the same sequence starts with the kept heights.
        var q = TimelinePanel()
        q.heightStore = store
        q.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
        q.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        #expect(q.geometry.heightOverrides == kept)
    }
}

@MainActor @Suite struct TimelineSpeedCommandTests {
    @Test func showTimeRemappingTogglesTheBandOnTheSelection() {
        var (p, s, host, _) = setup()
        #expect(p.runSpeedCommand(.toggleTimeRemapping, session: s) == "Select a video clip first.")
        s.select(clips: [host])
        #expect(p.runSpeedCommand(.toggleTimeRemapping, session: s) == "")
        #expect(p.speedBandClips == [host])
        #expect(p.runSpeedCommand(.toggleTimeRemapping, session: s) == "")
        #expect(p.speedBandClips.isEmpty)
        #expect(p.runSpeedCommand(.playPause, session: s) == nil)
    }
}

@MainActor @Suite struct TimelineSlipTwoUpTests {
    @Test func slipDragShowsTheTwoUpAndHidesItOnRelease() {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: fd * 50, duration: fd * 100), start: .zero)
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])]))
        var p = TimelinePanel()
        p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
        p.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        p.toolState.tool = .slip
        let row = p.rows[0], y = Float(row.y + row.height / 2), x = Float(p.geometry.x(for: fd * 50))
        _ = p.handle(.mouseDown(x: x, y: y, modifiers: []))
        let shown = p.handle(.mouseDragged(x: x + 40, y: y))
        #expect(shown.contains { if case .slipTwoUp(let two?, _) = $0 { two.clip == c.id } else { false } })
        let host = TimelineHost()
        var seen: [SlipTwoUp?] = []
        host.slipTwoUp = { two, _ in seen.append(two) }
        for a in shown { _ = TimelineSessionBridge.apply(a, to: s, host: host) }
        #expect(seen.count == 1 && seen[0] != nil)
        let up = p.handle(.mouseUp(x: x + 40, y: y))
        #expect(up.contains { if case .slipTwoUp(nil, _) = $0 { true } else { false } })
    }
}

@MainActor @Suite struct TimelineDropTests {
    @Test func mediaDropShowsTheGhostAndPlacesTheMediaAsOneUndoStep() throws {
        let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: fd, isVariableFrameRate: false)
        let m = MediaRef(name: "a", path: "/nonexistent/a.mov", fingerprint: MediaFingerprint(size: 1),
                         duration: fd * 50, info: MediaInfo(duration: fd * 50, video: v, audio: nil))
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 100), start: .zero)
        var project = Project(name: "P", timelines: [Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])])
        project.media = [m]
        let s = EditorSession(project: project)
        var p = TimelinePanel()
        p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
        p.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        let row = p.rows[0], y = Float(row.y + row.height / 2), x = Float(p.geometry.x(for: fd * 150))
        p.dropHover(items: [DropItem(name: "a", duration: fd * 50)], x: x, y: y, insert: false)
        #expect(!p.dropPreview.ghosts.isEmpty)
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        let a = p.dropCommit(media: [m.id], x: x, y: y, insert: false)
        #expect(!p.dropPreview.isActive)
        let drop = try #require(a.first)
        _ = TimelineSessionBridge.apply(drop, to: s)
        #expect(s.activeTimeline!.tracks[0].clips.count == 2)
        s.undo()
        #expect(s.activeTimeline!.tracks[0].clips.count == 1)
    }
}
