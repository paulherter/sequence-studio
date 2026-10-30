import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// Keyboard Shortcuts, translated from the Mac `KeyboardShortcutsWindowController` (+Sets): the keyboard picture colored by
/// command group, the modifier layer, every command with its shortcut, Set Shortcut (press the keys), Assign to a picked
/// key, Remove, Reset to Defaults, and the template switcher (presets, own sets, import, save, export, rename, delete).
/// Same models: `KeymapConfig` / `KeymapStore` (`sq.keymap`), `KeymapRow`, `Keymap.conflicts` / `assign` / `unbind`,
/// `KeyboardLayout` / `KeyboardLayoutModel`, `KeymapImport` / `ForeignKeymapFile`. Shortcut text and conflict messages name
/// the platform's keys (`KeyBindingText`: Ctrl+Shift+K on Windows).
@MainActor
public final class ShellShortcutsEditor {
    public weak var host: ShellHost?
    let defaults: UserDefaults
    public let platform: KeyPlatform
    public private(set) var config: KeymapConfig
    public private(set) var allRows: [KeymapRow] = []
    /// The rows the search keeps (`listing.shortcut` in the platform's key names).
    public private(set) var rows: [KeymapRow] = []
    public private(set) var selectedIndex: Int?
    /// The key picked on the picture.
    public private(set) var selectedKey: Key?
    /// The modifier layer the picture shows.
    public private(set) var modifiers: KeyModifiers = []
    public private(set) var style: KeyboardLayout.Style
    /// Set Shortcut waits for a key press.
    public private(set) var capturing = false
    public private(set) var info = ShellShortcutsEditor.idleInfo
    var search = TextFieldControl()
    let scrollBody = ScrollBody()
    /// The scroll offset; the body adds momentum and the rubber band.
    var scroll: CGFloat {
        get { scrollBody.position }
        set { scrollBody.position = newValue }
    }
    /// Popup lists (templates, layout).
    let menu = MenuController()
    /// The window, points.
    public var frame: CGRect = .zero
    var hover: Hit?
    var pressed: Hit?

    static let idleInfo = "Click a key to see what it does."

    public init(host: ShellHost, defaults: UserDefaults = .standard, platform: KeyPlatform = .current) {
        self.host = host
        self.defaults = defaults
        self.platform = platform
        config = KeymapStore(defaults: defaults).load()
        style = KeyboardLayout.Style.saved(defaults)
        search.alignment = .left
        search.fontSize = M.fBody
        refilter()
        search.mouseDown()    // the Mac window starts with the search field focused
    }

    // MARK: Model

    public var query: String { search.editor?.string ?? search.text }
    public var selectedRow: KeymapRow? { selectedIndex.flatMap { rows.indices.contains($0) ? rows[$0] : nil } }
    public var layoutModel: KeyboardLayoutModel { KeyboardLayoutModel(map: config.map, modifiers: modifiers) }
    public var countText: String { rows.count == allRows.count ? "\(rows.count) shortcuts" : "\(rows.count) of \(allRows.count)" }
    public var canReset: Bool { config.isModified }

    func keyText(_ b: KeyBinding) -> String { KeyBindingText.text(b, platform: platform) }

    /// The modifier toggles (`modifierControl`): the Mac's four, on Windows Ctrl / Alt / Shift (Ctrl stands for Command,
    /// which also reaches the Mac Control bindings, `WindowsKeyRoute`).
    var modifierChoices: [(label: String, mod: KeyModifiers)] {
        platform == .mac ? [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
            : [("Ctrl", .command), ("Alt", .option), ("Shift", .shift)]
    }

    /// "Assign to Key" / "Assign to Ctrl+K" (`updateButtons`).
    public var assignTitle: String {
        selectedKey.map { "Assign to " + keyText(KeyBinding($0, modifiers)) } ?? "Assign to Key"
    }

    func refilter() {
        let keep = selectedRow
        allRows = KeymapRow.build(config.map).map { r in
            var r = r
            if let e = r.entry { r.listing.shortcut = keyText(e.binding) }
            return r
        }
        rows = KeymapRow.filter(allRows, query: query)
        selectedIndex = keep.flatMap { k in rows.firstIndex { $0.command == k.command && $0.entry == k.entry }
            ?? rows.firstIndex { $0.command == k.command } }
    }

    public func setQuery(_ s: String) {
        search.cancel()
        search.text = s
        queryChanged()
    }

    /// `controlTextDidChange`: the list follows the search, the selection goes.
    func queryChanged() {
        rows = KeymapRow.filter(allRows, query: query)
        selectedIndex = nil
        scroll = 0
    }

    public func select(index: Int?) {
        selectedIndex = index.flatMap { rows.indices.contains($0) ? $0 : nil }
        if let i = selectedIndex { scrollToRow(i) }
    }

    /// A key on the picture: its commands in the info line.
    public func selectKey(_ k: Key?) {
        selectedKey = k
        info = k.map { layoutModel.summary(for: $0, platform: platform) } ?? Self.idleInfo
    }

    public func toggleModifier(_ m: KeyModifiers) {
        if modifiers.contains(m) { modifiers.remove(m) } else { modifiers.insert(m) }
        selectKey(selectedKey)
    }

    /// `layoutChanged`: saved under `sq.shortcuts.keyboardLayout`, the picked key goes.
    public func setStyle(_ s: KeyboardLayout.Style) {
        style = s
        defaults.set(s.rawValue, forKey: KeyboardLayout.Style.defaultsKey)
        selectKey(nil)
    }

    // MARK: Actions

    /// Set Shortcut…: the next key press becomes the row's shortcut; Esc cancels.
    public func beginCapture() {
        guard selectedRow != nil, !capturing else { return }
        if search.isEditing { _ = search.commit() }
        capturing = true
        info = "Press the new shortcut (Esc cancels)."
    }

    func endCapture() {
        capturing = false
        selectKey(selectedKey)
    }

    /// The press while capturing (`KeyMapping.keyEvent(from:capture:)` on the Mac).
    public func capture(_ k: InputKey, _ m: InputModifiers) {
        guard capturing else { return }
        if k == .escape { endCapture(); return }
        guard let key = ShellKeys.key(k) else { return }
        var mods: KeyModifiers = []
        if m.contains(.command) { mods.insert(.command) }
        if m.contains(.option) { mods.insert(.option) }
        if m.contains(.shift) { mods.insert(.shift) }
        let row = selectedRow
        endCapture()
        guard let row, let host else { return }
        host.spawn { await self.attempt(row, binding: KeyBinding(key, mods)) }
    }

    public func assignToKey() async {
        guard let row = selectedRow, let k = selectedKey else { return }
        await attempt(row, binding: KeyBinding(k, modifiers))
    }

    public func removeShortcut() {
        guard let e = selectedRow?.entry else { return }
        config.set(map: Keymap.unbind(e, in: config.map))
        commit()
    }

    public func resetAll() async {
        guard let host, config.isModified else { return }
        let d = ShellDialog(SQL10n.format("Reset all shortcuts to the %@ defaults?", config.baseTitle),
                            informative: SQL10n.format("Every shortcut you changed on top of “%@” goes back.", config.baseTitle))
        d.addButton("Reset")
        d.addButton("Cancel", role: .cancel)
        guard await host.ask(d) == .first else { return }
        config.resetOverrides()
        commit()
    }

    /// Binds the row's command to `binding`, in the row's own scope (Everywhere for a command without a key). Same-scope
    /// conflicts and shadowing are shown first; a reserved key is refused.
    public func attempt(_ row: KeymapRow, binding: KeyBinding) async {
        guard let host else { return }
        let scope = row.entry?.scope ?? .global
        let map = config.map
        let conflicts = Keymap.conflicts(of: row.command, binding: binding, scope: scope, in: map)
        if conflicts.contains(where: { $0.kind == .reserved }) {
            _ = await host.ask(ShellDialog("That shortcut is not available", informative: conflicts[0].message(for: binding, platform: platform)))
            return
        }
        if !conflicts.isEmpty {
            let hard = conflicts.contains { $0.kind == .sameScope }
            let d = ShellDialog(hard ? "Replace the existing shortcut?" : "This shortcut overlaps another one",
                                informative: conflicts.map { $0.message(for: binding, platform: platform) }.joined(separator: "\n")
                                    + (hard ? "\n\nThe other command loses this key." : ""))
            d.addButton(hard ? "Replace" : "Assign Anyway")
            d.addButton("Cancel", role: .cancel)
            guard await host.ask(d) == .first else { return }
        }
        guard let new = Keymap.assign(row.command, to: binding, scope: scope, in: map, moving: row.entry) else { return }
        config.set(map: new)
        commit()
    }

    /// Saves to `sq.keymap` and hands the map to the shell (menus, key route) and the host's panels.
    func commit() {
        KeymapStore(defaults: defaults).save(config)
        host?.applyKeymap(config.map)
        refilter()
        selectKey(selectedKey)
    }

    // MARK: Templates and own sets (KeyboardShortcutsWindow+Sets)

    public func templateMenuItems() -> [SQMenuItem] {
        var items: [SQMenuItem] = [.header("Templates")]
        for p in KeymapPreset.allCases {
            items.append(SQMenuItem(title: p.title, isChecked: config.activeSet == nil && config.preset == p) { [weak self] in
                self?.run { await $0.chooseTemplate(.preset(p)) }
            })
        }
        if !config.customSets.isEmpty {
            items += [.separator, .header("My Sets")]
            for s in config.customSets {
                items.append(SQMenuItem(title: s.name, isChecked: config.activeSetID == s.id) { [weak self] in
                    self?.run { await $0.chooseTemplate(.custom(s.id)) }
                })
            }
        }
        items.append(.separator)
        items.append(SQMenuItem(title: "Import Shortcuts…") { [weak self] in self?.run { await $0.importShortcuts() } })
        items.append(SQMenuItem(title: "Save Current as My Set…") { [weak self] in self?.run { await $0.saveCurrentAsSet() } })
        items.append(SQMenuItem(title: "Export Current Set…") { [weak self] in self?.run { await $0.exportCurrentSet() } })
        if let id = config.activeSetID, config.activeSet != nil {
            items.append(.separator)
            items.append(SQMenuItem(title: SQL10n.format("Rename “%@”…", config.baseTitle)) { [weak self] in self?.run { await $0.renameSet(id) } })
            items.append(SQMenuItem(title: SQL10n.format("Delete “%@”…", config.baseTitle)) { [weak self] in self?.run { await $0.deleteSet(id) } })
        }
        return items
    }

    private func run(_ f: @escaping @MainActor (ShellShortcutsEditor) async -> Void) {
        host?.spawn { [weak self] in if let self { await f(self) } }
    }

    public enum TemplateChoice: Sendable { case preset(KeymapPreset), custom(String) }

    public func chooseTemplate(_ choice: TemplateChoice) async {
        let title: String
        switch choice {
        case .preset(let p):
            if config.activeSet == nil && config.preset == p { return }
            title = p.title
        case .custom(let id):
            if config.activeSetID == id { return }
            title = config.customSets.first { $0.id == id }?.name ?? "this"
        }
        if config.isModified {
            // Own shortcuts on top of the current template are lost on a switch: ask first.
            guard await confirm(SQL10n.format("Switch to “%@”?", title),
                                SQL10n.format("Your own changes on top of “%@” are removed. Use Save Current as My Set first to keep them.", config.baseTitle),
                                button: "Switch") else { return }
        }
        switch choice {
        case .preset(let p): config.switchPreset(p)
        case .custom(let id): config.switchToSet(id)
        }
        commit()
    }

    public func importShortcuts() async {
        guard let url = await host?.files?.chooseShortcutFile() else { return }
        await importShortcuts(from: url)
    }

    public func importShortcuts(from url: URL) async {
        guard let data = try? Data(contentsOf: url) else {
            return await notify("Could not read that file", "Check that the file still exists and that you may open it.")
        }
        let name = url.deletingPathExtension().lastPathComponent
        if let set = KeymapSet(exported: data) {
            let count = Set(set.map.entries.map(\.command)).count
            guard await confirm("Import “\(set.name)”?", "\(count) commands with shortcuts. It is added to My Sets.", button: "Add Set") else { return }
            config.addSet(set)
            commit()
            return
        }
        let file: ForeignKeymapFile.Contents
        do { file = try ForeignKeymapFile.read(data) } catch {
            return await notify("That is not a shortcut file we know", "Premiere Pro keyboard layouts (.kys), DaVinci Resolve keyboard layouts, Final Cut Pro command sets (.commandset) and Sequence Studio sets (.sqkeys) can be imported.")
        }
        let result = KeymapImport.build(file.commands, table: file.format.table, resolver: .currentLayout())
        guard result.importedCommands > 0 else {
            return await notify("Nothing to import", "None of the commands in this file exist in Sequence Studio. \(result.summary).")
        }
        guard await showImportResult(result, name: name) else { return }
        config.addSet(name: name, map: result.map)
        commit()
    }

    /// "N imported, M have no equivalent", then the names (`KeymapImportResultDialog`). True when the user keeps the set.
    private func showImportResult(_ r: KeymapImport, name: String) async -> Bool {
        guard let host else { return false }
        let d = ShellDialog(r.summary, informative: "“\(name)” is saved as one of your own sets. Commands it does not mention keep their Sequence Studio keys.")
        d.width = 480
        var rows: [ShellForm.Row] = []
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            // shortcut: the first 8 lines of each section (no scrolling text block on the canvas yet); upgrade with one.
            let shown = lines.prefix(8).joined(separator: "\n") + (lines.count > 8 ? "\n… \(lines.count - 8) more" : "")
            rows += [.text(title), .text(shown), .gap(6)]
        }
        section("No equivalent in Sequence Studio (\(r.unmapped.count))", r.unmapped.map { KeymapImport.title(of: $0) })
        section("Changed keys", r.conflicts.map(\.message))
        section("Not imported", r.skippedKeys.map(\.message))
        if !rows.isEmpty { d.form = ShellForm(rows) }
        d.addButton("Save as Set")
        d.addButton("Cancel", role: .cancel)
        return await host.ask(d) == .first
    }

    public func saveCurrentAsSet() async {
        guard let name = await askName("Save Current as My Set", initial: config.activeSet == nil ? "My Shortcuts" : config.baseTitle + " copy",
                                       button: "Save") else { return }
        config.addSet(name: name, map: config.map)
        commit()
    }

    public func renameSet(_ id: String) async {
        guard let set = config.customSets.first(where: { $0.id == id }),
              let name = await askName("Rename Set", initial: set.name, button: "Rename") else { return }
        config.renameSet(id, to: name)
        commit()
    }

    public func deleteSet(_ id: String) async {
        guard let set = config.customSets.first(where: { $0.id == id }) else { return }
        guard await confirm(SQL10n.format("Delete “%@”?", set.name), "The set is removed. Sequence Studio's own shortcuts come back.",
                            button: "Delete") else { return }
        config.deleteSet(id)
        commit()
    }

    public func exportCurrentSet() async {
        let set = config.currentAsSet()
        guard let url = await host?.files?.chooseShortcutExportLocation(suggestedName: set.name + "." + KeymapSet.fileExtension) else { return }
        do { try set.exportData().write(to: url, options: .atomic) } catch {
            await notify("Could not save the file", SQL10n.errorText(error))
        }
    }

    private func askName(_ title: String, initial: String, button: String) async -> String? {
        guard let host else { return nil }
        let d = ShellDialog(title)
        d.form = ShellForm([.field(id: "name", label: "Name", value: initial)])
        d.addButton(button)
        d.addButton("Cancel", role: .cancel)
        guard await host.ask(d) == .first else { return nil }
        d.form?.commitEditing()
        return d.form?.text("name")
    }

    private func notify(_ title: String, _ text: String) async {
        _ = await host?.ask(ShellDialog(title, informative: text))
    }

    private func confirm(_ title: String, _ text: String, button: String) async -> Bool {
        guard let host else { return false }
        let d = ShellDialog(title, informative: text)
        d.addButton(button)
        d.addButton("Cancel", role: .cancel)
        return await host.ask(d) == .first
    }
}

extension ShellFilePicker {
    /// Import Shortcuts: a .kys, .commandset, Resolve layout or .sqkeys file. Default: not offered.
    public func chooseShortcutFile() async -> URL? { nil }
    /// Export Current Set: where the .sqkeys file goes. Default: not offered.
    public func chooseShortcutExportLocation(suggestedName: String) async -> URL? { nil }
}

extension ShellHost {
    public var isShortcutsShown: Bool { shortcutsEditor != nil }

    /// Keyboard Shortcuts (Ctrl+Alt+K): modal over the window; a second call while it shows does nothing.
    public func showShortcuts(defaults: UserDefaults = .standard) {
        guard shortcutsEditor == nil else { return }
        menuBar.controller.dismiss()
        let e = ShellShortcutsEditor(host: self, defaults: defaults)
        e.frame = CGRect(origin: .zero, size: size)
        e.menu.measure = measure
        shortcutsEditor = e
    }

    public func hideShortcuts() { shortcutsEditor = nil }

    /// A new key map from the Keyboard Shortcuts editor: the menus and the key route use it at once, the host's panels
    /// through `onKeymapChanged`.
    public func applyKeymap(_ m: CommandMap) {
        map = m
        menuBar.menus = menus()
        onKeymapChanged?(m)
    }
}
