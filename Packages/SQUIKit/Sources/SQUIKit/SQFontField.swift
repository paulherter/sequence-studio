import AppKit
import SQText

/// Rows of the list under the font field, drawn like menu rows (24 high, 5 inset, radius 5, 13 pt) with every font in its own face.
private final class SQFontListView: NSView {
    static let inset: CGFloat = 5
    static let itemHeight: CGFloat = Theme.Row.menu
    static let headerHeight: CGFloat = Theme.Row.columnHeader
    static let separatorHeight: CGFloat = 9

    var rows: [SQFontFieldModel.Row] = [] { didSet { recompute(); needsDisplay = true } }
    var highlight: Int? { didSet { if oldValue != highlight { needsDisplay = true } } }
    /// Name (family or PostScript) that is applied now: gets the check mark.
    var current: String = "" { didSet { needsDisplay = true } }
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    private var frames: [CGRect] = []
    private var fontCache: [String: NSFont] = [:]
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func contentHeight(of rows: [SQFontFieldModel.Row]) -> CGFloat {
        inset * 2 + rows.reduce(0) { $0 + height(of: $1) }
    }
    static func height(of r: SQFontFieldModel.Row) -> CGFloat {
        switch r { case .header: headerHeight; case .separator: separatorHeight; case .font, .showAll: itemHeight }
    }

    private func recompute() {
        var y = Self.inset
        frames = rows.map { r in
            defer { y += Self.height(of: r) }
            return CGRect(x: Self.inset, y: y, width: max(bounds.width - 2 * Self.inset, 0), height: Self.height(of: r))
        }
    }
    override func layout() { super.layout(); recompute() }

    func frame(ofRow i: Int) -> CGRect? { frames.indices.contains(i) ? frames[i] : nil }

    private func face(_ name: String) -> NSFont {
        if let f = fontCache[name] { return f }
        let f = NSFont(name: name, size: Theme.Typography.titleSize)
            ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: Theme.Typography.titleSize)
            ?? Theme.Typography.title
        fontCache[name] = f
        return f
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return frames.indices.first { frames[$0].contains(p) && rows[$0].isSelectable }
    }
    override func mouseMoved(with event: NSEvent) { if let i = index(at: event) { onHover?(i) } }
    override func mouseDown(with event: NSEvent) { if let i = index(at: event) { onClick?(i) } }

    override func draw(_ dirtyRect: NSRect) {
        for (i, r) in rows.enumerated() where frames[i].intersects(dirtyRect) {
            let f = frames[i]
            switch r {
            case .header(let t):
                text(t, font: Theme.Typography.captionStrong, color: Theme.Colors.label3, in: f, x: f.minX + 8)
            case .separator:
                Theme.Separator.hairline.setFill()
                CGRect(x: f.minX + 8, y: f.midY - 0.5, width: f.width - 16, height: 1).fill()
            case .font(let name, let title, let indented):
                let on = highlight == i
                if on { rowBackground(f) }
                if name == current { drawCheck(in: f, on: on) }
                let x = f.minX + 8 + 14 + 8 + (indented ? 14 : 0)
                text(title, font: face(name), color: on ? Theme.OnPicture.stroke : (indented ? Theme.Colors.label2 : Theme.Colors.label),
                     in: f, x: x, trailing: on ? 24 : 8)
                if on { text("\u{21A9}", font: Theme.Typography.title, color: Theme.OnPicture.stroke.withAlphaComponent(0.8), in: f, x: f.maxX - 8 - 12) }
            case .showAll:
                let on = highlight == i
                if on { rowBackground(f) }
                text("Show All Fonts\u{2026}", font: Theme.Typography.title, color: on ? Theme.OnPicture.stroke : Theme.Colors.label,
                     in: f, x: f.minX + 8 + 14 + 8)
            }
        }
    }

    private func rowBackground(_ f: CGRect) {
        Theme.Selection.fillFocused.setFill()
        NSBezierPath(roundedRect: f, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
    }

    private func drawCheck(in f: CGRect, on: Bool) {
        let x = f.minX + 8, y = f.midY
        let p = NSBezierPath()
        p.move(to: CGPoint(x: x + 3, y: y + 0.5)); p.line(to: CGPoint(x: x + 5.5, y: y + 3)); p.line(to: CGPoint(x: x + 11, y: y - 3.5))
        p.lineWidth = 1.2; p.lineCapStyle = .round; p.lineJoinStyle = .round
        (on ? Theme.OnPicture.stroke : Theme.Colors.label).setStroke()
        p.stroke()
    }

    private func text(_ s: String, font: NSFont, color: NSColor, in f: CGRect, x: CGFloat, trailing: CGFloat = 8) {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let h = a.size().height
        a.draw(in: CGRect(x: x, y: f.midY - h / 2, width: max(f.maxX - trailing - x, 0), height: h))
    }
}

private final class SQFontListPanel: NSPanel {
    override var worksWhenModal: Bool { get { true } set {} }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SQFontTextField: NSTextField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    /// The first press focuses and selects the whole name, so typing replaces it. The default press would also place the
    /// caret at the click, which turns the next letters into an append to the old name.
    override func mouseDown(with event: NSEvent) {
        if currentEditor() == nil {
            guard window?.makeFirstResponder(self) == true else { return }
            currentEditor()?.selectAll(nil)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// Font field: a capsule you can type in. While it has focus a list under it shows the matching families (each in its own face),
/// then Recent, then "Show All Fonts…" (the full list, every family with its faces). Up/Down preview through `onPreview`,
/// Return (or a click) applies through `onCommit`, Esc restores the font the field had and sends it through `onPreview`.
@MainActor
public final class SQFontField: NSView, NSTextFieldDelegate {
    public static let height: CGFloat = Theme.Metrics.pushButton
    private static let listGap: CGFloat = 4
    private static let maxListHeight: CGFloat = 340
    private static let minListWidth: CGFloat = 250

    /// Live preview: arrows over a font, and the restore on Esc. Not an edit: do not push undo here.
    public var onPreview: ((String) -> Void)?
    /// A font was chosen (Return or click).
    public var onCommit: ((String) -> Void)?
    /// The editing session ended (after a commit, on Esc, or when focus left): the host closes whatever it opened for the preview.
    public var onEnd: (() -> Void)?
    /// Installed families; replaceable for tests and render harnesses.
    public var familiesProvider: @MainActor () -> [String] = {
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    }
    /// Fonts shown under "Included" while the field is empty (the bundled families); empty hides the section.
    public var bundledProvider: @MainActor () -> [String] = { BundledFonts.pickerNames }
    /// The font the field shows (family or PostScript name).
    public var fontName: String { didSet { if !isEditing { updateText() }; needsDisplay = true } }
    public var isEnabled: Bool = true { didSet { text.isEditable = isEnabled; alphaValue = isEnabled ? 1 : Theme.State.disabledAlpha } }

    public private(set) var isEditing = false
    private let defaults: UserDefaults
    private let text = SQFontTextField()
    /// The text field of the capsule (tests focus and click it).
    var textFieldForTesting: NSTextField { text }
    private var model = SQFontFieldModel(families: [])
    private var panel: SQFontListPanel?
    private var listView: SQFontListView?
    private var scroll: NSScrollView?
    private var original = ""
    private var searchGuard = SQSearchGuard()
    private var typed = false
    /// Owns the outside-click monitor; its deinit removes it, so a field released while open leaves none behind.
    private final class MonitorToken: @unchecked Sendable {
        let token: Any
        init(_ token: Any) { self.token = token }
        deinit { NSEvent.removeMonitor(token) }
    }
    private var outsideMonitor: MonitorToken?
    private var previewed = false
    private var committed = false
    public override var isFlipped: Bool { true }

    public init(fontName: String, defaults: UserDefaults = .standard) {
        self.fontName = fontName
        self.defaults = defaults
        super.init(frame: CGRect(x: 0, y: 0, width: Self.minListWidth, height: Self.height))
        text.isBordered = false; text.isBezeled = false; text.drawsBackground = false; text.focusRingType = .none
        text.font = Theme.Typography.body; text.textColor = Theme.Colors.label
        text.lineBreakMode = .byTruncatingTail
        text.cell?.usesSingleLineMode = true
        text.delegate = self
        text.setAccessibilityLabel("Font")
        text.onFocus = { [weak self] in self?.focusGained() }
        addSubview(text)
        updateText()
    }
    required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func layout() {
        super.layout()
        let th = text.fittingSize.height
        text.frame = CGRect(x: 8, y: ((bounds.height - th) / 2).rounded(), width: max(bounds.width - 8 - 20, 0), height: th)
    }

    /// A press on the field (its arrow) opens the list, and closes it again while it is open.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, isEditing { cancel() } else if newWindow == nil { closeList() }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if isEditing { cancel() } else { window?.makeFirstResponder(text) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let r = bounds, rad = r.height / 2
        Theme.Colors.field.setFill()
        NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
        (isEditing ? Theme.State.focusRing : Theme.Colors.fieldEdge).setStroke()
        let e = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: rad, yRadius: rad)
        e.lineWidth = isEditing ? 1 : 0.5; e.stroke()
        // Chevron (5 pt, 1.2 pt stroke) at the right.
        let cx = r.maxX - 9.5, cy = r.midY - 0.5
        let c = NSBezierPath()
        c.move(to: CGPoint(x: cx - 3, y: cy - 1.5)); c.line(to: CGPoint(x: cx, y: cy + 1.5)); c.line(to: CGPoint(x: cx + 3, y: cy - 1.5))
        c.lineWidth = 1.2; c.lineCapStyle = .round; c.lineJoinStyle = .round
        Theme.Colors.label2.setStroke(); c.stroke()
    }

    // MARK: Text

    /// "Helvetica Bold" for a PostScript name that resolves, else the name as given.
    private func updateText() {
        text.stringValue = NSFont(name: fontName, size: 11)?.displayName ?? fontName
    }

    private func focusGained() {
        guard !isEditing else { return }
        isEditing = true
        committed = false; previewed = false; typed = false
        original = fontName
        needsDisplay = true
        model = SQFontFieldModel(families: familiesProvider(), recents: SQFontFieldModel.loadRecents(defaults),
                                   bundled: bundledProvider())
        // Select the old name so typing replaces it, but only if nothing was typed before this runs (a late select-all would
        // swallow the first letters of a fast "Inter").
        let token = searchGuard.begin()
        DispatchQueue.main.async { [weak self] in
            guard let self, searchGuard.isCurrent(token), model.query.isEmpty else { return }
            text.currentEditor()?.selectAll(nil)
        }
        openList()
    }

    public func controlTextDidChange(_ obj: Notification) {
        _ = searchGuard.begin()
        typed = true
        syncQuery()
    }

    /// The list always shows the matches of the text in the field: Return and the arrows re-read it first.
    private func syncQuery() {
        guard isEditing, typed, model.query != text.stringValue else { return }
        model.setQuery(text.stringValue)
        reloadList()
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditing else { return }
        if !committed, previewed { onPreview?(original) }
        finishEditing()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): step(1); return true
        case #selector(NSResponder.moveUp(_:)): step(-1); return true
        case #selector(NSResponder.insertNewline(_:)): applyReturn(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        default: return false
        }
    }

    // MARK: Actions

    private func step(_ delta: Int) {
        syncQuery()
        model.moveHighlight(by: delta)
        syncList(reveal: true)
        switch model.highlightedRow {
        case .font(let name, _, _)?: previewed = true; onPreview?(name)
        case .showAll?: if previewed { previewed = false; onPreview?(original) }
        default: break
        }
    }

    private func applyReturn() {
        syncQuery()
        if case .showAll? = model.highlightedRow { showAllFonts(); return }
        guard let name = model.returnTarget else { cancel(); return }
        commit(name)
    }

    private func clicked(_ row: Int) {
        guard model.rows.indices.contains(row) else { return }
        switch model.rows[row] {
        case .font(let name, _, _): commit(name)
        case .showAll: showAllFonts()
        default: break
        }
    }

    private func commit(_ name: String) {
        committed = true
        SQFontFieldModel.remember(name, in: defaults)
        fontName = name
        onCommit?(name)
        window?.makeFirstResponder(nil)
        finishEditing()
    }

    private func cancel() {
        if previewed { onPreview?(original) }
        previewed = false
        committed = false
        window?.makeFirstResponder(nil)
        finishEditing()
    }

    private func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        closeList()
        updateText()
        needsDisplay = true
        onEnd?()
    }

    private func showAllFonts() {
        model.showAll(rows: Self.allFontRows(families: model.families), current: fontName)
        reloadList()
        if let h = model.highlight, let f = listView?.frame(ofRow: h) { listView?.scrollToVisible(f) }
    }

    /// Every family in its face, followed by its faces (PostScript names) when it has more than one.
    static func allFontRows(families: [String], manager: NSFontManager = .shared) -> [SQFontFieldModel.Row] {
        var out: [SQFontFieldModel.Row] = []
        for fam in families.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            out.append(.font(name: fam, title: fam, indented: false))
            guard let members = manager.availableMembers(ofFontFamily: fam), members.count > 1 else { continue }
            for m in members {
                guard let ps = m.first as? String, m.count > 1, let style = m[1] as? String else { continue }
                out.append(.font(name: ps, title: style, indented: true))
            }
        }
        return out
    }

    // MARK: List panel

    private func openList() {
        guard let parent = window, panel == nil else { return }
        let lv = SQFontListView(frame: .zero)
        lv.onHover = { [weak self] i in self?.model.setHighlight(i); self?.syncList(reveal: false) }
        lv.onClick = { [weak self] i in self?.clicked(i) }
        let sv = NSScrollView(frame: .zero)
        sv.documentView = lv
        SQScrollView.apply(to: sv)
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.autoresizingMask = [.width, .height]
        let frameView = NSView(frame: .zero)
        frameView.wantsLayer = true
        Theme.Overlay.style(frameView.layer)
        frameView.addSubview(sv)
        let p = SQFontListPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.level = parent.level
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.appearance = Theme.windowAppearance
        p.contentView = frameView
        parent.addChildWindow(p, ordered: .above)
        panel = p; listView = lv; scroll = sv
        reloadList()
        p.orderFront(nil)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            nonisolated(unsafe) let e = event
            MainActor.assumeIsolated { self?.pressed(e) }
            return e
        }
        outsideMonitor = monitor.map(MonitorToken.init)
    }

    private func reloadList() {
        guard let p = panel, let lv = listView, let sv = scroll, let w = window else { return }
        let rows = model.rows
        let width = max(bounds.width, Self.minListWidth)
        let content = SQFontListView.contentHeight(of: rows)
        let height = min(content, Self.maxListHeight)
        lv.frame = CGRect(x: 0, y: 0, width: width, height: content)
        lv.rows = rows
        lv.current = fontName
        lv.highlight = model.highlight
        sv.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let anchor = w.convertToScreen(convert(bounds, to: nil))
        let visible = (w.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 4000, height: 4000)
        let placed = SQPopoverLogic.frame(size: CGSize(width: width, height: height), anchor: anchor, side: .below, visible: visible, gap: Self.listGap)
        p.setFrame(placed.frame, display: true)
        sv.contentView.scroll(to: .zero)
    }

    /// Highlights the model's row. Only the keyboard scrolls it into view: a pointer hover must never move the list, or the
    /// row under the pointer fights the user's own scrolling.
    private func syncList(reveal: Bool) {
        listView?.highlight = model.highlight
        if reveal, let h = model.highlight, let f = listView?.frame(ofRow: h) { listView?.scrollToVisible(f) }
    }

    /// A press outside the field and its list closes the list (the press still reaches its target).
    private func pressed(_ event: NSEvent) {
        guard isEditing else { return }
        if event.window === panel { return }
        if event.window === window, hitTestsSelf(event) { return }
        cancel()
    }

    private func hitTestsSelf(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }

    private func closeList() {
        outsideMonitor = nil
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
            p.contentView = nil
        }
        panel = nil; listView = nil; scroll = nil
    }
}
