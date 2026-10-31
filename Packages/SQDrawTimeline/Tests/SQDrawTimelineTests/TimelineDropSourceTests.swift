import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

/// V1 with one 100-frame clip and a second sequence `inner` (50 frames, with audio) in the project, plus one media item.
@MainActor private func setup() -> (TimelinePanel, EditorSession, MediaRef, Timeline) {
    let v = VideoTrackInfo(width: 1920, height: 1080, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                           nominalFrameDuration: fd, isVariableFrameRate: false)
    let m = MediaRef(name: "a", path: "/nonexistent/a.mov", fingerprint: MediaFingerprint(size: 1),
                     duration: fd * 50, info: MediaInfo(duration: fd * 50, video: v, audio: nil))
    let c = Clip(name: "c", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: fd * 100), start: .zero)
    let ia = Clip(name: "ia", media: m.id, kind: .audio, source: TimeRange(start: .zero, duration: fd * 50), start: .zero)
    let iv = Clip(name: "iv", media: m.id, kind: .video, source: TimeRange(start: .zero, duration: fd * 50), start: .zero)
    let host = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c]), Track(kind: .audio)])
    let inner = Timeline(name: "inner", frameDuration: fd, tracks: [Track(kind: .video, clips: [iv]), Track(kind: .audio, clips: [ia])])
    var project = Project(name: "P", timelines: [host, inner])
    project.media = [m]
    let s = EditorSession(project: project)
    s.setActiveTimeline(host.id)
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    p.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
    return (p, s, m, inner)
}

@MainActor @Suite struct TimelineDropSourceTests {
    @Test func ghostItemsForMediaSequencesAndFiles() {
        let (_, s, m, inner) = setup()
        let media = TimelineDrop.items(for: .media([m.id]), in: s)
        #expect(media == [DropItem(name: "a", duration: fd * 50, hasVideo: true, hasAudio: false)])
        let seq = TimelineDrop.items(for: .sequences([inner.id]), in: s)
        #expect(seq.first?.hasAudio == true && seq.first?.duration == fd * 50)
        let files = TimelineDrop.items(for: .files([URL(fileURLWithPath: "/x/s.wav"), URL(fileURLWithPath: "/x/p.png")]), in: s)
        #expect(files.map(\.hasVideo) == [false, true] && files.map(\.hasAudio) == [true, false])
    }

    @Test func sequenceDropNestsItAtTheGhostAsOneUndoStep() throws {
        var (p, s, _, inner) = setup()
        let row = p.rows[0], y = Float(row.y + row.height / 2), x = Float(p.geometry.x(for: fd * 150))
        p.dropHover(items: TimelineDrop.items(for: .sequences([inner.id]), in: s), x: x, y: y, insert: false)
        let a = try #require(p.dropCommit(media: [], x: x, y: y, insert: false).first)
        #expect(TimelineDrop.place(.sequences([inner.id]), at: a, in: s))
        let clips = s.activeTimeline!.tracks[0].clips
        #expect(clips.count == 2 && clips.contains { $0.isNested })
        s.undo()
        #expect(s.activeTimeline!.tracks[0].clips.count == 1)
    }

    @Test func filesDoNotPlaceBeforeTheyAreImported() throws {
        var (p, s, m, _) = setup()
        let row = p.rows[0], y = Float(row.y + row.height / 2), x = Float(p.geometry.x(for: fd * 150))
        let a = try #require(p.dropCommit(media: [], x: x, y: y, insert: false).first)
        #expect(!TimelineDrop.place(.files([URL(fileURLWithPath: m.path)]), at: a, in: s))
        #expect(TimelineDrop.place(.media([m.id]), at: a, in: s))      // what the host does after the import
        #expect(s.activeTimeline!.tracks[0].clips.count == 2)
    }

    @Test func altReleaseOverAClipReplacesItWithTheFirstItem() throws {
        var (p, s, m, inner) = setup()
        let row = p.rows[0], y = Float(row.y + row.height / 2)
        let first = s.activeTimeline!.tracks[0].clips[0].id
        #expect(p.clipID(x: Float(p.geometry.x(for: fd * 10)), y: y) == first)
        #expect(p.clipID(x: Float(p.geometry.x(for: fd * 150)), y: y) == nil)   // past the clip: an ordinary drop
        // A 50-frame clip of `m` at frame 150, so both replacements are long enough.
        let a = try #require(p.dropCommit(media: [], x: Float(p.geometry.x(for: fd * 150)), y: y, insert: false).first)
        #expect(TimelineDrop.place(.media([m.id]), at: a, in: s))
        let clip = try #require(s.activeTimeline!.tracks[0].clips.first { $0.start == fd * 150 }).id
        #expect(!TimelineDrop.replace(.files([URL(fileURLWithPath: m.path)]), clip: clip, matchSourceTime: nil, in: s))
        #expect(TimelineDrop.replace(.sequences([inner.id]), clip: clip, matchSourceTime: nil, in: s))
        #expect(s.activeTimeline!.tracks[0].clips.first { $0.start == fd * 150 }?.isNested == true)
        // Media: a second item replaces the first (one undo step).
        s.undo()
        var m2 = m
        m2.id = UUID()
        m2.name = "b"
        var project = s.project
        project.media.append(m2)
        let s2 = EditorSession(project: project)
        s2.setActiveTimeline(s.activeTimelineID!)
        #expect(TimelineDrop.replace(.media([m2.id, m.id]), clip: first, matchSourceTime: nil, in: s2) == false)  // 100 frames > 50
        #expect(TimelineDrop.replace(.media([m2.id, m.id]), clip: clip, matchSourceTime: nil, in: s2))
        #expect(s2.activeTimeline!.tracks[0].clips.first { $0.id == clip }?.media == m2.id)
    }
}

@MainActor private final class MenuLog { var v: [String] = [] }

@MainActor @Suite struct KeystonePaletteTests {
    private func palette() -> KeystonePalette {
        var k = KeystonePalette()
        k.keystones = Array(Keystone.builtIns.prefix(4))
        k.isVisible = true
        k.layout(in: CGRect(x: 0, y: 0, width: 1000, height: 400), scale: 2)
        return k
    }

    private func px(_ p: CGPoint) -> (Float, Float) { (Float(p.x * 2), Float(p.y * 2)) }

    @Test func pressAndDragReportsTheKeystoneUntilTheRelease() {
        var k = palette()
        let r = k.rowRect(1), (x, y) = px(CGPoint(x: r.midX, y: r.midY))
        #expect(k.handle(.mouseDown(x: x, y: y, modifiers: [])) == [])
        #expect(k.selectedID == k.keystones[1].id)
        #expect(k.handle(.mouseDragged(x: x + 2, y: y)) == [])                 // inside the slop
        #expect(k.handle(.mouseDragged(x: x - 400, y: y + 300)) == [.drag(k.keystones[1], x: x - 400, y: y + 300)])
        #expect(k.handle(.mouseUp(x: x - 400, y: y + 300)) == [.drop(k.keystones[1], x: x - 400, y: y + 300)])
        #expect(!k.isDragging)
        #expect(k.handle(.mouseDragged(x: 0, y: 0)) == nil)                    // no press: not the card's
    }

    @Test func dragPointFollowsTheDragAndClearsOnRelease() {
        var k = palette()
        let r = k.rowRect(1), (x, y) = px(CGPoint(x: r.midX, y: r.midY))
        _ = k.handle(.mouseDown(x: x, y: y, modifiers: []))
        #expect(k.dragPoint == nil)
        _ = k.handle(.mouseDragged(x: x - 400, y: y + 300))
        #expect(k.dragPoint == CGPoint(x: CGFloat(x - 400) / 2, y: CGFloat(y + 300) / 2))
        _ = k.handle(.mouseUp(x: x - 400, y: y + 300))
        #expect(k.dragPoint == nil)
    }

    @Test func changedChipAndHelpTipDraw() {
        var k = palette()
        k.changed = [k.keystones[0].id]
        var c = Canvas(list: DrawList(width: 2000, height: 800), atlas: nil, scale: 2)
        k.draw(&c)
        #expect(!c.list.quads.isEmpty)
        let r = k.rowRect(0)
        #expect(k.help(at: CGPoint(x: r.midX, y: r.midY)) != nil)
        #expect(k.help(at: .zero) == nil)
    }

    @Test func escCancelsTheDragAndDoubleClickApplies() {
        var k = palette()
        nonisolated(unsafe) var t = 10.0
        k.clock = { t }
        let r = k.rowRect(0), (x, y) = px(CGPoint(x: r.midX, y: r.midY))
        _ = k.handle(.mouseDown(x: x, y: y, modifiers: []))
        _ = k.handle(.mouseDragged(x: x - 100, y: y))
        #expect(k.handle(.keyDown(.escape, modifiers: [])) == [.cancel])
        #expect(k.handle(.mouseUp(x: x - 100, y: y)) == nil)
        t = 20
        _ = k.handle(.mouseDown(x: x, y: y, modifiers: []))
        _ = k.handle(.mouseUp(x: x, y: y))
        t = 20.2
        #expect(k.handle(.mouseDown(x: x, y: y, modifiers: [])) == [.apply(k.keystones[0])])
    }

    @Test func rightClickOptionsAndDeleteAskTheHost() {
        var k = palette()
        let r = k.rowRect(2), pt = CGPoint(x: r.midX, y: r.midY), (x, y) = px(pt)
        #expect(k.handle(.mouseDown(x: x, y: y, modifiers: .secondary)) == [.menu(k.keystones[2], at: pt)])
        #expect(k.selectedID == k.keystones[2].id)
        let (ox, oy) = px(CGPoint(x: k.optionsRect.midX, y: k.optionsRect.midY))
        guard case .options? = k.handle(.mouseDown(x: ox, y: oy, modifiers: []))?.first else { Issue.record("no options"); return }
        // Delete goes to the selected row while the pointer is over the card.
        #expect(k.handle(.keyDown(.delete, modifiers: [])) == nil)
        _ = k.handle(.mouseMoved(x: x, y: y))
        #expect(k.handle(.keyDown(.delete, modifiers: [])) == [.delete(k.keystones[2])])
    }

    @Test func menusFollowTheMacPanel() {
        let log = MenuLog()
        let a = KeystonePaletteActions(apply: { log.v.append("apply \($0.name)") }, saveFromClip: { log.v.append("save") },
                                       editCurve: { log.v.append("curve \($0.name)") }, useKeyframeEasing: { _ in log.v.append("keys") },
                                       delete: { log.v.append("delete \($0.name)") })
        let k = Keystone.builtIns[0]
        #expect(KeystonePalette.contextItems(for: nil, canDelete: false, a).map(\.title) == ["Save Keystone from Selected Clip\u{2026}"])
        let items = KeystonePalette.contextItems(for: k, canDelete: true, a)
        #expect(items.filter { !$0.title.isEmpty }.map(\.title) == ["Apply to Selected Clip", "Edit Curve\u{2026}", "Use Keyframe Easing",
                                                                   "Save Keystone from Selected Clip\u{2026}", "Reset to Built-in"])
        for i in items where i.isEnabled { i.action?() }
        #expect(log.v == ["apply \(k.name)", "curve \(k.name)", "save", "delete \(k.name)"])   // no curve of its own: easing dimmed
        #expect(KeystonePalette.optionItems(selected: k, a).map(\.title) == ["Save Keystone from Selected Clip\u{2026}", "Apply to Selected Clip"])
    }

    @Test func closeHidesAndOutsideClicksPassThrough() {
        var k = palette()
        #expect(k.handle(.mouseDown(x: 10, y: 10, modifiers: [])) == nil)
        let (x, y) = px(CGPoint(x: k.closeRect.midX, y: k.closeRect.midY))
        #expect(k.handle(.mouseDown(x: x, y: y, modifiers: [])) == [])
        #expect(!k.isVisible)
        var list = DrawList(width: 2000, height: 800)
        var c = Canvas(list: list, atlas: nil, scale: 2)
        k.isVisible = true
        k.draw(&c)
        list = c.list
        #expect(!list.quads.isEmpty)
    }
}
