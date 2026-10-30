import AppKit
import SQCore

/// The edit mode capsule in the timeline header (design variant B, docs/research/mode-switch): icon + label, quiet fill
/// for Normal, accent tint for Fast Cut. A click opens the SQ menu under it; the mode changes only when a row is picked.
@MainActor
final class TimelineModeChip: NSControl {
    var mode: TimelineEditMode = .normal { didSet { if mode != oldValue { needsDisplay = true } } }
    /// A row of the menu was picked (not yet applied: the owner decides and sets `mode`).
    var onPick: ((TimelineEditMode) -> Void)?
    var menuItems: [SQMenuItem] { TimelineModeMenu.items(current: mode) { [weak self] in self?.onPick?($0) } }

    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    /// SQ tooltip, never the system one.
    override var toolTip: String? {
        get { sqToolTip }
        set { sqToolTip = newValue }
    }

    static let iconSize = TimelineModeMenu.iconSize
    static let leftPadding = TimelineModeMenu.leftPadding
    static let rightPadding = TimelineModeMenu.rightPadding
    /// Wide enough for the longer label, so the header does not shift when the mode changes.
    static var width: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body]
        let label = [TimelineEditMode.normal, .magnetic].map { (TimelineModeMenu.chipLabel($0) as NSString).size(withAttributes: attrs).width }.max() ?? 0
        return ceil(leftPadding + iconSize + Theme.Spacing.iconToLabel + label + rightPadding)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { openMenu() }
    override func accessibilityPerformPress() -> Bool { openMenu(); return true }

    func openMenu() { SQContextMenu.popUp(items: menuItems, below: self) }

    override func draw(_ dirtyRect: NSRect) {
        let fast = mode == .magnetic
        let tint = fast ? Theme.Colors.accent : Theme.Colors.label2
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (fast ? Theme.Colors.accentTint : (hovering ? Theme.State.controlHover : Theme.Colors.fill)).setFill()
        shape.fill()
        let size = Self.iconSize
        TimelineModeMenu.icon(mode).image(size: size, color: tint)
            .draw(in: NSRect(x: Self.leftPadding, y: (bounds.height - size) / 2, width: size, height: size).integral)
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.Typography.body, .foregroundColor: tint]
        let text = TimelineModeMenu.chipLabel(mode) as NSString
        let h = text.size(withAttributes: attrs).height
        text.draw(at: NSPoint(x: Self.leftPadding + size + Theme.Spacing.iconToLabel, y: ((bounds.height - h) / 2).rounded()),
                  withAttributes: attrs)
    }
}
