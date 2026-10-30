import AppKit
import SQCore

/// The Graphics panel's layer list (DESIGN.md "LayerListView"): front first, 24 pt rows, group rows with a disclosure
/// chevron, kind icon, name, eye and lock. Click selects (Shift = range, Cmd = toggle), double-click renames in place
/// (SQTextField), drag reorders (2 pt accent insertion line; dropping on a group row joins the group, dropping outside a
/// group takes the layer out of it; Option copies; the list scrolls while the pointer rests at an edge), right-click opens
/// the SQ menu. Own scroll view; the footer adds layers. Pure rules live in `LayerListLogic`.
@MainActor
public final class LayerListView: NSView, NSTextFieldDelegate {
    public let editor: GraphicsEditor
    /// The panel has keyboard focus (selected rows use the focused fill).
    public var focused = false { didSet { if oldValue != focused { rowViews.forEach { $0.focused = focused } } } }
    /// A click in the list: the panel takes the keyboard (Delete, Cmd+A act on layers).
    public var onFocus: (() -> Void)?
    /// The layer selection changed from the list.
    public var onSelectionChange: (() -> Void)?
    /// An effect from the Effects panel was dropped on a layer row (the panel shows a refusal in its status line).
    public var onEffectDrop: ((GraphicsEditor.EffectDrop) -> Void)?

    public private(set) var rows: [LayerListRow] = []
    private var collapsed: Set<UUID> = []
    private var anchor: Int?

    private let scroll = NSScrollView()
    private let doc = LayerListDocument()
    private var rowViews: [LayerListRowView] = []
    private let insertion = NSView()
    private let empty: EmptyStateView = {
        let v = EmptyStateView(title: "No layers yet", hint: "Add text or a shape below.")
        return v
    }()
    /// Add / arrange buttons under the list (the panel fills it).
    public let footer = NSStackView()
    private let footerLine = SQDivider()

    // Drag
    private var pressRow: Int?
    private var pressPoint: NSPoint?
    private var drag: LayerDrag?
    private var dropGap: Int?
    private var dropOnto: Int?
    private var pressWasSelected = false
    /// Last drag event and the timer that keeps scrolling while the pointer rests at an edge (no mouse move, no event).
    private var lastDragEvent: NSEvent?
    private var dragTimer: Timer?
    /// Option is down: the drop copies instead of moving.
    private(set) var isCopying = false

    // Rename
    private var renameField: SQTextField?
    private var renaming: LayerListRow.Kind?
    private var renameCancelled = false
    /// A name field is open on a row (tests read it).
    var isRenaming: Bool { renameField != nil }

    public override var isFlipped: Bool { true }
    public static let footerHeight: CGFloat = 32

    public init(editor: GraphicsEditor) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.content.cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        addSubview(scroll)
        doc.list = self
        insertion.wantsLayer = true
        insertion.layer?.backgroundColor = Theme.Colors.accent.cgColor
        insertion.isHidden = true
        doc.addSubview(insertion)
        empty.isHidden = true
        addSubview(empty)
        footer.orientation = .horizontal
        footer.spacing = Theme.Spacing.xs
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: .zero, left: Theme.Spacing.sm, bottom: .zero, right: Theme.Spacing.sm)
        footer.wantsLayer = true
        footer.layer?.backgroundColor = Theme.Colors.panel.cgColor
        addSubview(footer)
        addSubview(footerLine)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Layers")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let fh = Self.footerHeight
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - fh, 0))
        footer.frame = NSRect(x: 0, y: max(bounds.height - fh, 0), width: bounds.width, height: fh)
        footerLine.frame = NSRect(x: 0, y: footer.frame.minY, width: bounds.width, height: Theme.Separator.width)
        empty.frame = scroll.frame
        layoutRows()
    }

    /// Only the rows in (or one row beside) the scroll window are placed and laid out; the others are hidden until they
    /// scroll in. A panel resize used to re-lay-out every row (cost grew with the layer count: GraphicsPanelResizePerfTests).
    private func layoutRows() {
        let w = scroll.contentSize.width, h = Theme.Row.list
        doc.frame = NSRect(x: 0, y: 0, width: w, height: max(CGFloat(rows.count) * h, scroll.contentSize.height))
        let visible = scroll.contentView.bounds.insetBy(dx: 0, dy: -h)
        for (i, v) in rowViews.enumerated() {
            let f = NSRect(x: 0, y: CGFloat(i) * h, width: w, height: h)
            let show = f.intersects(visible) || scroll.contentView.bounds.height <= 0
            if v.isHidden == show { v.isHidden = !show }
            if show, v.frame != f { v.frame = f }
        }
    }

    /// Rows that scrolled into view get their frame.
    @objc private func scrolled(_ note: Notification) { layoutRows() }

    // MARK: Data

    /// Rebuilds the rows from the editor (a rename in progress keeps the list as it is).
    public func reload() {
        guard renameField == nil else { return }
        guard let d = editor.document else { rows = []; rebuildViews(); return }
        collapsed = collapsed.intersection(Set(d.groups.map(\.id)))
        rows = LayerListLogic.rows(d, collapsed: collapsed)
        if let a = anchor, !rows.indices.contains(a) { anchor = nil }
        rebuildViews()
    }

    private func rebuildViews() {
        for v in rowViews { v.removeFromSuperview() }
        let d = editor.document ?? GraphicsDocument()
        let sel = editor.selectedLayers
        rowViews = rows.enumerated().map { i, r in
            let v = LayerListRowView(row: r)
            v.isSelected = LayerListLogic.isSelected(r, document: d, selection: sel)
            v.focused = focused
            v.onVisible = { [weak self] in self?.toggleVisible(i) }
            v.onLocked = { [weak self] in self?.toggleLocked(i) }
            doc.addSubview(v, positioned: .below, relativeTo: insertion)
            return v
        }
        empty.isHidden = !(rows.isEmpty && editor.document != nil)
        layoutRows()
        refreshTicks()
    }

    /// Key ticks and playhead line of every layer row (cheap; runs on every playhead or project change).
    public func refreshTicks() {
        guard let d = editor.document, let clip = editor.clip else { return }
        let inside = editor.playheadInClip
        for (i, r) in rows.enumerated() where rowViews.indices.contains(i) {
            guard let id = r.layerID, let l = d.layer(id) else { continue }
            let v = rowViews[i]
            let times = LayerListLogic.keyTimes(l)
            v.strip.times = times
            v.strip.duration = clip.duration
            v.strip.playhead = inside ? editor.localTime : nil
            v.strip.range = l.range
            v.showsStrip = !times.isEmpty || l.range != nil
            v.isOutsideRange = LayerListLogic.isOutsideRange(l, local: inside ? editor.localTime : nil)
        }
    }

    /// A playhead move only: the rows that show a strip or a range move their line, the rest stay as they are.
    func refreshPlayhead() {
        guard let d = editor.document, editor.clip != nil else { return }
        let inside = editor.playheadInClip
        let local: Time? = inside ? editor.localTime : nil
        for (i, r) in rows.enumerated() where rowViews.indices.contains(i) && rowViews[i].showsStrip {
            guard let id = r.layerID, let l = d.layer(id) else { continue }
            let v = rowViews[i]
            v.strip.playhead = local
            v.isOutsideRange = LayerListLogic.isOutsideRange(l, local: local)
        }
    }

    private func members(_ r: LayerListRow) -> Set<UUID> {
        if let id = r.layerID { return [id] }
        if let g = r.groupID { return editor.members(of: g) }
        return []
    }

    private func toggleVisible(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        let r = rows[i]
        if let id = r.layerID { editor.setVisible(id, !r.isVisible) } else { editor.setVisible(members(r), !r.isVisible) }
    }

    private func toggleLocked(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        let r = rows[i]
        if let id = r.layerID { editor.setLocked(id, !r.isLocked) } else { editor.setLocked(members(r), !r.isLocked) }
    }

    // MARK: Mouse (the document view forwards every click that is not on an eye / lock button)

    private func rowIndex(at p: NSPoint) -> Int? {
        let i = Int(floor(p.y / Theme.Row.list))
        return rows.indices.contains(i) ? i : nil
    }

    fileprivate func listMouseDown(_ event: NSEvent) {
        onFocus?()
        let p = doc.convert(event.locationInWindow, from: nil)
        guard let i = rowIndex(at: p), let d = editor.document else {
            pressRow = nil
            editor.select([]); anchor = nil; onSelectionChange?()
            return
        }
        let r = rows[i]
        // A click on a layer's key strip moves the playhead there (no selection change).
        if r.layerID != nil, let clip = editor.clip {
            let sp = rowViews[i].convert(p, from: doc)
            let f = rowViews[i].strip.frame
            if rowViews[i].showsStrip, sp.x >= f.minX, sp.x <= f.maxX, sp.y >= f.minY - 3 {
                editor.seekLocal(KeyTickStrip.time(atX: sp.x - f.minX, width: f.width, duration: clip.duration))
                pressRow = nil
                return
            }
        }
        // The chevron of a group row opens / closes it.
        if let g = r.groupID, p.x < LayerListRowView.nameX(for: r) {
            if collapsed.contains(g) { collapsed.remove(g) } else { collapsed.insert(g) }
            reload()
            return
        }
        if event.clickCount == 2 { beginRename(i); return }
        let flags = event.modifierFlags
        pressRow = i
        pressPoint = p
        pressWasSelected = LayerListLogic.isSelected(r, document: d, selection: editor.selectedLayers)
        // A press on a selected row keeps the selection until mouse up (so a drag carries all of it).
        if pressWasSelected && !flags.contains(.shift) && !flags.contains(.command) { return }
        applyClick(i, flags: flags)
    }

    private func applyClick(_ i: Int, flags: NSEvent.ModifierFlags) {
        guard let d = editor.document else { return }
        let range = flags.contains(.shift), toggle = flags.contains(.command)
        let s = LayerListLogic.select(rows: rows, document: d, current: editor.selectedLayers, index: i, anchor: anchor,
                                      toggle: toggle, range: range)
        if !range { anchor = i }
        editor.select(s)
        onSelectionChange?()
    }

    fileprivate func listMouseDragged(_ event: NSEvent) {
        guard let i = pressRow, let start = pressPoint, let d = editor.document else { return }
        let p = doc.convert(event.locationInWindow, from: nil)
        if drag == nil {
            guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
            if let g = rows[i].groupID, !LayerListLogic.isSelected(rows[i], document: d, selection: editor.selectedLayers)
                || editor.selectedLayers == editor.members(of: g) {
                drag = .group(g)
            } else {
                drag = .layers(Array(editor.selectedLayers))
            }
        }
        lastDragEvent = event
        isCopying = event.modifierFlags.contains(.option)
        (isCopying ? NSCursor.dragCopy : NSCursor.arrow).set()
        if dragTimer == nil {
            dragTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscrollTick() }
            }
        }
        autoscrollTick()
    }

    /// Scrolls the list while the pointer is at or past an edge and moves the drop target to what is now under the pointer
    /// (the timer calls this, so a held pointer keeps scrolling; the drop point is read after the scroll).
    func autoscrollTick() {
        guard drag != nil, let event = lastDragEvent else { return }
        doc.autoscroll(with: event)
        updateDropTarget(at: doc.convert(event.locationInWindow, from: nil))
    }

    fileprivate func listMouseUp(_ event: NSEvent) {
        defer {
            pressRow = nil; pressPoint = nil; drag = nil; clearDropTarget()
            dragTimer?.invalidate(); dragTimer = nil; lastDragEvent = nil
            if isCopying { NSCursor.arrow.set() }
            isCopying = false
        }
        if let drag, let d = editor.document {
            let copy = event.modifierFlags.contains(.option)
            if let drop = LayerListLogic.drop(drag, rows: rows, document: d, gap: dropGap ?? rows.count, onto: dropOnto,
                                              forCopy: copy) {
                if copy { editor.applyCopy(drop) } else { editor.apply(drop) }
                onSelectionChange?()
            }
            return
        }
        // Plain click on an already selected row: now it becomes the only selection.
        if let i = pressRow, pressWasSelected, !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.command) {
            applyClick(i, flags: [])
        }
    }

    private func updateDropTarget(at p: NSPoint) {
        let h = Theme.Row.list
        let y = min(max(p.y, 0), CGFloat(rows.count) * h)
        var gap = Int((y / h).rounded())
        var onto: Int?
        if let i = rowIndex(at: p), rows[i].groupID != nil {
            let f = (p.y - CGFloat(i) * h) / h
            if f > 0.25 && f < 0.75 { onto = i } else { gap = f <= 0.25 ? i : i + 1 }
        }
        dropGap = gap
        dropOnto = onto
        for (k, v) in rowViews.enumerated() { v.isDropTarget = k == onto }
        insertion.isHidden = onto != nil
        let lineY = CGFloat(gap) * h
        insertion.frame = NSRect(x: Theme.Spacing.sm, y: max(lineY - 1, 0), width: max(doc.bounds.width - Theme.Spacing.sm * 2, 0), height: 2)
    }

    // MARK: Effects dropped from the Effects panel

    fileprivate func effectDragUpdated(at p: NSPoint) -> NSDragOperation {
        let target = rowIndex(at: p).flatMap { rows[$0].layerID != nil ? $0 : nil }
        for (k, v) in rowViews.enumerated() { v.isDropTarget = k == target }
        return target != nil ? .copy : []
    }

    fileprivate func effectDrop(_ kinds: [String], at p: NSPoint) -> Bool {
        defer { clearDropTarget() }
        guard let i = rowIndex(at: p), let id = rows[i].layerID else { return false }
        if !editor.selectedLayers.contains(id) { editor.select([id]); onSelectionChange?() }
        onEffectDrop?(editor.addEffects(kinds, to: id))
        return true
    }

    private func clearDropTarget() {
        dropGap = nil; dropOnto = nil
        insertion.isHidden = true
        rowViews.forEach { $0.isDropTarget = false }
    }

    fileprivate func listRightMouseDown(_ event: NSEvent) {
        onFocus?()
        let p = doc.convert(event.locationInWindow, from: nil)
        if let i = rowIndex(at: p), let d = editor.document,
           !LayerListLogic.isSelected(rows[i], document: d, selection: editor.selectedLayers) {
            applyClick(i, flags: [])
        }
        let screen = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        SQMenuController.shared.present(items: contextItems(row: rowIndex(at: p)), at: screen)
    }

    /// Rename, Duplicate, Group, Ungroup | Bring to Front, Bring Forward, Send Backward, Send to Back | Delete.
    func contextItems(row: Int?) -> [SQMenuItem] {
        let e = editor
        let sel = !e.selectedLayers.isEmpty
        let grouped = e.selectedLayers.contains { e.document?.layer($0)?.group != nil }
        return [
            SQMenuItem(title: "Rename", isEnabled: row != nil) { [weak self] in if let row { self?.beginRename(row) } },
            SQMenuItem(title: "Duplicate", isEnabled: sel) { [weak e] in e?.duplicateSelected() },
            SQMenuItem(title: "Group", isEnabled: e.selectedLayers.count >= 2) { [weak e] in e?.groupSelected() },
            SQMenuItem(title: "Ungroup", isEnabled: grouped) { [weak e] in e?.ungroupSelected() },
            .separator,
            SQMenuItem(title: "Bring to Front", isEnabled: sel) { [weak e] in e?.reorder(.front) },
            SQMenuItem(title: "Bring Forward", isEnabled: sel) { [weak e] in e?.reorder(.forward) },
            SQMenuItem(title: "Send Backward", isEnabled: sel) { [weak e] in e?.reorder(.backward) },
            SQMenuItem(title: "Send to Back", isEnabled: sel) { [weak e] in e?.reorder(.back) },
            .separator,
            SQMenuItem(title: "Hide Others", isEnabled: sel) { [weak e] in e?.isolateSelection(lock: false) },
            SQMenuItem(title: "Lock Others", isEnabled: sel) { [weak e] in e?.isolateSelection(lock: true) },
            SQMenuItem(title: "Show All Layers") { [weak e] in e?.showAllLayers() },
            .separator,
            SQMenuItem(title: "Label", isEnabled: sel, submenu: labelItems()),
            .separator,
            SQMenuItem(title: "Delete", isEnabled: sel) { [weak e] in e?.deleteSelected() },
        ]
    }

    /// "No Label" and the 16 colors; the check marks the label every selected layer shares.
    private func labelItems() -> [SQMenuItem] {
        let e = editor
        let shared = Set(e.selectedLayers.map { e.document?.layer($0)?.label })
        var items = [SQMenuItem(title: "No Label", isChecked: shared == [nil]) { [weak e] in e?.setLabel(e?.selectedLayers ?? [], nil) }, .separator]
        for l in LabelColor.allCases {
            items.append(SQMenuItem(title: l.displayName, icon: .swatch(l.rgb), isChecked: shared == [l]) { [weak e] in
                e?.setLabel(e?.selectedLayers ?? [], l)
            })
        }
        return items
    }

    // MARK: Rename (SQTextField over the name)

    /// Starts the rename of the single selected layer's row; false when it has no row (inside a collapsed group).
    @discardableResult
    func beginRenameSelected() -> Bool {
        guard editor.selectedLayers.count == 1, let id = editor.selectedLayers.first,
              let i = rows.firstIndex(where: { $0.layerID == id }) else { return false }
        beginRename(i)
        return renameField != nil
    }

    private func beginRename(_ i: Int) {
        guard rows.indices.contains(i), renameField == nil else { return }
        let r = rows[i], v = rowViews[i]
        let f = SQTextField(string: r.name)
        f.delegate = self
        f.font = Theme.Typography.body
        let x = LayerListRowView.nameX(for: r)
        f.frame = NSRect(x: x - SQTextFieldCell.inset, y: (v.bounds.height - Theme.Metrics.capsule) / 2,
                         width: max(v.bounds.width - x - LayerListRowView.trailingWidth, 60), height: Theme.Metrics.capsule)
        v.addSubview(f)
        renameField = f
        renaming = r.kind
        renameCancelled = false
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { renameCancelled = true; window?.makeFirstResponder(nil); return true }
        return false
    }

    /// Return / click away commits, Esc cancels. Applied on the next turn so the field is not torn down mid-notification.
    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = renameField, let kind = renaming else { return }
        let name = f.stringValue, cancelled = renameCancelled
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            renameField = nil
            renaming = nil
            let refocus = window?.firstResponder === f || window?.firstResponder === window || window?.firstResponder == nil
            f.removeFromSuperview()
            if !cancelled {
                switch kind {
                case .layer(let id): editor.rename(id, name)
                case .group(let g): editor.renameGroup(g, name)
                }
            }
            reload()
            if refocus { onFocus?() }
        }
    }
}

/// Document of the list's scroll view: takes every click the row buttons do not.
@MainActor
final class LayerListDocument: NSView {
    weak var list: LayerListView?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { list?.listMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { list?.listMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { list?.listMouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { list?.listRightMouseDown(event) }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.sequenceEffectID]) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !GraphicsPanelView.effectKinds(from: sender.draggingPasteboard).isEmpty else { return [] }
        return list?.effectDragUpdated(at: convert(sender.draggingLocation, from: nil)) ?? []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { _ = list?.effectDragUpdated(at: NSPoint(x: -1, y: -1)) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        list?.effectDrop(GraphicsPanelView.effectKinds(from: sender.draggingPasteboard), at: convert(sender.draggingLocation, from: nil)) ?? false
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One 24 pt row: [chevron | indent] kind icon, name, eye, lock. Board `.li` (12 pt left, 34 for a grouped layer).
@MainActor
final class LayerListRowView: NSView {
    var onVisible: (() -> Void)?
    var onLocked: (() -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
    var focused = false { didSet { if oldValue != focused { needsDisplay = true } } }
    var isDropTarget = false { didSet { if oldValue != isDropTarget { needsDisplay = true } } }
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var hover: HoverTracker?
    private let row: LayerListRow
    /// Key ticks under the name (layer rows with keys).
    let strip = KeyTickStrip()
    var showsStrip = false { didSet { strip.isHidden = !showsStrip } }
    /// The item has a range and the playhead is outside it: name and kind icon take the disabled state.
    var isOutsideRange = false { didSet { if oldValue != isOutsideRange { applyRangeState() } } }
    private let nameLabel: NSTextField
    private var kindIcon: NSImageView?
    private var eyeButton: IconButton?
    private var lockButton: IconButton?
    private var nameHeight: CGFloat = 0

    private func applyRangeState() {
        nameLabel.textColor = isOutsideRange || !row.isVisible ? Theme.State.disabledText : Theme.Colors.label
        kindIcon?.alphaValue = isOutsideRange ? Theme.State.disabledAlpha : 1
    }

    static let iconWidth: CGFloat = 22
    static let trailingWidth: CGFloat = Theme.Inspector.iconSlot * 2 + Theme.Spacing.sm + Theme.Spacing.md
    /// Left edge of the name (group rows: after the chevron; grouped layers: indented).
    static func nameX(for r: LayerListRow) -> CGFloat {
        let base = Theme.Spacing.md
        if r.groupID != nil { return base + iconWidth }
        return (r.isIndented ? base + iconWidth : base) + iconWidth
    }

    override var isFlipped: Bool { true }

    init(row: LayerListRow) {
        self.row = row
        nameLabel = NSTextField(labelWithString: row.name)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: Theme.Row.list))
        let x0 = Self.nameX(for: row)
        if row.groupID != nil {
            let chevron = DisclosureGlyph(isOpen: row.isOpen)
            chevron.frame = NSRect(x: Theme.Spacing.md + (Self.iconWidth - 12) / 2 - 4, y: (Theme.Row.list - 12) / 2, width: 12, height: 12)
            addSubview(chevron)
        } else if let s = row.symbol, let img = Theme.symbol(s, size: 12) {
            let kind = NSImageView(image: img)
            kind.contentTintColor = Theme.Colors.label2
            kind.frame = NSRect(x: x0 - Self.iconWidth, y: (Theme.Row.list - 16) / 2, width: Self.iconWidth - Theme.Spacing.xs, height: 16)
            addSubview(kind)
            kindIcon = kind
        }
        strip.isHidden = true
        if row.layerID != nil { addSubview(strip) }
        let name = nameLabel
        name.font = row.groupID != nil ? Theme.Typography.bodyStrong : Theme.Typography.body
        name.textColor = row.isVisible ? Theme.Colors.label : Theme.Colors.label3
        name.lineBreakMode = .byTruncatingTail
        nameHeight = ceil(name.intrinsicContentSize.height)
        addSubview(name)
        let lock = IconButton(symbol: row.isLocked ? .trackLock : .trackUnlock,
                              label: row.isLocked ? "Unlock" : "Lock", size: 11) { [weak self] in self?.onLocked?() }
        lock.contentTintColor = row.isLocked ? Theme.Colors.label : Theme.Colors.label3
        let eye = IconButton(symbol: row.isVisible ? .eye : .eyeOff,
                             label: row.isVisible ? "Hide" : "Show", size: 11) { [weak self] in self?.onVisible?() }
        eye.contentTintColor = row.isVisible ? Theme.Colors.label2 : Theme.Colors.label3
        for b in [eye, lock] { addSubview(b) }
        eyeButton = eye
        lockButton = lock
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(row.groupID != nil ? "Group \(row.name)" : row.name)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Plain frames, no Auto Layout: a panel resize sets every row's frame, and solving three constraints per row for
    /// 40 rows was the biggest part of the list's resize cost (see GraphicsPanelResizePerfTests).
    override func layout() {
        super.layout()
        let h = bounds.height, slot = Theme.Inspector.iconSlot
        let lockX = bounds.width - Theme.Spacing.md - slot
        let eyeX = lockX - Theme.Spacing.sm - slot
        eyeButton?.frame = NSRect(x: eyeX, y: 0, width: slot, height: h)
        lockButton?.frame = NSRect(x: lockX, y: 0, width: slot, height: h)
        let nx = Self.nameX(for: row)
        nameLabel.frame = NSRect(x: nx, y: (h - nameHeight) / 2, width: max(eyeX - Theme.Spacing.xs - nx, 0), height: nameHeight)
        let x = Self.nameX(for: row)
        strip.frame = NSRect(x: x, y: bounds.height - KeyTickStrip.height - 1,
                             width: max(bounds.width - x - Self.trailingWidth, 0), height: KeyTickStrip.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if hover == nil { hover = HoverTracker(view: self) { [weak self] on in self?.hovering = on } }
    }

    /// Only the lock and eye buttons take clicks; everything else goes to the list (select, drag, rename).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v is IconButton || v is NSTextField && (v as? NSTextField)?.isEditable == true || v is NSTextView ? v : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if isDropTarget {
            Theme.Colors.accentTint.setFill(); bounds.fill()
        } else if isSelected {
            (focused ? Theme.Selection.fillFocused : Theme.Selection.fill).setFill(); bounds.fill()
        } else if hovering {
            Theme.Selection.hover.setFill(); bounds.fill()
        }
        if let label = row.label {
            label.fill.setFill()
            NSRect(x: 0, y: 0, width: Theme.Spacing.xs, height: bounds.height).fill()
        }
    }
}
