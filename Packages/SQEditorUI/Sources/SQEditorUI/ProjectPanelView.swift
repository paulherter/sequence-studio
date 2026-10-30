import AppKit
import Observation
import SQCore

/// Outline item: a stable object per bin item so expansion state survives reloads.
private final class Node: NSObject {
    let ref: BinItemRef
    init(_ ref: BinItemRef) { self.ref = ref }
}

@MainActor
enum IconImages {
    private struct Key: Hashable { var icon: ProjectItemIcon; var tints: [LabelColor] }
    private static var cache: [Key: NSImage] = [:]

    /// Template image of the base symbol with the optional badge composed into the bottom-right corner.
    /// With `tints` the symbols wear the type colors (picture color, sound color on the badge) and are not templates.
    static func image(_ icon: ProjectItemIcon, tints: [LabelColor] = []) -> NSImage? {
        let key = Key(icon: icon, tints: tints)
        if let c = cache[key] { return c }
        func symbol(_ name: String, size: CGFloat, stroke: CGFloat, _ l: LabelColor?) -> NSImage? {
            let icon = SQIcon(rawValue: name) ?? .unknown
            return l.map { icon.image(size: size, color: $0.fill, stroke: stroke) } ?? icon.image(size: size)
        }
        guard let base = symbol(icon.symbol, size: 11, stroke: 1.6, tints.first) else { return nil }
        var result = base
        let badgeTint = tints.count > 1 ? tints[1] : tints.first
        if let badgeName = icon.badge,
           let badge = symbol(badgeName, size: 7, stroke: 2.4, badgeTint) {
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
            composed.isTemplate = tints.isEmpty
            result = composed
        }
        if !tints.isEmpty { result.isTemplate = false }
        cache[key] = result
        return result
    }

    /// Menu chip for a label color.
    @MainActor static func swatch(_ l: LabelColor) -> NSImage { SQMenuDot.image(rgb: l.rgb) }
}


private final class DisclosureChevronButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.pushOnPushOff)
        isBordered = false
        title = ""
        focusRingType = .none
        setAccessibilityLabel("Disclose")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let open = state == .on
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let p = NSBezierPath()
        // Corner of a 5 pt square, turned like the board: right = -45 deg, down = 45 deg (view is flipped in rows).
        if open {
            p.move(to: NSPoint(x: c.x - 4.0, y: c.y - 2.0)); p.line(to: NSPoint(x: c.x, y: c.y + 2.0)); p.line(to: NSPoint(x: c.x + 4.0, y: c.y - 2.0))
        } else {
            p.move(to: NSPoint(x: c.x - 2.0, y: c.y - 4.0)); p.line(to: NSPoint(x: c.x + 2.0, y: c.y)); p.line(to: NSPoint(x: c.x - 2.0, y: c.y + 4.0))
        }
        p.lineWidth = 1.2; p.lineCapStyle = .round; p.lineJoinStyle = .round
        Theme.Colors.label3.setStroke(); p.stroke()
    }
}

/// Right-click and ctrl-click on the column header: SQ rows, no NSMenu.
private final class PanelHeaderView: NSTableHeaderView {
    var sqItems: (() -> [SQMenuItem])?
    override func menu(for event: NSEvent) -> NSMenu? {
        if let items = sqItems?(), !items.isEmpty { SQContextMenu.show(items: items, for: event, in: self) }
        return nil
    }
}

/// Name cell of the Project list: the icon box sits at a per-row inset (v9: 12, plus 11 per folder level).
private final class ProjectNameCell: NSTableCellView {
    var lead: NSLayoutConstraint!
    var iconWidth: NSLayoutConstraint!
    var gap: NSLayoutConstraint!
    func place(lead l: CGFloat, iconWidth w: CGFloat, gap g: CGFloat) {
        lead.constant = l; iconWidth.constant = w; gap.constant = g
    }
}

private final class PanelOutlineView: NSOutlineView {
    /// Left edge of the disclosure arrow of a row (the panel knows the row's inset).
    var chevronX: ((Int) -> CGFloat?)?
    /// The cells lay out their own inset: the name column's cell spans the whole column on every level.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = super.frameOfCell(atColumn: column, row: row)
        guard tableColumns.indices.contains(column), tableColumns[column] === outlineTableColumn else { return r }
        let c = rect(ofColumn: column)
        r.size.width = r.maxX - c.minX
        r.origin.x = c.minX
        return r
    }
    /// M3: the empty-state Pip watches a drag over the outline (window point), and learns how it ended.
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragMoved?(sender.draggingLocation)
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragMoved?(sender.draggingLocation)
        return super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragEnded?(false)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ok = super.performDragOperation(sender)
        onDragEnded?(ok)
        return ok
    }
    /// Right-click and ctrl-click: the panel builds SQ rows for the clicked row (selecting it first), no NSMenu.
    var sqItems: ((Int) -> [SQMenuItem])?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if let items = sqItems?(row), !items.isEmpty { SQContextMenu.show(items: items, for: event, in: self) }
        return nil
    }
    /// The one disclosure of the design (sq.css `.cv`): a 5 pt corner stroked 1.2 in `label3`, pointing right / down.
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        if identifier == NSOutlineView.disclosureButtonIdentifier {
            let b = DisclosureChevronButton()
            b.identifier = identifier
            // AppKit only wires the stock triangle: our own button needs its own target, else the arrow does nothing on a
            // single click and only the row's double-click action opens the folder.
            b.target = self
            b.action = #selector(toggleDisclosure(_:))
            return b
        }
        return super.makeView(withIdentifier: identifier, owner: owner)
    }
    @objc func toggleDisclosure(_ sender: NSView) {
        let row = self.row(for: sender)
        guard row >= 0, let item = item(atRow: row) else { return }
        if isItemExpanded(item) { collapseItem(item) } else { expandItem(item) }
        (sender as? DisclosureChevronButton)?.state = isItemExpanded(item) ? .on : .off
    }
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        let r = rect(ofRow: row)
        guard isExpandable(item(atRow: row)) else { return .zero }
        let x = chevronX?(row) ?? 10 + CGFloat(max(level(forRow: row), 0)) * indentationPerLevel
        return NSRect(x: rect(ofColumn: max(column(withIdentifier: outlineTableColumn?.identifier ?? .init("name")), 0)).minX + x, y: r.minY, width: 11, height: r.height)
    }
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

/// Project panel: bins and media in an NSOutlineView (Name / Format / Duration), import by dragging files in,
/// drag items out, inline rename, context menu. All edits go through `ProjectPanelModel`.
@MainActor
public final class ProjectPanelView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    public let model: ProjectPanelModel
    private let outline = PanelOutlineView()
    private let scroll = NSScrollView()
    private let emptyState = EmptyStateView(title: "No media yet")
    var emptyStateForTesting: EmptyStateView { emptyState }
    var gridForTesting: ProjectIconView { grid }
    /// Distance from the list's top to the empty state: a fresh project already lists its first sequence, Pip sits below it.
    private lazy var emptyTopC = emptyState.topAnchor.constraint(equalTo: scroll.topAnchor)
    private let search = SQSearchField()
    private let status = NSTextField(labelWithString: "")
    /// Import progress row: the status line reads "Importing 12 of 240…", this stops the rest of the batch.
    private let cancelImportButton = SQButton(title: "Cancel", target: nil, action: nil)
    private var cancelWidthC: NSLayoutConstraint!
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
    /// Insert / Overwrite of selected sequences (nested clips at the playhead).
    public var onPlaceSequences: (([Timeline.ID], ThreePointMode) -> Void)?
    public var onNewSequenceFromClip: ((MediaRef.ID) -> Void)?
    /// F7.16 "Create Angles Clip…" for the selected media items.
    /// "New Color Matte…": the host asks for name, color and duration and places the matte at the playhead.
    public var onNewColorMatte: (() -> Void)?
    public var onCreateAnglesClip: (([MediaRef.ID]) -> Void)?
    /// Fill Reel…: the selected media items pour into the active sequence's slots (the app opens the sheet).
    public var onFillReel: (([MediaRef.ID]) -> Void)?
    /// Whether the active sequence has slots; the menu row is disabled without.
    public var canFillReel: () -> Bool = { false }
    /// Make Subclip (Clip menu, Cmd+U) from the item's In/Out; Edit Original opens the items' files in their default app.
    public var onMakeSubclip: ((MediaRef.ID) -> Void)?
    public var onEditOriginal: (([MediaRef.ID]) -> Void)?
    public var onNewSequence: (() -> Void)?
    public var onReplaceFootage: ((MediaRef.ID) -> Void)?
    /// Per-file Locate of one offline item (context menu): the app asks for the file and relinks that item only.
    public var onLocateMedia: ((MediaRef.ID) -> Void)?
    public var onImportRequest: (() -> Void)?
    /// Extract Audio (context menu) of one online media item with sound: the app writes the M4A and imports it.
    public var onExtractAudio: ((MediaRef.ID) -> Void)?
    /// Conform to Constant Frame Rate (context menu) of the selected variable-frame-rate items; the app runs the job.
    public var onConformToConstantFrameRate: (([MediaRef.ID]) -> Void)?
    /// Double-click on a hover-scrubbed icon opens the clip at the hovered time (Premiere); nil time = from the start.
    public var onOpenMediaAt: ((MediaRef.ID, Time?) -> Void)?
    /// One-line messages (a delete that was blocked, Find results): the host shows them in its status bar.
    public var onNotice: ((String) -> Void)?
    /// Cmd+P without a hovered picture: the clip and time of the Source monitor, when it shows one of the selected clips.
    public var sourcePosition: (() -> (MediaRef.ID, Time)?)?
    public enum ViewMode: String, Sendable { case list, icons }
    public private(set) var viewMode: ViewMode
    private let grid: ProjectIconView
    private let sizeSlider = SQSlider()
    /// Icon view, breadcrumb row: back to the list (v9 header icon; as List / as Icons are also in the panel menu).
    private lazy var listButton = IconButton(symbol: .list, label: "List View", size: 12) { [weak self] in self?.setViewMode(.list) }
    private let binLabel = NSTextField(labelWithString: "")
    /// v9 numbers: search row 38 (shown on demand), breadcrumb 28, rows `Theme.Row.panelList` (26), name 12 in.
    static let searchRowHeight: CGFloat = 38
    static let crumbHeight: CGFloat = 28
    static let listRowHeight: CGFloat = Theme.Row.panelList
    static let nameLead: CGFloat = Theme.Spacing.md
    static let searchVisibleKey = "sq.project.searchVisible"
    /// The search row is off until asked for (v9 shows the list right under the header); panel menu > Search.
    public private(set) var isSearchVisible: Bool
    /// "14 items" for the panel header (v9 `.meta`): everything in the project, or the open folder in icon view.
    public var onItemCountChange: ((String) -> Void)?
    public var itemCountText: String {
        let n: Int
        if viewMode == .icons {
            n = model.children(of: model.project.bin(model.browseBin) ?? model.project.rootBin).count
        } else {
            n = model.project.rootBin.allRefs.filter { if case .bin = $0 { false } else { true } }.count
        }
        return n == 1 ? "1 item" : "\(n) items"
    }
    private var crumbTopC: NSLayoutConstraint!
    private let filterBar = ProjectFilterBar(frame: .zero)
    private var filterHeightC: NSLayoutConstraint!
    private var crumbHeightC: NSLayoutConstraint!
    private var statusHeightC: NSLayoutConstraint!
    /// Project health line above the status line (counts + Fix menu); the host runs Collect and Reconnect.
    private let healthBar = ProjectHealthBar()
    private var healthHeightC: NSLayoutConstraint!
    public var onHealthAction: ((ProjectHealthBar.Action) -> Void)?

    /// Plain-language text of the "format not supported" dialog.
    static func unsupportedMessage(_ items: [(file: String, codec: String)]) -> (title: String, message: String) {
        let codecs = Array(Set(items.map(\.codec))).sorted().joined(separator: ", ")
        let files = items.prefix(5).map(\.file).joined(separator: ", ") + (items.count > 5 ? " and \(items.count - 5) more" : "")
        let audioExt: Set<String> = ["ogg", "oga", "opus", "wma", "amr", "ape", "wv", "mka", "ac3", "dts"]
        let audioOnly = items.allSatisfy { audioExt.contains(($0.file as NSString).pathExtension.lowercased()) }
        let advice = audioOnly ? "Convert it to WAV, AIFF or AAC (m4a)" : "Convert it to MP4 (H.264 or HEVC)"
        return (items.count == 1 ? "This file can't be opened" : "These files can't be opened",
                "\(files) uses \(codecs), which Sequence Studio can't play on this Mac. \(advice) and import it again.")
    }

    /// The status line for a finished import: the report's summary, a tooltip that names every file by group
    /// (each group capped at 5 names), and whether anything needs the user's eyes (shown in the warning color).
    static func importReportStatus(_ r: ImportReport) -> (text: String, detail: String?, isProblem: Bool) {
        func names(_ items: [String]) -> String {
            items.prefix(5).joined(separator: ", ") + (items.count > 5 ? " and \(items.count - 5) more" : "")
        }
        func entries(_ items: [ImportReport.Entry]) -> [String] {
            var lines = items.prefix(5).map { "\($0.file): \($0.detail)" }
            if items.count > 5 { lines.append("and \(items.count - 5) more") }
            return lines
        }
        var lines: [String] = []
        if !r.alreadyInProject.isEmpty { lines.append("Already in the project: " + names(r.alreadyInProject)) }
        if !r.duplicates.isEmpty { lines.append("Same file as one already imported: " + names(r.duplicates)) }
        if !r.failed.isEmpty { lines.append("Could not be read:"); lines += entries(r.failed) }
        if !r.unsupported.isEmpty { lines.append("Codec not supported:"); lines += entries(r.unsupported) }
        if !r.audioDropped.isEmpty { lines.append("Imported without sound:"); lines += entries(r.audioDropped) }
        return (r.summary, lines.isEmpty ? nil : lines.joined(separator: "\n"), !r.isClean)
    }

    /// Plain-language text of the "imported without sound" notice.
    static func audioDroppedMessage(_ items: [(file: String, codec: String)]) -> (title: String, message: String) {
        let codecs = Array(Set(items.map(\.codec))).sorted().joined(separator: ", ")
        let files = items.prefix(5).map(\.file).joined(separator: ", ") + (items.count > 5 ? " and \(items.count - 5) more" : "")
        return ("Imported without sound",
                "\(files) imported, but its audio uses \(codecs), which this Mac cannot decode. The picture plays; convert the audio to AAC or WAV to hear it.")
    }

    public init(model: ProjectPanelModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        self.layout = ProjectColumnLayout.load(from: defaults)
        self.viewMode = ViewMode(rawValue: defaults.string(forKey: "ProjectPanel.viewMode") ?? "") ?? .list
        self.isSearchVisible = defaults.bool(forKey: Self.searchVisibleKey)
        self.grid = ProjectIconView(model: model)
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.panel.cgColor
        build()
        applyMode()
        reload()
        observe()
        model.onUnsupported = { [weak self] items in
            let m = Self.unsupportedMessage(items)
            SQDialog.warn(m.title, message: m.message, in: self?.window)
        }
        installAudioDroppedNotice()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func installAudioDroppedNotice() {
        model.onAudioDropped = { [weak self] items in
            let m = Self.audioDroppedMessage(items)
            SQDialog.warn(m.title, message: m.message, in: self?.window)
        }
    }

    // MARK: Layout

    /// Board `.tr .n`: chevron 11 wide at 11 (3 in the cell), icon 14 at 27, name 6 after the icon; every level 11 further in.
    static let levelIndent: CGFloat = Theme.Spacing.treeIndent
    static let iconLead: CGFloat = 6

    private func build() {
        search.setQuietPlaceholder("Search project")
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        status.font = Theme.Typography.caption
        status.textColor = Theme.Colors.label3
        status.translatesAutoresizingMaskIntoConstraints = false
        status.lineBreakMode = .byTruncatingTail
        cancelImportButton.target = self
        cancelImportButton.action = #selector(cancelImportPressed)
        cancelImportButton.boxHeight = Theme.Metrics.pushButton - Theme.Spacing.xs
        cancelImportButton.horizontalPadding = Theme.Spacing.sm
        cancelImportButton.isHidden = true
        cancelImportButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cancelImportButton)

        rebuildColumns()
        outline.dataSource = self
        outline.delegate = self
        QuietList.style(outline, rowHeight: Self.listRowHeight)          // v9: the list sits on the panel surface
        outline.chevronX = { [weak self] row in self?.chevronX(row: row) }
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.indentationPerLevel = 0          // the name cell insets itself (`binDepth`)
        outline.registerForDraggedTypes([.fileURL, .sequenceMediaIDs])
        outline.setDraggingSourceOperationMask([.copy, .generic], forLocal: false)
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .regular
        outline.onDragMoved = { [weak self] p in self?.emptyState.mascotDragMoved(windowPoint: p) }   // M3
        outline.onDragEnded = { [weak self] dropped in self?.emptyState.mascotDragEnded(dropped: dropped) }
        outline.onDelete = { [weak self] in self?.deleteSelection() }
        outline.onReturn = { [weak self] in self?.renameSelection() }
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.sqItems = { [weak self] row in self?.outlineMenuItems(clickedRow: row) ?? [] }
        let header = PanelHeaderView(frame: outline.headerView?.frame ?? .zero)
        header.sqItems = { [weak self] in self?.headerMenuItems() ?? [] }
        outline.headerView = header
        rebuildColumns()          // again: `QuietList.style` restyled the header cells
        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged(_:)),
                                               name: NSOutlineView.columnDidResizeNotification, object: outline)
        NotificationCenter.default.addObserver(self, selector: #selector(columnsChanged(_:)),
                                               name: NSOutlineView.columnDidMoveNotification, object: outline)

        scroll.documentView = outline
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification,
                                               object: scroll.contentView)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        grid.translatesAutoresizingMaskIntoConstraints = false
        wireGrid()
        sizeSlider.minValue = 64; sizeSlider.maxValue = 160; sizeSlider.doubleValue = Double(grid.thumbSize)
        sizeSlider.target = self; sizeSlider.action = #selector(sizeChanged)
        sizeSlider.sqToolTip = "Thumbnail size"
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        binLabel.font = Theme.Typography.body
        binLabel.textColor = Theme.Colors.label3
        binLabel.lineBreakMode = .byTruncatingHead
        binLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search); addSubview(filterBar); addSubview(scroll); addSubview(grid); addSubview(status)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        addSubview(sizeSlider); addSubview(binLabel)
        listButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(listButton)
        let g = Theme.Spacing.sm
        // Search row 38 high, only while asked for (panel menu > Search). Under it, in icon view, the breadcrumb
        // ("Project" or "Project › Bin") with the tile-size slider at its right. Status line only while importing or
        // after a failure.
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterHeightC = filterBar.heightAnchor.constraint(equalToConstant: 0)
        filterBar.isHidden = !isSearchVisible
        filterBar.onGrouping = { [weak self] g in self?.model.grouping = g; self?.afterFilterChange() }
        filterBar.onAdd = { [weak self] t in
            guard let self, !model.filterTokens.contains(t) else { return }
            model.filterTokens.append(t); afterFilterChange()
        }
        filterBar.onRemove = { [weak self] t in self?.model.filterTokens.removeAll { $0 == t }; self?.afterFilterChange() }
        filterBar.onHeightChange = { [weak self] h in
            guard let self else { return }
            filterHeightC.constant = h; updateCrumbTop()
        }
        crumbTopC = binLabel.topAnchor.constraint(equalTo: topAnchor, constant: isSearchVisible ? Self.searchRowHeight : 0)
        search.isHidden = !isSearchVisible
        crumbHeightC = binLabel.heightAnchor.constraint(equalToConstant: 0)
        statusHeightC = status.heightAnchor.constraint(equalToConstant: 0)
        healthBar.translatesAutoresizingMaskIntoConstraints = false
        healthBar.isHidden = true
        healthBar.onAction = { [weak self] action in
            guard let self else { return }
            if action == .showMissing { self.model.mediaFilter = .offline } else { self.onHealthAction?(action) }
        }
        addSubview(healthBar)
        healthHeightC = healthBar.heightAnchor.constraint(equalToConstant: 0)
        cancelWidthC = cancelImportButton.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: (Self.searchRowHeight - Theme.Metrics.quietField) / 2),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: g),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -g),
            filterBar.topAnchor.constraint(equalTo: topAnchor, constant: Self.searchRowHeight - Theme.Spacing.xs),
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterHeightC,
            sizeSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.nameLead),
            sizeSlider.centerYAnchor.constraint(equalTo: binLabel.centerYAnchor),
            sizeSlider.widthAnchor.constraint(equalToConstant: 64),
            binLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.nameLead),
            listButton.trailingAnchor.constraint(equalTo: sizeSlider.leadingAnchor, constant: -g),
            listButton.centerYAnchor.constraint(equalTo: binLabel.centerYAnchor),
            binLabel.trailingAnchor.constraint(equalTo: listButton.leadingAnchor, constant: -g),
            crumbTopC,
            crumbHeightC,
            emptyTopC, emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            grid.topAnchor.constraint(equalTo: scroll.topAnchor), grid.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), grid.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: binLabel.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: healthBar.topAnchor),
            healthBar.leadingAnchor.constraint(equalTo: leadingAnchor), healthBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            healthBar.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -Theme.Spacing.xs),
            healthHeightC,
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: g),
            status.trailingAnchor.constraint(equalTo: cancelImportButton.leadingAnchor, constant: -Theme.Spacing.xs),
            cancelImportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -g),
            cancelImportButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            cancelWidthC,
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
            statusHeightC,
        ])
    }

    // MARK: Model sync

    private func observe() {
        withObservationTracking {
            _ = model.revision; _ = model.pendingImports; _ = model.importFailures; _ = model.alreadyInProject
            _ = model.importTotal; _ = model.importCanceled; _ = model.lastImportReport
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
        refitColumns()
        outline.reloadData()
        if model.isFiltering { outline.expandItem(nil, expandChildren: true) }
        let rows = IndexSet(selected.compactMap { nodes[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        grid.reload()
        filterBar.update(grouping: model.grouping, tokens: model.filterTokens, media: model.project.media)
        updateBinLabel()
        updateEmptyState()
        if model.pendingImports > 0 {
            let total = max(model.importTotal, model.pendingImports)
            status.stringValue = "Importing \(total - model.pendingImports + 1) of \(total)…"
            status.textColor = Theme.Colors.label2
        } else if let c = model.importCanceled {
            status.stringValue = ProjectPanelModel.canceledText(imported: c.imported, total: c.total)
            status.textColor = Theme.Colors.label2
        } else if let report = model.lastImportReport {
            let s = Self.importReportStatus(report)
            status.stringValue = s.text
            status.toolTip = s.detail
            status.textColor = s.isProblem ? Theme.Colors.red : Theme.Colors.label3
        } else if !model.importFailures.isEmpty {
            status.stringValue = ProjectPanelModel.failureStatus(model.importFailureReasons, names: model.importFailures)
            status.toolTip = ProjectPanelModel.failureDetail(model.importFailureReasons)
            status.textColor = Theme.Colors.red
        } else if !model.alreadyInProject.isEmpty {
            status.stringValue = ProjectPanelModel.alreadyText(model.alreadyInProject)
            status.textColor = Theme.Colors.label2
        } else {
            status.stringValue = ""
        }
        if model.pendingImports > 0 || (model.lastImportReport == nil && model.importFailures.isEmpty) { status.toolTip = nil }
        updateImportPip()
        updateStatusRow()
        let showHealth = healthBar.update(model.health)
        healthBar.isHidden = !showHealth
        healthHeightC.constant = showHealth ? ProjectHealthBar.height : 0
        onItemCountChange?(itemCountText)
    }

    /// The status line shows in list view; during an import it also shows in icon view (with Cancel), so a big batch
    /// can be stopped from either.
    private func updateStatusRow() {
        let importing = model.pendingImports > 0
        let show = !status.stringValue.isEmpty && (viewMode != .icons || importing)
        status.isHidden = !show
        statusHeightC?.constant = show ? 18 : 0
        cancelImportButton.isHidden = !(show && importing)
        cancelWidthC.constant = cancelImportButton.isHidden ? 0 : cancelImportButton.intrinsicContentSize.width
    }

    @objc private func cancelImportPressed() { model.cancelImport() }

    // M15: Pip claps once when an import batch finishes without a problem; gone after a few seconds, never blocks input.
    private var importPip: SQMascotView?
    private var importWasRunning = false
    private var importPipTimer: Timer?

    private func updateImportPip() {
        let running = model.pendingImports > 0
        defer { importWasRunning = running }
        guard importWasRunning, !running, model.importCanceled == nil, model.importFailures.isEmpty,
              let report = model.lastImportReport, !Self.importReportStatus(report).isProblem,
              importPip == nil, let pip = SQMascotPlace.importDone.makeView() else { return }
        pip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pip)
        NSLayoutConstraint.activate([
            pip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.md),
            pip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.md),
        ])
        importPip = pip
        importPipTimer?.invalidate()
        importPipTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.importPip?.removeFromSuperview(); self?.importPip = nil }
        }
    }

    private func node(_ r: BinItemRef) -> Node {
        if let n = nodes[r] { return n }
        let n = Node(r); nodes[r] = n; return n
    }

    private func bin(of item: Any?) -> Bin? {
        guard let n = item as? Node, case .bin(let id) = n.ref else { return nil }
        return model.displayBin(id)
    }

    // MARK: Data source

    public func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootItems().count }
        return bin(of: item).map { model.children(of: $0).count } ?? 0
    }

    public func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let kids: [BinItem]
        if item == nil {
            kids = rootItems()
        } else {
            kids = model.children(of: bin(of: item) ?? model.project.rootBin)
        }
        // The project changed between AppKit's count and this row (replaced while the panel was still building):
        // hand back a placeholder and reload, never trap.
        guard kids.indices.contains(index) else {
            DispatchQueue.main.async { [weak self] in self?.reload() }
            return node(.bin(model.project.rootBin.id))
        }
        return node(kids[index].ref)
    }

    public func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { bin(of: item) != nil }

    // MARK: Cells

    public func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        ProjectRowView()          // v9 `.tbl`: no stripes, hover fill, full-width selection
    }

    /// Root level as the project holds it: sequences first, then the folders and loose items (each part keeps the
    /// model's order). No automatic categories.
    private func rootItems() -> [BinItem] {
        let all = model.children(of: model.project.rootBin)
        func isSequence(_ i: BinItem) -> Bool { if case .sequence = i.ref { true } else { false } }
        return all.filter(isSequence) + all.filter { !isSequence($0) }
    }

    /// How many folders the user made sit above an item.
    private func binDepth(_ r: BinItemRef) -> Int {
        let root = model.project.rootBin
        var d = 0, cur = r
        while let p = root.parent(of: cur), p != root.id { d += 1; cur = .bin(p) }
        return d
    }

    /// Where the disclosure arrow of a row sits: before a folder's icon.
    private func chevronX(row: Int) -> CGFloat? {
        let item = outline.item(atRow: row)
        guard let n = item as? Node else { return nil }
        return Self.nameLead - 2 + CGFloat(binDepth(n.ref)) * Self.levelIndent
    }

    public func outlineView(_ o: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
        guard let column, let col = ProjectPanelModel.Column(rawValue: column.identifier.rawValue) else { return nil }
        let id = column.identifier
        let cell = o.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        let nameCell = cell as? ProjectNameCell
        let box = cell.imageView as? ProjectIconBox
        guard let n = item as? Node else { return nil }
        var offline = false
        if case .media(let m) = n.ref {
            guard model.project.media(m) != nil else { return nil }
            offline = model.isOffline(m)
        }
        cell.textField?.stringValue = model.cellText(col, n.ref)
        cell.textField?.sqToolTip = model.cellTooltip(col, n.ref)
        if col == .name {
            let indent = CGFloat(binDepth(n.ref)) * Self.levelIndent
            box?.label = nil
            // Kind chip: the item's color (its label, else the type color as on the timeline; offline = red) with the kind's icon.
            let kind = model.itemKind(of: n.ref)
            let labels = model.tints(of: n.ref)
            let plate = model.plateLabel(of: n.ref) ?? labels.first
            let fills: [NSColor] = offline ? [Theme.Colors.red]
                : (model.plateLabel(of: n.ref) == nil && labels.count > 1 ? labels.map(\.fill) : [plate?.fill ?? Theme.Colors.label3])
            let glyph = SQIcon(rawValue: ProjectItemIcon.icon(for: kind).symbol) ?? .unknown
            box?.image = nil
            box?.chip = ProjectIconBox.Chip(fills: fills, glyph: glyph, glyphColor: offline ? Theme.Colors.onClip : (plate?.onFill ?? Theme.Colors.onClip))
            nameCell?.place(lead: Self.nameLead + indent + (kind == .bin ? Self.levelIndent : 0), iconWidth: ProjectIconBox.chipSize, gap: Theme.Spacing.sm)
            cell.textField?.isEditable = false     // Return / menu start a rename; a double-click opens the item
            cell.textField?.font = Theme.Typography.list
            cell.textField?.textColor = offline ? Theme.Colors.red : Theme.Colors.label
        } else {
            cell.textField?.font = col == .duration ? Theme.Typography.tabularList : Theme.Typography.list
            cell.textField?.alignment = col == .duration ? .right : .left
            cell.textField?.textColor = offline ? Theme.Colors.red : Theme.Colors.label2
        }
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let isName = id.rawValue == "name"
        let cell = isName ? ProjectNameCell() : NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.lineBreakMode = .byTruncatingTail
        tf.drawsBackground = false
        tf.isBordered = false
        tf.delegate = self
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf); cell.textField = tf
        if let cell = cell as? ProjectNameCell {
            let iv = ProjectIconBox()
            iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv); cell.imageView = iv
            cell.lead = iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.nameLead)
            cell.iconWidth = iv.widthAnchor.constraint(equalToConstant: ProjectIconBox.chipSize)
            cell.gap = tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: Theme.Spacing.sm)
            NSLayoutConstraint.activate([
                cell.lead, cell.iconWidth, cell.gap,
                iv.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iv.heightAnchor.constraint(equalToConstant: ProjectIconBox.size.height),
            ])
        } else {
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Theme.Spacing.sm).isActive = true
        }
        NSLayoutConstraint.activate([
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Theme.Spacing.sm),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Columns

    private func rebuildColumns() {
        rebuildingColumns = true
        defer { rebuildingColumns = false }
        // Snapshot of the old columns; they go after the new ones are in. An outline view refuses to remove its outline
        // column (it only logs), so the new Name column takes that role first, and nothing here loops "until empty".
        let old = outline.tableColumns
        for col in layout.visible {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = col.title
            c.width = layout.userWidth(of: col) ?? autoWidth(of: col); c.minWidth = col.minWidth
            if col == .duration { c.headerCell.alignment = .right }
            PanelListHeader.style(c, leadingPad: col == .name ? Self.nameLead : Theme.Spacing.sm)
            c.sortDescriptorPrototype = NSSortDescriptor(key: col.rawValue, ascending: true)
            outline.addTableColumn(c)
        }
        outline.headerView?.frame.size.height = PanelListHeader.height
        outline.outlineTableColumn = outline.tableColumns.first { c in !old.contains { $0 === c } }
        for c in old { outline.removeTableColumn(c) }
        if let sc = model.sortColumn, layout.isVisible(sc) {
            outline.sortDescriptors = [NSSortDescriptor(key: sc.rawValue, ascending: model.sortAscending)]
        } else {
            outline.sortDescriptors = []
            if model.sortColumn != nil { model.setSort(nil, ascending: true) }
        }
        fitNameColumn()
    }

    /// Compact automatic width of a column: its widest text (all items, capped) plus Theme spacing, clamped.
    private func autoWidth(of col: ProjectPanelModel.Column) -> CGFloat {
        let refs = Array(model.project.rootBin.allRefs.prefix(500))
        let root = model.project.rootBin
        func depth(_ r: BinItemRef) -> Int {
            var d = 0, cur = r
            while let p = root.parent(of: cur), p != root.id { d += 1; cur = .bin(p) }
            return d
        }
        var content: CGFloat = 0
        var maxDepth = 0
        for r in refs {
            content = max(content, ceil((model.cellText(col, r) as NSString).size(withAttributes: [.font: Theme.Typography.list]).width))
            if col == .name {
                let d = depth(r)
                maxDepth = max(maxDepth, d)
            }
        }
        let header = ceil((col.title as NSString).size(withAttributes: [.font: Theme.Typography.listHeader]).width)
        return ProjectColumnSizing.width(of: col, header: header, content: content, maxDepth: maxDepth)
    }

    /// Re-fits the columns the user has not dragged (names and values change with the project).
    /// Board `.tr`: Name takes what the other columns leave, so Format and Duration stay in view at panel width.
    @objc private func clipResized(_ n: Notification) { fitNameColumn() }

    private func fitNameColumn() {
        guard let name = outline.tableColumns.first(where: { $0.identifier.rawValue == "name" }) else { return }
        let others = outline.tableColumns.filter { $0 !== name }.reduce(0) { $0 + $1.width + outline.intercellSpacing.width }
        let room = scroll.contentView.bounds.width - others - outline.intercellSpacing.width
        let w = max(name.minWidth, room.rounded(.down))
        guard abs(name.width - w) > 0.5 else { return }
        rebuildingColumns = true
        defer { rebuildingColumns = false }
        name.width = w
    }

    private func refitColumns() {
        rebuildingColumns = true
        defer { rebuildingColumns = false }
        for c in outline.tableColumns {
            guard let col = ProjectPanelModel.Column(rawValue: c.identifier.rawValue), layout.userWidth(of: col) == nil else { continue }
            let w = autoWidth(of: col)
            if abs(c.width - w) > 0.5 { c.width = w }
        }
        fitNameColumn()
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
        // Only a column the user dragged keeps a fixed width; the others stay automatic.
        if let c = note.userInfo?["NSTableColumn"] as? NSTableColumn, note.name == NSOutlineView.columnDidResizeNotification,
           let col = ProjectPanelModel.Column(rawValue: c.identifier.rawValue) { l.setWidth(c.width, for: col) }
        layout = l
        layout.save(to: defaults)
    }

    /// Tests: a second rebuild (the outline column exists by then) ends and leaves each column once.
    func rebuildColumnsForTesting() -> [String] {
        rebuildColumns()
        return outline.tableColumns.map(\.identifier.rawValue)
    }

    private func toggleColumn(_ col: ProjectPanelModel.Column) {
        layout.toggle(col)
        layout.save(to: defaults)
        rebuildColumns()
        outline.reloadData()
    }

    private func resetColumns() {
        layout = .defaults
        layout.save(to: defaults)
        rebuildColumns()
        outline.reloadData()
    }

    private func headerMenuItems() -> [SQMenuItem] {
        ProjectPanelMenus.headerItems(isVisible: { [layout] in layout.isVisible($0) }) { [weak self] in self?.run($0) }
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
        guard (obj.object as? NSSearchField) === search else { return }
        takeTokens(final: false)
        model.searchText = search.stringValue
    }

    /// Moves finished filter tokens (cam:FX3 ...) out of the search text into the chips.
    private func takeTokens(final: Bool) {
        let x = MediaFilterToken.extract(from: search.stringValue, final: final)
        guard !x.tokens.isEmpty else { return }
        for t in x.tokens where !model.filterTokens.contains(t) { model.filterTokens.append(t) }
        search.stringValue = x.rest
        afterFilterChange()
    }

    private func afterFilterChange() {
        if viewMode == .icons, model.grouping != .folders { model.browseBin = model.project.rootBin.id; model.currentBin = model.browseBin }
        reload()
    }

    private func updateCrumbTop() {
        crumbTopC.constant = isSearchVisible ? Self.searchRowHeight + filterHeightC.constant : 0
    }

    // MARK: Rename

    public func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSSearchField) === search { takeTokens(final: true); model.searchText = search.stringValue; return }
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

    var outlineForTesting: NSOutlineView { outline }
    func disclosureButtonForTesting(row: Int) -> NSControl? {
        outline.rowView(atRow: row, makeIfNecessary: true)?.subviews.compactMap { $0 as? NSControl }.first { $0.action != nil }
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

    /// Delete in the Project panel (command key path; the table views also handle the key themselves).
    public func deleteSelectedItems() { deleteSelection() }

    private func deleteSelection() {
        let refs = selectedRefs
        guard !refs.isEmpty else { return }
        let r = model.delete(refs)
        if let message = r.message { onNotice?(message) }
        if !r.changed { NSSound.beep() }
    }

    /// Clear Used Media: unused items are deleted, used media goes offline with its clips kept (one undo step).
    private func clearSelection() {
        let refs = menuTargets
        guard !refs.isEmpty else { return }
        let r = model.clear(refs)
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
        let alert = SQDialog()
        alert.messageText = "Find"
        alert.informativeText = "Select the clips and sequences that match."
        let field = SQDialog.makeField(width: 240)
        field.placeholderString = "Text"
        let which = SQPopup(frame: .zero, pullsDown: false)
        which.addItems(withTitles: ["Name", "Label"])
        let offline = SQCheckbox(title: "Offline media only", target: nil, action: nil)
        which.setContentHuggingPriority(.required, for: .horizontal)
        let top = NSStackView(views: [field, which])
        top.spacing = 8
        alert.accessoryView = SQDialogForm(rows: [SQDialog.pad(top, SQDialogMetrics.insets(0, 0)),
                                                  SQDialog.checkRow(offline)])
        alert.addButton("Find")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        guard alert.runModal() == .first else { return }
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
        onNotice?(SQL10n.plural(found.count, one: "%@ match.", other: "%@ matches."))
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

    /// Sequences selected in the outline or grid, in row order (for Insert / Overwrite).
    public var selectedSequenceIDs: [Timeline.ID] {
        if viewMode == .icons { return grid.selection.compactMap { if case .sequence(let id) = $0 { id } else { nil } } }
        return outline.selectedRowIndexes.compactMap { row in
            guard case .sequence(let id)? = (outline.item(atRow: row) as? Node)?.ref else { return nil }
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

    /// Media files and folders import as media; other Sequence Studio projects (`.sqproj` packages) import as a bin.
    /// A package is never walked as a folder: its `project.json` is not media.
    public func importURLs(_ urls: [URL]) {
        let projects = urls.filter(ProjectFile.isProjectURL)
        let files = urls.filter { !ProjectFile.isProjectURL($0) }.flatMap { Self.expand($0) }
        Task {
            if !files.isEmpty { await model.importFiles(files) }
            if !projects.isEmpty { await importProjects(projects) }
        }
    }

    private func importProjects(_ urls: [URL]) async {
        await model.importProjects(urls)
        if let e = model.projectImportError { SQDialog.warn(e.title, message: e.detail, in: window) }
    }

    /// File > Import Project…: shows an open panel for `.sqproj` projects and imports the chosen ones as bins.
    public func runImportProjectPanel() {
        let panel = NSOpenPanel()
        panel.message = SQL10n.format("Choose Sequence Studio projects (.%@)", ProjectFile.fileExtension)
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importProjects(urls) }
    }

    /// Folders contribute their files (recursively, no hidden files).
    private static func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (e?.allObjects as? [URL] ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .filter { !ProjectPanelModel.isSidecar($0) }
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
            // Indexes of the re-ordered root level (sequences first) are not bin positions: append instead.
            let grouped = item == nil && rootItems().map(\.ref) != model.project.rootBin.children.map(\.ref)
            if index >= 0, !grouped, model.sortColumn == nil, !model.isFiltering {
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
        grid.menuItems = { [weak self] targets in self?.menuItems(targets: targets) ?? [] }
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

    public func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        defaults.set(viewMode.rawValue, forKey: "ProjectPanel.viewMode")
        if viewMode == .icons { model.browseBin = model.project.rootBin.id; model.currentBin = model.browseBin }   // the grid shows currentBin
        applyMode()
        reload()
    }

    /// New folder in the current bin (header folder button).
    public func newFolder() { menuNewBin() }

    /// Header "..." menu (board: after List, Icons and Folder): import and creation, then the view mode.
    public func showOptions(from sender: NSView) {
        let rows: [SQMenuItem] = [
            SQMenuItem(title: "Import…") { [weak self] in self?.menuImport() },
            SQMenuItem(title: "New Folder") { [weak self] in self?.menuNewBin() },
            SQMenuItem(title: "New Color Matte…") { [weak self] in self?.newColorMatte() },
            .separator,
            SQMenuItem(title: "as List", isChecked: viewMode == .list) { [weak self] in self?.setViewMode(.list) },
            SQMenuItem(title: "as Icons", isChecked: viewMode == .icons) { [weak self] in self?.setViewMode(.icons) },
            .separator,
            SQMenuItem(title: "Search", isChecked: isSearchVisible) { [weak self] in self?.toggleSearch() },
            .separator,
        ] + ProjectPanelModel.MediaFilter.allCases.map { f in
            SQMenuItem(title: f.title, isChecked: model.mediaFilter == f) { [weak self] in self?.model.mediaFilter = f }
        } + smartBinMenuItems()
        SQContextMenu.popUp(items: rows, at: NSPoint(x: sender.bounds.minX, y: sender.isFlipped ? sender.bounds.maxY : sender.bounds.minY), in: sender)
    }
    public func newColorMatte() { onNewColorMatte?() }

    /// Smart bins in the header menu: Save Filter as Smart Folder, one checked row per saved bin (click shows its media,
    /// click again returns to the folders), and Delete rows.
    private func smartBinMenuItems() -> [SQMenuItem] {
        var rows: [SQMenuItem] = [.separator]
        rows.append(SQMenuItem(title: "Search Spoken Words", isChecked: model.searchSpoken) { [weak self] in
            guard let self else { return }
            model.searchSpoken.toggle(); reload()
        })
        rows.append(SQMenuItem(title: "Save Filter as Smart Folder") { [weak self] in self?.saveFilterAsSmartBin() })
        for sb in model.project.smartBinList {
            rows.append(SQMenuItem(title: sb.name, isChecked: model.activeSmartBin == sb.id) { [weak self] in
                guard let self else { return }
                model.activeSmartBin = model.activeSmartBin == sb.id ? nil : sb.id
                if viewMode == .icons { model.browseBin = model.project.rootBin.id; model.currentBin = model.browseBin }
                reload()
            })
        }
        for sb in model.project.smartBinList {
            rows.append(SQMenuItem(title: "Delete Smart Folder \"\(sb.name)\"") { [weak self] in
                _ = self?.model.removeSmartBin(sb.id); self?.reload()
            })
        }
        return rows
    }

    /// Saves the header's search text and Unused / Offline choice as a smart bin named after them.
    public func saveFilterAsSmartBin() {
        let q = model.searchText.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? model.mediaFilter.title : q
        let taken = Set(model.project.smartBinList.map(\.name))
        var name = base, n = 2
        while taken.contains(name) { name = "\(base) \(n)"; n += 1 }
        _ = model.addSmartBin(model.currentFilterAsSmartBin(name: name))
    }

    /// Shows or hides the search row (kept per user); hiding it clears the search, showing it puts the cursor in the field.
    public func toggleSearch() {
        isSearchVisible.toggle()
        defaults.set(isSearchVisible, forKey: Self.searchVisibleKey)
        search.isHidden = !isSearchVisible
        filterBar.isHidden = !isSearchVisible
        updateCrumbTop()
        if isSearchVisible {
            window?.makeFirstResponder(search)
        } else if !search.stringValue.isEmpty || !model.filterTokens.isEmpty || model.grouping != .folders {
            search.stringValue = ""
            model.searchText = ""
            model.filterTokens = []
            model.grouping = .folders
            reload()
        }
    }

    /// Cmd+[ / Cmd+]: icon size one step (16 pt) smaller or larger, within the slider range. Icon view only.
    public func stepThumbnailSize(larger: Bool) {
        guard viewMode == .icons else { return }
        let v = min(sizeSlider.maxValue, max(sizeSlider.minValue, sizeSlider.doubleValue + (larger ? 16 : -16)))
        sizeSlider.doubleValue = v
        sizeChanged()
    }

    @objc private func sizeChanged() { grid.thumbSize = CGFloat(sizeSlider.doubleValue); grid.reload() }

    private func goUp() {
        guard let parent = model.project.rootBin.parent(of: .bin(model.browseBin)) else { return }
        model.browseBin = parent
        model.currentBin = parent
    }

    private func applyMode() {
        let icons = viewMode == .icons
        scroll.isHidden = icons
        grid.isHidden = !icons
        sizeSlider.isHidden = !icons
        listButton.isHidden = !icons
        binLabel.isHidden = !icons
        updateStatusRow()
        crumbHeightC?.constant = icons ? Self.crumbHeight : 0
        binLabel.isHidden = !icons
        updateBinLabel()
        updateEmptyState()
        onItemCountChange?(itemCountText)
    }

    /// "Import media (⌘I) or drag files here", the key read from the live key map.
    static var emptyHint: String { "Drop files here or press " + (CommandMap.current.binding(for: .importMedia).map { KeyboardListing.text(for: $0) } ?? "the Import key") + " to import." }

    /// The list shows its own empty state (the icon grid has one too): nothing imported, or a search without hits.
    private func updateEmptyState() {
        let searching = !model.searchText.isEmpty
        emptyState.title = searching ? "No results" : "No media yet"
        emptyState.hint = searching ? Self.noResultsHint(model.searchText) : Self.emptyHint
        emptyState.mascot = searching ? .searchEmpty : .projectEmpty   // M6 / M3
        let refs = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? Node)?.ref }
        let show = viewMode == .list && Self.showsEmptyState(refs, searching: searching)
        emptyState.isHidden = !show
        emptyTopC.constant = show && outline.numberOfRows > 0 ? outline.rect(ofRow: outline.numberOfRows - 1).maxY : 0
        // v9 "No media yet": the button under the hint opens the import panel.
        emptyState.setAction(title: searching ? nil : "Import\u{2026}", handler: searching ? nil : { [weak self] in self?.menuImport() })
        grid.setEmptyState(searching: searching, hint: searching ? Self.noResultsHint(model.searchText) : Self.emptyHint)
    }

    /// The empty hint shows while there is no media to see. A fresh project already lists its first sequence (and bins),
    /// which must not hide it; a search without hits shows it only when nothing at all matches.
    static func showsEmptyState(_ refs: [BinItemRef], searching: Bool) -> Bool {
        searching ? refs.isEmpty : !refs.contains { if case .media = $0 { true } else { false } }
    }

    static func noResultsHint(_ query: String) -> String { "Nothing here matches \u{201C}\(query)\u{201D}." }

    private func updateBinLabel() {
        guard viewMode == .icons else { return }
        let b = model.project.bin(model.browseBin) ?? model.project.rootBin
        binLabel.stringValue = b.id == model.project.rootBin.id ? "Project" : "Project \u{203A} " + b.name
    }

    // MARK: Context menu

    private var menuTargets: [BinItemRef] = []

    private func outlineMenuItems(clickedRow clicked: Int) -> [SQMenuItem] {
        if clicked >= 0, !outline.selectedRowIndexes.contains(clicked) {
            outline.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        let rows = clicked >= 0 ? outline.selectedRowIndexes : []
        return menuItems(targets: rows.compactMap { (outline.item(atRow: $0) as? Node)?.ref })
    }

    /// Premiere's three Project menus in one place: empty area, bin, item. Entries for features we do not have are left out.
    private func menuItems(targets: [BinItemRef]) -> [SQMenuItem] {
        menuTargets = targets
        let media = mediaTargets
        let nonBin = targets.filter { if case .bin = $0 { false } else { true } }
        let labels = Set(nonBin.map { model.label(of: $0) })
        let sounds = media.map { model.project.media($0)?.info?.audio }
        let counts = media.map { id in model.project.media(id).flatMap { r in r.info?.audio?.mappableChannels(path: r.path) } }
        let sameChannels = counts.allSatisfy { $0 == counts[0] }
        let sameMap = sounds.allSatisfy { $0?.channelMap == sounds[0]?.channelMap }
        var c = ProjectPanelMenus.Context(
            media: media,
            hasBin: targets.contains { if case .bin = $0 { true } else { false } },
            hasSequence: targets.contains { if case .sequence = $0 { true } else { false } },
            targetCount: targets.count,
            allMediaOnline: !media.isEmpty && media.allSatisfy { !model.isOffline($0) },
            singleMediaOffline: media.count == 1 && model.isOffline(media[0]),
            singleMediaHasPoster: media.count == 1 && model.project.media(media[0])?.posterTime != nil,
            singleMediaHasMarks: media.count == 1 && !model.project.sourceMarks(for: media[0]).isEmpty,
            sharedLabel: labels.count == 1 ? labels.first : nil,
            firstLabel: nonBin.first.map { model.label(of: $0) },
            hasNonBinTarget: !nonBin.isEmpty,
            isIconView: viewMode == .icons,
            canGoUp: model.browseBin != model.project.rootBin.id,
            hoverScrub: hoverScrubEnabled,
            pixelAspect: pixelAspectState(media))
        if sameChannels, let first = sounds.first { c.audioChannels = counts.first.flatMap { $0 } ?? 0; c.audioChannelMap = sameMap ? first?.channelMap : nil }
        c.deinterlace = model.deinterlaceState(media)
        c.anyMediaUsed = media.contains { !model.project.sequenceNames(using: $0).isEmpty }
        c.canFillReel = canFillReel()
        c.canConformToCFR = media.contains { id in model.project.media(id).map(ConstantFrameRateConform.isEligible) ?? false }
        return ProjectPanelMenus.items(c) { [weak self] in self?.run($0) }
    }

    private func run(_ action: ProjectPanelMenus.Action) {
        switch action {
        case .newFolder: menuNewBin()
        case .newColorMatte: onNewColorMatte?()
        case .newSequence: menuNewSequence()
        case .importMedia: menuImport()
        case .find: menuFind()
        case .goUp: goUp()
        case .toggleHoverScrub: menuToggleHoverScrub()
        case .openInSource: menuOpenSource()
        case .openInTimeline: menuOpenSequence()
        case .insert: menuInsert()
        case .overwrite: menuOverwrite()
        case .sequenceFromClip: menuSequenceFromClip()
        case .createAnglesClip: if mediaTargets.count >= 2 { onCreateAnglesClip?(mediaTargets) }
        case .fillReel: if !mediaTargets.isEmpty { onFillReel?(mediaTargets) }
        case .makeSubclip: menuMakeSubclip()
        case .editOriginal: menuEditOriginal()
        case .rename: menuRename()
        case .deletePoster: menuClearPoster()
        case .reveal: menuReveal()
        case .replaceMedia: menuReplaceFootage()
        case .locateMedia: if let id = mediaTargets.first { onLocateMedia?(id) }
        case .delete: menuDelete()
        case .clearUsedMedia: clearSelection()
        case .extractAudio: if let id = mediaTargets.first { onExtractAudio?(id) }
        case .conformToConstantFrameRate:
            let ids = mediaTargets.filter { id in model.project.media(id).map(ConstantFrameRateConform.isEligible) ?? false }
            if !ids.isEmpty { onConformToConstantFrameRate?(ids) }
        case .setPixelAspect(let a): _ = model.setPixelAspect(a, for: menuTargets)
        case .customPixelAspect: menuCustomPixelAspect()
        case .setDeinterlace(let on): _ = model.setDeinterlace(on, for: menuTargets)
        case .setLabel(let l): model.setLabel(l, for: menuTargets)
        case .selectLabelGroup(let l): selectLabelGroup(l)
        case .toggleColumn(let col): toggleColumn(col)
        case .resetColumns: resetColumns()
        case .setAudioChannels(let map): model.setAudioChannels(map, for: menuTargets)
        }
    }

    private func menuNewSequence() { onNewSequence?() }
    private func menuImport() { onImportRequest?() ?? runImportPanel() }
    private func menuOpenSource() { if let id = selectedMediaIDs.first ?? mediaTargets.first { onOpenMedia?(id) } }
    private func menuOpenSequence() { if case .sequence(let id)? = menuTargets.first { onOpenSequence?(id) } }
    private func menuInsert() { placeTargets(.insert) }
    private func menuOverwrite() { placeTargets(.overwrite) }
    private func placeTargets(_ mode: ThreePointMode) {
        if mediaTargets.isEmpty, !sequenceTargets.isEmpty { onPlaceSequences?(sequenceTargets, mode) } else { onPlace?(mediaTargets, mode) }
    }
    private var sequenceTargets: [Timeline.ID] { menuTargets.compactMap { if case .sequence(let id) = $0 { id } else { nil } } }
    private func menuSequenceFromClip() { if let id = mediaTargets.first { onNewSequenceFromClip?(id) } }
    private func menuMakeSubclip() { if let id = mediaTargets.first { onMakeSubclip?(id) } }
    private func menuEditOriginal() { if !mediaTargets.isEmpty { onEditOriginal?(mediaTargets) } }
    private func menuReplaceFootage() { if let id = mediaTargets.first { onReplaceFootage?(id) } }
    private var mediaTargets: [MediaRef.ID] { menuTargets.compactMap { if case .media(let id) = $0 { id } else { nil } } }

    private func selectLabelGroup(_ l: LabelColor) {
        let rows = IndexSet(model.project.items(withLabel: l).compactMap { nodes[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    /// Cmd+B: a new bin in the current bin, named in place.
    public func newBin() { menuNewBin() }

    private func menuNewBin() {
        if viewMode == .icons { model.currentBin = model.browseBin }
        guard let id = model.newBin(name: "Untitled Folder") else { return }
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
    private func menuRename() { renameSelection() }
    private func menuDelete() { deleteSelection() }
    private func menuClearPoster() { _ = model.setPoster(nil, for: menuTargets) }
    private func menuFind() { showFind() }
    private func menuToggleHoverScrub() { hoverScrubEnabled.toggle() }
    private func menuReveal() {
        let urls = menuTargets.compactMap { r -> URL? in
            if case .media(let id) = r, let m = model.project.media(id) { return URL(fileURLWithPath: m.path) }
            return nil
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}


extension ProjectPanelView {
    /// F7.3: the Pixel Aspect row is offered when every selected item is a media item with a picture (stills included).
    func pixelAspectState(_ media: [MediaRef.ID]) -> PixelAspectMenu.State? {
        PixelAspectChoices.state(project: model.project, media: media)
    }

    func menuCustomPixelAspect() { customPixelAspect(for: menuTargets) }

    private func customPixelAspect(for targets: [BinItemRef]) {
        guard let window else { return }
        let first = targets.compactMap { r -> PixelAspect? in
            if case .media(let id) = r { return model.project.pixelAspect(of: id) } else { return nil }
        }.first ?? .square
        PixelAspectMenu.presentCustom(on: window, initial: first) { [weak self] a in _ = self?.model.setPixelAspect(a, for: targets) }
    }

    // The menu bar's Clip > Pixel Aspect acts on the selection with the same model call as the item's context menu.
    private var selectedMediaRefs: [BinItemRef] { selectedMediaIDs.map { .media($0) } }
    /// What the selected media items say now; nil when nothing is selected or an item has no picture.
    public func selectionPixelAspectState() -> PixelAspectMenu.State? { pixelAspectState(selectedMediaIDs) }
    public func setSelectionPixelAspect(_ aspect: PixelAspect?) { _ = model.setPixelAspect(aspect, for: selectedMediaRefs) }
    public func customSelectionPixelAspect() { customPixelAspect(for: selectedMediaRefs) }
}
