import AppKit

/// Prev / diamond / next in three equal slots filling the tail column (trailing part of the keyframe control).
/// Its width is `Theme.Inspector.navigationWidth`, the same token as the four-button navigation of the parameter rows.
public final class KeyframeNavigationView: NSView {
    public static let width: CGFloat = Theme.Inspector.navigationWidth

    /// Right-click anywhere on prev / diamond / next.
    var onContextMenu: ((NSEvent) -> Void)?
    public override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }

    public let previous: IconButton
    public let key: IconButton
    public let next: IconButton

    init(onPrevious: @escaping () -> Void, onToggleKey: @escaping () -> Void, onNext: @escaping () -> Void) {
        previous = IconButton(symbol: .chevronLeft, label: "Previous Keyframe", handler: onPrevious)
        key = IconButton(keyDiamondLabel: "Add/Remove Keyframe", handler: onToggleKey)
        next = IconButton(symbol: .chevronRight, label: "Next Keyframe", handler: onNext)
        super.init(frame: .zero)
        for b in [previous, key, next] { addSubview(b) }
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: Theme.Inspector.rowHeight) }

    public override func layout() {
        super.layout()
        let w = bounds.width / 3
        for (i, b) in [previous, key, next].enumerated() {
            b.frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height)
        }
    }
}

/// The one keyframe control (replaces the ring + prev/diamond/next sets built in Effect Controls rows, `PropertyRow`
/// and the Graphics panel). Two views the row places itself: `ring` in the leading slot (`ControlsGrid.toggleX`) and
/// `navigation` trailing. Set `state` from `KeyframeControlState.resolve`; the closures run the model actions (the
/// owner asks before removing keys on a ring click).
@MainActor public final class KeyframeControls {
    public let ring: KeyframeToggleView
    public let navigation: KeyframeNavigationView
    public var state: KeyframeControlState = .off { didSet { if oldValue != state { apply() } } }
    /// Right-click on the ring or the key diamond of an animated property (the owner opens the ease list); the view is the
    /// anchor for a popover.
    public var onContextMenu: ((NSEvent, NSView) -> Void)? {
        didSet {
            ring.onContextMenu = { [weak self] e in if let self, self.state.showsNavigation { self.onContextMenu?(e, self.ring) } }
            navigation.onContextMenu = { [weak self] e in if let self, self.state.showsNavigation { self.onContextMenu?(e, self.navigation.key) } }
        }
    }
    /// Disables every part (locked layer, no clip).
    public var isEnabled = true { didSet { apply() } }

    public init(propertyName: String, onToggleAnimation: @escaping @MainActor () -> Void,
                onPrevious: @escaping () -> Void, onToggleKey: @escaping () -> Void, onNext: @escaping () -> Void) {
        ring = KeyframeToggleView(label: SQL10n.format("Animate %@", propertyName), onToggle: onToggleAnimation)
        navigation = KeyframeNavigationView(onPrevious: onPrevious, onToggleKey: onToggleKey, onNext: onNext)
        apply()
    }

    private func apply() {
        ring.keyState = state.ring
        ring.isEnabled = isEnabled
        navigation.isHidden = !state.showsNavigation
        navigation.previous.isEnabled = isEnabled && state.canGoPrevious
        navigation.next.isEnabled = isEnabled && state.canGoNext
        navigation.key.isEnabled = isEnabled && state.canToggleKey
        navigation.key.setKeyDiamond(onKey: state.keyIsOn)
        ring.needsDisplay = true
    }

    /// Adds both parts to `row`.
    public func install(in row: NSView) {
        row.addSubview(ring)
        row.addSubview(navigation)
    }

    /// Ring centered vertically at `ringX`, navigation ending at `navigationMaxX` (default: row width - trailing).
    public func layout(rowBounds b: NSRect, ringX: CGFloat = ControlsGrid.toggleX, navigationMaxX: CGFloat? = nil) {
        let slot = KeyframeToggleView.slot
        ring.frame = NSRect(x: b.minX + ringX, y: (b.minY + (b.height - slot) / 2).rounded(), width: slot, height: slot)
        let maxX = navigationMaxX ?? (b.maxX - Theme.Inspector.trailing)
        navigation.frame = NSRect(x: maxX - KeyframeNavigationView.width, y: b.minY,
                                  width: KeyframeNavigationView.width, height: b.height)
    }
}
