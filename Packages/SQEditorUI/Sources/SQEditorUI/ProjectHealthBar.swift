import AppKit
import SQCore
import SQUIKit

/// The Library's project health line: "312 in folder · 4 outside · 1 missing" with a Fix menu (Collect, Reconnect).
/// Shown only while something needs attention; when everything is in place the line is gone. The counts come from
/// `ProjectHealth` (the model keeps them current); the host runs the actions.
@MainActor
public final class ProjectHealthBar: NSView {
    public enum Action: Sendable { case collect, reconnect, showMissing }

    /// Height of the line while it shows.
    public static let height: CGFloat = 24

    public var onAction: ((Action) -> Void)?
    public private(set) var health = ProjectHealth()

    private let row = NSStackView()
    private let fix = SQButton(title: "Fix…", target: nil, action: nil)

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Theme.Spacing.md
        row.translatesAutoresizingMaskIntoConstraints = false
        fix.target = self
        fix.action = #selector(fixPressed)
        fix.boxHeight = Self.height - Theme.Spacing.xs
        fix.sqToolTip = "Collect files into the project folder or reconnect missing media"
        fix.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row); addSubview(fix)
        let g = Theme.Spacing.sm
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: g),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: fix.leadingAnchor, constant: -Theme.Spacing.sm),
            fix.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -g),
            fix.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Project health")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Updates the counts; true when the line has something to show.
    @discardableResult
    public func update(_ h: ProjectHealth) -> Bool {
        health = h
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        guard !h.isHealthy else { return false }
        row.addArrangedSubview(Segment(color: Theme.Colors.green, text: "\(h.inFolder) in folder", onClick: nil))
        if h.outside > 0 {
            row.addArrangedSubview(Segment(color: Theme.Colors.warning, text: "\(h.outside) outside",
                                           onClick: { [weak self] in self?.fixPressed() }))
        }
        if h.missing > 0 {
            row.addArrangedSubview(Segment(color: Theme.Colors.red, text: "\(h.missing) missing",
                                           onClick: { [weak self] in self?.onAction?(.showMissing) }))
        }
        return true
    }

    /// The Fix menu's rows for these counts.
    static func menuItems(for h: ProjectHealth, run: @escaping @MainActor (Action) -> Void) -> [SQMenuItem] {
        var rows: [SQMenuItem] = []
        if h.outside > 0 {
            rows.append(SQMenuItem(title: SQL10n.plural(h.outside, one: "Collect %@ file into project", other: "Collect %@ files into project"),
                                   action: { run(.collect) }))
        }
        if h.missing > 0 {
            rows.append(SQMenuItem(title: SQL10n.plural(h.missing, one: "Reconnect %@ missing file…", other: "Reconnect %@ missing files…"),
                                   action: { run(.reconnect) }))
            rows.append(SQMenuItem(title: "Show missing files", action: { run(.showMissing) }))
        }
        return rows
    }

    @objc private func fixPressed() {
        let items = Self.menuItems(for: health) { [weak self] in self?.onAction?($0) }
        guard !items.isEmpty else { return }
        SQContextMenu.popUp(items: items, belowTrailing: fix)
    }

    /// A colored dot and a count; clickable when `onClick` is set.
    private final class Segment: NSView {
        private let onClick: (() -> Void)?

        init(color: NSColor, text: String, onClick: (() -> Void)?) {
            self.onClick = onClick
            super.init(frame: .zero)
            let dot = NSTextField(labelWithString: "●")
            dot.font = Theme.Typography.caption
            dot.textColor = color
            let label = NSTextField(labelWithString: SQL10n.string(text))
            label.font = Theme.Typography.caption
            label.textColor = Theme.Colors.label2
            for v in [dot, label] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: leadingAnchor),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Theme.Spacing.xs),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.topAnchor.constraint(equalTo: topAnchor), label.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            setAccessibilityElement(true)
            setAccessibilityLabel(text)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) {
            if let onClick { onClick() } else { super.mouseDown(with: event) }
        }
        override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    }
}
