import AppKit

/// The one separator line (INTERACTION-AUDIT "Divider"): 1 pt, `Separator.hairline` between rows / sections,
/// `Separator.divider` for pane splits. (`SQDivider`, not `Divider`, so it never clashes with SwiftUI's.)
public final class SQDivider: NSView {
    public enum Orientation: Sendable { case horizontal, vertical }
    public enum Style: Sendable { case hairline, pane }

    public let orientation: Orientation
    public let style: Style

    public var color: NSColor { style == .pane ? Theme.Separator.divider : Theme.Separator.hairline }

    public init(orientation: Orientation = .horizontal, style: Style = .hairline) {
        self.orientation = orientation
        self.style = style
        super.init(frame: .zero)
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: orientation == .horizontal ? .vertical : .horizontal)
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize {
        orientation == .horizontal
            ? NSSize(width: NSView.noIntrinsicMetric, height: Theme.Separator.width)
            : NSSize(width: Theme.Separator.width, height: NSView.noIntrinsicMetric)
    }

    public override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let w = Theme.Separator.width
        (orientation == .horizontal
            ? NSRect(x: 0, y: 0, width: bounds.width, height: w)
            : NSRect(x: 0, y: 0, width: w, height: bounds.height)).fill()
    }
}
