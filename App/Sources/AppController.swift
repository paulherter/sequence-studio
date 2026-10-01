import AppKit
import Metal
import Observation
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
    var settings: AppSettings
    private(set) lazy var settingsWindow = SettingsWindowController(controller: self)
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
    /// Set once quitting started (Save alert, then teardown): the key monitor must not touch views any more.
    var isTerminating = false
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
        let prefs = AppSettings.load()
        settings = prefs
        session = EditorSession(engine: engine, media: media,
                                autosaveStore: AutosaveStore(policy: AutosavePolicy(interval: prefs.autosaveInterval)))
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
        panels.clipSections.onAudioPresetChange = { [audioEngine] id, p in audioEngine.feeder.setPreset(track: id, preset: p) }
        panels.onStatus = { [weak self] m in self?.shell.statusBar.flash(m) }
        panels.onCommand = { [weak self] c in self?.execute(c) }
        panels.onNest = { [weak self] in self?.requestNest() }
        wireCaptions()
        panels.onFrameSize = { [weak self] in self?.session.setToFrameSize() }
        panels.monitorModel.setQuality(settings.defaultQuality)

        shell.statusBar.onTasksClicked = { [weak self] v in self?.toggleTasks(v) }
        exports.queueModel.start()
        watchExports()
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
        PlayTestDriver.runKeyTestIfRequested(self)
        DevAidDrivers.runIfRequested(self)
    }

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 960),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.contentMinSize = NSSize(width: 640, height: 400)   // refined per workspace in `applyWorkspace`
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.Colors.titlebar
        w.toolbar = toolbar.toolbar
        w.toolbarStyle = .unifiedCompact
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

    /// `SS_OPEN=<path.ssproj>` opens a project; `SS_NO_RECOVERY=1` skips the recovery prompt; `SS_DEMO=1` fills the untitled project with sample clips (screenshots).
    private func launchDocument() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["SS_OPEN"] {
            Task { await openProject(at: URL(fileURLWithPath: path)) }
        } else if env["SS_DEMO"] == "1" {
            session.newProject(DemoProject.make())
            session.seek(to: DemoProject.playhead)
            session.select(clips: DemoProject.selection(in: session))
        } else if env["SS_NO_RECOVERY"] != "1", env["SS_IMPORT"] == nil, settings.offerRecovery {
            offerRecovery()
        }
        if let list = env["SS_IMPORT"] { importAtLaunch(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }) }
    }

    /// `SS_IMPORT=<path>[:<path>…]`: imports like Cmd+I, then places the first file at 0 like a Project-panel drop. Stays open.
    private func importAtLaunch(_ urls: [URL]) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            await panels.projectModel.importFiles(urls)
            guard let first = urls.first, let m = session.project.media.first(where: { $0.path == first.path }) else {
                NSLog("SS_IMPORT: nothing imported, failures=\(panels.projectModel.importFailures)"); return
            }
            session.placeMedia([m.id], at: .zero, mode: .overwrite)
            session.select(clips: [])
            if let v = m.info?.video, let f = session.activeTimeline?.format {
                NSLog("SS_IMPORT: \(m.name) native \(v.width)x\(v.height) rotation \(v.rotation) still \(m.info?.isStill == true) "
                      + "-> display \(v.displayWidth)x\(v.displayHeight), sequence \(f.width)x\(f.height), scale \(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.media == m.id }?.animation.scale.value.x ?? -1)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session.isDirty else { removeKeyMonitor(); return .terminateNow }
        // The Save alert runs a modal loop: the monitor stays installed but `handle` bails out while it is up.
        isTerminating = true
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
                if ok { removeKeyMonitor() } else { isTerminating = false }
                NSApp.reply(toApplicationShouldTerminate: ok)
            }
            return .terminateLater
        case .alertSecondButtonReturn: removeKeyMonitor(); return .terminateNow
        default: isTerminating = false; return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeKeyMonitor()
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
            } else {
                audioWarned = false
                router.transportStopped()      // stopped by a click or the button: the next L starts at 1x
            }
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
            // The sequence rate is fixed; say so when its source clip is variable frame rate.
            let vfr = t.tracks.lazy.filter { $0.kind == .video }.flatMap(\.clips)
                .contains { session.project.media($0.media)?.info?.video?.isVariableFrameRate == true }
            shell.statusBar.setDetail("\(t.name)  ·  \(f.width)×\(f.height)  ·  \(String(format: "%.2f", fps)) fps"
                                      + (vfr ? " VFR" : "")
                                      + (session.isDirty ? "  ·  Edited" : ""))
        }
        if let e = session.lastError { shell.statusBar.flash(e); session.clearError() }
    }

    // MARK: Workspaces

    func applyWorkspace() {
        var w = store.current
        w.maximized = maximizedPanel
        shell.host.apply(w)
        toolbar.sync(store: store)
        fillWorkspaceMenu(mainWorkspaceSubmenu)
        fillToolbarWorkspaceMenu()
        // The window never gets smaller than the layout's panels need.
        let m = w.minimumContentSize
        window?.contentMinSize = NSSize(width: max(CGFloat(m.width), 640),
                                        height: max(CGFloat(m.height) + Theme.Metrics.statusBar, 400))
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

    /// Pull-down menu of the toolbar: item 0 is the button title (the current workspace), then the same list as the Window menu.
    func fillToolbarWorkspaceMenu() {
        let menu = toolbar.workspaceMenu
        fillWorkspaceMenu(menu)
        let title = NSMenuItem(title: store.current.name, action: nil, keyEquivalent: "")
        menu.insertItem(title, at: 0)
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
                             ("Reset to Saved Layout", #selector(resetLayout(_:))),
                             ("Reset All Workspaces", #selector(resetAllWorkspaces(_:)))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
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

    /// Every built-in (and the Color page) back at its shipped layout; user workspaces stay.
    @objc func resetAllWorkspaces(_ sender: Any?) {
        store.library.resetAllBuiltIns()
        store.colorWorkspace = .color
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
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
        if store.page == .color { store.colorWorkspace.selectTab(.colorInspector) }
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    /// Keeps the status-bar ring in step with the export queue.
    func watchExports() {
        let m = exports.queueModel
        shell.statusBar.setTasks(progress: m.hasActiveJobs ? m.overallProgress : nil)
        withObservationTracking {
            _ = m.jobs
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchExports() }
        }
    }

    /// Status-bar ring: show or hide the export queue.
    @objc func toggleTasks(_ sender: NSView) {
        exports.showQueue(relativeTo: sender.bounds, of: sender)
    }

    @objc func showSettings(_ sender: Any?) { settingsWindow.show() }

    /// Window menu panel item: a click toggles the panel (checkmark = visible); its keyboard shortcut shows and focuses it.
    @objc func windowPanelItem(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? PanelID else { return }
        if NSApp.currentEvent?.type == .keyDown {
            showPanel(p)
        } else {
            if maximizedPanel != nil { maximizedPanel = nil }
            let wasVisible = store.current.isVisible(p)
            mutateWorkspace { $0.toggle(p) }
            if !wasVisible { focusedPanel = p }
        }
    }

    // MARK: Menu

    @objc func menuCommand(_ sender: NSMenuItem) {
        guard let c = sender.representedObject as? EditorCommand else { return }
        if Self.keyLog { NSLog("SSKEY menuCommand \(c) event=\(String(describing: NSApp.currentEvent?.type.rawValue))") }
        // A plain-key item (Space, J, X ...) is fired by the key monitor / KeyRouter. The same key down also reaches the
        // menu's key equivalent: running it again toggled Play twice (play, then pause at once). Clicks still run.
        if NSApp.currentEvent?.type == .keyDown, !sender.keyEquivalent.isEmpty,
           !sender.keyEquivalentModifierMask.contains(.command) { return }
        execute(c)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(renameWorkspace(_:)), #selector(deleteWorkspace(_:)): return store.canRenameOrDeleteCurrent
        case #selector(resetLayout(_:)): return store.canResetCurrent
        case #selector(windowPanelItem(_:)):
            if let p = item.representedObject as? PanelID { item.state = store.current.isVisible(p) ? .on : .off }
            // Shift+digit shortcuts must not fire while typing in a field (menus see key equivalents first).
            if NSApp.currentEvent?.type == .keyDown, textResponder != nil || window?.firstResponder is NSTableView { return false }
            return true
        default: break
        }
        guard let c = item.representedObject as? EditorCommand else { return true }
        // Plain-key items (no Command) belong to the KeyRouter; their key equivalent only fires when the router let the event pass.
        if !item.keyEquivalent.isEmpty, !item.keyEquivalentModifierMask.contains(.command) {
            if let tv = window?.firstResponder as? NSTextView, tv.isEditable || tv.isFieldEditor { return false }
            if window?.firstResponder is NSTableView { return false }
        }
        // Typing in a text field: the standard editing commands belong to it.
        if textResponder != nil, [.cut, .copy, .paste, .delete, .deleteProjectItems].contains(c) { return true }
        if ([.copy, .cut, .paste].contains(c) ? effectControlsTakes(c) : effectControlsHasFocus), let enabled = validateInEffectControls(c) { return enabled }
        switch c {
        case .undo:
            item.title = session.undoName.map { "Undo \($0)" } ?? "Undo"
            return session.canUndo || textResponder != nil
        case .redo:
            item.title = session.redoName.map { "Redo \($0)" } ?? "Redo"
            return session.canRedo || textResponder != nil
        case .save: return true
        case _ where (c == .delete || c == .rippleDelete) && effectControlsHasFocus:
            return !panels.effectModel.selection.isEmpty || panels.effectModel.selectedSection.map(panels.effectModel.canRemoveEffect) == true
        default: return Self.isSupported(c)
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    /// Also ends the router deadline timer; safe to call twice.
    func removeKeyMonitor() {
        isTerminating = true
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        deadlineWork?.cancel(); deadlineWork = nil
    }

    /// Returns nil when the event was consumed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        // Nothing while quitting or while any modal (Save alert, open/save panel) runs: its window is not ours and
        // the panels may be mid-teardown (crash: objc_retain on a freed first responder during applicationShouldTerminate).
        guard !isTerminating, NSApp.modalWindow == nil, NSApp.keyWindow?.sheetParent == nil,
              let window, event.window === window, window.attachedSheet == nil, panels != nil else { return event }
        if event.type == .leftMouseDown {
            if let p = panels.panel(containing: window.contentView?.hitTest(event.locationInWindow)) { focusedPanel = p }
            return event
        }
        // Typing: only a text view that can really be edited keeps its keys. A selectable label's field editor
        // (isFieldEditor but not editable) must not swallow Space/J/K/L: that was the "Space does nothing" regression.
        if let tv = window.firstResponder as? NSTextView, tv.isEditable { return event }
        guard let ke = KeyMapping.keyEvent(from: event) else { return event }
        // Command shortcuts belong to the menus (key equivalents).
        if ke.modifiers.contains(.command) { return event }
        // Lists keep their arrow and delete keys.
        if window.firstResponder is NSTableView, [Key.up, .down, .left, .right, .delete].contains(ke.key) { return event }
        // Consume every key the router knows, also auto-repeats and key ups it turns into no action: an unconsumed
        // key down travels to NSWindow and plays the error beep.
        let consumed = router.consumes(ke)
        let actions = router.handle(ke)
        scheduleRouterDeadline()
        guard !actions.isEmpty else { return consumed ? nil : event }
        if Self.keyLog { NSLog("SSKEY \(ke.key) -> \(actions)") }
        run(actions)
        return nil
    }

    private static let keyLog = ProcessInfo.processInfo.environment["SS_KEYLOG"] == "1"

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
