import AppKit

/// Unit after a number field in a dialog ("ms", "dB", "%", "frames"; board `.unit`): 12 pt `label3`, drawn from its own left
/// edge with no cell padding, so the gap to the field's outline is exactly the layout gap. Not an accessibility element
/// (the field announces its unit).
@MainActor
public final class SQUnitLabel: NSView {
    public var text: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Theme.Typography.body, .foregroundColor: Theme.Colors.label3]
    }

    public init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override func isAccessibilityElement() -> Bool { false }

    /// Width of `text` in the unit font.
    public static func width(of text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: Theme.Typography.body]).width)
    }

    public override var intrinsicContentSize: NSSize {
        let s = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(s.width), height: ceil(s.height))
    }

    public override func draw(_ dirtyRect: NSRect) {
        let s = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: 0, y: ((bounds.height - s.height) / 2).rounded()), withAttributes: attributes)
    }
}
