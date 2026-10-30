import AppKit

/// Shared drawing for the Library, Project and Effects panels (Panels board, "Library, Effects, Project").

/// Filter chip (v9 `.chip.xs`): 20 high capsule, 11 pt, `fill` with `label2` text, on = `selection` fill with `label` text.
public final class LibraryChip: SQButton {
    public static let height: CGFloat = 20

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.pushOnPushOff)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
    }
    public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: Theme.Typography.body]).width
        return NSSize(width: ceil(w) + 2 * Theme.Spacing.sm, height: Self.height)
    }

    public override var state: NSControl.StateValue { didSet { needsDisplay = true } }

    public override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let path = NSBezierPath(roundedRect: bounds, xRadius: Self.height / 2, yRadius: Self.height / 2)
        (on ? Theme.Colors.selection : Theme.Colors.fill).setFill()
        path.fill()
        let s = NSAttributedString(string: title, attributes: [
            .font: Theme.Typography.body,
            .foregroundColor: on ? Theme.Colors.label : Theme.Colors.label2,
        ])
        let size = s.size()
        s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    public override func accessibilityValue() -> Any? { state == .on }
}

/// Filter chips in a wrapping row (v9 `.chips`: `display:flex; gap:4px; flex-wrap:wrap; margin-bottom:8px`).
/// The height follows the width: one row = 20 + 8, two rows = 20 + 4 + 20 + 8.
public final class LibraryChipFlow: NSView {
    private var chips: [NSView] = []
    private var heightConstraint: NSLayoutConstraint!
    public static let bottomPad: CGFloat = 8
    public static let wrapGap: CGFloat = 4

    public override init(frame: NSRect) {
        super.init(frame: frame)
        heightConstraint = heightAnchor.constraint(equalToConstant: LibraryChip.height + Self.bottomPad)
        heightConstraint.isActive = true
    }
    public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: heightConstraint.constant) }
    /// A hidden row gives its space back (the views below are pinned to its bottom edge).
    private var fullHeight = LibraryChip.height + bottomPad
    public override var isHidden: Bool {
        didSet { if oldValue != isHidden { heightConstraint.constant = isHidden ? 0 : fullHeight } }
    }

    public func addChip(_ chip: NSView) {
        chips.append(chip)
        addSubview(chip)
        chip.translatesAutoresizingMaskIntoConstraints = true
    }

    /// Frames for `width`: (origin per chip, number of rows).
    public static func place(sizes: [NSSize], width: CGFloat) -> (origins: [NSPoint], rows: Int) {
        var x: CGFloat = 0, row = 0
        var out: [NSPoint] = []
        for s in sizes {
            if x > 0, x + s.width > width { x = 0; row += 1 }
            out.append(NSPoint(x: x, y: CGFloat(row) * (LibraryChip.height + wrapGap)))
            x += s.width + wrapGap
        }
        return (out, row + 1)
    }

    public override func layout() {
        super.layout()
        let sizes = chips.map(\.intrinsicContentSize)
        let placed = Self.place(sizes: sizes, width: bounds.width)
        for (chip, (origin, size)) in zip(chips, zip(placed.origins, sizes)) {
            chip.frame = NSRect(origin: origin, size: size)
        }
        let h = CGFloat(placed.rows) * LibraryChip.height + CGFloat(placed.rows - 1) * Self.wrapGap + Self.bottomPad
        fullHeight = h
        let target = isHidden ? 0 : h
        if heightConstraint.constant != target {
            heightConstraint.constant = target
            invalidateIntrinsicContentSize()
        }
    }
}

/// Table / outline row: optional faint stripe on every second row (`rowAlt`) and a selection fill, either full width
/// (tables) or a rounded pill (v9 `.row`: the Library tree, Effects, Keystones), which also lifts on hover.
public final class LibraryRowView: NSTableRowView {
    public var isStripe = false { didSet { needsDisplay = true } }
    /// Radius of the selection pill; 0 = full-width fill.
    public var selectionRadius: CGFloat = 0
    /// v9 `.row:hover`: faint fill under the pointer (off for group captions).
    public var showsHover = false
    /// Horizontal inset of the pill (v9 `.clist{padding:4px 8px}`: rows sit 8 in from the panel edges).
    public var pillInset: CGFloat = 0
    private var focused = false
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard showsHover else { tracking = nil; return }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(a); tracking = a
    }
    public override func mouseEntered(with event: NSEvent) { hovered = true }
    public override func mouseExited(with event: NSEvent) { hovered = false }
    public override func prepareForReuse() { super.prepareForReuse(); hovered = false; hoverSync.refresh() }

    /// Scrolling under a resting pointer sends no mouseExited: the pointer is re-read on every scroll step and on reuse.
    private lazy var hoverSync = ScrollHoverSync(view: self) { [weak self] p in self?.hovered = p != nil }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hoverSync.attach(); hoverSync.refresh() }
    /// Tests: apply a pointer position (window coordinates) as the scroll refresh would.
    public func syncHover(atWindowPoint p: NSPoint) { hovered = ScrollHoverSync.pointer(over: self, atWindowPoint: p) != nil }
    public var isHovered: Bool { hovered }

    private func fillPill() {
        let r = bounds.insetBy(dx: pillInset, dy: 0)
        if selectionRadius > 0 {
            NSBezierPath(roundedRect: r, xRadius: selectionRadius, yRadius: selectionRadius).fill()
        } else {
            r.fill()
        }
    }

    public override var isEmphasized: Bool {
        get { focused }
        set { if focused != newValue { focused = newValue; needsDisplay = true } }
    }

    public override func drawBackground(in dirtyRect: NSRect) {
        if isStripe { Theme.Colors.rowAlt.setFill(); bounds.fill() }
        if showsHover, hovered, !isSelected { Theme.Selection.hover.setFill(); fillPill() }
    }

    public override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        (focused ? Theme.Selection.fillFocused : Theme.Selection.fill).setFill()
        fillPill()
    }
}

/// Yellow tile ring (board `.tile.on .tn`): 2 pt outside the thumbnail, radius 5 + 2.
@MainActor
public enum LibraryTile {
    public static let ringWidth: CGFloat = 2
    public static let thumbRadius: CGFloat = Theme.Radius.control
    /// Thumbnail aspect of the v9 tiles (16 : 10).
    public static let aspect: CGFloat = 10.0 / 16.0
    public static let nameGap: CGFloat = Theme.Spacing.xs
    public static let nameHeight: CGFloat = 14

    /// Tile size for a thumbnail width.
    public static func size(thumbWidth w: CGFloat) -> NSSize {
        NSSize(width: w, height: (w * aspect).rounded() + nameGap + nameHeight)
    }

    /// Slider fraction (0...1) -> thumbnail width; 0.4 is the board's 96.
    public static func thumbWidth(forFraction f: Double) -> CGFloat { (64 + 80 * CGFloat(min(max(f, 0), 1))).rounded() }
    public static let defaultFraction = 0.4
}

/// Tile (v9 `.tile`): thumbnail (aspect fill, radius 6), name below (left, 11 pt, `label2`), selected = 2 pt yellow ring.
public final class LibraryTileView: NSView {
    public let thumb = NSView()
    private let glyph = NSImageView()
    private let ring = NSView()
    public let nameField = NSTextField(labelWithString: "")
    public let badge = NSImageView()

    public var isRingVisible = false { didSet { ring.isHidden = !isRingVisible } }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = LibraryTile.thumbRadius
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = Theme.Colors.tileBackground.cgColor
        thumb.layer?.contentsGravity = .resizeAspectFill
        glyph.contentTintColor = Theme.Colors.label3
        glyph.imageScaling = .scaleNone
        ring.wantsLayer = true
        ring.layer?.borderColor = Theme.Colors.yellow.cgColor
        ring.layer?.borderWidth = LibraryTile.ringWidth
        ring.layer?.cornerRadius = LibraryTile.thumbRadius + LibraryTile.ringWidth
        ring.isHidden = true
        nameField.font = Theme.Typography.body
        nameField.textColor = Theme.Colors.label2
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.alignment = .left
        badge.image = Theme.symbol(.starFilled, size: 10, label: "Favorite")
        badge.contentTintColor = Theme.Colors.yellow
        badge.isHidden = true
        for v in [thumb, glyph, ring, nameField, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let r = LibraryTile.ringWidth
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: topAnchor),
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumb.heightAnchor.constraint(equalTo: thumb.widthAnchor, multiplier: LibraryTile.aspect),
            glyph.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            ring.topAnchor.constraint(equalTo: thumb.topAnchor, constant: -r),
            ring.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: r),
            ring.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: -r),
            ring.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: r),
            nameField.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: LibraryTile.nameGap),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor),
            badge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -Theme.Spacing.xs),
            badge.topAnchor.constraint(equalTo: thumb.topAnchor, constant: Theme.Spacing.xs),
        ])
    }
    public required init?(coder: NSCoder) { fatalError() }

    /// Picture (or a symbol while there is none).
    public func setPicture(_ image: NSImage?, symbol: SQIcon) {
        if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            thumb.layer?.contents = cg
            glyph.image = nil
        } else {
            thumb.layer?.contents = nil
            glyph.image = Theme.symbol(symbol, size: 22)
        }
    }
}
