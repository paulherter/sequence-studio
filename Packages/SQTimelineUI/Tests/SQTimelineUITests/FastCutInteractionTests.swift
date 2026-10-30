#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

// Fast Cut gestures (docs/ARCHITECTURE.md "Fast Cut operations"): the drags of the Selection tool and the trim tools
// map to the magnetic verbs, the drop ghost shows the magnetic landing, and the view helpers (host highlight,
// spacer hatching). Normal sequences are checked to stay unchanged.

private let fd = Time(1, 24)
private let link = UUID()

/// 4 pt per frame: frame f is at x = contentOriginX + 4 f. Same rows as TimelineInteractionTests.
private func X(_ f: Double) -> CGFloat { TimelineGeometry.contentOriginX + CGFloat(f) * 4 }
private let yV2: CGFloat = 42, yV1: CGFloat = 82

private func mk(_ start: Int64, _ frames: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: fd * 50, duration: fd * frames),
         start: fd * start, link: link, mediaDuration: fd * 200)
}

/// V1: c1[0-20] (sound a1 on A1), c2[20-40], c3[40-60]. V2: x[45-55], attached to c3.
private struct Fixture {
    let c1 = mk(0, 20, link: link), c2 = mk(20, 20), c3 = mk(40, 20)
    let a1 = mk(0, 20, kind: .audio, link: link)
    let x = mk(45, 10)

    func timeline(_ mode: TimelineEditMode = .magnetic) -> Timeline {
        var t = Timeline(name: "t", frameDuration: fd,
                         tracks: [Track(kind: .video, clips: [c1, c2, c3]), Track(kind: .video, clips: [x]),
                                  Track(kind: .audio, clips: [a1]), Track(kind: .audio)])
        t.setEditMode(mode)
        return t
    }

    func interaction(_ tool: TimelineTool = .selection, mode: TimelineEditMode = .magnetic,
                     keepAttached: Bool = false) -> TimelineInteraction {
        var i = TimelineInteraction(timeline: timeline(mode), geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: tool, snapping: false, linkedSelection: true)
        i.toolState.keepAttached = keepAttached
        return i
    }
}

private func clip(_ t: Timeline, _ id: Clip.ID) -> Clip? { t.tracks.lazy.compactMap { $0.clips.first { $0.id == id } }.first }
private func start(_ t: Timeline, _ id: Clip.ID) -> Time? { clip(t, id)?.start }
private func row(_ t: Timeline, _ id: Clip.ID) -> Int? { t.tracks.firstIndex { $0.clips.contains { $0.id == id } } }

private func drag(_ i: inout TimelineInteraction, from a: CGPoint, to b: CGPoint) -> TimelineCommit? {
    i.mouseDown(a, modifiers: [])
    i.mouseDragged(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), modifiers: [])
    i.mouseDragged(b, modifiers: [])
    return i.mouseUp(b, modifiers: [])
}

@MainActor @Suite struct FastCutInteractionTests {
    @Test func fixtureAttachesTheBrollToC3() {
        let f = Fixture()
        #expect(f.timeline().attachedClips(of: [f.c3.id]).contains(f.x.id))
    }

    // MARK: Drag along V1

    @Test func dragAlongTheMainTrackRearrangesAtTheNearestEdit() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(5), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(40), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(62), y: yV1), modifiers: [])
        #expect(i.moveHint?.hasPrefix("Rearrange") == true)
        let raw = i.mouseUp(CGPoint(x: X(62), y: yV1), modifiers: [])
        let c = try #require(raw)
        // c1 (start dragged to 57) lands at the edit nearest to it, the end of V1: c2 c3 c1, no hole.
        #expect(start(c.timeline, f.c2.id) == .zero)
        #expect(start(c.timeline, f.c3.id) == fd * 20)
        #expect(start(c.timeline, f.c1.id) == fd * 40)
        #expect(start(c.timeline, f.a1.id) == fd * 40)               // its sound goes along
        #expect(start(c.timeline, f.x.id) == fd * 25)                // attached to c3: follows it
        #expect(row(c.timeline, f.c1.id) == 0)
    }

    @Test func dragAlongTheMainTrackFloatsTheClipUnderThePointer() throws {
        let f = Fixture()
        var i = f.interaction()
        #expect(i.reorderGhost == nil)
        i.mouseDown(CGPoint(x: X(5), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(40), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(62), y: yV1), modifiers: [])
        let g = try #require(i.reorderGhost)
        #expect(g.track == i.timeline.mainTrackID)
        #expect(g.range.start > f.c1.start)                          // follows the pointer, not the slot
        #expect(g.range.duration == f.c1.timeline.duration)
        _ = i.mouseUp(CGPoint(x: X(62), y: yV1), modifiers: [])
        #expect(i.reorderGhost == nil)
    }

    @Test func normalSequenceDragHasNoReorderGhost() {
        let f = Fixture()
        var i = f.interaction(mode: .normal)
        i.mouseDown(CGPoint(x: X(5), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(40), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(62), y: yV1), modifiers: [])
        #expect(i.reorderGhost == nil)
    }

    @Test func holdingBacktickKeepsAttachedClipsOnTheirFrame() throws {
        let f = Fixture()
        var i = f.interaction(keepAttached: true)
        i.mouseDown(CGPoint(x: X(45), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(20), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(1), y: yV1), modifiers: [])
        #expect(i.moveHint?.contains("attached stay") == true)
        let raw = i.mouseUp(CGPoint(x: X(1), y: yV1), modifiers: [])
        let c = try #require(raw)
        #expect(start(c.timeline, f.c3.id) == .zero)
        #expect(start(c.timeline, f.x.id) == fd * 45)                // stays where it was
    }

    @Test func normalSequenceDragStaysAPlainMove() throws {
        let f = Fixture()
        var i = f.interaction(mode: .normal)
        let raw = drag(&i, from: CGPoint(x: X(5), y: yV1), to: CGPoint(x: X(65), y: yV1))
        let c = try #require(raw)
        #expect(start(c.timeline, f.c2.id) == fd * 20)               // nothing closes
        #expect(i.moveHint?.hasPrefix("Rearrange") != true)
    }

    // MARK: Several clips, copies

    @Test func draggingTwoMainClipsRearrangesThemAsOneBlock() throws {
        let f = Fixture()
        var i = f.interaction()
        i.setSelection([f.c1.id, f.a1.id, f.c2.id])
        let raw = drag(&i, from: CGPoint(x: X(25), y: yV1), to: CGPoint(x: X(80), y: yV1))
        let c = try #require(raw)
        // The block's start (c1, dragged to 55) lands on the nearest edit not its own: the end of V1.
        #expect(start(c.timeline, f.c3.id) == .zero)
        #expect(start(c.timeline, f.c1.id) == fd * 20)
        #expect(start(c.timeline, f.c2.id) == fd * 40)
        #expect(start(c.timeline, f.a1.id) == fd * 20)
        #expect(start(c.timeline, f.x.id) == fd * 5)                 // attached to c3: follows it
        #expect(c.timeline.tracks[0].clips.count == 3)
    }

    private func optionDrag(_ i: inout TimelineInteraction, from a: CGPoint, to b: CGPoint) -> TimelineCommit? {
        i.mouseDown(a, modifiers: [.option])
        i.mouseDragged(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), modifiers: [.option])
        i.mouseDragged(b, modifiers: [.option])
        return i.mouseUp(b, modifiers: [.option])
    }

    @Test func optionDragCopyOfAMainClipPastTheEndAppendsWithoutAHole() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw = optionDrag(&i, from: CGPoint(x: X(25), y: yV1), to: CGPoint(x: X(95), y: yV1))
        let c = try #require(raw)
        let v1 = c.timeline.tracks[0].clips
        #expect(v1.count == 4)
        #expect(v1.map(\.start) == [.zero, fd * 20, fd * 40, fd * 60])
        #expect(start(c.timeline, f.c2.id) == fd * 20)               // the original stays
    }

    @Test func optionDragCopyOfAMainClipIntoV1InsertsAtTheNearestEdit() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw = optionDrag(&i, from: CGPoint(x: X(5), y: yV1), to: CGPoint(x: X(46), y: yV1))   // start 41 -> edit 40
        let c = try #require(raw)
        let v1 = c.timeline.tracks[0].clips
        #expect(v1.map(\.start) == [.zero, fd * 20, fd * 40, fd * 60])
        #expect(start(c.timeline, f.c3.id) == fd * 60)
        #expect(start(c.timeline, f.x.id) == fd * 65)                // attached to c3: follows
    }

    @Test func optionDragCopyOfAnAttachedClipAttachesAndMovesNothing() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw = optionDrag(&i, from: CGPoint(x: X(50), y: yV2), to: CGPoint(x: X(30), y: yV2))
        let c = try #require(raw)
        #expect(c.timeline.tracks[0].clips == f.timeline().tracks[0].clips)
        let copies = c.timeline.tracks.flatMap(\.clips).filter { $0.id != f.x.id && $0.start == fd * 25 }
        #expect(copies.count == 1)
        #expect(copies.first?.attachment?.host == f.c2.id)
    }

    @Test func closeGapOffTheMainTrackClosesOnlyThatLane() {
        let t = Fixture().timeline()
        let v2 = t.tracks[1].id
        #expect(TimelineEdit.fastCut([.closeGap(v2, at: fd * 10)], in: t) == [.fastCut(.closeLaneGap(v2, at: fd * 10))])
    }

    @Test func rateStretchAndSpeedMapToTheirFastCutVerbs() {
        let f = Fixture()
        let t = f.timeline()
        let sp = SpeedChange(reversed: true)
        #expect(TimelineEdit.fastCut([.rateStretch(f.c2.id, edge: .tail, by: fd)], in: t)
                == [.fastCut(.rateStretch(f.c2.id, edge: .tail, by: fd))])
        #expect(TimelineEdit.fastCut([.speed([f.c2.id], sp)], in: t) == [.fastCut(.speed([f.c2.id], sp))])
    }

    @Test func rateStretchToolOnTheMainTrackClosesV1() throws {
        let f = Fixture()
        var t = f.timeline()
        try TimelineEdit.fastCut([.rateStretch(f.c2.id, edge: .tail, by: fd * -10)], in: t).forEach { try $0.apply(to: &t) }
        #expect(clip(t, f.c2.id)?.timeline.end == fd * 30)
        #expect(start(t, f.c3.id) == fd * 30)
    }

    // MARK: Drag off / onto V1

    @Test func dragOffTheMainTrackClosesV1AndAttachesTheClip() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(25), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(25), y: yV2 + 4), modifiers: [])
        i.mouseDragged(CGPoint(x: X(25), y: yV2), modifiers: [])
        #expect(i.moveHint?.hasPrefix("Lift off main track") == true)
        let raw = i.mouseUp(CGPoint(x: X(25), y: yV2), modifiers: [])
        let c = try #require(raw)
        #expect(row(c.timeline, f.c2.id) != 0)
        #expect(start(c.timeline, f.c3.id) == fd * 20)               // V1 closed behind it
        #expect(clip(c.timeline, f.c2.id)?.attachment != nil)        // now attached
    }

    @Test func dragOntoTheMainTrackInsertsAtTheNearestEdit() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(50), y: yV2), modifiers: [])
        i.mouseDragged(CGPoint(x: X(30), y: yV2 + 20), modifiers: [])
        i.mouseDragged(CGPoint(x: X(26), y: yV1), modifiers: [])
        #expect(i.moveHint?.hasPrefix("Insert on main track") == true)
        let raw = i.mouseUp(CGPoint(x: X(26), y: yV1), modifiers: [])
        let c = try #require(raw)
        #expect(row(c.timeline, f.x.id) == 0)
        #expect(start(c.timeline, f.x.id) == fd * 20)                // x start dragged to 21: the edit at 20
        #expect(start(c.timeline, f.c2.id) == fd * 30)               // V1 rippled by x's length
        #expect(start(c.timeline, f.c3.id) == fd * 50)
    }

    // MARK: Trims

    @Test func selectionToolTrimOnTheMainTrackRipples() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw = drag(&i, from: CGPoint(x: X(40) - 1, y: yV1), to: CGPoint(x: X(35) - 1, y: yV1))
        let c = try #require(raw)
        #expect(clip(c.timeline, f.c2.id)?.timeline.end == fd * 35)
        #expect(start(c.timeline, f.c3.id) == fd * 35)               // V1 never gets a hole
        #expect(start(c.timeline, f.x.id) == fd * 40)                // attached to c3: follows
    }

    @Test func trimOfAnAttachedClipMovesNothingElse() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw = drag(&i, from: CGPoint(x: X(55) - 1, y: yV2), to: CGPoint(x: X(52) - 1, y: yV2))
        let c = try #require(raw)
        #expect(clip(c.timeline, f.x.id)?.timeline.end == fd * 52)
        #expect(start(c.timeline, f.c3.id) == fd * 40)
    }

    @Test func rollKeepsV1ClosedAndTheAttachedClip() throws {
        let f = Fixture()
        var i = f.interaction(.rollEdit)
        let raw = drag(&i, from: CGPoint(x: X(40), y: yV1), to: CGPoint(x: X(44), y: yV1))
        let c = try #require(raw)
        #expect(clip(c.timeline, f.c2.id)?.timeline.end == fd * 44)
        #expect(start(c.timeline, f.c3.id) == fd * 44)
        #expect(clip(c.timeline, f.c3.id)?.timeline.end == fd * 60)
    }

    // MARK: Edit mapping

    @Test func deleteMapsToMagneticDelete() {
        let t = Fixture().timeline()
        let ids = [Fixture().c2.id]
        #expect(TimelineEdit.fastCut([.lift(ids)], in: t) == [.fastCut(.delete(ids, keepAttached: false))])
        #expect(TimelineEdit.fastCut([.rippleDelete(ids)], in: t, keepAttached: true) == [.fastCut(.delete(ids, keepAttached: true))])
    }

    @Test func normalSequencesKeepTheirEdits() {
        let f = Fixture()
        let edits: [TimelineEdit] = [.lift([f.c2.id]), .trim(f.c1.id, edge: .tail, by: fd * -2)]
        #expect(TimelineEdit.fastCut(edits, in: f.timeline(.normal)) == edits)
    }

    @Test func addEditWithoutTracksCutsEveryTrackTheFastCutWay() {
        let f = Fixture()
        #expect(TimelineEdit.fastCut([.addEdit(at: fd * 50, tracks: nil)], in: f.timeline()) == [.fastCut(.addEditAll(at: fd * 50))])
    }

    @Test func closeGapOnTheMainTrackDeletesTheSpacer() {
        let f = Fixture()
        let t = f.timeline()
        let main = t.tracks[0].id
        #expect(TimelineEdit.fastCut([.closeGap(main, at: fd * 70)], in: t) == [.fastCut(.deleteSpacer(at: fd * 70, keepAttached: false))])
    }

    // MARK: Drop ghost

    private func dropPreview(_ t: Timeline, at f: Double, insert: Bool) -> DropPreview {
        var d = DropPreview()
        d.begin(items: [DropItem(name: "m", duration: fd * 8, hasVideo: true, hasAudio: false)])
        d.update(point: CGPoint(x: X(f), y: yV1), insert: insert, timeline: t,
                 geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4), snapping: false, playhead: .zero)
        return d
    }

    @Test func dropOnTheMainTrackInsertsAtTheNearestEdit() throws {
        let t = Fixture().timeline()
        let d = dropPreview(t, at: 27, insert: false)
        let target = try #require(d.commitTarget)
        #expect(target.insert)
        #expect(target.time == fd * 20)
        #expect(d.ghosts.first?.range.start == fd * 20)
    }

    @Test func commandDropOverwritesFromThePointerInFastCut() throws {
        let t = Fixture().timeline()
        let target = try #require(dropPreview(t, at: 27, insert: true).commitTarget)
        #expect(!target.insert)
        #expect(target.time == fd * 27)
    }

    @Test func dropPastTheEndOfV1LandsAtItsEnd() throws {
        let t = Fixture().timeline()
        let target = try #require(dropPreview(t, at: 90, insert: false).commitTarget)
        #expect(target.time == fd * 60)
    }

    @Test func normalDropIsUnchanged() throws {
        let t = Fixture().timeline(.normal)
        let target = try #require(dropPreview(t, at: 27, insert: false).commitTarget)
        #expect(!target.insert)
        #expect(target.time == fd * 27)
    }

    // MARK: View helpers

    @Test func hostHighlightNamesTheMainClipOfTheSelectedAttachedClip() {
        let f = Fixture()
        #expect(ClipDrawing.attachHosts(of: [f.x.id], in: f.timeline()) == [f.c3.id])
        #expect(ClipDrawing.attachHosts(of: [f.x.id], in: f.timeline(.normal)).isEmpty)
    }

    @Test func spacersAreTheHolesBeforeTheLastMainClip() throws {
        let f = Fixture()
        var t = f.timeline()
        try t.replaceWithSpacer([f.c2.id])
        #expect(ClipDrawing.spacers(in: t) == [TimeRange(start: fd * 20, duration: fd * 20)])
        #expect(ClipDrawing.spacers(in: f.timeline()).isEmpty)
    }
}
