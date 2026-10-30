import AppKit

/// The one title bar of the own-design windows (Settings, Keyboard Shortcuts, Import from card): a 38 pt strip on the
/// `titlebar` fill with a hairline below and the title centered in the dialog title style. The window keeps its system
/// buttons (full-size content view, transparent title bar); the system title is hidden because the content view covers it.
@MainActor
public final class SQWindowTitleStrip: NSView {
    public static let height: CGFloat = 38
    private let label = NSTextField(labelWithString: "")
    private let line = NSView()

    public var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    public init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.titlebar.cgColor
        label.font = Theme.Typography.titleStrong
        label.textColor = Theme.Dialog.titleColor
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.stringValue = title
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.Colors.separator.cgColor
        addSubview(label); addSubview(line)
        setAccessibilityElement(false)
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let lh = ceil(label.intrinsicContentSize.height)
        // Clear of the traffic lights on the left (they end near 70 pt).
        label.frame = NSRect(x: 80, y: ((bounds.height - lh) / 2).rounded(), width: max(bounds.width - 160, 0), height: lh)
        line.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    /// Pins a strip to the top of `content` (over whatever is there, the window keeps its layout) and hides the system title.
    @discardableResult
    public static func install(in content: NSView, window: NSWindow, title: String) -> SQWindowTitleStrip {
        let strip = SQWindowTitleStrip(title: title)
        strip.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: content.topAnchor), strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor), strip.heightAnchor.constraint(equalToConstant: height),
        ])
        window.title = title
        window.titleVisibility = .hidden
        SQWindowLights.install(in: window, layout: .titleStrip)
        return strip
    }
}
