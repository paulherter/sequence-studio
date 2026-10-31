import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell
import SQDrawTimeline
import SQEditorSession
import SQUIKit
import Testing

/// The shared timeline header bar host (Windows and the Mac shared UI): view commands on the panel, the rest to the shell.
@MainActor @Suite struct TimelineHeaderHostTests {
    private func setup() -> (TimelineHeaderHost, EditorSession, ShellHost, Box) {
        let fd = Time(1, 25)
        let main = Timeline(name: "Main", frameDuration: fd, tracks: [Track(kind: .video), Track(kind: .audio)])
        let inner = Timeline(name: "Inner", frameDuration: fd, tracks: [Track(kind: .video)])
        let s = EditorSession(project: Project(name: "P", timelines: [main, inner]))
        let shell = ShellHost(session: s, map: .premiereDefault, recents: RecentProjects(entries: []))
        let box = Box()
        box.panel.sync(timeline: s.activeTimeline!, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        let h = TimelineHeaderHost(session: s, shell: shell, host: { nil }, withPanel: { change in change(&box.panel) })
        return (h, s, shell, box)
    }

    @MainActor final class Box { var panel = TimelinePanel() }

    @Test func layoutTakesTheBarAndLeavesTheRestForThePanel() {
        let (h, _, _, box) = setup()
        let rest = h.layout(DrawRect(x: 0, y: 100, w: 1000, h: 400), scale: 1, theme: DrawTheme(), atlas: nil, panel: box.panel)
        #expect(rest.y == 130 && rest.h == 370)
        #expect(h.strip.bar.minY == 100)
    }

    @Test func headerSpansTheFullWidthAboveTheToolStrip() {
        let (h, _, _, box) = setup()
        var tools = ToolStrip()
        tools.followsPrefs = false
        tools.edge = .left
        let rest = h.layout(DrawRect(x: 20, y: 100, w: 1000, h: 400), scale: 1, theme: DrawTheme(), atlas: nil,
                            panel: box.panel, toolStrip: &tools)
        // Mac: the first tab starts 4 pt into the panel, not behind the 38 pt tool column.
        #expect(h.strip.tabRects.first?.tab.minX == 24)
        #expect(h.strip.bar.minX == 20 && h.strip.bar.width == 1000)
        #expect(tools.strip.minY == 130 && rest.x == 58 && rest.y == 130)
    }

    @Test func snappingButtonTogglesThePanelAndNotTheShell() {
        let (h, _, shell, box) = setup()
        var forwarded: [EditorCommand] = []
        shell.onCommand = { forwarded.append($0); return true }
        let before = box.panel.toolState.snapping
        h.apply(.command(.toggleSnapping))
        #expect(box.panel.toolState.snapping != before)
        #expect(forwarded.isEmpty)
    }

    @Test func otherCommandsGoToTheShell() {
        let (h, _, shell, _) = setup()
        var forwarded: [EditorCommand] = []
        shell.onCommand = { forwarded.append($0); return true }
        h.apply(.command(.lift))
        #expect(forwarded == [.lift])
    }

    @Test func tabActionsReachTheSession() {
        let (h, s, _, _) = setup()
        let main = s.project.timelines[0].id, inner = s.project.timelines[1].id
        s.openSequenceTab(inner)
        h.apply(.selectTab(main))
        #expect(s.activeTimeline?.id == main)
        h.apply(.closeTab(inner))
        #expect(s.sequenceTabs.tabs.count == 1)
    }
}
