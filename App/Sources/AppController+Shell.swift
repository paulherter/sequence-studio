import AppKit
import SSCore
import SSEditorUI

/// App-level commands (project handling, settings windows) and the rules that enable or disable menu items.
extension AppController {
    static func isShellCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .newProject, .openProject, .saveAs, .revert, .sequenceSettings, .setToFrameSize, .keyboardShortcuts, .preferences: true
        default: false
        }
    }

    /// True when `c` was one of the shell commands and has been handled.
    func executeShellCommand(_ c: EditorCommand) -> Bool {
        switch c {
        case .newProject: newProject(nil)
        case .openProject: openProject(nil)
        case .saveAs: saveProjectAs(nil)
        case .revert: revertProject(nil)
        case .sequenceSettings: showSequenceSettings(nil)
        case .setToFrameSize:
            if !session.setToFrameSize() { shell.statusBar.flash("Select clips to scale to the frame size.", seconds: 3) }
        case .keyboardShortcuts: shortcutsWindow.show()
        case .preferences: showSettings(nil)
        default: return false
        }
        return true
    }

    /// Enabled state of a command's menu item. Unwired commands are hidden by `MenuBuilder`; this disables the ones that
    /// cannot do anything right now (nothing selected, no In/Out range, no saved file).
    func commandEnabled(_ c: EditorCommand) -> Bool {
        guard Self.isSupported(c) else { return false }
        switch c {
        case .revert: return session.fileURL != nil && session.isDirty
        case .lift, .extract, .goToIn, .goToOut, .clearInOut: return session.activeTimeline?.inOut != nil
        case .insert, .overwrite: return !(panels?.projectView.selectedMediaIDs.isEmpty ?? true)
        case .setToFrameSize: return !session.selection.isEmpty
        case .delete, .rippleDelete: return !session.selection.isEmpty || !session.captionSelection.isEmpty
        case .sequenceSettings: return session.activeTimeline != nil
        default: return true
        }
    }

    // MARK: Project

    @objc func newProject(_ sender: Any?) {
        Task {
            guard await confirmDiscardChanges() else { return }
            session.newProject()
        }
    }

    @objc func revertProject(_ sender: Any?) {
        guard let url = session.fileURL, session.isDirty else { return }
        let alert = NSAlert()
        alert.messageText = "Revert to the last saved version of “\(session.displayName)”?"
        alert.informativeText = "Your changes since the last save will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                Task {
                    do { try await self.session.open(url: url) } catch { self.presentError("Could not revert", error) }
                }
            }
        }
    }

    /// Remembers a project in File > Open Recent (and the Dock menu).
    func noteRecent(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            presentError("“\(url.lastPathComponent)” is no longer there", CocoaError(.fileNoSuchFile))
            return
        }
        Task { await openProject(at: url) }
    }

    @objc func clearRecents(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(nil) }
}

extension AppController: NSMenuDelegate {
    /// Open Recent is rebuilt every time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs.filter { $0.pathExtension == "ssproj" }
        for url in urls {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }
}
