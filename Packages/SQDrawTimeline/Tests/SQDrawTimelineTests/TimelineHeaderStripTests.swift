import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import SQUIKit
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

@MainActor private func session(magnetic: Bool = false) -> EditorSession {
    var t = Timeline(name: "Main", frameDuration: fd, tracks: [Track(kind: .video), Track(kind: .audio)])
    if magnetic { t.editMode = .magnetic }
    let inner = Timeline(name: "Inner", frameDuration: fd, tracks: [Track(kind: .video)])
    let s = EditorSession(project: Project(name: "P", timelines: [t, inner]))
    return s
}

@MainActor private func strip(_ s: EditorSession, width: Float = 1000) -> (TimelineHeaderStrip, DrawRect) {
    var h = TimelineHeaderStrip()
    let rest = h.layout(DrawRect(x: 0, y: 0, w: width, h: 400), scale: 1, state: .make(session: s, panel: TimelinePanel()))
    return (h, rest)
}

@MainActor @Suite struct TimelineHeaderStripTests {
    @Test func barTakesThirtyPointsAndFastCutAddsTheStrip() {
        let (h, rest) = strip(session())
        #expect(h.bar.height == 30 && h.strip == .zero && rest.y == 30 && rest.h == 370)
        let (f, below) = strip(session(magnetic: true))
        #expect(f.strip.minY == 30 && f.strip.height == 30 && below.y == 60)
        #expect(f.verbRects.count == FastCutVerb.all.count && f.badgeRect.minX == 8)
    }

    @Test func layoutMatchesTheMacHeader() {
        let (h, _) = strip(session())
        let mac = TimelineHeaderLayout.frames(width: 1000, modeWidth: TimelineModeMenu.chipWidth { CGFloat($0.count) * 11 * 0.55 })
        #expect(h.frames == mac)
        #expect(h.frames.fit.maxX == 996)
    }

    @Test func stateNamesTabsAndFormatsTheTimecode() {
        let s = session()
        s.seek(to: fd * 30)
        let st = TimelineHeaderState.make(session: s, panel: TimelinePanel())
        #expect(st.timecode == "00:00:01:05")
        #expect(st.tabs.count == 1 && st.tabs[0].title == "Main" && st.tabs[0].active)
        #expect(st.verbsEnabled.isEmpty)
    }

    @Test func buttonsRunTheirCommandsOnRelease() {
        var (h, _) = strip(session())
        func click(_ r: CGRect) -> [TimelineHeaderAction] {
            _ = h.handle(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []))
            return h.handle(.mouseUp(x: Float(r.midX), y: Float(r.midY))) ?? []
        }
        #expect(click(h.frames.snap) == [.command(.toggleSnapping)])
        #expect(click(h.frames.link) == [.command(.toggleLinkedSelection)])
        #expect(click(h.frames.marker) == [.command(.addMarker)])
        let fit = h.handle(.mouseDown(x: Float(h.frames.fit.midX), y: 15, modifiers: []))
        #expect(fit == [.menu(.fit, at: CGPoint(x: h.frames.fit.minX, y: h.frames.fit.maxY))])
        let mode = h.handle(.mouseDown(x: Float(h.frames.editMode.midX), y: 15, modifiers: []))
        if case .menu(.editMode, _)? = mode?.first {} else { Issue.record("no mode menu") }
        #expect(h.handle(.mouseDown(x: 10, y: 200, modifiers: [])) == nil)   // below the bar: not the header's
    }

    @Test func tabsSelectCloseAndReorder() {
        let s = session()
        let inner = s.project.timelines[1].id
        s.openSequenceTab(inner)
        var (h, _) = strip(s)
        #expect(h.state.tabs.map(\.title) == ["Main", "Inner"] && h.state.tabs[1].active)
        let first = h.tabRects[0].tab
        #expect(h.handle(.mouseDown(x: Float(first.midX), y: Float(first.midY), modifiers: [])) == [.selectTab(s.project.timelines[0].id)])
        #expect(h.handle(.mouseDragged(x: Float(h.tabRects[1].tab.maxX - 2), y: Float(first.midY))) == [.moveTab(s.project.timelines[0].id, to: 1)])
        _ = h.handle(.mouseUp(x: Float(h.tabRects[1].tab.maxX - 2), y: Float(first.midY)))
        let close = h.tabRects[1].close
        _ = h.handle(.mouseMoved(x: Float(close.midX), y: Float(close.midY)))
        #expect(h.hovered == .tabClose(1))
        _ = h.handle(.mouseDown(x: Float(close.midX), y: Float(close.midY), modifiers: []))
        #expect(h.handle(.mouseUp(x: Float(close.midX), y: Float(close.midY))) == [.closeTab(inner)])
    }

    @Test func fastCutVerbsRunOnlyWhenTheSessionAllowsThem() {
        let s = session(magnetic: true)
        var (h, _) = strip(s)
        #expect(h.state.verbsEnabled.count == FastCutVerb.all.count)
        let i = FastCutVerb.all.firstIndex { $0.command == .insertSpacer }!
        let r = h.verbRects[i]
        _ = h.handle(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []))
        let out = h.handle(.mouseUp(x: Float(r.midX), y: Float(r.midY)))
        #expect(out == (h.state.verbsEnabled[i] ? [.command(.insertSpacer)] : []))
    }

    @Test func fitMenuMirrorsTheMac() {
        let (h, _) = strip(session())
        var ran: [EditorCommand] = []
        let items = h.items(.fit, toolState: ToolState(), fitsTracks: true, run: { ran.append($0) }, togglePlaceClips: {}, pickMode: { _ in })
        #expect(items.map(\.title) == ["Zoom", "Fit Sequence", "Zoom In", "Zoom Out", "", "Track Height", "Taller Tracks",
                                       "Shorter Tracks", "Fit All Tracks to Height", "", "Place Sequences as Clips"])
        #expect(items[8].isChecked)
        items[1].action?()
        #expect(ran == [.zoomFit])
    }
}
