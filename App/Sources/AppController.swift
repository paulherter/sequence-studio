import AppKit
import Metal
import SSCore
import SSEditorUI
import SSPlayback

/// Application delegate and owner of everything: the `EditorSession`, the window shell, the panels, the menus and the
/// keyboard routing. Commands from the menus, the toolbar, the monitor transport and `KeyRouter` all end up in
/// `execute(_:)` (AppController+Commands.swift) and from there in session calls.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let session: EditorSession
    /// nil when no Metal device: the stub engine runs and nothing is shown in the Program monitor.
    let engineNote: String?
    let commandMap = CommandMap.premiereDefault
    var store = WorkspaceStore.load()
    var maximizedPanel: PanelID?
    var focusedPanel: PanelID? = .timeline { didSet { router.focus = focusedPanel } }
    var router: KeyRouter
    var menuShuttle = Shuttle()

    var window: NSWindow!
    var shell = ShellContentView()
    var panels: EditorPanels!
    var toolbar: EditorToolbar!
    let mainWorkspaceSubmenu = NSMenu(title: "Workspace")
    var keyMonitor: Any?
    var saveWorkspaceWork: DispatchWorkItem?
    var deadlineWork: DispatchWorkItem?
    let exports = ExportCoordinator()
    let audioEngine: AudioEngine
    var audioWarned = false

    override init() {
        let media = ProjectMediaResolver()
        var engine: any ProgramEngine = StubProgramEngine()
        var note: String?
        let audio = AudioEngine(media: media)
        audioEngine = audio
        if let device = MTLCreateSystemDefaultDevice() {
            do { engine = try PlaybackEngine(device: device, media: media, audio: audio) } catch { note = "Playback engine unavailable: \(error)" }
        } else {
            note = "No Metal device: the Program monitor stays blank."
        }
        session = EditorSession(engine: engine, media: media)
        engineNote = note
        router = KeyRouter(map: .premiereDefault, focus: .timeline, clock: { ProcessInfo.processInfo.systemUptime })
        super.init()
        session.onChange = { [weak self] c in self?.sessionChanged(c) }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        panels = EditorPanels(session: session)
        panels.onFocus = { [weak self] p in self?.focusedPanel = p }
        panels.propertiesView.onAudioPresetChange = { [audioEngine] id, p in audioEngine.feeder.setPreset(track: id, preset: p) }
        panels.onStatus = { [weak self] m in self?.shell.statusBar.flash(m) }
        panels.onCommand = { [weak self] c in self?.execute(c) }
        panels.onNest = { [weak self] in self?.requestNest() }

        toolbar = EditorToolbar(controller: self)
        fillWorkspaceMenu(mainWorkspaceSubmenu)
        NSApp.mainMenu = MenuBuilder.build(target: self, map: commandMap)
        buildWindow()
        applyWorkspace()
        installKeyMonitor()
        sessionChanged([.project, .selection, .playhead, .transport])
        if let engineNote { shell.statusBar.flash(engineNote, seconds: 12) }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        session.startAutosaveTimer()
        launchDocument()
        SnapshotDriver.runIfRequested(self)
        PlayTestDriver.runIfRequested(self)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 960),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.minSize = NSSize(width: 1000, height: 620)
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.Colors.titlebar
        w.toolbar = toolbar.toolbar
        w.toolbarStyle = .unified
        w.titleVisibility = .visible
        w.delegate = self
        w.contentView = shell
        shell.host.panelView = { [weak self] p in self?.panels.view(for: p) ?? NSView() }
        shell.host.onSelectTab = { [weak self] p in
            self?.mutateWorkspace { $0.selectTab(p) }
            self?.focusedPanel = p
        }
        shell.host.onDock = { [weak self] panel, anchor, zone in
            self?.maximizedPanel = nil
            self?.mutateWorkspace { $0.dock(panel, onto: anchor, zone: zone) }
            self?.focusedPanel = panel
        }
        shell.host.onMoveTab = { [weak self] panel, index in
            self?.mutateWorkspace { $0.moveTab(panel, toIndex: index) }
        }
        shell.host.onFractions = { [weak self] path, fractions in
            guard let self else { return }
            var ws = store.current
            if ws.setFractions(at: path, fractions) { store.updateCurrent(ws); scheduleWorkspaceSave() }
        }
        w.setFrameAutosaveName("SequenceStudioMain")
        if !w.setFrameUsingName("SequenceStudioMain") { w.center() }
        window = w
    }

    /// `SS_OPEN=<path.ssproj>` opens a project; `SS_DEMO=1` fills the untitled project with sample clips (screenshots).
    private func launchDocument() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["SS_OPEN"] {
            Task { await openProject(at: URL(fileURLWithPath: path)) }
        } else if env["SS_DEMO"] == "1" {
            session.newProject(DemoProject.make())
            session.seek(to: DemoProject.playhead)
            session.select(clips: DemoProject.selection(in: session))
        } else {
            offerRecovery()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(session.displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                let ok = await saveDocument()
                NSApp.reply(toApplicationShouldTerminate: ok)
            }
            return .terminateLater
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.close()
        try? store.save()
    }

    // MARK: Session to UI

    func sessionChanged(_ change: EditorSession.Change) {
        panels?.sync(change)
        guard window != nil else { return }
        if change.contains(.transport) {
            if session.isPlaying {
                if session.engine.audioUnavailable, !audioWarned {
                    audioWarned = true
                    shell.statusBar.flash("Audio output unavailable: playing without sound.", seconds: 6)
                }
            } else { audioWarned = false }
        }
        if change.contains(.project) || change.contains(.status) { updateChrome() }
    }

    private func updateChrome() {
        window.title = session.displayName
        window.representedURL = session.fileURL
        window.isDocumentEdited = session.isDirty
        if let t = session.activeTimeline {
            let f = t.format
            let fps = Double(f.frameDuration.timescale) / Double(f.frameDuration.value)
            shell.statusBar.setDetail("\(t.name)  ·  \(f.width)×\(f.height)  ·  \(String(format: "%.2f", fps)) fps"
                                      + (session.isDirty ? "  ·  Edited" : ""))
        }
        if let e = session.lastError { shell.statusBar.flash(e); session.clearError() }
    }

    // MARK: Workspaces

    func applyWorkspace() {
        var w = store.current
        w.maximized = maximizedPanel
        shell.host.apply(w)
        toolbar.sync(store: store, workspace: w)
        fillWorkspaceMenu(mainWorkspaceSubmenu)
        if focusedPanel == .timeline { window?.makeFirstResponder(panels.timelineView) }
    }

    func mutateWorkspace(_ body: (inout Workspace) -> Void) {
        var w = store.current
        body(&w)
        store.updateCurrent(w)
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    func scheduleWorkspaceSave() {
        saveWorkspaceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { try? self?.store.save() } }
        saveWorkspaceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func fillWorkspaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for w in store.library.all {
            let i = NSMenuItem(title: w.name, action: #selector(selectWorkspace(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = w.name
            i.state = store.page == .edit && w.name == store.editName ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())
        for (title, sel) in [("Save Workspace As…", #selector(saveLayoutAs(_:))),
                             ("Rename Workspace…", #selector(renameWorkspace(_:))),
                             ("Delete Workspace", #selector(deleteWorkspace(_:))),
                             ("Reset to Saved Layout", #selector(resetLayout(_:)))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
    }

    /// A fresh menu for the toolbar item (an NSMenu has one parent, so it cannot share the main menu's).
    var workspaceMenu: NSMenu {
        let m = NSMenu(title: "Workspaces")
        fillWorkspaceMenu(m)
        return m
    }

    @objc func selectWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, store.selectEdit(name) else { return }
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    @objc func saveLayoutAs(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Save Layout As"
        alert.informativeText = "Name of the new workspace:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = "My Layout"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                var ws = self.store.current
                ws.name = name
                if !name.isEmpty, self.store.library.saveAs(name, from: ws) {
                    self.store.selectEdit(name)
                    self.scheduleWorkspaceSave()
                    self.applyWorkspace()
                } else {
                    self.shell.statusBar.flash("That workspace name is not available.")
                }
            }
        }
    }

    @objc func renameWorkspace(_ sender: Any?) {
        guard store.canRenameOrDeleteCurrent else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = store.editName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                if self.store.renameCurrent(to: field.stringValue) {
                    self.scheduleWorkspaceSave()
                    self.applyWorkspace()
                } else {
                    self.shell.statusBar.flash("That workspace name is not available.")
                }
            }
        }
    }

    @objc func deleteWorkspace(_ sender: Any?) {
        guard store.canRenameOrDeleteCurrent else { return }
        let alert = NSAlert()
        alert.messageText = "Delete workspace \u{201C}\(store.editName)\u{201D}?"
        alert.informativeText = "The Editing layout is shown afterwards."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn, self.store.deleteCurrent() else { return }
                self.maximizedPanel = nil
                self.scheduleWorkspaceSave()
                self.applyWorkspace()
            }
        }
    }

    @objc func resetLayout(_ sender: Any?) {
        guard store.page == .edit, store.library.resetBuiltIn(store.editName) else {
            if store.page == .color { store.colorWorkspace = .color; scheduleWorkspaceSave(); applyWorkspace() }
            return
        }
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    // MARK: Toolbar actions

    @objc func toolbarImport(_ sender: Any?) { execute(.importMedia) }
    @objc func toolbarExport(_ sender: Any?) { execute(.export) }

    @objc func toolbarPage(_ sender: NSToolbarItemGroup) {
        store.setPage(sender.selectedIndex == 1 ? .color : .edit)
        if store.page == .color {
            store.colorWorkspace.selectTab(.properties)
            panels.propertiesView.select(.color)
        }
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    @objc func toolbarPanels(_ sender: NSToolbarItemGroup) {
        mutateWorkspace { w in
            for (i, p) in EditorToolbar.togglePanels.enumerated() where w.allPanels.contains(p) {
                let want = sender.isSelected(at: i)
                if want != w.isVisible(p) { want ? w.show(p) : w.hide(p) }
            }
        }
    }

    @objc func toolbarTasks(_ sender: Any?) {
        guard let view = window.contentView else { return }
        exports.showQueue(relativeTo: CGRect(x: view.bounds.maxX - 120, y: 0, width: 40, height: 1), of: view)
    }

    // MARK: Menu

    @objc func menuCommand(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EditorCommand else { return }
        execute(c)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(renameWorkspace(_:)), #selector(deleteWorkspace(_:)): return store.canRenameOrDeleteCurrent
        case #selector(resetLayout(_:)): return store.canResetCurrent
        default: break
        }
        guard let c = item.representedObject as? EditorCommand else { return true }
        // Typing in a text field: the standard editing commands belong to it.
        if textResponder != nil, [.cut, .copy, .paste, .delete, .deleteProjectItems].contains(c) { return true }
        switch c {
        case .undo:
            item.title = session.undoName.map { "Undo \($0)" } ?? "Undo"
            return session.canUndo || textResponder != nil
        case .redo:
            item.title = session.redoName.map { "Redo \($0)" } ?? "Redo"
            return session.canRedo || textResponder != nil
        case .save: return true
        default: return Self.isSupported(c)
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    /// Returns nil when the event was consumed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window.attachedSheet == nil else { return event }
        if event.type == .leftMouseDown {
            if let p = panels.panel(containing: window.contentView?.hitTest(event.locationInWindow)) { focusedPanel = p }
            return event
        }
        // Typing: text fields and editors keep their keys.
        if let tv = window.firstResponder as? NSTextView, tv.isEditable || tv.isFieldEditor { return event }
        guard let ke = KeyMapping.keyEvent(from: event) else { return event }
        // Command shortcuts belong to the menus (key equivalents).
        if ke.modifiers.contains(.command) { return event }
        // Lists keep their arrow and delete keys.
        if window.firstResponder is NSTableView, [Key.up, .down, .left, .right, .delete].contains(ke.key) { return event }
        let actions = router.handle(ke)
        scheduleRouterDeadline()
        guard !actions.isEmpty else { return event }
        run(actions)
        return nil
    }

    private func run(_ actions: [RouterAction]) {
        for a in actions {
            switch a {
            case .command(let c, _): execute(c)
            case .shuttle(let s): session.apply(shuttle: s)
            }
        }
    }

    /// K held + J/L: slow mode starts after the hold threshold without another key event.
    private func scheduleRouterDeadline() {
        deadlineWork?.cancel()
        guard let deadline = router.nextDeadline else { return }
        let delay = max(deadline - ProcessInfo.processInfo.systemUptime, 0) + 0.01
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.run(self.router.tick())
                self.scheduleRouterDeadline()
            }
        }
        deadlineWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Focused text editor, if the user is typing somewhere.
    var textResponder: NSTextView? {
        guard let tv = window?.firstResponder as? NSTextView, tv.isEditable else { return nil }
        return tv
    }
}
