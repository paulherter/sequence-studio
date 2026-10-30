import AppKit
import SQCore
import SQEditorUI

/// Settings > Editing, lower group: every effect and transition kind with a user default, in three grouped lists (Effects,
/// Video Transitions, Audio Transitions), each entry with "Restore Factory". An empty group says how to fill it.
@MainActor
final class EffectDefaultsSettingsView: NSView {
    private typealias Entry = EffectDefaults.Entry
    private typealias Group = EffectDefaults.Group

    private static let help = EffectDefaults.settingsHelp

    private let library: EffectDefaultsLibrary
    private var lists: [Group: NSStackView] = [:]
    private var entries: [Group: [Entry]] = [:]
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(library: EffectDefaultsLibrary = .shared) {
        self.library = library
        super.init(frame: .zero)
        let rows = Group.allCases.map { g -> NSView in
            let list = NSStackView()
            list.orientation = .vertical; list.alignment = .width; list.spacing = 0
            list.setAccessibilityLabel("Your \(g.title.lowercased()) defaults")
            lists[g] = list
            let box = Self.box(list)
            return SQFormRow.row(g.title, box, help: g == .audioTransitions ? Self.help : nil)
        }
        let page = SQFormRow.page(rows)
        addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: topAnchor), page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor), page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observer = NotificationCenter.default.addObserver(forName: EffectDefaultsLibrary.didChange, object: library, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// The grouped list container (`box`): quiet fill, control radius, as wide as the help text.
    static func box(_ content: NSView) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = Theme.Colors.fill2.cgColor
        box.layer?.cornerRadius = Theme.Radius.control
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor), content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor), content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            box.widthAnchor.constraint(equalToConstant: SQFormRow.helpMaxWidth),
        ])
        return box
    }

    func reload() {
        let d = library.defaults
        entries = Dictionary(uniqueKeysWithValues: Group.allCases.map { ($0, d.entries(in: $0)) })
        for g in Group.allCases {
            guard let list = lists[g] else { continue }
            list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
            let items = entries[g] ?? []
            if items.isEmpty { list.addArrangedSubview(emptyRow()) }
            for (i, e) in items.enumerated() {
                let title = NSTextField(labelWithString: e.title)
                title.font = Theme.Typography.body; title.textColor = Theme.Colors.label
                title.lineBreakMode = .byTruncatingTail
                title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                title.setContentHuggingPriority(.init(1), for: .horizontal)
                let b = SQButton(title: "Restore Factory", target: self, action: #selector(restore(_:)), style: .standard)
                b.tag = g.rawValue * 1000 + i
                b.setAccessibilityLabel("Restore factory default of \(e.title)")
                list.addArrangedSubview(Self.line([title, b]))
            }
        }
    }

    private func emptyRow() -> NSView {
        let l = NSTextField(wrappingLabelWithString: EffectDefaults.emptyGroupText)
        l.font = Theme.Typography.body; l.textColor = Theme.Colors.label3
        l.preferredMaxLayoutWidth = SQFormRow.helpMaxWidth - Theme.Spacing.md * 2
        return Self.line([l])
    }

    /// One list line: 28 high, 12 inside the box edge.
    private static func line(_ views: [NSView]) -> NSView {
        let row = NSStackView(views: views)
        row.alignment = .centerY; row.spacing = Theme.Spacing.sm
        row.edgeInsets = NSEdgeInsets(top: .zero, left: Theme.Spacing.md, bottom: .zero, right: Theme.Spacing.md)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: SQFormRow.lineHeight).isActive = true
        return row
    }

    @objc private func restore(_ sender: NSControl) {
        guard let g = Group(rawValue: sender.tag / 1000), let list = entries[g], list.indices.contains(sender.tag % 1000) else { return }
        let e = list[sender.tag % 1000]
        library.update { $0.remove(e) }
    }
}
