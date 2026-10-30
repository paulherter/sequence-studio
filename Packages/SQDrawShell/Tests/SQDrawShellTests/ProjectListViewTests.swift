import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

@MainActor
@Suite struct ProjectListViewTests {
    /// The view holds its host weakly (the host owns the panel in the app); the tests keep them alive.
    static var hosts: [ShellHost] = []

    func view() -> (ProjectListView, ProjectPanelModel, ShellHost) {
        let (h, _, _) = ShellImportTests().host()
        // A fresh store: the list mode and default columns, whatever earlier runs saved.
        let v = ProjectListView(host: h, defaults: UserDefaults(suiteName: "sq.test.projectList.\(UUID())")!)
        v.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        Self.hosts.append(h)
        return (v, h.projectModel!, h)
    }

    func center(_ v: ProjectListView, row i: Int) -> (Float, Float) {
        let r = v.rowRect(i)
        return (Float(r.midX), Float(r.midY))
    }

    @Test func sequencesFirstAndFoldersOpenInPlace() throws {
        let (v, m, _) = view()
        let bin = try #require(m.newBin(name: "Shots"))
        let rows = v.rows()
        #expect(rows.first.map { if case .sequence = $0.ref { true } else { false } } == true)
        let at = try #require(rows.firstIndex { $0.ref == .bin(bin) })
        m.currentBin = bin
        _ = m.newBin(name: "Inner")
        #expect(v.rows().count == rows.count)              // closed folder hides its items
        // A click on the disclosure arrow opens it; the child sits one level deeper.
        let r = v.rowRect(at)
        _ = v.handle(.mouseDown(x: Float(r.minX + 14), y: Float(r.midY), modifiers: []), scale: 1)
        let open = v.rows()
        #expect(open.count == rows.count + 1)
        #expect(open[at + 1].depth == 1)
    }

    @Test func doubleClickOpensTheSequence() {
        let (v, _, _) = view()
        var t = 10.0
        v.now = { t }
        var opened: Timeline.ID?
        v.onOpenSequence = { opened = $0 }
        let (x, y) = center(v, row: 0)
        _ = v.handle(.mouseDown(x: x, y: y, modifiers: []), scale: 1)
        #expect(opened == nil)
        t += 0.2
        _ = v.handle(.mouseDown(x: x, y: y, modifiers: []), scale: 1)
        guard case .sequence(let id) = v.rows()[0].ref else { Issue.record("no sequence row"); return }
        #expect(opened == id)
    }

    @Test func dragOutOfTheListReportsTheRowUntilReleaseOrEsc() {
        let (v, _, _) = view()
        var seen: [(ProjectListView.DragPhase, Int, Float)] = []
        v.onDrag = { refs, phase, x, _ in seen.append((phase, refs.count, x)) }
        let (x, y) = center(v, row: 0)
        _ = v.handle(.mouseDown(x: x, y: y, modifiers: []), scale: 1)
        #expect(v.handle(.mouseDragged(x: x + 2, y: y), scale: 1))      // inside the slop: nothing yet
        #expect(seen.isEmpty)
        _ = v.handle(.mouseDragged(x: x + 500, y: y + 300), scale: 1)
        #expect(v.isDragging)
        _ = v.handle(.mouseUp(x: x + 500, y: y + 300), scale: 1)
        #expect(seen.map(\.0) == [.moved, .ended] && seen.allSatisfy { $0.1 == 1 } && seen.last?.2 == x + 500)
        seen = []
        _ = v.handle(.mouseDown(x: x, y: y, modifiers: []), scale: 1)
        _ = v.handle(.mouseDragged(x: x + 500, y: y), scale: 1)
        #expect(v.handle(.keyDown(.escape, modifiers: []), scale: 1))
        #expect(seen.map(\.0) == [.moved, .canceled] && !v.isDragging)
        #expect(!v.handle(.mouseUp(x: x + 500, y: y), scale: 1))      // the release after Esc is not the list's
    }

    @Test func rightClickShowsTheMacRowsAndDeleteRemoves() throws {
        let (v, m, h) = view()
        let bin = try #require(m.newBin(name: "Trash Me"))
        let i = try #require(v.rows().firstIndex { $0.ref == .bin(bin) })
        let (x, y) = center(v, row: i)
        _ = v.handle(.mouseDown(x: x, y: y, modifiers: .secondary), scale: 1)
        #expect(v.selection == [.bin(bin)])
        #expect(h.menuBar.controller.isOpen)
        let titles = v.menu().map(\.title).filter { !$0.isEmpty }
        #expect(titles == ["New Folder", "Rename", "Delete"])
        h.menuBar.controller.dismiss()
        _ = v.handle(.keyDown(.delete, modifiers: []), scale: 1)
        #expect(!v.rows().contains { $0.ref == .bin(bin) })
        #expect(v.selection.isEmpty)
        // The empty area: the Mac rows (ProjectPanelMenus, targetCount 0).
        #expect(v.menu().map(\.title).filter { !$0.isEmpty } == ["New Folder", "New Sequence…", "New Color Matte…", "Import…", "Find…"])
        #expect(h.menuBar.controller.rootItems.isEmpty)
    }

    /// Mac parity: a media item's menu is the AppKit `ProjectPanelView.menuItems` list row for row (ProjectPanelMenus with
    /// the same context), and its Label row checks the item's label.
    @Test func mediaMenuIsTheMacRows() throws {
        let (h, _, media) = try ShellLocateTests().host()
        Self.hosts.append(h)
        let v = ProjectListView(host: h, defaults: UserDefaults(suiteName: "sq.test.projectList.\(UUID())")!)
        let m = try #require(h.projectModel)
        let id = media[0].id
        v.selection = [.media(id)]
        m.refreshOffline()
        let rows = v.menu()
        let titles = rows.map { $0.kind == .separator ? "-" : $0.title }
        #expect(titles.starts(with: ["Open in Source", "-", "Insert", "Overwrite", "New Sequence From Clip", "Make Subclip", "-", "Rename", "-", "Label"]))
        #expect(titles.contains("Select Label Group") && titles.contains("Edit Original") && titles.last == "Delete")
        #expect(rows.first { $0.title == "Insert" }?.shortcut == ProjectPanelMenus.shortcut(.insert, map: h.map))
        let label = try #require(rows.first { $0.title == "Label" }?.submenu)
        #expect(label.filter(\.isChecked).map(\.title) == [m.label(of: .media(id)).displayName])
    }

    @Test func renameAsksForTheName() async throws {
        let (v, m, h) = view()
        let bin = try #require(m.newBin(name: "Old"))
        let i = try #require(v.rows().firstIndex { $0.ref == .bin(bin) })
        let (x, y) = center(v, row: i)
        _ = v.handle(.mouseDown(x: x, y: y, modifiers: []), scale: 1)    // the click selects and gives the list the keys
        #expect(v.selection == [.bin(bin)])
        _ = v.handle(.keyDown(.enter, modifiers: []), scale: 1)
        for _ in 0..<50 where h.dialog == nil { await Task.yield() }
        let d = try #require(h.dialog)
        d.form?.set("name", .text("New Name"))
        d.press(.first)
        for _ in 0..<50 where m.project.bin(bin)?.name != "New Name" { await Task.yield() }
        #expect(m.project.bin(bin)?.name == "New Name")
    }

    @Test func drawsRowsWithChipsAndText() throws {
        let (v, m, _) = view()
        _ = m.newBin(name: "Shots")
        var c = Canvas(width: 300, height: 400, atlas: GlyphAtlas(), scale: 1)
        v.draw(&c, theme: DrawTheme())
        #expect(c.list.quads.count > 20)
    }
}

@MainActor
@Suite struct ProjectListMoveTests {
    func drag(_ v: ProjectListView, from a: CGPoint, to b: CGPoint) {
        _ = v.handle(.mouseDown(x: Float(a.x), y: Float(a.y), modifiers: []), scale: 1)
        _ = v.handle(.mouseDragged(x: Float(b.x), y: Float(b.y)), scale: 1)
        _ = v.handle(.mouseUp(x: Float(b.x), y: Float(b.y)), scale: 1)
    }

    @Test func dropOnAFolderMovesTheFolderIntoIt() throws {
        let (v, m, _) = ProjectListViewTests().view()
        let a = try #require(m.newBin(name: "A"))
        let b = try #require(m.newBin(name: "B"))
        let rows = v.rows()
        let ia = try #require(rows.firstIndex { $0.ref == .bin(a) })
        let ib = try #require(rows.firstIndex { $0.ref == .bin(b) })
        v.select([.bin(a)])
        drag(v, from: CGPoint(x: v.rowRect(ia).midX, y: v.rowRect(ia).midY), to: CGPoint(x: v.rowRect(ib).midX, y: v.rowRect(ib).midY))
        #expect(m.project.bin(b)?.children.contains { $0.ref == .bin(a) } == true)
    }

    @Test func aFolderNeverDropsIntoItself() throws {
        let (v, m, _) = ProjectListViewTests().view()
        let a = try #require(m.newBin(name: "A"))
        let ia = try #require(v.rows().firstIndex { $0.ref == .bin(a) })
        let r = v.rowRect(ia)
        #expect(v.moveTarget(at: CGPoint(x: r.midX, y: r.midY), moving: [.bin(a)]) == nil)
    }

    @Test func topEdgeOfARowInsertsBetweenRowsAndEmptySpaceAppendsToRoot() throws {
        let (v, m, _) = ProjectListViewTests().view()
        let a = try #require(m.newBin(name: "A"))
        let b = try #require(m.newBin(name: "B"))
        let ib = try #require(v.rows().firstIndex { $0.ref == .bin(b) })
        let r = v.rowRect(ib)
        let t = try #require(v.moveTarget(at: CGPoint(x: r.midX, y: r.minY + 1), moving: [.bin(a)]))
        #expect(t.isLine && t.bin == m.project.rootBin.id)
        let empty = try #require(v.moveTarget(at: CGPoint(x: 10, y: v.listRect.maxY - 2), moving: [.bin(a)]))
        #expect(!empty.isLine && empty.bin == m.project.rootBin.id && empty.index == nil)
    }

    @Test func theInsertionLineShowsWithASortOrFilterButTheDropAppends() throws {
        let (v, m, _) = ProjectListViewTests().view()
        let a = try #require(m.newBin(name: "A"))
        let b = try #require(m.newBin(name: "B"))
        func line() throws -> ProjectListView.MoveTarget {
            let ib = try #require(v.rows().firstIndex { $0.ref == .bin(b) })
            let r = v.rowRect(ib)
            return try #require(v.moveTarget(at: CGPoint(x: r.midX, y: r.minY + 1), moving: [.bin(a)]))
        }
        let plain = try line()
        #expect(plain.isLine && plain.index != nil)
        m.setSort(.name, ascending: false)
        let sorted = try line()
        #expect(sorted.isLine && sorted.index == nil && sorted.bin == m.project.rootBin.id)
        m.setSort(nil, ascending: true)
        m.searchText = "B"
        let filtered = try line()
        #expect(filtered.isLine && filtered.index == nil)
    }

    @Test func dropOnAFolderIsNotReportedToTheHostAsADrop() throws {
        let (v, m, _) = ProjectListViewTests().view()
        let a = try #require(m.newBin(name: "A"))
        let b = try #require(m.newBin(name: "B"))
        var phases: [String] = []
        v.onDrag = { _, p, _, _ in phases.append("\(p)") }
        let rows = v.rows()
        let ia = try #require(rows.firstIndex { $0.ref == .bin(a) })
        let ib = try #require(rows.firstIndex { $0.ref == .bin(b) })
        v.select([.bin(a)])
        drag(v, from: CGPoint(x: v.rowRect(ia).midX, y: v.rowRect(ia).midY), to: CGPoint(x: v.rowRect(ib).midX, y: v.rowRect(ib).midY))
        #expect(!phases.contains("ended"))
    }
}
