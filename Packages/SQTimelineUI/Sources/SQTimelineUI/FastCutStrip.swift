import AppKit
import SQCore

/// The Fast Cut strip (docs/COMPARE.md section 12, row 3): a thin row under the timeline header, visible only in a Fast
/// Cut sequence. A "Fast Cut" badge on the left, then one quiet button per verb that used to be key-only. The owner
/// runs the command (same path as the key) and sets `enabled` from the selection.
@MainActor
public final class FastCutStrip: NSView {
    public typealias Verb = FastCutVerb
    /// The verbs, left to right (`FastCutVerb.all`).
    public static var verbs: [Verb] { FastCutVerb.all }
    public static let height: CGFloat = Theme.Row.timelineHeader

    /// A verb button was clicked.
    public var onVerb: ((EditorCommand) -> Void)?
    private var buttons: [(Verb, SQButton)] = []
    private let badge = NSTextField(labelWithString: "Fast Cut")

    public override var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        badge.font = Theme.Typography.ns(11, .medium)
        badge.textColor = Theme.Colors.accent
        badge.setAccessibilityLabel("Fast Cut verbs")
        addSubview(badge)
        for v in Self.verbs {
            let b = SQButton(title: v.title, target: self, action: #selector(clicked(_:)), style: .standard)
            b.image = Theme.symbol(v.icon, size: Theme.Typography.symbolChrome, label: v.title)
            b.imagePosition = .imageLeading
            b.sqToolTip = Tooltip.text(v.title, command: v.command) + " · " + v.help
            b.setAccessibilityLabel(v.title)
            addSubview(b)
            buttons.append((v, b))
        }
    }
    public required init?(coder: NSCoder) { fatalError("not used") }

    /// Greys the verbs that cannot run on the current selection.
    public func setEnabled(_ isEnabled: (EditorCommand) -> Bool) {
        for (v, b) in buttons { b.isEnabled = isEnabled(v.command) }
    }

    @objc func clicked(_ sender: SQButton) {
        if let v = buttons.first(where: { $0.1 === sender })?.0 { onVerb?(v.command) }
    }

    public override func layout() {
        super.layout()
        badge.sizeToFit()
        var x = Theme.Spacing.sm
        badge.frame.origin = CGPoint(x: x, y: ((bounds.height - badge.frame.height) / 2).rounded())
        x = badge.frame.maxX + Theme.Spacing.md
        for (_, b) in buttons {
            let s = b.intrinsicContentSize
            b.frame = CGRect(x: x, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            x = b.frame.maxX + Theme.Spacing.xs
        }
    }
}
