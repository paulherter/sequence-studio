import AppKit
import SQCore

/// Controls panel columns and glyph sizes (the row heights are in ControlsMetrics.swift, portable).
extension ControlsMetrics {
    // Column edges: all from `ControlsGrid` (the one grid). The names below are the older ones the rows still read.
    static let sectionLeading: CGFloat = ControlsGrid.headerToggleX
    static let chevronSlot: CGFloat = ControlsGrid.toggleWidth
    static let eyeSlot: CGFloat = ControlsGrid.resetWidth
    static let resetSlot: CGFloat = ControlsGrid.resetWidth
    static let trailing: CGFloat = ControlsGrid.trailing
    static let diamondSlot: CGFloat = ControlsGrid.toggleWidth
    static let labelX: CGFloat = ControlsGrid.labelX
    static let navigation: CGFloat = ControlsGrid.navigationWidth
    static let valueWidth: CGFloat = ControlsGrid.valueWidth
    static let popupWidth: CGFloat = Theme.Inspector.popupWidth
    static let valueX: CGFloat = ControlsGrid.valueX
    /// Left edge of the n-th value field of a row (0 = shared edge, 1 = second column, 2 = link button).
    static func valueColumn(_ index: Int) -> CGFloat { ControlsGrid.valueColumn(index) }
    /// Right edge of the values of a row `width` wide.
    static func valuesMaxX(_ width: CGFloat) -> CGFloat { ControlsGrid(width: width).valueMaxX }

    /// Color of the n-th row drawn in one speed graph (v9: first row accent, second light).
    static func curveColor(_ index: Int) -> NSColor {
        switch index {
        case 0: Theme.Colors.accentText
        case 1: Theme.Colors.label
        default: Theme.Palette.graphCurve[(index - 2) % Theme.Palette.graphCurve.count]
        }
    }
}

/// Line and fill strengths of the Controls panel (sq.css `.ruler`, `.epane`, build.py `egraph`): names for the Theme tokens.
enum ControlsColors {
    /// `.ruler .t` left line, `.eg` dashed Steady line.
    static let rulerLine = Theme.Colors.rulerLine
    /// `.ruler .mn`.
    static let rulerMinor = Theme.Colors.rulerMinor
    static let graphGrid = Theme.Colors.graphGrid
    static let graphBaseline = Theme.Colors.graphBaseline
    static let steadyLine = Theme.Colors.rulerLine
    static let handleLine = Theme.Colors.graphHandleLine
    /// `.epane` background over the panel color.
    static let paneFill = Theme.Colors.graphPane
}

/// The animation switch of a parameter row (`.an`): hollow while the parameter is static, filled accent while it has
/// keys. Click: off -> on sets the first key at the playhead; on -> off asks, then removes all keys (see
/// `EffectControlsView.stopwatchTapped`). Adding / removing one key is the diamond button in the navigation.
final class AnimateDiamondView: NSControl {
    var keyState: ScrubKeyframeState = .none { didSet { if oldValue != keyState { needsDisplay = true; updateAccessibility() } } }
    var onClick: (@MainActor () -> Void)?
    private let propertyName: String
    private var hovering = false { didSet { if oldValue != hovering { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    init(propertyName: String) {
        self.propertyName = propertyName
        super.init(frame: .zero)
        setAccessibilityRole(.checkBox)
        updateAccessibility()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    /// Tooltip / accessibility name for the state.
    static func label(_ state: ScrubKeyframeState, propertyName: String) -> String {
        switch state {
        case .none: SQL10n.format("Animate %@", propertyName)
        case .between, .onKey: SQL10n.format("Stop Animating %@", propertyName)
        }
    }

    private func updateAccessibility() {
        let l = Self.label(keyState, propertyName: propertyName)
        sqToolTip = Tooltip.text(l, shortcut: nil)
        setAccessibilityLabel(l)
        setAccessibilityValue(keyState == .none ? 0 : 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        // `.an`: 7 pt square turned 45 degrees, centered in the toggle column.
        let s = ControlsMetrics.toggleSide
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let path = KeyGlyphPath.diamond(centre: c, side: s)
        if keyState == .none {
            (hovering && isEnabled ? Theme.Colors.label2 : Theme.Colors.label3).setStroke()
            let inner = KeyGlyphPath.diamond(centre: c, side: s - 1.2)
            inner.lineWidth = 1.2
            inner.stroke()
        } else {
            Theme.Colors.accent.setFill()
            path.fill()
        }
    }
}

/// Shapes of the key glyphs (lanes, animate diamond, speed graph).
enum KeyGlyphPath {
    /// A square of `side` turned 45 degrees around `center`.
    static func diamond(centre c: CGPoint, side: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.append(NSBezierPath(cgPath: cgDiamond(centre: c, side: side)))
        return p
    }

    static func cgDiamond(centre c: CGPoint, side: CGFloat) -> CGPath {
        let h = side * 0.5 * 2.0.squareRoot()
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y - h)); p.addLine(to: CGPoint(x: c.x + h, y: c.y))
        p.addLine(to: CGPoint(x: c.x, y: c.y + h)); p.addLine(to: CGPoint(x: c.x - h, y: c.y))
        p.closeSubpath()
        return p
    }

    /// The lane key of v9 (`.dm`): the square has 1.5 pt corners before it is turned.
    static func cgRoundedDiamond(centre c: CGPoint, side: CGFloat, radius: CGFloat = 1.5) -> CGPath {
        var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: .pi / 4)
        let r = min(radius, side / 2)
        return CGPath(roundedRect: CGRect(x: -side / 2, y: -side / 2, width: side, height: side), cornerWidth: r, cornerHeight: r, transform: &t)
    }

    /// Adds the glyph of `shape` to `path`: diamond = steady, circle = eased, square = hold, pointed square = hold ahead.
    static func add(_ shape: KeyShape, at c: CGPoint, side: CGFloat, to path: CGMutablePath) {
        switch shape {
        case .diamond: path.addPath(cgRoundedDiamond(centre: c, side: side))
        case .circle:
            let d = side + 1        // v9 `.dm.k-e`: 10 pt beside the 9 pt diamond
            path.addEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
        case .ahead:
            let pts = KeyShape.ahead.corners(at: c, size: side / 0.82)
            path.move(to: pts[0]); pts.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
        case .square:
            path.addPath(CGPath(roundedRect: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side),
                                cornerWidth: 1, cornerHeight: 1, transform: nil))
        }
    }
}

/// Key navigation of an animated parameter row (`.kp .nav`): previous key, add / remove key at the playhead (the key
/// diamond, filled on a key), next key, Open (the inline speed graph; chevron down = closed, up and accent = opened).
/// 72 pt wide, hidden while the parameter is not animated.
final class ControlsKeyNavigation: NSView {
    let previous: IconButton
    let key: IconButton
    let next: IconButton
    let open: IconButton
    private let propertyName: String
    var showsOpen = true { didSet { open.isHidden = !showsOpen } }
    var isOpen = false { didSet { if oldValue != isOpen { applyOpen() } } }
    /// Previous key, add / remove key and next key are always shown (feedback 2026-10-11: a control that exists is visible, no hover).
    var showsKeyButtons = true { didSet { for b in [previous, key, next] { b.isHidden = !showsKeyButtons } } }

    init(propertyName: String, onPrevious: @escaping () -> Void, onToggleKey: @escaping () -> Void,
         onNext: @escaping () -> Void, onOpen: @escaping () -> Void) {
        self.propertyName = propertyName
        previous = IconButton(symbol: .chevronLeft, label: "Previous Keyframe", handler: onPrevious)
        key = IconButton(keyDiamondLabel: "Add/Remove Keyframe", handler: onToggleKey)
        next = IconButton(symbol: .chevronRight, label: "Next Keyframe", handler: onNext)
        open = IconButton(symbol: .chevronRight, label: SQL10n.format("Open %@ Curve", propertyName), handler: onOpen)
        open.fillsWhenPressed = false
        super.init(frame: .zero)
        for b in [previous, key, next, open] { addSubview(b) }
        applyOpen()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func applyOpen() {
        // v9 `.kcv`: chevron right, turned down and `label` while the curve is open.
        open.setSymbol(isOpen ? .chevronDown : .chevronRight, tint: isOpen ? Theme.Colors.label : Theme.Colors.label3,
                       size: Theme.Typography.symbolSmall)
        let l = isOpen ? SQL10n.format("Close %@ Curve", propertyName) : SQL10n.format("Open %@ Curve", propertyName)
        open.sqToolTip = Tooltip.text(l, shortcut: nil)
        open.setAccessibilityLabel(l)
    }

    override func layout() {
        super.layout()
        // Four equal slots filling the tail column.
        let w = bounds.width / 4
        for (i, b) in [previous, key, next, open].enumerated() {
            b.frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
        }
    }
}

/// The keyframe controls of one parameter row: the animate diamond at the row's leading edge and the key navigation
/// at its trailing edge (shown only while the parameter has keys).
@MainActor final class ParameterKeyControls {
    let diamond: AnimateDiamondView
    let navigation: ControlsKeyNavigation
    /// Per-property reset (the section reset's icon): always visible in its fixed slot at the trailing edge, dimmed while the
    /// property is at its default. Nil on a row that has no reset of its own.
    let reset: IconButton?

    /// `onAnimate`: the animation switch (left diamond) was clicked. `onToggleKey`: the add / remove key button.
    /// `onOpen` nil = the row has no curve to open.
    init(propertyName: String, onAnimate: @escaping @MainActor () -> Void, onPrevious: @escaping () -> Void,
         onToggleKey: @escaping () -> Void, onNext: @escaping () -> Void, onOpen: (() -> Void)? = nil, onReset: (() -> Void)? = nil) {
        reset = onReset.map { IconButton(symbol: .reset, label: SQL10n.format("Reset %@", propertyName), handler: $0) }
        reset?.sqToolTip = Tooltip.text(SQL10n.format("Reset %@", propertyName), shortcut: nil)
        diamond = AnimateDiamondView(propertyName: propertyName)
        diamond.onClick = onAnimate
        navigation = ControlsKeyNavigation(propertyName: propertyName, onPrevious: onPrevious, onToggleKey: onToggleKey,
                                       onNext: onNext, onOpen: onOpen ?? {})
        navigation.showsOpen = onOpen != nil
    }

    func install(in row: NSView) {
        row.addSubview(diamond); row.addSubview(navigation)
        if let reset { row.addSubview(reset) }
    }

    /// The tail column of the row: navigation (while shown) and the reset slot; nil when it holds nothing.
    var tailFrame: NSRect? {
        let nav = navigation.isHidden ? nil : navigation.frame
        return [nav, reset?.frame].compactMap { $0 }.reduce(nil) { acc, f in acc.map { $0.union(f) } ?? f }
    }

    var state = KeyframeControlState(ring: .none, showsNavigation: false, canGoPrevious: false, canGoNext: false,
                                     canToggleKey: false, keyIsOn: false) {
        didSet {
            diamond.keyState = state.showsNavigation ? .onKey : .none     // the switch: filled while animated
            navigation.isHidden = !state.showsNavigation
            navigation.key.isEnabled = state.canToggleKey
            navigation.key.setKeyDiamond(onKey: state.keyIsOn)
            navigation.previous.isEnabled = state.canGoPrevious
            navigation.next.isEnabled = state.canGoNext
        }
    }

    func layout(rowBounds b: NSRect, diamondX: CGFloat = ControlsGrid.toggleX) {
        diamond.frame = NSRect(x: diamondX, y: 0, width: ControlsGrid.toggleWidth, height: b.height)
        let grid = ControlsGrid(width: b.width)
        navigation.frame = grid.navigationFrame(height: b.height)
        reset?.frame = grid.resetFrame(height: b.height)
    }
}
