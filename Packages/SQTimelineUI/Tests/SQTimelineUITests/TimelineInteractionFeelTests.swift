#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 24)
private func X(_ f: Double) -> CGFloat { TimelineGeometry.contentOriginX + CGFloat(f) * 4 }

private func mk(_ start: Int64, _ frames: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: fd * 50, duration: fd * frames),
         start: fd * start, mediaDuration: fd * 200)
}

private func interaction(snapping: Bool = false) -> TimelineInteraction {
    let t = Timeline(name: "t", frameDuration: fd,
                     tracks: [Track(kind: .video, clips: [mk(20, 20), mk(60, 20)]), Track(kind: .video)])
    var i = TimelineInteraction(timeline: t, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
    i.toolState = ToolState(tool: .razor, snapping: snapping, linkedSelection: true)
    return i
}

@Suite struct TimelineInteractionFeelTests {
    @Test func selectedGapIsADeleteTarget() {
        var i = interaction()
        i.toolState = ToolState(tool: .selection, snapping: false, linkedSelection: true)
        #expect(!i.hasDeleteTarget)
        i.mouseDown(CGPoint(x: X(10), y: 70), modifiers: [])
        i.mouseUp(CGPoint(x: X(10), y: 70), modifiers: [])
        #expect(i.gapSelection != nil)
        #expect(i.hasDeleteTarget)
    }

    @Test func razorCutTimeIsTheFrameUnderThePointer() {
        let i = interaction()
        #expect(i.razorCutTime(atX: X(30)) == fd * 30)
    }

    @Test func razorGuideSpansOneRowOrAllRows() {
        let rows = [TrackRow(track: UUID(), kind: .video, label: "V2", y: 22, height: 40),
                    TrackRow(track: UUID(), kind: .video, label: "V1", y: 62, height: 40)]
        let one = RazorGuide.rect(x: 200, pointerY: 80, allTracks: false, rows: rows)
        #expect(one == CGRect(x: 199.5, y: 62, width: 1, height: 40))
        let all = RazorGuide.rect(x: 200, pointerY: 80, allTracks: true, rows: rows)
        #expect(all == CGRect(x: 199.5, y: 22, width: 1, height: 80))
        #expect(RazorGuide.rect(x: 200, pointerY: 5, allTracks: false, rows: rows) == nil)
    }
}

@MainActor @Suite struct RazorGuideTests {
    private func linkedTimeline() -> Timeline {
        let link = UUID()
        var v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: fd * 50, duration: fd * 20), start: fd * 20, mediaDuration: fd * 200)
        var a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: fd * 50, duration: fd * 20), start: fd * 20, mediaDuration: fd * 200)
        v.link = link; a.link = link
        return Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [v]), Track(kind: .video), Track(kind: .audio, clips: [a])])
    }

    private func view() -> TimelineView {
        let v = TimelineView(timeline: linkedTimeline(), frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        v.layoutSubtreeIfNeeded()
        return v
    }

    @Test func guideCoversLinkedPartnersAndSkipsEmptyLanes() {
        let i = TimelineInteraction(timeline: linkedTimeline(), geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        let v = i.timeline.tracks[0].id, empty = i.timeline.tracks[1].id, a = i.timeline.tracks[2].id
        let rows = i.geometry.rows(for: i.timeline)
        func row(_ id: UUID) -> TrackRow { rows.first { $0.track == id }! }
        let overClip = CGPoint(x: X(30), y: row(v).y + 5)
        #expect(Set(i.razorGuideTracks(at: overClip, shift: false)) == [v, a])
        #expect(i.razorGuideTracks(at: overClip, shift: false, option: true) == [v])
        #expect(i.razorGuideTracks(at: CGPoint(x: X(30), y: row(empty).y + 5), shift: false).isEmpty)      // empty lane
        #expect(i.razorGuideTracks(at: CGPoint(x: X(70), y: row(v).y + 5), shift: false).isEmpty)      // past the clip
        #expect(Set(i.razorGuideTracks(at: CGPoint(x: X(70), y: row(empty).y + 5), shift: true)) == [v, empty, a])
        let segs = RazorGuide.rects(x: 200, tracks: [v, a], rows: rows)
        #expect(segs.count == 1)                       // V1 + A1 are adjacent: one line, the empty V2 above stays free
        #expect(segs[0].minY == row(v).y && segs[0].maxY == row(a).maxY)
        #expect(RazorGuide.rects(x: 200, tracks: [empty], rows: rows).count == 1)
    }

    @Test func guideIsSeededFromThePointerWhenTheToolIsSelected() {
        let v = view()
        let row = v.layoutRows().first { $0.track == v.timeline.tracks[0].id }!
        let p = CGPoint(x: v.geometry.x(for: fd * 30), y: row.y + 5)
        v.pointerProvider = { p }
        #expect(v.razorGuideRects.isEmpty)
        v.toolState = ToolState(tool: .razor, snapping: false, linkedSelection: true)      // no mouse move after this
        #expect(!v.razorGuideRects.isEmpty)
        #expect(v.razorGuideRects.allSatisfy { abs($0.midX - v.geometry.x(for: v.interaction.razorCutTime(atX: p.x))) <= 1 })
        // scrolling without a mouse move (playback follow) must not leave the line at the old x
        v.scroll(byX: 40, y: 0)
        let expected = v.geometry.x(for: v.interaction.razorCutTime(atX: p.x))
        #expect(v.razorGuideRects.allSatisfy { abs($0.midX - expected) <= 1 })
        v.toolState = ToolState(tool: .selection, snapping: false, linkedSelection: true)
        #expect(v.razorGuideRects.isEmpty)
    }
}

@MainActor @Suite struct PlaybackContinuityTests {
    private func session() -> EditorSession {
        var t = Track(kind: .video)
        try! t.overwrite(Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero))
        let tl = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [t])
        return EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine())
    }

    @Test func cutSeekAndSelectionDoNotStopPlayback() {
        let ses = session()
        ses.playPause()
        #expect(ses.isPlaying)
        ses.seek(to: Time(3, 1))
        ses.addEditAtPlayhead()
        ses.select(clips: [])
        #expect(ses.activeTimeline!.tracks[0].clips.count == 2)
        #expect(ses.isPlaying)
    }
}
