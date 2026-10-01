import AppKit
import SSCore
import SSEditorUI
import SwiftUI

/// Open, save, recovery and export.
extension AppController {
    @objc func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a Sequence Studio project (.ssproj)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(at: url) }
    }

    func openProject(at url: URL) async {
        guard await confirmDiscardChanges() else { return }
        do { try await session.open(url: url); noteRecent(url) } catch {
            presentError("Could not open “\(url.lastPathComponent)”", error)
        }
    }

    @objc func saveProjectAs(_ sender: Any?) { Task { await saveDocumentAs() } }

    /// Save, or Save As for an untitled project. False when the user cancelled or saving failed.
    @discardableResult
    func saveDocument() async -> Bool {
        if session.fileURL != nil {
            do { try await session.save(); session.fileURL.map(noteRecent); return true } catch { presentError("Could not save", error); return false }
        }
        return await saveDocumentAs()
    }

    @discardableResult
    func saveDocumentAs() async -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.project.name + ".ssproj"
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        let ok: Bool = await withCheckedContinuation { c in
            panel.begin { c.resume(returning: $0 == .OK) }
        }
        guard ok, var url = panel.url else { return false }
        if url.pathExtension != "ssproj" { url.appendPathExtension("ssproj") }
        do { try await session.saveAs(to: url); noteRecent(url); return true } catch { presentError("Could not save", error); return false }
    }

    /// Asks before a document is replaced. True to go on.
    func confirmDiscardChanges() async -> Bool {
        guard session.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(session.displayName)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return await saveDocument()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let w = window { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    // MARK: Recovery

    /// At launch: a crashed session with a newer autosave is offered for recovery.
    func offerRecovery() {
        let scanner = RecoveryScanner(store: session.autosaveStore)
        guard let candidate = EditorSession.recoveryCandidates(scanner: scanner).first else { return }
        let alert = NSAlert()
        alert.messageText = "Recover “\(candidate.projectName)”?"
        alert.informativeText = "Sequence Studio did not close cleanly. An autosaved version from "
            + candidate.autosave.date.formatted(date: .abbreviated, time: .shortened) + " is available."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Discard")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .alertFirstButtonReturn {
                    Task {
                        do { try await self.session.recover(candidate, scanner: scanner) } catch {
                            self.presentError("Could not recover", error)
                        }
                    }
                } else {
                    scanner.dismiss(candidate)
                }
            }
        }
    }

    // MARK: Export

    func showExport() {
        exports.presentDialog(for: session, on: window)
    }
}
