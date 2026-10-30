#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 24)
private func X(_ f: Double) -> CGFloat { TimelineGeometry.contentOriginX + CGFloat(f) * 4 }

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
        #expect(cr[0].y == TimelineGeometry.rulerHeight && cr[0].height == 26 && cr[0].label == "C1")
        #expect(g.rows(for: f.tl)[0].y == cr[0].maxY)
        #expect(g.contentHeight(for: f.tl) == TimelineGeometry.rulerHeight + 26 + 40)
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
        #expect(r?.commit.undoName == "Combine")
        #expect(r?.project.timeline(r!.sequence)?.name == "Combined 01")
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
        #expect(NestSheet.defaultName(existing: []) == "Combined 01")
        #expect(NestSheet.defaultName(existing: ["Combined 01", "Combined 03"]) == "Combined 02")
        #expect(NestSheet.resolvedName("  ", existing: []) == "Combined 01")
        #expect(NestSheet.resolvedName(" A ", existing: []) == "A")
    }

    private func enabled(_ items: [TimelineMenuItem]) -> Set<TimelineMenuAction> {
        Set(items.filter { $0.isEnabled && $0.submenu == nil && $0.action != .newColorMatte }.map(\.action))   // New Color Matte… is always on
    }

    @Test func menuStates() {
        let (_, tl, a, b) = project()
        let none = TimelineContextMenu.items(timeline: tl, selection: [], clipboardHasClips: false)
        #expect(enabled(none) == [.punchInCuts])   // the command falls back to the targeted track's shots
        let one = TimelineContextMenu.items(timeline: tl, selection: [a.id], clipboardHasClips: true)
        #expect(enabled(one) == [.punchInCuts, .cut, .copy, .paste, .pasteInsert, .pasteAttributes, .delete, .rippleDelete, .enable, .group, .nest, .rename, .addClipMarker, .editOriginal, .revealInProject, .label, .setToFrameSize, .setToFillFrame, .speed, .reverse, .timeRemapping, .saveAsPreset])
        let two = TimelineContextMenu.items(timeline: tl, selection: [a.id, b.id], clipboardHasClips: false)
        #expect(enabled(two) == [.punchInCuts, .cut, .copy, .delete, .rippleDelete, .link, .enable, .group, .bundle, .nest, .editOriginal, .revealInProject, .label, .setToFrameSize, .setToFillFrame, .speed, .reverse, .timeRemapping])
        // No dead entries: features we do not have are not listed.
        #expect(two.filter { $0.submenu == nil }.count == 38)
        #expect(two.filter { $0.submenu != nil }.count == 10)
    }

    @Test func shortformEntriesFollowTheCommandRules() throws {
        let (_, tl, a, b) = project()
        let items = TimelineContextMenu.items(timeline: tl, selection: [a.id, b.id], clipboardHasClips: false)
        let actions = items.map(\.action)
        #expect(actions.contains(.removeFillerWords) && actions.contains(.punchInCuts))
        // Remove Filler Words needs audio and caption words; none here.
        #expect(!enabled(items).contains(.removeFillerWords))
        #expect(TimelineContextMenu.punchInShots(timeline: tl, selection: []) == tl.tracks.first { $0.kind == .video }?.clips.filter { $0.isEnabled && !$0.isGenerator }.count)
        let none = TimelineContextMenu.items(timeline: tl, selection: [], clipboardHasClips: false)
        #expect(none.first { $0.action == .removeSilences }?.isEnabled == false)
    }

    @Test func ungroupIsEnabledOnGroupClipsOnly() throws {
        let (p0, tl, a, _) = project()
        var p = p0
        let seq = try p.group(clips: [a.id], in: tl.id)
        let t = try #require(p.timeline(tl.id))
        let g = try #require(t.tracks.flatMap(\.clips).first { $0.sequence == seq })
        let on = TimelineContextMenu.items(timeline: t, selection: [g.id], clipboardHasClips: false, groups: [seq])
        #expect(enabled(on).contains(.ungroup))
        let off = TimelineContextMenu.items(timeline: t, selection: [g.id], clipboardHasClips: false)
        #expect(!enabled(off).contains(.ungroup))
    }

    @Test func menuShowsUnlinkForLinkedClips() {
        let l = UUID()
        let v = mk(0, 10, link: l), au = mk(0, 10, kind: .audio, link: l)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [au])])
        let items = TimelineContextMenu.items(timeline: tl, selection: [v.id, au.id], clipboardHasClips: false)
        #expect(items.contains { $0.action == .unlink && $0.isEnabled })
        #expect(!items.contains { $0.action == .link })
        #expect(items.contains { $0.action == .audioGain && $0.isEnabled })     // an audio clip is selected
    }

    @Test func captionOnlySelectionEnablesDelete() {
        let f = Fx()
        let items = TimelineContextMenu.items(timeline: f.tl, selection: [], captionSelection: [f.c1.id], clipboardHasClips: false)
        #expect(enabled(items) == [.delete])
    }

    @Test func gapAndEmptyMenus() {
        let gap = TimelineContextMenu.gapItems(clipboardHasClips: false)
        #expect(gap.last?.action == .rippleDelete && gap.last?.isEnabled == true)
        #expect(!gap.contains { $0.action == .paste && $0.isEnabled })
        let empty = TimelineContextMenu.emptyItems(clipboardHasClips: true)
        #expect(empty.map(\.action) == [.paste, .pasteInsert, .togglePlaceSequencesAsClips] && empty.allSatisfy(\.isEnabled))
        #expect(!empty[2].isChecked)
        #expect(TimelineContextMenu.emptyItems(clipboardHasClips: false, placeSequencesAsClips: true).last?.isChecked == true)
    }

    @MainActor @Test func sqItemsMirrorSpec() {
        let items = TimelineContextMenu.items(timeline: Fx().tl, selection: [], clipboardHasClips: false)
        let rows = TimelineContextMenu.makeSQItems(items: items) { _ in }
        let actions = rows.filter { $0.kind == .action }
        // Every top-level spec item is one row, plus the Speed Ramp Presets parent.
        #expect(actions.count == items.filter { $0.submenu == nil }.count + 1)
        #expect(actions.first { $0.title == "Combine…" }?.isEnabled == false)
        // Separators sit where the spec asks, never first or doubled.
        #expect(rows.first?.kind != .separator)
        #expect(zip(rows, rows.dropFirst()).allSatisfy { !($0.kind == .separator && $1.kind == .separator) })
    }

    @MainActor @Test func sqItemsCarryShortcutsCheckAndActions() {
        var fired: [TimelineMenuAction] = []
        let items = [TimelineMenuItem(.cut, "Cut", enabled: true, key: "x", modifiers: .command),
                     TimelineMenuItem(.extendToSequenceEnd, "Extend", enabled: true, separatorBefore: true).checked(true),
                     TimelineMenuItem(.delete, "Delete", enabled: false)]
        let rows = TimelineContextMenu.makeSQItems(items: items) { fired.append($0) }
        #expect(rows.map(\.kind) == [.action, .separator, .action, .action])
        #expect(rows[0].shortcut == "\u{2318}X")
        #expect(rows[2].isChecked && !rows[0].isChecked)
        #expect(rows[3].isEnabled == false)
        rows[0].action?()
        rows[2].action?()
        #expect(fired == [.cut, .extendToSequenceEnd])
    }

    @MainActor @Test func labelSubmenuListsDefaultThenColoursAndMarksCurrent() {
        var picked: [LabelColor?] = []
        let items = [TimelineMenuItem(.label, "Label", enabled: true)]
        let rows = TimelineContextMenu.makeSQItems(items: items, labelHandler: { picked.append($0) }, currentLabel: LabelColor.allCases[1]) { _ in }
        #expect(rows.count == 1 && rows[0].isEnabled)
        let sub = rows[0].submenu ?? []
        #expect(sub.count == LabelColor.allCases.count + 2 && sub[1].kind == .separator)
        #expect(sub.filter(\.isChecked).map(\.title) == [LabelColor.allCases[1].displayName])
        sub[0].action?()
        sub[2].action?()
        #expect(picked == [nil, LabelColor.allCases[0]])
        // Without a handler the Label row is disabled.
        #expect(TimelineContextMenu.makeSQItems(items: items) { _ in }[0].isEnabled == false)
    }

    @MainActor @Test func submenuRowsNavigateWithKeys() {
        let (_, tl, a, _) = project()
        let rows = TimelineContextMenu.makeSQItems(items: TimelineContextMenu.items(timeline: tl, selection: [a.id], clipboardHasClips: false)) { _ in }
        var nav = SQMenuNavigator(items: rows)
        nav.move(.first)
        #expect(nav.highlighted != nil)
        let idx = rows.firstIndex { $0.submenu != nil && $0.title == "Speed Ramp Presets" }!
        nav.hover(idx)
        #expect(nav.rightKey() == .openedSubmenu)
        #expect(nav.depth == 2)
        // Return on the first enabled preset runs it; Left closes the submenu.
        guard case .run(let path) = nav.activate() else { Issue.record("expected run"); return }
        #expect(path.first == idx && path.count == 2)
        #expect(nav.leftKey() && nav.depth == 1)
    }

    @MainActor @Test func speedRampPresetsSubmenuMatchesClipMenuCommands() {
        let (_, tl, a, _) = project()
        let items = TimelineContextMenu.items(timeline: tl, selection: [a.id], clipboardHasClips: false).filter { $0.submenu != nil }
        #expect(items.count == SpeedRampPreset.allCases.count * 2)
        #expect(items.allSatisfy { $0.submenu == "Speed Ramp Presets" })
        // Same titles as the Clip menu commands, on-Beat variants off without beat markers.
        for it in items {
            guard case .speedRamp(let p, let onBeat) = it.action else { Issue.record("wrong action"); continue }
            #expect(it.title == EditorCommand.speedRampPreset(p, onBeat: onBeat).title)
            #expect(it.isEnabled == !onBeat)
        }
        let rows = TimelineContextMenu.makeSQItems(items: items) { _ in }
        #expect(rows.count == 1)
        #expect(rows[0].submenu?.filter { $0.kind == .action }.count == 10)
        #expect(rows[0].submenu?.filter { $0.kind == .separator }.count == 1)
    }

    @Test func captionMenuEntriesFollowTheSelectionAndPlayhead() {
        let f = Fx()
        func on(_ items: [TimelineMenuItem]) -> [TimelineMenuAction] { items.filter(\.isEnabled).map(\.action) }
        // One caption selected, playhead inside it.
        let one = TimelineContextMenu.captionItems(timeline: f.tl, captionSelection: [f.c1.id], playhead: fd * 5)
        #expect(on(one) == [.editCaption, .splitCaption, .delete])
        // Playhead in a gap: no split.
        let gap = TimelineContextMenu.captionItems(timeline: f.tl, captionSelection: [f.c1.id], playhead: fd * 25)
        #expect(on(gap) == [.editCaption, .delete])
        // Two captions of one track: merge, no edit.
        let two = TimelineContextMenu.captionItems(timeline: f.tl, captionSelection: [f.c1.id, f.c2.id], playhead: fd * 25)
        #expect(on(two) == [.mergeCaptions, .delete])
    }
}
