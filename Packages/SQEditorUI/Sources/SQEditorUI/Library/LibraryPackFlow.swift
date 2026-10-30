import SQUIKit
import AppKit
import UniformTypeIdentifiers
import SQLibrary
import SQDrawLibrary

/// The two `.sqpack` flows with SQ dialogs: "Export as Pack…" (naming dialog, then the file panel) and import (read and
/// check the file, ask rename / replace / skip only when names clash, then add). File choice uses the open/save panel the
/// app already uses elsewhere.
@MainActor
public enum LibraryPackFlow {
    static let authorKey = "sq.pack.author"

    public static var packType: UTType? { UTType(filenameExtension: SQPackFormat.fileExtension) }

    public static func isPack(_ url: URL) -> Bool { url.pathExtension.lowercased() == SQPackFormat.fileExtension }

    // MARK: Export

    /// Asks for name, author and version, then where to save, then writes the pack of the presets `ids`.
    public static func export(ids: [UUID], suggestedName: String, model: LibraryPanelModel, window: NSWindow?) {
        guard !ids.isEmpty else { return }
        let dialog = SQDialog()
        dialog.messageText = "Export as Pack"
        dialog.informativeText = ids.count == 1 ? "One preset goes into the pack." : "\(ids.count) presets go into the pack."
        let name = SQDialog.makeField(suggestedName, placeholder: "Pulse Presets Bundle 3.0", width: nil)
        let author = SQDialog.makeField(UserDefaults.standard.string(forKey: authorKey) ?? "", placeholder: "Your name", width: nil)
        let version = SQDialog.makeField("1.0", width: nil)
        name.setAccessibilityLabel("Pack name"); author.setAccessibilityLabel("Author"); version.setAccessibilityLabel("Version")
        dialog.accessoryView = SQDialogForm(rows: [SQDialog.formRow("Name", name), SQDialog.formRow("Author", author),
                                                   SQDialog.formRow("Version", version)])
        dialog.initialFirstResponder = name
        dialog.addButton("Export…", role: .default)
        dialog.addButton("Cancel", role: .cancel)
        let finish: @MainActor (SQDialog.Response) -> Void = { r in
            guard r == .first else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let by = author.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(by, forKey: authorKey)
            let manifest = SQPackManifest(name: title, author: by, version: version.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            do { try SQPackFormat.validateName(title) } catch {
                notice("Choose another name", "A pack name needs 1 to 120 characters and no slashes or colons.", window: window); return
            }
            save(ids: ids, manifest: manifest, model: model, window: window)
        }
        if let window { dialog.beginSheetModal(for: window, completion: finish) } else { finish(dialog.runModal()) }
    }

    private static func save(ids: [UUID], manifest: SQPackManifest, model: LibraryPanelModel, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SQPackFormat.suggestedFileName(for: manifest.name)
        if let type = packType { panel.allowedContentTypes = [type] }
        let done: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await model.exportPack(ids: ids, manifest: manifest, to: url) } catch {
                    notice("The pack could not be saved", message(for: error), window: window)
                }
            }
        }
        if let window { panel.beginSheetModal(for: window) { r in MainActor.assumeIsolated { done(r) } } } else { done(panel.runModal()) }
    }

    // MARK: Import

    /// Choose `.sqpack` files, then import each.
    public static func chooseAndImport(model: LibraryPanelModel, window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let type = packType { panel.allowedContentTypes = [type] }
        let done: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            importFiles(panel.urls, model: model, window: window)
        }
        if let window { panel.beginSheetModal(for: window) { r in MainActor.assumeIsolated { done(r) } } } else { done(panel.runModal()) }
    }

    /// Imports the `.sqpack` files among `urls`, one after the other (a dialog may be open between them).
    public static func importFiles(_ urls: [URL], model: LibraryPanelModel, window: NSWindow?) {
        let packs = urls.filter(isPack)
        guard !packs.isEmpty else { return }
        Task { @MainActor in
            for url in packs { await importFile(url, model: model, window: window) }
        }
    }

    private static func importFile(_ url: URL, model: LibraryPanelModel, window: NSWindow?) async {
        let read: SQPackReadResult
        do { read = try await model.readPack(at: url) } catch {
            notice(SQL10n.format("“%@” could not be imported", url.lastPathComponent), message(for: error), window: window)
            return
        }
        let clashes = await model.packConflicts(read.pack)
        var policy = SQPackConflict.rename
        if !clashes.isEmpty {
            guard let chosen = await askConflict(packName: read.pack.manifest.name, count: clashes.count, window: window) else { return }
            policy = chosen
        }
        do {
            let s = try await model.importPack(read, conflict: policy)
            if s.unreadable > 0 {
                notice(SQL10n.format("“%@” was imported", s.packName),
                       SQL10n.plural(s.unreadable, one: "%@ preset in it needs a newer version of Sequence Studio and was left out.", other: "%@ presets in it need a newer version of Sequence Studio and were left out."),
                       window: window)
            }
        } catch {
            notice(SQL10n.format("“%@” could not be imported", url.lastPathComponent), message(for: error), window: window)
        }
    }

    private static func askConflict(packName: String, count: Int, window: NSWindow?) async -> SQPackConflict? {
        await withCheckedContinuation { cont in
            let d = SQDialog()
            d.messageText = SQL10n.format("“%@” is already in the Library", packName)
            d.informativeText = SQL10n.plural(count, one: "%@ preset has the same name as one you already imported from this pack.", other: "%@ presets have the same name as one you already imported from this pack.")
            d.width = SQModal.Size.s.width
            d.addButton("Keep Both", role: .default)
            d.addButton("Replace")
            d.addButton("Skip Existing")
            d.addButton("Cancel", role: .cancel)
            let finish: @MainActor (SQDialog.Response) -> Void = { r in
                switch r {
                case .first: cont.resume(returning: .rename)
                case .second: cont.resume(returning: .replace)
                case .third: cont.resume(returning: .skip)
                default: cont.resume(returning: nil)
                }
            }
            if let window { d.beginSheetModal(for: window, completion: finish) } else { finish(d.runModal()) }
        }
    }

    // MARK: Messages

    static func message(for error: any Error) -> String { LibraryLabels.packError(error) }

    private static func notice(_ title: String, _ text: String, window: NSWindow?) {
        let d = SQDialog()
        d.messageText = title
        d.informativeText = text
        d.addButton("OK", role: .default)
        if let window { d.beginSheetModal(for: window) } else { d.runModal() }
    }
}
