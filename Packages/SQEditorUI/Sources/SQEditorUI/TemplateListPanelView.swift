import AppKit
import SQCore
import SQText
import SQDrawLibrary

/// Simple list with an "Apply" button and double-click, used by the Text and Effects panels.
/// Rows may be dragged out (`dragType`).
@MainActor
public class TemplateListPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// The row model lives in SQDrawLibrary (shared with the draw panel).
    public typealias Row = EffectsRow

    public var rows: [Row] { didSet { if rows != oldValue { table.reloadData(); grid?.rows = rows; updateEmptyState() } } }
    /// Double-click or the button.
    public var onApply: ((String) -> Void)?
    fileprivate var dragType: NSPasteboard.PasteboardType?
    /// Click on a folder row (Effects panel).
    fileprivate var onFolderToggle: ((String) -> Void)?
    /// The footer button (the Effects panel uses it for "New Folder"); nil = it applies the selection.
    fileprivate var onButton: (() -> Void)?
    /// Context menu items for a row (nil / empty = no menu); `-1` = empty area.
    fileprivate var rowMenu: ((Int) -> [SQMenuItem])?
    /// Something dropped on a user folder row.
    fileprivate var onDropItem: ((String, UUID) -> Void)?
    /// Effects a folder row carries when dragged out (empty = the folder is not draggable as a payload).
    fileprivate var folderDragIDs: ((Row) -> [String])?
    /// A user folder dropped in front of another user folder (nil = at the end).
    fileprivate var onMoveFolder: ((UUID, UUID?) -> Void)?

    private let table = FolderOutlineTableView()
    private let scroll = NSScrollView()
    private let button = SQButton(title: "", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let emptyState = EmptyStateView(title: "")
    /// Present when the panel is searchable (the Effects panel); typing calls `onSearch`.
    fileprivate let searchField = SQSearchField()
    fileprivate var onSearch: ((String) -> Void)?
    /// Grid mode (the Effects panel): chosen in the panel header's "..." menu, persisted under `EffectsPanel.viewMode`.
    fileprivate var grid: EffectsGridView?
    fileprivate let gridScroll = NSScrollView()
    public private(set) var viewMode: EffectsViewMode = .list
    fileprivate let defaults: UserDefaults

    init(rows: [Row], buttonTitle: String, hint: String, label: String, searchable: Bool = false,
         gridCapable: Bool = false, defaults: UserDefaults = .standard) {
        self.rows = rows
        self.defaults = defaults
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 300))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        appearance = NSAppearance(named: .darkAqua)
        let col = NSTableColumn(identifier: .init("row"))
        table.addTableColumn(col)
        table.headerView = nil
        QuietList.style(table, rowHeight: Self.itemRowHeight)
        table.dataSource = self
        table.delegate = self
        table.onFolderClick = { [weak self] row in self?.toggleFolder(row: row) }
        table.onArrowKey = { [weak self] key in self?.handleArrow(key) ?? false }
        table.doubleAction = #selector(apply)
        table.target = self
        table.setAccessibilityLabel(label)
        table.sqItems = { [weak self] row in self?.rowMenu?(row) ?? [] }
        table.registerForDraggedTypes([.sequenceEffectID, .sequenceEffectFolder])
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        button.title = buttonTitle
        button.target = self; button.action = #selector(buttonPressed)
        self.hint.stringValue = hint
        self.hint.font = Theme.Typography.body
        self.hint.textColor = Theme.Colors.label3
        addSubview(scroll); addSubview(self.hint); addSubview(emptyState)
        updateEmptyState()
        if searchable {
            searchField.setQuietPlaceholder("Search " + label.lowercased())
            // Without this NSSearchField waits ~300 ms after the last keystroke before it sends its action.
            searchField.sendsSearchStringImmediately = true
            searchField.target = self; searchField.action = #selector(searchChanged)
            searchField.setAccessibilityLabel("Search \(label)")
            addSubview(searchField)
        }
        if !buttonTitle.isEmpty { addSubview(button) }
        if gridCapable { setUpGrid(label: label) }
    }

    private func setUpGrid(label: String) {
        let g = EffectsGridView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        g.rows = rows
        g.onApply = { [weak self] id in self?.onApply?(id) }
        grid = g
        gridScroll.documentView = g
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = false
        gridScroll.scrollerStyle = .overlay
        addSubview(gridScroll)
        viewMode = EffectsViewMode.load(from: defaults)
        applyMode()
    }

    /// Switches between the outline list and the preview grid (header "..." menu) and remembers it.
    public func setViewMode(_ mode: EffectsViewMode) {
        guard grid != nil, mode != viewMode else { return }
        viewMode = mode
        viewMode.save(to: defaults)
        if let id = (viewMode == .grid ? selectedRowID : grid?.selectedID) { select(id: id) }
        applyMode()
    }

    /// Header "..." of the Effects panel: as List / as Grid (the board has no toggle in the panel body).
    public func showOptions(from sender: NSView) {
        guard grid != nil else { return }
        let items = ["as List", "as Grid"].enumerated().map { i, title in
            SQMenuItem(title: title, isChecked: (viewMode == .grid) == (i == 1)) { [weak self] in self?.setViewMode(i == 1 ? .grid : .list) }
        }
        SQContextMenu.popUp(items: items, at: NSPoint(x: sender.bounds.minX, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY), in: sender)
    }

    private var selectedRowID: String? {
        table.selectedRow >= 0 && rows.indices.contains(table.selectedRow) && !rows[table.selectedRow].isHeader && !rows[table.selectedRow].isFolder ? rows[table.selectedRow].itemID : nil
    }

    private func applyMode() {
        scroll.isHidden = viewMode == .grid
        gridScroll.isHidden = viewMode != .grid
        needsLayout = true
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let pad = Theme.Spacing.md
        let footer: CGFloat = button.superview != nil ? 52 : (hint.stringValue.isEmpty ? 0 : 28)
        hint.frame = CGRect(x: pad, y: 6, width: max(bounds.width - 2 * pad, 0), height: Theme.Row.control)
        button.sizeToFit()
        button.frame.origin = CGPoint(x: pad, y: 28)
        // Search strip = panel header height, field centered in it.
        let top: CGFloat = searchField.superview == nil ? 0 : LibraryPanelView.searchRowHeight
        let fieldH = Theme.Metrics.quietField
        if top > 0 {
            searchField.frame = CGRect(x: Theme.Spacing.sm, y: bounds.height - top + ((top - fieldH) / 2).rounded(),
                                       width: max(bounds.width - 2 * Theme.Spacing.sm, 0), height: fieldH)
        }
        scroll.frame = CGRect(x: 0, y: footer, width: bounds.width, height: max(bounds.height - footer - top, 0))
        emptyState.frame = scroll.frame
        if let grid {
            gridScroll.frame = scroll.frame
            grid.setFrameSize(NSSize(width: gridScroll.contentSize.width, height: grid.frame.height))
            grid.relayout()
        }
    }

    /// Empty list: a search without hits says so and how to go on; an empty list explains where entries come from.
    fileprivate func updateEmptyState() {
        emptyState.isHidden = !rows.isEmpty
        let searching = !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        emptyState.title = searching ? "No results" : "Nothing here yet"
        emptyState.hint = searching ? "Nothing here matches \u{201C}\(searchField.stringValue.trimmingCharacters(in: .whitespaces))\u{201D}." : nil
    }

    @objc private func searchChanged() { onSearch?(searchField.stringValue); updateEmptyState() }
    /// Runs the search as if the user typed `text` (tests, measurements).
    func typeSearch(_ text: String) { searchField.stringValue = text; searchChanged() }

    public var selectedID: String? { viewMode == .grid ? grid?.selectedID : selectedRowID }
    public func select(id: String) {
        grid?.select(id: id)
        if let i = rows.firstIndex(where: { $0.id == id }) { table.selectRowIndexes([i], byExtendingSelection: false) }
    }

    static let disclosureWidth: CGFloat = 12
    func isFolderRow(_ row: Int) -> Bool { rows.indices.contains(row) && rows[row].isFolder }

    @objc private func buttonPressed() { if let onButton { onButton() } else { apply() } }

    @objc private func apply() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard rows.indices.contains(r), !rows[r].isHeader else { return }
        if rows[r].isFolder { return }   // a folder row only opens or closes
        onApply?(rows[r].itemID)
    }

    // MARK: Table

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let cell = NSTableCellView()
        if r.isHeader {
            let t = NSTextField(labelWithString: r.title)
            t.font = Theme.Typography.bodyStrong; t.textColor = Theme.Colors.label2
            t.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(t)
            NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.xs),
                                         t.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            cell.setAccessibilityLabel(r.title)
            return cell
        }
        // v9 `.tree .row`: every folder = chevron, folder icon, name; an effect = "fx" badge, name. 12 pt in `label2`,
        // 12 / 26 / 40 in by depth. No rules, counts or strong titles.
        let flat = onFolderToggle == nil
        let title = NSTextField(labelWithString: r.title)
        title.font = Theme.Typography.list
        title.textColor = Theme.Colors.label2
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        // One line per row (docs/DESIGN-SPEC.md §2): the subtitle only shows as a tooltip.
        if !r.subtitle.isEmpty { cell.sqToolTip = r.subtitle }
        cell.addSubview(title)
        cell.textField = title
        let lead = Self.rowLead(depth: flat ? 0 : r.depth)
        let gap = Theme.Spacing.iconToLabel
        var before: NSView
        if r.isFolder {
            let arrow = DisclosureGlyph(isOpen: r.isExpanded)
            arrow.setAccessibilityLabel(r.isExpanded ? "Close folder" : "Open folder")
            let icon = NSImageView(image: Theme.symbol(.folder, size: 12) ?? NSImage())
            icon.contentTintColor = Theme.Colors.label3
            for v in [arrow, icon] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
            NSLayoutConstraint.activate([
                arrow.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: lead),
                arrow.widthAnchor.constraint(equalToConstant: Self.disclosureWidth),
                arrow.heightAnchor.constraint(equalToConstant: Self.disclosureWidth),
                arrow.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: gap),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            before = icon
        } else if flat {
            // Flat lists keep the symbol of each entry.
            let icon = NSImageView(image: Theme.symbol(r.symbol, size: 12) ?? Theme.symbol(.sparkles, size: 12) ?? NSImage())
            icon.contentTintColor = Theme.Colors.label3
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: lead),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            before = icon
        } else {
            let badge = FxBadge()
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: lead),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            before = badge
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: before.trailingAnchor, constant: gap),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -Self.rowLead(depth: 0)),
        ])
        cell.setAccessibilityLabel(r.title)
        return cell
    }

    /// v9 `.tree`: rows sit 4 in from the panel edges with 8 of padding; each depth adds one `Theme.Spacing.treeIndent`.
    static func rowLead(depth: Int) -> CGFloat {
        Theme.Spacing.xs + Theme.Spacing.sm + CGFloat(min(max(depth, 0), 2)) * Theme.Spacing.treeIndent
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].isHeader }
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !rows[row].isHeader }
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let r = rows[row]
        return r.isHeader ? Theme.Row.sectionHeader : Self.itemRowHeight
    }

    /// Every item and folder row is one line, `Theme.Row.panelList` (26) high.
    static let itemRowHeight: CGFloat = Theme.Row.panelList

    /// v9 `.tree .row`: rounded hover and selection, 4 in from the panel edges.
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = LibraryRowView()
        v.selectionRadius = Theme.Radius.small
        v.pillInset = Theme.Spacing.xs
        v.showsHover = !rows[row].isHeader
        return v
    }

    /// A click anywhere on a folder row opens or closes it (the row is neither selected nor dragged by the mouse).
    private func toggleFolder(row: Int) {
        guard rows.indices.contains(row), rows[row].isFolder else { return }
        let selected = table.selectedRow >= 0 && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        onFolderToggle?(rows[row].id)
        if let selected { select(id: selected) }     // the rebuild must not drop the current selection
    }

    /// Left / right on the selected row: collapse, expand, or move between folder and contents.
    private func handleArrow(_ key: EffectFolderOutline.Key) -> Bool {
        guard onFolderToggle != nil else { return false }
        let sel = table.selectedRow
        switch EffectFolderOutline.keyNavigation(rows: rows, selected: sel, key: key) {
        case .none: return false
        case .select(let i): table.selectRowIndexes([i], byExtendingSelection: false); table.scrollRowToVisible(i); return true
        case .toggle(let id):
            onFolderToggle?(id)
            select(id: id)
            return true
        }
    }

    /// Mouse selection: effects only. Folders open/close on click instead, headers do nothing.
    static func isMouseSelectable(_ r: Row) -> Bool { !r.isFolder && !r.isHeader }

    /// Where a dragged user folder lands for a proposed row: in front of that folder (rows of a folder's items count
    /// as the folder), or at the end of the user folders when the pointer is below them.
    func folderMoveTarget(forProposedRow row: Int) -> (row: Int, before: UUID?) {
        if rows.indices.contains(row), let f = rows[row].userFolder {
            let head = rows.firstIndex { $0.isFolder && $0.userFolder == f } ?? row
            return (head, f)
        }
        let firstOther = rows.firstIndex { $0.userFolder == nil } ?? rows.count
        return (firstOther, nil)
    }

    public func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                          proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        let pb = info.draggingPasteboard
        if pb.string(forType: .sequenceEffectFolder) != nil {
            // Reordering: user folders only, as a gap between rows. The built-in folders keep their fixed order.
            guard onMoveFolder != nil else { return [] }
            let t = folderMoveTarget(forProposedRow: row)
            tableView.setDropRow(t.row, dropOperation: .above)
            return .move
        }
        // Items (and the effects of a dragged folder) go into a user folder; built-in folders (Presets included) are read-only.
        guard onDropItem != nil, rows.indices.contains(row), rows[row].userFolder != nil else { return [] }
        tableView.setDropRow(row, dropOperation: .on)
        return .copy
    }

    public func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                          dropOperation op: NSTableView.DropOperation) -> Bool {
        let pb = info.draggingPasteboard
        if let s = pb.string(forType: .sequenceEffectFolder), let moving = UUID(uuidString: s) {
            onMoveFolder?(moving, folderMoveTarget(forProposedRow: row).before)
            return true
        }
        guard rows.indices.contains(row), let f = rows[row].userFolder,
              let s = pb.string(forType: .sequenceEffectID) else { return false }
        for id in EffectFolderOutline.decodeDrag(s) { onDropItem?(id, f) }
        return true
    }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let type = dragType, !rows[row].isHeader, !rows[row].isFolder else { return nil }
        let r = rows[row]
        let item = NSPasteboardItem()
        if r.isFolder { return nil }   // folders are not draggable
        // Presets are not dragged (they apply by double-click or from the palette).
        guard !r.itemID.hasPrefix("preset.") else { return nil }
        item.setString(r.itemID, forType: type)
        return item
    }
}

/// Effects panel: the effects that exist so far, grouped like Premiere's bins and searchable. Drag one onto a clip (or
/// double-click for the selection); it then shows in Effect Controls. Categories with no effect are not listed.
@MainActor
public final class EffectsPanelView: TemplateListPanelView {
    /// Entry ids are effect kinds (`ClipEffect.kind`).
    public static let roundedCorners = ClipEffect.roundedCornersKind
    public static let crop = ClipEffect.cropKind
    public static let gaussianBlur = ClipEffect.gaussianBlurKind
    public static let ultraKey = ClipEffect.ultraKeyKind
    public static let dropShadow = ClipEffect.dropShadowKind

    public typealias Entry = EffectsEntry
    // The catalog lives in SQDrawLibrary (`EffectsCatalog`, shared with the draw panel); these forward for callers and tests.
    public static var catalog: [Entry] { EffectsCatalog.catalog }
    static func offered(hiding: Bool) -> [Entry] { EffectsCatalog.offered(hiding: hiding) }
    static var textPresetEntries: [Entry] { EffectsCatalog.textPresetEntries }
    static var audioEntries: [Entry] { EffectsCatalog.audioEntries }
    static var videoEntries: [Entry] { EffectsCatalog.videoEntries }
    static var lookEntries: [Entry] { EffectsCatalog.lookEntries }
    public static var transitionPrefix: String { EffectDragPayload.transitionPrefix }
    public static func transitionID(_ k: TransitionKind) -> String { EffectDragPayload.transitionID(k) }
    public static func transitionKind(forID id: String) -> TransitionKind? { EffectDragPayload.transitionKind(forID: id) }
    static var transitionEntries: [Entry] { EffectsCatalog.transitionEntries }
    static func transitionSymbol(_ k: TransitionKind) -> SQIcon { EffectsCatalog.transitionSymbol(k) }
    public static func rows(matching query: String, in entries: [Entry] = EffectsCatalog.catalog) -> [Row] {
        EffectsCatalog.rows(matching: query, in: entries)
    }
    public static var builtInPresetEntries: [Entry] { EffectsCatalog.builtInPresetEntries }
    static func stackPresetEntries(_ bins: Set<EffectStackPreset.Bin>) -> [Entry] { EffectsCatalog.stackPresetEntries(bins) }

    /// Presets (Library) the panel lists under "Presets"; the app refreshes them when the library changes.
    public var presetEntries: [Entry] = [] { didSet { rebuild() } }
    public private(set) var folderStore: EffectFolderStore
    private var expanded: Set<String>
    private var query = ""
    /// While searching every matching folder is open; these are the ones the user closed again with their arrow.
    private var collapsedInSearch: Set<String> = []

    private var allEntries: [Entry] { Self.catalog + Self.builtInPresetEntries + Self.textPresetEntries + presetEntries }

    private func rebuild() {
        rows = EffectFolderOutline.rows(entries: allEntries, store: folderStore, expanded: expanded, query: query,
                                        collapsedInSearch: collapsedInSearch)
    }

    private func saveFolders() { folderStore.save(to: defaults); rebuild() }

    private func askName(_ title: String, initial: String) -> String? {
        let alert = SQDialog()
        alert.messageText = title
        alert.addButton("OK"); alert.addButton("Cancel")
        let field = SQDialog.makeField(width: 220)
        field.stringValue = initial
        alert.accessoryView = field
        alert.initialFirstResponder = field
        return alert.runModal() == .first ? field.stringValue : nil
    }

    private func newFolder(adding item: String? = nil) {
        guard let name = askName("New Folder", initial: "New Folder") else { return }
        let id = folderStore.createFolder(named: name)
        if let item { folderStore.add(item, to: id) }
        expanded.insert(EffectFolderOutline.userID(id))
        EffectFolderOutline.saveExpanded(expanded, to: defaults)
        saveFolders()
    }

    private func menuItems(forRow row: Int) -> [SQMenuItem] {
        func item(_ title: String, _ action: @escaping @MainActor () -> Void) -> SQMenuItem { SQMenuItem(title: title, action: action) }
        var out = [item("New Folder\u{2026}") { [weak self] in self?.newFolder() }]
        guard rows.indices.contains(row) else { return out }
        let r = rows[row]
        if r.isFolder, let f = r.userFolder {
            out.append(item("Rename Folder\u{2026}") { [weak self] in
                guard let self, let n = askName("Rename Folder", initial: folderStore.folder(f)?.name ?? "") else { return }
                folderStore.rename(f, to: n); saveFolders()
            })
            out.append(.separator)
            out.append(item("Delete Folder") { [weak self] in self?.folderStore.delete(f); self?.saveFolders() })
        } else if !r.isFolder && !r.isHeader {
            var sub: [SQMenuItem] = []
            for f in folderStore.folders {
                sub.append(item(f.name) { [weak self] in self?.folderStore.add(r.itemID, to: f.id); self?.saveFolders() })
            }
            if !folderStore.folders.isEmpty { sub.append(.separator) }
            sub.append(item("New Folder\u{2026}") { [weak self] in self?.newFolder(adding: r.itemID) })
            out.insert(SQMenuItem(title: "Add to Folder", submenu: sub), at: 0)
            if let f = r.userFolder {
                out.append(.separator)
                out.append(item("Remove from Folder") { [weak self] in self?.folderStore.remove(r.itemID, from: f); self?.saveFolders() })
            }
        }
        return out
    }

    public init(defaults: UserDefaults = .standard) {
        folderStore = EffectFolderStore.load(from: defaults)
        var open = EffectFolderOutline.loadExpanded(from: defaults)
        if open.isEmpty { open = [EffectFolderOutline.builtinID(EffectFolderOutline.effectsFolder)] }
        expanded = open
        // Board: no footer. New Folder lives in the right-click menu (also on empty space).
        super.init(rows: [], buttonTitle: "",
                   hint: "",
                   label: "Effects", searchable: true, gridCapable: true, defaults: defaults)
        dragType = .sequenceEffectID
        rebuild()
        onSearch = { [weak self] q in
            guard let self, q != query else { return }
            query = q; collapsedInSearch = []   // a new search opens all matches again
            rebuild()
        }
        onButton = { [weak self] in self?.newFolder() }
        rowMenu = { [weak self] row in self?.menuItems(forRow: row) ?? [] }
        folderDragIDs = { [weak self] row in
            guard let self else { return [] }
            return EffectFolderOutline.effectIDs(forFolder: row.id, entries: allEntries, store: folderStore)
        }
        onMoveFolder = { [weak self] id, before in
            guard let self else { return }
            folderStore.move(id, before: before)
            saveFolders()
        }
        onDropItem = { [weak self] id, folder in
            guard let self else { return }
            folderStore.add(id, to: folder)
            expanded.insert(EffectFolderOutline.userID(folder))
            EffectFolderOutline.saveExpanded(expanded, to: self.defaults)
            saveFolders()
        }
        onFolderToggle = { [weak self] id in
            guard let self else { return }
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                // Search results are forced open; the arrow closes one for this search only (not saved).
                if collapsedInSearch.contains(id) { collapsedInSearch.remove(id) } else { collapsedInSearch.insert(id) }
            } else {
                if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                EffectFolderOutline.saveExpanded(expanded, to: self.defaults)
            }
            rebuild()
        }
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }
}



/// Outline table: a mouse click on a folder row only toggles it (no selection, no drag start); left / right arrows
/// collapse and expand the selected folder.
final class FolderOutlineTableView: SQMenuTableView {
    var onFolderClick: ((Int) -> Void)?
    var onArrowKey: ((EffectFolderOutline.Key) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, let delegate = delegate as? TemplateListPanelView, delegate.isFolderRow(row) {
            window?.makeFirstResponder(self)
            onFolderClick?(row)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if plain, event.keyCode == 123 || event.keyCode == 124,
           onArrowKey?(event.keyCode == 123 ? .left : .right) == true { return }
        super.keyDown(with: event)
    }
}

/// v9 `.fx`: the small "fx" mark in front of an effect row (16 high, radius 4, `fill`, 9 pt bold `label2`).
final class FxBadge: NSView {
    private static let text = NSAttributedString(string: "fx", attributes: [.font: Theme.Typography.badge, .foregroundColor: Theme.Colors.label2])
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(Self.text.size().width) + 10, height: 16) }
    override func draw(_ dirtyRect: NSRect) {
        Theme.Colors.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        let s = Self.text.size()
        Self.text.draw(at: NSPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
    }
}
