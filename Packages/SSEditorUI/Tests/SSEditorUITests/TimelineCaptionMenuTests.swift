import CoreGraphics
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1, 24)
private func X(_ f: Double) -> CGFloat { 162 + CGFloat(f) * 4 }

private func cap(_ a: Int64, _ b: Int64, _ text: String = "hi") -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: fd * a, end: fd * b))
}
private func mk(_ start: Int64, _ frames: Int64, kind: TrackKind = .video, link: UUID? = nil) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: fd * 50, duration: fd * frames),
         start: fd * start, link: link, mediaDuration: fd * 200)
}

/// Caption row C1 at y 22..<44, V1 (32 pt) at 44..<76.
private struct Fx {
    var c1 = cap(0, 20), c2 = cap(30, 50)
    var clip = mk(0, 40)
    var tl: Timeline
    let yC: CGFloat = 33, yV1: CGFloat = 60
    init() {
        var ct = CaptionTrack(name: "")
        try! ct.replaceAll([c1, c2])
        tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip])])
        tl.captionTracks = [ct]
    }
    func interaction(snapping: Bool = false) -> TimelineInteraction {
        var i = TimelineInteraction(timeline: tl, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: .selection, snapping: snapping, linkedSelection: true)
        return i
    }
}

private func drag(_ i: inout TimelineInteraction, _ a: CGPoint, _ b: CGPoint) -> TimelineCommit? {
    i.mouseDown(a, modifiers: [])
    i.mouseDragged(CGPoint(x: (a.x + b.x) / 2, y: a.y), modifiers: [])
    i.mouseDragged(b, modifiers: [])
    return i.mouseUp(b, modifiers: [])
}

@Suite struct CaptionGeometryTests {
    @Test func captionRowsSitAboveVideoRows() {
        let f = Fx()
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 4)
        let cr = g.captionRows(for: f.tl)
        #expect(cr.count == 1)
        #expect(cr[0].y == TimelineGeometry.rulerHeight && cr[0].height == 22 && cr[0].label == "C1")
        #expect(g.rows(for: f.tl)[0].y == cr[0].maxY)
        #expect(g.contentHeight(for: f.tl) == TimelineGeometry.rulerHeight + 22 + 32)
    }

    @Test func noCaptionTracksLeavesLayoutUnchanged() {
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video)])
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 4)
        #expect(g.captionRows(for: tl).isEmpty)
        #expect(g.rows(for: tl)[0].y == TimelineGeometry.rulerHeight)
    }

    @Test func hitTestCaptionZonesGapAndHeader() {
        let f = Fx()
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 4)
        #expect(g.hitTest(CGPoint(x: X(10), y: f.yC), in: f.tl) == .caption(f.c1.id, zone: .body))
        #expect(g.hitTest(CGPoint(x: X(0) + 1, y: f.yC), in: f.tl) == .caption(f.c1.id, zone: .head))
        #expect(g.hitTest(CGPoint(x: X(20) - 1, y: f.yC), in: f.tl) == .caption(f.c1.id, zone: .tail))
        if case .captionGap(_, let t) = g.hitTest(CGPoint(x: X(25), y: f.yC), in: f.tl) { #expect(t == fd * 25) } else { Issue.record("gap") }
        #expect(g.hitTest(CGPoint(x: 100, y: f.yC), in: f.tl) == .captionHeader(f.tl.captionTracks[0].id))
        #expect(g.hitTest(CGPoint(x: X(10), y: f.yV1), in: f.tl) == .clip(f.clip.id, zone: .body))
    }

    @Test func previewText() {
        #expect(CaptionDrawing.preview(CaptionItem(lines: ["a", "b"], range: TimeRange(start: .zero, end: fd))) == "a b")
        #expect(CaptionDrawing.preview(CaptionItem(lines: [], range: TimeRange(start: .zero, end: fd))) == "(empty)")
    }
}

@Suite struct CaptionInteractionTests {
    @Test func clickSelectsCaptionAndClearsClips() {
        let f = Fx()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(10), y: f.yV1), modifiers: []); _ = i.mouseUp(CGPoint(x: X(10), y: f.yV1), modifiers: [])
        #expect(!i.selection.isEmpty)
        i.mouseDown(CGPoint(x: X(10), y: f.yC), modifiers: []); _ = i.mouseUp(CGPoint(x: X(10), y: f.yC), modifiers: [])
        #expect(i.captionSelection == [f.c1.id] && i.selection.isEmpty)
        i.mouseDown(CGPoint(x: X(40), y: f.yC), modifiers: .shift); _ = i.mouseUp(CGPoint(x: X(40), y: f.yC), modifiers: .shift)
        #expect(i.captionSelection == [f.c1.id, f.c2.id])
    }

    @Test func moveCaption() {
        let f = Fx()
        var i = f.interaction()
        let c = drag(&i, CGPoint(x: X(10), y: f.yC), CGPoint(x: X(15), y: f.yC))
        #expect(c?.undoName == "Move Caption")
        #expect(c?.timeline.captionTracks[0].item(f.c1.id)?.range == TimeRange(start: fd * 5, end: fd * 25))
        #expect(c?.captionSelection == [f.c1.id])
    }

    @Test func moveClampedByNeighbour() {
        let f = Fx()
        var i = f.interaction()
        let c = drag(&i, CGPoint(x: X(10), y: f.yC), CGPoint(x: X(40), y: f.yC))
        #expect(c?.timeline.captionTracks[0].item(f.c1.id)?.range.end == fd * 30)
    }

    @Test func trimTailAndHead() {
        let f = Fx()
        var i = f.interaction()
        let c = drag(&i, CGPoint(x: X(20) - 1, y: f.yC), CGPoint(x: X(25), y: f.yC))
        #expect(c?.undoName == "Trim Caption")
        #expect(c?.timeline.captionTracks[0].item(f.c1.id)?.range.end == fd * 25)
        var j = f.interaction()
        let d = drag(&j, CGPoint(x: X(30) + 1, y: f.yC), CGPoint(x: X(35), y: f.yC))
        #expect(d?.timeline.captionTracks[0].item(f.c2.id)?.range.start == fd * 35)
    }

    @Test func lockedTrackRejectsMove() {
        var f = Fx()
        f.tl.captionTracks[0].isLocked = true
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(10), y: f.yC), modifiers: [])
        i.mouseDragged(CGPoint(x: X(12), y: f.yC), modifiers: [])
        i.mouseDragged(CGPoint(x: X(15), y: f.yC), modifiers: [])
        #expect(i.isRejected)
        #expect(i.mouseUp(CGPoint(x: X(15), y: f.yC), modifiers: []) == nil)
    }

    @Test func deleteSelectedCaption() {
        let f = Fx()
        var i = f.interaction()
        i.mouseDown(CGPoint(x: X(40), y: f.yC), modifiers: []); _ = i.mouseUp(CGPoint(x: X(40), y: f.yC), modifiers: [])
        let c = i.deleteSelection(ripple: false)
        #expect(c?.timeline.captionTracks[0].items.map(\.id) == [f.c1.id])
        #expect(i.captionSelection.isEmpty)
    }

    @Test func captionItemLookupForDoubleClick() {
        let f = Fx()
        let i = f.interaction()
        #expect(i.captionItem(at: CGPoint(x: X(10), y: f.yC)) == f.c1.id)
        #expect(i.captionItem(at: CGPoint(x: X(10), y: f.yV1)) == nil)
    }

    @Test func contextSelect() {
        let f = Fx()
        var i = f.interaction()
        i.contextSelect(at: CGPoint(x: X(10), y: f.yV1))
        #expect(i.selection == [f.clip.id])
        i.contextSelect(at: CGPoint(x: X(10), y: f.yC))
        #expect(i.captionSelection == [f.c1.id] && i.selection.isEmpty)
    }
}

@Suite struct NestAndMenuTests {
    private func project() -> (Project, Timeline, Clip, Clip) {
        let a = mk(0, 20), b = mk(20, 20)
        let tl = Timeline(name: "Main", frameDuration: fd, tracks: [Track(kind: .video, clips: [a, b])])
        var p = Project(name: "p")
        p.timelines = [tl]
        return (p, tl, a, b)
    }

    @Test func nestProducesOneClipAndNewSequence() {
        let (p, tl, a, b) = project()
        var i = TimelineInteraction(timeline: tl, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.setSelection([a.id, b.id])
        let r = i.nest(name: "", in: p)
        #expect(r != nil)
        #expect(r?.project.timelines.count == 2)
        #expect(r?.commit.timeline.tracks[0].clips.count == 1)
        #expect(r?.commit.undoName == "Nest")
        #expect(r?.project.timeline(r!.sequence)?.name == "Nested Sequence 01")
        #expect(i.selection == r?.commit.selection)
        #expect(!i.isRejected)
    }

    @Test func nestUsesGivenName() {
        let (p, tl, a, _) = project()
        var i = TimelineInteraction(timeline: tl, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.setSelection([a.id])
        let r = i.nest(name: "  Intro ", in: p)
        #expect(r?.project.timeline(r!.sequence)?.name == "Intro")
    }

    @Test func nestErrorsReject() {
        var (p, tl, a, _) = project()
        var i = TimelineInteraction(timeline: tl, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        #expect(i.nest(name: "x", in: p) == nil)
        #expect(i.isRejected && i.rejectionMessage != nil)
        tl.tracks[0].isLocked = true
        p.timelines = [tl]
        i.reset(timeline: tl)
        i.setSelection([a.id])
        #expect(i.nest(name: "x", in: p) == nil)
        #expect(i.isRejected && i.rejectionMessage == "A selected clip is on a locked track.")
        #expect(i.timeline == tl)
    }

    @Test func defaultNames() {
        #expect(NestSheet.defaultName(existing: []) == "Nested Sequence 01")
        #expect(NestSheet.defaultName(existing: ["Nested Sequence 01", "Nested Sequence 03"]) == "Nested Sequence 02")
        #expect(NestSheet.resolvedName("  ", existing: []) == "Nested Sequence 01")
        #expect(NestSheet.resolvedName(" A ", existing: []) == "A")
    }

    private func enabled(_ items: [TimelineMenuItem]) -> Set<TimelineMenuAction> {
        Set(items.filter(\.isEnabled).map(\.action))
    }

    @Test func menuStates() {
        let (_, tl, a, b) = project()
        let none = TimelineContextMenu.items(timeline: tl, selection: [], clipboardHasClips: false)
        #expect(enabled(none).isEmpty)
        let one = TimelineContextMenu.items(timeline: tl, selection: [a.id], clipboardHasClips: true)
        #expect(enabled(one) == [.cut, .copy, .paste, .pasteInsert, .delete, .rippleDelete, .nest, .rename, .label, .setToFrameSize, .scaleToFrameSize])
        let two = TimelineContextMenu.items(timeline: tl, selection: [a.id, b.id], clipboardHasClips: false)
        #expect(enabled(two) == [.cut, .copy, .delete, .rippleDelete, .link, .nest, .label, .setToFrameSize, .scaleToFrameSize])
        // No dead entries: features we do not have are not listed.
        #expect(two.count == 12)
    }

    @Test func menuShowsUnlinkForLinkedClips() {
        let l = UUID()
        let v = mk(0, 10, link: l), au = mk(0, 10, kind: .audio, link: l)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [au])])
        let items = TimelineContextMenu.items(timeline: tl, selection: [v.id, au.id], clipboardHasClips: false)
        #expect(items.contains { $0.action == .unlink && $0.isEnabled })
        #expect(!items.contains { $0.action == .link })
    }

    @Test func captionOnlySelectionEnablesDelete() {
        let f = Fx()
        let items = TimelineContextMenu.items(timeline: f.tl, selection: [], captionSelection: [f.c1.id], clipboardHasClips: false)
        #expect(enabled(items) == [.delete])
    }

    @Test func gapAndEmptyMenus() {
        let gap = TimelineContextMenu.gapItems(clipboardHasClips: false)
        #expect(gap.first?.action == .rippleDelete && gap.first?.isEnabled == true)
        #expect(!gap.contains { $0.action == .paste && $0.isEnabled })
        let empty = TimelineContextMenu.emptyItems(clipboardHasClips: true)
        #expect(empty.map(\.action) == [.paste, .pasteInsert] && empty.allSatisfy(\.isEnabled))
    }

    @MainActor @Test func nsMenuMirrorsSpec() {
        let items = TimelineContextMenu.items(timeline: Fx().tl, selection: [], clipboardHasClips: false)
        let menu = TimelineContextMenu.makeMenu(items: items) { _ in }
        #expect(menu.items.filter { !$0.isSeparatorItem }.count == items.count)
        #expect(menu.items.first { $0.title == "Nest…" }?.isEnabled == false)
    }
}
