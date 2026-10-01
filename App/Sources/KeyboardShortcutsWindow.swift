import AppKit
import SQEditorUI

/// Keyboard Shortcuts window (Cmd+Option+K): every command with its shortcut and where it is active, with a search
/// field. Read-only: the default map is Premiere's and cannot be edited yet.
@MainActor
final class KeyboardShortcutsWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let allRows: [KeyboardListing.Row]
    private(set) var rows: [KeyboardListing.Row]

    init(map: CommandMap) {
        allRows = KeyboardListing.windowRows(map)
        rows = allRows
        super.init()
    }

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        for (id, title, w) in [("command", "Command", 270.0), ("shortcut", "Shortcut", 120), ("scope", "Active in", 130)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title; c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        search.placeholderString = "Search commands or keys"
        search.delegate = self
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let note = NSTextField(labelWithString: "Premiere Pro's default shortcuts. Editing shortcuts is not available yet.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [note, NSView(), countLabel])
        footer.distribution = .fill

        let content = NSView()
        for v in [search, scroll, footer] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Keyboard Shortcuts"
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = content
        w.contentMinSize = NSSize(width: 460, height: 300)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("SequenceStudioShortcuts")
        window = w
        updateCount()
    }

    func controlTextDidChange(_ obj: Notification) {
        rows = KeyboardListing.filter(allRows, query: search.stringValue)
        table.reloadData()
        updateCount()
    }

    private func updateCount() {
        countLabel.stringValue = rows.count == allRows.count ? "\(rows.count) shortcuts" : "\(rows.count) of \(allRows.count)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let id = tableColumn?.identifier.rawValue
        let l = NSTextField(labelWithString: id == "command" ? r.command : id == "shortcut" ? r.shortcut : r.scope)
        l.font = id == "shortcut" ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        l.lineBreakMode = .byTruncatingTail
        return l
    }
}
