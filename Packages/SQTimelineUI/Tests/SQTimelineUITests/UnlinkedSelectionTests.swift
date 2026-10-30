#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

/// Premiere "selected unlinked": a clip picked with Option (or with Linked Selection off) is edited alone; its linked
/// partner follows only when it is selected too.
private let fd = Time(1, 24)

/// 4 pt per frame: frame f is at x = contentOriginX (124) + 4 f. Rows: V2 y22..<54, V1 54..<86, A1 86..<112, A2 112..<138.
private func X(_ f: Double) -> CGFloat { TimelineGeometry.contentOriginX + CGFloat(f) * 4 }
private let yV2: CGFloat = 38, yV1: CGFloat = 70

private func mk(_ start: Int64, _ frames: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: fd * 50, duration: fd * frames),
         start: fd * start, link: link, mediaDuration: fd * 200)
}

private struct Fixture {
    let link = UUID()
    let v: Clip, a: Clip
    init() { v = mk(0, 20, link: link); a = mk(0, 20, kind: .audio, link: link) }
    var timeline: Timeline {
        Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [v]), Track(kind: .video),
                                                        Track(kind: .audio, clips: [a]), Track(kind: .audio)])
    }
    func interaction(linked: Bool = true) -> TimelineInteraction {
        var i = TimelineInteraction(timeline: timeline, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: .selection, snapping: false, linkedSelection: linked)
        return i
    }
}

private func clip(_ t: Timeline, _ id: Clip.ID) -> Clip? { t.tracks.lazy.compactMap { $0.clips.first { $0.id == id } }.first }

private func drag(_ i: inout TimelineInteraction, from a: CGPoint, to b: CGPoint, _ m: GestureModifiers = []) -> TimelineCommit? {
    i.mouseDown(a, modifiers: m)
    i.mouseDragged(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), modifiers: m)
    i.mouseDragged(b, modifiers: m)
    return i.mouseUp(b, modifiers: m)
}

@Suite struct UnlinkedSelectionInteractionTests {
    @Test func optionSelectedClipMovesAlone() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(10), y: yV1), modifiers: .option)
        _ = i.mouseUp(CGPoint(x: X(10), y: yV1), modifiers: .option)
        #expect(i.selection == [f.v.id])
        let raw_c = drag(&i, from: CGPoint(x: X(10), y: yV1), to: CGPoint(x: X(40), y: yV2))
        let c = try #require(raw_c)
        #expect(clip(c.timeline, f.v.id)?.start == fd * 30)
        #expect(c.timeline.tracks[1].clips.map(\.id) == [f.v.id])
        #expect(clip(c.timeline, f.a.id)?.start == .zero)
        #expect(c.timeline.tracks[2].clips.map(\.id) == [f.a.id])
        #expect(clip(c.timeline, f.v.id)?.link == f.link)         // still linked, now out of sync
    }

    @Test func plainSelectedClipMovesWithPartner() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw_c = drag(&i, from: CGPoint(x: X(10), y: yV1), to: CGPoint(x: X(40), y: yV1))
        let c = try #require(raw_c)
        #expect(clip(c.timeline, f.a.id)?.start == fd * 30)
    }

    @Test func linkedSelectionOffMovesAlone() throws {
        let f = Fixture()
        var i = f.interaction(linked: false)
        let raw_c = drag(&i, from: CGPoint(x: X(10), y: yV1), to: CGPoint(x: X(40), y: yV1))
        let c = try #require(raw_c)
        #expect(clip(c.timeline, f.v.id)?.start == fd * 30)
        #expect(clip(c.timeline, f.a.id)?.start == .zero)
    }

    @Test func optionEdgeTrimsAlone() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw_c = drag(&i, from: CGPoint(x: X(20) - 1, y: yV1), to: CGPoint(x: X(15) - 1, y: yV1), .option)
        let c = try #require(raw_c)
        #expect(clip(c.timeline, f.v.id)?.duration == fd * 15)
        #expect(clip(c.timeline, f.a.id)?.duration == fd * 20)
        var j = f.interaction()
        let raw_d = drag(&j, from: CGPoint(x: X(20) - 1, y: yV1), to: CGPoint(x: X(15) - 1, y: yV1))
        let d = try #require(raw_d)
        #expect(clip(d.timeline, f.a.id)?.duration == fd * 15)    // plain edge drag trims both
    }

    @Test func optionDeleteRemovesOnlyThatClip() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(10), y: yV1), modifiers: .option)
        _ = i.mouseUp(CGPoint(x: X(10), y: yV1), modifiers: .option)
        let raw_c = i.deleteSelection(ripple: false)
        let c = try #require(raw_c)
        #expect(clip(c.timeline, f.v.id) == nil)
        #expect(clip(c.timeline, f.a.id) != nil)
        #expect(clip(c.timeline, f.a.id)?.link == nil)            // lone partner loses its link
    }

    @Test func optionDragOnUnselectedClipCopiesOnlyThatClip() throws {
        let f = Fixture()
        var i = f.interaction()
        let raw_c = drag(&i, from: CGPoint(x: X(10), y: yV1), to: CGPoint(x: X(40), y: yV2), .option)
        let c = try #require(raw_c)
        #expect(c.timeline.tracks[1].clips.count == 1)            // the copy
        #expect(c.timeline.tracks[0].clips.map(\.id) == [f.v.id]) // original stays
        #expect(c.timeline.tracks[2].clips.count == 1 && c.timeline.tracks[3].clips.isEmpty)
        #expect(c.timeline.tracks[1].clips[0].link == nil)
    }

    @Test func optionDragOnSelectedPairCopiesBoth() throws {
        let f = Fixture()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(10), y: yV1), modifiers: [])
        _ = i.mouseUp(CGPoint(x: X(10), y: yV1), modifiers: [])
        let raw_c = drag(&i, from: CGPoint(x: X(10), y: yV1), to: CGPoint(x: X(40), y: yV1), .option)
        let c = try #require(raw_c)
        #expect(c.timeline.tracks[0].clips.count == 2)
        #expect(c.timeline.tracks[2].clips.count == 2)
    }
}

@MainActor private func session(_ f: Fixture) -> EditorSession {
    EditorSession(project: Project(name: "P", timelines: [f.timeline]), engine: StubProgramEngine())
}

@MainActor @Suite struct UnlinkedSelectionSessionTests {
    @Test func deleteNudgeSpeedActOnSelectedClipOnly() throws {
        let f = Fixture()
        let ses = session(f)
        ses.select(clips: [f.v.id])
        ses.nudgeSelection(frames: 2)
        #expect(clip(ses.activeTimeline!, f.v.id)?.start == fd * 2)
        #expect(clip(ses.activeTimeline!, f.a.id)?.start == .zero)
        #expect(ses.applySpeed(SpeedChange(speed: ClipSpeed(num: 2, den: 1))))
        #expect(clip(ses.activeTimeline!, f.v.id)?.duration == fd * 10)
        #expect(clip(ses.activeTimeline!, f.a.id)?.duration == fd * 20)
        ses.deleteSelection(ripple: false)
        #expect(clip(ses.activeTimeline!, f.v.id) == nil)
        #expect(clip(ses.activeTimeline!, f.a.id) != nil)
    }

    @Test func unlinkedEdgeTrimByKeys() throws {
        let f = Fixture()
        let ses = session(f)
        ses.trimEdges(EdgeSelection(edges: [EdgeRef(clip: f.v.id, edge: .tail)], linked: false), frames: -2)
        #expect(clip(ses.activeTimeline!, f.v.id)?.duration == fd * 18)
        #expect(clip(ses.activeTimeline!, f.a.id)?.duration == fd * 20)
        ses.trimEdges(EdgeSelection(edges: [EdgeRef(clip: f.v.id, edge: .tail)]), frames: -2)
        #expect(clip(ses.activeTimeline!, f.a.id)?.duration == fd * 18)
    }

    @Test func cutCopiesAndLiftsOnlySelected() throws {
        let f = Fixture()
        let ses = session(f)
        ses.select(clips: [f.v.id])
        ses.cutSelection()
        #expect(ses.clipboard?.entries.count == 1)
        #expect(clip(ses.activeTimeline!, f.a.id) != nil)
    }
}

/// Review fixes: roll scope covers the left clip, edge `linked` survives prune/cycle, D expands to partners.
@MainActor @Suite struct UnlinkedSelectionReviewTests {
    /// V1: v0 0..<20, v1 20..<40; A1: a0, a1 the same, v0/a0 and v1/a1 linked.
    private struct Cut {
        let l0 = UUID(), l1 = UUID()
        let v0: Clip, v1: Clip, a0: Clip, a1: Clip
        init() {
            v0 = mk(0, 20, link: l0); v1 = mk(20, 20, link: l1)
            a0 = mk(0, 20, kind: .audio, link: l0); a1 = mk(20, 20, kind: .audio, link: l1)
        }
        var timeline: Timeline {
            Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [v0, v1], isTargeted: true),
                                                            Track(kind: .video), Track(kind: .audio, clips: [a0, a1])])
        }
        func interaction(_ tool: TimelineTool, linked: Bool = true) -> TimelineInteraction {
            var i = TimelineInteraction(timeline: timeline, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
            i.toolState = ToolState(tool: tool, snapping: false, linkedSelection: linked)
            return i
        }
    }

    @Test func rollToolOnHeadWithOptionRollsOnlyThatCut() throws {
        let f = Cut()
        for (linked, m) in [(true, GestureModifiers.option), (false, [])] {
            var i = f.interaction(.rollEdit, linked: linked)
            let raw_c = drag(&i, from: CGPoint(x: X(20) + 1, y: yV1), to: CGPoint(x: X(25) + 1, y: yV1), m)
            let c = try #require(raw_c)
            #expect(clip(c.timeline, f.v1.id)?.start == fd * 25)
            #expect(clip(c.timeline, f.v0.id)?.duration == fd * 25)
            #expect(clip(c.timeline, f.a1.id)?.start == fd * 20)
            #expect(clip(c.timeline, f.a0.id)?.duration == fd * 20)
        }
        var j = f.interaction(.rollEdit)
        let raw_d = drag(&j, from: CGPoint(x: X(20) + 1, y: yV1), to: CGPoint(x: X(25) + 1, y: yV1))
        let d = try #require(raw_d)
        #expect(clip(d.timeline, f.a1.id)?.start == fd * 25)      // plain roll moves the linked cut too
    }

    @Test func pruneAndCycleKeepUnlinked() {
        let f = Cut()
        let t = f.timeline
        let sel = EdgeSelection(edges: [EdgeRef(clip: f.v0.id, edge: .tail)], linked: false)
        #expect(EdgeEdits.pruned(sel, in: t)?.linked == false)
        var s = sel
        for _ in 0..<4 { s = EdgeEdits.cycled(s, in: t); #expect(s.linked == false) }
        var i = f.interaction(.selection)
        i.setEdgeSelection(sel)
        i.reset(timeline: t)
        #expect(i.edgeSelection?.linked == false)
    }

    @Test func selectClipAtPlayheadAddsLinkedPartners() {
        let f = Cut()
        let ses = EditorSession(project: Project(name: "P", timelines: [f.timeline]), engine: StubProgramEngine())
        ses.seek(to: fd * 5)
        ses.selectClipAtPlayhead()
        #expect(ses.selection == [f.v0.id, f.a0.id])
        ses.linkedSelection = false
        ses.selectClipAtPlayhead()
        #expect(ses.selection == [f.v0.id])
    }
}
