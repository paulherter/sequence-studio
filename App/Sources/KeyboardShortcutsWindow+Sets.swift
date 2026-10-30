import AppKit
import SQCore
import SQEditorUI
import UniformTypeIdentifiers

/// Templates and import in the Keyboard Shortcuts window (docs/KEYMAP.md "Templates and import"): the switcher menu at the top
/// (our set, Classic NLE, Final Cut style, the user's own sets), import of a Final Cut `.commandset` or our own `.sqkeys`,
/// save / rename / delete / export of own sets. All dialogs are SQ's own; only the file pickers are the system's.
extension KeyboardShortcutsWindowController {
    // MARK: Switcher menu

    func templateMenuItems() -> [SQMenuItem] {
        var items: [SQMenuItem] = [.header("Templates")]
        for p in KeymapPreset.allCases {
            items.append(SQMenuItem(title: p.title, isChecked: config.activeSet == nil && config.preset == p) { [weak self] in self?.chooseTemplate(.preset(p)) })
        }
        if !config.customSets.isEmpty {
            items.append(.separator)
            items.append(.header("My Sets"))
            for s in config.customSets {
                items.append(SQMenuItem(title: s.name, isChecked: config.activeSetID == s.id) { [weak self] in self?.chooseTemplate(.custom(s.id)) })
            }
        }
        items.append(.separator)
        items.append(SQMenuItem(title: "Import Shortcuts…") { [weak self] in self?.importShortcuts() })
        items.append(SQMenuItem(title: "Save Current as My Set…") { [weak self] in self?.saveCurrentAsSet() })
        items.append(SQMenuItem(title: "Export Current Set…") { [weak self] in self?.exportCurrentSet() })
        if let id = config.activeSetID, config.activeSet != nil {
            items.append(.separator)
            items.append(SQMenuItem(title: SQL10n.format("Rename “%@”…", config.baseTitle)) { [weak self] in self?.renameSet(id) })
            items.append(SQMenuItem(title: SQL10n.format("Delete “%@”…", config.baseTitle)) { [weak self] in self?.deleteSet(id) })
        }
        return items
    }

    enum TemplateChoice { case preset(KeymapPreset), custom(String) }

    func chooseTemplate(_ choice: TemplateChoice) {
        let title: String
        switch choice {
        case .preset(let p):
            if config.activeSet == nil && config.preset == p { return }
            title = p.title
        case .custom(let id):
            if config.activeSetID == id { return }
            title = config.customSets.first { $0.id == id }?.name ?? "this"
        }
        guard confirmLeavingChanges(toward: title) else { return }
        switch choice {
        case .preset(let p): config.switchPreset(p)
        case .custom(let id): config.switchToSet(id)
        }
        commit()
    }

    /// Own shortcuts on top of the current template are lost on a switch: ask first.
    private func confirmLeavingChanges(toward title: String) -> Bool {
        guard config.isModified else { return true }
        let a = SQDialog()
        a.messageText = SQL10n.format("Switch to “%@”?", title)
        a.informativeText = SQL10n.format("Your own changes on top of “%@” are removed. Use Save Current as My Set first to keep them.", config.baseTitle)
        a.addButton("Switch")
        a.addButton("Cancel", role: .cancel)
        return a.runModal() == .first
    }

    // MARK: Import

    func importShortcuts() {
        let panel = NSOpenPanel()
        panel.message = "Choose a shortcut file: a Premiere Pro keyboard layout (.kys), a DaVinci Resolve keyboard layout, a Final Cut Pro command set (.commandset) or a Sequence Studio set (.sqkeys)"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["kys", "commandset", "preset", "txt", KeymapSet.fileExtension].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importShortcuts(from: url)
    }

    func importShortcuts(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return notify("Could not read that file", "Check that the file still exists and that you may open it.") }
        let name = url.deletingPathExtension().lastPathComponent
        if let set = KeymapSet(exported: data) {
            let count = Set(set.map.entries.map(\.command)).count
            guard confirm("Import “\(set.name)”?", "\(count) commands with shortcuts. It is added to My Sets.", button: "Add Set") else { return }
            config.addSet(set)
            commit()
            return
        }
        let file: ForeignKeymapFile.Contents
        do { file = try ForeignKeymapFile.read(data) } catch {
            return notify("That is not a shortcut file we know", "Premiere Pro keyboard layouts (.kys), DaVinci Resolve keyboard layouts, Final Cut Pro command sets (.commandset) and Sequence Studio sets (.sqkeys) can be imported.")
        }
        let result = KeymapImport.build(file.commands, table: file.format.table, resolver: .currentLayout())
        guard result.importedCommands > 0 else {
            return notify("Nothing to import", "None of the commands in this file exist in Sequence Studio. \(result.summary).")
        }
        guard showImportResult(result, name: name) else { return }
        config.addSet(name: name, map: result.map)
        commit()
    }

    /// "N imported, M have no equivalent in Sequence Studio", then the names. True when the user keeps the set.
    private func showImportResult(_ r: KeymapImport, name: String) -> Bool {
        let a = SQDialog()
        a.width = SQModal.Size.sList.width
        a.messageText = KeymapImportResultDialog.title(r)
        a.informativeText = KeymapImportResultDialog.note(name: name)
        a.accessoryView = KeymapImportResultDialog.makeAccessory(r)
        a.addButton("Save as Set")
        a.addButton("Cancel", role: .cancel)
        return a.runModal() == .first
    }

    // MARK: Own sets

    func saveCurrentAsSet() {
        guard let name = askName(title: "Save Current as My Set", initial: config.activeSet == nil ? "My Shortcuts" : config.baseTitle + " copy", button: "Save") else { return }
        config.addSet(name: name, map: config.map)
        commit()
    }

    func renameSet(_ id: String) {
        guard let set = config.customSets.first(where: { $0.id == id }),
              let name = askName(title: "Rename Set", initial: set.name, button: "Rename") else { return }
        config.renameSet(id, to: name)
        commit()
    }

    func deleteSet(_ id: String) {
        guard let set = config.customSets.first(where: { $0.id == id }) else { return }
        let a = SQDialog()
        a.messageText = SQL10n.format("Delete “%@”?", set.name)
        a.informativeText = "The set is removed. Sequence Studio's own shortcuts come back."
        a.addButton("Delete")
        a.addButton("Cancel", role: .cancel)
        guard a.runModal() == .first else { return }
        config.deleteSet(id)
        commit()
    }

    func exportCurrentSet() {
        let set = config.currentAsSet()
        let panel = NSSavePanel()
        panel.message = SQL10n.format("Export “%@” as a shortcut file", set.name)
        panel.nameFieldStringValue = set.name + "." + KeymapSet.fileExtension
        if let t = UTType(filenameExtension: KeymapSet.fileExtension) { panel.allowedContentTypes = [t] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try set.exportData().write(to: url, options: .atomic) } catch {
            notify("Could not save the file", SQL10n.errorText(error))
        }
    }

    // MARK: Small dialogs

    private func askName(title: String, initial: String, button: String) -> String? {
        let field = SQDialog.makeField(initial, width: nil)
        let a = SQDialog()
        a.messageText = title
        a.accessoryView = SQDialogForm(rows: [SQDialog.fieldRow(field)])
        a.initialFirstResponder = field
        a.addButton(button)
        a.addButton("Cancel", role: .cancel)
        guard a.runModal() == .first else { return nil }
        return field.stringValue
    }

    private func notify(_ title: String, _ text: String) {
        let a = SQDialog()
        a.messageText = title
        a.informativeText = text
        a.addButton("OK")
        a.runModal()
    }

    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let a = SQDialog()
        a.messageText = title
        a.informativeText = text
        a.addButton(button)
        a.addButton("Cancel", role: .cancel)
        return a.runModal() == .first
    }
}
