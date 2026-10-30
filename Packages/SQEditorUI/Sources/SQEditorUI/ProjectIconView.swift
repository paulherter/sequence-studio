import AppKit
import SQCore

/// One cell of the icon view: thumbnail (hover scrubs it), duration badge, label strip, name.
@MainActor
final class ProjectIconCell: NSView {
    static let nameHeight: CGFloat = LibraryTile.nameHeight
    /// Board tile: 6 pt margin (room for the 2 pt ring), picture 96 x 60 (radius 5), name 5 pt below.
    static func cellSize(thumb: CGFloat) -> NSSize { NSSize(width: thumb + 12, height: (thumb * LibraryTile.aspect).rounded() + LibraryTile.nameGap + nameHeight + 12) }

    let imageView = NSImageView()
    let badge = NSTextField(labelWithString: "")
    let nameField = NSTextField(labelWithString: "")
    let strip = NSView()
    /// Used bar: accent line over the label strip, as wide as the share of the clip the sequences use (0 = hidden).
    let usedBar = NSView()
    var usedFraction: Double = 0 { didSet { if usedFraction != oldValue { needsLayout = true } } }
    let typeChip = ProjectTypeChip()
    let scrubLine = NSView()
    var isSelected = false { didSet { needsDisplay = true } }
    /// The grid has keyboard focus: the selection shows the focused fill (the same pair every list uses).
    var isFocused = false { didSet { if isSelected { needsDisplay = true } } }
    var isOffline = false
    /// Label color of the small box behind the type icon left of the name (nil for folders / offline: no icon).
    var plate: LabelColor? { didSet { applyPlate(); needsDisplay = true } }
    var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    let typeIcon = NSImageView()
    var onRename: ((String) -> Void)?
    private(set) var thumbRect = NSRect.zero
    static let plateInset: CGFloat = 5
    static let iconWidth: CGFloat = 12

    /// Name strip under the picture (hover lift and selection outline), one point taller than the text line.
    var plateRect: NSRect {
        NSRect(x: thumbRect.minX, y: thumbRect.maxY + LibraryTile.nameGap - 1, width: thumbRect.width, height: Self.nameHeight + 2)
    }

    /// Box behind the type icon, inside the name strip.
    var iconBoxRect: NSRect {
        let h = Self.nameHeight - 2
        return NSRect(x: thumbRect.minX + Self.plateInset - 2, y: thumbRect.maxY + LibraryTile.nameGap + 1, width: Self.iconWidth + 4, height: h)
    }

    private func applyPlate() {
        typeIcon.isHidden = plate == nil
        typeIcon.contentTintColor = plate?.onFill
        nameField.textColor = isOffline ? Theme.Colors.red : Theme.Colors.label
        needsLayout = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = Theme.Colors.tileBackground.cgColor
        imageView.layer?.cornerRadius = LibraryTile.thumbRadius
        imageView.layer?.masksToBounds = true
        badge.font = Theme.Typography.caption
        badge.textColor = Theme.Colors.label
        badge.wantsLayer = true
        badge.layer?.backgroundColor = Theme.OnPicture.hudFill.cgColor
        badge.layer?.cornerRadius = Theme.Radius.small
        nameField.font = Theme.Typography.body
        nameField.textColor = Theme.Colors.label
        nameField.alignment = .left
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1
        nameField.delegate = self
        strip.wantsLayer = true
        usedBar.wantsLayer = true
        usedBar.layer?.backgroundColor = Theme.Colors.accent.cgColor
        scrubLine.wantsLayer = true
        scrubLine.layer?.backgroundColor = Theme.Colors.accent.cgColor
        scrubLine.isHidden = true
        typeIcon.imageScaling = .scaleProportionallyDown
        typeIcon.isHidden = true
        for v in [imageView, strip, usedBar, typeChip, badge, scrubLine, typeIcon, nameField] { addSubview(v) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width - 12
        thumbRect = NSRect(x: 6, y: 6, width: w, height: (w * LibraryTile.aspect).rounded())
        imageView.frame = thumbRect
        strip.frame = NSRect(x: thumbRect.minX, y: thumbRect.maxY - 3, width: thumbRect.width, height: 3)
        usedBar.isHidden = usedFraction <= 0
        usedBar.frame = NSRect(x: thumbRect.minX, y: thumbRect.maxY - 5, width: (thumbRect.width * CGFloat(min(1, usedFraction))).rounded(.up), height: 2)
        scrubLine.frame = NSRect(x: thumbRect.minX, y: thumbRect.minY, width: 1.5, height: thumbRect.height)
        typeChip.frame = NSRect(x: thumbRect.minX + 4, y: thumbRect.minY + 4, width: 16, height: 9)
        badge.sizeToFit()
        let bs = badge.frame.size
        badge.frame = NSRect(x: thumbRect.maxX - bs.width - 3, y: thumbRect.maxY - bs.height - 6, width: bs.width, height: bs.height)
        let nameY = thumbRect.maxY + LibraryTile.nameGap
        var x = thumbRect.minX + Self.plateInset
        if plate != nil {
            typeIcon.frame = NSRect(x: x, y: nameY, width: Self.iconWidth, height: Self.nameHeight)
            x += Self.iconWidth + 5
        }
        nameField.frame = NSRect(x: x, y: nameY, width: max(0, thumbRect.maxX - Self.plateInset - x), height: Self.nameHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered && !isSelected {
            Theme.Selection.hover.setFill()
            NSBezierPath(roundedRect: plateRect, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        }
        // Label color (the timeline clip fill) only as a small rounded box behind the type icon.
        if let plate {
            plate.fill.setFill()
            NSBezierPath(roundedRect: iconBoxRect, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
        }
        guard isSelected else { return }
        // Selection = accent outline around the label plate and a ring around the picture.
        let r = LibraryTile.ringWidth
        let ring = NSBezierPath(roundedRect: thumbRect.insetBy(dx: -r / 2, dy: -r / 2),
                                xRadius: LibraryTile.thumbRadius + r / 2, yRadius: LibraryTile.thumbRadius + r / 2)
        ring.lineWidth = r
        Theme.Colors.accent.setStroke()
        ring.stroke()
        let outline = NSBezierPath(roundedRect: plateRect.insetBy(dx: -r / 2, dy: -r / 2),
                                   xRadius: Theme.Radius.small + r / 2, yRadius: Theme.Radius.small + r / 2)
        outline.lineWidth = r
        outline.stroke()
    }

    func beginRename() {
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.drawsBackground = true
        nameField.backgroundColor = Theme.Colors.field
        window?.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }
}

extension ProjectIconCell: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        nameField.isEditable = false
        nameField.drawsBackground = false
        onRename?(nameField.stringValue)
    }
}

/// Icon view of the Project panel: the items of one bin as thumbnails. Hover over a clip scrubs it. All state lives in
/// `ProjectPanelModel`; this view only draws and reports gestures.
@MainActor
final class ProjectIconView: NSView {
    let model: ProjectPanelModel
    private let thumbs = ProjectThumbnails()
    private let scroll = NSScrollView()
    private let content = IconContentView()
    private var cells: [BinItemRef: ProjectIconCell] = [:]
    private(set) var items: [BinItemRef] = []
    private(set) var selection: [BinItemRef] = []
    private var anchor: BinItemRef?
    private var hovered: BinItemRef?
    /// Media time under the pointer while hover scrubbing (nil when not hovering a picture).
    private(set) var hoveredTime: Time?
    /// The media item under the pointer while hover scrubbing.
    var hoveredMedia: MediaRef.ID? { if case .media(let id)? = hovered { id } else { nil } }
    /// Hover Scrub on/off (Shift+H). While off, holding Shift scrubs temporarily (Premiere).
    var hoverScrubEnabled = true { didSet { if !hoverScrubEnabled { endHover() } } }
    private var posterSeen: [UUID: Time?] = [:]
    var thumbSize: CGFloat = 96 { didSet { relayout() } }

    private let emptyState = EmptyStateView(title: "No media yet")
    var emptyStateForTesting: EmptyStateView { emptyState }
    private lazy var emptyTopC = emptyState.topAnchor.constraint(equalTo: topAnchor)
    private var emptySearching = false

    /// Text of the empty grid: a search without hits, or an empty project.
    func setEmptyState(searching: Bool, hint: String) {
        emptyState.title = searching ? "No results" : "No media yet"
        emptyState.hint = hint
        emptySearching = searching
        updateEmptyVisibility()
        emptyState.mascot = searching ? .searchEmpty : .projectEmpty
    }

    /// Pip and the hint show while the grid has no media (sequences and bins do not count), below the last tile row.
    private func updateEmptyVisibility() {
        let show = ProjectPanelView.showsEmptyState(items, searching: emptySearching)
        emptyState.isHidden = !show
        let cell = ProjectIconCell.cellSize(thumb: thumbSize)
        let width = max(scroll.contentSize.width, cell.width)
        let cols = max(1, Int(width / cell.width))
        let rows = (items.count + cols - 1) / cols
        emptyTopC.constant = show && !items.isEmpty ? CGFloat(rows) * cell.height + 8 : 0
    }

    var onOpen: ((BinItemRef) -> Void)?
    /// `I` / `O` over a hovered media thumbnail: media, time under the pointer.
    var onHoverMark: ((Bool, MediaRef.ID, Time) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRename: ((BinItemRef, String) -> Void)?
    var onDropOnto: ((NSDraggingInfo, Bin.ID) -> Bool)?
    var validateDrop: ((NSDraggingInfo, Bin.ID) -> NSDragOperation)?
    var menuItems: (([BinItemRef]) -> [SQMenuItem])?
    var pasteboardWriter: ((BinItemRef) -> NSPasteboardWriting?)?

    init(model: ProjectPanelModel) {
        self.model = model
        super.init(frame: .zero)
        content.owner = self
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.Colors.content
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyTopC, emptyState.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor), emptyState.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        content.registerForDraggedTypes([.fileURL, .sequenceMediaIDs])
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        content.sqItems = { [weak self] p in self?.contextItems(at: p) ?? [] }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); relayout() }

    // MARK: Content

    func reload() {
        let bin = model.project.bin(model.currentBin) ?? model.project.rootBin
        items = model.children(of: bin).map(\.ref)
        // shortcut: "Sorted by" shows one flat grid (no day/camera headings) in icon view; add section headers when wanted.
        if model.grouping != .folders, model.activeSmartBin == nil {
            items = items.flatMap { ref -> [BinItemRef] in
                guard case .bin(let id) = ref, let g = model.displayBin(id) else { return [ref] }
                return model.children(of: g).map(\.ref)
            }
        }
        let alive = Set(items)
        for (k, c) in cells where !alive.contains(k) { c.removeFromSuperview(); cells[k] = nil }
        selection = selection.filter(alive.contains)
        updateEmptyVisibility()
        for ref in items {
            let cell = cells[ref] ?? makeCell(ref)
            configure(cell, ref)
        }
        relayout()
    }

    private func makeCell(_ ref: BinItemRef) -> ProjectIconCell {
        let c = ProjectIconCell(frame: .zero)
        c.onRename = { [weak self] name in self?.onRename?(ref, name) }
        content.addSubview(c)
        cells[ref] = c
        return c
    }

    private func configure(_ cell: ProjectIconCell, _ ref: BinItemRef) {
        let offline: Bool
        if case .media(let id) = ref { offline = model.isOffline(id) } else { offline = false }
        cell.isOffline = offline
        if case .media(let id) = ref { cell.usedFraction = model.usedFraction(of: id) ?? 0 } else { cell.usedFraction = 0 }
        let kind = model.itemKind(of: ref)
        cell.typeChip.tints = model.tints(of: ref)
        cell.nameField.stringValue = model.project.displayName(of: ref)
        cell.plate = model.plateLabel(of: ref)
        cell.typeIcon.image = Theme.symbol(SQIcon(rawValue: model.icon(of: ref).symbol) ?? .unknown, size: 11)
        cell.isSelected = selection.contains(ref)
        cell.isFocused = gridFocused
        var dur = model.cellText(.duration, ref)
        if dur.hasPrefix("00:") { dur.removeFirst(3) }
        cell.badge.stringValue = " " + dur + " "
        cell.badge.isHidden = dur.isEmpty
        if case .bin = ref { cell.strip.isHidden = true } else {
            cell.strip.isHidden = false
            cell.strip.layer?.backgroundColor = Theme.hex(model.label(of: ref).rgb).cgColor
        }
        let height = Int(thumbSize * LibraryTile.aspect * (window?.backingScaleFactor ?? 2))
        switch ref {
        case .media(let id):
            if offline {
                thumbs.clearFailure(id)          // back online later: the poster is tried again
                cell.imageView.image = symbol(.warning, Theme.Colors.red)
            } else if let ref = model.project.media(id) {
                if let seen = posterSeen[id], seen != ref.posterTime { thumbs.forget(id) }
                posterSeen[id] = ref.posterTime
                if let img = thumbs.poster(for: ref) { cell.imageView.image = img } else {
                    cell.imageView.image = symbol(SQIcon(rawValue: model.icon(of: .media(id)).symbol) ?? .unknown, (model.tints(of: .media(id)).first ?? .videoDefault).fill)
                }
                if ref.kind != .audio {          // no-op while the cached poster is sharp enough for this thumbnail size
                    thumbs.requestPoster(ref, height: height) { [weak self] in
                        guard let self, let c = cells[.media(id)], hovered != .media(id) else { return }
                        c.imageView.image = thumbs.cachedPoster(id) ?? c.imageView.image
                    }
                }
            }
        case .bin: cell.imageView.image = symbol(.folderFilled, LabelColor.binDefault.fill)
        case .sequence: cell.imageView.image = symbol(.sequence, model.project.label(of: ref).fill)
        }
        cell.needsLayout = true
    }

    private func symbol(_ name: SQIcon, _ color: NSColor) -> NSImage? {
        name.image(size: thumbSize * 0.28, color: color)
    }

    func forgetThumbnail(_ id: MediaRef.ID) { thumbs.forget(id) }

    private func relayout() {
        let cell = ProjectIconCell.cellSize(thumb: thumbSize)
        let width = max(scroll.contentSize.width, cell.width)
        let cols = max(1, Int(width / cell.width))
        let rows = (items.count + cols - 1) / cols
        let spacing = (width - CGFloat(cols) * cell.width) / CGFloat(cols + 1)
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(CGFloat(rows) * cell.height + 8, scroll.contentSize.height))
        for (i, ref) in items.enumerated() {
            guard let c = cells[ref] else { continue }
            let col = i % cols, row = i / cols
            c.frame = NSRect(x: spacing + CGFloat(col) * (cell.width + spacing), y: 4 + CGFloat(row) * cell.height,
                             width: cell.width, height: cell.height)
        }
        updateVisiblePosters()
    }

    @objc private func scrolled() { updateVisiblePosters() }

    /// Tells the poster loader which media are on screen (plus half a screen below), top-left first: those load first.
    private func updateVisiblePosters() {
        let seen = content.visibleRect
        let r = seen.isEmpty ? seen : NSRect(x: seen.minX, y: seen.minY, width: seen.width, height: seen.height * 1.5)
        var ids: [UUID] = []
        if !r.isEmpty {
            for ref in items {
                guard case .media(let id) = ref, let c = cells[ref], c.frame.intersects(r) else { continue }
                ids.append(id)
            }
        }
        thumbs.setVisible(ids)
    }

    // MARK: Selection

    private var gridFocused = false
    func setFocused(_ on: Bool) {
        gridFocused = on
        for c in cells.values { c.isFocused = on }
    }

    func setSelection(_ refs: [BinItemRef]) {
        selection = refs.filter(items.contains)
        for (k, c) in cells { c.isSelected = selection.contains(k) }
        onSelectionChange?()
    }

    func item(at point: NSPoint) -> BinItemRef? { items.first { cells[$0]?.frame.contains(point) == true } }

    fileprivate func mouseDown(_ event: NSEvent, at p: NSPoint) {
        window?.makeFirstResponder(content)
        guard let hit = item(at: p) else {
            setSelection([]); return
        }
        if event.clickCount == 2 { onOpen?(hit); return }
        if event.modifierFlags.contains(.command) {
            var s = selection
            if let i = s.firstIndex(of: hit) { s.remove(at: i) } else { s.append(hit) }
            setSelection(s); anchor = hit
        } else if event.modifierFlags.contains(.shift), let a = anchor, let i = items.firstIndex(of: a), let j = items.firstIndex(of: hit) {
            setSelection(Array(items[min(i, j)...max(i, j)]))
        } else {
            if !selection.contains(hit) { setSelection([hit]) }
            anchor = hit
        }
    }

    fileprivate func mouseUp(at p: NSPoint) {
        // A plain click on one of several selected items narrows the selection to it.
        if let hit = item(at: p), selection.count > 1, !(NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)) {
            setSelection([hit])
        }
    }

    fileprivate func startDrag(_ event: NSEvent, at p: NSPoint) {
        guard let hit = item(at: p), selection.contains(hit) else { return }
        let refs = selection
        var dragItems: [NSDraggingItem] = []
        for r in refs {
            guard let w = pasteboardWriter?(r), let cell = cells[r] else { continue }
            let d = NSDraggingItem(pasteboardWriter: w)
            let img = cell.imageView.image ?? NSImage()
            d.setDraggingFrame(NSRect(x: cell.frame.minX + 6, y: cell.frame.minY + 6, width: 90, height: 51), contents: img)
            dragItems.append(d)
        }
        guard !dragItems.isEmpty else { return }
        content.beginDraggingSession(with: dragItems, event: event, source: content)
    }

    func selectAllItems() { setSelection(items) }

    func beginRenameSelected() {
        guard selection.count == 1, let c = cells[selection[0]] else { return }
        c.beginRename()
    }

    /// `I` / `O` while hovering a clip's picture sets that clip's Source In / Out at the hovered frame.
    func handleHoverMark(isIn: Bool) -> Bool {
        guard let h = hovered, case .media(let id) = h, let t = hoveredTime else { return false }
        onHoverMark?(isIn, id, t)
        return true
    }

    func keyDown(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let c = event.charactersIgnoringModifiers?.lowercased(), c == "i" || c == "o", handleHoverMark(isIn: c == "i") { return true }
        switch event.keyCode {
        case 51, 117: onDelete?(); return true
        case 36, 76: beginRenameSelected(); return true
        case 123, 124, 125, 126: moveSelection(event); return true
        default: return false
        }
    }

    private func moveSelection(_ event: NSEvent) {
        guard !items.isEmpty else { return }
        let cols = max(1, Int(max(scroll.contentSize.width, ProjectIconCell.cellSize(thumb: thumbSize).width) / ProjectIconCell.cellSize(thumb: thumbSize).width))
        let cur = selection.last.flatMap { items.firstIndex(of: $0) } ?? -1
        var next = cur
        switch event.keyCode {
        case 123: next = max(0, cur - 1)
        case 124: next = min(items.count - 1, cur + 1)
        case 125: next = cur < 0 ? 0 : min(items.count - 1, cur + cols)
        default: next = max(0, cur - cols)
        }
        setSelection([items[next]]); anchor = items[next]
        if let c = cells[items[next]] { content.scrollToVisible(c.frame) }
    }

    // MARK: Hover scrub

    private var tileHover: BinItemRef?
    fileprivate func clearTileHover() { setTileHover(nil) }
    private func setTileHover(_ ref: BinItemRef?) {
        guard ref != tileHover else { return }
        if let old = tileHover { cells[old]?.isHovered = false }
        tileHover = ref
        if let ref { cells[ref]?.isHovered = true }
    }

    fileprivate func mouseMoved(at p: NSPoint, shift: Bool = false) {
        setTileHover(item(at: p))
        guard hoverScrubEnabled || shift else { endHover(); return }
        guard let hit = item(at: p), case .media(let id) = hit, let cell = cells[hit], let ref = model.project.media(id),
              ref.kind != .audio, ref.kind != .image, !model.isOffline(id),
              let total = ref.info?.duration ?? ref.duration, total > .zero else { endHover(); return }
        let local = content.convert(p, to: cell)
        guard cell.thumbRect.contains(local) else { endHover(); return }
        if hovered != hit { endHover(); hovered = hit }
        let frac = Double((local.x - cell.thumbRect.minX) / cell.thumbRect.width)
        cell.scrubLine.isHidden = false
        cell.scrubLine.frame.origin.x = cell.thumbRect.minX + (local.x - cell.thumbRect.minX)
        let t = HoverScrub.time(fraction: frac, duration: total, frameDuration: ref.info?.video?.nominalFrameDuration ?? Time(1, 30))
        hoveredTime = t
        let height = Int(thumbSize * LibraryTile.aspect * (window?.backingScaleFactor ?? 2))
        thumbs.scrub(ref, to: t, height: height) { [weak self] img in
            guard let self, hovered == hit else { return }
            cells[hit]?.imageView.image = img
        }
    }

    fileprivate func endHover() {
        thumbs.cancelScrub()
        if let h = hovered, let c = cells[h] {
            c.scrubLine.isHidden = true
            if case .media(let id) = h, let p = thumbs.cachedPoster(id) { c.imageView.image = p }
        }
        hovered = nil
        hoveredTime = nil
    }

    // MARK: Menu

    fileprivate func contextItems(at p: CGPoint) -> [SQMenuItem] {
        if let hit = item(at: p) {
            if !selection.contains(hit) { setSelection([hit]) }
            return menuItems?(selection) ?? []
        }
        setSelection([])
        return menuItems?([]) ?? []
    }

    // MARK: Drop

    fileprivate func targetBin(for info: NSDraggingInfo) -> Bin.ID {
        let p = content.convert(info.draggingLocation, from: nil)
        if let hit = item(at: p), case .bin(let id) = hit { return id }
        return model.currentBin
    }
}

/// Document view of the icon grid: forwards mouse, drag and drop to `ProjectIconView`.
@MainActor
private final class IconContentView: NSView, NSDraggingSource, KeyClaiming {
    weak var owner: ProjectIconView?
    var sqItems: ((CGPoint) -> [SQMenuItem])?
    /// Right-click and ctrl-click: SQ rows, no NSMenu.
    override func menu(for event: NSEvent) -> NSMenu? {
        if let items = sqItems?(convert(event.locationInWindow, from: nil)), !items.isEmpty { SQContextMenu.show(items: items, for: event, in: self) }
        return nil
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { owner?.setFocused(true); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { owner?.setFocused(false); return super.resignFirstResponder() }
    var claimsArrowKeys: Bool { true }
    private var downEvent: NSEvent?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
    }

    override func mouseMoved(with event: NSEvent) { owner?.mouseMoved(at: convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift)) }
    override func mouseExited(with event: NSEvent) { owner?.endHover(); owner?.clearTileHover() }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        owner?.endHover()
        owner?.mouseDown(event, at: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let d = downEvent else { return }
        let a = convert(d.locationInWindow, from: nil), b = convert(event.locationInWindow, from: nil)
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        downEvent = nil
        owner?.startDrag(event, at: a)
    }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp(at: convert(event.locationInWindow, from: nil)); downEvent = nil }
    override func keyDown(with event: NSEvent) { if owner?.keyDown(event) != true { super.keyDown(with: event) } }
    override func selectAll(_ sender: Any?) { owner?.selectAllItems() }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy] : .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let o = owner else { return [] }
        return o.validateDrop?(sender, o.targetBin(for: sender)) ?? []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let o = owner else { return false }
        return o.onDropOnto?(sender, o.targetBin(for: sender)) ?? false
    }
}
