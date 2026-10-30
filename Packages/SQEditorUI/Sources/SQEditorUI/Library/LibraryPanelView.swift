import SQUIKit
import AppKit
import SQLibrary
import SQText
import UniformTypeIdentifiers

/// Re-runs `apply` whenever an @Observable property read inside it changes.
@MainActor
private func trackObservation(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking(apply) {
        Task { @MainActor in trackObservation(apply) }
    }
}

// Labels and icons are shared with the draw Library panel (SQDrawLibrary `LibraryLabels`).
private func symbolName(for kind: LibraryItemKind) -> SQIcon { LibraryLabels.symbol(for: kind) }
private func title(for kind: LibraryItemKind) -> String { LibraryLabels.title(for: kind) }
private func sidebarSymbol(for kind: PresetKind?) -> SQIcon { LibraryLabels.symbol(for: kind) }
private func title(for kind: PresetKind?) -> String { LibraryLabels.title(for: kind) }

/// Sidebar node. Reference type for NSOutlineView identity.
private final class SidebarNode: NSObject {
    /// A group row (folder icon; selects `section` when it has one) or a plain indented child row.
    enum Content { case group(String, LibrarySection?), section(LibrarySection, title: String, symbol: SQIcon, offline: Bool) }
    let content: Content
    var children: [SidebarNode] = []
    init(_ content: Content) { self.content = content }
    var section: LibrarySection? {
        switch content {
        case .group(_, let s): s
        case .section(let s, _, _, _): s
        }
    }
    var isOffline: Bool { if case .section(_, _, _, true) = content { true } else { false } }
}

private final class LibraryOutlineView: NSOutlineView {
    var sqItems: ((Int) -> [SQMenuItem])?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if let items = sqItems?(row), !items.isEmpty { SQContextMenu.show(items: items, for: event, in: self) }
        return nil
    }
}

private final class LibraryTableView: NSTableView {
    var sqItems: ((Int) -> [SQMenuItem])?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if let items = sqItems?(row), !items.isEmpty { SQContextMenu.show(items: items, for: event, in: self) }
        return nil
    }
}

private final class LibraryCollectionView: NSCollectionView {
    var sqItems: (() -> [SQMenuItem])?
    /// Tile under the pointer at the last right-click (the presets section acts on it).
    var clickedPath: IndexPath?
    var onDoubleClick: ((IndexPath) -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let p = indexPathForItem(at: convert(event.locationInWindow, from: nil)) { onDoubleClick?(p) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        clickedPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        if let items = sqItems?(), !items.isEmpty { SQContextMenu.show(items: items, for: event, in: self) }
        return nil
    }
}

/// Library panel: sidebar (folders, Favorites, Presets) + grid/list of items.
/// Items are dragged out as file URLs.
@MainActor
public final class LibraryPanelView: NSView {
    private let model: LibraryPanelModel
    private let outline = LibraryOutlineView()
    private let search = SQSearchField()
    /// v9 head row: search, the Grid / List toggle (one button showing the current view), tile size (grid only; dimmed in the list).
    private let sizeSlider = SQSlider(value: LibraryTile.defaultFraction, minValue: 0, maxValue: 1)
    private lazy var viewButton = IconButton(symbol: .grid, label: "Show as List", size: 12) { [weak self] in
        guard let self else { return }
        self.model.viewMode = self.model.viewMode == .grid ? .list : .grid
    }
    private var allChip: LibraryChip!
    private let sideColumn = NSStackView()
    private let chipStack = LibraryChipFlow()
    private var chipButtons: [LibraryItemKind: LibraryChip] = [:]
    private static let tileSizeKey = "sq.library.tileSize"
    private var tileFraction: Double = {
        let d = UserDefaults.standard
        return d.object(forKey: LibraryPanelView.tileSizeKey) == nil ? LibraryTile.defaultFraction : d.double(forKey: LibraryPanelView.tileSizeKey)
    }()
    private let collection = LibraryCollectionView()
    private let table = LibraryTableView()
    private let gridScroll = NSScrollView()
    private let listScroll = NSScrollView()
    private let emptyState = EmptyStateView(title: "")
    /// The empty message sits right of the sidebar (8 + 128 + 10); a search without hits has no sidebar and spans the panel.
    private var emptyLeading: NSLayoutConstraint!
    private var nodes: [SidebarNode] = []
    /// Every item of the section (menus, drag); `sections` is non-empty when the folder has subfolders.
    private var items: [LibraryItem] = []
    private var sections: [LibrarySectionData] = []
    private enum ListRow { case header(LibrarySectionData), item(LibraryItem) }
    private var listRows: [ListRow] = []
    private var gridGroups: [[LibraryItem]] = [[]]
    private lazy var previewBar = LibraryPreviewBar(model: model)
    private var presets: [PresetItem] = []
    private var hoverTracker: PresetHoverTracker?
    private var templates: [TextTemplateCatalog.Entry] = []
    /// The presets section's tiles: templates, then saved presets (the flat row is the list row).
    private var presetTiles: [(row: Int, cell: LibraryPresetCell)] = []
    private let presetThumbs = LibraryPresetThumbs()
    /// Double-click on a built-in text template: place it at the playhead.
    public var onApplyTextTemplate: ((String) -> Void)?
    /// Context menu on an audio file: "Whoosh at Selected Cuts" (the host imports the file and places it on the selected cuts).
    public var onWhoosh: ((URL) -> Void)?
    private var syncingSelection = false
    /// reloadData ends display of every cell; that must not cancel pending previews.
    private var reloading = false

    private static let itemID = NSUserInterfaceItemIdentifier("LibraryGridItem")
    private static let headerID = NSUserInterfaceItemIdentifier("LibrarySectionHeader")
    /// v9 numbers: search row 38, tree 136 (v9 had 118; "Text Templates" and "Animated Text" were cut; 4 in on each side), rows `Theme.Row.panelList` (26).
    static let searchRowHeight: CGFloat = 38
    static let sidebarWidth: CGFloat = 136
    static let listRowHeight: CGFloat = Theme.Row.panelList
    /// Where the content starts: tree + v9 `.libmain{padding:8px}`.
    static let contentLeading: CGFloat = sidebarWidth + Theme.Spacing.sm

    private func applyTileSize() {
        guard let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        // v9 `.tiles{grid-template-columns:repeat(auto-fill,minmax(N,1fr))}`: the slider sets the smallest tile, the
        // columns then share the width.
        let size = LibraryTile.size(thumbWidth: LibraryTile.thumbWidth(forFraction: tileFraction))
        let gap = layout.minimumInteritemSpacing
        let avail = (collection.enclosingScrollView?.contentSize.width ?? 0) - layout.sectionInset.left - layout.sectionInset.right
        var item = size
        if avail > size.width {
            let columns = max(1, ((avail + gap) / (size.width + gap)).rounded(.down))
            let width = ((avail - (columns - 1) * gap) / columns).rounded(.down)
            let stretched = LibraryTile.size(thumbWidth: width - (size.width - LibraryTile.thumbWidth(forFraction: tileFraction)))
            item = NSSize(width: width, height: stretched.height)
        }
        guard layout.itemSize != item else { return }
        layout.itemSize = item
        layout.invalidateLayout()
    }

    @objc private func sizeChanged() {
        tileFraction = sizeSlider.doubleValue
        UserDefaults.standard.set(tileFraction, forKey: Self.tileSizeKey)
        applyTileSize()
    }

    public init(model: LibraryPanelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        build()
        registerForDraggedTypes([.fileURL])       // drop a .sqpack here (LibraryPanelView+PackDrop)
        trackObservation { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(lookThumbnailsReady), name: ColorLookPreview.thumbnailsReady,
                                               object: nil)
    }

    /// Look thumbnails finished in the background: refill the visible LUT tiles and rows in place (no reload, so pending
    /// media previews keep running).
    @objc private func lookThumbnailsReady() {
        guard !model.isShowingPresets else { return }
        for ip in collection.indexPathsForVisibleItems() {
            guard let it = item(at: ip), it.entry.kind == .lut, let cell = collection.item(at: ip) as? LibraryGridItem else { continue }
            cell.configure(name: it.entry.name, image: thumbnailImage(for: it), symbol: symbolName(for: it.entry.kind), favorite: it.isFavorite)
        }
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        let lutRows = IndexSet((rows.location..<rows.location + rows.length).filter { item(row: $0)?.entry.kind == .lut })
        if !lutRows.isEmpty { table.reloadData(forRowIndexes: lutRows, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor

        // Tree (v9 `.libside`): 118 wide, group rows with a folder icon, plain indented children, rounded selection.
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        QuietList.style(outline, rowHeight: Self.listRowHeight)
        outline.indentationPerLevel = 0
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.sqItems = { [weak self] row in self?.folderMenuItems(row: row) ?? [] }
        let sideScroll = NSScrollView()
        sideScroll.documentView = outline
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false
        outline.backgroundColor = .clear

        // v9 has no footer under the tree: Add Folder… lives in the panel menu, the tree's context menu and the empty state.
        sideColumn.orientation = .vertical
        sideColumn.spacing = 0
        sideColumn.alignment = .leading
        sideColumn.edgeInsets = NSEdgeInsetsMake(Theme.Spacing.xs, 0, 0, 0)
        sideColumn.setViews([sideScroll], in: .top)
        sideColumn.translatesAutoresizingMaskIntoConstraints = false
        sideColumn.widthAnchor.constraint(equalToConstant: Self.sidebarWidth - 2 * Theme.Spacing.xs).isActive = true
        sideScroll.widthAnchor.constraint(equalTo: sideColumn.widthAnchor).isActive = true

        // Head row (38 high): search field, Grid / List, tile size.
        search.setQuietPlaceholder("Search library")
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        sizeSlider.doubleValue = tileFraction
        sizeSlider.defaultValue = LibraryTile.defaultFraction
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.sqToolTip = "Tile Size"
        let topBar = NSStackView(views: [search, viewButton, sizeSlider])
        topBar.spacing = Theme.Spacing.sm
        topBar.edgeInsets = NSEdgeInsetsMake(0, Theme.Spacing.sm, 0, Theme.Spacing.sm)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 64).isActive = true
        sizeSlider.heightAnchor.constraint(equalToConstant: Theme.Row.control).isActive = true

        // v9: "All" first (on while no kind is picked; a click clears the filter), then the kind chips (a click toggles one).
        allChip = LibraryChip(title: "All", target: self, action: #selector(allChipPressed))
        chipStack.addChip(allChip)
        for kind in LibraryPanelModel.filterKinds {
            let b = LibraryChip(title: title(for: kind), target: self, action: #selector(chipToggled(_:)))
            b.tag = LibraryPanelModel.filterKinds.firstIndex(of: kind)!
            chipButtons[kind] = b
            chipStack.addChip(b)
        }

        // Grid
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Theme.Spacing.sm
        layout.minimumLineSpacing = Theme.Spacing.sm
        layout.sectionInset = NSEdgeInsetsMake(LibraryTile.ringWidth, LibraryTile.ringWidth, Theme.Spacing.sm, Theme.Spacing.sm)
        collection.collectionViewLayout = layout
        applyTileSize()
        collection.register(LibraryGridItem.self, forItemWithIdentifier: Self.itemID)
        collection.register(LibrarySectionHeaderItem.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: Self.headerID)
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        collection.onDoubleClick = { [weak self] path in self?.gridDoubleClicked(path) }
        collection.sqItems = { [weak self] in self?.itemMenuItems(row: -1) ?? [] }
        gridScroll.documentView = collection
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false

        // List: Name | Kind | Size (Created for presets); `Theme.Row.list` rows, header click sorts.
        let specs: [(String, String, Double, LibrarySortKey?)] = [("name", "Name", 240, .name), ("kind", "Kind", 64, nil),
                                                                  ("size", "Size", 84, .size), ("date", "Created", 90, .date)]
        for (id, title, width, proto) in specs {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 40
            if let proto { c.sortDescriptorPrototype = NSSortDescriptor(key: "\(proto)", ascending: true) }
            QuietList.styleColumn(c)
            table.addTableColumn(c)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.allowsMultipleSelection = true
        QuietList.style(table, rowHeight: Self.listRowHeight)
        PanelListHeader.apply(to: table)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.sqItems = { [weak self] row in self?.itemMenuItems(row: row) ?? [] }
        let hover = PresetHoverTracker(table: table)
        hover.content = { [weak self] row in self?.hoverContent(row: row) }
        hoverTracker = hover
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        for v in [chipStack, gridScroll, listScroll, previewBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            chipStack.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.sm),
            chipStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            previewBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            previewBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            gridScroll.topAnchor.constraint(equalTo: chipStack.bottomAnchor),
            listScroll.topAnchor.constraint(equalTo: chipStack.bottomAnchor),
        ])
        for v in [gridScroll, listScroll] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: previewBar.topAnchor),
            ])
        }

        // Body: tree 4 in (v9 `.libside{padding:4px}`), content 8 in on both sides (`.libmain{padding:8px}`).
        let body = NSStackView(views: [sideColumn, content])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = Theme.Spacing.xs + Theme.Spacing.sm
        body.edgeInsets = NSEdgeInsetsMake(0, Theme.Spacing.xs, 0, Theme.Spacing.sm)
        body.translatesAutoresizingMaskIntoConstraints = false
        content.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        sideColumn.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        emptyLeading = emptyState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentLeading)
        addSubview(topBar)
        addSubview(body)
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Self.searchRowHeight),
            body.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLeading,
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refresh()
    }

    @objc private func tableDoubleClicked() {
        guard model.isShowingPresets, let cell = presetCell(row: table.clickedRow) else { return }
        activate(cell)
    }

    private func gridDoubleClicked(_ path: IndexPath) {
        guard model.isShowingPresets, presetTiles.indices.contains(path.item) else { return }
        activate(presetTiles[path.item].cell)
    }

    /// Double-click on a preset row or tile: place the template, insert the title block, apply the effect preset.
    private func activate(_ cell: LibraryPresetCell) {
        switch cell {
        case .template(let t):
            model.recordPresetUse(PresetKey.builtIn(t.id))
            onApplyTextTemplate?(t.id)
        case .user(let p):
            if p.kind.isTitleInsert { model.recordPresetUse(PresetKey.user(p.id)); model.onInsertTitleBlock?(p, nil) }
            else if p.kind == .effect { model.recordPresetUse(PresetKey.user(p.id)); model.onApplyPreset?(p, nil) }
        }
    }

    /// The cell of a row of the presets list (built-in templates, then saved presets).
    private func presetCell(row: Int) -> LibraryPresetCell? {
        guard row >= 0 else { return nil }
        if templates.indices.contains(row) { return .template(templates[row]) }
        let p = row - templates.count
        return presets.indices.contains(p) ? .user(presets[p]) : nil
    }

    /// Picture of a template or saved preset: its own style drawn by the real text renderer; a title template's saved
    /// frame; nil (symbol) for presets without a text style.
    private func presetPicture(_ cell: LibraryPresetCell) -> (image: NSImage?, symbol: SQIcon) {
        func sample(_ text: String) -> String { text.count <= 12 && !text.contains("\n") && !text.isEmpty ? text : "Text" }
        switch cell {
        case .template(let t):
            if t.isCTA || t.graphicPresetID != nil { return (nil, t.graphicPresetID == nil ? .text : .sparkles) }
            return (presetThumbs.styleStill(key: "tpl." + t.id, style: t.template.style, text: sample(t.template.text)), .text)
        case .user(let p):
            if p.kind == .titleTemplate, let thumb = titleTemplateImage(for: p) { return (thumb, sidebarSymbol(for: p.kind)) }
            if p.kind == .textTemplate, let t = try? TextTemplate.decode(from: p.payload) {
                return (presetThumbs.styleStill(key: "usr." + p.id.uuidString, style: t.style, text: sample(t.text)), sidebarSymbol(for: p.kind))
            }
            return (nil, sidebarSymbol(for: p.kind))
        }
    }

    /// Flat rows of the selected tiles or list rows, for the menus.
    private func selectedPresetRows() -> [Int] {
        if listScroll.isHidden {
            return collection.selectionIndexPaths.sorted().compactMap { presetTiles.indices.contains($0.item) ? presetTiles[$0.item].row : nil }
        }
        return Array(table.selectedRowIndexes)
    }

    // MARK: Refresh (driven by observation)

    private func refresh() {
        let keptSelection = Set(clickedItemsSelection().map(\.id))      // survives the reload below
        // Read everything the view shows so observation tracks it.
        let folders = model.folders
        let selection = model.selection
        let presetMode = model.isShowingPresets
        items = model.items
        sections = model.sections
        gridGroups = sections.isEmpty ? [items] : sections.map(\.items)
        listRows = sections.isEmpty ? items.map { .item($0) }
            : sections.flatMap { [ListRow.header($0)] + $0.items.map { ListRow.item($0) } }
        presets = model.visiblePresets
        templates = model.visibleTextTemplates
        presetTiles = presetMode ? (0..<(templates.count + presets.count)).compactMap { r in presetCell(row: r).map { (r, $0) } } : []
        let offline = model.isSelectedFolderOffline
        let viewMode = model.viewMode
        let kinds = model.kindFilter
        _ = model.thumbnails
        _ = model.favorites
        _ = model.presetCount(nil)
        let sortKey = model.sortKey
        _ = (model.presetSort, model.presetAscending)

        rebuildSidebar(folders: folders)
        syncSidebarSelection(selection)
        for (kind, b) in chipButtons { b.state = kinds.contains(kind) ? .on : .off }
        allChip.state = kinds.isEmpty ? .on : .off
        chipStack.isHidden = presetMode
        viewButton.setSymbol(viewMode == .grid ? .grid : .list, tint: Theme.Colors.label2, size: 12)
        viewButton.setAccessibilityLabel(viewMode == .grid ? "Show as List" : "Show as Grid")
        viewButton.sqToolTip = viewMode == .grid ? "Show as List" : "Show as Grid"
        sizeSlider.alphaValue = viewMode == .grid ? 1 : 0.4
        sizeSlider.isEnabled = viewMode == .grid
        _ = sortKey
        let query = model.query

        gridScroll.isHidden = viewMode != .grid
        listScroll.isHidden = viewMode != .list
        if presetMode {
            setColumns(presetMode: true)
        } else {
            setColumns(presetMode: false)
        }
        reloading = true
        collection.reloadData()
        table.reloadData()
        if !presetMode, !keptSelection.isEmpty {
            // An item listed under All and under its subfolder is selected once (the first copy).
            var seen = Set<LibraryEntryID>()
            var paths: Set<IndexPath> = []
            for (s, group) in gridGroups.enumerated() {
                for (i, it) in group.enumerated() where keptSelection.contains(it.id) && seen.insert(it.id).inserted {
                    paths.insert(IndexPath(item: i, section: s))
                }
            }
            collection.selectionIndexPaths = paths
            var seenRows = Set<LibraryEntryID>()
            var rows = IndexSet()
            for (r, row) in listRows.enumerated() {
                if case .item(let it) = row, keptSelection.contains(it.id), seenRows.insert(it.id).inserted { rows.insert(r) }
            }
            table.selectRowIndexes(rows, byExtendingSelection: false)
        }
        reloading = false

        let count = presetMode ? templates.count + presets.count : items.count
        emptyState.isHidden = count > 0
        // A search without hits fills the panel (board "Library · no hits"): no sidebar, no chips.
        let noHits = count == 0 && !query.trimmingCharacters(in: .whitespaces).isEmpty
        sideColumn.isHidden = noHits
        emptyLeading.constant = noHits ? 0 : Self.contentLeading
        gridScroll.isHidden = gridScroll.isHidden || noHits
        listScroll.isHidden = listScroll.isHidden || noHits
        if noHits { chipStack.isHidden = true }
        var text = Self.emptyText(offline: offline, presetMode: presetMode, favorites: selection == .favorites,
                                  hasFolders: !model.folders.isEmpty, query: query)
        if presetMode, model.presetFilterActive, query.trimmingCharacters(in: .whitespaces).isEmpty {
            text = ("Nothing here", "No preset matches the current filter. Open the ... menu and choose Show: All.")
        }
        emptyState.title = text.title
        emptyState.hint = text.hint
        // v9 "No library folders": the button under the hint adds one.
        let offersFolder = !presetMode && !noHits && !offline && model.folders.isEmpty && selection != .favorites
        emptyState.setAction(title: offersFolder ? "Add Folder\u{2026}" : nil, handler: offersFolder ? { [weak self] in self?.addFolder() } : nil)
    }

    /// What the empty list says and how to fill it (INTERACTION-AUDIT §10).
    static func emptyText(offline: Bool, presetMode: Bool, favorites: Bool, hasFolders: Bool, query: String = "") -> (title: String, hint: String) {
        LibraryLabels.emptyText(offline: offline, presetMode: presetMode, favorites: favorites, hasFolders: hasFolders, query: query)
    }

    override public func layout() {
        super.layout()
        fitListColumns()
        applyTileSize()
    }

    /// Name takes what Kind / Size (Created) leave, so every column is visible at the narrowest panel (board: 480 pt panel).
    private func fitListColumns() {
        let width = listScroll.contentSize.width
        guard width > 0, let name = table.tableColumn(withIdentifier: .init("name")) else { return }
        let others = table.tableColumns.filter { $0 !== name && !$0.isHidden }.reduce(0) { $0 + $1.width + table.intercellSpacing.width }
        let target = max(100, width - others - table.intercellSpacing.width)
        if abs(name.width - target) > 0.5 { name.width = target }
    }

    private func setColumns(presetMode: Bool) {
        table.tableColumn(withIdentifier: .init("kind"))?.title = "Kind"
        table.tableColumn(withIdentifier: .init("size"))?.isHidden = presetMode
        // Files: Name | Kind | Size as drawn on the board. Presets keep their creation date.
        table.tableColumn(withIdentifier: .init("date"))?.isHidden = !presetMode
    }

    private var lastSidebarSignature: [String] = []

    private func rebuildSidebar(folders: [LibraryFolderRow]) {
        let sig = folders.map { "\($0.id)|\($0.folder.displayName)|\($0.state)" } + ["\(model.presetCount(nil))"] + model.packNames
        guard sig != lastSidebarSignature else { return }
        lastSidebarSignature = sig
        // v9 tree: "Library" (selectable: every folder) > Favorites + the watched folders; "Presets" > the preset kinds.
        let library = SidebarNode(.group("Library", .all))
        library.children = [SidebarNode(.section(.favorites, title: "Favorites", symbol: .star, offline: false))] + folders.map {
            SidebarNode(.section(.folder($0.id), title: $0.folder.displayName, symbol: $0.state == .offline ? .driveOffline : .folder, offline: $0.state == .offline))
        }
        let presetGroup = SidebarNode(.group("Presets", nil))
        presetGroup.children = ([nil] + PresetKind.allCases.filter { $0 != .titleBlock && $0 != .titleTemplate }.map { Optional($0) }).map {
            SidebarNode(.section(.presets($0), title: title(for: $0), symbol: sidebarSymbol(for: $0), offline: false))
        }
        nodes = [library, presetGroup]
        if !model.packNames.isEmpty {
            let packGroup = SidebarNode(.group("Packs", nil))
            packGroup.children = model.packNames.map { SidebarNode(.section(.pack($0), title: $0, symbol: .package, offline: false)) }
            nodes.append(packGroup)
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    private func syncSidebarSelection(_ selection: LibrarySection) {
        for n in nodes + nodes.flatMap(\.children) where n.section == selection {
            let row = outline.row(forItem: n)
            if row >= 0, outline.selectedRow != row {
                syncingSelection = true
                outline.selectRowIndexes([row], byExtendingSelection: false)
                syncingSelection = false
            }
        }
        updateSidebarTextColors()
    }

    /// v9 `.row{color:t2}` / `.row.sel{color:t1}`: the selected row's text is brighter.
    private func updateSidebarTextColors() {
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
                  let node = outline.item(atRow: row) as? SidebarNode else { continue }
            cell.textField?.textColor = node.isOffline ? Theme.Colors.label3 : (row == outline.selectedRow ? Theme.Colors.label : Theme.Colors.label2)
        }
    }

    // MARK: Actions

    /// "Add Folder…" (panel menu, tree context menu, empty state): add a watched folder.
    public func addWatchedFolder() { addFolder() }

    /// Header "..." of the Library panel: as Grid / as List, Sort by Name / Date / Size (picking the current key flips
    /// the direction).
    public func showOptions(from sender: NSView) {
        var rows: [SQMenuItem] = ["as Grid", "as List"].enumerated().map { i, title in
            SQMenuItem(title: title, isChecked: (model.viewMode == .grid) == (i == 0)) { [weak self] in self?.model.viewMode = i == 0 ? .grid : .list }
        }
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Add Folder\u{2026}") { [weak self] in self?.addFolder() })
        rows.append(.separator)
        if model.isShowingPresets { return showPresetOptions(rows: rows, from: sender) }
        for (i, key) in Self.sortMenuKeys.enumerated() {
            rows.append(SQMenuItem(title: "Sort by \(Self.sortMenuTitles[i])", isChecked: model.sortKey == key) { [weak self] in self?.sort(by: key) })
        }
        SQContextMenu.popUp(items: rows, at: NSPoint(x: sender.bounds.minX, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY), in: sender)
    }

    /// Presets section: Sort by Name / Newest / Most Used / Recently Used, Show (scope), Category and Tag filters.
    private func showPresetOptions(rows base: [SQMenuItem], from sender: NSView) {
        var rows = base
        for key in PresetSortKey.allCases {
            rows.append(SQMenuItem(title: "Sort by \(key.title)", isChecked: model.presetSort == key) { [weak self] in self?.model.sortPresets(by: key) })
        }
        rows.append(.separator)
        rows.append(SQMenuItem(title: "Show", submenu: PresetScope.allCases.map { scope in
            SQMenuItem(title: scope.title, isChecked: model.presetScope == scope) { [weak self] in self?.model.presetScope = scope }
        }))
        let counts = model.presetCategoryCounts
        var cats = [SQMenuItem(title: "All Categories", isChecked: model.presetCategory == nil) { [weak self] in self?.model.presetCategory = nil }]
        cats += PresetCategory.allCases.map { cat in
            SQMenuItem(title: "\(cat.title) (\(counts[cat] ?? 0))", isEnabled: (counts[cat] ?? 0) > 0 || model.presetCategory == cat,
                       isChecked: model.presetCategory == cat) { [weak self] in self?.model.presetCategory = cat }
        }
        rows.append(SQMenuItem(title: "Category", submenu: cats))
        let tags = model.presetTagCounts
        if !tags.isEmpty {
            var items = [SQMenuItem(title: "All Tags", isChecked: model.presetTag == nil) { [weak self] in self?.model.presetTag = nil }]
            items += tags.map { t in
                SQMenuItem(title: "\(t.tag) (\(t.count))", isChecked: model.presetTag == t.tag) { [weak self] in self?.model.presetTag = t.tag }
            }
            rows.append(SQMenuItem(title: "Tag", submenu: items))
        }
        if model.presetFilterActive {
            rows.append(.separator)
            rows.append(SQMenuItem(title: "Clear Filters") { [weak self] in self?.model.clearPresetFilters() })
        }
        SQContextMenu.popUp(items: rows, at: NSPoint(x: sender.bounds.minX, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY), in: sender)
    }

    private static let sortMenuKeys: [LibrarySortKey] = [.name, .date, .size]
    private static let sortMenuTitles = ["Name", "Date", "Size"]

    private func sort(by key: LibrarySortKey) {
        if model.sortKey == key { model.ascending.toggle() } else { model.sortKey = key; model.ascending = true }
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope)
        Task { await model.addFolder(url: url, bookmark: bookmark) }
    }

    @objc private func searchChanged() { model.query = search.stringValue }
    @objc private func chipToggled(_ sender: SQButton) { model.toggleKind(LibraryPanelModel.filterKinds[sender.tag]) }
    @objc private func allChipPressed() { model.clearKindFilter(); allChip.state = .on }

    func importDroppedPacks(_ urls: [URL]) { LibraryPackFlow.importFiles(urls, model: model, window: window) }
    var canImportDroppedTemplates: Bool { model.onImportMotionGraphicsTemplates != nil }
    func importDroppedTemplates(_ urls: [URL]) { model.onImportMotionGraphicsTemplates?(urls) }

    fileprivate func packName(atRow row: Int) -> String? {
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, case .pack(let name)? = node.section else { return nil }
        return name
    }

    private func folderID(atRow row: Int) -> UUID? {
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, case .folder(let id)? = node.section else { return nil }
        return id
    }

    /// The selected items of the visible list or grid (before a reload replaces `items`).
    private func clickedItemsSelection() -> [LibraryItem] {
        if model.isShowingPresets { return [] }
        if !listScroll.isHidden { return Self.unique(table.selectedRowIndexes.sorted().compactMap(item(row:))) }
        return Self.unique(collection.selectionIndexPaths.sorted().compactMap(item(at:)))
    }

    private static func unique(_ items: [LibraryItem]) -> [LibraryItem] {
        var seen = Set<LibraryEntryID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func item(at path: IndexPath) -> LibraryItem? {
        guard gridGroups.indices.contains(path.section), gridGroups[path.section].indices.contains(path.item) else { return nil }
        return gridGroups[path.section][path.item]
    }

    private func item(row: Int) -> LibraryItem? {
        guard listRows.indices.contains(row), case .item(let it) = listRows[row] else { return nil }
        return it
    }

    private func isHeaderRow(_ row: Int) -> Bool {
        guard !model.isShowingPresets, listRows.indices.contains(row), case .header = listRows[row] else { return false }
        return true
    }

    /// Space while the Library has focus: pauses or plays the previewed item. False when nothing is previewed
    /// (the app then plays the sequence).
    public func handlePlayPause() -> Bool {
        guard let item = model.previewItem, let mode = LibraryPreviewMath.mode(for: item.entry.kind), mode != .image else { return false }
        model.preview.togglePlayPause()
        return true
    }

    override public func viewDidHide() {
        super.viewDidHide()
        model.preview.pause()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { model.preview.pause() }
    }

    /// Selecting one item previews it (audio and video play at once); several selected items keep the current preview.
    private func previewSelection() {
        guard !reloading, !model.isShowingPresets else { return }
        let selected = clickedItemsSelection()
        if selected.count == 1 { model.selectItemForPreview(selected[0]) }
        else if selected.isEmpty { model.selectItemForPreview(nil) }
    }

    private func clickedItems(clickedRow clicked: Int = -1) -> [LibraryItem] {
        if !listScroll.isHidden {
            var rows = table.selectedRowIndexes
            if clicked >= 0, !rows.contains(clicked) { rows = [clicked] }
            return Self.unique(rows.compactMap(item(row:)))
        }
        return Self.unique(collection.selectionIndexPaths.sorted().compactMap(item(at:)))
    }

    // MARK: Item rows

    /// The thumbnail saved with a title template, decoded once per preset.
    fileprivate func titleTemplateImage(for preset: PresetItem) -> NSImage? {
        let key = preset.id.uuidString as NSString
        if let hit = templateImageCache.object(forKey: key) { return hit }
        guard let data = model.titleTemplateThumbnailData(for: preset), let image = NSImage(data: data) else { return nil }
        templateImageCache.setObject(image, forKey: key)
        return image
    }
    private let templateImageCache = NSCache<NSString, NSImage>()

    fileprivate func thumbnailImage(for item: LibraryItem) -> NSImage? {
        // C3: a LUT shows its look on the shared test picture (cached, rendered off the main thread; nil until ready).
        if item.entry.kind == .lut { return ColorLookPreview.thumbnail(forLookPath: item.url.path) }
        guard LibraryPanelModel.previewKind(for: item.entry.kind) == .thumbnail,
              let url = model.thumbnails[item.id] else { return nil }
        if let hit = imageCache.object(forKey: url as NSURL) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: url as NSURL)       // every cell asks again on each reload: read each file once
        return image
    }

    private let imageCache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 300
        return c
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Sidebar

extension LibraryPanelView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? nodes.count
    }
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? nodes[index]
    }
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }
    /// Group rows are ordinary rows here (v9: same row style, with a folder icon), so "Library" can be selected.
    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }
    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.section != nil
    }
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.Typography.list
        label.lineBreakMode = .byTruncatingTail
        label.textColor = node.section == model.selection ? Theme.Colors.label : Theme.Colors.label2
        cell.addSubview(label)
        cell.textField = label
        let pad = Theme.Spacing.sm
        var trailing = cell.trailingAnchor
        func addIcon(_ symbol: SQIcon, label text: String?) -> NSImageView {
            let icon = NSImageView(image: Theme.symbol(symbol, size: 12, label: text) ?? NSImage())
            icon.contentTintColor = Theme.Colors.label3
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
            return icon
        }
        switch node.content {
        case .group(let t, _):
            // v9 `.libside .row`: 12 pt folder icon in `label3`, 6 gap, name.
            label.stringValue = t
            let icon = addIcon(.folder, label: nil)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: pad),
                icon.widthAnchor.constraint(equalToConstant: 14),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.iconToLabel),
            ])
        case .section(_, let t, _, let offline):
            // v9 `.row.sub`: plain text, one tree step in. An offline folder is dimmed and keeps its mark at the right edge.
            label.stringValue = t
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: pad + Theme.Spacing.treeIndent).isActive = true
            if offline {
                label.textColor = Theme.Colors.label3
                let icon = addIcon(.driveOffline, label: "Offline")
                icon.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -pad).isActive = true
                trailing = icon.leadingAnchor
                cell.sqToolTip = "Folder is offline"
            }
        }
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -Theme.Spacing.xs),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        updateSidebarTextColors()
        guard !syncingSelection, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode,
              let section = node.section else { return }
        model.selection = section
    }
    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let v = LibraryRowView()
        v.selectionRadius = Theme.Radius.control
        v.showsHover = (item as? SidebarNode)?.section != nil
        return v
    }
    /// Groups are plain rows (no disclosure): every row is `Theme.Row.panelList` high.
    public func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }
    public func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { false }
    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { Self.listRowHeight }
}

// MARK: - Grid

private final class LibraryGridItem: NSCollectionViewItem {
    private let tile = LibraryTileView()

    override func loadView() { view = tile }

    /// Selection is the 2 pt yellow ring around the thumbnail (no fill).
    override var isSelected: Bool { didSet { tile.isRingVisible = isSelected } }

    func configure(name: String, image: NSImage?, symbol: SQIcon, favorite: Bool) {
        tile.nameField.stringValue = name
        tile.setPicture(image, symbol: symbol)
        tile.badge.isHidden = !favorite
    }
}

extension LibraryPanelView: NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    public func numberOfSections(in collectionView: NSCollectionView) -> Int { model.isShowingPresets ? 1 : gridGroups.count }
    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        if model.isShowingPresets { return presetTiles.count }
        return !gridGroups.indices.contains(section) ? 0 : gridGroups[section].count
    }
    public func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let v = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: Self.headerID, for: indexPath)
        if let v = v as? LibrarySectionHeaderItem, sections.indices.contains(indexPath.section) {
            let g = sections[indexPath.section].group
            v.header.configure(g)
            v.header.onToggle = { [weak self] in self?.model.toggleGroup(g.id) }
        }
        return v
    }
    public func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
        sections.isEmpty || model.isShowingPresets ? .zero : NSSize(width: max(collectionView.bounds.width, 1), height: LibrarySectionHeaderView.height)
    }
    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath)
        if model.isShowingPresets {
            if let cell = cell as? LibraryGridItem, presetTiles.indices.contains(indexPath.item) {
                let c = presetTiles[indexPath.item].cell
                let pic = presetPicture(c)
                switch c {
                case .template(let t): cell.configure(name: t.name, image: pic.image, symbol: pic.symbol, favorite: model.entry(for: t).meta.isFavorite)
                case .user(let p): cell.configure(name: p.name, image: pic.image, symbol: pic.symbol, favorite: model.entry(for: p).meta.isFavorite)
                }
            }
            return cell
        }
        if let cell = cell as? LibraryGridItem, let item = item(at: indexPath) {
            cell.configure(name: item.entry.name, image: thumbnailImage(for: item), symbol: symbolName(for: item.entry.kind), favorite: item.isFavorite)
        }
        return cell
    }
    public func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        if let it = self.item(at: indexPath) { model.itemDidAppear(it) }
    }
    public func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        if !reloading, let it = self.item(at: indexPath) { model.itemDidDisappear(it.id) }
    }
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { previewSelection() }
    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { previewSelection() }
    public func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        if model.isShowingPresets { return presetTiles.indices.contains(indexPath.item) ? presetPasteboardItem(presetTiles[indexPath.item].cell) : nil }
        return item(at: indexPath).map { $0.url as NSURL }
    }
}

// MARK: - List

extension LibraryPanelView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        model.isShowingPresets ? templates.count + presets.count : listRows.count
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = LibraryRowView()          // v9 `.clist .row`: no stripes, hover fill
        v.showsHover = !isHeaderRow(row)
        return v
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { isHeaderRow(row) }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !isHeaderRow(row) }

    public func tableViewSelectionDidChange(_ notification: Notification) { previewSelection() }

    /// Header click: Name, Size (files) or Created (presets) sorts; the same column again flips the direction.
    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        if !reloading, model.isShowingPresets, let d = tableView.sortDescriptors.first, let key = d.key {
            let (sort, asc) = key == "date" ? (PresetSortKey.newest, !d.ascending) : (.name, d.ascending)
            if sort != model.presetSort || asc != model.presetAscending { model.presetSort = sort; model.presetAscending = asc }
            return
        }
        guard !reloading, let d = tableView.sortDescriptors.first, let key = d.key,
              let sort = LibrarySortKey.allCases.first(where: { "\($0)" == key }) else { return }
        if sort == model.sortKey && model.ascending == d.ascending { return }
        model.sortKey = sort
        model.ascending = d.ascending
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if isHeaderRow(row), case .header(let section) = listRows[row] {
            let v = LibrarySectionHeaderView()
            v.configure(section.group)
            v.onToggle = { [weak self] in self?.model.toggleGroup(section.group.id) }
            return v
        }
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.font = Theme.Typography.list
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        var leading = cell.leadingAnchor
        var inset: CGFloat = Theme.Spacing.sm
        if id == "name" {
            label.textColor = Theme.Colors.label
            let icon = NSImageView()
            icon.contentTintColor = Theme.Colors.label2
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.sm),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 22),
                icon.heightAnchor.constraint(equalToConstant: 14),
            ])
            leading = icon.trailingAnchor
            inset = Theme.Spacing.iconToLabel
        } else {
            // v9 `.clist`: kind and size / date in label3, the numbers right-aligned.
            let right = id != "kind"
            label.textColor = Theme.Colors.label3
            label.alignment = right ? .right : .left
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: inset),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.Spacing.sm),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if model.isShowingPresets {
            if row < templates.count {
                let e = model.entry(for: templates[row])
                switch id {
                case "name":
                    label.stringValue = templates[row].name
                    Self.setPresetIcon(cell, symbol: .text, favorite: e.meta.isFavorite)
                    if !e.meta.isFavorite, let pic = presetPicture(.template(templates[row])).image {
                        cell.imageView?.image = pic                    // its own style, drawn by the text renderer
                        cell.imageView?.imageScaling = .scaleProportionallyUpOrDown
                        cell.imageView?.contentTintColor = nil
                    }
                case "kind": label.stringValue = e.category.title
                    cell.imageView?.image = Theme.symbol(templates[row].graphicPresetID == nil ? .text : .sparkles, size: 11)
                case "kind": label.stringValue = templates[row].kindLabel
                case "date": label.stringValue = "Built-in"
                default: break
                }
                return cell
            }
            guard row - templates.count < presets.count else { return cell }
            let p = presets[row - templates.count]
            let e = model.entry(for: p)
            switch id {
            case "name":
                label.stringValue = p.name
                Self.setPresetIcon(cell, symbol: sidebarSymbol(for: p.kind), favorite: e.meta.isFavorite)
                if p.kind == .titleTemplate || p.kind == .textTemplate, !e.meta.isFavorite, let thumb = presetPicture(.user(p)).image {
                    cell.imageView?.image = thumb                  // the saved frame / its own style instead of the type icon
                    cell.imageView?.imageScaling = .scaleProportionallyUpOrDown
                    cell.imageView?.contentTintColor = nil
                }
            case "kind": label.stringValue = e.category.title
            case "date": label.stringValue = Self.dateFormatter.string(from: p.createdAt)
            default: break
            }
        } else {
            guard let item = item(row: row) else { return cell }
            switch id {
            case "name":
                label.stringValue = item.entry.name
                if let img = thumbnailImage(for: item) {
                    cell.imageView?.image = img
                    cell.imageView?.imageScaling = .scaleProportionallyUpOrDown
                } else {
                    cell.imageView?.image = Theme.symbol(symbolName(for: item.entry.kind), size: 11)
                    cell.imageView?.imageScaling = .scaleNone
                    cell.imageView?.contentTintColor = Theme.Colors.label2
                }
                model.itemDidAppear(item)
            case "kind": label.stringValue = title(for: item.entry.kind)
            case "size": label.stringValue = SQByteSize.string(item.entry.size)
            case "date": label.stringValue = Self.dateFormatter.string(from: item.entry.modified)
            default: break
            }
        }
        return cell
    }

    /// Type icon of a preset row; a favorite shows a yellow star instead.
    private static func setPresetIcon(_ cell: NSTableCellView, symbol: SQIcon, favorite: Bool) {
        cell.imageView?.image = Theme.symbol(favorite ? .starFilled : symbol, size: 11)
        cell.imageView?.contentTintColor = favorite ? Theme.Colors.yellow : Theme.Colors.label2
    }

    public func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard !reloading, !model.isShowingPresets, let it = item(row: row) else { return }
        model.itemDidDisappear(it.id)
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        if model.isShowingPresets { return presetCell(row: row).flatMap(presetPasteboardItem) }
        return item(row: row).map { $0.url as NSURL }
    }
}

// MARK: - Item menu and preset files

extension LibraryPanelView {
    /// What a dragged template or preset puts on the pasteboard (timeline and clips accept these); nil = not draggable.
    fileprivate func presetPasteboardItem(_ cell: LibraryPresetCell) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        switch cell {
        case .template(let t):
            item.setString(t.id, forType: .sequenceTextTemplate)
            model.recordPresetUse(PresetKey.builtIn(t.id))
        case .user(let p) where p.kind.isTitleInsert:
            item.setString(p.id.uuidString, forType: .sequenceTitleBlock)   // drop onto the timeline places it
            model.recordPresetUse(PresetKey.user(p.id))
        case .user(let p) where p.kind == .effect:
            item.setString(p.id.uuidString, forType: .sequencePresetID)    // drop onto a clip applies it
            model.recordPresetUse(PresetKey.user(p.id))
        case .user: return nil
        }
        return item
    }

    fileprivate func preset(atRow row: Int) -> PresetItem? {
        let i = row - templates.count
        return row >= 0 && presets.indices.contains(i) ? presets[i] : nil
    }

    /// Card content of a row in the presets section (built-in templates and saved presets).
    fileprivate func hoverContent(row: Int) -> (key: String, content: PresetHoverContent)? {
        guard model.isShowingPresets else { return nil }
        if templates.indices.contains(row) {
            let t = templates[row]
            let e = model.entry(for: t)
            let c = PresetHoverContent(title: t.name, lines: PresetHoverInfo.lines(for: e), sample: t.isCTA ? nil : t.template.style,
                                       sampleText: TextTemplateCatalog.placeholderText)
            return (e.key, c)
        }
        guard let p = preset(atRow: row) else { return nil }
        let e = model.entry(for: p)
        var style: TextStyle?
        var text = TextTemplateCatalog.placeholderText
        if p.kind == .textTemplate, let t = try? TextTemplate.decode(from: p.payload) { style = t.style; text = t.text.isEmpty ? text : t.text }
        return (e.key, PresetHoverContent(title: p.name, lines: PresetHoverInfo.lines(for: e) + [title(for: p.kind)], sample: style, sampleText: text))
    }

    fileprivate func folderMenuItems(row: Int) -> [SQMenuItem] {
        if let pack = packName(atRow: row) {
            return LibraryMenus.packItems { [weak self] a in
                guard let self else { return }
                switch a {
                case .exportPack: LibraryPackFlow.export(ids: self.model.presetIDs(inPack: pack), suggestedName: pack, model: self.model, window: self.window)
                case .importPack: LibraryPackFlow.chooseAndImport(model: self.model, window: self.window)
                default: break
                }
            }
        }
        let add = SQMenuItem(title: "Add Folder\u{2026}") { [weak self] in self?.addFolder() }
        guard let id = folderID(atRow: row) else { return [add] }
        return [add, .separator] + LibraryMenus.folderItems { [weak self] a in
            guard let self else { return }
            switch a {
            case .rescan: Task { await self.model.rescan(id) }
            case .removeFolder: Task { await self.model.removeFolder(id) }
            default: break
            }
        }
    }

    /// Rows are built at the click and capture what was clicked: the actions run after the menu closed.
    fileprivate func itemMenuItems(row: Int) -> [SQMenuItem] {
        let gridRow = collection.clickedPath.flatMap { presetTiles.indices.contains($0.item) ? presetTiles[$0.item].row : nil }
        let presetRow = row >= 0 ? row : (listScroll.isHidden ? (gridRow ?? selectedPresetRows().first ?? -1) : table.selectedRow)
        let p: PresetItem? = model.isShowingPresets ? preset(atRow: presetRow) : nil
        let template: TextTemplateCatalog.Entry? = model.isShowingPresets && templates.indices.contains(presetRow) ? templates[presetRow] : nil
        let entry = p.map(model.entry(for:)) ?? template.map(model.entry(for:))
        let items = clickedItems(clickedRow: row)
        let audio = items.first { $0.entry.kind == .audio }
        let ctx = LibraryMenus.Context(
            showsPresets: model.isShowingPresets, hasAudio: audio != nil, canWhoosh: onWhoosh != nil,
            presetIsTitleBlock: p?.kind.isTitleInsert == true, presetIsEffect: p?.kind == .effect, hasPreset: p != nil,
            relativeDefault: PresetApplyModeSetting.load() == .relative,
            organize: entry.map { e in
                let def = p.map { PresetCategory.defaultCategory(for: $0.kind) } ?? template.map { $0.isCTA ? .social : PresetCategory.inferred(fromName: $0.name) } ?? .other
                return LibraryMenus.Organize(isFavorite: e.meta.isFavorite, category: e.category, defaultCategory: def, tags: e.tags)
            })
        // Presets in the selection when the click is inside it, else the clicked one.
        let selectedRows = selectedPresetRows()
        let selected = selectedRows.contains(presetRow) ? selectedRows.compactMap { preset(atRow: $0) } : (p.map { [$0] } ?? [])
        let key = entry?.key
        return LibraryMenus.itemItems(ctx) { [weak self] a in
            guard let self else { return }
            switch a {
            case .exportPack:
                let name = Set(selected.compactMap(\.pack)).count == 1 ? (selected.first?.pack ?? "") : ""
                LibraryPackFlow.export(ids: selected.map(\.id), suggestedName: name, model: self.model, window: self.window)
            case .importPack: LibraryPackFlow.chooseAndImport(model: self.model, window: self.window)
            default: self.runMenu(a, items: items, audio: audio, preset: p, key: key)
            }
        }
    }

    private func runMenu(_ a: LibraryMenus.Action, items: [LibraryItem], audio: LibraryItem?, preset p: PresetItem?, key: String? = nil) {
        switch a {
        case .rescan, .removeFolder: break
        case .toggleFavorite: for item in items { model.toggleFavorite(item.id) }
        case .whoosh:
            guard let item = audio else { return }
            if model.sfxSounds.contains(item.url) { model.chooseWhoosh(item.url) }   // the Sequence menu command reuses it
            onWhoosh?(item.url)
        case .addToSFX:
            let urls = items.filter { $0.entry.kind == .audio }.map(\.url)
            Task { [model] in
                await model.addToSFXBin(urls)
                if let f = model.sfxFolder { model.selection = .folder(f.id) }
            }
        case .reveal: NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
        case .insertTitleBlock: if let p, p.kind.isTitleInsert { model.recordPresetUse(PresetKey.user(p.id)); model.onInsertTitleBlock?(p, nil) }
        case .applyPreset: if let p { model.recordPresetUse(PresetKey.user(p.id)); model.onApplyPreset?(p, nil) }
        case .applyAbsolute: if let p { model.recordPresetUse(PresetKey.user(p.id)); model.onApplyPreset?(p, .absolute) }
        case .applyRelative: if let p { model.recordPresetUse(PresetKey.user(p.id)); model.onApplyPreset?(p, .relative) }
        case .toggleFavoritePreset: if let key { model.toggleFavoritePreset(key) }
        case .setCategory(let c): if let key { model.setPresetCategory(key, c) }
        case .toggleTag(let t): if let key { model.togglePresetTag(key, t) }
        case .toggleDefaultApply:
            PresetApplyModeSetting.save(PresetApplyModeSetting.load() == .relative ? .absolute : .relative)
        case .exportPack, .importPack: break      // handled in itemMenuItems
        case .exportPreset: if let p { exportPreset(p) }
        case .importPresets: importPresets()
        case .deletePreset: if let p { deletePreset(p) }
        }
    }

    private func exportPreset(_ p: PresetItem) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PresetFile.suggestedFileName(for: p.name)
        if let type = UTType(filenameExtension: PresetFile.fileExtension) { panel.allowedContentTypes = [type] }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let self else { return }
                Task { @MainActor in
                    do { try await self.model.exportPreset(p.id, to: url) } catch { self.showError(error) }
                }
            }
        }
    }

    private func deletePreset(_ p: PresetItem) {
        guard let window else { return }
        let alert = SQDialog()
        alert.messageText = SQL10n.format("Delete “%@”?", p.name)
        alert.informativeText = "The preset is removed from the Library. Clips that use it keep their keyframes."
        alert.addButton("Delete", role: .destructive)
        alert.addButton("Cancel", role: .cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .first, let self else { return }
                Task { @MainActor in await self.model.deletePreset(p.id) }
            }
        }
    }

    private func importPresets() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: PresetFile.fileExtension) { panel.allowedContentTypes = [type] }
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self else { return }
                let urls = panel.urls
                Task { @MainActor in
                    let failures = await self.model.importPresets(from: urls)
                    if let first = failures.first { self.showError(first.error, file: first.url) }
                }
            }
        }
    }

    private func showError(_ error: any Error, file: URL? = nil) {
        guard let window else { return }
        let alert = SQDialog()
        alert.messageText = file.map { "“\($0.lastPathComponent)” could not be imported." } ?? "The preset could not be saved."
        switch error {
        case LibraryStoreError.newerFormat: alert.informativeText = "It was made by a newer version of Sequence Studio."
        case PresetFileError.notAPreset: alert.informativeText = "It is not a Sequence Studio preset."
        case PresetFileError.damagedPayload: alert.informativeText = "The preset inside the file is damaged."
        default: alert.informativeText = SQL10n.errorText(error)
        }
        alert.beginSheetModal(for: window)
    }
}
