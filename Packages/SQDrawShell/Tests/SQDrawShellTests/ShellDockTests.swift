import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ShellDockTests {
    func dock(_ size: CGSize = CGSize(width: 1600, height: 900)) -> ShellDock {
        let d = ShellDock()
        d.frame = CGRect(origin: CGPoint(x: 0, y: 44), size: size)
        d.ownsHeader = { $0 == .programMonitor || $0 == .sourceMonitor }
        d.layout()
        return d
    }

    @Test func editingLayoutPlacesOneCardPerGroup() {
        let d = dock()
        let selected = Set(d.groups.map(\.selected))
        #expect(selected == [.effectControls, .programMonitor, .timeline, .audioMeter, .library, .project])
        // The timeline-only group and the monitors (their own header) show no strip; the others a 30 pt one.
        for g in d.groups {
            let bare = g.selected == .programMonitor || g.panels == [.timeline]
            #expect(g.strip.height == (bare ? 0 : ShellDock.stripHeight), "\(g.selected)")
            #expect(g.content.maxY == g.frame.maxY)
            #expect(d.frame.insetBy(dx: ShellDock.gap, dy: ShellDock.gap).contains(g.frame))
        }
        // Cards never overlap and every gap is a divider.
        for (i, a) in d.groups.enumerated() { for b in d.groups[(i + 1)...] { #expect(!a.frame.intersects(b.frame)) } }
        #expect(d.dividers.count >= 4)
    }

    @Test func dragDividerTradesLengthAndKeepsMinimums() {
        let d = dock()
        let div = d.dividers.first { $0.path.isEmpty }!   // the root split: editing area | Library/Project column
        let before = d.cardFrame(.project)!.width
        let s: Float = 2
        func px(_ p: CGPoint) -> (Float, Float) { (Float(p.x) * s, Float(p.y) * s) }
        let start = CGPoint(x: div.frame.midX, y: div.frame.midY)
        #expect(d.handle(.mouseDown(x: px(start).0, y: px(start).1, modifiers: []), scale: s))
        #expect(d.handle(.mouseDragged(x: px(start).0 - 200, y: px(start).1), scale: s))
        #expect(abs(d.cardFrame(.project)!.width - (before + 100)) <= 1)   // 200 px at scale 2
        // Far past the edge: the left side stays at its minimum.
        _ = d.handle(.mouseDragged(x: 0, y: px(start).1), scale: s)
        let left = d.dividers.first { $0.path.isEmpty }!.lengths[0]
        #expect(left >= d.dividers.first { $0.path.isEmpty }!.mins[0] - 0.5)
        var saved = 0
        d.save = { _ in saved += 1 }
        #expect(d.handle(.mouseUp(x: 0, y: px(start).1), scale: s))
        #expect(saved == 1 && !d.isTracking)
    }

    @Test func clickOnATabSelectsIt() {
        let d = dock()
        let g = d.groups.first { $0.panels.contains(.markerList) }!
        let tab = g.tabs[g.panels.firstIndex(of: .markerList)!]
        _ = d.handle(.mouseDown(x: Float(tab.midX), y: Float(tab.midY), modifiers: []), scale: 1)
        _ = d.handle(.mouseUp(x: Float(tab.midX), y: Float(tab.midY)), scale: 1)
        #expect(d.shows(.markerList) && !d.shows(.project))
        #expect(d.focused == .markerList)
    }

    @Test func stripToolsKeepTheirWidthFreeOfTabsAndPresses() {
        let d = dock()
        d.stripTools = { $0 == .project ? 120 : 0 }
        d.layout()
        let g = d.groups.first { $0.selected == .project }!
        for t in g.tabs where t.width > 0 { #expect(t.maxX <= g.strip.maxX - 120) }
        #expect(!d.handle(.mouseDown(x: Float(g.strip.maxX - 20), y: Float(g.strip.midY), modifiers: []), scale: 1))
        #expect(d.handle(.mouseDown(x: Float(g.strip.maxX - 140), y: Float(g.strip.midY), modifiers: []), scale: 1))
    }

    @Test func draggingATabOntoAnotherCardsEdgeSplitsIt() {
        let d = dock()
        let g = d.groups.first { $0.panels.contains(.markerList) }!
        let tab = g.tabs[g.panels.firstIndex(of: .markerList)!]
        let tl = d.cardFrame(.timeline)!
        _ = d.handle(.mouseDown(x: Float(tab.midX), y: Float(tab.midY), modifiers: []), scale: 1)
        let to = CGPoint(x: tl.maxX - 10, y: tl.midY)   // the right edge band
        _ = d.handle(.mouseDragged(x: Float(to.x), y: Float(to.y)), scale: 1)
        #expect(d.dropTarget?.action == .dock(.markerList, onto: .timeline, .right))
        _ = d.handle(.mouseUp(x: Float(to.x), y: Float(to.y)), scale: 1)
        #expect(d.shows(.markerList))
        #expect(d.cardFrame(.markerList)!.minX > d.cardFrame(.timeline)!.minX)
        #expect(d.dropTarget == nil && d.dragTab == nil)
    }

    @Test func draggingInsideTheOwnStripReorders() {
        let d = dock()
        let g = d.groups.first { $0.panels.contains(.project) }!
        let first = g.tabs[0], last = g.tabs[g.panels.count - 1]
        _ = d.handle(.mouseDown(x: Float(first.midX), y: Float(first.midY), modifiers: []), scale: 1)
        _ = d.handle(.mouseDragged(x: Float(last.maxX - 2), y: Float(last.midY)), scale: 1)
        if case .reorder(.project, _)? = d.dropTarget?.action {} else { Issue.record("no reorder target") }
        _ = d.handle(.mouseUp(x: Float(last.maxX - 2), y: Float(last.midY)), scale: 1)
        #expect(d.groups.first { $0.panels.contains(.project) }!.panels.last == .project)
    }

    @Test func escapeCancelsATabDrag() {
        let d = dock()
        let g = d.groups.first { $0.panels.contains(.markerList) }!
        let tab = g.tabs[g.panels.firstIndex(of: .markerList)!]
        _ = d.handle(.mouseDown(x: Float(tab.midX), y: Float(tab.midY), modifiers: []), scale: 1)
        _ = d.handle(.mouseDragged(x: 300, y: 300), scale: 1)
        #expect(d.handle(.keyDown(.escape, modifiers: []), scale: 1))
        #expect(!d.isTracking && d.dropTarget == nil)
    }

    @Test func togglingHidesAndShowsAPanel() {
        let d = dock()
        #expect(d.visiblePanels.contains(.project))
        d.toggle(.project)
        #expect(!d.visiblePanels.contains(.project) && !d.shows(.project))
        d.toggle(.project)
        #expect(d.shows(.project) && d.focused == .project)
    }

    @Test func maximizeFillsTheDockAndRestores() {
        let d = dock()
        d.toggleMaximize(.timeline)
        #expect(d.groups.count == 1 && d.groups[0].selected == .timeline)
        #expect(d.groups[0].frame == d.frame.insetBy(dx: ShellDock.gap, dy: ShellDock.gap))
        d.toggleMaximize(.timeline)
        #expect(d.groups.count > 1)
    }

    @Test func tabMenuOffersMaximizeAndClose() {
        let d = dock()
        var shown: [SQMenuItem] = []
        d.presentMenu = { items, _ in shown = items }
        let g = d.groups.first { $0.panels.contains(.project) }!
        let tab = g.tabs[g.panels.firstIndex(of: .project)!]
        _ = d.handle(.mouseDown(x: Float(tab.midX), y: Float(tab.midY), modifiers: .secondary), scale: 1)
        #expect(shown.map(\.title) == ["Maximize Panel", "Close Panel"])
        shown[1].action?()
        #expect(!d.visiblePanels.contains(.project))
    }

    @Test func tabMenuOffersMoveToFloatingWindowOnlyWhenTheHostCanFloat() {
        let d = dock()
        #expect(d.tabMenu(.project).map(\.title) == ["Maximize Panel", "Close Panel"])
        var floated: [PanelID] = []
        d.floatPanel = { floated.append($0) }
        #expect(d.tabMenu(.project).map(\.title) == ["Maximize Panel", "Move to Floating Window", "Close Panel"])
        d.tabMenu(.project)[1].action?()
        #expect(floated == [.project])
    }

    @Test func workspacesSaveRenameDeleteAndReset() {
        let d = dock()
        var saves = 0
        d.save = { _ in saves += 1 }
        d.toggle(.project)
        #expect(d.saveAsNew("Mine") == "Mine")
        #expect(d.store.editName == "Mine" && d.store.library.names.contains("Mine"))
        #expect(d.renameCurrent("Ours"))
        #expect(d.store.library.names.contains("Ours") && !d.store.library.names.contains("Mine"))
        #expect(d.deleteCurrent())
        #expect(!d.store.library.names.contains("Ours"))
        d.chooseWorkspace(Workspace.editingPC.name)
        d.toggle(.markerList)
        d.resetLayout()
        #expect(d.store.current.isVisible(.project))
        #expect(saves >= 6)
    }

    @Test func nextPanelCyclesThroughTheCards() {
        let d = dock()
        let order = d.groups.map(\.selected)
        #expect(d.cycle(from: order[0], forward: true) == order[1])
        #expect(d.cycle(from: order[0], forward: false) == order.last)
        #expect(d.cycle(from: nil, forward: true) == order[0])
    }

    // MARK: Shell

    @Test func windowMenuShowsWorkspacesAndPanelChecks() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        let s = h.menuState()
        #expect(s.workspaces == h.dock.store.library.names)
        #expect(s.currentWorkspace == Workspace.editingPC.name)
        #expect(s.visiblePanels.contains(.timeline) && !s.visiblePanels.contains(.colorClips))
        h.perform(.togglePanel(.project))
        #expect(!h.menuState().visiblePanels.contains(.project))
    }

    @Test func panelCommandsRunOnTheDock() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        h.dock.frame = CGRect(x: 0, y: 44, width: 1600, height: 900)
        h.dock.layout()
        h.dock.toggle(.project)
        #expect(h.execute(.focusPanel(.project)))
        #expect(h.dock.shows(.project) && h.focus == .project)
        #expect(h.execute(.maximizeActivePanel))
        #expect(h.dock.maximized == .project)
        #expect(h.execute(.resetLayout))
        #expect(h.dock.maximized == nil)
    }

    @Test func welcomeShowsOnceAndListsTheTips() async {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault)
        h.spawn = { _ in }
        let defaults = UserDefaults(suiteName: "ShellDockTests.welcome")!
        defaults.removePersistentDomain(forName: "ShellDockTests.welcome")
        h.presentWelcomeIfNeeded(defaults: defaults)
        #expect(AppSettings.load(from: defaults).onboardingSeen)
        let t = Task { @MainActor in await h.showWelcome() }
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        #expect(h.dialog?.messageText == OnboardingContent.title)
        #expect(h.dialog?.form?.rows.count == OnboardingContent.tips.count * 2)
        h.dialog?.press(.first)
        await t.value
        #expect(OnboardingContent.tips(for: .windows)[0].detail.contains("Ctrl+I"))
        #expect(OnboardingContent.tips(for: .mac)[0].detail.contains("Cmd+I"))
    }

    @Test func shellRowsFollowTheMacEnabledRulesAndRunOnTheSession() throws {
        let session = ShellCommandsTests.session()
        let h = ShellHost(session: session, map: .premiereDefault)
        var status: [String] = []
        h.onStatus = { status.append($0) }
        func find(_ items: [SQMenuItem], _ title: String) -> SQMenuItem? {
            for i in items {
                if i.title == title { return i }
                if let s = i.submenu, let f = find(s, title) { return f }
            }
            return nil
        }
        let window = try #require(h.menus().first { $0.title == "Window" })
        #expect(find(window.items, "Delete Workspace")?.isEnabled == false)   // a built-in
        #expect(find(window.items, "Reset to Saved Layout")?.isEnabled == false)   // unchanged
        _ = h.dock.saveAsNew("Mine")
        #expect(find(h.menus().first { $0.title == "Window" }!.items, "Delete Workspace")?.isEnabled == true)
        // Mac parity: the Window menu ends with the system window list, the project window checked.
        let last = ShellMenuBar.build(state: h.menuState(), map: h.map, platform: .mac, validate: { _ in true }, perform: { _ in })
            .first { $0.title == "Window" }!.items.suffix(2)
        #expect(last.first?.kind == .separator && last.last?.title == session.displayName && last.last?.isChecked == true)

        let space = ColorSpaceID.allCases[1]
        h.perform(.projectInputColor(space))
        #expect(session.project.inputColorSpace == space && h.menuState().projectInputColor == space)
        h.perform(.relinkMedia)
        #expect(status.last == "All media is online.")
        // File > Media Management: one undo step each, the checks follow the project's policy.
        h.perform(.outsideMedia(.leave))
        #expect(session.project.mediaPolicy?.outside == .leave && h.menuState().outsideMedia == .leave)
        let watch = h.menuState().watchFolder
        h.perform(.toggleWatchFolder)
        #expect(h.menuState().watchFolder == !watch)
        session.undo()
        #expect(h.menuState().watchFolder == watch)
        let hasSequence = session.activeTimeline != nil
        #expect(h.menuState().hasSequence == hasSequence)
        let before = session.activeTimeline?.tracks.reduce(0) { $0 + $1.clips.count } ?? 0
        h.perform(.newAdjustmentLayer)
        let after = session.activeTimeline?.tracks.reduce(0) { $0 + $1.clips.count } ?? 0
        #expect(hasSequence ? after == before + 1 : status.last == "Open a sequence first.")
        h.perform(.newShape(.rectangle))
        let shapes = session.activeTimeline?.tracks.reduce(0) { $0 + $1.clips.count } ?? 0
        #expect(hasSequence ? shapes == after + 1 : status.last == "Open a sequence first.")
        // With the Create tool's hook the host makes the item (into the targeted Graphic); the shell adds nothing.
        var asked: [ShapeKind] = []
        h.onNewShape = { asked.append($0) }
        h.perform(.newShape(.ellipse))
        let hooked = session.activeTimeline?.tracks.reduce(0) { $0 + $1.clips.count } ?? 0
        #expect(hasSequence ? asked == [.ellipse] && hooked == shapes : asked.isEmpty)
    }

    @Test func historyPickJumpsToTheStep() async {
        let session = ShellCommandsTests.session()
        let h = ShellHost(session: session, map: .premiereDefault)
        let t = Task { @MainActor in await h.showHistory() }
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        #expect(h.dialog?.messageText == "History")
        h.dialog?.press(.first)
        await t.value
    }
}
