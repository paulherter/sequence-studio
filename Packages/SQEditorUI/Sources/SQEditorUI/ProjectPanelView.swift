import AppKit
import Observation
import SQCore

/// Pasteboard type carrying the item IDs dragged out of the Project panel (see `ProjectPanelModel.encodeItems`).
public extension NSPasteboard.PasteboardType {
    static let sequenceMediaIDs = NSPasteboard.PasteboardType(ProjectPanelModel.pasteboardTypeName)
}

/// Outline item: a stable object per bin item so expansion state survives reloads.
private final class Node: NSObject {
    let ref: BinItemRef
    init(_ ref: BinItemRef) { self.ref = ref }
}

/// Label colour chip at the left of a row.
private final class SwatchView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
    }
}

@MainActor
private enum IconImages {
    private static var cache: [ProjectItemIcon: NSImage] = [:]

    /// Template image of the base symbol with the optional badge composed into the bottom-right corner.
    static func image(_ icon: ProjectItemIcon) -> NSImage? {
        if let c = cache[icon] { return c }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        guard let base = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        var result = base
        if let badgeName = icon.badge,
           let badge = NSImage(systemSymbolName: badgeName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .bold)) {
            let size = NSSize(width: 16, height: 14)
            let composed = NSImage(size: size, flipped: false) { rect in
                let b = base.size
                base.draw(in: NSRect(x: 0, y: rect.height - b.height, width: b.width, height: b.height))
                let bs = badge.size
                let badgeRect = NSRect(x: rect.width - bs.width, y: 0, width: bs.width, height: bs.height)
                // Knock out a halo so the badge reads against the base symbol.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                badge.draw(in: badgeRect)
                return true
            }
            composed.isTemplate = true
            result = composed
        }
        cache[icon] = result
        return result
    }

    /// Menu chip for a label colour.
    static func swatch(_ l: LabelColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            Theme.hex(l.rgb).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5).fill()
            return true
        }
    }
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
    private var layout: ProjectColumnLayout
    private var rebuildingColumns = false
    private let defaults: UserDefaults
    /// Double-click: a media item opens in the Source monitor, a sequence becomes the active one.
    public var onOpenMedia: ((MediaRef.ID) -> Void)?
    public var onOpenSequence: ((Timeline.ID) -> Void)?
    /// Context menu and drag actions that need the session: Insert / Overwrite, New Sequence From Clip, Replace Footage.
    public var onPlace: (([MediaRef.ID], ThreePointMode) -> Void)?
    public var onNewSequenceFromClip: ((MediaRef.ID) -> Void)?
    public var onNewSequence: (() -> Void)?
    public var onReplaceFootage: ((MediaRef.ID) -> Void)?
    public var onImportRequest: (() -> Void)?
    /// Double-click on a hover-scrubbed icon opens the clip at the hovered time (Premiere); nil time = from the start.
    public var onOpenMediaAt: ((MediaRef.ID, Time?) -> Void)?
    /// One-line messages (a delete that was blocked, Find results): the host shows them in its status bar.
    public var onNotice: ((String) -> Void)?
    /// Cmd+P without a hovered picture: the clip and time of the Source monitor, when it shows one of the selected clips.
    public var sourcePosition: (() -> (MediaRef.ID, Time)?)?
    public enum ViewMode: String, Sendable { case list, icons }
    public private(set) var viewMode: ViewMode
    private let grid: ProjectIconView
    private let viewToggle = NSSegmentedControl()
    private let sizeSlider = NSSlider()
    private let upButton = NSButton()
    private let binLabel = NSTextField(labelWithString: "")

    public init(model: ProjectPanelModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        self.layout = ProjectColumnLayout.load(from: defaults)
        self.viewMode = ViewMode(rawValue: defaults.string(forKey: "ProjectPanel.viewMode") ?? "") ?? .list
        self.grid = ProjectIconView(model: model)
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        build()
        applyMode()
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

        rebuildColumns()
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = Theme.Metrics.listRow
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.backgroundColor = Theme.Colors.content
        outline.usesAlternatingRowBackgroundColors = false
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.style = .plain
        outline.indentationPerLevel = 14
        outline.registerForDraggedTypes([.fileURL, .sequenceMediaIDs])
        outline.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.onDelete = { [weak self] in self?.deleteSelection() }
        outline.onReturn = { [weak self] in self?.renameSelection() }
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        outline.headerView?.menu = headerMenu
        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged(_:)),
                                               name: NSOutlineView.columnDidResizeNotification, object: outline)
        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged(_:)),
                                               name: NSOutlineView.columnDidMoveNotification, object: outline)

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        grid.translatesAutoresizingMaskIntoConstraints = false
        wireGrid()
        viewToggle.segmentCount = 2
        viewToggle.trackingMode = .selectOne
        viewToggle.segmentStyle = .texturedRounded
        for (i, (name, tip)) in [("list.bullet", "List view"), ("square.grid.2x2", "Icon view")].enumerated() {
            viewToggle.setImage(NSImage(systemSymbolName: name, accessibilityDescription: tip), forSegment: i)
            viewToggle.setWidth(26, forSegment: i)
            viewToggle.setToolTip(tip, forSegment: i)
        }
        viewToggle.selectedSegment = viewMode == .list ? 0 : 1
        viewToggle.target = self; viewToggle.action = #selector(viewModeChanged)
        viewToggle.controlSize = .small
        viewToggle.translatesAutoresizingMaskIntoConstraints = false
        viewToggle.setAccessibilityLabel("View")
        sizeSlider.minValue = 70; sizeSlider.maxValue = 220; sizeSlider.doubleValue = Double(grid.thumbSize)
        sizeSlider.controlSize = .mini
        sizeSlider.target = self; sizeSlider.action = #selector(sizeChanged)
        sizeSlider.toolTip = "Thumbnail size"
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        upButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Up one level")
        upButton.isBordered = false
        upButton.bezelStyle = .accessoryBarAction
        upButton.contentTintColor = Theme.Colors.label2
        upButton.toolTip = "Up one level"
        upButton.target = self; upButton.action = #selector(goUp)
        upButton.translatesAutoresizingMaskIntoConstraints = false
        binLabel.font = Theme.Fonts.small
        binLabel.textColor = Theme.Colors.label2
        binLabel.lineBreakMode = .byTruncatingHead
        binLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search); addSubview(scroll); addSubview(grid); addSubview(status)
        addSubview(viewToggle); addSubview(sizeSlider); addSubview(upButton); addSubview(binLabel)
        let g = Theme.Spacing.sm
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: g),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: g),
            search.trailingAnchor.constraint(equalTo: viewToggle.leadingAnchor, constant: -g),
            viewToggle.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            viewToggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -g),
            grid.topAnchor.constraint(equalTo: scroll.topAnchor), grid.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), grid.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            upButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: g),
            upButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            binLabel.leadingAnchor.constraint(equalTo: upButton.trailingAnchor, constant: 2),
            binLabel.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            binLabel.trailingAnchor.constraint(lessThanOrEqualTo: sizeSlider.leadingAnchor, constant: -g),
            sizeSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -g),
            sizeSlider.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            sizeSlider.widthAnchor.constraint(equalToConstant: 90),
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
        grid.reload()
        updateBinLabel()
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
        guard let n = item as? Node, let column, let col = ProjectPanelModel.Column(rawValue: column.identifier.rawValue) else { return nil }
        let id = column.identifier
        let cell = o.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        var offline = false
        if case .media(let m) = n.ref {
            guard model.project.media(m) != nil else { return nil }
            offline = model.isOffline(m)
        }
        cell.textField?.stringValue = model.cellText(col, n.ref)
        if col == .name {
            cell.imageView?.image = IconImages.image(model.icon(of: n.ref))
            cell.imageView?.contentTintColor = offline ? Theme.Colors.red : Theme.Colors.label2
            (cell.subviews.compactMap { $0 as? SwatchView }.first)?.color = Theme.hex(model.label(of: n.ref).rgb)
            cell.textField?.font = Theme.Fonts.smallName
            cell.textField?.isEditable = false     // Return / menu start a rename; a double-click opens the item
            cell.textField?.textColor = offline ? Theme.Colors.red : Theme.Colors.label
        } else {
            cell.textField?.font = Theme.Fonts.small
            cell.textField?.textColor = offline ? Theme.Colors.red : Theme.Colors.label2
        }
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
            let sw = SwatchView()
            sw.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(sw)
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv); cell.imageView = iv
            NSLayoutConstraint.activate([
                sw.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.xxs),
                sw.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                sw.widthAnchor.constraint(equalToConstant: 8),
                sw.heightAnchor.constraint(equalToConstant: 12),
                iv.leadingAnchor.constraint(equalTo: sw.trailingAnchor, constant: 5),
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

    // MARK: Columns

    private func rebuildColumns() {
        rebuildingColumns = true
        defer { rebuildingColumns = false }
        for c in outline.tableColumns { outline.removeTableColumn(c) }
        for col in layout.visible {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = col.title
            c.width = layout.width(of: col); c.minWidth = col.minWidth
            c.headerCell.font = Theme.Fonts.mini
            c.sortDescriptorPrototype = NSSortDescriptor(key: col.rawValue, ascending: true)
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        if let sc = model.sortColumn, layout.isVisible(sc) {
            outline.sortDescriptors = [NSSortDescriptor(key: sc.rawValue, ascending: model.sortAscending)]
        } else {
            outline.sortDescriptors = []
            if model.sortColumn != nil { model.setSort(nil, ascending: true) }
        }
    }

    /// Reads the order and widths back from the table and saves them per user.
    @objc private func columnsChanged(_ note: Notification) {
        guard !rebuildingColumns else { return }
        var order = outline.tableColumns.compactMap { ProjectPanelModel.Column(rawValue: $0.identifier.rawValue) }
        if order.first != .name, let i = outline.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) {
            // Name stays first: undo a move across it.
            rebuildingColumns = true
            outline.moveColumn(i, toColumn: 0)
            rebuildingColumns = false
            order = outline.tableColumns.compactMap { ProjectPanelModel.Column(rawValue: $0.identifier.rawValue) }
        }
        var l = ProjectColumnLayout(visible: order, widths: layout.widths)
        for c in outline.tableColumns {
            if let col = ProjectPanelModel.Column(rawValue: c.identifier.rawValue) { l.setWidth(c.width, for: col) }
        }
        layout = l
        layout.save(to: defaults)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let col = ProjectPanelModel.Column(rawValue: raw) else { return }
        layout.toggle(col)
        layout.save(to: defaults)
        rebuildColumns()
        outline.reloadData()
    }

    @objc private func resetColumns() {
        layout = .defaults
        layout.save(to: defaults)
        rebuildColumns()
        outline.reloadData()
    }

    private func populateHeaderMenu(_ menu: NSMenu) {
        for col in ProjectPanelModel.Column.allCases where col != .name {
            let it = menu.addItem(withTitle: col.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = col.rawValue
            it.state = layout.isVisible(col) ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Reset Columns", action: #selector(resetColumns), keyEquivalent: "").target = self
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
        tf.isEditable = false
        if !model.rename(n.ref, to: tf.stringValue) { reload() }   // empty or unchanged: restore the old name
    }

    private func renameSelection() {
        if viewMode == .icons { grid.beginRenameSelected(); return }
        let row = outline.selectedRow
        guard row >= 0 else { return }
        beginRename(row: row)
    }

    private func beginRename(row: Int) {
        (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.isEditable = true
        outline.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? Node else { return }
        switch n.ref {
        case .media(let id): onOpenMedia?(id)
        case .sequence(let id): onOpenSequence?(id)
        case .bin: if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        }
    }

    /// Selects a media item (expanding its bins) and scrolls it into view.
    public func reveal(media id: MediaRef.ID) {
        model.searchText = ""
        search.stringValue = ""
        if let parent = model.project.rootBin.parent(of: .media(id)), parent != model.project.rootBin.id {
            var chain: [Bin.ID] = [parent]
            while let up = model.project.rootBin.parent(of: .bin(chain.last!)), up != model.project.rootBin.id { chain.append(up) }
            for b in chain.reversed() { if let n = nodes[.bin(b)] { outline.expandItem(n) } }
        }
        guard let n = nodes[.media(id)] else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// Selected items of the visible view.
    private var selectedRefs: [BinItemRef] {
        viewMode == .icons ? grid.selection : outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.ref }
    }

    private func deleteSelection() {
        let refs = selectedRefs
        guard !refs.isEmpty else { return }
        let r = model.delete(refs)
        if let message = r.message { onNotice?(message) }
        if !r.changed { NSSound.beep() }
    }

    // MARK: Hover scrub, poster frame, Find (Cmd+F)

    /// Hover Scrub on/off (Shift+H, Project panel). While off, holding Shift scrubs temporarily.
    public var hoverScrubEnabled: Bool {
        get { grid.hoverScrubEnabled }
        set { grid.hoverScrubEnabled = newValue }
    }

    /// `I` / `O` over a hovered thumbnail. False when nothing is hovered (the key then goes on to the default command).
    public func handleHoverMark(isIn: Bool) -> Bool { viewMode == .icons && grid.handleHoverMark(isIn: isIn) }

    /// Cmd+P: poster frame of the selected clips = the hovered frame, else the Source monitor's frame of that clip.
    /// Option+P (`clear`) goes back to the automatic poster.
    public func setPosterFrame(clear: Bool) {
        let ids = selectedMediaIDs
        guard !ids.isEmpty else { onNotice?("Select a clip first."); return }
        if clear { _ = model.setPoster(nil, for: ids.map { .media($0) }); return }
        if viewMode == .icons, let t = grid.hoveredTime, let h = grid.hoveredMedia, ids.contains(h) {
            _ = model.setPoster(t, for: [.media(h)]); return
        }
        if let (id, t) = sourcePosition?(), ids.contains(id) { _ = model.setPoster(t, for: [.media(id)]); return }
        onNotice?("Hover a clip in icon view (or open it in the Source monitor) and press Cmd+P.")
    }

    /// Cmd+F: asks for name / label / offline criteria and selects every match.
    public func showFind() {
        let alert = NSAlert()
        alert.messageText = "Find"
        alert.informativeText = "Select the clips and sequences that match."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = "Text"
        let which = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 110, height: 24), pullsDown: false)
        which.addItems(withTitles: ["Name", "Label"])
        let offline = NSButton(checkboxWithTitle: "Offline media only", target: nil, action: nil)
        let stack = NSStackView(views: [field, which, offline])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 90)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Find")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let c = ProjectPanelModel.FindCriteria(text: field.stringValue, field: which.indexOfSelectedItem == 1 ? .label : .name,
                                               offlineOnly: offline.state == .on)
        selectFound(c)
    }

    /// Selects the matches of `criteria` (and shows them); reports the count.
    public func selectFound(_ c: ProjectPanelModel.FindCriteria) {
        let found = model.find(c)
        guard !found.isEmpty else { onNotice?(c.isEmpty ? "Nothing to find." : "No match."); NSSound.beep(); return }
        model.searchText = ""
        if viewMode == .icons {
            let here = Set(grid.items)
            let inView = found.filter(here.contains)
            grid.setSelection(inView.isEmpty ? found : inView)
        } else {
            for ref in found { if case .media(let id) = ref, let parent = model.project.rootBin.parent(of: .media(id)) { expandChain(to: parent) } }
            let rows = IndexSet(found.compactMap { nodes[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first { outline.scrollRowToVisible(first) }
        }
        onNotice?("\(found.count) match\(found.count == 1 ? "" : "es").")
    }

    private func expandChain(to bin: Bin.ID) {
        var chain: [Bin.ID] = [bin]
        while let up = model.project.rootBin.parent(of: .bin(chain.last!)), up != model.project.rootBin.id { chain.append(up) }
        for b in chain.reversed() { if let n = nodes[.bin(b)] { outline.expandItem(n) } }
    }

    /// Media items selected in the outline, in row order (for Insert / Overwrite).
    public var selectedMediaIDs: [MediaRef.ID] {
        if viewMode == .icons { return grid.selection.compactMap { if case .media(let id) = $0 { id } else { nil } } }
        return outline.selectedRowIndexes.compactMap { row in
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
        return pasteboardItem(n.ref)
    }

    private func pasteboardItem(_ ref: BinItemRef) -> NSPasteboardItem {
        let pb = NSPasteboardItem()
        pb.setString(ProjectPanelModel.encodeItems([ref]), forType: .sequenceMediaIDs)
        if case .media(let id) = ref, let m = model.project.media(id) {
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

    private func dropOperation(_ info: NSDraggingInfo, target: Bin) -> NSDragOperation {
        switch model.classifyDrop(items: droppedItems(info), files: droppedFiles(info)) {
        case .move(let items):
            for case .bin(let id) in items {
                if let moving = model.project.bin(id), moving.bin(target.id) != nil { return [] }
            }
            return .move
        case .importFiles: return .copy
        case .none: return []
        }
    }

    public func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                            proposedChildIndex index: Int) -> NSDragOperation {
        let target = targetBin(item)
        if bin(of: item) == nil {
            // Drops on a leaf go into its bin (as "on item" so no insertion line is drawn).
            let pn = target.id == model.project.rootBin.id ? nil : nodes[.bin(target.id)]
            o.setDropItem(pn, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        switch model.classifyDrop(items: droppedItems(info), files: droppedFiles(info)) {
        case .move(let items):
            for case .bin(let id) in items {
                if let moving = model.project.bin(id), moving.bin(target.id) != nil { return [] }   // into itself/descendant
            }
            return .move
        case .importFiles: return .copy
        case .none: return []
        }
    }

    public func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let destBin = targetBin(item)
        switch model.classifyDrop(items: droppedItems(info), files: droppedFiles(info)) {
        case .none: return false
        case .move(let items):
            var at: Int?
            if index >= 0, model.sortColumn == nil, model.searchText.isEmpty {
                // Model index counts the children after the moved items were removed.
                let before = destBin.children.prefix(index).filter { items.contains($0.ref) }.count
                at = index - before
            }
            // Dropped back where it came from: nothing to do, but not a failed drop either.
            _ = model.move(items, to: destBin.id, at: at)
            return true
        case .importFiles(let files):
            model.currentBin = destBin.id
            importURLs(files)
            return true
        }
    }

    // MARK: Icon view

    private func wireGrid() {
        grid.onOpen = { [weak self] ref in
            guard let self else { return }
            switch ref {
            case .media(let id): if let open = onOpenMediaAt { open(id, grid.hoveredTime) } else { onOpenMedia?(id) }
            case .sequence(let id): onOpenSequence?(id)
            case .bin(let id): model.browseBin = id; model.currentBin = id; grid.setSelection([])
            }
        }
        grid.onDelete = { [weak self] in self?.deleteSelection() }
        grid.onHoverMark = { [weak self] isIn, id, t in _ = self?.model.markFromHover(isIn: isIn, media: id, time: t) }
        grid.onRename = { [weak self] ref, name in
            guard let self else { return }
            if !model.rename(ref, to: name) { reload() }
        }
        grid.pasteboardWriter = { [weak self] ref in self?.pasteboardItem(ref) }
        grid.menuFill = { [weak self] menu, targets in self?.fillMenu(menu, targets: targets) }
        grid.validateDrop = { [weak self] info, bin in
            guard let self, let b = model.project.bin(bin) else { return [] }
            return dropOperation(info, target: b)
        }
        grid.onDropOnto = { [weak self] info, bin in
            guard let self, model.project.bin(bin) != nil else { return false }
            switch model.classifyDrop(items: droppedItems(info), files: droppedFiles(info)) {
            case .none: return false
            case .move(let items): _ = model.move(items, to: bin, at: nil); return true
            case .importFiles(let files): model.currentBin = bin; importURLs(files); return true
            }
        }
    }

    /// Drops the thumbnail of a relinked or replaced file so the next draw reads the new one.
    public func forgetThumbnail(_ id: MediaRef.ID) { grid.forgetThumbnail(id); grid.reload() }

    @objc private func viewModeChanged() {
        viewMode = viewToggle.selectedSegment == 0 ? .list : .icons
        defaults.set(viewMode.rawValue, forKey: "ProjectPanel.viewMode")
        if viewMode == .icons { model.browseBin = model.project.rootBin.id }
        applyMode()
        reload()
    }

    @objc private func sizeChanged() { grid.thumbSize = CGFloat(sizeSlider.doubleValue); grid.reload() }

    @objc private func goUp() {
        guard let parent = model.project.rootBin.parent(of: .bin(model.browseBin)) else { return }
        model.browseBin = parent
        model.currentBin = parent
    }

    private func applyMode() {
        let icons = viewMode == .icons
        scroll.isHidden = icons
        grid.isHidden = !icons
        sizeSlider.isHidden = !icons
        upButton.isHidden = !icons
        binLabel.isHidden = !icons
        status.isHidden = icons
        updateBinLabel()
    }

    private func updateBinLabel() {
        guard viewMode == .icons else { return }
        let b = model.project.bin(model.browseBin) ?? model.project.rootBin
        binLabel.stringValue = b.id == model.project.rootBin.id ? "\(model.project.media.count) items" : b.name
        upButton.isEnabled = b.id != model.project.rootBin.id
    }

    // MARK: Context menu

    private var menuTargets: [BinItemRef] = []

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === outline.headerView?.menu { populateHeaderMenu(menu); return }
        let clicked = outline.clickedRow
        if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
            outline.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        let rows = clicked >= 0 ? outline.selectedRowIndexes : []
        fillMenu(menu, targets: rows.compactMap { (outline.item(atRow: $0) as? Node)?.ref })
    }

    /// Premiere's three Project menus in one place: empty area, bin, item. Entries for features we do not have are left out.
    private func fillMenu(_ menu: NSMenu, targets: [BinItemRef]) {
        menuTargets = targets
        func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
            let it = menu.addItem(withTitle: title, action: sel, keyEquivalent: "")
            it.target = self
            it.isEnabled = enabled
        }
        let media: [MediaRef.ID] = targets.compactMap { if case .media(let id) = $0 { id } else { nil } }
        let hasBin = targets.contains { if case .bin = $0 { true } else { false } }
        let hasSeq = targets.contains { if case .sequence = $0 { true } else { false } }
        if targets.isEmpty {
            add("New Bin", #selector(menuNewBin))
            add("New Sequence…", #selector(menuNewSequence))
            menu.addItem(.separator())
            add("Import…", #selector(menuImport))
            menu.addItem(.separator())
            add("Find…", #selector(menuFind))
            if viewMode == .icons {
                add("Hover Scrub", #selector(menuToggleHoverScrub))
                menu.items.last?.state = hoverScrubEnabled ? .on : .off
            }
            return
        }
        let online = !media.isEmpty && media.allSatisfy { !model.isOffline($0) }
        if !media.isEmpty && !hasBin && !hasSeq {
            add("Open in Source Monitor", #selector(menuOpenSource), enabled: media.count == 1 && online)
            menu.addItem(.separator())
            add("Insert", #selector(menuInsert), enabled: online)
            add("Overwrite", #selector(menuOverwrite), enabled: online)
            add("New Sequence From Clip", #selector(menuSequenceFromClip), enabled: media.count == 1 && online)
            menu.addItem(.separator())
        } else if hasSeq && !hasBin && media.isEmpty {
            add("Open in Timeline", #selector(menuOpenSequence), enabled: targets.count == 1)
            menu.addItem(.separator())
        }
        if hasBin && targets.count == 1 { add("New Bin", #selector(menuNewBin)); menu.addItem(.separator()) }
        add("Rename", #selector(menuRename), enabled: targets.count == 1)
        add("Delete", #selector(menuDelete), enabled: true)
        if media.count == 1, !hasBin, !hasSeq, model.project.media(media[0])?.posterTime != nil {
            add("Clear Poster Frame", #selector(menuClearPoster))
        }
        if targets.contains(where: { if case .bin = $0 { false } else { true } }) {
            menu.addItem(.separator())
            addLabelItems(to: menu)
        }
        if !media.isEmpty {
            menu.addItem(.separator())
            add("Reveal in Finder", #selector(menuReveal))
            if media.count == 1 {
                add(model.isOffline(media[0]) ? "Link Media…" : "Replace Footage…", #selector(menuReplaceFootage))
            }
        }
    }

    @objc private func menuNewSequence() { onNewSequence?() }
    @objc private func menuImport() { onImportRequest?() ?? runImportPanel() }
    @objc private func menuOpenSource() { if let id = selectedMediaIDs.first ?? mediaTargets.first { onOpenMedia?(id) } }
    @objc private func menuOpenSequence() { if case .sequence(let id)? = menuTargets.first { onOpenSequence?(id) } }
    @objc private func menuInsert() { onPlace?(mediaTargets, .insert) }
    @objc private func menuOverwrite() { onPlace?(mediaTargets, .overwrite) }
    @objc private func menuSequenceFromClip() { if let id = mediaTargets.first { onNewSequenceFromClip?(id) } }
    @objc private func menuReplaceFootage() { if let id = mediaTargets.first { onReplaceFootage?(id) } }
    private var mediaTargets: [MediaRef.ID] { menuTargets.compactMap { if case .media(let id) = $0 { id } else { nil } } }

    private func addLabelItems(to menu: NSMenu) {
        let sub = NSMenu(title: "Label")
        let current = Set(menuTargets.filter { if case .bin = $0 { false } else { true } }.map { model.label(of: $0) })
        for l in LabelColor.allCases {
            let it = sub.addItem(withTitle: l.displayName, action: #selector(menuSetLabel(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.rawValue
            it.image = IconImages.swatch(l)
            it.state = current == [l] ? .on : .off
        }
        let parent = menu.addItem(withTitle: "Label", action: nil, keyEquivalent: "")
        parent.submenu = sub
        if let first = menuTargets.first(where: { if case .bin = $0 { false } else { true } }) {
            let it = menu.addItem(withTitle: "Select Label Group", action: #selector(menuSelectLabelGroup(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = model.label(of: first).rawValue
        }
    }

    @objc private func menuSetLabel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = LabelColor(rawValue: raw) else { return }
        model.setLabel(l, for: menuTargets)
    }

    @objc private func menuSelectLabelGroup(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = LabelColor(rawValue: raw) else { return }
        let rows = IndexSet(model.project.items(withLabel: l).compactMap { nodes[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// Cmd+B: a new bin in the current bin, named in place.
    public func newBin() { menuNewBin() }

    @objc private func menuNewBin() {
        if viewMode == .icons { model.currentBin = model.browseBin }
        guard let id = model.newBin(name: "Untitled Bin") else { return }
        reload()
        if viewMode == .icons { grid.setSelection([.bin(id)]); grid.beginRenameSelected(); return }
        if let n = nodes[.bin(id)] {
            // Expand the parent so the new row is visible, then start editing.
            if let parent = model.project.rootBin.parent(of: .bin(id)), let pn = nodes[.bin(parent)] { outline.expandItem(pn) }
            let row = outline.row(forItem: n)
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
                beginRename(row: row)
            }
        }
    }
    @objc private func menuRename() { renameSelection() }
    @objc private func menuDelete() { deleteSelection() }
    @objc private func menuClearPoster() { _ = model.setPoster(nil, for: menuTargets) }
    @objc private func menuFind() { showFind() }
    @objc private func menuToggleHoverScrub() { hoverScrubEnabled.toggle() }
    @objc private func menuReveal() {
        let urls = menuTargets.compactMap { r -> URL? in
            if case .media(let id) = r, let m = model.project.media(id) { return URL(fileURLWithPath: m.path) }
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
