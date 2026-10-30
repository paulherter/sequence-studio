import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import SQUIKit
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

private func clip(_ startFrame: Int64, _ frames: Int64) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * frames), start: fd * startFrame)
}

/// 1000 x 400 pt at scale 1, V1 with clips at 0...50 and 100...150 (Fast Cut when `fastCut`).
private func makePanel(fastCut: Bool = false) -> (TimelinePanel, Timeline) {
    var t = Timeline(name: "t", frameDuration: fd,
                     tracks: [Track(kind: .video, clips: [clip(0, 50), clip(100, 50)]), Track(kind: .video), Track(kind: .audio)])
    if fastCut { t.editMode = .magnetic }
    var p = TimelinePanel()
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    p.sync(timeline: t, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
    return (p, t)
}

@Suite struct TimelineCursorTests {
    @Test func selectionToolTrimsAtClipEdges() throws {
        let (p, t) = makePanel()
        let row = try #require(p.rows.first { $0.track == t.tracks[0].id })
        let y = Float(row.y + row.height * 0.7)
        let head = Float(p.geometry.x(for: fd * 100)) + 2, tail = Float(p.geometry.x(for: fd * 50)) - 2
        #expect(p.cursor(at: head, y: y) == .trimIn)
        #expect(p.cursor(at: tail, y: y) == .trimOut)
        #expect(p.cursor(at: 2000, y: y) == nil)                       // outside the panel: the host's arrow
    }

    @Test func razorToolShowsTheRazorOverTheTracks() throws {
        var (p, t) = makePanel()
        _ = p.key(.character("c"), modifiers: [])
        let row = try #require(p.rows.first { $0.track == t.tracks[0].id })
        let x = Float(p.geometry.x(for: fd * 25))
        #expect(p.cursor(at: x, y: Float(row.y + row.height * 0.5)) == .razor)
    }

    @Test func rowEdgeResizes() throws {
        let (p, _) = makePanel()
        let x = TimelineGeometry.contentOriginX + 300
        let y = try #require(stride(from: TimelineGeometry.rulerHeight, to: 400, by: 1).first {
            TrackSizing.zone(at: CGPoint(x: x, y: $0), rows: p.rows, viewWidth: 1000) != nil })
        #expect(p.cursor(at: Float(x), y: Float(y)) == .resizeUpDown)
    }

    @Test func dragKeepsThePressCursorAndPublishesIt() throws {
        var (p, t) = makePanel()
        let row = try #require(p.rows.first { $0.track == t.tracks[0].id })
        let y = Float(row.y + row.height * 0.7), x = Float(p.geometry.x(for: fd * 100)) + 2
        let hover = HostHover()
        HostHover.$current.withValue(hover) {
            hover.beginEvent(.mouseMoved(x: x, y: y))
            _ = p.handle(.mouseMoved(x: x, y: y))
            #expect(hover.cursor == .trimIn)
            _ = p.handle(.mouseDown(x: x, y: y, modifiers: []))
            hover.beginEvent(.mouseDragged(x: x + 200, y: y))
            _ = p.handle(.mouseDragged(x: x + 200, y: y))      // far off the edge: the trim cursor stays
            #expect(hover.cursor == .trimIn)
            _ = p.handle(.mouseUp(x: x + 200, y: y))
        }
    }

    @Test func headerButtonsOfferTheirTips() throws {
        var (p, t) = makePanel()
        let row = try #require(p.rows.first { $0.track == t.tracks[0].id })
        let chip = TimelinePanel.chipRect(height: row.height)
        let x = Float(TimelineGeometry.toolColumnWidth + chip.midX), y = Float(row.y + chip.midY)
        let hover = HostHover()
        HostHover.$current.withValue(hover) {
            let e = InputEvent.mouseMoved(x: x, y: y)
            hover.beginEvent(e)
            _ = p.handle(e)
            hover.endEvent(e, now: 0)
        }
        #expect(hover.tooltip.text == "Target Track")
    }

    /// A move through `handle` with its own `HostHover`; returns the offered tip.
    private func tipAfterMove(_ x: Float, _ y: Float, _ route: (InputEvent) -> Void) -> String? {
        let hover = HostHover()
        HostHover.$current.withValue(hover) {
            let e = InputEvent.mouseMoved(x: x, y: y)
            hover.beginEvent(e)
            route(e)
            hover.endEvent(e, now: 0)
        }
        return hover.tooltip.text
    }

    @MainActor @Test func headerBarOffersTheMacTips() throws {
        let s = EditorSession(project: Project(name: "P", timelines: [Timeline(name: "Main", frameDuration: fd, tracks: [Track(kind: .video)])]))
        var h = TimelineHeaderStrip()
        _ = h.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1, state: .make(session: s, panel: TimelinePanel()))
        let snap = h.frames.snap
        let tip = try #require(tipAfterMove(Float(snap.midX), Float(snap.midY)) { _ = h.handle($0) })
        #expect(tip.hasPrefix("Snapping") && tip.hasSuffix(" · Clips snap to edits, markers and the playhead."))
        let mode = h.frames.editMode
        #expect(tipAfterMove(Float(mode.midX), Float(mode.midY)) { _ = h.handle($0) }?.hasPrefix("Normal · ") == true)
        #expect(tipAfterMove(Float(snap.midX), 390) { _ = h.handle($0) } == nil)   // under the bar: no tip
    }

    @Test func toolStripOffersToolTipsWithTheirHelp() throws {
        var t = ToolStrip()
        t.followsPrefs = false
        t.edge = .left
        t.visible = true
        _ = t.layout(DrawRect(x: 0, y: 0, w: 800, h: 300), scale: 1)
        let razor = t.slots.tools[1]
        let tip = try #require(tipAfterMove(Float(razor.midX), Float(razor.midY)) { _ = t.handle($0, state: ToolState()) })
        #expect(tip.hasPrefix("Blade") && tip.hasSuffix(" · Cuts a clip where you click."))
        let grip = t.slots.grip
        #expect(tipAfterMove(Float(grip.midX), Float(grip.midY)) { _ = t.handle($0, state: ToolState()) } == ToolStripTools.gripTip)
    }

    @Test func fastCutBacktickTapMaximizesThePanel() {
        var (p, _) = makePanel(fastCut: true)
        #expect(p.timeline.isFastCut)
        _ = p.key(.character("`"), modifiers: [])
        #expect(p.keyUp(.character("`")).contains(.command(.maximizePanel)))
        // A key during the hold makes it a hold, not a tap.
        _ = p.key(.character("`"), modifiers: [])
        _ = p.key(.character("c"), modifiers: [])
        #expect(!p.keyUp(.character("`")).contains(.command(.maximizePanel)))
        // Normal: the key map already maximized on the key-down.
        var (n, _) = makePanel()
        _ = n.key(.character("`"), modifiers: [])
        #expect(!n.keyUp(.character("`")).contains(.command(.maximizePanel)))
    }
}
