import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

/// V1 with one 100-frame clip, A1 below; a 1000 x 400 pt panel synced to the session, behind a host whose `panel`
/// reaches it (the bridge sets the keystone bar through it).
@MainActor private final class Rig {
    var p = TimelinePanel()
    let s: EditorSession
    let host = TimelineHost()

    init() {
        let v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 100), start: .zero)
        let a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 100), start: .zero)
        let t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [v]), Track(kind: .audio, clips: [a])])
        s = EditorSession(project: Project(name: "P", timelines: [t]))
        p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
        host.panel = { [unowned self] change in change(&p) }
        sync()
    }

    func sync() {
        p.sync(timeline: s.activeTimeline!, selection: s.selection, playhead: s.playhead, selectedTransition: nil,
               labels: LabelResolver())
    }

    @discardableResult
    func run(_ actions: [TimelineAction]) -> [String] {
        let lines = actions.compactMap { TimelineSessionBridge.apply($0, to: s, host: host) }
        sync()
        return lines
    }

    var clip: Clip { s.activeTimeline!.tracks[0].clips[0] }
    var row: TrackRow { p.rows.first { $0.track == s.activeTimeline!.tracks[0].id }! }
    func x(_ t: Time) -> Float { Float(p.geometry.x(for: t)) }
}

@MainActor @Suite("TimelineKeystones") struct TimelineKeystonesTests {
    let punchIn = Keystone.builtIn(named: "Punch In")!

    @Test func payloadStringRoundTrips() throws {
        let s = try #require(KeystoneDrag.string(for: punchIn))
        #expect(KeystoneDrag.keystone(from: s) == punchIn)
        #expect(KeystoneDrag.keystone(from: "not a keystone") == nil)
    }

    @Test func barEdgesStayInsideTheClip() {
        let span = KeystoneSpan(start: fd * 10, duration: fd * 10, properties: [.scale])
        let end = KeystoneBar.dragged(span, edge: .end, toLocal: fd * 200, clipDuration: fd * 100, minimum: fd)
        #expect(end.start == fd * 10 && end.end == fd * 100)
        let start = KeystoneBar.dragged(span, edge: .start, toLocal: fd * 30, clipDuration: fd * 100, minimum: fd)
        #expect(start.start == fd * 19 && start.end == fd * 20)
        let r = CGRect(x: 100, y: 50, width: 80, height: 12)
        #expect(KeystoneBar.edge(at: CGPoint(x: 103, y: 55), barRect: r) == .start)
        #expect(KeystoneBar.edge(at: CGPoint(x: 178, y: 55), barRect: r) == .end)
        #expect(KeystoneBar.edge(at: CGPoint(x: 140, y: 55), barRect: r) == nil)
    }

    @Test func dropShowsTheGhostThenAppliesWithTheBar() throws {
        let r = Rig()
        let y = Float(r.row.y + r.row.height / 2), x = r.x(fd * 50)
        let hit = r.p.keystoneHover(punchIn, x: x, y: y)
        #expect(hit)
        let ghost = try #require(r.p.keystoneGhost)
        #expect(ghost.clip == r.clip.id && ghost.span.duration > .zero)
        // Off the clips (the audio row, empty space) there is no target; leaving drops the ghost.
        let miss = r.p.keystoneHover(punchIn, x: r.x(fd * 150), y: y)
        #expect(!miss)
        #expect(r.p.keystoneGhost == nil)
        let actions = r.p.keystoneDrop(punchIn, x: x, y: y)
        #expect(actions == [.dropKeystone(punchIn, clip: r.clip.id, span: ghost.span)])
        #expect(r.p.keystoneGhost == nil)
        #expect(r.run(actions).isEmpty)
        #expect(r.clip.animation.scale.track.keys.count >= 2)
        #expect(r.p.keystoneBar?.clip == r.clip.id && r.p.keystoneBar?.name == "Punch In")
    }

    @Test func barEdgeDragRestretchesInOneUndoStep() throws {
        let r = Rig()
        let y = Float(r.row.y + r.row.height / 2)
        r.run(r.p.keystoneDrop(punchIn, x: r.x(fd * 20), y: y))
        let bar = try #require(r.p.keystoneBar)
        try #require(r.row.height >= KeystoneBar.minimumRowHeight)
        let rect = KeystoneBar.rect(span: bar.span, clipStart: r.clip.start, row: r.row, geometry: r.p.geometry)
        let keysBefore = r.clip.animation.scale.track.keys.map(\.time)
        let undoBefore = r.s.canUndo
        var out = r.p.handle(.mouseDown(x: Float(rect.maxX), y: Float(rect.midY), modifiers: []))
        #expect(out.isEmpty && r.p.isDragging)
        let to = r.x(r.clip.start + bar.span.end + fd * 20)
        out += r.p.handle(.mouseDragged(x: to, y: Float(rect.midY)))
        #expect(r.p.keystoneBar!.span.end > bar.span.end)                   // the preview follows live
        out += r.p.handle(.mouseUp(x: to, y: Float(rect.midY)))
        guard case .restretchKeystone(let clip, let old, let new, _)? = out.last else { Issue.record("no restretch"); return }
        #expect(clip == r.clip.id && old == bar.span && new.end > bar.span.end)
        #expect(r.run(out).isEmpty)
        #expect(r.p.keystoneBar?.span == new)
        #expect(r.clip.animation.scale.track.keys.map(\.time) != keysBefore)
        #expect(undoBefore && r.s.undo())
        r.sync()
        #expect(r.clip.animation.scale.track.keys.map(\.time) == keysBefore)
        #expect(r.p.keystoneBar == nil)                // undo changed its clip: the bar goes
    }

    @Test func drawsTheBarAndTheGhost() {
        let r = Rig()
        let y = Float(r.row.y + r.row.height / 2)
        var bare = DrawList(width: 1000, height: 400)
        r.p.draw(into: &bare, atlas: nil)
        r.run(r.p.keystoneDrop(punchIn, x: r.x(fd * 20), y: y))
        r.p.keystoneHover(punchIn, x: r.x(fd * 60), y: y)
        var list = DrawList(width: 1000, height: 400)
        r.p.draw(into: &list, atlas: nil)
        #expect(list.quads.count > bare.quads.count)
    }
}

/// Window > Keystones docked in a dock card: the list fills the card, no own header or close button.
@MainActor @Suite struct KeystonePaletteDockedTests {
    @Test func dockedListFillsTheCardAndHasNoCloseButton() {
        var p = KeystonePalette()
        p.keystones = Keystone.builtIns
        p.layout(docked: CGRect(x: 10, y: 20, width: 300, height: 400), scale: 1)
        #expect(p.isVisible && p.isDocked)
        #expect(p.frame == CGRect(x: 10, y: 20, width: 300, height: 400))
        #expect(p.row(at: CGPoint(x: 100, y: 20 + CGFloat(DrawTheme.Spacing.xs) + 5)) == 0)
        // Where the floating card's close button sits nothing closes the docked list.
        _ = p.handle(.mouseDown(x: Float(p.closeRect.midX), y: Float(p.closeRect.midY), modifiers: []))
        _ = p.handle(.mouseUp(x: Float(p.closeRect.midX), y: Float(p.closeRect.midY)))
        #expect(p.isVisible)
    }

    @Test func dockedHidesWithoutACard() {
        var p = KeystonePalette()
        p.layout(docked: nil, scale: 1)
        #expect(!p.isVisible)
    }
}
