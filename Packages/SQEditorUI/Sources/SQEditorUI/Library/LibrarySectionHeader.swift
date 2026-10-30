import AppKit
import SQLibrary

/// Collapsible section header of a Library folder with subfolders ("All", then one per subfolder): chevron, name, item count.
/// A click anywhere on it collapses or expands the section; nested subfolders are indented one step per level.
final class LibrarySectionHeaderView: NSView {
    static let height: CGFloat = Theme.Row.sectionHeader
    static let indent: CGFloat = Theme.Spacing.md

    private let glyph = DisclosureGlyph(isOpen: true)
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    var onToggle: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = Theme.Typography.body
        title.textColor = Theme.Colors.label
        title.lineBreakMode = .byTruncatingTail
        count.font = Theme.Typography.caption
        count.textColor = Theme.Colors.label3
        count.setContentHuggingPriority(.required, for: .horizontal)
        for v in [glyph, title, count] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        leading = glyph.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            leading,
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 12),
            glyph.heightAnchor.constraint(equalToConstant: 12),
            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Theme.Spacing.xs),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: Theme.Spacing.sm),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Spacing.sm),
        ])
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ group: LibraryGroup) {
        glyph.isOpen = !group.isCollapsed
        title.stringValue = group.title
        count.stringValue = "\(group.totalCount)"
        leading.constant = Theme.Spacing.xs + CGFloat(group.depth) * Self.indent
        setAccessibilityLabel("\(group.title), \(group.totalCount) items, \(group.isCollapsed ? "collapsed" : "expanded")")
    }

    override func mouseDown(with event: NSEvent) { onToggle?() }
}

/// NSCollectionView supplementary view wrapping the header (grid).
final class LibrarySectionHeaderItem: NSView, NSCollectionViewElement {
    let header = LibrarySectionHeaderView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
