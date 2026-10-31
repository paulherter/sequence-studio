import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// The Project panel's search row, column picker, sorting and icon grid (`ProjectListView+Chrome`, `+Grid`).
@MainActor
@Suite struct ProjectPanelChromeTests {
    static var hosts: [ShellHost] = []

    func view(defaults: UserDefaults? = nil) -> (ProjectListView, ProjectPanelModel, ShellHost, UserDefaults) {
        let (h, _, _) = ShellImportTests().host()
        let d = defaults ?? UserDefaults(suiteName: "sq.test.projectChrome.\(UUID())")!
        let v = ProjectListView(host: h, defaults: d)
        v.frame = CGRect(x: 0, y: 0, width: 420, height: 400)
        Self.hosts.append(h)
        return (v, h.projectModel!, h, d)
    }

    func click(_ v: ProjectListView, _ p: CGPoint, _ m: InputModifiers = []) {
        _ = v.handle(.mouseDown(x: Float(p.x), y: Float(p.y), modifiers: m), scale: 1)
        _ = v.handle(.mouseUp(x: Float(p.x), y: Float(p.y)), scale: 1)
    }

    func names(_ v: ProjectListView, _ m: ProjectPanelModel) -> [String] { v.rows().map { m.displayName(of: $0.ref) } }

    @Test func searchRowFiltersAsYouTypeAndEscClears() throws {
        let (v, m, _, d) = view()
        _ = m.newBin(name: "Interviews")
        _ = m.newBin(name: "Broll")
        #expect(!v.isSearchVisible)
        let listTop = v.listRect.minY
        v.toggleSearch()
        #expect(v.isSearchVisible && d.bool(forKey: "sq.project.searchVisible"))
        #expect(v.listRect.minY == listTop + ProjectListView.searchRowHeight)
        for ch in "inter" { _ = v.handle(.keyDown(.character(ch), modifiers: []), scale: 1) }
        #expect(m.searchText == "inter")
        #expect(names(v, m) == ["Interviews"])
        _ = v.handle(.keyDown(.escape, modifiers: []), scale: 1)
        #expect(m.searchText.isEmpty && names(v, m).contains("Broll"))
        // Hiding the row clears the search.
        for ch in "br" { _ = v.handle(.keyDown(.character(ch), modifiers: []), scale: 1) }
        v.toggleSearch()
        #expect(m.searchText.isEmpty && !v.isSearchVisible)
    }

    @Test func columnPickerShowsEveryColumnButNameAndPersists() throws {
        let (v, _, h, d) = view()
        let titles = v.columnMenu().map(\.title).filter { !$0.isEmpty }
        #expect(titles.first == "Label" && titles.last == "Reset Columns" && !titles.contains("Name"))
        #expect(v.columns.visible == [.name, .format, .duration])
        // Right-click on the column header opens the picker.
        let sub = v.subheaderRect
        click(v, CGPoint(x: sub.midX, y: sub.midY), .secondary)
        #expect(h.menuBar.controller.isOpen)
        h.menuBar.controller.dismiss()
        v.toggleColumn(.codec)
        #expect(v.columnFrames().map(\.column) == [.name, .format, .duration, .codec])
        let (again, _, _, _) = view(defaults: d)
        #expect(again.columns.isVisible(.codec))
        // A narrow panel drops the columns that leave Name less than its minimum, from the right.
        again.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        let narrow = again.columnFrames()
        #expect(narrow.first?.column == .name && narrow.count < 4)
        #expect(narrow[0].maxX - narrow[0].minX >= ProjectPanelModel.Column.name.minWidth)
        again.resetColumns()
        #expect(again.columns == .defaults)
    }

    @Test func clickOnAColumnTitleSortsAndAgainFlips() throws {
        let (v, m, _, _) = view()
        _ = m.newBin(name: "B")
        _ = m.newBin(name: "A")
        let sub = v.subheaderRect
        let name = try #require(v.columnFrames().first)
        let at = CGPoint(x: name.minX + 30, y: sub.midY)
        click(v, at)
        #expect(m.sortColumn == .name && m.sortAscending)
        #expect(names(v, m).filter { $0.count == 1 } == ["A", "B"])
        click(v, at)
        #expect(!m.sortAscending)
        #expect(names(v, m).filter { $0.count == 1 } == ["B", "A"])
    }

    func drag(_ v: ProjectListView, from a: CGPoint, to b: CGPoint) {
        _ = v.handle(.mouseDown(x: Float(a.x), y: Float(a.y), modifiers: []), scale: 1)
        _ = v.handle(.mouseDragged(x: Float(b.x), y: Float(b.y)), scale: 1)
        _ = v.handle(.mouseUp(x: Float(b.x), y: Float(b.y)), scale: 1)
    }

    @Test func draggingAColumnEdgeResizesItAndSavesTheWidth() throws {
        let (v, m, _, d) = view()
        let fmt = try #require(v.columnFrames().first { $0.column == .format })
        let y = v.subheaderRect.midY
        drag(v, from: CGPoint(x: fmt.minX, y: y), to: CGPoint(x: fmt.minX - 30, y: y))
        let after = try #require(v.columnFrames().first { $0.column == .format })
        #expect(abs((after.maxX - after.minX) - (fmt.maxX - fmt.minX + 30)) < 0.5)
        #expect(m.sortColumn == nil)
        #expect(ProjectColumnLayout.load(from: d).userWidth(of: .format) != nil)
        // Never narrower than the column's minimum.
        let now = try #require(v.columnFrames().first { $0.column == .format })
        drag(v, from: CGPoint(x: now.minX, y: y), to: CGPoint(x: now.minX + 500, y: y))
        let narrow = try #require(v.columnFrames().first { $0.column == .format })
        #expect(narrow.maxX - narrow.minX == ProjectPanelModel.Column.format.minWidth)
    }

    @Test func draggingATitleMovesTheColumnButNeverBeforeName() throws {
        let (v, m, _, d) = view()
        let frames = v.columnFrames()
        let fmt = try #require(frames.first { $0.column == .format }), dur = try #require(frames.first { $0.column == .duration })
        let y = v.subheaderRect.midY
        drag(v, from: CGPoint(x: fmt.minX + 10, y: y), to: CGPoint(x: dur.maxX - 4, y: y))
        #expect(v.columns.visible == [.name, .duration, .format])
        #expect(ProjectColumnLayout.load(from: d).visible == [.name, .duration, .format])
        #expect(m.sortColumn == nil)
        let name = try #require(v.columnFrames().first)
        drag(v, from: CGPoint(x: name.minX + 20, y: y), to: CGPoint(x: name.maxX + 5, y: y))
        #expect(v.columns.visible.first == .name)
    }

    @Test func optionsMenuSwitchesToIconsAndPersists() throws {
        let (v, _, h, d) = view()
        click(v, CGPoint(x: v.optionsRect.midX, y: v.optionsRect.midY))
        #expect(h.menuBar.controller.isOpen)
        h.menuBar.controller.dismiss()
        let titles = v.optionsMenu().map(\.title).filter { !$0.isEmpty }
        #expect(titles.starts(with: ["Import…", "New Folder", "New Color Matte…", "as List", "as Icons", "Search"]))
        v.setViewMode(.icons)
        #expect(d.string(forKey: "ProjectPanel.viewMode") == "icons")
        let (again, _, _, _) = view(defaults: d)
        #expect(again.viewMode == .icons)
    }

    /// The Mac `showOptions` rows after the media filters: a separator, Search Spoken Words, Save Filter as Smart Folder, one
    /// checked row per saved smart folder, then a Delete row for each.
    @Test func optionsMenuEndsWithTheSmartFolderRowsLikeTheMac() throws {
        let (v, m, _, _) = view()
        var titles = v.optionsMenu().map { $0.kind == .separator ? "-" : $0.title }
        #expect(titles.suffix(3) == ["-", "Search Spoken Words", "Save Filter as Smart Folder"])
        m.searchText = "beach"
        v.optionsMenu().first { $0.title == "Save Filter as Smart Folder" }?.action?()
        v.optionsMenu().first { $0.title == "Save Filter as Smart Folder" }?.action?()
        let names = m.project.smartBinList.map(\.name)
        #expect(names == ["beach", "beach 2"])
        titles = v.optionsMenu().map { $0.kind == .separator ? "-" : $0.title }
        #expect(titles.suffix(4) == ["beach", "beach 2", "Delete Smart Folder \"beach\"", "Delete Smart Folder \"beach 2\""])
        v.optionsMenu().first { $0.title == "beach" }?.action?()
        #expect(m.activeSmartBin == m.project.smartBinList.first?.id)
        #expect(v.optionsMenu().first { $0.title == "beach" }?.isChecked == true)
        v.optionsMenu().first { $0.title == "Search Spoken Words" }?.action?()
        #expect(m.searchSpoken)
        v.optionsMenu().first { $0.title == "Delete Smart Folder \"beach\"" }?.action?()
        #expect(m.project.smartBinList.map(\.name) == ["beach 2"])
    }

    @Test func newColorMatteInTheOptionsMenuReachesTheHost() throws {
        let (v, _, h, _) = view()
        var seen: [ShellAction] = []
        h.onAction = { seen.append($0); return true }
        v.optionsMenu().first { $0.title == "New Color Matte…" }?.action?()
        #expect(seen == [.newColorMatte])
    }

    @Test func iconGridEntersFoldersByDoubleClickAndThePathRowGoesBack() throws {
        let (v, m, _, _) = view()
        var t = 10.0
        v.now = { t }
        let bin = try #require(m.newBin(name: "Shots"))
        m.currentBin = bin
        let inner = try #require(m.newBin(name: "Inner"))
        v.setViewMode(.icons)
        let items = v.gridItems()
        #expect(items.first.map { if case .sequence = $0 { true } else { false } } == true)   // sequences first at the top
        let i = try #require(items.firstIndex(of: .bin(bin)))
        // Tiles sit side by side: the 420 pt panel holds 3 columns of 108 pt cells.
        #expect(v.gridColumns == 3 && v.tileRect(1).minX > v.tileRect(0).maxX)
        let r = v.tileRect(i)
        click(v, CGPoint(x: r.midX, y: r.midY))
        #expect(v.selection == [.bin(bin)])
        t += 0.2
        click(v, CGPoint(x: r.midX, y: r.midY))
        #expect(m.browseBin == bin && v.gridItems() == [.bin(inner)])
        #expect(v.crumbPath(m) == "Project / Shots")
        #expect(v.subheaderRect.height == ProjectListView.crumbHeight)
        // New Folder from the "..." menu lands in the folder the grid shows.
        v.select([])
        v.newFolder()
        #expect(v.gridItems().count == 2)
        click(v, CGPoint(x: v.subheaderRect.midX, y: v.subheaderRect.midY))
        #expect(m.browseBin == m.project.rootBin.id && v.selection == [.bin(bin)])
    }

    @Test func thumbnailSliderInTheIconHeaderResizesTheTilesAndPersists() throws {
        let (v, _, _, d) = view()
        #expect(v.sizeSliderRect == nil)   // list mode: no slider
        v.setViewMode(.icons)
        let r = try #require(v.sizeSliderRect)
        #expect(r.width == ProjectListView.sizeSliderWidth && r.maxX < v.optionsRect.minX)
        let before = v.tileRect(0).width
        _ = v.handle(.mouseDown(x: Float(r.minX), y: Float(r.midY), modifiers: []), scale: 1)
        #expect(v.thumbSize == ProjectListView.thumbRange.lowerBound)
        _ = v.handle(.mouseDragged(x: Float(r.maxX + 40), y: Float(r.midY)), scale: 1)
        _ = v.handle(.mouseUp(x: Float(r.maxX + 40), y: Float(r.midY)), scale: 1)
        #expect(v.thumbSize == ProjectListView.thumbRange.upperBound)
        #expect(v.tileRect(0).width > before)
        #expect(d.double(forKey: ProjectListView.thumbSizeKey) == Double(ProjectListView.thumbRange.upperBound))
        let (again, _, _, _) = view(defaults: d)
        #expect(again.thumbSize == ProjectListView.thumbRange.upperBound)
    }

    @Test func gridDrawsThePosterFromTheHostsImageSlot() async throws {
        let (v, m, _, _) = view()
        await m.importFiles([try ShellImportTests().file("poster.mp4")])
        let media = try #require(m.project.media.first)
        v.poster = { $0 == media.id ? ProjectPoster(slot: 0, u0: 0, v0: 0, u1: 0.5, v1: 0.25, pixelSize: CGSize(width: 160, height: 90)) : nil }
        v.setViewMode(.icons)
        var c = Canvas(width: 420, height: 400, atlas: GlyphAtlas(), scale: 1)
        v.draw(&c, theme: DrawTheme())
        let images = c.list.quads.filter { $0.kind == DrawQuad.Kind.image.rawValue }
        #expect(images.count == 1)
        #expect(images.first.map { $0.pad } == 0)
        // 16:9 into a 16:10 plate: cropped left and right, full height.
        let q = try #require(images.first)
        #expect(q.v0 == 0 && q.v1 == 0.25 && q.u0 > 0 && q.u1 < 0.5)
    }

    @Test func listDrawsTheColumnHeaderAndEveryVisibleColumn() throws {
        let (v, m, _, _) = view()
        _ = m.newBin(name: "Shots")
        var c = Canvas(width: 420, height: 400, atlas: GlyphAtlas(), scale: 1)
        v.draw(&c, theme: DrawTheme())
        let base = c.list.quads.count
        v.toggleColumn(.label)
        var c2 = Canvas(width: 420, height: 400, atlas: GlyphAtlas(), scale: 1)
        v.draw(&c2, theme: DrawTheme())
        #expect(c2.list.quads.count > base)
    }
}
