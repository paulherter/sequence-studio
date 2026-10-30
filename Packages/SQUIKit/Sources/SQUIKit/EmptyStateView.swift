import AppKit
import SwiftUI

/// The one empty state (INTERACTION-AUDIT §10): what is missing (title, body `label2`) and how to get it (hint, caption
/// `label3`, may name a key, e.g. "Import media (⌘I) or drag files here"). Optional icon above. Centered in its
/// bounds; transparent, so it sits on the panel's own surface. Not interactive: clicks and drops go to the view below,
/// except on the optional action button (v9 `.cempty .btn`, e.g. "Import…").
public final class EmptyStateView: NSView {
    public private(set) var actionButton: SQButton?
    private var actionHandler: (() -> Void)?

    /// One small button under the hint; nil removes it.
    public func setAction(title: String?, handler: (() -> Void)? = nil) {
        actionHandler = handler
        guard let title, handler != nil else { actionButton?.isHidden = true; return }
        let b = actionButton ?? {
            let b = SQButton(title: title, target: self, action: #selector(runAction), style: .standard)
            stack.addArrangedSubview(b)
            stack.setCustomSpacing(Theme.Spacing.md, after: hintLabel)
            actionButton = b
            return b
        }()
        b.title = title
        b.isHidden = false
    }
    @objc private func runAction() { actionHandler?() }

    public let titleLabel = NSTextField(labelWithString: "")
    public let hintLabel = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    private let stack: NSStackView

    public var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue; setAccessibilityLabel(newValue) }
    }
    public var hint: String? {
        didSet { hintLabel.stringValue = hint ?? ""; hintLabel.isHidden = (hint ?? "").isEmpty }
    }
    public var symbol: SQIcon? {
        didSet { updateSymbol() }
    }

    public init(title: String, hint: String? = nil, symbol: SQIcon? = nil) {
        stack = NSStackView()
        super.init(frame: .zero)
        // One empty state everywhere: heading 15 semibold in `label`, hint body in `label2`.
        titleLabel.font = Theme.Typography.emptyHeading
        titleLabel.textColor = Theme.Colors.label
        hintLabel.font = Theme.Typography.body
        hintLabel.textColor = Theme.Colors.label2
        for l in [titleLabel, hintLabel] {
            l.alignment = .center
            l.lineBreakMode = .byWordWrapping
            l.maximumNumberOfLines = 3
            l.cell?.wraps = true
        }
        symbolView.contentTintColor = Theme.Colors.label3
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Theme.Spacing.xs
        stack.addArrangedSubview(symbolView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(hintLabel)
        stack.setCustomSpacing(Theme.Spacing.sm, after: symbolView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Theme.Spacing.lg),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Spacing.lg),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        self.title = title
        self.hint = hint
        hintLabel.stringValue = hint ?? ""
        hintLabel.isHidden = (hint ?? "").isEmpty
        self.symbol = symbol
        updateSymbol()
    }
    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    private var mascotView: SQMascotView?
    /// Pip above the title instead of the icon (a mascot place; nil or a switched-off place shows the icon).
    public var mascot: SQMascotPlace? {
        didSet {
            guard mascot != oldValue else { return }
            if let old = mascotView { stack.removeArrangedSubview(old); old.removeFromSuperview(); mascotView = nil }
            if let v = mascot?.makeView() {
                stack.insertArrangedSubview(v, at: 0)
                stack.setCustomSpacing(Theme.Spacing.sm, after: v)
                mascotView = v
            }
            updateSymbol()
        }
    }

    private var pipAwake = false

    /// M3: a drag is over the empty area at `windowPoint` (window coordinates). The first call inside wakes Pip, who then
    /// follows the point.
    public func mascotDragMoved(windowPoint: NSPoint) {
        guard let pip = mascotView, !isHidden else { return }
        if !pipAwake {
            guard bounds.contains(convert(windowPoint, from: nil)), pip.dragBegan() else { return }
            pipAwake = true
        }
        pip.dragMoved(to: pip.convert(windowPoint, from: nil))
    }

    /// The drag left or ended; `dropped` makes Pip hop away.
    public func mascotDragEnded(dropped: Bool) {
        guard pipAwake else { return }
        pipAwake = false
        mascotView?.dragEnded(dropped: dropped)
    }

    private func updateSymbol() {
        symbolView.image = symbol.flatMap { Theme.symbol($0, size: Theme.Typography.displaySize) }
        symbolView.isHidden = symbolView.image == nil || mascotView != nil
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let b = actionButton, !b.isHidden, let sv = superview else { return nil }
        return b.frame.contains(b.superview?.convert(point, from: sv) ?? .zero) ? b : nil
    }

    public override func layout() {
        super.layout()
        let w = max(bounds.width - 2 * Theme.Spacing.lg, 0)
        titleLabel.preferredMaxLayoutWidth = w
        hintLabel.preferredMaxLayoutWidth = w
    }
}

/// SwiftUI twin of `EmptyStateView` for the shell (same type, colors and spacing).
public struct EmptyStateLabel: SwiftUI.View {
    public let title: String
    public let hint: String?

    public init(title: String, hint: String? = nil) { self.title = title; self.hint = hint }

    public var body: some SwiftUI.View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(title).font(Theme.Typography.emptyHeadingFont).foregroundStyle(Color(nsColor: Theme.Colors.label))
            if let hint, !hint.isEmpty {
                Text(hint).font(Theme.Typography.bodyFont).foregroundStyle(Color(nsColor: Theme.Colors.label2))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
