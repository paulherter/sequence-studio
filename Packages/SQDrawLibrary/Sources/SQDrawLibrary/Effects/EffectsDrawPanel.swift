import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQLibrary
import SQEditorSession

/// The Effects panel on the shared draw-list toolkit, translated from the Mac `EffectsPanelView`: the same catalog
/// (`EffectsCatalog`), folder outline (`EffectFolderOutline`, the user's folders from `EffectFolderStore`, the saved open
/// state), search with the effects' other names, list or grid (`EffectsViewMode`, the Mac key), the "fx" badge, the
/// right-click folder menu, a drop of an item onto a user folder, user folder reordering, and a drag of an effect or
/// transition out of the panel (the host routes it onto the timeline). Coordinates are panel-local points.
/// Grid tiles show the host's still (`EffectsTileAtlas`, the Mac `EffectPreviewStore` still), the icon until it is made.
/// Hovering a grid tile plays its `EffectPreviewPlan` loop (`EffectsTileAtlas.setHover`, one live cell; text presets keep
/// their still: their Mac loop is a CoreGraphics render).
@MainActor
public final class EffectsDrawPanel {
    public enum DragPhase: Sendable, Equatable { case moved, ended, canceled }

    public static let searchRowHeight: CGFloat = 38
    public static let rowHeight: CGFloat = 26
    public static let indent: CGFloat = 14
    public static let tileWidth: CGFloat = 104
    static let dragSlop: CGFloat = 4
    static let doubleClick: Double = 0.4

    public var size: CGSize = .zero
    public var theme = DrawTheme()
    public let defaults: UserDefaults

    /// Saved presets of the Library listed under "Presets" (`EffectsCatalog.presetEntries`).
    public var presetEntries: [EffectsEntry] = [] { didSet { rebuild() } }
    public private(set) var folderStore: EffectFolderStore
    public private(set) var expanded: Set<String>
    public private(set) var query = ""
    /// While searching every matching folder is open; these are the ones the user closed again.
    public private(set) var collapsedInSearch: Set<String> = []
    public private(set) var rows: [EffectsRow] = []
    public private(set) var viewMode: EffectsViewMode
    public private(set) var selectedID: String?
    let scrollBody = ScrollBody()
    /// The scroll offset; the body adds momentum and the rubber band.
    public private(set) var scroll: CGFloat {
        get { scrollBody.position }
        set { scrollBody.position = newValue }
    }
    var search = TextFieldControl()

    /// Double-click or Return on an item: the effect, transition or preset id (`EffectsRow.itemID`).
    public var onApply: ((String) -> Void)?
    /// The grid tile's still in the host's image slot (`EffectsTileAtlas.picture(for:)`); nil: the icon.
    public var picture: ((String) -> EffectsTilePicture?)?
    /// The ids of the grid tiles in view (empty in list mode), for the host's `EffectsTileAtlas.prepare`.
    public var visibleTileIDs: [String] {
        guard viewMode == .grid else { return [] }
        let top = listRect.minY - scroll
        return grid.items.filter { item in
            let f = item.frame.offsetBy(dx: 0, dy: top)
            return !item.isHeader && f.maxY >= listRect.minY && f.minY <= listRect.maxY
        }.map(\.id)
    }
    /// A menu at a panel-local point.
    public var onMenu: (([SQMenuItem], CGPoint) -> Void)?
    /// Asks for a folder name (title, initial text); the answer comes back through the closure (nil = canceled).
    public var askName: ((String, String, @escaping @MainActor (String?) -> Void) -> Void)?
    /// A drag of effect ids out of the panel; the point is panel-local (the host turns it into window pixels).
    public var onDrag: (([String], DragPhase, CGPoint) -> Void)?
    /// Clock for the double-click test.
    public var now: () -> Double = { ProcessInfo.processInfo.systemUptime }

    private var press: (point: CGPoint, row: EffectsRow?)?
    public private(set) var isDragging = false
    private var lastClick: (id: String, time: Double)?
    /// The row under the pointer while an item or folder is dragged inside the panel (drop target highlight).
    public private(set) var dropRow: Int?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folderStore = EffectFolderStore.load(from: defaults)
        var open = EffectFolderOutline.loadExpanded(from: defaults)
        if open.isEmpty { open = [EffectFolderOutline.builtinID(EffectFolderOutline.effectsFolder)] }
        expanded = open
        viewMode = EffectsViewMode.load(from: defaults)
        search.alignment = .left
        rebuild()
    }

    public var allEntries: [EffectsEntry] {
        EffectsCatalog.catalog + EffectsCatalog.builtInPresetEntries + EffectsCatalog.textPresetEntries + presetEntries
    }

    func rebuild() {
        rows = EffectFolderOutline.rows(entries: allEntries, store: folderStore, expanded: expanded, query: query,
                                        collapsedInSearch: collapsedInSearch)
    }

    private func saveFolders() { folderStore.save(to: defaults); rebuild() }

    // MARK: Model actions (the Mac panel's closures)

    public func setQuery(_ q: String) {
        guard q != query else { return }
        query = q; collapsedInSearch = []     // a new search opens all matches again
        scroll = 0
        rebuild()
    }

    public func toggleFolder(_ id: String) {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            // Search results are forced open; the arrow closes one for this search only (not saved).
            if collapsedInSearch.contains(id) { collapsedInSearch.remove(id) } else { collapsedInSearch.insert(id) }
        } else {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
            EffectFolderOutline.saveExpanded(expanded, to: defaults)
        }
        rebuild()
    }

    public func setViewMode(_ mode: EffectsViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        mode.save(to: defaults)
        scroll = 0
    }

    public func newFolder(named name: String, adding item: String? = nil) {
        let id = folderStore.createFolder(named: name)
        if let item { folderStore.add(item, to: id) }
        expanded.insert(EffectFolderOutline.userID(id))
        EffectFolderOutline.saveExpanded(expanded, to: defaults)
        saveFolders()
    }

    public func renameFolder(_ id: UUID, to name: String) { folderStore.rename(id, to: name); saveFolders() }
    public func deleteFolder(_ id: UUID) { folderStore.delete(id); saveFolders() }
    public func removeItem(_ item: String, from folder: UUID) { folderStore.remove(item, from: folder); saveFolders() }

    public func addItem(_ item: String, to folder: UUID) {
        folderStore.add(item, to: folder)
        expanded.insert(EffectFolderOutline.userID(folder))
        EffectFolderOutline.saveExpanded(expanded, to: defaults)
        saveFolders()
    }

    public func moveFolder(_ id: UUID, before target: UUID?) { folderStore.move(id, before: target); saveFolders() }

    private func askNewFolder(adding item: String? = nil) {
        askName?("New Folder", "New Folder") { [weak self] name in
            guard let self, let name else { return }
            newFolder(named: name, adding: item)
        }
    }

    /// The right-click menu of a row (nil = empty space): the Mac `menuItems(forRow:)`.
    public func menu(for row: EffectsRow?) -> [SQMenuItem] {
        func item(_ title: String, _ action: @escaping @MainActor () -> Void) -> SQMenuItem { SQMenuItem(title: title, action: action) }
        var out = [item("New Folder\u{2026}") { [weak self] in self?.askNewFolder() }]
        guard let r = row else { return out }
        if r.isFolder, let f = r.userFolder {
            out.append(item("Rename Folder\u{2026}") { [weak self] in
                guard let self else { return }
                askName?("Rename Folder", folderStore.folder(f)?.name ?? "") { [weak self] n in
                    if let n { self?.renameFolder(f, to: n) }
                }
            })
            out.append(.separator)
            out.append(item("Delete Folder") { [weak self] in self?.deleteFolder(f) })
        } else if !r.isFolder && !r.isHeader {
            var sub: [SQMenuItem] = []
            for f in folderStore.folders { sub.append(item(f.name) { [weak self] in self?.addItem(r.itemID, to: f.id) }) }
            if !folderStore.folders.isEmpty { sub.append(.separator) }
            sub.append(item("New Folder\u{2026}") { [weak self] in self?.askNewFolder(adding: r.itemID) })
            out.insert(SQMenuItem(title: "Add to Folder", submenu: sub), at: 0)
            if let f = r.userFolder {
                out.append(.separator)
                out.append(item("Remove from Folder") { [weak self] in self?.removeItem(r.itemID, from: f) })
            }
        }
        return out
    }

    /// The panel header's "..." menu: as List / as Grid.
    public func optionsMenu() -> [SQMenuItem] {
        [SQMenuItem(title: "as List", isChecked: viewMode == .list, action: { [weak self] in self?.setViewMode(.list) }),
         SQMenuItem(title: "as Grid", isChecked: viewMode == .grid, action: { [weak self] in self?.setViewMode(.grid) })]
    }

    // MARK: Geometry

    var searchFieldRect: CGRect {
        CGRect(x: CGFloat(DrawTheme.Spacing.sm), y: 7, width: max(size.width - 2 * CGFloat(DrawTheme.Spacing.sm), 0),
               height: Self.searchRowHeight - 14)
    }
    var searchClearRect: CGRect { CGRect(x: searchFieldRect.maxX - 20, y: searchFieldRect.midY - 8, width: 16, height: 16) }
    var listRect: CGRect { CGRect(x: 0, y: Self.searchRowHeight, width: size.width, height: max(size.height - Self.searchRowHeight, 0)) }

    func rowRect(_ i: Int) -> CGRect {
        CGRect(x: 0, y: listRect.minY + CGFloat(i) * Self.rowHeight - scroll, width: size.width, height: Self.rowHeight)
    }

    /// Grid rows: an open folder becomes a heading over its tiles (closed folders stay as a heading too).
    var gridRows: [EffectsRow] {
        rows.map { r in
            guard r.isFolder else { return r }
            var h = r
            h.isHeader = true
            return h
        }
    }

    var grid: EffectsGridLayout { EffectsGridLayout(rows: gridRows, width: max(size.width, 1), tileWidth: Self.tileWidth) }

    var contentHeight: CGFloat { viewMode == .list ? CGFloat(rows.count) * Self.rowHeight : grid.contentHeight }

    /// The row index under a panel-local point.
    public func rowIndex(at p: CGPoint) -> Int? {
        guard listRect.contains(p) else { return nil }
        switch viewMode {
        case .list:
            let i = Int(((p.y - listRect.minY + scroll) / Self.rowHeight).rounded(.down))
            return rows.indices.contains(i) ? i : nil
        case .grid:
            let q = CGPoint(x: p.x, y: p.y - listRect.minY + scroll)
            guard let item = grid.items.first(where: { $0.frame.contains(q) }) else { return nil }
            return rows.firstIndex { $0.id == item.id }
        }
    }

    /// The grid tile (not a header) under a panel-local point; nil in list mode or off a tile.
    public func tileID(at p: CGPoint) -> String? {
        guard viewMode == .grid, listRect.contains(p) else { return nil }
        let q = CGPoint(x: p.x, y: p.y - listRect.minY + scroll)
        guard let item = grid.items.first(where: { !$0.isHeader && $0.frame.contains(q) }) else { return nil }
        return item.id
    }

    static func lead(depth: Int) -> CGFloat {
        CGFloat(DrawTheme.Spacing.xs + DrawTheme.Spacing.sm) + CGFloat(min(max(depth, 0), 2)) * indent
    }

    /// What dragging a row carries out of the panel: an effect or transition id (presets apply by double-click, folders
    /// do not drag out; the Mac pasteboard writer).
    static func dragIDs(for r: EffectsRow) -> [String] {
        guard !r.isHeader, !r.isFolder, !r.itemID.hasPrefix("preset.") else { return [] }
        return [r.itemID]
    }

    // MARK: Events (panel-local points)

    public func mouseDown(at p: CGPoint, modifiers m: InputModifiers) {
        if p.y < Self.searchRowHeight {
            if !searchText.isEmpty, searchClearRect.contains(p) { setSearchText(""); return }
            if searchFieldRect.contains(p) { search.mouseDown() }
            return
        }
        endSearchEditing()
        let i = rowIndex(at: p)
        let row = i.map { rows[$0] }
        if m.contains(.secondary) {
            if let row, !row.isFolder, !row.isHeader { selectedID = row.id }
            onMenu?(menu(for: row), p)
            press = nil
            return
        }
        press = (p, row)
        guard let row else { selectedID = nil; return }
        if row.isFolder || row.isHeader {
            // A folder row only opens or closes (a user folder can still be dragged to reorder).
            if row.userFolder == nil || !row.isFolder { toggleFolder(row.id); press = nil }
            return
        }
        selectedID = row.id
        let t = now()
        defer { lastClick = (row.id, t) }
        if let last = lastClick, last.id == row.id, t - last.time < Self.doubleClick {
            lastClick = nil
            press = nil
            onApply?(row.itemID)
        }
    }

    public func mouseDragged(to p: CGPoint) {
        guard let start = press else { return }
        if !isDragging {
            guard hypot(p.x - start.point.x, p.y - start.point.y) >= Self.dragSlop, start.row != nil else { return }
            isDragging = true
            lastClick = nil
        }
        dropRow = internalDropTarget(at: p)
        if let r = start.row, !r.isFolder { onDrag?(Self.dragIDs(for: r), .moved, p) }
    }

    public func mouseUp(at p: CGPoint) {
        defer { press = nil; isDragging = false; dropRow = nil }
        guard let start = press, let r = start.row else { return }
        guard isDragging else {
            // A click (no drag) on a user folder row opens or closes it.
            if r.isFolder { toggleFolder(r.id) }
            return
        }
        if r.isFolder, let moving = r.userFolder {
            if listRect.contains(p) { moveFolder(moving, before: folderMoveTarget(at: p)) }
            return
        }
        if listRect.contains(p), let t = internalDropTarget(at: p), let folder = rows[t].userFolder {
            addItem(r.itemID, to: folder)
            onDrag?(Self.dragIDs(for: r), .canceled, p)
            return
        }
        onDrag?(Self.dragIDs(for: r), .ended, p)
    }

    /// A user folder row under the pointer while an item is dragged inside the panel (built-in folders are read-only).
    func internalDropTarget(at p: CGPoint) -> Int? {
        guard let i = rowIndex(at: p), rows[i].userFolder != nil else { return nil }
        return i
    }

    /// Where a dragged user folder lands: in front of the folder under the pointer, else after the last user folder.
    func folderMoveTarget(at p: CGPoint) -> UUID? {
        guard let i = rowIndex(at: p) else { return nil }
        return rows[i].userFolder
    }

    public func scroll(dy: CGFloat) {
        let maxScroll = max(contentHeight - listRect.height, 0)
        scrollBody.feed(dy: dy, maxOffset: maxScroll, extent: listRect.height)
    }

    /// Keys while the panel has focus: typing in the search field, up / down selection, left / right open and close
    /// folders (`EffectFolderOutline.keyNavigation`), Return applies, Escape cancels a drag.
    public func key(_ k: InputKey, modifiers m: InputModifiers) -> Bool {
        if k == .escape, isDragging, let r = press?.row {
            onDrag?(Self.dragIDs(for: r), .canceled, .zero)
            press = nil; isDragging = false; dropRow = nil
            return true
        }
        if search.isEditing {
            if k == .escape {
                if searchText.isEmpty { search.cancel() } else { setSearchText(""); search.mouseDown() }
                return true
            }
            if k == .down { endSearchEditing(); moveSelection(1); return true }
            _ = search.key(k, modifiers: m)
            setQuery(searchText)
            return true
        }
        let sel = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? -1
        switch k {
        case .up: moveSelection(-1); return true
        case .down: moveSelection(1); return true
        case .left, .right:
            switch EffectFolderOutline.keyNavigation(rows: rows, selected: sel, key: k == .left ? .left : .right) {
            case .none: return false
            case .select(let i): selectedID = rows[i].id
            case .toggle(let id): toggleFolder(id); selectedID = id
            }
            return true
        case .enter:
            guard rows.indices.contains(sel) else { return false }
            let r = rows[sel]
            if r.isFolder { toggleFolder(r.id) } else if !r.isHeader { onApply?(r.itemID) }
            return true
        default: return false
        }
    }

    func moveSelection(_ d: Int) {
        guard !rows.isEmpty else { return }
        let cur = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? (d > 0 ? -1 : rows.count)
        var i = cur + d
        while rows.indices.contains(i), rows[i].isHeader { i += d }
        guard rows.indices.contains(i) else { return }
        selectedID = rows[i].id
        let r = rowRect(i)
        if r.minY < listRect.minY { scroll -= listRect.minY - r.minY }
        if r.maxY > listRect.maxY { scroll += r.maxY - listRect.maxY }
    }

    public var searchText: String { search.editor?.string ?? search.text }
    public var isEditingSearch: Bool { search.isEditing }

    func setSearchText(_ s: String) {
        search.cancel()
        search.text = s
        setQuery(s)
    }

    func endSearchEditing() { if search.isEditing { _ = search.commit(); search.text = searchText } }

    /// Focus goes to the search field (Cmd+F in the panel).
    public func focusSearch() { search.mouseDown() }

    /// The hover tip under a point: a row's subtitle or the full title when it is cut.
    public func help(at p: CGPoint) -> String? {
        guard let i = rowIndex(at: p) else { return nil }
        let r = rows[i]
        return r.subtitle.isEmpty ? nil : r.subtitle
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        let t = theme
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        let f = searchFieldRect
        search.fontSize = 11
        // `SQSearchField`: the magnifier at 9, the text from 28 (as the Library field).
        search.textInset = 28
        search.quiet = true
        search.draw(&c, in: f, theme: t, focused: search.isEditing)
        c.draw(icon: .search, at: CGPoint(x: f.minX + 9, y: f.midY - 6), size: 12, t.label3)
        if searchText.isEmpty, !search.isEditing {
            c.draw("Search effects", in: f, fontSize: 11, t.label3, inset: 28)
        } else if !searchText.isEmpty {
            let x = searchClearRect
            c.draw(icon: .closeCircleFilled, at: CGPoint(x: x.minX + 1, y: x.minY + 1), size: x.width - 2, t.label3)
        }
        c.saveGState()
        c.clip(to: listRect)
        if rows.isEmpty { drawEmpty(&c) } else if viewMode == .list { drawList(&c) } else { drawGrid(&c) }
        c.restoreGState()
    }

    private func drawEmpty(_ c: inout Canvas) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let r = listRect.insetBy(dx: CGFloat(DrawTheme.Spacing.md), dy: 0)
        c.draw(q.isEmpty ? "Nothing here yet" : "No results", in: CGRect(x: r.minX, y: r.midY - 20, width: r.width, height: 18),
               fontSize: CGFloat(DrawTheme.TypeSize.title), theme.label2, align: .center, face: c.semibold)
        if !q.isEmpty {
            c.draw("Nothing here matches \u{201C}\(q)\u{201D}.", in: CGRect(x: r.minX, y: r.midY, width: r.width, height: 16),
                   fontSize: 11, theme.label3, align: .center)
        }
    }

    private func drawList(_ c: inout Canvas) {
        let t = theme
        let gap = CGFloat(DrawTheme.Spacing.xs + DrawTheme.Spacing.xxs)
        for (i, r) in rows.enumerated() {
            let rr = rowRect(i)
            guard rr.maxY >= listRect.minY, rr.minY <= listRect.maxY else { continue }
            let pill = rr.insetBy(dx: CGFloat(DrawTheme.Spacing.xs), dy: 1)
            if dropRow == i {
                c.fill(roundedRect: pill, radius: CGFloat(DrawTheme.Radius.small), t.accentFill)
                c.stroke(roundedRect: pill, radius: CGFloat(DrawTheme.Radius.small), width: 2, t.accent)
            } else if selectedID == r.id {
                c.fill(roundedRect: pill, radius: CGFloat(DrawTheme.Radius.small), t.accentFill)
            }
            var x = Self.lead(depth: r.depth)
            if r.isHeader {
                c.draw(r.title, in: CGRect(x: x, y: rr.minY, width: rr.width - x, height: rr.height), fontSize: 11, t.label2)
                continue
            }
            if r.isFolder {
                let mid = CGPoint(x: x + 6, y: rr.midY)
                let pts = r.isExpanded
                    ? [CGPoint(x: mid.x - 3, y: mid.y - 1.5), CGPoint(x: mid.x, y: mid.y + 1.5), CGPoint(x: mid.x + 3, y: mid.y - 1.5)]
                    : [CGPoint(x: mid.x - 1.5, y: mid.y - 3), CGPoint(x: mid.x + 1.5, y: mid.y), CGPoint(x: mid.x - 1.5, y: mid.y + 3)]
                c.strokePolyline(pts, width: 1.2, t.label2)
                x += 12 + gap
                c.draw(icon: r.symbol == .folderFilled ? .folderFilled : .folder, at: CGPoint(x: x, y: rr.midY - 6), size: 12, t.label3)
                x += 14 + gap
            } else {
                // v9 `.fx`: the small "fx" mark in front of an effect row (16 high, radius 4, `fill`, `label2`).
                let w = c.size(of: "fx", fontSize: 9).width + 10
                let badge = CGRect(x: x, y: rr.midY - 8, width: w, height: 16)
                c.fill(roundedRect: badge, radius: CGFloat(DrawTheme.Radius.small), t.fill)
                c.draw("fx", in: badge, fontSize: 9, t.label2, align: .center)
                x = badge.maxX + gap
            }
            var right = rr.maxX - Self.lead(depth: 0)
            if r.isFolder, let n = r.count, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let s = "\(n)"
                let w = c.size(of: s, fontSize: 10).width
                c.draw(s, at: CGPoint(x: right - w, y: rr.midY - 6), fontSize: 10, t.label3)
                right -= w + gap
            }
            c.draw(r.title, in: CGRect(x: x, y: rr.minY, width: max(right - x, 0), height: rr.height), fontSize: 12, t.label)   // NSTableCellView turns its text field white, whatever textColor says
        }
    }

    private func drawGrid(_ c: inout Canvas) {
        let t = theme
        let top = listRect.minY - scroll
        for item in grid.items {
            let f = item.frame.offsetBy(dx: 0, dy: top)
            guard f.maxY >= listRect.minY, f.minY <= listRect.maxY else { continue }
            if item.isHeader {
                c.draw(item.title, in: f.insetBy(dx: EffectsGridLayout.pad, dy: 0), fontSize: 11, t.label2)
                continue
            }
            let thumb = item.thumb.offsetBy(dx: 0, dy: top)
            c.fill(roundedRect: thumb, radius: CGFloat(DrawTheme.Radius.small), t.content)
            if let pic = picture?(item.id) {
                c.draw(imageSlot: pic.slot, in: thumb, source: pic.source)
            } else {
                let s: CGFloat = 22
                c.draw(icon: item.symbol, at: CGPoint(x: thumb.midX - s / 2, y: thumb.midY - s / 2), size: s, t.label2)
            }
            if selectedID == item.id {
                c.stroke(roundedRect: thumb, radius: CGFloat(DrawTheme.Radius.small), width: 2, t.accent)
            }
            c.draw(item.title, in: CGRect(x: f.minX, y: thumb.maxY, width: f.width, height: EffectsGridLayout.captionHeight),
                   fontSize: 10, t.label2, align: .center)
        }
    }
}
