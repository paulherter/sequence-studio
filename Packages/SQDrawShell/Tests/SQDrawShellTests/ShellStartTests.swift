import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// The start screen (`ShellStart.swift`): when it shows and goes, the Recent grid, search, keys and the rail.
@MainActor
@Suite struct ShellStartTests {
    static var hosts: [ShellHost] = []

    func host(recents: [RecentProjects.Entry] = []) -> (ShellHost, ShellStartScreen, UserDefaults) {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault, recents: RecentProjects(entries: recents))
        h.size = CGSize(width: 1280, height: 800)
        let d = UserDefaults(suiteName: "sq.test.start.\(UUID())")!
        h.showStart(defaults: d)
        Self.hosts.append(h)
        return (h, h.startScreen!, d)
    }

    static let now = Date()
    static func entry(_ name: String, daysAgo: Double) -> RecentProjects.Entry {
        RecentProjects.Entry(path: "/nowhere/\(name)/\(name).sqproj", name: name, opened: now.addingTimeInterval(-daysAgo * 86_400))
    }

    func click(_ h: ShellHost, _ p: CGPoint, _ m: InputModifiers = []) {
        _ = h.handle(.mouseDown(x: Float(p.x), y: Float(p.y), modifiers: m), scale: 1)
        _ = h.handle(.mouseUp(x: Float(p.x), y: Float(p.y)), scale: 1)
    }

    func key(_ h: ShellHost, _ k: InputKey, _ m: InputModifiers = []) { _ = h.handle(.keyDown(k, modifiers: m), scale: 1) }

    @Test func coversTheWindowUnderTheMenuBarAndGatesTheMenus() {
        let (h, s, _) = host()
        #expect(h.isStartShown)
        #expect(s.frame == CGRect(x: 0, y: h.menuBar.height, width: 1280, height: 800 - h.menuBar.height))
        #expect(h.menuState().chooserShown)
        // Esc cannot close it without a project behind it.
        key(h, .escape)
        #expect(h.isStartShown)
    }

    @Test func goesWhenAProjectOpensAndComesBackAfterClose() {
        let (h, _, _) = host()
        var p = h.session.project
        p.id = UUID()
        p.media = [MediaRef(name: "a.mp4", path: "/x/a.mp4", fingerprint: MediaFingerprint(size: 1))]
        h.session.newProject(p)
        h.syncStart()
        #expect(!h.isStartShown)
        h.session.closeProject()
        h.syncStart()
        #expect(h.isStartShown)
        // Window > Start Window over a real project: Esc goes back to it.
        h.session.newProject(p)
        h.syncStart()
        h.perform(.startWindow)
        h.syncStart()
        #expect(h.isStartShown)
        key(h, .escape)
        #expect(!h.isStartShown)
    }

    @Test func recentGridGroupsByDayAndClicksHitTheCards() {
        let (_, s, _) = host(recents: [Self.entry("Today One", daysAgo: 0), Self.entry("Week", daysAgo: 3), Self.entry("Old", daysAgo: 30)])
        #expect(s.tab == .recent)
        let els = s.paneLayout().elements
        let headings = els.compactMap { if case .heading(let t, _, _) = $0 { t } else { nil } }
        #expect(headings == ["Today", "This week", "Earlier"])
        let cards = els.compactMap { if case .card(let e, let r) = $0 { (e, r) } else { nil } }
        #expect(cards.map(\.0.name) == ["Today One", "Week", "Old"])
        // Adaptive columns: at least 168 wide, spread over the pane.
        #expect(cards.allSatisfy { $0.1.width >= ShellStartScreen.M.cardMin })
        let first = cards[0].1
        #expect(s.hit(at: CGPoint(x: first.minX + 20, y: first.minY + 20)) == .card(cards[0].0.path))
        let more = s.moreRect(first)
        #expect(s.hit(at: CGPoint(x: more.midX, y: more.midY)) == .cardMore(cards[0].0.path))
        // Sorting by name drops the groups.
        s.sort = .name
        #expect(s.paneLayout().elements.allSatisfy { if case .heading = $0 { false } else { true } })
        #expect(s.shown.map(\.name) == ["Old", "Today One", "Week"])
    }

    @Test func theListToggleSwitchesRecentToHeaderAndRows() {
        let (h, s, d) = host(recents: [Self.entry("A", daysAgo: 0), Self.entry("B", daysAgo: 3)])
        let seg = s.layoutSegment(true)
        click(h, CGPoint(x: seg.midX, y: seg.midY))
        #expect(s.listLayout && d.bool(forKey: "sq.start.listLayout"))
        let els = s.paneLayout().elements
        #expect(els.filter { if case .listHeader = $0 { true } else { false } }.count == 1)
        let rows = els.compactMap { if case .listRow(let e, let r) = $0 { (e, r) } else { nil } }
        #expect(rows.map(\.0.name) == ["A", "B"] && rows.allSatisfy { $0.1.height == 44 })
        #expect(els.allSatisfy { if case .heading = $0 { false } else if case .card = $0 { false } else { true } })
        let r = rows[0].1
        #expect(s.hit(at: CGPoint(x: r.minX + 30, y: r.midY)) == .card(rows[0].0.path))
        let more = s.listColumns(r).more
        #expect(s.hit(at: CGPoint(x: more.midX, y: more.midY)) == .cardMore(rows[0].0.path))
        let grid = s.layoutSegment(false)
        click(h, CGPoint(x: grid.midX, y: grid.midY))
        #expect(!s.listLayout)
    }

    @Test func theMacKeepsTheSearchInTheWindowBarAndDropsTheTopRow() {
        let (h, s, _) = host(recents: [Self.entry("Interview", daysAgo: 0)])
        let ownRow = s.railRect.minY
        #expect(s.searchRect.minY >= s.frame.minY)
        h.startSearchInBar = true
        #expect(s.barFrame == CGRect(x: 0, y: 0, width: 1280, height: h.menuBar.height))
        #expect(s.searchRect.maxY <= h.menuBar.height && s.searchRect.maxX < 1280)
        #expect(s.railRect.minY == ownRow - ShellStartScreen.M.top)
        // A click on the field in the bar starts typing there.
        click(h, CGPoint(x: s.searchRect.midX, y: s.searchRect.midY))
        for ch in "int" { key(h, .character(ch)) }
        #expect(s.query == "int")
        // The bar's titles stay with the menus.
        #expect(h.menuBar.title(at: CGPoint(x: s.searchRect.midX, y: s.searchRect.midY)) == nil)
    }

    @Test func searchFiltersSwitchesToRecentAndEscClears() {
        let (h, s, d) = host(recents: [Self.entry("Interview", daysAgo: 0), Self.entry("Broll", daysAgo: 1)])
        s.tab = .learn
        #expect(d.string(forKey: "sq.start.tab") == "Learn")
        key(h, .character("f"), .command)
        for ch in "inter" { key(h, .character(ch)) }
        #expect(s.query == "inter")
        #expect(s.tab == .recent)
        #expect(s.shown.map(\.name) == ["Interview"])
        key(h, .escape)
        #expect(s.query.isEmpty && s.shown.count == 2)
        // Nothing matches: the empty state offers Clear search.
        s.setQuery("zzz")
        #expect(s.emptyState()?.title == "No projects match “zzz”")
    }

    @Test func upDownMoveTheHighlightAndTabsSwitchFromTheRail() {
        let (h, s, _) = host(recents: [Self.entry("A", daysAgo: 0), Self.entry("B", daysAgo: 0), Self.entry("C", daysAgo: 0)])
        #expect(s.highlightedPath == s.recents[0].path)
        key(h, .down); key(h, .down)
        #expect(s.selectedPath == s.recents[2].path)
        key(h, .up)
        #expect(s.selectedPath == s.recents[1].path)
        let templates = s.railSpots().first { $0.1 == .tab(.templates) }!.0
        click(h, CGPoint(x: templates.midX, y: templates.midY))
        #expect(s.tab == .templates)
        let names = s.paneLayout().elements.compactMap { if case .templateCard(let t, _) = $0 { t.name } else { nil } }
        #expect(names == ProjectTemplate.builtIn.map(\.name))
        let check = s.railSpots().first { $0.1 == .reopenLast }!.0
        click(h, CGPoint(x: check.midX, y: check.midY))
        #expect(s.reopenLast)
    }

    @Test func homeShowsContinueAndOneTilePerBuiltInSize() {
        let (_, s, _) = host(recents: [Self.entry("Last", daysAgo: 0)])
        s.tab = .home
        let els = s.paneLayout().elements
        #expect(els.contains { if case .continueBox(let e, _) = $0 { e.name == "Last" } else { false } })
        let quick = els.compactMap { if case .quick(let t, _) = $0 { t?.id ?? "all" } else { nil } }
        #expect(quick == ProjectTemplate.builtIn.map(\.id) + ["all"])
    }

    @Test func onlyProjectCommandsPassTheKeys() {
        let (h, _, _) = host(recents: [Self.entry("A", daysAgo: 0)])
        #expect(ShellStartScreen.allowedCommands.contains(.openProject))
        #expect(!ShellStartScreen.allowedCommands.contains(.undo))
        // Ctrl+Z reaches nothing behind the start screen.
        key(h, .character("z"), .command)
        #expect(h.isStartShown && h.dialog == nil)
    }

    @Test func removeFromRecentsSavesTheList() {
        let (h, s, _) = host(recents: [Self.entry("A", daysAgo: 0), Self.entry("B", daysAgo: 0)])
        var saved: RecentProjects?
        h.saveRecents = { saved = $0 }
        let items = s.recentMenu(s.recents[0].path)
        #expect(items.map(\.title).contains("Remove from Recents"))
        h.removeRecent(path: s.recents[0].path)
        #expect(saved?.entries.map(\.name) == ["B"])
    }
    @Test func cardPictureIsThePosterMediaFrameAtThePosterTime() {
        let h = ShellHost(session: ShellCommandsTests.session(), map: .premiereDefault, recents: RecentProjects(entries: []))
        h.size = CGSize(width: 1280, height: 800)
        var asked: [String] = []
        h.startPoster = { path, seconds in
            asked.append("\(path)@\(seconds)")
            return ProjectPoster(slot: 0, pixelSize: CGSize(width: 160, height: 90))
        }
        h.showStart(defaults: UserDefaults(suiteName: "sq.test.start.\(UUID())")!)
        Self.hosts.append(h)
        let s = h.startScreen!
        s.infos = ["/p/A.sqproj": StartProjectInfo(width: 1920, height: 1080, fps: 25, seconds: 10, posterPath: "/m/a.mp4", posterSeconds: 2.5),
                   "/p/B.sqproj": StartProjectInfo(width: 1920, height: 1080, fps: 25, seconds: 10)]
        #expect(s.cardPoster(path: "/p/A.sqproj")?.pixelSize == CGSize(width: 160, height: 90))
        #expect(asked == ["/m/a.mp4@2.5"])
        // No picture media, unknown project, missing project or missing media: the neutral well, no decode asked.
        #expect(s.cardPoster(path: "/p/B.sqproj") == nil)
        #expect(s.cardPoster(path: "/p/C.sqproj") == nil)
        s.missing = ["/p/A.sqproj"]
        #expect(s.cardPoster(path: "/p/A.sqproj") == nil)
        s.missing = []
        s.infos["/p/A.sqproj"]?.mediaMissing = true
        #expect(s.cardPoster(path: "/p/A.sqproj") == nil)
        #expect(asked.count == 1)
    }
}
