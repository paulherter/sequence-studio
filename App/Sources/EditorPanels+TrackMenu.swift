import AppKit
import SQCore
import SQEditorUI

/// A menu item that runs a closure (the menu keeps the closure alive through `representedObject`).
@MainActor
final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void
    init(_ title: String, enabled: Bool = true, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func run() { block() }
}

/// Right-click on a track header (Premiere: Add Track, Delete Track, Rename).
extension EditorPanels {
    func trackHeaderMenu(for id: Track.ID) -> NSMenu? {
        guard let track = session.activeTimeline?.track(id) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(BlockMenuItem("Add Video Track") { [weak self] in self?.session.addTrack(.video) })
        menu.addItem(BlockMenuItem("Add Audio Track") { [weak self] in self?.session.addTrack(.audio) })
        menu.addItem(BlockMenuItem("Delete Track", enabled: !track.isLocked) { [weak self] in self?.session.deleteTrack(id) })
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem("Rename…") { [weak self] in self?.renameTrack(track) })
        return menu
    }

    private func renameTrack(_ track: Track) {
        guard let window = timelineView.window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Track"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = track.name
        field.placeholderString = track.kind == .video ? "Video" : "Audio"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { self?.session.renameTrack(track.id, to: field.stringValue) } }
        }
    }
}
