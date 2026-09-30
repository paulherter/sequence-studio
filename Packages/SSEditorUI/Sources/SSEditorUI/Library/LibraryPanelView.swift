import AppKit
import SSLibrary

/// Re-runs `apply` whenever an @Observable property read inside it changes.
@MainActor
private func trackObservation(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking(apply) {
        Task { @MainActor in trackObservation(apply) }
    }
}

private func symbolName(for kind: LibraryItemKind) -> String {
    switch kind {
    case .video: "film"
    case .audio: "waveform"
    case .image: "photo"
    case .overlay: "square.on.square"
    case .lut: "camera.filters"
    case .font: "textformat"
    case .other: "doc"
    }
}

private func title(for kind: LibraryItemKind) -> String {
    switch kind {
    case .video: "Video"
    case .audio: "Audio"
    case .image: "Image"
    case .overlay: "Overlay"
    case .lut: "LUT"
    case .font: "Font"
    case .other: "Other"
    }
}

private func title(for kind: PresetKind?) -> String {
    switch kind {
    case nil: "All Presets"
    case .textTemplate: "Text Templates"
    case .animatedTextTemplate: "Animated Text"
    case .easing: "Easing"
    case .caption: "Captions"
    case .effect: "Effects"
    }
}

/// Sidebar node. Reference type for NSOutlineView identity.
private final class SidebarNode: NSObject {
    enum Content { case group(String), section(LibrarySection, title: String, symbol: String, offline: Bool) }
    let content: Content
    var children: [SidebarNode] = []
    init(_ content: Content) { self.content = content }
    var section: LibrarySection? { if case .section(let s, _, _, _) = content { s } else { nil } }
}

/// Library panel: sidebar (folders, Favorites, Presets) + grid/list of items.
/// Items are dragged out as file URLs.
@MainActor
public final class LibraryPanelView: NSView {
    private let model: LibraryPanelModel
    private let split = NSSplitView()
    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private let modeControl = NSSegmentedControl(
        images: [NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid")!,
                 NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")!],
        trackingMode: .selectOne, target: nil, action: nil)
    private let sortPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let chipStack = NSStackView()
    private var chipButtons: [LibraryItemKind: NSButton] = [:]
    private let collection = NSCollectionView()
    private let table = NSTableView()
    private let gridScroll = NSScrollView()
    private let listScroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var nodes: [SidebarNode] = []
    private var items: [LibraryItem] = []
    private var presets: [PresetItem] = []
    private var syncingSelection = false
    /// reloadData ends display of every cell; that must not cancel pending previews.
    private var reloading = false

    private static let itemID = NSUserInterfaceItemIdentifier("LibraryGridItem")

    public init(model: LibraryPanelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        build()
        trackObservation { [weak self] in self?.refresh() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor

        // Sidebar
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.menu = makeFolderMenu()
        let sideScroll = NSScrollView()
        sideScroll.documentView = outline
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false
        outline.backgroundColor = .clear

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Folder")!, target: self, action: #selector(addFolder))
        addButton.bezelStyle = .accessoryBarAction
        addButton.isBordered = false
        addButton.toolTip = "Add Folder"
        let sideFooter = NSStackView(views: [addButton, NSView()])
        sideFooter.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let side = NSStackView(views: [sideScroll, sideFooter])
        side.orientation = .vertical
        side.spacing = 0
        side.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        // Toolbar
        search.placeholderString = "Search"
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .texturedRounded
        sortPopUp.addItems(withTitles: ["Name", "Date", "Size"])
        sortPopUp.target = self
        sortPopUp.action = #selector(sortChanged)
        sortPopUp.controlSize = .small
        let topBar = NSStackView(views: [search, sortPopUp, modeControl])
        topBar.spacing = 8
        topBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 4, right: 8)
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        chipStack.spacing = 4
        chipStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 8)
        for kind in LibraryPanelModel.filterKinds {
            let b = NSButton(title: title(for: kind), target: self, action: #selector(chipToggled(_:)))
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = Theme.Fonts.small
            b.tag = LibraryPanelModel.filterKinds.firstIndex(of: kind)!
            chipButtons[kind] = b
            chipStack.addArrangedSubview(b)
        }
        chipStack.addArrangedSubview(NSView())

        // Grid
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 120, height: 98)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collection.collectionViewLayout = layout
        collection.register(LibraryGridItem.self, forItemWithIdentifier: Self.itemID)
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.menu = makeItemMenu()
        gridScroll.documentView = collection
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false

        // List
        for (id, title, width) in [("name", "Name", 240.0), ("kind", "Kind", 80.0), ("size", "Size", 80.0), ("date", "Modified", 120.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 40
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 28
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menu = makeItemMenu()
        table.backgroundColor = .clear
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        emptyLabel.font = Theme.Fonts.small
        emptyLabel.textColor = Theme.Colors.label3
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        let bars = NSStackView(views: [topBar, chipStack])
        bars.orientation = .vertical
        bars.spacing = 0
        bars.alignment = .leading
        for v in [bars, gridScroll, listScroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bars.topAnchor.constraint(equalTo: content.topAnchor),
            bars.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bars.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBar.trailingAnchor.constraint(equalTo: bars.trailingAnchor),
            gridScroll.topAnchor.constraint(equalTo: bars.bottomAnchor),
            listScroll.topAnchor.constraint(equalTo: bars.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        for v in [gridScroll, listScroll] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(side)
        split.addArrangedSubview(content)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }

    // MARK: Refresh (driven by observation)

    private func refresh() {
        // Read everything the view shows so observation tracks it.
        let folders = model.folders
        let selection = model.selection
        let presetMode = model.isShowingPresets
        items = model.items
        presets = model.visiblePresets
        let offline = model.isSelectedFolderOffline
        let viewMode = model.viewMode
        let kinds = model.kindFilter
        _ = model.thumbnails
        _ = model.favorites
        _ = model.presetCount(nil)
        let sortKey = model.sortKey

        rebuildSidebar(folders: folders)
        syncSidebarSelection(selection)
        for (kind, b) in chipButtons { b.state = kinds.contains(kind) ? .on : .off }
        chipStack.isHidden = presetMode
        modeControl.selectedSegment = viewMode == .grid ? 0 : 1
        sortPopUp.selectItem(at: [LibrarySortKey.name, .date, .size].firstIndex(of: sortKey) ?? 0)

        gridScroll.isHidden = viewMode != .grid || presetMode
        listScroll.isHidden = viewMode != .list && !presetMode
        if presetMode {
            setColumns(presetMode: true)
        } else {
            setColumns(presetMode: false)
        }
        reloading = true
        collection.reloadData()
        table.reloadData()
        reloading = false

        let count = presetMode ? presets.count : items.count
        emptyLabel.isHidden = count > 0
        emptyLabel.stringValue = offline ? "Folder is offline"
            : presetMode ? "No presets"
            : selection == .favorites ? "No favorites yet"
            : model.folders.isEmpty ? "Add a folder to get started" : "No items"
    }

    private func setColumns(presetMode: Bool) {
        table.tableColumn(withIdentifier: .init("kind"))?.title = "Kind"
        table.tableColumn(withIdentifier: .init("size"))?.isHidden = presetMode
        table.tableColumn(withIdentifier: .init("date"))?.title = presetMode ? "Created" : "Modified"
    }

    private var lastSidebarSignature: [String] = []

    private func rebuildSidebar(folders: [LibraryFolderRow]) {
        let sig = folders.map { "\($0.id)|\($0.folder.displayName)|\($0.state)" } + ["\(model.presetCount(nil))"]
        guard sig != lastSidebarSignature else { return }
        lastSidebarSignature = sig
        let library = SidebarNode(.group("Library"))
        library.children = [SidebarNode(.section(.favorites, title: "Favorites", symbol: "star", offline: false))]
        let folderGroup = SidebarNode(.group("Folders"))
        folderGroup.children = folders.map {
            SidebarNode(.section(.folder($0.id), title: $0.folder.displayName, symbol: $0.state == .offline ? "externaldrive.badge.xmark" : "folder", offline: $0.state == .offline))
        }
        let presetGroup = SidebarNode(.group("Presets"))
        presetGroup.children = ([nil] + PresetKind.allCases.map { Optional($0) }).map {
            SidebarNode(.section(.presets($0), title: title(for: $0), symbol: "square.stack", offline: false))
        }
        nodes = [library, folderGroup, presetGroup]
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    private func syncSidebarSelection(_ selection: LibrarySection) {
        for n in nodes.flatMap(\.children) where n.section == selection {
            let row = outline.row(forItem: n)
            if row >= 0, outline.selectedRow != row {
                syncingSelection = true
                outline.selectRowIndexes([row], byExtendingSelection: false)
                syncingSelection = false
            }
        }
    }

    // MARK: Actions

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
    @objc private func modeChanged() { model.viewMode = modeControl.selectedSegment == 0 ? .grid : .list }
    @objc private func sortChanged() {
        let key = [LibrarySortKey.name, .date, .size][max(0, sortPopUp.indexOfSelectedItem)]
        if key == model.sortKey { model.ascending.toggle() } else { model.sortKey = key; model.ascending = true }
    }
    @objc private func chipToggled(_ sender: NSButton) { model.toggleKind(LibraryPanelModel.filterKinds[sender.tag]) }

    @objc private func removeSelectedFolder() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, case .folder(let id)? = node.section else { return }
        Task { await model.removeFolder(id) }
    }

    @objc private func rescanSelectedFolder() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, case .folder(let id)? = node.section else { return }
        Task { await model.rescan(id) }
    }

    @objc private func toggleFavoriteFromMenu() {
        for item in clickedItems() { model.toggleFavorite(item.id) }
    }

    @objc private func revealFromMenu() {
        NSWorkspace.shared.activateFileViewerSelecting(clickedItems().map(\.url))
    }

    private func clickedItems() -> [LibraryItem] {
        if !listScroll.isHidden {
            let clicked = table.clickedRow
            var rows = table.selectedRowIndexes
            if clicked >= 0, !rows.contains(clicked) { rows = [clicked] }
            return rows.compactMap { $0 < items.count ? items[$0] : nil }
        }
        return collection.selectionIndexPaths.map(\.item).sorted().compactMap { $0 < items.count ? items[$0] : nil }
    }

    private func makeFolderMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Rescan", action: #selector(rescanSelectedFolder), keyEquivalent: "").target = self
        m.addItem(withTitle: "Remove Folder", action: #selector(removeSelectedFolder), keyEquivalent: "").target = self
        return m
    }

    private func makeItemMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Toggle Favorite", action: #selector(toggleFavoriteFromMenu), keyEquivalent: "").target = self
        m.addItem(withTitle: "Reveal in Finder", action: #selector(revealFromMenu), keyEquivalent: "").target = self
        return m
    }

    // MARK: Item rows

    fileprivate func thumbnailImage(for item: LibraryItem) -> NSImage? {
        guard LibraryPanelModel.previewKind(for: item.entry.kind) == .thumbnail,
              let url = model.thumbnails[item.id] else { return nil }
        return NSImage(contentsOf: url)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
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
    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .group? = (item as? SidebarNode)?.content { true } else { false }
    }
    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.section != nil
    }
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        switch node.content {
        case .group(let t):
            label.stringValue = t.uppercased()
            label.font = Theme.Fonts.mini
            label.textColor = Theme.Colors.label3
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        case .section(_, let t, let symbol, let offline):
            label.stringValue = t
            label.font = Theme.Fonts.small
            label.textColor = offline ? Theme.Colors.label3 : Theme.Colors.label
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = offline ? Theme.Colors.label3 : Theme.Colors.label2
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Spacing.iconToLabel),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }
    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode,
              let section = node.section else { return }
        model.selection = section
    }
    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { nil }
}

// MARK: - Grid

private final class LibraryGridItem: NSCollectionViewItem {
    private let thumb = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let star = NSImageView()

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = Theme.Radius.row
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = Theme.Radius.clip
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = Theme.Colors.content.cgColor
        thumb.contentTintColor = Theme.Colors.label3
        nameField.font = Theme.Fonts.small
        nameField.textColor = Theme.Colors.label
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.alignment = .center
        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite")
        star.contentTintColor = Theme.Colors.yellow
        for s in [thumb, nameField, star] as [NSView] {
            s.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(s)
        }
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            thumb.heightAnchor.constraint(equalToConstant: 66),
            nameField.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            nameField.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            star.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -4),
            star.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 4),
            star.widthAnchor.constraint(equalToConstant: 12),
            star.heightAnchor.constraint(equalToConstant: 12),
        ])
        view = v
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? Theme.Colors.accentTint.cgColor : NSColor.clear.cgColor }
    }

    func configure(name: String, image: NSImage?, symbol: String, favorite: Bool) {
        nameField.stringValue = name
        if let image {
            thumb.image = image
            thumb.imageScaling = .scaleProportionallyUpOrDown
        } else {
            thumb.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .light))
            thumb.imageScaling = .scaleNone
        }
        star.isHidden = !favorite
    }
}

extension LibraryPanelView: NSCollectionViewDataSource, NSCollectionViewDelegate {
    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        model.isShowingPresets ? 0 : items.count
    }
    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath)
        if let cell = cell as? LibraryGridItem, indexPath.item < items.count {
            let item = items[indexPath.item]
            cell.configure(name: item.entry.name, image: thumbnailImage(for: item), symbol: symbolName(for: item.entry.kind), favorite: item.isFavorite)
        }
        return cell
    }
    public func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        if indexPath.item < items.count { model.itemDidAppear(items[indexPath.item]) }
    }
    public func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        if !reloading, indexPath.item < items.count { model.itemDidDisappear(items[indexPath.item].id) }
    }
    public func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        indexPath.item < items.count ? items[indexPath.item].url as NSURL : nil
    }
}

// MARK: - List

extension LibraryPanelView: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        model.isShowingPresets ? presets.count : items.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.font = Theme.Fonts.small
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        var leading = cell.leadingAnchor
        var inset: CGFloat = 0
        if id == "name" {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 36),
                icon.heightAnchor.constraint(equalToConstant: 22),
            ])
            leading = icon.trailingAnchor
            inset = Theme.Spacing.sm
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: inset),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if model.isShowingPresets {
            guard row < presets.count else { return cell }
            let p = presets[row]
            switch id {
            case "name":
                label.stringValue = p.name
                cell.imageView?.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
            case "kind": label.stringValue = title(for: p.kind)
            case "date": label.stringValue = Self.dateFormatter.string(from: p.createdAt)
            default: break
            }
        } else {
            guard row < items.count else { return cell }
            let item = items[row]
            switch id {
            case "name":
                label.stringValue = item.entry.name
                if let img = thumbnailImage(for: item) {
                    cell.imageView?.image = img
                    cell.imageView?.imageScaling = .scaleProportionallyUpOrDown
                } else {
                    cell.imageView?.image = NSImage(systemSymbolName: symbolName(for: item.entry.kind), accessibilityDescription: nil)
                    cell.imageView?.imageScaling = .scaleNone
                    cell.imageView?.contentTintColor = Theme.Colors.label3
                }
                model.itemDidAppear(item)
            case "kind": label.stringValue = title(for: item.entry.kind)
            case "size": label.stringValue = Self.byteFormatter.string(fromByteCount: item.entry.size)
            case "date": label.stringValue = Self.dateFormatter.string(from: item.entry.modified)
            default: break
            }
        }
        return cell
    }

    public func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard !reloading, !model.isShowingPresets, row >= 0, row < items.count else { return }
        model.itemDidDisappear(items[row].id)
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard !model.isShowingPresets, row < items.count else { return nil }
        return items[row].url as NSURL
    }
}
