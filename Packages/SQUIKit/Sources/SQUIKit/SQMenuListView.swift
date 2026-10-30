import AppKit

/// Borderless panel that never takes key or main status, so the window under the menu keeps focus.
final class SQMenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    /// Modal dialogs run their own event loop that drops events for other windows; the menu must still get its clicks.
    override var worksWhenModal: Bool { get { true } set {} }
    override var canBecomeMain: Bool { false }
}

/// Accessibility row: a menu item that can be pressed and reports its selection.
final class SQMenuAXItem: NSAccessibilityElement {
    var onPress: (() -> Void)?
    var selected = false
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
    override func isAccessibilitySelected() -> Bool { selected }
}

/// One level of the menu: draws rows, icons, shortcut column, checkmarks, submenu chevrons. Dumb: the controller owns state.
@MainActor
final class SQMenuListView: NSView {
    var items: [SQMenuItem] { didSet { relayout() } }
    /// Type-to-filter text; the filter row exists only while this is non-empty.
    var filter: String = "" { didSet { if oldValue != filter { relayout() } } }
    private(set) var filterFrame: CGRect?
    var highlighted: Int? { didSet { if oldValue != highlighted { needsDisplay = true; updateAX() } } }
    /// Row index chosen by accessibility "press".
    var onPress: ((Int) -> Void)?

    private(set) var rowFrames: [CGRect] = []
    private(set) var width: CGFloat = SQMenuLayout.minWidth
    private(set) var symbolWidth: CGFloat = 0
    private(set) var iconWidth: CGFloat = SQMenuLayout.iconColumn
    private var axElements: [SQMenuAXItem] = []

    private static let font = Theme.Menu.font
    private static let headerFont = Theme.Menu.captionFont
    private static let helpFont = Theme.Typography.caption
    private static let shortcutFont = Theme.Menu.shortcutFont

    init(items: [SQMenuItem]) {
        self.items = items
        super.init(frame: .zero)
        setAccessibilityRole(.menu)
        relayout()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// Full size of the rows.
    var contentSize: CGSize { CGSize(width: width, height: (rowFrames.last?.maxY ?? SQMenuLayout.inset) + SQMenuLayout.inset) }
    /// Tallest the view may be (the screen's room); taller content scrolls.
    var maxHeight: CGFloat? { didSet { if oldValue != maxHeight { relayout() } } }
    /// What the view (and its panel) shows: the content, clamped to `maxHeight`.
    var visibleSize: CGSize { CGSize(width: width, height: min(contentSize.height, maxHeight ?? .greatestFiniteMagnitude)) }
    private(set) var scrollOffset: CGFloat = 0
    var maxScroll: CGFloat { max(contentSize.height - visibleSize.height, 0) }

    func scroll(by delta: CGFloat) { setScroll(scrollOffset + delta) }
    private func setScroll(_ y: CGFloat) {
        let c = max(0, min(y, maxScroll))
        if c != scrollOffset { scrollOffset = c; needsDisplay = true }
    }
    /// Scrolls the least that shows row `i` completely.
    func reveal(row i: Int) {
        guard rowFrames.indices.contains(i) else { return }
        let r = rowFrames[i]
        if r.minY - SQMenuLayout.inset < scrollOffset { setScroll(r.minY - SQMenuLayout.inset) }
        else if r.maxY + SQMenuLayout.inset > scrollOffset + visibleSize.height { setScroll(r.maxY + SQMenuLayout.inset - visibleSize.height) }
    }

    private func relayout() {
        // Board: [check 14][gap 8][color dot 8 + gap 8, only when a row carries one][title]; no other icons.
        let dots = items.contains { if case .swatch = $0.icon { true } else { false } }
        iconWidth = SQMenuLayout.checkColumn + (dots ? SQMenuLayout.dotColumn : 0)
        var maxText: CGFloat = 0, maxShort: CGFloat = 0
        var hasSub = false
        let symbols = items.contains { $0.leadingSymbol != nil }
        symbolWidth = symbols ? SQMenuLayout.symbolColumn : 0
        for i in items where i.kind == .action {
            maxText = max(maxText, (i.title as NSString).size(withAttributes: [.font: Self.font]).width)
            if let h = i.help, !h.isEmpty { maxText = max(maxText, min(SQMenuLayout.helpWidth, ceil((h as NSString).size(withAttributes: [.font: Self.helpFont]).width))) }
            maxShort = max(maxShort, Self.shortcutWidth(i.shortcut))
            hasSub = hasSub || i.submenu != nil
        }
        // Header rows start over the title column (`.mcap`), so their text counts like a title there.
        let headerIndent = SQMenuLayout.checkColumn + SQMenuLayout.gap - (iconWidth + symbolWidth + SQMenuLayout.gap)
        for i in items where i.kind == .header {
            maxText = max(maxText, (i.title as NSString).size(withAttributes: [.font: Self.headerFont]).width + headerIndent)
        }
        let trailing: CGFloat = max(maxShort, hasSub ? 10 : 0)
        width = max(SQMenuLayout.minWidth, ceil(SQMenuLayout.inset * 2 + SQMenuLayout.rowPad + iconWidth + symbolWidth + SQMenuLayout.gap + maxText + (trailing > 0 ? 2 * SQMenuLayout.gap + trailing : 0) + SQMenuLayout.trailPad))
        if items.contains(where: { $0.kind == .caption }) {
            width = max(width, ceil(SQMenuLayout.inset * 2 + SQMenuLayout.rowPad * 2 + SQMenuLayout.captionWidth))
        }
        var y = SQMenuLayout.inset
        if filter.isEmpty {
            filterFrame = nil
        } else {
            filterFrame = CGRect(x: SQMenuLayout.inset, y: y, width: width - 2 * SQMenuLayout.inset, height: SQMenuLayout.rowHeight)
            y += SQMenuLayout.rowHeight + SQMenuLayout.separatorHeight
            width = max(width, ceil((filter as NSString).size(withAttributes: [.font: Self.font]).width + 40))
            filterFrame?.size.width = width - 2 * SQMenuLayout.inset
        }
        rowFrames = []
        for h in SQMenuLayout.heights(items) {
            rowFrames.append(CGRect(x: SQMenuLayout.inset, y: y, width: width - 2 * SQMenuLayout.inset, height: h))
            y += h
        }
        setFrameSize(visibleSize)
        setScroll(scrollOffset)
        needsDisplay = true
        rebuildAX()
    }

    func index(at p: CGPoint) -> Int? {
        let q = CGPoint(x: p.x, y: p.y + scrollOffset)
        return rowFrames.firstIndex { $0.contains(q) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: SQMenuLayout.cornerRadius, yRadius: SQMenuLayout.cornerRadius)
        Theme.Colors.overlay.setFill(); bg.fill()
        Theme.Colors.overlayEdge.setStroke(); bg.lineWidth = Theme.Overlay.edgeWidth; bg.stroke()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: bounds, xRadius: SQMenuLayout.cornerRadius, yRadius: SQMenuLayout.cornerRadius).addClip()
        let shift = NSAffineTransform()
        shift.translateX(by: 0, yBy: -scrollOffset)
        shift.concat()

        if let f = filterFrame {
            let a: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Theme.Colors.label]
            let th = (filter as NSString).size(withAttributes: a).height
            (filter as NSString).draw(at: CGPoint(x: f.minX + 8, y: f.midY - th / 2), withAttributes: a)
            Theme.Colors.separator.setFill()
            NSRect(x: f.minX + SQMenuLayout.rowPad, y: f.maxY + SQMenuLayout.separatorHeight / 2 - 0.5, width: f.width - 2 * SQMenuLayout.rowPad, height: 1).fill()
        }

        for (i, item) in items.enumerated() {
            let r = rowFrames[i]
            switch item.kind {
            case .separator:
                Theme.Colors.separator.setFill()
                NSRect(x: r.minX + SQMenuLayout.rowPad, y: r.midY - 0.5, width: r.width - 2 * SQMenuLayout.rowPad, height: 1).fill()
            case .header:
                let a: [NSAttributedString.Key: Any] = [.font: Self.headerFont, .foregroundColor: Theme.Colors.label3]
                let hh = (item.title as NSString).size(withAttributes: a).height
                // `.mcap`: text starts over the title column (padding-left 30); the 6/2 padding sits it 2 pt below center.
                let hx = r.minX + SQMenuLayout.rowPad + SQMenuLayout.checkColumn + SQMenuLayout.gap
                (item.title as NSString).draw(at: CGPoint(x: hx, y: r.midY - hh / 2 + 2), withAttributes: a)
            case .caption:
                let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byWordWrapping
                let a: [NSAttributedString.Key: Any] = [.font: SQMenuLayout.captionFont, .foregroundColor: Theme.Colors.label2, .paragraphStyle: ps]
                (item.title as NSString).draw(with: CGRect(x: r.minX + SQMenuLayout.rowPad, y: r.minY + SQMenuLayout.captionPad,
                                                            width: r.width - 2 * SQMenuLayout.rowPad, height: r.height - 2 * SQMenuLayout.captionPad),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: a)
            case .action:
                drawRow(item, in: r, active: highlighted == i)
            }
        }
    }

    private func drawRow(_ item: SQMenuItem, in r: CGRect, active: Bool) {
        if active {
            Theme.Colors.accentFill.setFill()
            NSBezierPath(roundedRect: r, xRadius: SQMenuLayout.rowRadius, yRadius: SQMenuLayout.rowRadius).fill()
        }
        let text: NSColor = !item.isEnabled ? Theme.Colors.label3 : (active ? .white : Theme.Colors.label)
        let sub: NSColor = !item.isEnabled ? Theme.Colors.label3 : (active ? Theme.white(0.8) : Theme.Colors.label3)

        let checkBox = CGRect(x: r.minX + SQMenuLayout.rowPad, y: r.minY, width: SQMenuLayout.checkColumn, height: r.height)
        if item.isChecked { Self.drawCheck(color: text, in: checkBox) }
        var tx = checkBox.maxX + SQMenuLayout.gap
        let dot = CGRect(x: tx, y: r.midY - 4, width: 8, height: 8)
        switch item.icon {
        case .swatch(let rgb):
            Theme.hex(rgb, alpha: item.isEnabled ? 1 : Theme.State.disabledAlpha).setFill(); NSBezierPath(ovalIn: dot).fill()
        default: break
        }
        if iconWidth > SQMenuLayout.checkColumn { tx += SQMenuLayout.dotColumn }
        if let sym = item.leadingSymbol {
            let c = item.leadingTint.map { item.isEnabled ? $0 : Theme.Colors.label3 } ?? text
            Self.drawSymbol(sym, color: c, in: CGRect(x: tx, y: r.minY, width: SQMenuLayout.symbolColumn - 4, height: r.height))
            tx += symbolWidth
        }
        let ta: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: text]
        let th = (item.title as NSString).size(withAttributes: ta).height
        let hasHelp = item.help?.isEmpty == false
        let titleMid = hasHelp ? r.minY + SQMenuLayout.rowHeight / 2 - 1 : r.midY
        (item.title as NSString).draw(at: CGPoint(x: tx, y: titleMid - th / 2), withAttributes: ta)
        if let help = item.help, hasHelp {
            let ha: [NSAttributedString.Key: Any] = [.font: Self.helpFont, .foregroundColor: sub]
            let lines = CGFloat(SQMenuLayout.helpLines(item))
            let box = CGRect(x: tx, y: r.minY + SQMenuLayout.rowHeight - 2, width: SQMenuLayout.helpWidth + 2, height: lines * SQMenuLayout.helpHeight)
            (help as NSString).draw(with: box, options: [.usesLineFragmentOrigin], attributes: ha)
        }

        if item.submenu != nil {
            Self.drawSymbol(.chevronRight, color: sub, in: CGRect(x: r.maxX - SQMenuLayout.trailPad - 10, y: r.minY, width: 12, height: r.height), size: Theme.Typography.symbolSmall)
        } else if !item.shortcut.isEmpty {
            Self.drawShortcut(item.shortcut, color: sub, rightEdge: r.maxX - SQMenuLayout.trailPad, midY: r.midY)
        }
    }

    // One shortcut style: every key, punctuation included, is a plain glyph (no key cap) in the right column.
    static func shortcutWidth(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: shortcutFont]).width
    }
    private static func drawShortcut(_ s: String, color: NSColor, rightEdge: CGFloat, midY: CGFloat) {
        let sa: [NSAttributedString.Key: Any] = [.font: shortcutFont, .foregroundColor: color]
        let sz = (s as NSString).size(withAttributes: sa)
        (s as NSString).draw(at: CGPoint(x: rightEdge - sz.width, y: midY - sz.height / 2), withAttributes: sa)
    }

    /// The board's check: a 1.5 pt stroke through (3, 7.5) (5.5, 10) (11, 4) in a 14 pt box.
    private static func drawCheck(color: NSColor, in box: CGRect) {
        let p = NSBezierPath()
        p.move(to: CGPoint(x: box.minX + 3, y: box.midY + 0.5))
        p.line(to: CGPoint(x: box.minX + 5.5, y: box.midY + 3))
        p.line(to: CGPoint(x: box.minX + 11, y: box.midY - 3))
        p.lineWidth = 1.5; p.lineCapStyle = .round; p.lineJoinStyle = .round
        color.setStroke(); p.stroke()
    }

    static func tinted(_ img: NSImage, color: NSColor) -> NSImage {
        let out = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            color.set(); r.fill(using: .sourceAtop)
            return true
        }
        return out
    }

    private static func drawSymbol(_ name: SQIcon, color: NSColor, in box: CGRect, size: CGFloat = 12.5) {
        let tinted = name.image(size: size, color: color)
        let s = tinted.size
        tinted.draw(in: CGRect(x: box.minX + 1, y: box.midY - s.height / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Accessibility

    private func rebuildAX() {
        axElements = items.enumerated().compactMap { i, item in
            guard item.kind == .action else { return nil }
            let el = SQMenuAXItem()
            el.setAccessibilityRole(.menuItem)
            el.setAccessibilityLabel(item.title)
            el.setAccessibilityEnabled(item.isEnabled)
            if !item.shortcut.isEmpty { el.setAccessibilityHelp(item.shortcut) }
            el.setAccessibilityParent(self)
            el.setAccessibilityFrameInParentSpace(rowFrames[i])
            el.onPress = { [weak self] in self?.onPress?(i) }
            el.selected = highlighted == i
            return el
        }
        setAccessibilityChildren(axElements)
    }

    private func updateAX() {
        let rows = items.indices.filter { items[$0].kind == .action }
        for (n, i) in rows.enumerated() where axElements.indices.contains(n) { axElements[n].selected = highlighted == i }
    }
}
