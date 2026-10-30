import Foundation
import Observation
import SQCore
import SQUIKit
import SQDrawKit
import SQLibrary
import SQInspectorUI
import SQEditorSession

/// What the Library panel asks of its host (file choosers, dialogs, the timeline): the Mac panel's NSOpenPanel /
/// NSSavePanel / SQDialog / NSWorkspace calls and its `onApplyTextTemplate` / `onWhoosh` closures.
public enum LibraryRequest: Equatable, Sendable {
    case addFolder
    case reveal([URL])
    case whoosh(URL)
    case applyTextTemplate(String)
    case exportPreset(PresetItem)
    case importPresets
    case deletePreset(PresetItem)
    case exportPack(ids: [UUID], suggestedName: String)
    case importPack
}

/// The Library panel on the shared draw toolkit, translated from the Mac `LibraryPanelView` on the same
/// `LibraryPanelModel`: the sidebar tree (Library > Favorites + watched folders, Presets > kinds, Packs), the search
/// row with the view switch and the tile size slider, the kind chips, the grid (sections per subfolder, thumbnails from
/// the host's `picture`, template tiles in their own type) or the list (Name, Kind, Size, Date), selection with
/// Command / Shift, the item, preset, folder and pack menus (`LibraryMenus`), the "..." options (view, sort, preset
/// filters), the empty states, double-click to place or apply a preset, and drags out (files, templates, titles, effect
/// presets) that the host routes onto the timeline. Coordinates are panel-local points, y down.
/// shortcut: the preview player plays sound on the Mac only (off the Mac the portable player is silent), the panel draws
/// no video picture or transport, only a progress line under the playing item, and LUT tiles show their icon, not the look on the test picture; upgrade when
/// the draw toolkit has a live picture slot per panel.
@MainActor
public final class LibraryDrawPanel {
    public enum DragPhase: Sendable, Equatable { case moved, ended, canceled }

    /// One entry of the content in display order.
    public enum Cell: Equatable {
        case header(LibraryGroup)
        case item(LibraryItem)
        case preset(LibraryPresetCell)

        public var key: String {
            switch self {
            case .header(let g): "h:" + g.id
            case .item(let it): "i:" + it.entry.folderID.uuidString + "/" + it.entry.relativePath
            case .preset(let p): p.presetKey
            }
        }
        var isHeader: Bool { if case .header = self { true } else { false } }
    }

    public static let sidebarWidth: CGFloat = 136
    public static let searchRowHeight: CGFloat = 38
    public static let chipRowHeight: CGFloat = 24
    public static let rowHeight: CGFloat = 26
    public static let sectionHeight: CGFloat = 24
    static let pad = CGFloat(DrawTheme.Spacing.sm)
    static let dragSlop: CGFloat = 4
    static let doubleClick: Double = 0.4
    static let sliderWidth: CGFloat = 64
    /// `Theme.Typography.list`: sidebar rows and kind chips.
    static let listFont: CGFloat = 12
    /// Space between the search row and the first chip row.
    static let chipsInset: CGFloat = 8
    /// Space between the search row and the first sidebar row.
    static let sidebarInset = CGFloat(DrawTheme.Spacing.xs)

    public let model: LibraryPanelModel
    /// The panel has keyboard focus: the sidebar selection is accent, else the quiet gray of the AppKit sidebar.
    public var hasFocus = false
    static let unfocusedSelection = DrawColor(hex: 0x4F4F51)
    public let defaults: UserDefaults
    public var size: CGSize = .zero
    public var theme = DrawTheme()
    /// The item's thumbnail for a tile rect (the host's media atlas: poster frame of a video, the picture of an image),
    /// as an image slot and the normalized part of it that fills the rect; nil = the kind icon.
    public var picture: (@MainActor (LibraryItem, CGRect) -> (slot: Int, source: (Float, Float, Float, Float))?)?
    /// Dialogs, file choosers and timeline calls the host runs.
    public var onRequest: (@MainActor (LibraryRequest) -> Void)?
    /// A menu at a panel-local point.
    public var onMenu: (@MainActor ([SQMenuItem], CGPoint) -> Void)?
    /// A drag out of the panel; the point is panel-local (the host turns it into window pixels).
    public var onDrag: (@MainActor (LibraryDragPayload, DragPhase, CGPoint) -> Void)?
    /// "Whoosh at Selected Cuts" is offered (the host places sounds on cuts).
    public var canWhoosh = false
    public var now: () -> Double = { ProcessInfo.processInfo.systemUptime }

    public private(set) var cells: [Cell] = []
    public internal(set) var selected: Set<String> = []
    let scrollBody = ScrollBody()
    /// The scroll offset; the body adds momentum and the rubber band.
    public private(set) var scroll: CGFloat {
        get { scrollBody.position }
        set { scrollBody.position = newValue }
    }
    public private(set) var tileFraction: Double
    private var sidebar: [LibrarySidebarRow] = []
    private var templateTiles: [String: TextTemplateTile] = [:]
    private var anchor: Int?
    private var dirty = true
    private var press: (point: CGPoint, cell: Int?)?
    /// The rubber band of a drag that started on the grid's empty background (`LibraryDrawPanel+Marquee.swift`).
    var marquee: Marquee?
    public private(set) var isDragging = false
    private var dragPayload: LibraryDragPayload?
    private var lastClick: (key: String, time: Double)?
    private var draggingSlider = false
    private var hover: CGPoint?
    var search = TextFieldControl()

    public init(model: LibraryPanelModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        tileFraction = defaults.object(forKey: LibraryTileGeometry.tileSizeKey) == nil
            ? LibraryTileGeometry.defaultFraction : defaults.double(forKey: LibraryTileGeometry.tileSizeKey)
        search.alignment = .left
        search.fontSize = CGFloat(DrawTheme.TypeSize.body)
        search.text = model.query
    }

    // MARK: Model refresh (driven by observation)

    /// Rebuilds the cells when the model changed (cheap when nothing did); the host calls it before drawing.
    public func refresh() {
        guard dirty else { return }
        dirty = false
        withObservationTracking { rebuild() } onChange: { [weak self] in
            Task { @MainActor in self?.dirty = true }
        }
    }

    func rebuild() {
        sidebar = LibrarySidebarRow.rows(folders: model.folders, packNames: model.packNames)
        _ = (model.favorites, model.presetMeta, model.sortKey, model.ascending, model.presetSort, model.presetAscending)
        if model.isShowingPresets {
            let tpl = model.visibleTextTemplates.map { Cell.preset(.template($0)) }
            cells = tpl + model.visiblePresets.map { Cell.preset(.user($0)) }
            templateTiles = Dictionary(TextTemplateTile.tiles(presets: model.presets, builtIns: TextTemplateCatalog.all)
                .map { ($0.presetKey, $0) }, uniquingKeysWith: { a, _ in a })
        } else {
            let sections = model.sections
            if sections.isEmpty {
                cells = model.items.map { .item($0) }
            } else {
                // An item listed under All and under its subfolder is one cell key: selection marks both copies.
                cells = sections.flatMap { s in [Cell.header(s.group)] + s.items.map { Cell.item($0) } }
            }
        }
        let keys = Set(cells.map(\.key))
        selected.formIntersection(keys)
        scroll = min(scroll, maxScroll)
    }

    // MARK: Derived state

    public var contentCount: Int { cells.filter { !$0.isHeader }.count }
    var trimmedQuery: String { model.query.trimmingCharacters(in: .whitespaces) }
    /// A search without hits fills the panel (board "Library · no hits"): no sidebar, no chips.
    public var isNoHits: Bool { contentCount == 0 && !trimmedQuery.isEmpty }
    var showsSidebar: Bool { !isNoHits }
    var showsChips: Bool { !model.isShowingPresets && !isNoHits }
    /// Measured chip widths by title (filled while drawing; see `chipFrames`).
    var chipWidths: [String: CGFloat] = [:]

    public var emptyText: (title: String, hint: String) {
        var text = LibraryLabels.emptyText(offline: model.isSelectedFolderOffline, presetMode: model.isShowingPresets,
                                           favorites: model.selection == .favorites, hasFolders: !model.folders.isEmpty,
                                           query: model.query)
        if model.isShowingPresets, model.presetFilterActive, trimmedQuery.isEmpty {
            text = ("Nothing here", "No preset matches the current filter. Open the ... menu and choose Show: All.")
        }
        return text
    }

    /// v9 "No library folders": the button under the hint adds one.
    public var offersAddFolder: Bool {
        !model.isShowingPresets && !isNoHits && !model.isSelectedFolderOffline && model.folders.isEmpty && model.selection != .favorites
    }

    // MARK: Geometry

    var contentX: CGFloat { showsSidebar ? Self.sidebarWidth : 0 }
    /// The sidebar sits under the search row, which spans the whole panel (the AppKit panel: field, view switch, slider).
    var sidebarRect: CGRect {
        CGRect(x: 0, y: Self.searchRowHeight, width: showsSidebar ? Self.sidebarWidth : 0, height: max(size.height - Self.searchRowHeight, 0))
    }
    var sliderRect: CGRect? {
        guard model.viewMode == .grid else { return nil }
        return CGRect(x: size.width - Self.pad - Self.sliderWidth, y: 7, width: Self.sliderWidth, height: 24)
    }
    var viewButtonRect: CGRect {
        let right = sliderRect.map { $0.minX - Self.pad } ?? size.width - Self.pad
        return CGRect(x: right - 24 - (sliderRect == nil ? 0 : 5), y: 7, width: 24, height: 24)
    }
    var searchFieldRect: CGRect {
        // Measured against the AppKit panel (2x crop): the field starts 2 pt left of the pad and ends 11 pt before the view switch.
        CGRect(x: Self.pad - 2, y: 7, width: max(viewButtonRect.minX - 11 - (Self.pad - 2), 0), height: 24)
    }
    var searchClearRect: CGRect { CGRect(x: searchFieldRect.maxX - 20, y: searchFieldRect.midY - 8, width: 16, height: 16) }
    var chipsTop: CGFloat { Self.searchRowHeight }
    var listRect: CGRect {
        let top = Self.searchRowHeight + (showsChips ? Self.chipsInset - 3 + Self.chipRowHeight * CGFloat(chipRows) : 0)
        return CGRect(x: contentX, y: top, width: max(size.width - contentX, 0), height: max(size.height - top, 0))
    }

    /// Chip frames: All, then the filter kinds (`LibraryPanelModel.filterKinds`), wrapped onto as many rows as the
    /// panel width needs (the AppKit chip bar wraps the same way). Widths come from the last draw's measure
    /// (`chipWidths`), so layout and hit testing match the drawn chips.
    func chipFrames(_ c: Canvas? = nil) -> [(kind: LibraryItemKind?, title: String, frame: CGRect)] {
        let left = contentX + Self.pad, right = max(size.width - Self.pad, left)
        let gap = CGFloat(DrawTheme.Spacing.xs)
        var x = left, row = 0
        var out: [(LibraryItemKind?, String, CGRect)] = []
        let all: [LibraryItemKind?] = [nil] + LibraryPanelModel.filterKinds.map { Optional($0) }
        for k in all {
            let title = k.map(LibraryLabels.title(for:)) ?? "All"
            let estimate: CGFloat = CGFloat(title.count) * 6.5 + 12
            var w: CGFloat = chipWidths[title] ?? estimate
            if let c { w = c.size(of: title, fontSize: Self.listFont).width + 12 }
            if c != nil { chipWidths[title] = w }
            if x > left, x + w > right { row += 1; x = left }
            out.append((k, title, CGRect(x: x, y: chipsTop + Self.chipsInset + CGFloat(row) * Self.chipRowHeight, width: w, height: 20)))
            x += w + gap
        }
        return out
    }

    /// Rows the chips take at the current width.
    var chipRows: Int {
        guard let last = chipFrames().last else { return 1 }
        return Int(((last.frame.minY - chipsTop - Self.chipsInset) / Self.chipRowHeight).rounded()) + 1
    }

    struct Placed { var index: Int; var frame: CGRect }

    /// Cell frames in content coordinates (y from the list top, before scrolling).
    func placed() -> [Placed] {
        let w = listRect.width
        var out: [Placed] = []
        out.reserveCapacity(cells.count)
        if model.viewMode == .list {
            for i in cells.indices {
                out.append(Placed(index: i, frame: CGRect(x: 0, y: CGFloat(i) * Self.rowHeight, width: w, height: Self.rowHeight)))
            }
            return out
        }
        let inner = max(w - 2 * Self.pad, 1)
        let g = LibraryTileGeometry.layout(width: inner, fraction: tileFraction)
        var y = Self.pad, col = 0
        for (i, cell) in cells.enumerated() {
            if cell.isHeader {
                if col > 0 { y += g.tile.height + LibraryTileGeometry.gap; col = 0 }
                out.append(Placed(index: i, frame: CGRect(x: 0, y: y, width: w, height: Self.sectionHeight)))
                y += Self.sectionHeight + CGFloat(DrawTheme.Spacing.xs)
                continue
            }
            let x = Self.pad + CGFloat(col) * (g.tile.width + LibraryTileGeometry.gap)
            out.append(Placed(index: i, frame: CGRect(x: x, y: y, width: g.tile.width, height: g.tile.height)))
            col += 1
            if col == g.columns { col = 0; y += g.tile.height + LibraryTileGeometry.gap }
        }
        return out
    }

    var contentHeight: CGFloat {
        guard let last = placed().max(by: { $0.frame.maxY < $1.frame.maxY }) else { return 0 }
        return last.frame.maxY + Self.pad
    }
    var maxScroll: CGFloat { max(contentHeight - listRect.height, 0) }

    /// The cell index under a panel-local point.
    public func cellIndex(at p: CGPoint) -> Int? {
        guard listRect.contains(p) else { return nil }
        let q = CGPoint(x: p.x - listRect.minX, y: p.y - listRect.minY + scroll)
        return placed().first { $0.frame.contains(q) }?.index
    }

    func cellRect(_ placed: Placed) -> CGRect {
        placed.frame.offsetBy(dx: listRect.minX, dy: listRect.minY - scroll)
    }

    func sidebarIndex(at p: CGPoint) -> Int? {
        guard sidebarRect.contains(p) else { return nil }
        let i = Int(((p.y - sidebarRect.minY - Self.sidebarInset) / Self.rowHeight).rounded(.down))
        return sidebar.indices.contains(i) ? i : nil
    }

    func sidebarRowRect(_ i: Int) -> CGRect {
        CGRect(x: 0, y: sidebarRect.minY + Self.sidebarInset + CGFloat(i) * Self.rowHeight, width: Self.sidebarWidth, height: Self.rowHeight)
    }

    var addFolderButtonRect: CGRect {
        let r = listRect
        return CGRect(x: r.midX - 56, y: r.midY + 26, width: 112, height: 24)
    }

    // MARK: Selection helpers

    func selectableIndices() -> [Int] { cells.indices.filter { !cells[$0].isHeader } }

    /// The selected file items, each once.
    public var selectedItems: [LibraryItem] {
        var seen = Set<LibraryEntryID>()
        return cells.compactMap { c in
            guard case .item(let it) = c, selected.contains(c.key), seen.insert(it.id).inserted else { return nil }
            return it
        }
    }

    /// The selected saved presets in display order.
    public var selectedPresets: [PresetItem] {
        cells.compactMap { c in
            guard case .preset(.user(let p)) = c, selected.contains(c.key) else { return nil }
            return p
        }
    }

    func select(_ i: Int, modifiers m: InputModifiers) {
        let key = cells[i].key
        if m.contains(.shift), let a = anchor, cells.indices.contains(a) {
            let range = min(a, i)...max(a, i)
            selected = Set(range.filter { !cells[$0].isHeader }.map { cells[$0].key })
        } else if m.contains(.command) {
            if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
            anchor = i
        } else {
            selected = [key]
            anchor = i
        }
        previewSelection()
    }

    /// Selecting one item previews it (audio and video play at once); several selected items keep the current preview.
    func previewSelection() {
        guard !model.isShowingPresets else { return }
        let items = selectedItems
        if items.count == 1 { model.selectItemForPreview(items[0]) } else if items.isEmpty { model.selectItemForPreview(nil) }
    }

    func choose(_ section: LibrarySection) {
        guard model.selection != section else { return }
        model.selection = section
        selected = []
        anchor = nil
        scroll = 0
        model.selectItemForPreview(nil)
        dirty = true
    }

    // MARK: Actions

    /// Double-click on a preset row or tile: place the template, insert the title block, apply the effect preset.
    public func activate(_ cell: LibraryPresetCell) {
        switch cell {
        case .template(let t):
            model.recordPresetUse(PresetKey.builtIn(t.id))
            onRequest?(.applyTextTemplate(t.id))
        case .user(let p):
            if p.kind.isTitleInsert { model.recordPresetUse(PresetKey.user(p.id)); model.onInsertTitleBlock?(p, nil) }
            else if p.kind == .effect { model.recordPresetUse(PresetKey.user(p.id)); model.onApplyPreset?(p, nil) }
        }
    }

    public func setViewMode(_ mode: LibraryViewMode) {
        model.viewMode = mode
        scroll = 0
    }

    public func setTileFraction(_ f: Double) {
        tileFraction = min(max(f, 0), 1)
        defaults.set(tileFraction, forKey: LibraryTileGeometry.tileSizeKey)
        scroll = min(scroll, maxScroll)
    }

    func sort(by key: LibrarySortKey) {
        if model.sortKey == key { model.ascending.toggle() } else { model.sortKey = key; model.ascending = true }
    }

    // MARK: Menus

    /// Header "..." of the Library panel: as Grid / as List, Add Folder…, then Sort by Name / Date / Size (the current
    /// key flips the direction) or, for presets, sort, Show (scope), Category, Tag and Clear Filters.
    public func optionsMenu() -> [SQMenuItem] {
        var rows: [SQMenuItem] = [
            SQMenuItem(title: "as Grid", isChecked: model.viewMode == .grid) { [weak self] in self?.setViewMode(.grid) },
            SQMenuItem(title: "as List", isChecked: model.viewMode == .list) { [weak self] in self?.setViewMode(.list) },
            .separator,
            SQMenuItem(title: "Add Folder\u{2026}") { [weak self] in self?.onRequest?(.addFolder) },
            .separator,
        ]
        guard model.isShowingPresets else {
            for (key, title) in [(LibrarySortKey.name, "Name"), (.date, "Date"), (.size, "Size")] {
                rows.append(SQMenuItem(title: "Sort by \(title)", isChecked: model.sortKey == key) { [weak self] in self?.sort(by: key) })
            }
            return rows
        }
        let model = model
        for key in PresetSortKey.allCases {
            rows.append(SQMenuItem(title: "Sort by \(key.title)", isChecked: model.presetSort == key) { model.sortPresets(by: key) })
        }
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Show", submenu: PresetScope.allCases.map { scope in
            SQMenuItem(title: scope.title, isChecked: model.presetScope == scope) { model.presetScope = scope }
        }))
        let counts = model.presetCategoryCounts
        var cats = [SQMenuItem(title: "All Categories", isChecked: model.presetCategory == nil) { model.presetCategory = nil }]
        cats += PresetCategory.allCases.map { cat in
            SQMenuItem(title: "\(cat.title) (\(counts[cat] ?? 0))", isEnabled: (counts[cat] ?? 0) > 0 || model.presetCategory == cat,
                       isChecked: model.presetCategory == cat) { model.presetCategory = cat }
        }
        rows.append(SQMenuItem(title: "Category", submenu: cats))
        let tags = model.presetTagCounts
        if !tags.isEmpty {
            var items = [SQMenuItem(title: "All Tags", isChecked: model.presetTag == nil) { model.presetTag = nil }]
            items += tags.map { t in SQMenuItem(title: "\(t.tag) (\(t.count))", isChecked: model.presetTag == t.tag) { model.presetTag = t.tag } }
            rows.append(SQMenuItem(title: "Tag", submenu: items))
        }
        if model.presetFilterActive {
            rows.append(.separator)
            rows.append(SQMenuItem(title: "Clear Filters") { model.clearPresetFilters() })
        }
        return rows
    }

    /// The sidebar row menu: Add Folder…, then Rescan / Remove Folder on a watched folder, Export / Import Pack on a pack.
    public func sidebarMenu(_ row: LibrarySidebarRow?) -> [SQMenuItem] {
        if case .pack(let name)? = row?.section {
            return LibraryMenus.packItems { [weak self] a in
                guard let self else { return }
                switch a {
                case .exportPack: self.onRequest?(.exportPack(ids: self.model.presetIDs(inPack: name), suggestedName: name))
                case .importPack: self.onRequest?(.importPack)
                default: break
                }
            }
        }
        let add = SQMenuItem(title: "Add Folder\u{2026}") { [weak self] in self?.onRequest?(.addFolder) }
        guard case .folder(let id)? = row?.section else { return [add] }
        let model = model
        return [add, .separator] + LibraryMenus.folderItems { a in
            switch a {
            case .rescan: Task { await model.rescan(id) }
            case .removeFolder: Task { await model.removeFolder(id) }
            default: break
            }
        }
    }

    /// The menu of a cell (nil = empty space): file items or the presets section's rows (`LibraryMenus.itemItems`).
    /// Rows capture what was clicked: the actions run after the menu closed.
    public func itemMenu(at index: Int?) -> [SQMenuItem] {
        let cell = index.map { cells[$0] }
        let p: PresetItem? = if case .preset(.user(let u))? = cell { u } else { nil }
        let template: TextTemplateCatalog.Entry? = if case .preset(.template(let t))? = cell { t } else { nil }
        let entry = p.map(model.entry(for:)) ?? template.map(model.entry(for:))
        let items = selectedItems
        let audio = items.first { $0.entry.kind == .audio }
        let ctx = LibraryMenus.Context(
            showsPresets: model.isShowingPresets, hasAudio: audio != nil, canWhoosh: canWhoosh,
            presetIsTitleBlock: p?.kind.isTitleInsert == true, presetIsEffect: p?.kind == .effect, hasPreset: p != nil,
            relativeDefault: PresetApplyModeSetting.load() == .relative,
            organize: entry.map { e in
                let def = p.map { PresetCategory.defaultCategory(for: $0.kind) }
                    ?? template.map { $0.isCTA ? .social : PresetCategory.inferred(fromName: $0.name) } ?? .other
                return LibraryMenus.Organize(isFavorite: e.meta.isFavorite, category: e.category, defaultCategory: def, tags: e.tags)
            })
        // Presets in the selection when the click is inside it, else the clicked one.
        let selectedPresets = cell.map { selected.contains($0.key) } == true ? self.selectedPresets : (p.map { [$0] } ?? [])
        let key = entry?.key
        return LibraryMenus.itemItems(ctx) { [weak self] a in
            self?.run(a, items: items, audio: audio, preset: p, selectedPresets: selectedPresets, key: key)
        }
    }

    func run(_ a: LibraryMenus.Action, items: [LibraryItem], audio: LibraryItem?, preset p: PresetItem?,
             selectedPresets: [PresetItem], key: String?) {
        switch a {
        case .rescan, .removeFolder: break
        case .toggleFavorite: for item in items { model.toggleFavorite(item.id) }
        case .whoosh:
            guard let item = audio else { return }
            if model.sfxSounds.contains(item.url) { model.chooseWhoosh(item.url) }   // the Sequence menu command reuses it
            onRequest?(.whoosh(item.url))
        case .addToSFX:
            let urls = items.filter { $0.entry.kind == .audio }.map(\.url)
            Task { [model] in
                await model.addToSFXBin(urls)
                if let f = model.sfxFolder { model.selection = .folder(f.id) }
            }
        case .reveal: onRequest?(.reveal(items.map(\.url)))
        case .insertTitleBlock: if let p, p.kind.isTitleInsert { model.recordPresetUse(PresetKey.user(p.id)); model.onInsertTitleBlock?(p, nil) }
        case .applyPreset: if let p { model.recordPresetUse(PresetKey.user(p.id)); model.onApplyPreset?(p, nil) }
        case .applyAbsolute: if let p { model.recordPresetUse(PresetKey.user(p.id)); model.onApplyPreset?(p, .absolute) }
        case .applyRelative: if let p { model.recordPresetUse(PresetKey.user(p.id)); model.onApplyPreset?(p, .relative) }
        case .toggleFavoritePreset: if let key { model.toggleFavoritePreset(key) }
        case .setCategory(let c): if let key { model.setPresetCategory(key, c) }
        case .toggleTag(let t): if let key { model.togglePresetTag(key, t) }
        case .toggleDefaultApply:
            PresetApplyModeSetting.save(PresetApplyModeSetting.load() == .relative ? .absolute : .relative)
        case .exportPack:
            let name = Set(selectedPresets.compactMap(\.pack)).count == 1 ? (selectedPresets.first?.pack ?? "") : ""
            onRequest?(.exportPack(ids: selectedPresets.map(\.id), suggestedName: name))
        case .importPack: onRequest?(.importPack)
        case .exportPreset: if let p { onRequest?(.exportPreset(p)) }
        case .importPresets: onRequest?(.importPresets)
        case .deletePreset: if let p { onRequest?(.deletePreset(p)) }
        }
    }

    // MARK: Events (panel-local points)

    public func mouseDown(at p: CGPoint, modifiers m: InputModifiers) {
        refresh()
        press = nil
        if let i = sidebarIndex(at: p) {
            endSearchEditing()
            let row = sidebar[i]
            if let s = row.section { choose(s) }
            if m.contains(.secondary) { onMenu?(sidebarMenu(row), p) }
            return
        }
        if sidebarRect.contains(p) {
            if m.contains(.secondary) { onMenu?(sidebarMenu(nil), p) }
            return
        }
        if p.y < Self.searchRowHeight {
            if viewButtonRect.contains(p) { endSearchEditing(); setViewMode(model.viewMode == .grid ? .list : .grid); return }
            if let s = sliderRect, s.insetBy(dx: -4, dy: 0).contains(p) {
                endSearchEditing(); draggingSlider = true; setSlider(x: p.x); return
            }
            if !searchText.isEmpty, searchClearRect.contains(p) { setSearchText(""); return }
            if searchFieldRect.contains(p) { search.mouseDown() }
            return
        }
        endSearchEditing()
        if showsChips, p.y < listRect.minY {
            for chip in chipFrames() where chip.frame.contains(p) {
                if let k = chip.kind { model.toggleKind(k) } else { model.clearKindFilter() }
                return
            }
            return
        }
        if contentCount == 0, offersAddFolder, addFolderButtonRect.contains(p) { onRequest?(.addFolder); return }
        guard let i = cellIndex(at: p) else {
            if !m.contains(.command) && !m.contains(.shift) { selected = []; previewSelection() }
            beginMarquee(at: p, modifiers: m)
            if m.contains(.secondary) { onMenu?(model.isShowingPresets ? itemMenu(at: nil) : sidebarMenu(nil), p) }
            return
        }
        let cell = cells[i]
        if case .header(let g) = cell {
            if m.contains(.secondary) { return }
            model.toggleGroup(g.id)
            dirty = true
            return
        }
        if m.contains(.secondary) {
            if !selected.contains(cell.key) { select(i, modifiers: []) }
            onMenu?(itemMenu(at: i), p)
            return
        }
        let wasSelected = selected.contains(cell.key)
        if !(wasSelected && m.isEmpty) { select(i, modifiers: m) }
        press = (p, i)
        let t = now()
        defer { lastClick = (cell.key, t) }
        if let last = lastClick, last.key == cell.key, t - last.time < Self.doubleClick, m.isEmpty {
            lastClick = nil
            press = nil
            if case .preset(let pc) = cell { activate(pc) }
        }
    }

    public func mouseDragged(to p: CGPoint) {
        if draggingSlider { setSlider(x: p.x); return }
        if marquee != nil { dragMarquee(to: p); return }
        guard let start = press, let i = start.cell else { return }
        if !isDragging {
            guard hypot(p.x - start.point.x, p.y - start.point.y) >= Self.dragSlop else { return }
            lastClick = nil
            dragPayload = payload(for: i)
            guard dragPayload != nil else { press = nil; return }
            isDragging = true
        }
        if let d = dragPayload { onDrag?(d, .moved, p) }
    }

    public func mouseUp(at p: CGPoint) {
        defer { press = nil; isDragging = false; dragPayload = nil; draggingSlider = false; marquee = nil }
        if draggingSlider || marquee != nil { return }
        guard let start = press, let i = start.cell else { return }
        guard isDragging, let d = dragPayload else {
            // A plain click inside a multiple selection narrows it to the clicked cell.
            if cells.indices.contains(i), selected.count > 1 { select(i, modifiers: []) }
            return
        }
        if CGRect(origin: .zero, size: size).contains(p) { onDrag?(d, .canceled, p); return }
        if case .preset(let pc) = cells[i] { model.recordPresetUse(pc.presetKey) }
        onDrag?(d, .ended, p)
    }

    /// What dragging cell `i` carries: the selected files (the Mac `dragURLs`), or the template / title / effect preset.
    func payload(for i: Int) -> LibraryDragPayload? {
        switch cells[i] {
        case .header: return nil
        case .item(let it):
            let ids = selected.contains(cells[i].key) ? selectedItems.map(\.id) : [it.id]
            let urls = model.dragURLs(for: ids)
            return urls.isEmpty ? nil : .files(urls)
        case .preset(let pc): return pc.dragPayload
        }
    }

    public func mouseMoved(to p: CGPoint?) { hover = p }

    func setSlider(x: CGFloat) {
        guard let r = sliderRect else { return }
        setTileFraction(Double((x - r.minX - 5) / max(r.width - 10, 1)))
    }

    public func scroll(at p: CGPoint, dy: CGFloat) -> Bool {
        guard listRect.contains(p) else { return false }
        scrollBody.feed(dy: dy, maxOffset: maxScroll, extent: listRect.height)
        return true
    }

    /// Keys while the panel has focus: typing in the search field, arrows move the selection, Return places or applies
    /// the selected preset, Space plays or pauses the preview, Escape cancels a drag.
    public func key(_ k: InputKey, modifiers m: InputModifiers) -> Bool {
        if k == .escape, isDragging, let d = dragPayload {
            onDrag?(d, .canceled, .zero)
            press = nil; isDragging = false; dragPayload = nil
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
        switch k {
        case .up, .left: moveSelection(-1); return true
        case .down, .right: moveSelection(1); return true
        case .enter:
            guard let i = cells.firstIndex(where: { selected.contains($0.key) }), case .preset(let pc) = cells[i] else { return false }
            activate(pc)
            return true
        case .space:
            guard !model.isShowingPresets, model.previewItem != nil else { return false }
            model.preview.togglePlayPause()
            return true
        default: return false
        }
    }

    func moveSelection(_ d: Int) {
        let order = selectableIndices()
        guard !order.isEmpty else { return }
        let cur = cells.indices.first { selected.contains(cells[$0].key) }.flatMap { order.firstIndex(of: $0) }
        let next = cur.map { min(max($0 + d, 0), order.count - 1) } ?? (d > 0 ? 0 : order.count - 1)
        let i = order[next]
        select(i, modifiers: [])
        guard let pl = placed().first(where: { $0.index == i }) else { return }
        let r = cellRect(pl)
        if r.minY < listRect.minY { scroll -= listRect.minY - r.minY }
        if r.maxY > listRect.maxY { scroll += r.maxY - listRect.maxY }
        scroll = min(max(scroll, 0), maxScroll)
    }

    public var searchText: String { search.editor?.string ?? search.text }
    public var isEditingSearch: Bool { search.isEditing }

    func setQuery(_ q: String) {
        guard model.query != q else { return }
        model.query = q
        scroll = 0
        dirty = true
    }

    func setSearchText(_ s: String) {
        search.cancel()
        search.text = s
        setQuery(s)
    }

    func endSearchEditing() { if search.isEditing { _ = search.commit(); search.text = searchText } }

    /// Focus goes to the search field (Cmd+F in the panel).
    public func focusSearch() { search.mouseDown() }

    /// The tooltip under the pointer: a sidebar folder's path, a cell's full name.
    public func help(at p: CGPoint) -> String? {
        if let i = sidebarIndex(at: p) {
            if case .folder(let id)? = sidebar[i].section { return model.folder(id)?.url.path }
            return nil
        }
        if viewButtonRect.contains(p) { return model.viewMode == .grid ? "Show as List" : "Show as Grid" }
        if let s = sliderRect, s.contains(p) { return "Tile Size" }
        guard let i = cellIndex(at: p) else { return nil }
        switch cells[i] {
        case .header: return nil
        case .item(let it): return it.entry.relativePath
        case .preset(let pc): return pc.name
        }
    }

    // MARK: Drawing

    public func draw(_ c: inout Canvas) {
        refresh()
        let t = theme
        c.fill(CGRect(origin: .zero, size: size), t.panel)
        if showsSidebar { drawSidebar(&c) }
        if showsChips { _ = chipFrames(c) }  // measure first: `listRect` follows the chip rows
        drawSearchRow(&c)
        if showsChips { drawChips(&c) }
        c.saveGState()
        c.clip(to: listRect)
        if contentCount == 0 { drawEmpty(&c) } else if model.viewMode == .list { drawList(&c) } else { drawGrid(&c) }
        drawMarquee(&c)
        c.restoreGState()
    }

    private func drawSidebar(_ c: inout Canvas) {
        let t = theme
        c.fill(CGRect(x: Self.sidebarWidth - 1, y: Self.searchRowHeight, width: 1, height: max(size.height - Self.searchRowHeight, 0)), t.separator)
        c.saveGState()
        c.clip(to: sidebarRect)
        for (i, row) in sidebar.enumerated() {
            let r = sidebarRowRect(i)
            guard r.minY < size.height else { break }
            let isSel = row.section != nil && row.section == model.selection
            if isSel {
                c.fill(roundedRect: r.insetBy(dx: CGFloat(DrawTheme.Spacing.xs), dy: 1), radius: CGFloat(DrawTheme.Radius.small), hasFocus ? t.accentFill : Self.unfocusedSelection)
            }
            // The AppKit sidebar: a folder icon on the group rows only; the items are plain text.
            let ink = row.isOffline ? t.label3 : (isSel ? t.label : t.label2)
            let textX: CGFloat = row.isGroup ? 32 : 26
            if row.isGroup { c.draw(icon: .folder, at: CGPoint(x: 14, y: r.midY - 6), size: 12, t.label3) }
            c.draw(row.title, in: CGRect(x: textX, y: r.minY, width: max(r.maxX - textX - 4, 0), height: r.height),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), row.isGroup ? t.label2 : ink)
        }
        c.restoreGState()
    }

    private func drawSearchRow(_ c: inout Canvas) {
        let t = theme
        let f = searchFieldRect
        // `SQSearchField`: the magnifier at 9, the text from 28 (measured in the AppKit render, as the Marker List field).
        search.textInset = 28
        search.quiet = true
        search.draw(&c, in: f, theme: t, focused: search.isEditing)
        c.draw(icon: .search, at: CGPoint(x: f.minX + 9, y: f.midY - 6), size: 12, t.label3)
        if searchText.isEmpty, !search.isEditing {
            c.draw("Search library", in: f, fontSize: CGFloat(DrawTheme.TypeSize.body), t.label3, inset: 28)
        } else if !searchText.isEmpty {
            let x = searchClearRect
            c.draw(icon: .closeCircleFilled, at: CGPoint(x: x.minX + 1, y: x.minY + 1), size: x.width - 2, t.label3)
        }
        if let s = sliderRect {
            let track = CGRect(x: s.minX, y: s.midY - 1, width: s.width, height: 2)
            c.fill(roundedRect: track, radius: 1, t.fill)
            let kx = track.minX + 5 + CGFloat(tileFraction) * (track.width - 10)   // the knob travels 5 pt in from the ends
            c.fill(roundedRect: CGRect(x: track.minX, y: track.minY, width: max(kx - track.minX, 0), height: 2), radius: 1, t.accent)
            c.fill(roundedRect: CGRect(x: kx - 5, y: s.midY - 5, width: 10, height: 10), radius: 5, .white)
        }
        let v = viewButtonRect
        let hot = hover.map { v.contains($0) } == true
        if hot { c.fill(roundedRect: v, radius: CGFloat(DrawTheme.Radius.small), t.fill) }
        c.draw(icon: model.viewMode == .grid ? .grid : .list, at: CGPoint(x: v.midX - 6, y: v.midY - 6), size: 12, t.label2)
    }

    private func drawChips(_ c: inout Canvas) {
        let t = theme
        for chip in chipFrames(c) {
            let on = chip.kind.map { model.kindFilter.contains($0) } ?? model.kindFilter.isEmpty
            c.fill(roundedRect: chip.frame, radius: chip.frame.height / 2, on ? t.fillPressed : t.fill)
            c.draw(chip.title, in: chip.frame, fontSize: Self.listFont, on ? t.label : t.label2, align: .center)
        }
    }

    private func drawEmpty(_ c: inout Canvas) {
        let t = theme
        let text = emptyText
        // The AppKit empty state is centered in the pane under the search row (chips included), 20 pt in from the edges.
        let pane = CGRect(x: contentX, y: Self.searchRowHeight, width: max(size.width - contentX, 0), height: max(size.height - Self.searchRowHeight, 0))
        let r = pane.insetBy(dx: 20, dy: 0)
        let lines = c.wrap(text.hint, width: r.width, fontSize: Self.listFont).prefix(3)
        let block = 20 + 6 + CGFloat(lines.count) * 14
        let top = pane.midY - block / 2
        c.draw(text.title, in: CGRect(x: r.minX, y: top, width: r.width, height: 20),
               fontSize: 15, t.label2, align: .center, face: c.semibold)
        for (i, line) in lines.enumerated() {
            c.draw(line, in: CGRect(x: r.minX, y: top + 26 + CGFloat(i) * 14, width: r.width, height: 14),
                   fontSize: Self.listFont, t.label3, align: .center)
        }
        if offersAddFolder {
            let b = addFolderButtonRect
            c.fill(roundedRect: b, radius: CGFloat(DrawTheme.Radius.small), t.fill)
            c.draw("Add Folder\u{2026}", in: b, fontSize: CGFloat(DrawTheme.TypeSize.body), t.label, align: .center)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// The list's text columns of a cell: Kind, Size, Date (items) or Kind, Date (presets).
    func columns(_ cell: Cell) -> [String] {
        switch cell {
        case .header: return []
        case .item(let it):
            return [LibraryLabels.title(for: it.entry.kind), SQByteSize.string(it.entry.size), Self.dateFormatter.string(from: it.entry.modified)]
        case .preset(.template(let tpl)):
            return [model.entry(for: tpl).category.title, "Built-in"]
        case .preset(.user(let p)):
            return [model.entry(for: p).category.title, Self.dateFormatter.string(from: p.createdAt)]
        }
    }

    private func drawList(_ c: inout Canvas) {
        let t = theme
        let colWidths: [CGFloat] = model.isShowingPresets ? [84, 92] : [64, 64, 92]
        let showColumns = listRect.width > 300
        for pl in placed() {
            let rr = cellRect(pl)
            guard rr.maxY >= listRect.minY, rr.minY <= listRect.maxY else { continue }
            let cell = cells[pl.index]
            if case .header(let g) = cell { drawSectionHeader(&c, g, in: rr); continue }
            let pill = rr.insetBy(dx: CGFloat(DrawTheme.Spacing.xs), dy: 1)
            if selected.contains(cell.key) { c.fill(roundedRect: pill, radius: CGFloat(DrawTheme.Radius.small), t.accentFill) }
            let x = rr.minX + Self.pad + 4
            let (symbol, name, fav) = label(cell)
            c.draw(icon: symbol, at: CGPoint(x: x, y: rr.midY - 6), size: 12, t.label3)
            var right = rr.maxX - Self.pad
            if showColumns {
                let texts = columns(cell)
                for (w, s) in zip(colWidths, texts).reversed() {
                    c.draw(s, in: CGRect(x: right - w, y: rr.minY, width: w, height: rr.height), fontSize: 10, t.label3)
                    right -= w
                }
            }
            if fav {
                c.draw(icon: .star, at: CGPoint(x: right - 14, y: rr.midY - 5), size: 10, t.accent)
                right -= 16
            }
            c.draw(name, in: CGRect(x: x + 18, y: rr.minY, width: max(right - x - 22, 0), height: rr.height),
                   fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2)
            drawProgress(&c, cell, under: CGRect(x: pill.minX, y: pill.maxY - 2, width: pill.width, height: 2))
        }
    }

    private func label(_ cell: Cell) -> (SQIcon, String, Bool) {
        switch cell {
        case .header(let g): return (.folder, g.title, false)
        case .item(let it): return (LibraryLabels.symbol(for: it.entry.kind), it.entry.name, it.isFavorite)
        case .preset(let pc):
            let fav: Bool = switch pc {
            case .template(let tpl): model.entry(for: tpl).meta.isFavorite
            case .user(let p): model.entry(for: p).meta.isFavorite
            }
            return (pc.symbol, pc.name, fav)
        }
    }

    private func drawSectionHeader(_ c: inout Canvas, _ g: LibraryGroup, in rr: CGRect) {
        let t = theme
        let x = rr.minX + Self.pad + CGFloat(min(g.depth, 3)) * 14
        let mid = CGPoint(x: x + 5, y: rr.midY)
        let pts = g.isCollapsed
            ? [CGPoint(x: mid.x - 1.5, y: mid.y - 3), CGPoint(x: mid.x + 1.5, y: mid.y), CGPoint(x: mid.x - 1.5, y: mid.y + 3)]
            : [CGPoint(x: mid.x - 3, y: mid.y - 1.5), CGPoint(x: mid.x, y: mid.y + 1.5), CGPoint(x: mid.x + 3, y: mid.y - 1.5)]
        c.strokePolyline(pts, width: 1.2, t.label2)
        let count = "\(g.totalCount)"
        let cw = c.size(of: count, fontSize: 10).width
        c.draw(g.title, in: CGRect(x: x + 14, y: rr.minY, width: max(rr.maxX - x - 22 - cw - Self.pad, 0), height: rr.height),
               fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2)
        c.draw(count, at: CGPoint(x: rr.maxX - Self.pad - cw, y: rr.midY - 6), fontSize: 10, t.label3)
    }

    /// The preview's position under the playing item (shortcut: no transport drawn).
    private func drawProgress(_ c: inout Canvas, _ cell: Cell, under r: CGRect) {
        guard case .item(let it) = cell, model.previewItem?.id == it.id, model.preview.duration > 0 else { return }
        c.fill(r, theme.fill)
        c.fill(CGRect(x: r.minX, y: r.minY, width: r.width * CGFloat(model.preview.fraction), height: r.height), theme.accent)
    }

    private func drawGrid(_ c: inout Canvas) {
        let t = theme
        let radius = CGFloat(DrawTheme.Radius.control)
        for pl in placed() {
            let f = cellRect(pl)
            guard f.maxY >= listRect.minY, f.minY <= listRect.maxY else { continue }
            let cell = cells[pl.index]
            if case .header(let g) = cell { drawSectionHeader(&c, g, in: f); continue }
            let thumb = CGRect(x: f.minX, y: f.minY, width: f.width, height: (f.width * LibraryTileGeometry.aspect).rounded())
            c.fill(roundedRect: thumb, radius: radius, t.content)
            let (symbol, name, fav) = label(cell)
            var drewPicture = false
            if case .item(let it) = cell, let poster = picture?(it, thumb) {
                c.saveGState()
                c.clip(to: thumb)
                c.draw(imageSlot: poster.slot, in: thumb, source: poster.source)
                c.restoreGState()
                drewPicture = true
            } else if case .preset(let pc) = cell, let tile = templateTiles[pc.presetKey] {
                drawTemplateSample(&c, tile, in: thumb)
                drewPicture = true
            }
            if !drewPicture {
                let s: CGFloat = 22
                c.draw(icon: symbol, at: CGPoint(x: thumb.midX - s / 2, y: thumb.midY - s / 2), size: s, t.label3)
            }
            if fav { c.draw(icon: .star, at: CGPoint(x: thumb.maxX - 16, y: thumb.minY + 4), size: 12, t.accent) }
            if selected.contains(cell.key) {
                c.stroke(roundedRect: thumb.insetBy(dx: 1, dy: 1), radius: radius, width: 2, t.accent)
            }
            drawProgress(&c, cell, under: CGRect(x: thumb.minX + 4, y: thumb.maxY - 5, width: thumb.width - 8, height: 2))
            c.draw(name, in: CGRect(x: f.minX, y: thumb.maxY + LibraryTileGeometry.nameGap, width: f.width,
                                    height: LibraryTileGeometry.nameHeight), fontSize: CGFloat(DrawTheme.TypeSize.body), t.label2)
        }
    }

    /// A template tile's sample in its own font and color (`TextTemplatesTabDraw.drawTile`).
    private func drawTemplateSample(_ c: inout Canvas, _ tile: TextTemplateTile, in well: CGRect) {
        let t = theme
        let text = tile.sampleText.count <= 12 && !tile.sampleText.contains("\n") && !tile.sampleText.isEmpty ? tile.sampleText : "Text"
        c.saveGState()
        c.clip(to: well)
        if let st = tile.style {
            let face = c.face(family: st.fontName, weight: st.weight, italic: st.italic)
            let col = st.color, ink = col.alpha > 0.05
                ? DrawColor(Float(col.red), Float(col.green), Float(col.blue), Float(col.alpha)) : t.label2
            c.draw(text, in: well.insetBy(dx: 4, dy: 0), fontSize: CGFloat(DrawTheme.TypeSize.title), ink, align: .center, face: face)
        } else {
            c.draw(text, in: well.insetBy(dx: 4, dy: 0), fontSize: CGFloat(DrawTheme.TypeSize.title), t.label2, align: .center)
        }
        c.restoreGState()
    }
}
