import AppKit
import Observation
import SSCore

/// Pasteboard type carrying the item IDs dragged out of the Project panel (see `ProjectPanelModel.encodeItems`).
public extension NSPasteboard.PasteboardType {
    static let sequenceMediaIDs = NSPasteboard.PasteboardType(ProjectPanelModel.pasteboardTypeName)
}

/// Outline item: a stable object per bin item so expansion state survives reloads.
private final class Node: NSObject {
    let ref: BinItemRef
    init(_ ref: BinItemRef) { self.ref = ref }
}

private final class PanelOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: onDelete?()          // delete, forward delete
        case 36, 76: onReturn?()           // return, enter: rename
        default: super.keyDown(with: event)
        }
    }
}

private final class PanelRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 0)
        (isEmphasized ? Theme.Colors.accentTint : Theme.Colors.selection).setFill()
        NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
    }
    override var isOpaque: Bool { false }
}

/// Project panel: bins and media in an NSOutlineView (Name / Format / Duration), import by dragging files in,
/// drag items out, inline rename, context menu. All edits go through `ProjectPanelModel`.
@MainActor
public final class ProjectPanelView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    public let model: ProjectPanelModel
    private let outline = PanelOutlineView()
    private let scroll = NSScrollView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private var nodes: [BinItemRef: Node] = [:]
    private var tracking = true
    private var lastRevision = -1

    public init(model: ProjectPanelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        build()
        reload()
        observe()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func build() {
        search.placeholderString = "Search"
        search.font = Theme.Fonts.small
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        status.font = Theme.Fonts.mini
        status.textColor = Theme.Colors.label3
        status.translatesAutoresizingMaskIntoConstraints = false

        let specs: [(ProjectPanelModel.Column, String, CGFloat, CGFloat)] = [
            (.name, "Name", 180, 80), (.format, "Format", 210, 80), (.duration, "Duration", 84, 60)]
        for (col, title, width, minWidth) in specs {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = title
            c.width = width; c.minWidth = minWidth
            c.headerCell.font = Theme.Fonts.mini
            c.sortDescriptorPrototype = NSSortDescriptor(key: col.rawValue, ascending: true)
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = Theme.Metrics.listRow
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.backgroundColor = Theme.Colors.content
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.style = .plain
        outline.indentationPerLevel = 14
        outline.registerForDraggedTypes([.fileURL, .sequenceMediaIDs])
        outline.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.onDelete = { [weak self] in self?.deleteSelection() }
        outline.onReturn = { [weak self] in self?.renameSelection() }
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(search); addSubview(scroll); addSubview(status)
        let g = Theme.Spacing.sm
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: g),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: g),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -g),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: g),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -Theme.Spacing.xs),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: g),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -g),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
        ])
    }

    // MARK: Model sync

    private func observe() {
        withObservationTracking {
            _ = model.revision; _ = model.pendingImports; _ = model.importFailures
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reload()
                self.observe()
            }
        }
    }

    private func reload() {
        lastRevision = model.revision
        let alive = Set(model.project.rootBin.allRefs)
        nodes = nodes.filter { alive.contains($0.key) }
        let selected = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.ref }
        outline.reloadData()
        if model.searchText.isEmpty == false { outline.expandItem(nil, expandChildren: true) }
        let rows = IndexSet(selected.compactMap { nodes[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if model.pendingImports > 0 {
            status.stringValue = "Importing \(model.pendingImports) file\(model.pendingImports == 1 ? "" : "s")…"
            status.textColor = Theme.Colors.label2
        } else if !model.importFailures.isEmpty {
            status.stringValue = "Could not read: " + model.importFailures.joined(separator: ", ")
            status.textColor = Theme.Colors.red
        } else {
            let n = model.project.media.count
            status.stringValue = "\(n) item\(n == 1 ? "" : "s")"
            status.textColor = Theme.Colors.label3
        }
    }

    private func node(_ r: BinItemRef) -> Node {
        if let n = nodes[r] { return n }
        let n = Node(r); nodes[r] = n; return n
    }

    private func bin(of item: Any?) -> Bin? {
        guard let n = item as? Node, case .bin(let id) = n.ref else { return nil }
        return model.project.bin(id)
    }

    // MARK: Data source

    public func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let b = item == nil ? model.project.rootBin : bin(of: item)
        return b.map { model.children(of: $0).count } ?? 0
    }

    public func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let b = item == nil ? model.project.rootBin : bin(of: item)!
        return node(model.children(of: b)[index].ref)
    }

    public func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { bin(of: item) != nil }

    // MARK: Cells

    public func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { PanelRowView() }

    public func outlineView(_ o: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node, let column else { return nil }
        let id = column.identifier
        let cell = o.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        let p = model.project
        var text = "", color = Theme.Colors.label, icon = "doc"
        var offline = false
        switch n.ref {
        case .bin(let b): text = p.rootBin.bin(b)?.name ?? ""; icon = "folder"
        case .sequence(let s): text = p.timelines.first { $0.id == s }?.name ?? ""; icon = "film.stack"
        case .media(let m):
            guard let r = p.media(m) else { return nil }
            offline = model.isOffline(m)
            switch column.identifier.rawValue {
            case "name": text = r.name; icon = r.info?.video == nil ? "waveform" : "film"
            case "format": text = ProjectPanelModel.formatString(r); color = Theme.Colors.label2
            default: text = ProjectPanelModel.durationString(r); color = Theme.Colors.label2
            }
        }
        if column.identifier.rawValue == "name" {
            cell.imageView?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = offline ? Theme.Colors.red : Theme.Colors.label2
            cell.textField?.font = Theme.Fonts.smallName
            cell.textField?.isEditable = true
        } else {
            cell.textField?.font = Theme.Fonts.small
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = offline ? Theme.Colors.red : color
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.drawsBackground = false
        tf.isBordered = false
        tf.delegate = self
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf); cell.textField = tf
        if id.rawValue == "name" {
            let iv = NSImageView()
            iv.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv); cell.imageView = iv
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.xxs),
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: Theme.Spacing.iconToLabel),
            ])
        } else {
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.xs).isActive = true
        }
        NSLayoutConstraint.activate([
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.Spacing.xs),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Selection and sorting

    public func outlineViewSelectionDidChange(_ n: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
        switch node.ref {
        case .bin(let id): model.currentBin = id
        default: model.currentBin = model.project.rootBin.parent(of: node.ref) ?? model.project.rootBin.id
        }
    }

    public func outlineView(_ o: NSOutlineView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        if let d = o.sortDescriptors.first, let key = d.key, let col = ProjectPanelModel.Column(rawValue: key) {
            model.setSort(col, ascending: d.ascending)
        } else {
            model.setSort(nil, ascending: true)
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === search { model.searchText = search.stringValue }
    }

    // MARK: Rename

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, tf !== search else { return }
        let row = outline.row(for: tf)
        guard row >= 0, let n = outline.item(atRow: row) as? Node else { return }
        if !model.rename(n.ref, to: tf.stringValue) { reload() }   // empty or unchanged: restore the old name
    }

    private func renameSelection() {
        let row = outline.selectedRow
        guard row >= 0 else { return }
        outline.editColumn(0, row: row, with: nil, select: true)
    }

    private func deleteSelection() {
        let refs = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.ref }
        guard !refs.isEmpty else { return }
        if !model.delete(refs) { NSSound.beep() }
    }

    /// Media items selected in the outline, in row order (for Insert / Overwrite).
    public var selectedMediaIDs: [MediaRef.ID] {
        outline.selectedRowIndexes.compactMap { row in
            guard case .media(let id)? = (outline.item(atRow: row) as? Node)?.ref else { return nil }
            return id
        }
    }

    // MARK: Import

    /// Shows an open panel and imports the chosen files (Cmd+I).
    public func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    private func importURLs(_ urls: [URL]) {
        let files = urls.flatMap { Self.expand($0) }
        Task { await model.importFiles(files) }
    }

    /// Folders contribute their files (recursively, no hidden files).
    private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (e?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Drag out

    public func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let n = item as? Node else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(ProjectPanelModel.encodeItems([n.ref]), forType: .sequenceMediaIDs)
        if case .media(let id) = n.ref, let m = model.project.media(id) {
            pb.setString(URL(fileURLWithPath: m.path).absoluteString, forType: .fileURL)
        }
        return pb
    }

    // MARK: Drop

    private func droppedItems(_ info: NSDraggingInfo) -> [BinItemRef] {
        (info.draggingPasteboard.pasteboardItems ?? []).flatMap {
            ProjectPanelModel.decodeItems($0.string(forType: .sequenceMediaIDs) ?? "")
        }
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Bin that a drop on `item` lands in; non-bin targets resolve to their parent bin.
    private func targetBin(_ item: Any?) -> Bin {
        if let b = bin(of: item) { return b }
        if let n = item as? Node, let p = model.project.rootBin.parent(of: n.ref), let b = model.project.bin(p) { return b }
        return model.project.rootBin
    }

    public func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                            proposedChildIndex index: Int) -> NSDragOperation {
        let target = targetBin(item)
        if bin(of: item) == nil {
            // Drops on a leaf go into its bin (as "on item" so no insertion line is drawn).
            let pn = target.id == model.project.rootBin.id ? nil : nodes[.bin(target.id)]
            o.setDropItem(pn, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        let internalItems = droppedItems(info)
        if !internalItems.isEmpty {
            for case .bin(let id) in internalItems {
                if let moving = model.project.bin(id), moving.bin(target.id) != nil { return [] }   // into itself/descendant
            }
            return .move
        }
        return droppedFiles(info).isEmpty ? [] : .copy
    }

    public func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let destBin = targetBin(item)
        let items = droppedItems(info)
        if !items.isEmpty {
            var at: Int?
            if index >= 0, model.sortColumn == nil, model.searchText.isEmpty {
                // Model index counts the children after the moved items were removed.
                let before = destBin.children.prefix(index).filter { items.contains($0.ref) }.count
                at = index - before
            }
            return model.move(items, to: destBin.id, at: at)
        }
        let files = droppedFiles(info)
        guard !files.isEmpty else { return false }
        model.currentBin = destBin.id
        importURLs(files)
        return true
    }

    // MARK: Context menu

    private var menuTargets: [BinItemRef] = []

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = outline.clickedRow
        if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
            outline.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        let rows = clicked >= 0 ? outline.selectedRowIndexes : []
        menuTargets = rows.compactMap { (outline.item(atRow: $0) as? Node)?.ref }
        menu.addItem(withTitle: "New Bin", action: #selector(menuNewBin), keyEquivalent: "").target = self
        if !menuTargets.isEmpty {
            menu.addItem(withTitle: "Rename", action: #selector(menuRename), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Delete", action: #selector(menuDelete), keyEquivalent: "").target = self
            if menuTargets.contains(where: { if case .media = $0 { true } else { false } }) {
                menu.addItem(.separator())
                menu.addItem(withTitle: "Reveal in Finder", action: #selector(menuReveal), keyEquivalent: "").target = self
            }
        }
    }

    @objc private func menuNewBin() {
        guard let id = model.newBin(name: "Untitled Bin") else { return }
        reload()
        if let n = nodes[.bin(id)] {
            // Expand the parent so the new row is visible, then start editing.
            if let parent = model.project.rootBin.parent(of: .bin(id)), let pn = nodes[.bin(parent)] { outline.expandItem(pn) }
            let row = outline.row(forItem: n)
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                outline.editColumn(0, row: row, with: nil, select: true)
            }
        }
    }
    @objc private func menuRename() { renameSelection() }
    @objc private func menuDelete() { deleteSelection() }
    @objc private func menuReveal() {
        let urls = menuTargets.compactMap { r -> URL? in
            if case .media(let id) = r, let m = model.project.media(id) { return URL(fileURLWithPath: m.path) }
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
