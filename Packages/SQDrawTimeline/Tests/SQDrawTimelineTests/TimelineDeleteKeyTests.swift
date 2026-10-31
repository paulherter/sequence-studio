import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

/// Delete in the shared timeline against the Mac order (`AppController.execute(.delete)`): a selected transition first, then a
/// picked caption word, then a selected gap (ripple close), then the clip selection.
@MainActor @Suite struct TimelineDeleteKeyTests {
    static let fd = Time(1, 25)

    /// A at 0-2 s, a gap, B at 4-6 s on one video track; the gap is selected with a click.
    func gapPanel() -> (TimelinePanel, EditorSession) {
        func clip(_ at: Int64) -> Clip { Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Self.fd * 50), start: Self.fd * at) }
        let t = Timeline(name: "t", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [clip(0), clip(100)])])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        var p = TimelinePanel()
        p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
        p.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        let row = p.rows[0]
        let x = Float(p.geometry.x(for: Time(3, 1))), y = Float(row.y + row.height / 2)
        _ = p.handle(.mouseDown(x: x, y: y, modifiers: []))
        _ = p.handle(.mouseUp(x: x, y: y))
        return (p, s)
    }

    @Test func deleteOnASelectedGapClosesIt() {
        var (p, s) = gapPanel()
        #expect(p.interaction.gapSelection != nil, "the click selected the gap")
        let actions = p.key(.backspace, modifiers: []) ?? []
        #expect(!actions.isEmpty, "Delete on a gap is not swallowed")
        for a in actions { TimelineSessionBridge.apply(a, to: s) }
        let clips = s.activeTimeline!.tracks[0].clips
        #expect(clips.count == 2 && clips[1].timeline.start == clips[0].timeline.end, "B moved up against A")
        #expect(s.undo(), "one undo step")
        #expect(s.activeTimeline!.tracks[0].clips[1].timeline.start == Self.fd * 100)
    }

    @Test func theDeleteCommandFromAMenuClosesTheGapToo() {
        var (p, s) = gapPanel()
        let line = p.runViewCommand(.delete, session: s, host: nil)
        #expect(line != nil, "taken by the timeline")
        let clips = s.activeTimeline!.tracks[0].clips
        #expect(clips[1].timeline.start == clips[0].timeline.end)
    }

    @Test func aSelectedTransitionIsRemovedBeforeTheClipSelection() {
        var (p, s) = gapPanel()
        let id = s.activeTimeline!.tracks[0].clips[0].id
        p.sync(timeline: s.activeTimeline!, selection: [id], playhead: .zero, selectedTransition: UUID(), labels: LabelResolver())
        #expect(p.key(.backspace, modifiers: []) == nil, "the host removes the transition first (the Mac order)")
    }
}
