import AppKit

/// Flat, custom-drawn controls of the text block (Panels board `.tg` pills, `.pop` popup). Checkbox, color well and
/// section header are the shared SQCheckbox / SQColorWell / InspectorSection.
enum TextPanelMetrics {
    static let radius = Theme.Radius.control
    /// Pill of the Format row (board `.tg`: 24 x 22, capsule), and the gap between pills (the row's 8 pt).
    static let pill = NSSize(width: 24, height: Theme.Metrics.quietField)
    static let pillGap: CGFloat = Theme.Spacing.sm
}

// MARK: Icon buttons

/// A row of flat icon or text buttons. `.selectOne` keeps one selected (alignment), `.toggle` lets each be on or off
/// (bold, italic), `.momentary` just fires (align to frame). The selected fill is the only decoration.
@MainActor
final class TextPanelIconGroup: NSControl {
    enum Mode { case selectOne, toggle, momentary }
    struct Item {
        var symbol: SQIcon?; var title: String?; var tip: String
        /// Letter style of a title item (B bold, I italic).
        var traits: NSFontDescriptor.SymbolicTraits = []
        /// A line style pill: the title letter is drawn with a bar under, through or over it (0 under, 1 through, 2 over).
        var bar: Int?
    }

    let mode: Mode
    private(set) var items: [Item]
    var selected: Set<Int> = [] { didSet { needsDisplay = true } }
    /// Multi-select, the selected items differ here: drawn off with a short dash under the glyph (like a mixed
    /// checkbox); a click turns it on for all of them.
    var mixed: Set<Int> = [] { didSet { if oldValue != mixed { needsDisplay = true } } }
    var onPress: ((Int) -> Void)?
    private var hover: Int?
    private var tracking: NSTrackingArea?
    private static let cell = TextPanelMetrics.pill
    private static let gap = TextPanelMetrics.pillGap

    init(_ items: [Item], mode: Mode) {
        self.items = items; self.mode = mode
        super.init(frame: .zero)
        setAccessibilityRole(.group)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: (Self.cell.width + Self.gap) * CGFloat(items.count) - Self.gap, height: Self.cell.height) }
    override var acceptsFirstResponder: Bool { false }

    private func rect(_ i: Int) -> NSRect {
        NSRect(x: (Self.cell.width + Self.gap) * CGFloat(i), y: 0, width: Self.cell.width, height: Self.cell.height)
    }

    private func index(at p: NSPoint) -> Int? { items.indices.first { rect($0).contains(p) } }

    override func draw(_ dirtyRect: NSRect) {
        for (i, it) in items.enumerated() {
            let r = rect(i)
            let on = selected.contains(i)
            // Board `.tg`: a capsule of its own, fill2 off, accent tint + accent glyph on; momentary pills show only on hover.
            let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            if mode == .momentary {
                if hover == i { Theme.Colors.fillHover.setFill(); pill.fill() }
            } else {
                (on ? Theme.Colors.accentTint : (hover == i ? Theme.Colors.fillHover : Theme.Colors.fill2)).setFill(); pill.fill()
            }
            let tint = isEnabled ? (on ? Theme.Colors.accent : Theme.Colors.label2) : Theme.Colors.label3
            if let s = it.symbol {
                let t = s.image(size: Theme.Typography.symbolInline, color: tint)
                let sz = t.size
                t.draw(in: NSRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
            } else if let title = it.title {
                var font = Theme.Typography.bodyStrong
                if !it.traits.isEmpty { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(it.traits)), size: font.pointSize) ?? font }
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
                let sz = (title as NSString).size(withAttributes: attrs)
                (title as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
                if let bar = it.bar {
                    // Not flipped (like the mixed dash below): y grows upward, so "under" is the smaller y.
                    let y = bar == 0 ? r.midY - sz.height * 0.32 : (bar == 1 ? r.midY : r.midY + sz.height * 0.32)
                    tint.setFill()
                    NSRect(x: r.midX - sz.width / 2 - 1, y: (y - 0.5).rounded(), width: sz.width + 2, height: 1).fill()
                }
            }
            if mixed.contains(i), !on {
                tint.setFill()
                NSRect(x: r.midX - 3, y: r.minY + 3, width: 6, height: 1.5).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        mixed = []
        switch mode {
        case .selectOne: selected = [i]
        case .toggle: if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
        case .momentary: break
        }
        onPress?(i)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true; sqToolTip = i.map { items[$0].tip } }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { r in
            self.draw(in: r)
            color.setFill(); r.fill(using: .sourceAtop)
            return true
        }
        return img
    }
}

// MARK: Menu button

/// The panel's popup: an `SQPopup` (20 high, radius 5, `fill`) with the index / id API the inspector was built on.
@MainActor
final class TextPanelMenuButton: SQPopup {
    private(set) var titles: [String] = []
    private(set) var ids: [String?] = []
    private(set) var selectedIndex = -1
    /// Shown when nothing is selected (e.g. "Custom").
    var placeholder = ""
    var onSelect: ((Int) -> Void)?

    override var displayTitle: String { selectedTitle ?? placeholder }

    init() {
        super.init(frame: .zero, pullsDown: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) { super.init(frame: buttonFrame, pullsDown: flag) }

    /// Right-click menu (e.g. look actions); nil result shows nothing.
    var contextItems: (() -> [SQMenuItem])?
    override func rightMouseDown(with event: NSEvent) {
        guard let items = contextItems?(), !items.isEmpty else { return super.rightMouseDown(with: event) }
        SQContextMenu.show(items: items, for: event, in: self)
    }

    func setItems(_ titles: [String], ids: [String?]? = nil, selected: Int) {
        self.titles = titles
        self.ids = ids ?? Array(repeating: nil, count: titles.count)
        menu?.removeAllItems()
        for (i, t) in titles.enumerated() {
            let item = NSMenuItem(title: t, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self; item.tag = i
            menu?.addItem(item)
        }
        selectedIndex = titles.indices.contains(selected) ? selected : -1
        selectItem(at: selectedIndex)
        needsDisplay = true
    }

    func select(title: String?) {
        selectedIndex = title.flatMap { titles.firstIndex(of: $0) } ?? -1
        selectItem(at: selectedIndex)
        needsDisplay = true
    }

    var selectedID: String? { ids.indices.contains(selectedIndex) ? ids[selectedIndex] : nil }
    var selectedTitle: String? { titles.indices.contains(selectedIndex) ? titles[selectedIndex] : nil }

    @objc private func picked(_ item: NSMenuItem) {
        selectedIndex = item.tag
        selectItem(at: item.tag)
        onSelect?(item.tag)
    }

    override func accessibilityValue() -> Any? { displayTitle }
}
