import AppKit

/// The one icon-only button (INTERACTION-AUDIT "IconButton"; replaces `ClosureButton`, which stays as a typealias).
/// An `SQButton` in `.icon` style with a closure handler. States:
/// - rest: no fill, `label2` glyph (or `contentTintColor`);
/// - hover: glyph brightens to `label`, no fill (States board); pressed: `State.pressed` fill;
/// - selected (`isSelected`, e.g. "on a keyframe", an active toggle): `accent` glyph, no fill (board `.btn.ic.on`);
/// - disabled: no fill, glyph at `State.disabledAlpha`;
/// - focused (Full Keyboard Access): the `SQButton` focus line (`State.focusLine`), no ring of its own.
/// The tooltip is the name plus the command's key (`Tooltip.text`), never a sentence.
open class IconButton: SQButton {
    public var handler: (() -> Void)?
    /// Cursor while hovering (nil = arrow, the macOS default for buttons).
    public var hoverCursor: NSCursor? { didSet { window?.invalidateCursorRects(for: self) } }
    /// Board `.btn.ic.on`: the selected state is the accent glyph only; set true to also fill (none do today).
    public var fillsWhenSelected = false
    /// False for disclosure chevrons: pressing them changes nothing behind the glyph (no gray layer).
    public var fillsWhenPressed = true
    public var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }

    /// Symbol size of row icon buttons (prev / next / reset / chevrons).
    public static let symbolSize: CGFloat = 10

    public convenience init(symbol: SQIcon, label rawLabel: String, command: EditorCommand? = nil,
                            size: CGFloat = IconButton.symbolSize, handler: @escaping () -> Void) {
        let label = SQL10n.string(rawLabel)
        self.init(frame: .zero)
        self.handler = handler
        title = ""
        imagePosition = .imageOnly
        image = Self.symbolImage(symbol, label: label, size: size)
        contentTintColor = Theme.Colors.label2
        sqToolTip = command.map { Tooltip.text(label, command: $0) } ?? Tooltip.text(label, shortcut: nil)
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
    }

    /// The key button of a property row: the same diamond with a center dot as the keyframe toggle, drawn, not a symbol.
    public convenience init(keyDiamondLabel label: String, handler: @escaping () -> Void) {
        self.init(symbol: .diamond, label: label, handler: handler)
        setKeyDiamond(onKey: false)
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        style = .icon
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        style = .icon
    }

    @objc private func fire() { handler?() }

    public func setSymbol(_ name: SQIcon, tint: NSColor, size: CGFloat = IconButton.symbolSize) {
        image = Self.symbolImage(name, label: toolTip, size: size)
        contentTintColor = tint
    }

    /// Design v7: diamond filled `accent` on a key, outlined and dim (`label3`, hover `label`) otherwise.
    public func setKeyDiamond(onKey: Bool) {
        image = onKey ? Self.diamondOn : Self.diamondOff
        contentTintColor = onKey ? Theme.Colors.accent : Theme.Colors.label3
    }
    private static let diamondOn = KeyframeToggleView.diamondImage(filled: true)
    private static let diamondOff = KeyframeToggleView.diamondImage(filled: false)

    static func symbolImage(_ name: SQIcon, label: String?, size: CGFloat) -> NSImage? {
        Theme.symbol(name, size: size, label: label)
    }

    // MARK: States

    func setHoveredForTesting(_ on: Bool) { isHovered = on }

    override var fillColor: NSColor? {
        guard isEnabled else { return nil }
        if isHighlighted, fillsWhenPressed { return Theme.State.pressed }
        if isSelected, fillsWhenSelected { return Theme.Selection.fill }
        return super.fillColor
    }

    override var foreground: NSColor {
        var base: NSColor = isSelected ? Theme.Colors.accent : (contentTintColor ?? Theme.Colors.label2)
        if isHovered, !isSelected, isEnabled, base == Theme.Colors.label2 || base == Theme.Colors.label3 { base = Theme.Colors.label }   // custom tints stay
        guard isEnabled else { return base.withAlphaComponent(base.alphaComponent * Theme.State.disabledAlpha) }
        return base
    }

    open override var isEnabled: Bool { didSet { window?.invalidateCursorRects(for: self) } }

    open override func resetCursorRects() {
        if let hoverCursor, isEnabled { addCursorRect(bounds, cursor: hoverCursor) }
    }
}

/// Old name of `IconButton` (Effect Controls, Graphics, graph editor); new code says `IconButton`.
typealias ClosureButton = IconButton
