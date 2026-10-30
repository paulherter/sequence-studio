import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

/// MON-30: the patch column appears with a loaded source; chips sit on the patched tracks; a drag resolves the row.
@MainActor @Suite struct SourcePatchHeaderTests {
    private func view() -> TimelineView {
        TimelineView(timeline: Timeline(name: "t", frameDuration: Time(1, 24), tracks: Timeline.defaultTracks()),
                     frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
    }

    @Test func noSourceNoColumn() {
        let v = view()
        for t in v.timeline.tracks { #expect(v.headerView(for: t.id)?.patch.column == false) }
        #expect(v.patchColumnOffset == 0)
    }

    @Test func chipsFollowThePatch() {
        let v = view()
        let video = v.timeline.tracks.filter { $0.kind == .video }.map(\.id)
        let audio = v.timeline.tracks.filter { $0.kind == .audio }.map(\.id)
        var p = SourcePatch()
        p.patch(.video, to: video[1], in: v.timeline)
        p.toggleConnection(.audio)
        v.sourcePatch = p
        #expect(v.headerView(for: video[0])?.patch.column == true)
        #expect(v.headerView(for: video[0])?.patch.chip == nil)
        #expect(v.headerView(for: video[1])?.patch.chip?.kind == .video)
        #expect(v.headerView(for: video[1])?.patch.chip?.connected == true)
        #expect(v.headerView(for: audio[0])?.patch.chip?.connected == false)   // off, still shown where it was
        v.sourcePatchStreams = [.video]
        #expect(v.headerView(for: audio[0])?.patch.chip == nil)
        v.sourcePatch = nil
        #expect(v.headerView(for: video[1])?.patch.column == false)
    }

    @Test func dragResolvesTheRowOfTheSameKind() {
        let v = view()
        v.sourcePatch = SourcePatch()
        var moved: (TrackKind, Track.ID)?
        v.onSourcePatchMove = { moved = ($0, $1) }
        let rows = v.layoutRows()
        let v3 = rows.first { $0.label == "V3" }!, a2 = rows.first { $0.label == "A2" }!
        let x = TimelineGeometry.toolColumnWidth + 10
        func window(_ y: CGFloat) -> NSPoint { v.convert(NSPoint(x: x, y: y), to: nil) }
        v.patchDragged(.video, window: window(v3.y + 2), ended: false)
        #expect(v.patchDropTrack == v3.track)
        v.patchDragged(.video, window: window(a2.y + 2), ended: false)          // audio row: no target for video
        #expect(v.patchDropTrack == nil)
        v.patchDragged(.audio, window: window(a2.y + 2), ended: true)
        #expect(moved?.0 == .audio && moved?.1 == a2.track)
        #expect(v.patchDropTrack == nil)
    }

    @Test func shiftDragReportsTheBothVariant() {
        let v = view()
        v.sourcePatch = SourcePatch()
        var both: (TrackKind, Track.ID)?, single = false
        v.onSourcePatchMove = { _, _ in single = true }
        v.onSourcePatchMoveBoth = { both = ($0, $1) }
        let v2 = v.layoutRows().first { $0.label == "V2" }!
        let p = v.convert(NSPoint(x: TimelineGeometry.toolColumnWidth + 10, y: v2.y + 2), to: nil)
        v.patchDragged(.video, window: p, ended: true, both: true)
        #expect(both?.1 == v2.track && !single)
    }
}
