import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite("ShellMenuBar")
struct ShellMenuBarTests {
    func menus(_ s: ShellMenuState = ShellMenuState(), platform: KeyPlatform, log: Log? = nil) -> [ShellMenu] {
        ShellMenuBar.build(state: s, map: .premiereDefault, platform: platform) { log?.actions.append($0) }
    }
    final class Log { var actions: [ShellAction] = [] }
    func menu(_ m: [ShellMenu], _ t: String) -> [SQMenuItem] { m.first { $0.title == t }?.items ?? [] }

    @Test func barOrderIsAppThenEditorMenusThenHelp() {
        let m = menus(platform: .mac)
        #expect(m.first?.title == "Sequence Studio")
        #expect(m.last?.title == "Help")
        #expect(Array(m.dropFirst().dropLast()).map(\.title) == EditorMenus.visible.map(\.title))
    }

    /// Windows shows the Mac menu model: same menus, rows, order and enabled state; a shortcut is spelled with Ctrl/Alt/Shift
    /// (no Mac glyphs) exactly where the Mac row has one. Only the app menu differs (Hide rows, Quit vs Exit).
    @Test func windowsMenusAreTheMacMenusWithCtrlShortcuts() {
        let glyphs = Set("\u{2318}\u{2325}\u{21E7}\u{2303}")
        // Window system rows: Zoom is Maximize on Windows; Bring All to Front and the window list are Mac-only.
        func tidied(_ items: [SQMenuItem]) -> [SQMenuItem] {
            ShellMenuBar.tidy(items.filter { $0.title != "Bring All to Front" }.map { var i = $0; if i.title == "Maximize" { i.title = "Zoom" }; return i })
        }
        func compare(_ mac: [SQMenuItem], _ win: [SQMenuItem], _ path: String) {
            let mac = tidied(mac), win = tidied(win)
            #expect(mac.map(\.title) == win.map(\.title), "rows of \(path)")
            for (m, w) in zip(mac, win) {
                #expect(m.kind == w.kind && m.isEnabled == w.isEnabled && m.isChecked == w.isChecked, "\(path) > \(m.title)")
                #expect(m.shortcut.isEmpty == w.shortcut.isEmpty, "shortcut presence of \(path) > \(m.title)")
                #expect(!w.shortcut.contains { glyphs.contains($0) }, "Mac glyph in \(path) > \(m.title): \(w.shortcut)")
                compare(m.submenu ?? [], w.submenu ?? [], path + " > " + m.title)
            }
        }
        let mac = menus(platform: .mac), win = menus(platform: .windows)
        #expect(mac.map(\.title) == win.map(\.title))
        for (m, w) in zip(mac, win).dropFirst() { compare(m.items, w.items, m.title) }
        #expect(win.flatMap(\.items).contains { $0.shortcut == "Ctrl+Z" })
    }

    @Test func windowsAppMenuEndsWithExitAltF4AndHasNoHide() {
        let app = menus(platform: .windows).first!.items
        #expect(app.last?.title == "Exit")
        #expect(app.last?.shortcut == "Alt+F4")
        #expect(!app.contains { $0.title.hasPrefix("Hide") })
        let mac = menus(platform: .mac).first!.items
        #expect(mac.last?.title == "Quit Sequence Studio")
        #expect(mac.contains { $0.title == "Hide Sequence Studio" })
    }

    /// The AppKit bar: Hide Others (Option-Command-H) and Show All under Hide on the Mac; File ends with Collect and
    /// Media Management (`MediaMenuTarget`: four modes, library copies and watching, the last two need a project folder).
    @Test func macAppMenuAndFileMediaManagementAreTheAppKitRows() {
        let mac = menus(platform: .mac).first!.items.map(\.title)
        #expect(mac.firstIndex(of: "Hide Others") == mac.firstIndex(of: "Hide Sequence Studio").map { $0 + 1 })
        #expect(mac.contains("Show All"))
        #expect(menus(platform: .mac).first!.items.first { $0.title == "Hide Others" }?.shortcut == "\u{2325}\u{2318}H")
        #expect(!menus(platform: .windows).first!.items.contains { $0.title == "Show All" })
        var s = ShellMenuState()
        s.outsideMedia = .copy
        s.copyLibraryItems = true
        let log = Log()
        let file = menu(menus(s, platform: .mac, log: log), "File")
        #expect(file.suffix(2).map(\.title) == ["Collect Files into Project Folder", "Media Management"])
        let media = file.last?.submenu ?? []
        #expect(media.filter { $0.kind == .action }.map(\.title) == ["Ask About Outside Files", "Copy Outside Files Into Project",
            "Move Outside Files Into Project", "Leave Outside Files Where They Are", "Copy Library Items Into Project", "Watch Project Folder"])
        #expect(media.first { $0.isChecked }?.title == "Copy Outside Files Into Project")
        #expect(media.first { $0.title == "Watch Project Folder" }?.isEnabled == false)
        media.first { $0.title == "Move Outside Files Into Project" }?.action?()
        #expect(log.actions == [.outsideMedia(.move)])
    }

    @Test func openRecentFollowsOpenProjectAndPerformsThePath() {
        var s = ShellMenuState()
        s.recents = [RecentProjects.Entry(path: "/p/Film.sqproj", name: "Film", opened: Date())]
        let log = Log()
        let file = menu(menus(s, platform: .windows, log: log), "File")
        let i = file.firstIndex { $0.title == "Open Recent" }
        #expect(i != nil)
        #expect(file[i! - 1].title == EditorCommand.openProject.title)
        let rows = file[i!].submenu ?? []
        #expect(rows.first?.title == "Film")
        #expect(rows.last?.title == "Clear Menu" && rows.last?.isEnabled == true)
        rows.first?.action?()
        #expect(log.actions == [.openRecent(path: "/p/Film.sqproj")])
    }

    @Test func emptyRecentsDisableClearMenu() {
        let file = menu(menus(platform: .mac), "File")
        let rows = file.first { $0.title == "Open Recent" }?.submenu ?? []
        #expect(rows.count == 1 && rows[0].isEnabled == false)
    }

    @Test func undoTitleCarriesTheStepName() {
        var s = ShellMenuState()
        s.undoName = "Trim"
        let edit = menus(s, platform: .windows).flatMap(\.items)
        #expect(edit.contains { $0.title.hasPrefix("Undo ") && $0.isEnabled && $0.shortcut == "Ctrl+Z" })
        #expect(edit.contains { $0.title == "Redo" && !$0.isEnabled })
    }

    @Test func runningCommandShowsItsCancelTitle() {
        let title = EditorCommand.anonymize.title
        let all: ([ShellMenu]) -> [SQMenuItem] = { $0.flatMap(\.items).flatMap { [$0] + ($0.submenu ?? []) + ($0.submenu ?? []).flatMap { $0.submenu ?? [] } } }
        #expect(all(menus(platform: .mac)).contains { $0.title == title })
        var s = ShellMenuState()
        s.titles[.anonymize] = "Cancel Anonymize"
        let m = all(menus(s, platform: .mac))
        #expect(m.contains { $0.title == "Cancel Anonymize" })
        #expect(!m.contains { $0.title == title })
    }

    @Test func chooserLetsOnlyProjectStartsThrough() {
        var s = ShellMenuState()
        s.chooserShown = true
        let file = menu(menus(s, platform: .mac), "File")
        #expect(file.first { $0.title == EditorCommand.openProject.title }?.isEnabled == true)
        #expect(file.first { $0.title == EditorCommand.save.title }?.isEnabled == false)
        s.chooserShown = false; s.modalShown = true
        #expect(menu(menus(s, platform: .mac), "File").allSatisfy { !$0.isEnabled || $0.kind != .action || $0.submenu != nil })
    }

    @Test func tidyDropsEdgeAndDoubledSeparators() {
        let a = SQMenuItem(title: "A"), b = SQMenuItem(title: "B")
        #expect(ShellMenuBar.tidy([.separator, a, .separator, .separator, b, .separator]).map(\.kind) == [.action, .separator, .action])
    }
}

@MainActor
@Suite("MenuListView")
struct MenuListViewTests {
    let m = TextMeasure(atlas: nil, scale: 1)

    @Test func rowsStackFromTheInsetWithMenuHeights() {
        var v = MenuListView(items: [SQMenuItem(title: "Cut"), .separator, .header("Clips"), SQMenuItem(title: "Paste")])
        v.relayout(m)
        #expect(v.rowFrames.map(\.minY) == [CGFloat(4), 28, 37, 59])
        #expect(v.contentSize.height == CGFloat(59 + 24 + 4))
        #expect(v.width >= SQMenuLayout.minWidth)
    }

    @Test func maxHeightScrollsAndRevealShowsTheRow() {
        var v = MenuListView(items: (0..<20).map { SQMenuItem(title: "Row \($0)") })
        v.maxHeight = 100
        v.relayout(m)
        #expect(v.visibleSize.height == 100)
        v.reveal(row: 10)
        #expect(v.scrollOffset == v.rowFrames[10].maxY + 4 - 100)
        #expect(v.index(at: CGPoint(x: 20, y: 95)) == 10)
        v.scroll(by: 10_000)
        #expect(v.scrollOffset == v.maxScroll)
    }

    @Test func filterRowPushesRowsDown() {
        var v = MenuListView(items: [SQMenuItem(title: "Cut")])
        v.filter = "cu"
        v.relayout(m)
        #expect(v.filterFrame != nil)
        #expect(v.rowFrames[0].minY == CGFloat(4 + 24 + 9))
    }

    @Test func drawPaintsPanelHighlightAndClips() {
        var v = MenuListView(items: [SQMenuItem(title: "Cut"), SQMenuItem(title: "Copy")])
        v.highlighted = 1
        v.relayout(m)
        var c = Canvas(width: 400, height: 300, atlas: nil, scale: 2)
        v.draw(&c, theme: DrawTheme())
        #expect(c.list.quads.count > 3)
    }
}
