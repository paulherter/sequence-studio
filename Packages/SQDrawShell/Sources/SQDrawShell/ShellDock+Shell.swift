import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// The Window menu's workspace and panel rows, the panel commands (Show <Panel>, Maximize, Reset to Saved Layout, next /
/// previous panel), Window > History and Help > Welcome Tour on the shell (the Mac `AppController` workspace actions,
/// `showHistory`, `showWelcome` translated).
extension ShellHost {
    /// Window rows the dock owns; true when handled.
    func performWindow(_ a: ShellAction) -> Bool {
        switch a {
        case .selectWorkspace(let name): dock.chooseWorkspace(name)
        case .saveWorkspaceAs: spawn { await self.saveWorkspaceAs() }
        case .renameWorkspace: spawn { await self.renameWorkspace() }
        case .deleteWorkspace: spawn { await self.deleteWorkspace() }
        case .resetLayout: dock.resetLayout()
        case .resetAllWorkspaces: dock.resetAll()
        case .togglePanel(let p): dock.toggle(p); focus = dock.focused
        case .history: spawn { await self.showHistory() }
        case .welcomeTour: spawn { await self.showWelcome() }
        default: return false
        }
        return true
    }

    /// The panel commands; nil when `c` is not one of them.
    func executePanelCommand(_ c: EditorCommand) -> Bool? {
        switch c {
        case .focusPanel(let p):
            // Window > Sources: the clip list lives on the Color page (the Mac `showPanel`).
            if p == .colorClips { dock.setPage(.color) }
            dock.show(p)
        case .maximizePanel:
            guard let p = dock.pointer.flatMap(dock.panel(at:)) ?? focus else { return false }
            dock.toggleMaximize(p)
        case .maximizeActivePanel:
            guard let p = focus ?? dock.focused else { return false }
            dock.toggleMaximize(p)
        case .resetLayout: dock.resetLayout()
        case .selectNextPanel, .selectPreviousPanel:
            guard let p = dock.cycle(from: focus, forward: c == .selectNextPanel) else { return false }
            dock.focused = p
        default: return nil
        }
        focus = dock.focused ?? focus
        return true
    }

    /// Fills the Window menu rows the dock knows.
    func fillWindowState(_ s: inout ShellMenuState) {
        s.workspaces = dock.store.library.names
        s.currentWorkspace = dock.store.editName
        s.visiblePanels = dock.visiblePanels
        s.unavailablePanels = dock.transientlyHidden
        s.windowName = startScreen == nil ? session.displayName : nil
    }

    // MARK: Workspace dialogs

    private func askWorkspaceName(_ title: String, info: String = "", initial: String, button: String) async -> String? {
        let d = ShellDialog(title, informative: info)
        d.form = ShellForm([.field(id: "name", label: "Name", value: initial)])
        d.addButton(button)
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return nil }
        d.form?.commitEditing()
        return d.form?.text("name")
    }

    func saveWorkspaceAs() async {
        guard let name = await askWorkspaceName("Save as New Workspace", info: "Saves the Edit and the Color layout together under one name.",
                                                initial: dock.store.library.suggestedNewName(base: "My Layout"), button: "Save") else { return }
        // An existing name gets a numbered copy instead of being overwritten silently.
        if dock.saveAsNew(name) == nil { flash("That workspace name is not available.") }
    }

    func renameWorkspace() async {
        guard dock.store.canRenameOrDeleteCurrent,
              let name = await askWorkspaceName("Rename Workspace", initial: dock.store.editName, button: "Rename") else { return }
        if !dock.renameCurrent(name) { flash("That workspace name is not available.") }
    }

    func deleteWorkspace() async {
        guard dock.store.canRenameOrDeleteCurrent else { return }
        let d = ShellDialog(SQL10n.format("Delete workspace “%@”?", dock.store.editName), informative: "The Editing layout is shown afterwards.")
        d.addButton("Delete", role: .destructive)
        d.addButton("Cancel", role: .cancel)
        guard await ask(d) == .first else { return }
        _ = dock.deleteCurrent()
    }

    // MARK: History, Welcome

    /// Window > History: the undo steps as one choice list; picking a row jumps there (`jumpToHistoryRow`).
    // shortcut: the list shows the newest `historyRows` steps as radio rows (no scrolling list on the canvas yet),
    // upgrade when ShellForm gets a scrolling list row.
    func showHistory() async {
        let list = session.historyList
        let first = max(list.rows.count - Self.historyRows, 0)
        let shown = Array(list.rows[first...])
        let d = ShellDialog("History", informative: "Click a step to go back to it. Dimmed steps were undone.")
        let form = ShellForm([.radio(id: "row", options: shown.map { $0.isUndone ? "(" + $0.title + ")" : $0.title },
                                     selected: list.position - first)])
        form.onChange = { [weak self] _, v in
            guard let self, case .index(let i) = v else { return }
            session.jumpToHistoryRow(first + i)
        }
        d.form = form
        d.addButton("Done")
        _ = await ask(d)
    }

    static let historyRows = 14

    /// Help > Welcome Tour, and the first run (`presentWelcomeIfNeeded`).
    func showWelcome() async {
        let d = ShellDialog(OnboardingContent.title, informative: OnboardingContent.intro)
        var rows: [ShellForm.Row] = []
        for t in OnboardingContent.tips { rows += [.text(SQL10n.string(t.title) + ": " + SQL10n.string(t.detail)), .gap(4)] }
        d.form = ShellForm(rows)
        d.addButton(OnboardingContent.startButton)
        d.addButton(OnboardingContent.skipButton, leading: true)
        _ = await ask(d)
    }

    /// Shows the welcome once per machine, the first time the editor window is up; the flag is written when it opens so
    /// it never comes back after a quit or a crash (the Mac `presentWelcomeIfNeeded`).
    public func presentWelcomeIfNeeded(defaults: UserDefaults = .standard) {
        var s = AppSettings.load(from: defaults)
        guard !s.onboardingSeen, dialog == nil, startScreen == nil else { return }
        s.onboardingSeen = true
        s.save(to: defaults)
        spawn { await self.showWelcome() }
    }
}

extension ShellDock {
    /// The next or previous visible panel after `p` in layout order (Select Next / Previous Panel).
    public func cycle(from p: PanelID?, forward: Bool) -> PanelID? {
        let order = groups.map(\.selected)
        guard !order.isEmpty else { return nil }
        guard let p, let i = order.firstIndex(of: p) else { return order[0] }
        return order[(i + (forward ? 1 : order.count - 1)) % order.count]
    }
}
