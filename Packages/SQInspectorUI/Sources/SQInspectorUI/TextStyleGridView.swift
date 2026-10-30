import AppKit
import SQText

/// Pure layout of the style cells (testable): the "+" cell comes after the last style; `columns == nil` = one row.
enum TextStyleGridLayout {
    static func frames(count: Int, cell: NSSize, gap: CGFloat, columns: Int?) -> [NSRect] {
        (0..<count).map { i in
            let col = columns.map { i % max($0, 1) } ?? i
            let row = columns.map { i / max($0, 1) } ?? 0
            return NSRect(x: CGFloat(col) * (cell.width + gap), y: CGFloat(row) * (cell.height + gap), width: cell.width, height: cell.height)
        }
    }

    static func size(count: Int, cell: NSSize, gap: CGFloat, columns: Int?) -> NSSize {
        guard count > 0 else { return .zero }
        let cols = columns.map { min(max($0, 1), count) } ?? count
        let rows = columns.map { (count + max($0, 1) - 1) / max($0, 1) } ?? 1
        return NSSize(width: CGFloat(cols) * cell.width + CGFloat(cols - 1) * gap,
                      height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap)
    }
}

/// Thumbnails of the text styles, one per look, drawn with the real text renderer (cached). Click applies the look to the
/// selected clip (one undo step); the last cell saves the current look under a name typed in place. Right-click on a
/// style: Rename, Update Style (when the clip was edited away from it), Delete. Built-in looks are read-only.
@MainActor
final class TextStyleGridView: NSView, NSTextFieldDelegate {
    let model: TextInspectorModel
    /// The clip's text (thumbnails show it when short, else "Aa").
    var clipText: () -> String = { "" }
    /// nil = single row (the strip); a number = wrapping grid (the popover).
    var columns: Int? { didSet { resize() } }
    var onApplied: (() -> Void)?

    static let cellSize = NSSize(width: 96, height: 48)
    static let gap: CGFloat = 6

    private var hover: Int?
    private var tracking: NSTrackingArea?
    private var editor: NSTextField?
    private var editing: Editing?

    private enum Editing { case new, rename(String) }

    private var entries: [TextStyleEntry] { model.styles.entries }
    /// Cells = styles + the "+" cell.
    private var cellCount: Int { entries.count + 1 }
    private var frames: [NSRect] { TextStyleGridLayout.frames(count: cellCount, cell: Self.cellSize, gap: Self.gap, columns: columns) }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        TextStyleGridLayout.size(count: cellCount, cell: Self.cellSize, gap: Self.gap, columns: columns)
    }

    init(model: TextInspectorModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: .zero))
        setAccessibilityRole(.list)
        setAccessibilityLabel("Text styles")
        setFrameSize(intrinsicContentSize)
        track()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func track() {
        withObservationTracking {
            _ = model.styles; _ = model.style
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.resize(); self.track()
            }
        }
    }

    private func resize() {
        invalidateIntrinsicContentSize()
        setFrameSize(intrinsicContentSize)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let sample = TextStyleThumbnails.sample(forClipText: clipText())
        let selected = model.selectedStyleID
        for (i, r) in frames.enumerated() where r.intersects(dirtyRect) {
            if i == entries.count { drawPlus(r, hovered: hover == i); continue }
            let e = entries[i]
            let tile = Self.tileColor(for: e.style)
            let body = NSBezierPath(roundedRect: r, xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
            tile.setFill(); body.fill()
            if hover == i { Theme.State.rowHover.setFill(); body.fill() }
            if let img = TextStyleThumbnails.shared.image(style: e.style, text: sample) {
                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                let k = min(1, (r.width - 14) / max(iw, 1), (r.height - 12) / max(ih, 1))
                let w = iw * k, h = ih * k
                let dest = NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
                NSGraphicsContext.current?.cgContext.saveGState()
                NSGraphicsContext.current?.cgContext.interpolationQuality = .high
                // The context is flipped: draw the CGImage upright.
                NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: dest.minY + dest.maxY)
                NSGraphicsContext.current?.cgContext.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current?.cgContext.draw(img, in: dest)
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
            if e.id == selected || e.id == model.appliedStyleID {
                Theme.Colors.accent.setStroke()
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
                ring.lineWidth = 2; ring.stroke()
                if e.id != selected, model.isStyleModified {          // edited away from it: a small dot
                    Theme.Colors.accent.setFill()
                    NSBezierPath(ovalIn: NSRect(x: r.maxX - 11, y: r.minY + 5, width: 6, height: 6)).fill()
                }
            }
        }
    }

    private func drawPlus(_ r: NSRect, hovered: Bool) {
        let body = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.Radius.control, yRadius: Theme.Radius.control)
        (hovered ? Theme.Colors.fillHover : Theme.Colors.fill2).setFill(); body.fill()
        let c = NSPoint(x: r.midX, y: r.midY)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x - 6, y: c.y)); p.line(to: NSPoint(x: c.x + 6, y: c.y))
        p.move(to: NSPoint(x: c.x, y: c.y - 6)); p.line(to: NSPoint(x: c.x, y: c.y + 6))
        Theme.Colors.label2.setStroke(); p.lineWidth = 1.2; p.lineCapStyle = .round; p.stroke()
    }

    /// Light text gets a dark tile, dark text a light one, so every look stays readable.
    static func tileColor(for s: TextStyle) -> NSColor {
        if s.background != nil { return Theme.Colors.fill2.blended(withFraction: 0.5, of: .black) ?? Theme.Colors.fill2 }
        let lum = 0.2126 * s.color.red + 0.7152 * s.color.green + 0.0722 * s.color.blue
        return lum < 0.3 ? Theme.Colors.label : Theme.Colors.content
    }

    // MARK: Mouse

    private func index(at p: NSPoint) -> Int? { frames.firstIndex { $0.contains(p) } }

    override func mouseDown(with event: NSEvent) {
        commitEditor()
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        if i == entries.count { beginNaming(.new, at: i); return }
        model.applyStyle(entries[i].id)
        needsDisplay = true
        onApplied?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)), i < entries.count else { return super.rightMouseDown(with: event) }
        SQContextMenu.show(items: contextItems(forEntry: i), for: event, in: self)
    }

    func contextItems(forEntry i: Int) -> [SQMenuItem] {
        let e = entries[i]
        return [
            SQMenuItem(title: "Rename\u{2026}", isEnabled: !e.isBuiltIn) { [weak self] in self?.beginNaming(.rename(e.id), at: i) },
            SQMenuItem(title: "Update Look", isEnabled: !e.isBuiltIn && model.appliedStyleID == e.id && model.isStyleModified) { [weak self] in
                self?.model.updateStyleFromCurrent(e.id)
            },
            .separator,
            SQMenuItem(title: "Delete", isEnabled: !e.isBuiltIn) { [weak self] in self?.model.deleteStyle(e.id) },
        ]
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with event: NSEvent) {
        let i = index(at: convert(event.locationInWindow, from: nil))
        guard i != hover else { return }
        hover = i; needsDisplay = true
        sqToolTip = i.map { $0 < entries.count ? entries[$0].name : "Save the current look as a style" }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    // MARK: Naming in place

    private func beginNaming(_ kind: Editing, at i: Int) {
        commitEditor()
        let f = SQTextField(frame: frames[i].insetBy(dx: 4, dy: 12))
        f.placeholderString = "Style name"
        f.alignment = .center
        f.focusRingType = .none
        f.delegate = self
        if case .rename(let id) = kind { f.stringValue = model.styles.entry(id)?.name ?? "" }
        addSubview(f)
        editor = f; editing = kind
        window?.makeFirstResponder(f)
    }

    private func commitEditor() {
        guard let f = editor, let kind = editing else { return }
        editor = nil; editing = nil
        let name = f.stringValue
        f.delegate = nil
        f.removeFromSuperview()
        switch kind {
        case .new: model.saveCurrentAsStyle(named: name)
        case .rename(let id): model.renameStyle(id, to: name)
        }
        needsDisplay = true
    }

    private func cancelEditor() {
        editor?.delegate = nil
        editor?.removeFromSuperview()
        editor = nil; editing = nil
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitEditor(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelEditor(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking elsewhere keeps what was typed (an empty name just drops the cell).
        if editor != nil { commitEditor() }
    }
}
