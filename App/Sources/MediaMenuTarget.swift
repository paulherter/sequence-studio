import AppKit
import SQCore
import SQEditorUI

/// File > Media Management: this project's choice for outside media, library copies and folder watching. The check marks
/// show the effective value (the project's own choice, else the app default from Settings > Media).
@MainActor
final class MediaMenuTarget: NSObject, NSMenuItemValidation {
    weak var owner: AppController?
    private let modeItems: [(OutsideMediaMode, NSMenuItem)]
    private let libraryItem = NSMenuItem(title: SQL10n.string("Copy Library Items Into Project"), action: nil, keyEquivalent: "")
    private let watchItem = NSMenuItem(title: SQL10n.string("Watch Project Folder"), action: nil, keyEquivalent: "")
    /// The submenu entries in order (a nil entry is a separator).
    var items: [NSMenuItem] { modeItems.map(\.1) + [.separator(), libraryItem, watchItem] }

    override init() {
        modeItems = OutsideMediaMode.allCases.map { mode in
            let title: String
            switch mode {
            case .ask: title = "Ask About Outside Files"
            case .copy: title = "Copy Outside Files Into Project"
            case .move: title = "Move Outside Files Into Project"
            case .leave: title = "Leave Outside Files Where They Are"
            }
            return (mode, NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        super.init()
        for (mode, item) in modeItems {
            item.target = self; item.action = #selector(setMode(_:)); item.representedObject = mode.rawValue
        }
        libraryItem.target = self; libraryItem.action = #selector(toggleLibrary(_:))
        watchItem.target = self; watchItem.action = #selector(toggleWatch(_:))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let owner else { return false }
        let project = owner.session.project, url = owner.session.fileURL, d = MediaSettings.defaults
        let current = MediaManagement.outsideMode(of: project, defaults: d)
        for (mode, item) in modeItems { item.state = mode == current ? .on : .off }
        libraryItem.state = (project.mediaPolicy?.copyLibraryItems ?? d.copyLibraryItems) ? .on : .off
        watchItem.state = (project.mediaPolicy?.watchFolder ?? false) ? .on : .off
        let inFolder = MediaManagement.projectFolder(forProjectAt: url) != nil
        return item === libraryItem || item === watchItem ? inFolder : true
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let owner, let raw = sender.representedObject as? String, let mode = OutsideMediaMode(rawValue: raw) else { return }
        change(owner) { $0.outside = mode }
        let text: String
        switch mode {
        case .ask: text = "Files from outside the project folder: ask."
        case .copy: text = "Files from outside the project folder: copy into project."
        case .move: text = "Files from outside the project folder: move into project."
        case .leave: text = "Files from outside the project folder: leave where it is."
        }
        owner.shell.statusBar.flash(text, seconds: 5)
    }

    @objc private func toggleLibrary(_ sender: NSMenuItem) {
        guard let owner else { return }
        let on = sender.state != .on
        change(owner) { $0.copyLibraryItems = on }
    }

    @objc private func toggleWatch(_ sender: NSMenuItem) {
        guard let owner else { return }
        let on = sender.state != .on
        change(owner) { $0.watchFolder = on }
        owner.mediaPlacement.restartWatching()
    }

    private func change(_ owner: AppController, _ edit: @escaping (inout MediaPolicy) -> Void) {
        owner.session.perform("Change Media Setting") { p in
            var policy = p.mediaPolicy ?? MediaPolicy()
            edit(&policy)
            p.mediaPolicy = policy.isEmpty ? nil : policy
        }
    }
}
