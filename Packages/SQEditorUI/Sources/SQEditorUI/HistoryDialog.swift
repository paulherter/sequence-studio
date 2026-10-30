import AppKit
import SQEditorSession
import SQUIKit

/// Window > History: every undo step of the project as a list (oldest first, "Original" on top). A click goes to that
/// state; steps after the current one are dimmed and can be redone by clicking them. Shown in the shared modal shell,
/// the project behind it follows each click.
@MainActor
public final class HistoryListView: NSView {
    /// Called with the row id the user picked; the owner jumps and then calls `reload(_:)`.
    public var onPick: ((Int) -> Void)?
    public private(set) var list: HistoryList
    private let scroll = NSScrollView()
    private let documentView = FlippedView()
    private var rowViews: [HistoryRowView] = []

    /// Height of the visible list (about 11 rows).
    public static let height: CGFloat = Theme.Row.list * 11

    public init(list: HistoryList, width: CGFloat) {
        self.list = list
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = Theme.Colors.field.cgColor
        layer?.cornerRadius = Theme.Radius.well
        layer?.masksToBounds = true
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = documentView
        addSubview(scroll)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityLabel("History")
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func reload(_ new: HistoryList) {
        guard new != list else { return }
        list = new
        rebuild()
    }

    private func rebuild() {
        rowViews.forEach { $0.removeFromSuperview() }
        let w = bounds.width
        rowViews = list.rows.enumerated().map { i, row in
            let v = HistoryRowView(row: row, frame: NSRect(x: 0, y: CGFloat(i) * Theme.Row.list, width: w, height: Theme.Row.list))
            v.onClick = { [weak self] in self?.onPick?(row.id) }
            documentView.addSubview(v)
            return v
        }
        documentView.frame = NSRect(x: 0, y: 0, width: w, height: CGFloat(list.rows.count) * Theme.Row.list)
        let target = NSRect(x: 0, y: CGFloat(list.position) * Theme.Row.list, width: w, height: Theme.Row.list)
        documentView.scrollToVisible(target)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class HistoryRowView: NSView {
    private let row: HistoryList.Row
    var onClick: (() -> Void)?

    init(row: HistoryList.Row, frame: NSRect) {
        self.row = row
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.title)
        setAccessibilityValue(row.isCurrent ? "Current" : (row.isUndone ? "Undone" : ""))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { if !row.isCurrent { onClick?() } }
    override func resetCursorRects() { if !row.isCurrent { addCursorRect(bounds, cursor: .pointingHand) } }

    override func draw(_ dirtyRect: NSRect) {
        if row.isCurrent {
            Theme.Colors.selection.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: Theme.Spacing.xs, dy: 1), xRadius: Theme.Radius.inner, yRadius: Theme.Radius.inner).fill()
        }
        let font = row.isCurrent ? Theme.Typography.bodyStrong : Theme.Typography.body
        let color = row.isUndone ? Theme.Colors.label3 : (row.isCurrent ? Theme.Colors.label : Theme.Colors.label2)
        let s = NSAttributedString(string: row.title, attributes: [.font: font, .foregroundColor: color])
        let h = ceil(s.size().height)
        s.draw(in: NSRect(x: Theme.Spacing.md, y: (bounds.height - h) / 2, width: bounds.width - Theme.Spacing.md * 2, height: h))
    }
}

// `OnboardingContent` (the welcome text) lives in SQEditorSession so the Windows shell shows the same tour.

@MainActor
public enum OnboardingDialog {
    public static func makeBody(width: CGFloat) -> NSView {
        func label(_ t: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: t)
            f.font = font
            f.textColor = color
            f.isSelectable = false
            f.preferredMaxLayoutWidth = width
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: width).isActive = true
            return f
        }
        var views: [NSView] = [label(OnboardingContent.intro, Theme.Typography.body, Theme.Colors.label2)]
        for t in OnboardingContent.tips {
            let block = NSStackView(views: [label(t.title, Theme.Typography.bodyStrong, Theme.Colors.label),
                                            label(t.detail, Theme.Typography.body, Theme.Colors.label2)])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = Theme.Spacing.xxs
            views.append(block)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }
}
