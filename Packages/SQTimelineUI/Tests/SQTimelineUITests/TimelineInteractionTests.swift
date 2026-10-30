#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 24)
private let link = UUID()

/// 4 pt per frame: frame f is at x = contentOriginX (124) + 4 f. Rows: V2 y22..<42, V1 42..<74, A1 74..<100, A2 100..<120.
private func X(_ f: Double) -> CGFloat { TimelineGeometry.contentOriginX + CGFloat(f) * 4 }
private let yV2: CGFloat = 42, yV1: CGFloat = 82, yA1: CGFloat = 116, yA2: CGFloat = 144

private func mk(_ start: Int64, _ frames: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: fd * 50, duration: fd * frames),
         start: fd * start, link: link, mediaDuration: fd * 200)
}

private struct Fixture {
    var c1 = mk(0, 20, link: link)            // V1, linked to a1
    var c2 = mk(20, 20)                       // V1, adjacent to c1
    var c3 = mk(60, 20)                       // V1
    var a1 = mk(0, 20, kind: .audio, link: link)
    var a2c = mk(10, 10, kind: .audio)        // A2, unlinked
    var v1: Track, v2: Track, aT1: Track, aT2: Track

    init() {
        v1 = Track(kind: .video, clips: [c1, c2, c3])
        v2 = Track(kind: .video)
        aT1 = Track(kind: .audio, clips: [a1])
        aT2 = Track(kind: .audio, clips: [a2c])
    }

    var timeline: Timeline { Timeline(name: "t", frameDuration: fd, tracks: [v1, v2, aT1, aT2]) }

    func interaction(_ tool: TimelineTool = .selection, snapping: Bool = false, linked: Bool = true,
                     playhead: Time? = nil) -> TimelineInteraction {
        var i = TimelineInteraction(timeline: timeline, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: tool, snapping: snapping, linkedSelection: linked)
        i.playhead = playhead
        return i
    }
}

private func clip(_ t: Timeline, _ id: Clip.ID) -> Clip? { t.tracks.lazy.compactMap { $0.clips.first { $0.id == id } }.first }

private func drag(_ i: inout TimelineInteraction, from a: CGPoint, to b: CGPoint,
                  _ m: GestureModifiers = []) -> TimelineCommit? {
    i.mouseDown(a, modifiers: m)
    i.mouseDragged(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), modifiers: m)
    i.mouseDragged(b, modifiers: m)
    return i.mouseUp(b, modifiers: m)
}

private func click(_ i: inout TimelineInteraction, _ p: CGPoint, _ m: GestureModifiers = []) -> TimelineCommit? {
    i.mouseDown(p, modifiers: m)
    return i.mouseUp(p, modifiers: m)
}

@Suite struct TimelineInteractionTests {
    // MARK: Selection

    @Test func clickSelectsLinkedGroup() {
        let f = Fixture()
        var i = f.interaction()
        #expect(click(&i, CGPoint(x: X(10), y: yV1)) == nil)
        #expect(i.selection == [f.c1.id, f.a1.id])
    }

    /// Monitor tools (Mask, Create, ...) act as Selection in the timeline (2026-10-11): same click selection, same drag.
    @Test func monitorToolsActLikeSelectionInTheTimeline() {
        let f = Fixture()
        for tool in [TimelineTool.mask, .type] {
            var i = f.interaction(tool)
            var s = f.interaction(.selection)
            #expect(click(&i, CGPoint(x: X(30), y: yV1)) == nil)
            #expect(click(&s, CGPoint(x: X(30), y: yV1)) == nil)
            #expect(i.selection == s.selection && i.selection == [f.c2.id])
            let a = drag(&i, from: CGPoint(x: X(30), y: yV1), to: CGPoint(x: X(50), y: yV1))
            let b = drag(&s, from: CGPoint(x: X(30), y: yV1), to: CGPoint(x: X(50), y: yV1))
            #expect(a != nil && a?.undoName == b?.undoName && a?.selection == b?.selection && a?.edits == b?.edits, "\(tool)")
        }
    }

    /// A bundle (Opt+Cmd+G) selects together with linked selection on, like a link group; Option-click picks one clip.
    @Test func clickSelectsTheBundle() {
        var f = Fixture()
        let b = UUID()
        f.c3.bundle = b
        f.a2c.bundle = b
        f.v1 = Track(kind: .video, clips: [f.c1, f.c2, f.c3])
        f.aT2 = Track(kind: .audio, clips: [f.a2c])
        var i = f.interaction()
        _ = click(&i, CGPoint(x: X(70), y: yV1))
        #expect(i.selection == [f.c3.id, f.a2c.id])
        var j = f.interaction()
        _ = click(&j, CGPoint(x: X(70), y: yV1), .option)
        #expect(j.selection == [f.c3.id])
        var k = f.interaction(linked: false)
        _ = click(&k, CGPoint(x: X(70), y: yV1))
        #expect(k.selection == [f.c3.id])
    }

    @Test func optionInvertsLinkedSelectionAndToggleOffWorks() {
        let f = Fixture()
        var i = f.interaction()
        _ = click(&i, CGPoint(x: X(10), y: yV1), .option)
        #expect(i.selection == [f.c1.id])
        var j = f.interaction(linked: false)
        _ = click(&j, CGPoint(x: X(10), y: yV1))
        #expect(j.selection == [f.c1.id])
        _ = click(&j, CGPoint(x: X(10), y: yV1), .option)        // option turns linking on
        #expect(j.selection == [f.c1.id, f.a1.id])
    }

    @Test func shiftClickTogglesAndGapClickClears() {
        let f = Fixture()
        var i = f.interaction(linked: false)
        _ = click(&i, CGPoint(x: X(25), y: yV1))
        _ = click(&i, CGPoint(x: X(70), y: yV1), .shift)
        #expect(i.selection == [f.c2.id, f.c3.id])
        _ = click(&i, CGPoint(x: X(25), y: yV1), .shift)
        #expect(i.selection == [f.c3.id])
        _ = click(&i, CGPoint(x: X(50), y: yV1))                  // gap
        #expect(i.selection.isEmpty)
    }

    @Test func clickInsideMultiSelectionWithoutDragReducesToThatClip() {
        let f = Fixture()
        var i = f.interaction(linked: false)
        _ = click(&i, CGPoint(x: X(25), y: yV1))
        _ = click(&i, CGPoint(x: X(70), y: yV1), .shift)
        _ = click(&i, CGPoint(x: X(25), y: yV1))
        #expect(i.selection == [f.c2.id])
    }

    @Test func marqueePicksUpCaptionsInsideTheRectangle() {
        var f = Fixture()
        f.v1 = Track(kind: .video, clips: [f.c1, f.c3])
        var tl = f.timeline
        let early = CaptionItem(lines: ["a"], range: TimeRange(start: fd * 2, end: fd * 10))
        let late = CaptionItem(lines: ["b"], range: TimeRange(start: fd * 70, end: fd * 78))
        tl.captionTracks = [CaptionTrack(items: [early, late])]
        let geo = TimelineGeometry(frameDuration: fd, pointsPerFrame: 4)
        var i = TimelineInteraction(timeline: tl, geometry: geo)
        i.toolState = ToolState(tool: .selection, snapping: false, linkedSelection: false)
        let row = geo.captionRows(for: tl)[0]
        let yC = row.y + row.height / 2
        let yClip = geo.rows(for: tl).first { $0.track == f.v1.id }!.y + 4
        // From below the first video clip up through the caption row: the early caption and the clip are in, the late one is out.
        i.mouseDown(CGPoint(x: X(40), y: yClip + 6), modifiers: [])
        i.mouseDragged(CGPoint(x: X(1), y: yC), modifiers: [])
        #expect(i.captionSelection == [early.id])
        #expect(i.selection == [f.c1.id])
        _ = i.mouseUp(CGPoint(x: X(1), y: yC), modifiers: [])
        // Shift keeps the earlier caption selection and adds the late one.
        i.mouseDown(CGPoint(x: X(90), y: yC), modifiers: .shift)
        i.mouseDragged(CGPoint(x: X(65), y: yC + 2), modifiers: .shift)
        #expect(i.captionSelection == [early.id, late.id])
        _ = i.mouseUp(CGPoint(x: X(65), y: yC + 2), modifiers: .shift)
    }

    /// Option on a marquee flips Linked Selection for that sweep: the partner stays out (and with it off, comes in).
    @Test func optionMarqueeLeavesLinkedPartnersOut() {
        let f = Fixture()
        var i = f.interaction(linked: true)
        i.mouseDown(CGPoint(x: X(85), y: yV2), modifiers: [.option])
        i.mouseDragged(CGPoint(x: X(15), y: yV1), modifiers: [.option])
        _ = i.mouseUp(CGPoint(x: X(15), y: yV1), modifiers: [.option])
        #expect(i.selection == [f.c1.id, f.c2.id, f.c3.id])
    }

    @Test func marqueeSelectsIntersectingClipsAndShiftExtends() {
        let f = Fixture()
        var i = f.interaction(linked: false)
        i.mouseDown(CGPoint(x: X(85), y: yV2), modifiers: [])
        i.mouseDragged(CGPoint(x: X(15), y: yV1), modifiers: [])
        #expect(i.marquee != nil)
        #expect(i.selection == [f.c1.id, f.c2.id, f.c3.id])
        #expect(i.mouseUp(CGPoint(x: X(15), y: yV1), modifiers: []) == nil)
        #expect(i.marquee == nil)
        // Linked selection pulls the partner in.
        var j = f.interaction(linked: true)
        j.mouseDown(CGPoint(x: X(85), y: yV2), modifiers: [])
        j.mouseDragged(CGPoint(x: X(15), y: yV1), modifiers: [])
        _ = j.mouseUp(CGPoint(x: X(15), y: yV1), modifiers: [])
        #expect(j.selection == [f.c1.id, f.c2.id, f.c3.id, f.a1.id])
        // Shift keeps the old selection.
        var k = f.interaction(linked: false)
        _ = click(&k, CGPoint(x: X(10), y: yV1))
        k.mouseDown(CGPoint(x: X(55), y: yV2), modifiers: .shift)
        k.mouseDragged(CGPoint(x: X(85), y: yV1), modifiers: .shift)
        _ = k.mouseUp(CGPoint(x: X(85), y: yV1), modifiers: .shift)
        #expect(k.selection == [f.c1.id, f.c3.id])
    }

    // MARK: Move

    @Test func moveProducesPreviewThenOneCommit() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(25), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(30), y: yV1), modifiers: [])
        #expect(clip(i.preview, f.c2.id)?.start == fd * 25)
        #expect(clip(i.timeline, f.c2.id)?.start == fd * 20)       // base untouched while dragging
        let raw_c = i.mouseUp(CGPoint(x: X(30), y: yV1), modifiers: [])
        let c = try #require(raw_c)
        #expect(c.undoName == "Move Clip")
        #expect(clip(c.timeline, f.c2.id)?.start == fd * 25)
        #expect(clip(i.timeline, f.c2.id)?.start == fd * 25)
        #expect(c.edits == [.move(f.c2.id, to: fd * 25, track: nil)])
    }

    @Test func movedSelectionKeepsRelativeOffsets() throws {
        let f = Fixture()
        var i = f.interaction(linked: false)
        _ = click(&i, CGPoint(x: X(25), y: yV1))
        _ = click(&i, CGPoint(x: X(70), y: yV1), .shift)
        let raw_c = drag(&i, from: CGPoint(x: X(25), y: yV1), to: CGPoint(x: X(35), y: yV1))
        let c = try #require(raw_c)
        #expect(c.undoName == "Move Clips")
        #expect(clip(c.timeline, f.c2.id)?.start == fd * 30)
        #expect(clip(c.timeline, f.c3.id)?.start == fd * 70)
    }

    @Test func moveClampsAtZero() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw_c = drag(&i, from: CGPoint(x: X(25), y: yV1), to: CGPoint(x: X(-50), y: yV1))
        let c = try #require(raw_c)
        #expect(clip(c.timeline, f.c2.id)?.start == .zero)
    }

    @Test func moveSnapsClipEndToNeighbourStart() throws {
        let f = Fixture()
        var on = f.interaction(snapping: true)
        let raw_c = drag(&on, from: CGPoint(x: X(25), y: yV1), to: CGPoint(x: X(44), y: yV1))
        let c = try #require(raw_c)
        #expect(clip(c.timeline, f.c2.id)?.start == fd * 40)                                            // end on 60
        var off = f.interaction(snapping: false)
        let raw_d = drag(&off, from: CGPoint(x: X(25), y: yV1), to: CGPoint(x: X(44), y: yV1))
        let d = try #require(raw_d)
        #expect(clip(d.timeline, f.c2.id)?.start == fd * 39)
    }

    @Test func moveSnapsToPlayheadAndReportsSnapTime() {
        let f = Fixture()
        var i = f.interaction(snapping: true, playhead: fd * 100)
        i.mouseDown(CGPoint(x: X(65), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(84), y: yV1), modifiers: [])      // c3 start 79 -> end 99 snaps to playhead 100
        #expect(i.snapTime == fd * 100)
        #expect(clip(i.preview, f.c3.id)?.start == fd * 80)
        _ = i.mouseUp(CGPoint(x: X(84), y: yV1), modifiers: [])
        #expect(i.snapTime == nil)
    }

    @Test func crossTrackMoveOntoOtherVideoTrack() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw_c = drag(&i, from: CGPoint(x: X(25), y: yV1), to: CGPoint(x: X(25), y: yV2))
        let c = try #require(raw_c)
        #expect(c.timeline.tracks[1].clips.map(\.id) == [f.c2.id])
        #expect(c.timeline.tracks[0].clips.map(\.id) == [f.c1.id, f.c3.id])
    }

    @Test func videoClipDraggedOverAudioRowsStaysOnVideo() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(65), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(70), y: yA2), modifiers: [])
        let raw_c = i.mouseUp(CGPoint(x: X(70), y: yA2), modifiers: [])
        let c = try #require(raw_c)
        #expect(c.timeline.tracks.count == 4)
        #expect(c.timeline.tracks[0].clips.contains { $0.id == f.c3.id })   // nearest video row is V1
    }

    @Test func dragAboveTopTrackAddsVideoTrack() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(65), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(65), y: 4), modifiers: [])
        #expect(i.preview.tracks.count == 5)
        let raw_c = i.mouseUp(CGPoint(x: X(65), y: 4), modifiers: [])
        let c = try #require(raw_c)
        #expect(c.timeline.tracks.count == 5)
        let added = c.timeline.tracks[4]
        #expect(added.kind == .video)
        #expect(added.clips.map(\.id) == [f.c3.id])
        #expect(c.undoName == "Move Clip")
        #expect(c.edits.count == 2)
    }

    @Test func dragBelowLastTrackAddsAudioTrack() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw_c = drag(&i, from: CGPoint(x: X(15), y: yA2), to: CGPoint(x: X(15), y: 400))
        let c = try #require(raw_c)
        #expect(c.timeline.tracks.count == 5)
        #expect(c.timeline.tracks[4].kind == .audio)
        #expect(c.timeline.tracks[4].clips.map(\.id) == [f.a2c.id])
        #expect(c.timeline.tracks[3].clips.isEmpty)
    }

    /// A video clip dragged onto the "V+" ghost strip (under the last track) creates a new top video track.
    @Test func dragOntoVideoGhostStripAddsVideoTrack() throws {
        let f = Fixture()
        var i = f.interaction()
        let ghost = i.geometry.ghostRows(for: f.timeline).first { $0.kind == .video }!
        let y = ghost.y + ghost.height / 2
        let raw_c = drag(&i, from: CGPoint(x: X(65), y: yV1), to: CGPoint(x: X(65), y: y))
        let c = try #require(raw_c)
        #expect(c.timeline.tracks.count == 5)
        #expect(c.timeline.tracks[4].kind == .video)
        #expect(c.timeline.tracks[4].clips.map(\.id) == [f.c3.id])
    }

    @Test func dragBackInsideDropsTheNewTrack() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(65), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(65), y: 4), modifiers: [])
        i.mouseDragged(CGPoint(x: X(70), y: yV1), modifiers: [])
        #expect(i.preview.tracks.count == 4)
        let raw_c = i.mouseUp(CGPoint(x: X(70), y: yV1), modifiers: [])
        let c = try #require(raw_c)
        #expect(c.timeline.tracks.count == 4)
    }

    @Test func commandDragIsInsertMove() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw_c = drag(&i, from: CGPoint(x: X(65), y: yV1), to: CGPoint(x: X(25), y: yV1), .command)
        let c = try #require(raw_c)
        #expect(c.undoName == "Insert Move")
        #expect(clip(c.timeline, f.c3.id)?.start == fd * 20)
        #expect(clip(c.timeline, f.c2.id)?.start == fd * 40)     // pushed right
    }

    @Test func movingOntoLockedTrackIsRejected() {
        var f = Fixture()
        f.v1.isLocked = true
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(25), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(35), y: yV1), modifiers: [])
        #expect(i.isRejected)
        #expect(i.preview == i.timeline)
        #expect(i.rejectionMessage == "A selected clip is on a locked track.")      // review finding 4
        #expect(i.mouseUp(CGPoint(x: X(35), y: yV1), modifiers: []) == nil)
        #expect(i.releasedRejection == "A selected clip is on a locked track.")
    }

    @Test func cancelRestoresBase() {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(25), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(35), y: yV1), modifiers: [])
        i.cancel()
        #expect(i.preview == i.timeline)
        #expect(i.mouseUp(CGPoint(x: X(35), y: yV1), modifiers: []) == nil)
    }

    @Test func tinyJitterIsAClickNotAMove() {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(25), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(25) + 2, y: yV1), modifiers: [])
        #expect(i.mouseUp(CGPoint(x: X(25) + 2, y: yV1), modifiers: []) == nil)
    }

    // MARK: Delete

    @Test func deleteLiftsAndShiftDeleteRipples() throws {
        let f = Fixture()
        var i = f.interaction(linked: false)
        _ = click(&i, CGPoint(x: X(25), y: yV1))
        var j = i
        let raw_lift = i.deleteSelection(ripple: false)
        let lift = try #require(raw_lift)
        #expect(lift.undoName == "Delete")
        #expect(lift.timeline.tracks[0].clips.map(\.id) == [f.c1.id, f.c3.id])
        #expect(clip(lift.timeline, f.c3.id)?.start == fd * 60)
        #expect(i.selection.isEmpty)
        let raw_rip = j.deleteSelection(ripple: true)
        let rip = try #require(raw_rip)
        #expect(rip.undoName == "Ripple Delete")
        #expect(clip(rip.timeline, f.c3.id)?.start == fd * 40)
    }

    @Test func deleteWithEmptySelectionDoesNothing() {
        var i = Fixture().interaction()
        #expect(i.deleteSelection(ripple: false) == nil)
    }

    // MARK: Edge trim (selection tool)

    @Test func selectionToolTrimsTailAndHead() throws {
        let f = Fixture()
        var i = f.interaction()
        // c3 tail: x end = X(80); handle 6 pt.
        let raw_t = drag(&i, from: CGPoint(x: X(80) - 1, y: yV1), to: CGPoint(x: X(80) + 19, y: yV1))
        let t = try #require(raw_t)
        #expect(t.undoName == "Trim Clip")
        #expect(clip(t.timeline, f.c3.id)?.timeline.end == fd * 85)
        var j = f.interaction()
        let raw_h = drag(&j, from: CGPoint(x: X(60) + 1, y: yV1), to: CGPoint(x: X(60) + 21, y: yV1))
        let h = try #require(raw_h)
        #expect(clip(h.timeline, f.c3.id)?.start == fd * 65)        // head trim leaves a gap, tail stays
        #expect(clip(h.timeline, f.c3.id)?.timeline.end == fd * 80)
        #expect(clip(h.timeline, f.c3.id)?.timeline.duration == fd * 15)
    }

    @Test func trimSnapsEdgeToNeighbour() throws {
        let f = Fixture()
        var i = f.interaction(snapping: true)
        // c2 tail 40 -> drag +19 frames = 59 -> snaps to c3 start 60 (within 2 frames).
        let raw_t = drag(&i, from: CGPoint(x: X(40) - 1, y: yV1), to: CGPoint(x: X(59) - 1, y: yV1))
        let t = try #require(raw_t)
        #expect(clip(t.timeline, f.c2.id)?.timeline.end == fd * 60)
    }

    // MARK: Ripple (B)

    @Test func rippleToolShortensAndShiftsFollowers() throws {
        let f = Fixture()
        var i = f.interaction(.rippleEdit)
        let raw_c = drag(&i, from: CGPoint(x: X(40) - 1, y: yV1), to: CGPoint(x: X(35) - 1, y: yV1))
        let c = try #require(raw_c)
        #expect(c.undoName == "Ripple Trim")
        #expect(clip(c.timeline, f.c2.id)?.timeline.end == fd * 35)
        #expect(clip(c.timeline, f.c3.id)?.start == fd * 55)
    }

    @Test func rippleToolInBodyUsesNearestEdge() throws {
        let f = Fixture()
        var i = f.interaction(.rippleEdit)
        // Left half of c3 -> head edge; dragging right by 5 shortens it, start stays (Premiere).
        let raw_c = drag(&i, from: CGPoint(x: X(63), y: yV1), to: CGPoint(x: X(68), y: yV1))
        let c = try #require(raw_c)
        #expect(clip(c.timeline, f.c3.id)?.start == fd * 60)
        #expect(clip(c.timeline, f.c3.id)?.timeline.duration == fd * 15)
    }

    // MARK: Roll (N)

    @Test func rollMovesTheCutBetweenNeighbours() throws {
        let f = Fixture()
        var i = f.interaction(.rollEdit)
        let raw_c = drag(&i, from: CGPoint(x: X(20) - 1, y: yV1), to: CGPoint(x: X(23) - 1, y: yV1))
        let c = try #require(raw_c)
        #expect(c.undoName == "Move Edit")
        #expect(clip(c.timeline, f.c1.id)?.timeline.end == fd * 23)
        #expect(clip(c.timeline, f.c2.id)?.start == fd * 23)
        #expect(clip(c.timeline, f.c2.id)?.timeline.end == fd * 40)
        // Grabbing the right side of the cut (c2 head) does the same.
        var j = f.interaction(.rollEdit)
        let raw_d = drag(&j, from: CGPoint(x: X(20) + 1, y: yV1), to: CGPoint(x: X(17) + 1, y: yV1))
        let d = try #require(raw_d)
        #expect(clip(d.timeline, f.c2.id)?.start == fd * 17)
    }

    @Test func rollWithoutAdjacentClipDoesNothing() {
        let f = Fixture()
        var i = f.interaction(.rollEdit)
        #expect(drag(&i, from: CGPoint(x: X(80) - 1, y: yV1), to: CGPoint(x: X(85), y: yV1)) == nil)
    }

    // MARK: Slip (Y) and slide (U)

    @Test func slipShiftsSourceAndKeepsPosition() throws {
        let f = Fixture()
        var i = f.interaction(.slip)
        let raw_c = drag(&i, from: CGPoint(x: X(30), y: yV1), to: CGPoint(x: X(34), y: yV1))
        let c = try #require(raw_c)
        #expect(c.undoName == "Slip Clip")
        let s = try #require(clip(c.timeline, f.c2.id))
        #expect(s.start == fd * 20)
        #expect(s.source.start == fd * 46)             // dragging right pulls earlier media into view
        #expect(s.timeline.duration == fd * 20)
    }

    @Test func slipTwoUpFollowsTheDragAndEndsWithIt() throws {
        let f = Fixture()
        var i = f.interaction(.slip)
        #expect(i.slipTwoUp == nil)
        i.mouseDown(CGPoint(x: X(30), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(34), y: yV1), modifiers: [])
        let t = try #require(i.slipTwoUp)
        #expect(t.clip == f.c2.id)
        #expect(t.headTime == fd * 20)                  // the clip stays, its content moves
        #expect(t.tailTime == fd * 39)
        #expect(t.sourceHead == fd * 46)
        #expect(t.sourceTail == fd * 65)
        #expect(t.offset == fd * -4)                    // dragging right pulls earlier media
        #expect(t.offsetLabel(frameDuration: fd) == "-4 f")
        i.mouseDragged(CGPoint(x: X(26), y: yV1), modifiers: [])
        #expect(i.slipTwoUp?.offset == fd * 4)
        _ = i.mouseUp(CGPoint(x: X(26), y: yV1), modifiers: [])
        #expect(i.slipTwoUp == nil)
    }

    @Test func slipMovesKeyframesWithContentAndVariantKeepsThem() throws {
        var f = Fixture()
        f.c2.animation.opacity.track = KeyframeTrack(keys: [Keyframe(time: fd * 5, value: 0.5)])
        f.v1 = Track(kind: .video, clips: [f.c1, f.c2, f.c3])
        var i = f.interaction(.slip)
        let plain = try #require(drag(&i, from: CGPoint(x: X(30), y: yV1), to: CGPoint(x: X(34), y: yV1)))
        let p = try #require(clip(plain.timeline, f.c2.id))
        #expect(p.source.start == fd * 46)
        #expect(p.animation.opacity.track.keys[0].time == fd * 9)      // key stays on its source frame
        var j = f.interaction(.slip)
        j.toolState.slipKeyframesStay = true
        let stay = try #require(drag(&j, from: CGPoint(x: X(30), y: yV1), to: CGPoint(x: X(34), y: yV1)))
        #expect(stay.undoName == "Slip Clip (Keyframes Stay)")
        let s = try #require(clip(stay.timeline, f.c2.id))
        #expect(s.source.start == fd * 46)
        #expect(s.animation.opacity.track.keys[0].time == fd * 5)      // key stays on the timeline
    }

    @Test func slideMovesClipAndAdjustsNeighbour() throws {
        let f = Fixture()
        var i = f.interaction(.slide)
        let raw_c = drag(&i, from: CGPoint(x: X(30), y: yV1), to: CGPoint(x: X(33), y: yV1))
        let c = try #require(raw_c)
        #expect(c.undoName == "Slide Clip")
        #expect(clip(c.timeline, f.c2.id)?.start == fd * 23)
        #expect(clip(c.timeline, f.c2.id)?.source == f.c2.source)
        #expect(clip(c.timeline, f.c1.id)?.timeline.end == fd * 23)
    }

    @Test func slipAndSlideShowTheOffsetWhileDragging() {
        let f = Fixture()
        var i = f.interaction(.slip)
        i.mouseDown(CGPoint(x: X(30), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(34), y: yV1), modifiers: [])
        #expect(i.moveHint == "Slip -4 f")
        i.mouseDragged(CGPoint(x: X(30), y: yV1), modifiers: [])
        #expect(i.moveHint == nil)
        _ = i.mouseUp(CGPoint(x: X(30), y: yV1), modifiers: [])
        #expect(i.moveHint == nil)
        var j = f.interaction(.slide)
        j.mouseDown(CGPoint(x: X(30), y: yV1), modifiers: [])
        j.mouseDragged(CGPoint(x: X(33), y: yV1), modifiers: [])
        #expect(j.moveHint == "Slide +3 f")
        _ = j.mouseUp(CGPoint(x: X(33), y: yV1), modifiers: [])
        #expect(j.moveHint == nil)
    }

    // MARK: Razor (C)

    @Test func razorCutsClipAndLinkedPartner() throws {
        let f = Fixture()
        var i = f.interaction(.razor)
        let raw_c = click(&i, CGPoint(x: X(10), y: yV1))
        let c = try #require(raw_c)
        #expect(c.undoName == "Blade")
        #expect(c.timeline.tracks[0].clips.count == 4)
        #expect(c.timeline.tracks[2].clips.count == 2)             // partner cut too
        #expect(c.timeline.tracks[0].clips[1].start == fd * 10)
        #expect(c.edits == [.addEdit(at: fd * 10, tracks: [c.timeline.tracks[0].id, c.timeline.tracks[2].id])])
    }

    @Test func draggingTheRazorShowsAHintAndCutsNothingMore() {
        let f = Fixture()
        var i = f.interaction(.razor)
        i.mouseDown(CGPoint(x: X(10), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(20), y: yV1), modifiers: [])
        #expect(i.moveHint == TimelineInteraction.razorDragHint)
        i.mouseUp(CGPoint(x: X(20), y: yV1), modifiers: [])
        #expect(i.moveHint == nil)
    }

    @Test func razorWithOptionCutsOnlyTheClickedTrack() throws {
        let f = Fixture()
        var i = f.interaction(.razor)
        let raw_c = click(&i, CGPoint(x: X(10), y: yV1), .option)
        let c = try #require(raw_c)
        #expect(c.timeline.tracks[0].clips.count == 4)
        #expect(c.timeline.tracks[2].clips.count == 1)
    }

    @Test func razorWithShiftCutsAllTracks() throws {
        let f = Fixture()
        var i = f.interaction(.razor)
        let raw_c = click(&i, CGPoint(x: X(15), y: yV1), .shift)
        let c = try #require(raw_c)
        #expect(c.undoName == "Blade All Tracks")
        #expect(c.timeline.tracks[0].clips.count == 4)
        #expect(c.timeline.tracks[2].clips.count == 2)
        #expect(c.timeline.tracks[3].clips.count == 2)             // unlinked a2c spans frame 15 too (10..<20)
        #expect(c.edits == [.addEdit(at: fd * 15, tracks: nil)])
    }

    @Test func razorInGapDoesNothingAndPreviewShowsCutBeforeRelease() throws {
        let f = Fixture()
        var i = f.interaction(.razor)
        #expect(click(&i, CGPoint(x: X(50), y: yV1)) == nil)
        i.mouseDown(CGPoint(x: X(70), y: yV1), modifiers: [])
        #expect(i.preview.tracks[0].clips.count == 4)
        #expect(i.timeline.tracks[0].clips.count == 3)
        #expect(i.mouseUp(CGPoint(x: X(70), y: yV1), modifiers: []) != nil)
    }

    @Test func razorShiftClickInGapCutsAllTracksAtThatTime() throws {
        let f = Fixture()
        var i = f.interaction(.razor)
        // Frame 15 on V2 (empty row): all other tracks are cut at 15, in one undo step.
        let raw_c = click(&i, CGPoint(x: X(15), y: yV2), .shift)
        let c = try #require(raw_c)
        #expect(c.undoName == "Blade All Tracks")
        #expect(c.timeline.tracks[0].clips.count == 4)
        #expect(c.edits == [.addEdit(at: fd * 15, tracks: nil)])
        var j = f.interaction(.razor)
        #expect(click(&j, CGPoint(x: X(15), y: yV2)) == nil)       // without Shift an empty spot does nothing
    }

    @Test func razorSnapsToPlayhead() throws {
        let f = Fixture()
        var i = f.interaction(.razor, snapping: true, playhead: fd * 71)
        let raw_c = click(&i, CGPoint(x: X(70), y: yV1))
        let c = try #require(raw_c)
        #expect(c.timeline.tracks[0].clips[3].start == fd * 71)
    }

    // MARK: Track select forward (A)

    @Test func trackSelectForwardSelectsClipAndEverythingAfterOnEveryTrack() {
        let f = Fixture()
        var i = f.interaction(.trackSelectForward, linked: false)
        _ = click(&i, CGPoint(x: X(25), y: yV1))
        #expect(i.selection == [f.c2.id, f.c3.id])                   // nothing else reaches past frame 20 except c2/c3
        var j = f.interaction(.trackSelectForward, linked: false)
        _ = click(&j, CGPoint(x: X(12), y: yV1))                     // Premiere: a plain click spans all tracks
        #expect(j.selection == [f.c1.id, f.c2.id, f.c3.id, f.a1.id, f.a2c.id])
        _ = click(&j, CGPoint(x: X(50), y: yV1))                     // gap: from there on
        #expect(j.selection == [f.c3.id])
    }

    @Test func trackSelectForwardWithShiftLimitsToTheClickedTrack() {
        let f = Fixture()
        var i = f.interaction(.trackSelectForward, linked: false)
        _ = click(&i, CGPoint(x: X(12), y: yV1), .shift)
        #expect(i.selection == [f.c1.id, f.c2.id, f.c3.id])          // video track V1 only
    }

    @Test func trackSelectBackwardSelectsClipAndEverythingBeforeIt() {
        let f = Fixture()
        var i = f.interaction(.trackSelectForward, linked: false)
        i.toolState.selectBackward = true
        _ = click(&i, CGPoint(x: X(25), y: yV1))                     // c2 ends at 40: everything starting before that
        #expect(i.selection == [f.c1.id, f.c2.id, f.a1.id, f.a2c.id])
        _ = click(&i, CGPoint(x: X(50), y: yV1))                     // gap: everything starting before the click
        #expect(i.selection == [f.c1.id, f.c2.id, f.a1.id, f.a2c.id])
        _ = click(&i, CGPoint(x: X(25), y: yV1), .shift)             // Shift: the clicked track only
        #expect(i.selection == [f.c1.id, f.c2.id])
    }

    // MARK: Hand (H)

    @Test func handPansTheViewAndNeverEdits() {
        let f = Fixture()
        var i = f.interaction(.hand)
        i.geometry.scrollX = 100
        i.geometry.scrollY = 10
        i.mouseDown(CGPoint(x: 400, y: 60), modifiers: [])
        i.mouseDragged(CGPoint(x: 370, y: 70), modifiers: [])
        #expect(i.geometry.scrollX == 130)
        #expect(i.geometry.scrollY == 0)
        i.mouseDragged(CGPoint(x: 600, y: 60), modifiers: [])
        #expect(i.geometry.scrollX == 0)                              // clamped
        #expect(i.mouseUp(CGPoint(x: 600, y: 60), modifiers: []) == nil)
        #expect(i.preview == i.timeline)
    }

    // MARK: Keys

    @Test func toolKeys() {
        let pairs: [(Character, TimelineTool)] = [("v", .selection), ("A", .trackSelectForward), ("b", .rippleEdit),
                                                  ("n", .rollEdit), ("y", .slip), ("u", .slide), ("c", .razor), ("h", .hand), ("z", .zoom)]
        for (k, t) in pairs { #expect(TimelineTool(key: k) == t); #expect(TimelineTool(key: t.key) == t) }
        #expect(TimelineTool(key: "k") == nil)
    }

    @Test func clicksOnRulerAndHeaderAreIgnored() {
        let f = Fixture()
        var i = f.interaction()
        #expect(click(&i, CGPoint(x: X(10), y: 5)) == nil)
        #expect(click(&i, CGPoint(x: 100, y: yV1)) == nil)
        #expect(i.selection.isEmpty)
    }
}

/// Pre-release timeline audit (2026-10-07).
@Suite struct TimelineInteractionAudit2Tests {
    /// Esc during a marquee: the selection the marquee made goes, the one from before the press comes back.
    @Test func cancelledMarqueeRestoresSelection() {
        let f = Fixture()
        var i = f.interaction()
        _ = click(&i, CGPoint(x: X(65), y: yV1))
        #expect(i.selection == [f.c3.id])
        i.mouseDown(CGPoint(x: X(45), y: yV2), modifiers: .shift)
        i.mouseDragged(CGPoint(x: X(5), y: yA1), modifiers: .shift)
        #expect(i.selection.contains(f.c1.id))
        i.cancel()
        #expect(i.selection == [f.c3.id])
        #expect(i.marquee == nil)
    }

    /// Without Shift the press clears the selection first; Esc still brings back what was selected before it.
    @Test func cancelledPlainMarqueeRestoresSelection() {
        let f = Fixture()
        var i = f.interaction()
        _ = click(&i, CGPoint(x: X(65), y: yV1))
        #expect(i.selection == [f.c3.id])
        i.mouseDown(CGPoint(x: X(45), y: yV2), modifiers: [])
        i.mouseDragged(CGPoint(x: X(5), y: yA1), modifiers: [])
        #expect(!i.selection.contains(f.c3.id))
        i.cancel()
        #expect(i.selection == [f.c3.id])
    }

    /// A marquee sweeping over a locked track leaves its clips out (Premiere: locked clips cannot be selected), so a
    /// following Delete is not refused for them.
    @Test func marqueeSkipsLockedTrackClips() {
        var f = Fixture()
        f.aT2.isLocked = true
        var i = f.interaction(linked: false)
        _ = drag(&i, from: CGPoint(x: X(45), y: yV2), to: CGPoint(x: X(1), y: yA2))
        #expect(i.selection.contains(f.c1.id))
        #expect(!i.selection.contains(f.a2c.id))
        #expect(i.deleteSelection(ripple: false) != nil)
    }
}
