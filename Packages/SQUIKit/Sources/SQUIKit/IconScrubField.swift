import AppKit

/// A scrub field led by an icon instead of a word (text panel metrics: letter spacing, line spacing). The icon sits left
/// of the number, the tooltip on both names the value. The control is as high as a plain field and as wide as its row
/// gives it; `field` is the ScrubField to configure (range, step, callbacks).
@MainActor
public final class IconScrubField: NSView {
    public let field = ScrubField()
    public let icon: SQIcon
    public static let iconWidth: CGFloat = 18
    private let imageView = NSImageView()

    public init(icon: SQIcon, tip: String) {
        self.icon = icon
        super.init(frame: .zero)
        field.isPlain = true
        imageView.image = icon.image(size: Theme.Typography.symbolInline, color: Theme.Colors.label3)
        imageView.imageScaling = .scaleNone
        imageView.setAccessibilityLabel(tip)
        addSubview(field); addSubview(imageView)
        field.sqToolTip = tip; imageView.sqToolTip = tip; sqToolTip = tip
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: ControlsGrid.controlHeight) }

    public override func layout() {
        super.layout()
        let h = bounds.height
        imageView.frame = NSRect(x: 0, y: 0, width: Self.iconWidth, height: h)
        field.frame = NSRect(x: Self.iconWidth, y: 0, width: max(bounds.width - Self.iconWidth, 0), height: h)
    }
}
