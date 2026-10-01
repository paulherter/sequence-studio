import CoreGraphics
import Foundation
import SQCore
import Testing
@testable import SQEditorUI

// Round 2, stream timeline-edit: zoom tool maths, autoscroll, axis lock, trim type cycle, marker drag, gestures, session verbs.

private let fd = Time(1, 24)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    // Source starts at `start`, so there is handle before and after for rolls.
    Clip(name: "c\(start)", media: UUID(), kind: kind, source: TimeRange(start: s(start), duration: s(dur)), start: s(start),
         link: link, mediaDuration: s(1000))
}
private func track(_ clips: [Clip], kind: TrackKind = .video) -> Track {
    var t = Track(kind: kind)
    for c in clips { try! t.overwrite(c) }
    return t
}

@Suite struct ZoomToolMathTests {
    private let range = 0.5...2000.0

    @Test func clickZoomsInByOneKeyStepKeepingTheAnchorTime() {
        let r = TimelineZoom.zoomClick(scale: 20, scrollX: 100, anchorX: 300, zoomOut: false, range: range)
        #expect(r.scale == 20 * TimelineZoom.keyStep)
        let before = (300 + 100.0) / 20, after = (300 + r.scrollX) / r.scale
        #expect(abs(before - after) < 1e-9)
    }

    @Test func optionClickZoomsOut() {
        let r = TimelineZoom.zoomClick(scale: 50, scrollX: 400, anchorX: 200, zoomOut: true, range: range)
        #expect(r.scale == 50 / TimelineZoom.keyStep)
        #expect(abs((200 + 400.0) / 50 - (200 + r.scrollX) / r.scale) < 1e-9)
    }

    @Test func clickClampsToTheRangeAndNeverScrollsBelowZero() {
        let top = TimelineZoom.zoomClick(scale: 1900, scrollX: 0, anchorX: 100, zoomOut: false, range: range)
        #expect(top.scale == 2000)
        let out = TimelineZoom.zoomClick(scale: 1, scrollX: 0, anchorX: 0, zoomOut: true, range: range)
        #expect(out.scale == 0.5 && out.scrollX >= 0)
    }

    @Test func marqueeFitsTheDraggedRange() {
        // 10 s..12 s into a 1000 pt viewport: 500 pt/s, the range starts at the left edge.
        let r = TimelineZoom.zoomMarquee(startSeconds: 10, endSeconds: 12, viewport: 1000, range: range)
        #expect(abs(r.scale - 500) < 1e-9)
        #expect(abs(r.scrollX - 10 * 500) < 1e-6)
        // Dragged right to left gives the same result.
        let back = TimelineZoom.zoomMarquee(startSeconds: 12, endSeconds: 10, viewport: 1000, range: range)
        #expect(back.scale == r.scale && back.scrollX == r.scrollX)
    }

    @Test func marqueeAtMaxZoomCentresTheRangeAndNearZeroStaysPositive() {
        let r = TimelineZoom.zoomMarquee(startSeconds: 50, endSeconds: 50.001, viewport: 1000, range: range)
        #expect(r.scale == 2000)
        // The 1 ms range sits in the middle of the 0.5 s window.
        #expect(abs((r.scrollX + 500) / r.scale - 50.0005) < 1e-6)
        let left = TimelineZoom.zoomMarquee(startSeconds: 0, endSeconds: 0.01, viewport: 1000, range: range)
        #expect(left.scrollX == 0)
    }

    @Test func keyStepIsTheSingleFeelConstant() {
        // FEEDBACK-5 #1: one constant drives key presses and Zoom tool clicks. Kept at 2.5 (see TimelineZoom.keyStep).
        #expect(TimelineZoom.keyStep == 2.5)
        // Presses from a one-minute fit (1000 pt wide view, 24 fps) to about one second across the view.
        let fit = 1000.0 / 60
        #expect(TimelineZoom.steps(from: fit, to: 1000) == 5)
    }
}

@Suite struct AutoscrollTests {
    @Test func zeroInTheInterior() {
        for d in stride(from: TimelineAutoscroll.zone, through: 2000, by: 37) { #expect(TimelineAutoscroll.autoscrollSpeed(distanceFromEdge: d) == 0) }
    }

    @Test func monotonicAndCapped() {
        var last: CGFloat = 0
        for d in stride(from: TimelineAutoscroll.zone, through: -400, by: -3) {
            let v = TimelineAutoscroll.autoscrollSpeed(distanceFromEdge: d)
            #expect(v >= last)
            #expect(v <= TimelineAutoscroll.maxSpeed)
            last = v
        }
        #expect(TimelineAutoscroll.autoscrollSpeed(distanceFromEdge: -1000) == TimelineAutoscroll.maxSpeed)
        #expect(TimelineAutoscroll.autoscrollSpeed(distanceFromEdge: 1) > 0)
    }

    @Test func velocityHasTheSideAsSign() {
        #expect(TimelineAutoscroll.velocity(pointerX: 170, viewLeft: 162, viewRight: 1162) < 0)
        #expect(TimelineAutoscroll.velocity(pointerX: 1160, viewLeft: 162, viewRight: 1162) > 0)
        #expect(TimelineAutoscroll.velocity(pointerX: 600, viewLeft: 162, viewRight: 1162) == 0)
        #expect(TimelineAutoscroll.velocity(pointerX: 100, viewLeft: 162, viewRight: 1162) <= -TimelineAutoscroll.maxSpeed / 2)
        // A view too narrow for both zones never scrolls.
        #expect(TimelineAutoscroll.velocity(pointerX: 170, viewLeft: 162, viewRight: 250) == 0)
    }
}

@Suite struct AxisLockTests {
    @Test func firstAxisToReachTheThresholdWinsAndStays() {
        var l = AxisLock()
        #expect(l.update(dx: 2, dy: 1) == nil)
        #expect(l.update(dx: 3, dy: 6) == .vertical)
        #expect(l.update(dx: 90, dy: 6) == .vertical)
        l.reset()
        #expect(l.axis == nil)
        #expect(l.update(dx: 8, dy: 1) == .horizontal)
    }
}

@Suite struct TrimTypeCycleTests {
    private func edit() -> (Timeline, Clip, Clip) {
        let a = clip(0, 4), b = clip(4, 4)
        return (Timeline(name: "t", frameDuration: fd, tracks: [track([a, b])]), a, b)
    }

    @Test func regularRippleRollRegular() {
        let (t, a, b) = edit()
        let tail = EdgeRef(clip: a.id, edge: .tail)
        var sel = EdgeSelection(edges: [tail])
        sel = EdgeEdits.cycled(sel, in: t)
        #expect(sel.ripple && sel.edges == [tail])
        sel = EdgeEdits.cycled(sel, in: t)
        #expect(!sel.ripple && EdgeEdits.isRoll(sel, in: t))
        #expect(Set(sel.edges) == [tail, EdgeRef(clip: b.id, edge: .head)])
        sel = EdgeEdits.cycled(sel, in: t)
        #expect(!sel.ripple && sel.edges == [tail])
    }

    @Test func aLoneEdgeWithoutNeighbourSkipsRolling() {
        let (t, _, b) = edit()
        let tail = EdgeRef(clip: b.id, edge: .tail)
        var sel = EdgeSelection(edges: [tail])
        sel = EdgeEdits.cycled(sel, in: t)
        #expect(sel.ripple)
        sel = EdgeEdits.cycled(sel, in: t)
        #expect(!sel.ripple && sel.edges == [tail])
    }
}

@Suite struct MarkerDragTests {
    private func setup() -> (Timeline, Marker.ID, TimelineGeometry) {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [track([clip(2, 4)])])
        let id = t.addMarker(at: s(1))
        return (t, id, TimelineGeometry(frameDuration: fd, pointsPerSecond: 100))
    }

    @Test func clampsAtZero() {
        let (t, id, g) = setup()
        let r = MarkerDrag.target(time: s(-3), dragging: id, in: t, playhead: nil, snapping: true, geometry: g)
        #expect(r.time == .zero)
        #expect(MarkerDrag.target(time: s(-3), dragging: id, in: t, playhead: nil, snapping: false, geometry: g).time == .zero)
    }

    @Test func snapsToClipEdgesWithinTheThreshold() {
        let (t, id, g) = setup()
        // 8 pt at 100 pt/s = 80 ms; 2.04 s is within it of the clip start at 2 s.
        let r = MarkerDrag.target(time: Time(204, 100), dragging: id, in: t, playhead: nil, snapping: true, geometry: g)
        #expect(r.time == s(2) && r.hit?.kind == .clipEdge)
        let far = MarkerDrag.target(time: Time(260, 100), dragging: id, in: t, playhead: nil, snapping: true, geometry: g)
        #expect(far.hit == nil)
    }

    @Test func withoutSnappingTheFrameGridApplies() {
        let (t, id, g) = setup()
        let r = MarkerDrag.target(time: Time(204, 100), dragging: id, in: t, playhead: nil, snapping: false, geometry: g)
        #expect(r.hit == nil && r.time == Time(204, 100).snapped(to: fd))
    }

    @Test func theDraggedMarkerDoesNotSnapToItself() {
        let (t, id, g) = setup()
        let r = MarkerDrag.target(time: Time(102, 100), dragging: id, in: t, playhead: nil, snapping: true, geometry: g)
        #expect(r.hit == nil || r.hit?.kind != .marker)
    }
}

@Suite struct TimelineGestures2Tests {
    /// 4 pt per frame; one video track and its linked audio track.
    private func rig(_ tracks: [Track]) -> TimelineInteraction {
        var i = TimelineInteraction(timeline: Timeline(name: "t", frameDuration: fd, tracks: tracks),
                                    geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: .selection, snapping: false, linkedSelection: true)
        return i
    }
    private func X(_ f: Double) -> CGFloat { 162 + CGFloat(f) * 4 }

    private func rowY(_ i: TimelineInteraction, _ trackIndex: Int) -> CGFloat {
        let r = i.geometry.rows(for: i.timeline).first { $0.track == i.timeline.tracks[trackIndex].id }!
        return r.y + r.height / 2
    }

    @Test func commandOptionDragInsertsACopyAndKeepsTheOriginal() throws {
        let a = clip(0, 1), b = clip(1, 1)                    // 24-frame clips
        var i = rig([track([a, b])])
        let y = rowY(i, 0)
        i.mouseDown(CGPoint(x: X(10), y: y), modifiers: [])
        i.mouseDragged(CGPoint(x: X(20), y: y), modifiers: [.command, .option])
        i.mouseDragged(CGPoint(x: X(34), y: y), modifiers: [.command, .option])
        let raw_c = i.mouseUp(CGPoint(x: X(34), y: y), modifiers: [.command, .option])
        let c = try #require(raw_c)
        #expect(c.undoName == "Insert Copy")
        let clips = c.timeline.tracks[0].clips
        #expect(clips.contains { $0.id == a.id })
        #expect(clips.count == 3)
        #expect(c.timeline.duration == s(3))                  // b moved back by the copy's length
        #expect(c.selection.count == 1 && !c.selection.contains(a.id))
        if case .insertCopy = c.edits.last {} else { Issue.record("expected an insertCopy edit") }
    }

    @Test func commandAloneStillMovesInsteadOfCopying() throws {
        let a = clip(0, 1), b = clip(1, 1)
        var i = rig([track([a, b])])
        let y = rowY(i, 0)
        i.mouseDown(CGPoint(x: X(10), y: y), modifiers: [])
        i.mouseDragged(CGPoint(x: X(20), y: y), modifiers: [.command])
        i.mouseDragged(CGPoint(x: X(70), y: y), modifiers: [.command])
        let raw_c = i.mouseUp(CGPoint(x: X(70), y: y), modifiers: [.command])
        let c = try #require(raw_c)
        #expect(c.undoName == "Insert Move")
        #expect(c.timeline.tracks[0].clips.count == 2)
    }

    @Test func shiftLocksADragToTheHorizontalAxis() throws {
        let a = clip(0, 1)
        var i = rig([track([a]), track([])])                  // V1 with the clip, V2 empty
        let y1 = rowY(i, 0), y2 = rowY(i, 1)
        i.mouseDown(CGPoint(x: X(10), y: y1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(30), y: y1), modifiers: [.shift])     // horizontal first
        i.mouseDragged(CGPoint(x: X(30), y: y2), modifiers: [.shift])     // now pulled up a track: ignored
        let raw_c = i.mouseUp(CGPoint(x: X(30), y: y2), modifiers: [.shift])
        let c = try #require(raw_c)
        #expect(c.timeline.tracks[0].clips.count == 1 && c.timeline.tracks[1].clips.isEmpty)
        #expect(c.timeline.tracks[0].clips[0].start == fd * 20)
    }

    @Test func shiftLocksADragToTheVerticalAxis() throws {
        let a = clip(0, 1)
        var i = rig([track([a]), track([])])
        let y1 = rowY(i, 0), y2 = rowY(i, 1)
        i.mouseDown(CGPoint(x: X(10), y: y1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(11), y: y2), modifiers: [.shift])     // vertical first
        i.mouseDragged(CGPoint(x: X(40), y: y2), modifiers: [.shift])     // time travel ignored
        let raw_c = i.mouseUp(CGPoint(x: X(40), y: y2), modifiers: [.shift])
        let c = try #require(raw_c)
        #expect(c.timeline.tracks[1].clips.map(\.start) == [.zero])
    }

    @Test func holdingSFlipsSnappingForTheGestureInFlight() throws {
        let a = clip(0, 1), b = clip(3, 1)                    // gap 1 s .. 3 s
        var i = rig([track([a, b])])
        i.toolState.snapping = true
        let y = rowY(i, 0)
        // Drag a so its end lands 2 frames short of b's start: with snapping on it would jump to b.
        i.mouseDown(CGPoint(x: X(10), y: y), modifiers: [])
        i.snapInverted = true
        i.mouseDragged(CGPoint(x: X(10 + 47), y: y), modifiers: [])
        i.mouseDragged(CGPoint(x: X(10 + 47), y: y), modifiers: [])
        let raw_free = i.mouseUp(CGPoint(x: X(10 + 47), y: y), modifiers: [])
        let free = try #require(raw_free)
        #expect(free.timeline.tracks[0].clips[0].start == fd * 47)         // flipped off: no pull
        // The flip resets with the next gesture.
        var j = rig([track([a, b])])
        j.toolState.snapping = true
        j.mouseDown(CGPoint(x: X(10), y: y), modifiers: [])
        j.mouseDragged(CGPoint(x: X(10 + 47), y: y), modifiers: [])
        j.mouseDragged(CGPoint(x: X(10 + 47), y: y), modifiers: [])
        let raw_snapped = j.mouseUp(CGPoint(x: X(10 + 47), y: y), modifiers: [])
        let snapped = try #require(raw_snapped)
        #expect(snapped.timeline.tracks[0].clips[0].start == fd * 48)      // end hits b's start at frame 72
    }

    @Test func inOutMarksAndKeyframesAttractADraggedClip() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [track([clip(0, 1), clip(10, 1)])])
        t.inOut = TimeRange(start: s(4), end: s(6))
        var i = TimelineInteraction(timeline: t, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: .selection, snapping: true, linkedSelection: true)
        let y = rowY(i, 0)
        // Drop the first clip's start 1 frame after the In point (4 s = frame 96).
        i.mouseDown(CGPoint(x: X(10), y: y), modifiers: [])
        i.mouseDragged(CGPoint(x: X(10 + 97), y: y), modifiers: [])
        i.mouseDragged(CGPoint(x: X(10 + 97), y: y), modifiers: [])
        let raw_c = i.mouseUp(CGPoint(x: X(10 + 97), y: y), modifiers: [])
        let c = try #require(raw_c)
        #expect(c.timeline.tracks[0].clips[0].start == s(4))
    }

    @Test func zoomToolIsAvailableAndOnTheZKey() {
        #expect(TimelineTool.zoom.isAvailable)
        #expect(TimelineTool(key: "z") == .zoom)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [track([clip(0, 4)])])
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 40)
        let regions = TimelineCursorMap.regions(timeline: t, geometry: g, tool: .zoom,
                                                content: CGRect(x: 162, y: 22, width: 800, height: 300))
        #expect(regions.count == 1 && regions[0].kind == .zoom)
    }
}

@MainActor @Suite struct TimelineEdit2SessionTests {
    private func session(_ tracks: [Track]) -> EditorSession {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: tracks)
        return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
    }

    @Test func shiftWRollsAndOptWLeavesAGapEachOneUndoStep() {
        let a = clip(0, 10), b = clip(10, 10)
        let ses = session([track([a, b])])
        ses.seek(to: s(7))
        ses.trimToPlayhead(.tail, mode: .roll)
        var spans = ses.activeTimeline!.tracks[0].clips.map { [$0.start, $0.timeline.end] }
        #expect(spans == [[s(0), s(7)], [s(7), s(20)]])
        #expect(ses.undoName == "Roll Trim Next Edit")
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [s(0), s(10)])
        ses.trimToPlayhead(.tail, mode: .plain)
        spans = ses.activeTimeline!.tracks[0].clips.map { [$0.start, $0.timeline.end] }
        #expect(spans == [[s(0), s(7)], [s(10), s(20)]])
        #expect(ses.undo())
        ses.trimToPlayhead(.tail, mode: .ripple)
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [s(0), s(7)])
    }

    @Test func duplicateSelectsTheCopiesAndUndoesInOneStep() {
        let a = clip(0, 4)
        let ses = session([track([a])])
        ses.select(clips: [a.id])
        ses.duplicateSelection()
        let clips = ses.activeTimeline!.tracks[0].clips
        #expect(clips.count == 2 && clips[1].start == s(4))
        #expect(ses.selection == [clips[1].id])
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[0].clips.count == 1)
    }

    @Test func enableTogglesAndNamesTheStep() {
        let a = clip(0, 4)
        let ses = session([track([a])])
        ses.select(clips: [a.id])
        ses.toggleEnabledSelection()
        #expect(ses.activeTimeline!.tracks[0].clips[0].isEnabled == false)
        #expect(ses.undoName == "Disable Clip")
        ses.toggleEnabledSelection()
        #expect(ses.activeTimeline!.tracks[0].clips[0].isEnabled)
        #expect(ses.undoName == "Enable Clip")
    }

    @Test func laneMoveReportsABlockedLane() {
        let a = clip(0, 4)
        let ses = session([track([a]), track([])])
        ses.select(clips: [a.id])
        #expect(ses.moveSelectionLane(up: true))
        #expect(ses.activeTimeline!.tracks[1].clips.count == 1)
        #expect(!ses.moveSelectionLane(up: true))
        #expect(ses.moveSelectionLane(up: false))
    }

    @Test func markerMoveIsOneUndoStep() {
        var t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [track([clip(0, 10)])])
        let id = t.addMarker(at: s(2))
        let ses = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        ses.moveMarker(id, to: s(5))
        #expect(ses.activeTimeline!.markers[0].time == s(5))
        #expect(ses.undo())
        #expect(ses.activeTimeline!.markers[0].time == s(2))
    }

    @Test func targetModifiersGoThroughOneStep() {
        let ses = session([track([]), track([])])
        let ids = ses.activeTimeline!.tracks.map(\.id)
        ses.toggleTarget(ids[0], shift: true, option: false)
        #expect(ses.activeTimeline!.tracks.allSatisfy { $0.isTargeted })
        ses.toggleTarget(ids[1], shift: false, option: true)
        #expect(ses.activeTimeline!.tracks.map(\.isTargeted) == [false, true])
    }
}

@Suite struct Round2CommandMapTests {
    @Test func noDuplicateBindingsAndTheNewKeysResolve() {
        let m = CommandMap.premiereDefault
        #expect(m.duplicates.isEmpty)
        func cmd(_ k: Key, _ mod: KeyModifiers, _ scope: PanelID? = .timeline) -> EditorCommand? {
            m.command(for: KeyBinding(k, mod), focus: scope)
        }
        #expect(cmd(.char("q"), []) == .rippleTrimPrevious && cmd(.char("w"), []) == .rippleTrimNext)
        #expect(cmd(.char("q"), .shift) == .rollTrimPrevious && cmd(.char("w"), .shift) == .rollTrimNext)
        #expect(cmd(.char("q"), .option) == .trimPrevious && cmd(.char("w"), .option) == .trimNext)
        #expect(cmd(.char("t"), .control) == .toggleTrimType)
        #expect(cmd(.up, .option) == .moveSelectionUp && cmd(.down, .option) == .moveSelectionDown)
        #expect(cmd(.char("e"), [.command, .shift]) == .enableClip)
        #expect(cmd(.char("/"), [.command, .shift]) == .duplicate)
        #expect(cmd(.char("e"), .shift) == .exportFrame)
        // Cmd+D belongs to transitions: not bound here.
        #expect(cmd(.char("d"), .command) == nil)
    }

    @Test func everyNewCommandHasATitle() {
        for c in [EditorCommand.rollTrimPrevious, .rollTrimNext, .trimPrevious, .trimNext, .enableClip, .duplicate,
                  .toggleTrimType, .moveSelectionUp, .moveSelectionDown] {
            #expect(!c.title.isEmpty)
        }
    }
}
