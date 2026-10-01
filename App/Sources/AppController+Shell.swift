import AppKit
import SQCore
import SQEditorUI

/// App-level commands (project handling, settings windows) and the rules that enable or disable menu items.
extension AppController {
    static func isShellCommand(_ c: EditorCommand) -> Bool { CommandSupport.isShellCommand(c) }

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
        case .maximizeActivePanel: if let p = focusedPanel { toggleMaximize(p) }
        case .resetLayout: resetLayout(nil)
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
        case .enableClip, .duplicate, .moveSelectionUp, .moveSelectionDown: return !session.selection.isEmpty
        case .setToFrameSize: return session.commandClipsForMenu(kind: .video).contains { session.selection.contains($0.id) }
        case .link: return session.linkMenuState.enabled
        case .speedDuration: return session.speedDialogModel() != nil
        case .audioGain: return !session.audioGainTargets.isEmpty
        case .audioGainDown, .audioGainUp, .audioGainDown6, .audioGainUp6, .matchLoudness, .removeSilences,
             .tagDialogue, .tagMusic, .tagSFX: return !session.selectedAudioClips.isEmpty
        case .autoDuck: return !session.musicDuckTargets.isEmpty
        case .paste, .pasteInsert: return session.clipboard != nil
        case .extendEdit, .toggleTrimType, .trimBackward, .trimForward, .trimBackward5, .trimForward5:
            return panels?.timelineView.interaction.edgeSelection != nil
        case .easyEase, .easeIn, .easeOut, .toggleHoldInterpolation: return !(panels?.effectModel.selection.isEmpty ?? true)
        case .toggleTimeRemapping: return session.canToggleTimeRemapping
        case .removeTimeRemapping: return session.canRemoveTimeRemapping
        case .delete, .rippleDelete: return !session.selection.isEmpty || !session.captionSelection.isEmpty || session.selectedTransition != nil
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

// MARK: Sequence match prompt

extension AppController {
    /// "This clip does not match the sequence settings": Change Sequence Settings (adopt) or Keep Existing Settings.
    func askChangeSequenceFormat(_ current: SequenceFormat, _ proposed: SequenceFormat) -> Bool {
        func text(_ f: SequenceFormat) -> String {
            let fps = Double(f.frameDuration.timescale) / Double(f.frameDuration.value)
            return "\(f.width)×\(f.height), \(String(format: "%.5g", fps)) fps"
        }
        let alert = NSAlert()
        alert.messageText = "This clip does not match the sequence settings."
        alert.informativeText = "Sequence: \(text(current)). Clip: \(text(proposed)). Change the sequence settings to match the clip?"
        alert.addButton(withTitle: "Change Sequence Settings")
        alert.addButton(withTitle: "Keep Existing Settings")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: Panels

extension AppController {
    /// Panel group under the pointer (Premiere: ` maximises "the panel under the mouse"); nil outside the window.
    func panelUnderMouse() -> PanelID? {
        guard let window, let content = window.contentView, panels != nil else { return nil }
        let p = window.mouseLocationOutsideOfEventStream
        guard content.frame.contains(p) else { return nil }
        return panels.panel(containing: content.hitTest(p))
    }

    func toggleMaximize(_ p: PanelID) {
        maximizedPanel = maximizedPanel == p ? nil : p
        focusedPanel = p
        applyWorkspace()
    }

    /// Right-click menu of a panel tab.
    func tabContextMenu(for p: PanelID) -> NSMenu {
        let menu = NSMenu(title: EditorCommand.panelTitle(p))
        let close = NSMenuItem(title: "Close Panel", action: #selector(closePanelFromTab(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = p
        menu.addItem(close)
        let max = NSMenuItem(title: maximizedPanel == p ? "Restore Panel Size" : "Maximize Panel",
                             action: #selector(maximizePanelFromTab(_:)), keyEquivalent: "`")
        max.keyEquivalentModifierMask = []
        max.target = self
        max.representedObject = p
        menu.addItem(max)
        return menu
    }

    @objc func closePanelFromTab(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? PanelID else { return }
        if maximizedPanel != nil { maximizedPanel = nil }
        mutateWorkspace { $0.hide(p) }
        if focusedPanel == p { focusedPanel = store.current.isVisible(.timeline) ? .timeline : nil }
    }

    @objc func maximizePanelFromTab(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? PanelID else { return }
        toggleMaximize(p)
    }
}

extension AppController: NSMenuDelegate {
    /// Open Recent is rebuilt every time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs.filter(ProjectFile.isProjectURL)
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
