import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

/// A 1000 x 400 pt panel with V1, V2, A1 and a source with video and audio loaded.
@MainActor private func setup() -> (TimelinePanel, EditorSession) {
    let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 50), start: .zero)
    let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio, clips: [a])])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    p.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
    p.sourcePatchStreams = [.video, .audio]
    return (p, s)
}

private func center(_ p: TimelinePanel, _ track: Track.ID) -> CGPoint {
    let row = p.rows.first { $0.track == track }!
    let r = TimelinePanel.patchRect(height: row.height)
    return CGPoint(x: TimelineGeometry.toolColumnWidth + r.midX, y: row.y + r.midY)
}

private func ev(_ e: (Float, Float) -> InputEvent, _ q: CGPoint) -> InputEvent { e(Float(q.x), Float(q.y)) }

@MainActor @Suite struct SourcePatchTests {
    @Test func chipsSitOnThePatchedTracksAndShiftTheTargetChip() {
        var (p, s) = setup()
        let t = s.activeTimeline!
        #expect(p.patchChip(for: t.tracks[0].id)?.kind == .video)     // V1 by default
        #expect(p.patchChip(for: t.tracks[2].id)?.kind == .audio)
        #expect(p.patchChip(for: t.tracks[1].id) == nil)
        let row = p.rows.first { $0.track == t.tracks[0].id }!
        #expect(p.targetChipRect(height: row.height).minX == TimelinePanel.patchRect(height: row.height).maxX + TimelinePanel.patchGap)
        p.sourcePatchStreams = [.audio]                                  // a sound file: no video chip
        #expect(p.patchChip(for: t.tracks[0].id) == nil)
        p.sourcePatchStreams = nil                                       // nothing in the Source view: no column
        #expect(p.patchChip(for: t.tracks[2].id) == nil)
        #expect(p.targetChipRect(height: row.height) == TimelinePanel.chipRect(height: row.height))
        var list = DrawList(width: 1000, height: 400)
        p.sourcePatchStreams = [.video, .audio]
        p.draw(into: &list, atlas: nil)
        #expect(!list.quads.isEmpty)
    }

    @Test func clickTogglesOptionSolosAndADragPatchesElsewhere() {
        var (p, s) = setup()
        let t = s.activeTimeline!
        let v1 = center(p, t.tracks[0].id), v2 = center(p, t.tracks[1].id), a1 = center(p, t.tracks[2].id)

        #expect(p.handle(.mouseDown(x: Float(v1.x), y: Float(v1.y), modifiers: [])).isEmpty)
        let click = p.handle(ev(TimelineEvents.up, v1))
        #expect(click == [.sourcePatchClick(.video, solo: false)])
        for a in click { TimelineSessionBridge.apply(a, to: s, host: nil) }
        #expect(s.sourcePatch.video.isConnected == false)
        p.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        #expect(p.patchChip(for: t.tracks[0].id)?.connected == false)  // off, still shown where it was

        _ = p.handle(.mouseDown(x: Float(a1.x), y: Float(a1.y), modifiers: [.option]))
        #expect(p.handle(ev(TimelineEvents.up, a1)) == [.sourcePatchClick(.audio, solo: true)])

        _ = p.handle(.mouseDown(x: Float(v1.x), y: Float(v1.y), modifiers: [.shift]))
        _ = p.handle(ev(TimelineEvents.drag, v2))
        #expect(p.patchDropTrack == t.tracks[1].id)
        let moved = p.handle(ev(TimelineEvents.up, v2))
        #expect(moved == [.sourcePatchMove(.video, to: t.tracks[1].id, both: true)])
        #expect(p.patchDropTrack == nil)
        for a in moved { TimelineSessionBridge.apply(a, to: s, host: nil) }
        #expect(s.sourcePatch.video == SourcePatchSlot(track: t.tracks[1].id, isConnected: true))

        p.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        #expect(p.patchChip(for: t.tracks[1].id)?.kind == .video)
        _ = p.handle(.mouseDown(x: Float(v2.x), y: Float(v2.y), modifiers: []))
        _ = p.handle(ev(TimelineEvents.drag, a1))                      // the other kind's row: no target
        #expect(p.patchDropTrack == nil)
        #expect(p.handle(ev(TimelineEvents.up, a1)).isEmpty)
    }
}

private enum TimelineEvents {
    static func up(_ x: Float, _ y: Float) -> InputEvent { .mouseUp(x: x, y: y) }
    static func drag(_ x: Float, _ y: Float) -> InputEvent { .mouseDragged(x: x, y: y) }
}
