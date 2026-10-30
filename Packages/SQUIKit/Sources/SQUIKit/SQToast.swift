import AppKit

/// Version 9 `.toast`: a short message that floats at the bottom center of the window, with an optional ghost "Undo".
/// 40 pt tall, 16 pt leading and 8 pt trailing padding, 12 pt text, the overlay surface and edge. It fades in, stays
/// 4.2 s and fades out; a new toast replaces the one on screen. Lives in SQUIKit (not SQEditorUI) so the inspector
/// package can raise one without a dependency on the layer above it.
@MainActor
public final class SQToast: NSView {
    private static let height: CGFloat = 40
    private static let bottom: CGFloat = 44
    private static let lifetime: TimeInterval = 4.2

    private let label = NSTextField(labelWithString: "")
    private var undoButton: SQButton?
    private var undoHandler: (() -> Void)?
    private var timer: Timer?

    /// The toast now on a window (one per window).
    private static var current: [ObjectIdentifier: SQToast] = [:]

    /// Shows `text` over the content view of `view`'s window. `undo`, when given, adds the Undo button.
    @discardableResult
    public static func show(_ text: String, undo: (() -> Void)? = nil, in view: NSView?) -> SQToast? {
        guard let host = view?.window?.contentView else { return nil }
        let key = ObjectIdentifier(host)
        current[key]?.dismiss(animated: false)
        let t = SQToast(text: text, undo: undo)
        current[key] = t
        host.addSubview(t)
        t.frame = NSRect(origin: .zero, size: t.fittingSize(maxWidth: host.bounds.width * 0.7))
        t.frame.origin = NSPoint(x: ((host.bounds.width - t.frame.width) / 2).rounded(),
                                 y: host.isFlipped ? host.bounds.height - Self.bottom - t.frame.height : Self.bottom)
        t.autoresizingMask = [.minXMargin, .maxXMargin, host.isFlipped ? .minYMargin : .maxYMargin]
        t.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; t.animator().alphaValue = 1 }
        t.timer = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak t] _ in
            MainActor.assumeIsolated { t?.dismiss(animated: true) }
        }
        return t
    }

    /// The message (for tests and accessibility).
    public var text: String { label.stringValue }
    public var hasUndo: Bool { undoButton != nil }

    private init(text: String, undo: (() -> Void)?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.overlay
        layer?.masksToBounds = false
        label.stringValue = text
        label.font = Theme.Typography.shell
        label.textColor = Theme.Colors.label
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityRole(.staticText)
        addSubview(label)
        if let undo {
            undoHandler = undo
            let b = SQButton(title: "Undo", target: self, action: #selector(undoPressed), style: .standard)
            addSubview(b)
            undoButton = b
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
    }
    public required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.Colors.overlay.cgColor
            layer?.borderColor = Theme.Colors.overlayEdge.cgColor
            layer?.borderWidth = 0.5
        }
        layer?.shadowColor = Theme.black(0.5).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    private func fittingSize(maxWidth: CGFloat) -> NSSize {
        let text = label.intrinsicContentSize.width
        let b = undoButton?.intrinsicContentSize.width ?? 0
        let gap = b > 0 ? Theme.Spacing.md : 0
        let w = Theme.Spacing.lg + text + gap + b + Theme.Spacing.sm
        return NSSize(width: min(w, max(maxWidth, 160)), height: Self.height)
    }

    public override func layout() {
        super.layout()
        var right = bounds.width - Theme.Spacing.sm
        if let b = undoButton {
            let s = b.intrinsicContentSize
            b.frame = NSRect(x: right - s.width, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
            right = b.frame.minX - Theme.Spacing.md
        }
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: Theme.Spacing.lg, y: ((bounds.height - lh) / 2).rounded(), width: max(right - Theme.Spacing.lg, 0), height: lh)
    }

    @objc private func undoPressed() {
        let h = undoHandler
        dismiss(animated: true)
        h?()
    }

    private func dismiss(animated: Bool) {
        timer?.invalidate(); timer = nil
        if let host = superview, Self.current[ObjectIdentifier(host)] === self { Self.current[ObjectIdentifier(host)] = nil }
        guard animated else { removeFromSuperview(); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.16; animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperview() } })
    }
}
