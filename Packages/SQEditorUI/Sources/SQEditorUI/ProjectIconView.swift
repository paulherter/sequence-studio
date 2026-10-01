import AppKit
import SQCore

/// One cell of the icon view: thumbnail (hover scrubs it), duration badge, label strip, name.
@MainActor
final class ProjectIconCell: NSView {
    static let nameHeight: CGFloat = 30
    static func cellSize(thumb: CGFloat) -> NSSize { NSSize(width: thumb + 12, height: (thumb * 9 / 16).rounded() + nameHeight + 14) }

    let imageView = NSImageView()
    let badge = NSTextField(labelWithString: "")
    let nameField = NSTextField(labelWithString: "")
    let strip = NSView()
    let scrubLine = NSView()
    var isSelected = false { didSet { needsDisplay = true } }
    var isOffline = false
    var onRename: ((String) -> Void)?
    private(set) var thumbRect = NSRect.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = Theme.Colors.viewer.cgColor
        imageView.layer?.cornerRadius = Theme.Radius.small
        imageView.layer?.masksToBounds = true
        badge.font = Theme.Fonts.mini
        badge.textColor = Theme.Colors.label
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        badge.layer?.cornerRadius = 2
        nameField.font = Theme.Fonts.small
        nameField.textColor = Theme.Colors.label
        nameField.alignment = .center
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 2
        nameField.cell?.wraps = true
        nameField.cell?.truncatesLastVisibleLine = true
        nameField.delegate = self
        strip.wantsLayer = true
        scrubLine.wantsLayer = true
        scrubLine.layer?.backgroundColor = Theme.Colors.accent.cgColor
        scrubLine.isHidden = true
        for v in [imageView, strip, badge, scrubLine, nameField] { addSubview(v) }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width - 12
        thumbRect = NSRect(x: 6, y: 6, width: w, height: (w * 9 / 16).rounded())
        imageView.frame = thumbRect
        strip.frame = NSRect(x: thumbRect.minX, y: thumbRect.maxY - 3, width: thumbRect.width, height: 3)
        scrubLine.frame = NSRect(x: thumbRect.minX, y: thumbRect.minY, width: 1.5, height: thumbRect.height)
        badge.sizeToFit()
        let bs = badge.frame.size
        badge.frame = NSRect(x: thumbRect.maxX - bs.width - 3, y: thumbRect.maxY - bs.height - 6, width: bs.width, height: bs.height)
        nameField.frame = NSRect(x: 2, y: thumbRect.maxY + 4, width: bounds.width - 4, height: Self.nameHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.Colors.accentTint.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill()
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
final class ProjectIconView: NSView, NSMenuDelegate {
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
    var thumbSize: CGFloat = 110 { didSet { relayout() } }

    var onOpen: ((BinItemRef) -> Void)?
    /// `I` / `O` over a hovered media thumbnail: media, time under the pointer.
    var onHoverMark: ((Bool, MediaRef.ID, Time) -> Void)?
    var onSelectionChange: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRename: ((BinItemRef, String) -> Void)?
    var onDropOnto: ((NSDraggingInfo, Bin.ID) -> Bool)?
    var validateDrop: ((NSDraggingInfo, Bin.ID) -> NSDragOperation)?
    var menuFill: ((NSMenu, [BinItemRef]) -> Void)?
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
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        content.registerForDraggedTypes([.fileURL, .sequenceMediaIDs])
        let menu = NSMenu(); menu.delegate = self
        content.menu = menu
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); relayout() }

    // MARK: Content

    func reload() {
        let bin = model.project.bin(model.currentBin) ?? model.project.rootBin
        items = model.children(of: bin).map(\.ref)
        let alive = Set(items)
        for (k, c) in cells where !alive.contains(k) { c.removeFromSuperview(); cells[k] = nil }
        selection = selection.filter(alive.contains)
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
        cell.nameField.stringValue = model.project.displayName(of: ref)
        cell.nameField.textColor = offline ? Theme.Colors.red : Theme.Colors.label
        cell.isSelected = selection.contains(ref)
        var dur = model.cellText(.duration, ref)
        if dur.hasPrefix("00:") { dur.removeFirst(3) }
        cell.badge.stringValue = " " + dur + " "
        cell.badge.isHidden = dur.isEmpty
        if case .bin = ref { cell.strip.isHidden = true } else {
            cell.strip.isHidden = false
            cell.strip.layer?.backgroundColor = Theme.hex(model.label(of: ref).rgb).cgColor
        }
        let height = Int(thumbSize * 9 / 16 * (window?.backingScaleFactor ?? 2))
        switch ref {
        case .media(let id):
            if offline {
                cell.imageView.image = symbol("exclamationmark.triangle", Theme.Colors.red)
            } else if let ref = model.project.media(id) {
                if let seen = posterSeen[id], seen != ref.posterTime { thumbs.forget(id) }
                posterSeen[id] = ref.posterTime
                if let img = thumbs.cachedPoster(id) { cell.imageView.image = img } else {
                    cell.imageView.image = symbol(model.icon(of: .media(id)).symbol, Theme.Colors.label3)
                    if ref.kind != .audio {
                        thumbs.requestPoster(ref, height: height) { [weak self] in
                            guard let self, let c = cells[.media(id)], hovered != .media(id) else { return }
                            c.imageView.image = thumbs.cachedPoster(id) ?? c.imageView.image
                        }
                    }
                }
            }
        case .bin: cell.imageView.image = symbol("folder.fill", Theme.Colors.label2)
        case .sequence: cell.imageView.image = symbol("film.stack", Theme.Colors.label2)
        }
        cell.needsLayout = true
    }

    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: thumbSize * 0.28, weight: .light).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
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
    }

    // MARK: Selection

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

    fileprivate func mouseMoved(at p: NSPoint, shift: Bool = false) {
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
        let height = Int(thumbSize * 9 / 16 * (window?.backingScaleFactor ?? 2))
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let p = content.convert(NSApp.currentEvent?.locationInWindow ?? .zero, from: nil)
        if let hit = item(at: p) {
            if !selection.contains(hit) { setSelection([hit]) }
            menuFill?(menu, selection)
        } else {
            setSelection([])
            menuFill?(menu, [])
        }
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
private final class IconContentView: NSView, NSDraggingSource {
    weak var owner: ProjectIconView?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var downEvent: NSEvent?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a); area = a
    }

    override func mouseMoved(with event: NSEvent) { owner?.mouseMoved(at: convert(event.locationInWindow, from: nil), shift: event.modifierFlags.contains(.shift)) }
    override func mouseExited(with event: NSEvent) { owner?.endHover() }

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
