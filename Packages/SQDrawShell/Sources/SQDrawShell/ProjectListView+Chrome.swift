import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// A poster frame in one of the renderer's image slots (the Windows timeline thumbnail atlas): the part `u0...v1` of the
/// slot, `pixelSize` big.
public struct ProjectPoster: Sendable, Equatable {
    public var slot: Int
    public var u0: Float, v0: Float, u1: Float, v1: Float
    public var pixelSize: CGSize
    public init(slot: Int, u0: Float = 0, v0: Float = 0, u1: Float = 1, v1: Float = 1, pixelSize: CGSize) {
        self.slot = slot; self.u0 = u0; self.v0 = v0; self.u1 = u1; self.v1 = v1; self.pixelSize = pixelSize
    }

    /// The part that fills `r` cropped to its aspect (centered), as the Mac draws a poster into a tile.
    public func cropped(toFill r: CGRect) -> (Float, Float, Float, Float) {
        guard pixelSize.width > 0, pixelSize.height > 0, r.width > 0, r.height > 0 else { return (u0, v0, u1, v1) }
        let k = max(r.width / pixelSize.width, r.height / pixelSize.height)
        let fx = Float(min(r.width / (pixelSize.width * k), 1)), fy = Float(min(r.height / (pixelSize.height * k), 1))
        let w = u1 - u0, h = v1 - v0, cu = u0 + w / 2, cv = v0 + h / 2
        return (cu - w * fx / 2, cv - h * fy / 2, cu + w * fx / 2, cv + h * fy / 2)
    }
}

/// The panel chrome: header with the "..." menu, the search row, the list's column header with the column picker, the
/// grid's path row (`ProjectPanelView.showOptions`, `toggleSearch`, `headerMenuItems`, `toggleColumn`, `setViewMode`).
extension ProjectListView {
    public struct ColumnFrame: Equatable {
        public var column: ProjectPanelModel.Column
        public var minX: CGFloat
        public var maxX: CGFloat
    }
    /// Column sizing pad (`Theme.Spacing.xs`, as `ProjectColumnSizing`) and the cell text inset (`Theme.Spacing.sm`).
    static let cellPad: CGFloat = CGFloat(DrawTheme.Spacing.xs)
    static let cellInset: CGFloat = CGFloat(DrawTheme.Spacing.sm)
    /// The Mac list's text: `Theme.Typography.list` 12 for rows, `listHeader` 11 semibold for the column titles.
    static let listFont: CGFloat = 12
    static let optionsSize: CGFloat = 22

    static func rightAligned(_ c: ProjectPanelModel.Column) -> Bool { c == .duration || c == .frameRate }

    /// The header row is gone while the dock's tab strip carries the item count, New Folder and "..." (Mac `TabStrip`).
    var headerRect: CGRect { CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: stripDock == nil ? Self.headerHeight : 0) }
    /// The strip tools of the Project tab: "..." at the right end, New Folder left of it, the count left of that
    /// (`TabStrip.layout`: 28 pt buttons 2 pt apart, the count label 6 pt wider than its text). Nil while the tab is not shown.
    struct StripRects { var more: CGRect; var folder: CGRect; var count: CGFloat }
    var stripRects: StripRects? {
        guard let g = stripDock?.groups.first(where: { $0.selected == .project }), g.strip.height > 0 else { return nil }
        let s = g.strip, h: CGFloat = 22
        let more = CGRect(x: s.maxX - CGFloat(DrawTheme.Spacing.sm) - Self.stripButton, y: ((s.height - 1 - h) / 2).rounded() + s.minY,
                          width: Self.stripButton, height: h)
        let folder = more.offsetBy(dx: -(Self.stripButton + 2), dy: 0)
        return StripRects(more: more, folder: folder, count: folder.minX - 2 - 6)
    }
    static let stripButton: CGFloat = 28

    /// Moves the item count, New Folder and "..." into `dock`'s tab strip (the header row goes), keeping the tab names clear of them.
    public func dock(in dock: ShellDock) {
        stripDock = dock
        let previous = dock.stripTools
        dock.stripTools = { [weak self] p in
            guard p == .project, let self else { return previous(p) }
            let w = (self.host?.measure ?? TextMeasure(atlas: nil, scale: 1)).width(self.itemCountText, size: 11)
            let slider = self.viewMode == .icons ? Self.sizeSliderWidth + CGFloat(DrawTheme.Spacing.md) : 0
            return 2 * Self.stripButton + 2 + ceil(w) + 6 + 2 + slider
        }
    }

    /// A press on the strip tools; true when taken.
    func stripClick(at p: CGPoint) -> Bool {
        guard let t = stripRects else { return false }
        if t.folder.contains(p) { newFolder(); return true }
        if t.more.contains(p) {
            host?.menuBar.controller.present(items: optionsMenu(), at: CGPoint(x: t.more.minX, y: t.more.maxY))
            return true
        }
        if let r = sizeSliderRect, r.insetBy(dx: -4, dy: -4).contains(p) { sizeSliderDragging = true; setThumbSize(atX: p.x); return true }
        return false
    }

    var searchRect: CGRect {
        CGRect(x: frame.minX, y: headerRect.maxY, width: frame.width, height: isSearchVisible ? Self.searchRowHeight : 0)
    }
    var searchFieldRect: CGRect { searchRect.insetBy(dx: CGFloat(DrawTheme.Spacing.sm), dy: 7) }
    var searchClearRect: CGRect {
        CGRect(x: searchFieldRect.maxX - 20, y: searchFieldRect.midY - 8, width: 16, height: 16)
    }
    /// Column header (list) or path row (grid inside a folder).
    var subheaderRect: CGRect {
        let h: CGFloat = viewMode == .list ? Self.columnHeaderHeight : (isInsideFolder ? Self.crumbHeight : 0)
        return CGRect(x: frame.minX, y: searchRect.maxY, width: frame.width, height: h)
    }
    var chromeHeight: CGFloat { subheaderRect.maxY - frame.minY }
    var optionsRect: CGRect {
        if let r = stripRects?.more { return r }
        return CGRect(x: headerRect.maxX - CGFloat(DrawTheme.Spacing.sm) - Self.optionsSize, y: headerRect.midY - Self.optionsSize / 2,
               width: Self.optionsSize, height: Self.optionsSize)
    }
    static let sizeSliderWidth: CGFloat = 64
    /// The thumbnail size slider in the header, icon grid only (the Mac `sizeSlider`), left of the item count.
    var sizeSliderRect: CGRect? {
        guard viewMode == .icons else { return nil }
        let w = (host?.measure ?? TextMeasure(atlas: nil, scale: 1)).width(itemCountText, size: 11)
        if let t = stripRects {
            // shortcut: the Mac keeps the slider on the icon view's path row; here it sits left of the count in the strip. Upgrade with the path row.
            return CGRect(x: t.count - w - CGFloat(DrawTheme.Spacing.md) - Self.sizeSliderWidth, y: t.more.midY - 8, width: Self.sizeSliderWidth, height: 16)
        }
        let right = optionsRect.minX - CGFloat(DrawTheme.Spacing.sm) - w - CGFloat(DrawTheme.Spacing.md)
        return CGRect(x: right - Self.sizeSliderWidth, y: headerRect.midY - 8, width: Self.sizeSliderWidth, height: 16)
    }
    /// "8 items" (the Mac `ProjectPanelView.itemCountText`): every sequence and clip in the project, or what the open
    /// folder holds in icon view; folders do not count.
    var itemCountText: String {
        guard let model else { return "0 items" }
        let n: Int
        if viewMode == .icons {
            n = model.children(of: model.project.bin(model.browseBin) ?? model.project.rootBin).count
        } else {
            n = model.project.rootBin.allRefs.filter { if case .bin = $0 { false } else { true } }.count
        }
        return n == 1 ? "1 item" : "\(n) items"
    }

    func setThumbSize(atX x: CGFloat) {
        guard let r = sizeSliderRect else { return }
        let f = CGFloat(InspectorDraw.sliderFraction(x: x, in: r))
        thumbSize = (Self.thumbRange.lowerBound + f * (Self.thumbRange.upperBound - Self.thumbRange.lowerBound)).rounded()
    }

    var isInsideFolder: Bool { model.map { $0.browseBin != $0.project.rootBin.id } ?? false }

    // MARK: View mode, search, columns

    public func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        defaults.set(mode.rawValue, forKey: Self.viewModeKey)
        // The grid shows one folder at a time; it starts at the top (the Mac `setViewMode`).
        if mode == .icons, let model { model.browseBin = model.project.rootBin.id; model.currentBin = model.browseBin }
        scroll = 0
    }

    /// Shows or hides the search row (kept per user); hiding clears the search, showing puts the cursor in the field.
    public func toggleSearch() {
        isSearchVisible.toggle()
        defaults.set(isSearchVisible, forKey: Self.searchVisibleKey)
        if isSearchVisible {
            search.mouseDown()
            hasFocus = true
        } else {
            search.cancel()
            setSearchText("")
            // The Mac also drops the filter chips and the grouping when the search row closes.
            model?.filterTokens = []
            model?.grouping = .folders
        }
    }

    public var searchText: String { search.editor?.string ?? search.text }

    func setSearchText(_ s: String) {
        search.cancel()
        search.text = s
        model?.searchText = s
        scroll = 0
    }

    func searchKey(_ k: InputKey, modifiers m: InputModifiers) {
        if k == .escape {
            // Esc clears the field first, then leaves it.
            if searchText.isEmpty { search.cancel() } else { setSearchText(""); search.mouseDown() }
            return
        }
        _ = search.key(k, modifiers: m)
        model?.searchText = searchText
        scroll = 0
    }

    func endSearchEditing() { if search.isEditing { _ = search.commit() } }

    public func toggleColumn(_ c: ProjectPanelModel.Column) {
        columns.toggle(c)
        columns.save(to: defaults)
    }

    public func resetColumns() {
        columns = .defaults
        columns.save(to: defaults)
    }

    /// The column picker (`ProjectPanelMenus.headerItems`): every column but Name, checked when shown, then Reset Columns.
    public func columnMenu() -> [SQMenuItem] {
        var rows: [SQMenuItem] = []
        for col in ProjectPanelModel.Column.allCases where col != .name {
            rows.append(SQMenuItem(title: col.title, isChecked: columns.isVisible(col), action: { [weak self] in self?.toggleColumn(col) }))
        }
        rows += [.separator, SQMenuItem(title: "Reset Columns", action: { [weak self] in self?.resetColumns() })]
        return rows
    }

    /// The header's "..." menu (`ProjectPanelView.showOptions`): import and creation, the view mode, search, the media filter.
    public func optionsMenu() -> [SQMenuItem] {
        guard let model else { return [] }
        var rows: [SQMenuItem] = [
            SQMenuItem(title: "Import…", action: { [weak self] in self?.host?.spawn { await self?.host?.importAnything() } }),
            SQMenuItem(title: "New Folder", action: { [weak self] in self?.selection = []; self?.newFolder() }),
            SQMenuItem(title: "New Color Matte…", action: { [weak self] in self?.host?.perform(.newColorMatte) }),
            .separator,
            SQMenuItem(title: "as List", isChecked: viewMode == .list, action: { [weak self] in self?.setViewMode(.list) }),
            SQMenuItem(title: "as Icons", isChecked: viewMode == .icons, action: { [weak self] in self?.setViewMode(.icons) }),
            .separator,
            SQMenuItem(title: "Search", isChecked: isSearchVisible, action: { [weak self] in self?.toggleSearch() }),
            .separator,
        ]
        for f in ProjectPanelModel.MediaFilter.allCases {
            rows.append(SQMenuItem(title: f.title, isChecked: model.mediaFilter == f, action: { [weak model] in model?.mediaFilter = f }))
        }
        return rows + smartFolderRows(model)
    }

    /// The Mac `smartBinMenuItems`: Search Spoken Words, Save Filter as Smart Folder, one checked row per saved smart folder
    /// (a click shows its media, a second click returns to the folders), then a Delete row for each.
    func smartFolderRows(_ model: ProjectPanelModel) -> [SQMenuItem] {
        var rows: [SQMenuItem] = [.separator]
        rows.append(SQMenuItem(title: "Search Spoken Words", isChecked: model.searchSpoken, action: { [weak model] in model?.searchSpoken.toggle() }))
        rows.append(SQMenuItem(title: "Save Filter as Smart Folder", action: { [weak self] in self?.saveFilterAsSmartFolder() }))
        for sb in model.project.smartBinList {
            rows.append(SQMenuItem(title: sb.name, isChecked: model.activeSmartBin == sb.id, action: { [weak self, weak model] in
                guard let self, let model else { return }
                model.activeSmartBin = model.activeSmartBin == sb.id ? nil : sb.id
                if viewMode == .icons { model.browseBin = model.project.rootBin.id; model.currentBin = model.browseBin }
            }))
        }
        for sb in model.project.smartBinList {
            rows.append(SQMenuItem(title: "Delete Smart Folder \"\(sb.name)\"", action: { [weak model] in _ = model?.removeSmartBin(sb.id) }))
        }
        return rows
    }

    /// Saves the search text and the Unused / Offline choice as a smart folder named after them (the Mac
    /// `saveFilterAsSmartBin`: a taken name gets " 2", " 3" ...).
    func saveFilterAsSmartFolder() {
        guard let model else { return }
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? model.mediaFilter.title : q
        let taken = Set(model.project.smartBinList.map(\.name))
        var name = base, n = 2
        while taken.contains(name) { name = "\(base) \(n)"; n += 1 }
        _ = model.addSmartBin(model.currentFilterAsSmartBin(name: name))
    }

    /// The column frames of the list: Name takes what the other columns leave (at least its minimum); columns that do not
    /// fit any more drop from the right. Automatic widths follow `ProjectColumnSizing`: the widest text plus padding.
    /// shortcut: no horizontal scrolling or column drag/resize; add them with a pointer-hover pass for the header.
    public func columnFrames(_ refs: [BinItemRef]? = nil) -> [ColumnFrame] {
        let measure = host?.measure ?? TextMeasure(atlas: nil, scale: 1)
        let list = refs ?? rows().map(\.ref)
        var others = columns.visible.filter { $0 != .name }
        func width(_ c: ProjectPanelModel.Column) -> CGFloat {
            if let w = columns.userWidth(of: c) { return w }
            var content: CGFloat = 0
            if let model { for r in list.prefix(200) { content = max(content, measure.width(model.cellText(c, r), size: Self.listFont)) } }
            let header = measure.width(c.title, size: 11)
            let w = max(content + 2 * Self.cellPad, header + 2 * Self.cellPad + ProjectColumnSizing.headerExtra)
            return min(max(w, c.minWidth), c == .filePath ? 360 : 150)
        }
        var widths = others.map(width)
        let end = frame.maxX
        while !others.isEmpty, end - widths.reduce(0, +) - frame.minX < ProjectPanelModel.Column.name.minWidth {
            others.removeLast(); widths.removeLast()
        }
        var x = end - widths.reduce(0, +)
        var out = [ColumnFrame(column: .name, minX: frame.minX, maxX: x)]
        for (c, w) in zip(others, widths) { out.append(ColumnFrame(column: c, minX: x, maxX: x + w)); x += w }
        return out
    }

    // MARK: Chrome events

    /// A press on the header, the search row or the column header / path row. True when taken.
    func chromeClick(at p: CGPoint, modifiers m: InputModifiers) -> Bool {
        guard let model, p.y < listRect.minY else { return false }
        if optionsRect.insetBy(dx: -2, dy: -2).contains(p) {
            host?.menuBar.controller.present(items: optionsMenu(), at: CGPoint(x: optionsRect.minX, y: optionsRect.maxY))
            return true
        }
        if let r = sizeSliderRect, r.insetBy(dx: -4, dy: -4).contains(p) {
            sizeSliderDragging = true
            setThumbSize(atX: p.x)
            return true
        }
        if headerRect.contains(p) { return true }
        if searchRect.contains(p) {
            if !searchText.isEmpty, searchClearRect.contains(p) { setSearchText(""); return true }
            if searchFieldRect.contains(p) { search.mouseDown() }
            return true
        }
        guard subheaderRect.contains(p) else { return true }
        if viewMode == .icons { goUp(); return true }
        if m.contains(.secondary) { host?.menuBar.controller.present(items: columnMenu(), at: p); return true }
        // A click on a title sorts by it; again flips the order (the outline's sort descriptors).
        if let col = columnFrames().first(where: { p.x >= $0.minX && p.x < $0.maxX })?.column {
            model.setSort(col, ascending: model.sortColumn == col ? !model.sortAscending : true)
        }
        return true
    }

    // MARK: Chrome drawing

    func drawChrome(_ c: inout Canvas, theme: DrawTheme, model: ProjectPanelModel) {
        let header = headerRect
        if showsTitle {
            c.draw("Project", in: header.insetBy(dx: Self.nameLead, dy: 0), fontSize: CGFloat(DrawTheme.TypeSize.title), theme.label,
                   face: c.semibold)
        }
        let o = optionsRect
        let count = itemCountText
        let cw = c.size(of: count, fontSize: 11).width
        if let t = stripRects {
            c.draw(icon: .ellipsis, at: CGPoint(x: o.midX - 6, y: o.midY - 6), size: 12, theme.label3)
            c.draw(icon: .folderAdd, at: CGPoint(x: t.folder.midX - 6, y: t.folder.midY - 6), size: 12, theme.label2)
            c.draw(count, at: CGPoint(x: t.count - cw, y: o.midY - 7), fontSize: 11, theme.label3)
        } else {
            c.draw(icon: .ellipsis, at: CGPoint(x: o.minX + 3, y: o.minY + 3), size: o.width - 6, theme.label2)
            c.draw(count, at: CGPoint(x: o.minX - CGFloat(DrawTheme.Spacing.sm) - cw, y: header.midY - 7), fontSize: 11, theme.label3)
        }
        if let r = sizeSliderRect {
            let range = Self.thumbRange.upperBound - Self.thumbRange.lowerBound
            InspectorDraw.slider(&c, fraction: Double((thumbSize - Self.thumbRange.lowerBound) / range), in: r, enabled: true, theme)
        }
        if header.height > 0 { c.fill(CGRect(x: frame.minX, y: header.maxY - 1, width: frame.width, height: 1), theme.separator) }
        if isSearchVisible {
            let f = searchFieldRect
            search.fontSize = 11
            search.draw(&c, in: f, theme: theme, focused: search.isEditing)
            if searchText.isEmpty, !search.isEditing {
                c.draw("Search project", in: f, fontSize: 11, theme.label3, inset: 8)
            } else if !searchText.isEmpty {
                let x = searchClearRect
                c.draw(icon: .closeCircleFilled, at: CGPoint(x: x.minX + 1, y: x.minY + 1), size: x.width - 2, theme.label3)
            }
        }
        let sub = subheaderRect
        guard sub.height > 0 else { return }
        if viewMode == .list {
            for col in columnFrames() {
                // `PanelListHeaderCell`: 11 semibold label3, name at the 12 pt lead, others 8 pt in (right-aligned: from the right).
                let x0 = col.column == .name ? col.minX + Self.nameLead : col.minX
                let r = CGRect(x: x0, y: sub.minY, width: col.maxX - x0, height: sub.height)
                let right = Self.rightAligned(col.column)
                let w = c.draw(col.column.title, in: r, fontSize: 11, theme.label3, align: right ? .right : .left,
                               inset: col.column == .name ? 0 : Self.cellInset, face: c.semibold)
                if model.sortColumn == col.column {
                    let ax = right ? r.maxX - Self.cellInset - w - Self.cellPad - 8 : r.minX + (col.column == .name ? 0 : Self.cellInset) + w + Self.cellPad
                    c.draw(icon: model.sortAscending ? .chevronUp : .chevronDown, at: CGPoint(x: ax, y: sub.midY - 4),
                           size: 8, theme.label3)
                }
            }
        } else {
            c.draw(icon: .chevronLeft, at: CGPoint(x: sub.minX + Self.nameLead - 2, y: sub.midY - 6), size: 12, theme.label2)
            c.draw(crumbPath(model), in: sub.insetBy(dx: Self.nameLead + 14, dy: 0), fontSize: 11, theme.label2)
        }
        c.fill(CGRect(x: frame.minX, y: sub.maxY - 1, width: frame.width, height: 1), theme.separator)
    }

    /// "Project / Shots / Day 1": the folders from the top to the one the grid shows.
    func crumbPath(_ model: ProjectPanelModel) -> String {
        var names: [String] = []
        var id: Bin.ID? = model.browseBin
        while let b = id, b != model.project.rootBin.id {
            names.insert(model.displayName(of: .bin(b)), at: 0)
            id = model.project.rootBin.parent(of: .bin(b))
        }
        return (["Project"] + names).joined(separator: " / ")
    }
}
