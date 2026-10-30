import AppKit
import SQAnalysis
import SQCore
import SQEditorSession
import SQEditorUI
import SQMedia
import SQUIKit
import SwiftUI

/// Open, save, recovery and export.
extension AppController {
    @objc func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = "Choose a Sequence Studio or Premiere Pro project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openProject(at: url) }
    }

    /// Matte files whose removal a session before this one decided and never finished (it ended between the
    /// removal and the store's queued delete): deleted once per launch, off the main thread, except what the
    /// project that just arrived refers to (opened, recovered, restored, new, imported) and what the store wrote
    /// or holds unsaved in this launch. Only files the journal lists, only in the matte folder.
    func sweepLeftoverMattes() {
        let store = MagicMatteStore.shared
        let keeping = session.project.magicMatteCacheKeys.union(store.writtenKeys).union(store.unsavedKeys)
        DispatchQueue.global(qos: .utility).async { MatteRemovalJournal.shared.sweepLeftover(keeping: keeping) }
    }

    func openProject(at url: URL) async {
        if ProjectOpenRouting.route(for: url) == .premiereImport {
            pendingOpenRequest = false
            await importPremiereProject(at: url)
            return
        }
        guard await confirmDiscardChanges() else { return }
        pendingOpenRequest = false
        // A mask track of the project that goes away ends here: its frames are saved, the project is not written.
        MaskTrackActivity.shared.stop(owner: session, reason: "another project opens")
        SQLog.info("project open start: \(url.path)")
        do { let salvage = try await session.open(url: url); SQLog.info("project open ok: \(url.lastPathComponent)"); sweepLeftoverMattes(); applyRememberedQuality(); closeStartWindow(); noteRecent(url); autoPickWorkspace(); await mediaPlacement.projectOpened(); offerRelinkIfNeeded()
            if let salvage { presentMessage(ProjectSalvageNotice.title, ProjectSalvageNotice.detail(fileName: url.lastPathComponent, report: salvage)) }
        } catch {
            NSLog("Open failed for %@: %@", url.path, String(describing: error))
            if let m = ProjectOpenRouting.message(for: error, fileName: url.lastPathComponent) {
                presentMessage(m.title, m.detail)
            } else {
                presentError("Could not open “\(url.lastPathComponent)”", error)
            }
            if !hasRealProject { showStartWindow() }   // e.g. the last project failed to reopen at launch
        }
    }

    /// The Edit workspace of the project that just opened: "Editing – PC", unless the user picked another one for this
    /// project himself (`WorkspaceChoices`). Runs for every open, new, imported and recovered project and at launch,
    /// with or without a sequence (the store keeps one global name, so a workspace picked in another project or left
    /// by an earlier version would otherwise show).
    func autoPickWorkspace(recoveredFrom: URL? = nil) {
        if RenderPanels.isRequested { return }
        recoveredProjectPath = recoveredFrom?.path
        workspaceChoices.forgetUntitled()      // a pick made in an unsaved project ends with that project
        let name = workspaceChoices.name(project: session.fileURL?.path ?? recoveredProjectPath, available: store.library.all.map(\.name))
        guard name != store.editName, store.selectEdit(name) else { return }
        maximizedPanel = nil
        scheduleWorkspaceSave()
        applyWorkspace()
    }

    /// The user picked the workspace on screen by hand: remembered for the open project.
    func noteWorkspaceChoice() {
        if RenderPanels.isRequested { return }
        workspaceChoices.choose(store.editName, project: session.fileURL?.path ?? recoveredProjectPath)
        UserDefaults.standard.set(workspaceChoices.byProject, forKey: WorkspaceChoices.defaultsKey)
    }

    /// Finder double-click, drop on the Dock icon, "Open With": opens the first project (`.sqproj`, or a legacy `.ssproj`).
    func application(_ sender: NSApplication, open urls: [URL]) {
        let packs = urls.filter(LibraryPackFlow.isPack)      // .sqpack: preset packs go to the Library
        if !packs.isEmpty, panels != nil { LibraryPackFlow.importFiles(packs, model: panels.libraryModel, window: window) }
        guard let url = urls.first(where: { ProjectOpenRouting.route(for: $0) != .unsupported }) else { return }
        pendingOpenRequest = true         // may arrive before launch finished: no start window then
        Task { await openProject(at: url) }
    }

    // MARK: Project folder and media management

    /// New Project: the sheet asks for a name, format, import behavior and a location; creates `<Name>/<Name>.sqproj` and `<Name>/Files/`.
    /// Nothing existing is overwritten: a folder with that name already there ends the flow with a message.
    func createProjectFolder(preferred: ProjectTemplate? = nil) async {
        guard await confirmDiscardChanges() else { return }
        // From the run loop, not from this task's main-queue job: a modal session started there would hold the main queue
        // (and with it every `DispatchQueue.main.async` and `Task` inside the dialog) until the dialog closes.
        let templates = templateStore.all
        let picked: NewProjectSheet.Answer? = await withCheckedContinuation { done in
            SQAfterEvent.run { done.resume(returning: NewProjectSheet.run(templates: templates, preferred: preferred)) }
        }
        guard let answer = picked else { return }
        let parent = answer.location
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) } catch {
            presentError("Could not create the location folder", error); return
        }
        await createProject(template: answer.template, name: answer.name, in: parent, mode: answer.mode, editMode: answer.editMode)
    }

    /// Creates `<parent>/<Name>/<Name>.sqproj` and `Files/` from a template and opens it. Nothing existing is overwritten.
    func createProject(template: ProjectTemplate, name: String, in parent: URL, mode: OutsideMediaMode?, editMode: TimelineEditMode? = nil) async {
        let projectName = MediaManagement.sanitized(name)
        let layout = MediaManagement.layout(name: projectName, in: parent)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: layout.folder.path) else {
            presentError("A folder named “\(projectName)” already exists there",
                         NSError(domain: "SQ", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose another name or location. Nothing was changed."]))
            return
        }
        do {
            try fm.createDirectory(at: layout.filesFolder, withIntermediateDirectories: true)
            var p = template.makeProject(name: projectName)
            if let editMode, !p.timelines.isEmpty { p.timelines[0].editMode = editMode }
            // The Start window passes no mode: same as the sheet with the default policy (watching on, mode from Settings).
            p.mediaPolicy = MediaPolicy(outside: mode, watchFolder: MediaSettings.defaults.watchFolder)
            session.newProject(p)
            sweepLeftoverMattes()
            applyRememberedQuality()
            try await session.saveAs(to: layout.projectFile)
            closeStartWindow()
            noteRecent(layout.projectFile)
            autoPickWorkspace()
            mediaPlacement.restartWatching()
        } catch where reportedSilently(error) {
        } catch { presentError("Could not create the project", error) }
    }

    /// Wires the Project panel's import to the project's `Files/` folder and adds the menu items. Call once at launch.
    func installMediaManagement() {
        mediaPlacement.owner = self
        mediaMenu.owner = self
        panels.projectModel.onImported = { [weak self] files, pointer in self?.mediaPlacement.imported(files, pointer: pointer) }
        panels.projectModel.amend = { [weak self] change in _ = self?.session.amendProject(change) }
        panels.projectModel.projectFolder = { [weak self] in MediaManagement.projectFolder(forProjectAt: self?.session.fileURL) }
        session.mediaPolicyDefaults = { MediaSettings.defaults }
        session.onSaved = { [weak self] saved in self?.mediaPlacement.saved(saved) }
        session.onProjectReplaced = { [weak self] in self?.mediaPlacement.cancelCopies() }   // open, new, import, revert, close
        // Footage re-exported or unplugged while the project is open, volumes mounting, the Mac sleeping.
        session.onMediaFilesChanged = { [weak self] ids in self?.panels.mediaFilesChanged(ids) }
        session.startWatchingMediaFiles()
        startGrowingFilePoll()
        shell.statusBar.onOutsideClicked = { [weak self] in self?.collectFiles(nil) }
        panels.projectView.onHealthAction = { [weak self] action in
            switch action {
            case .collect: self?.collectFiles(nil)
            case .reconnect: self?.reconnectMedia()
            case .showMissing: break
            }
        }
        guard let file = NSApp.mainMenu?.items.first(where: { $0.title == SQL10n.string("File") })?.submenu else { return }
        file.addItem(.separator())
        let collect = NSMenuItem(title: SQL10n.string("Collect Files into Project Folder"), action: #selector(collectFiles(_:)), keyEquivalent: "")
        collect.target = self
        file.addItem(collect)
        let parent = NSMenuItem(title: SQL10n.string("Media Management"), action: nil, keyEquivalent: "")
        let sub = NSMenu(title: SQL10n.string("Media Management"))
        mediaMenu.items.forEach(sub.addItem)
        parent.submenu = sub
        file.addItem(parent)
    }

    /// Copies all used media that is outside the project's Files folder into it and re-points the project at the copies:
    /// not an undo step. Originals are never touched.
    @objc func collectFiles(_ sender: Any?) {
        guard let url = session.fileURL else {
            presentError("Save the project first", NSError(domain: "SQ", code: 2, userInfo: [NSLocalizedDescriptionKey: "Collect Files needs a project folder. Use File > Save As… or create the project with New Project."]))
            return
        }
        let folder = MediaManagement.importedFolder(forProjectAt: url)
        let media = session.project.media
        shell.statusBar.flash("Collecting files…", seconds: 120)
        mediaPlacement.setPaused(true)                       // the watcher waits for the whole run
        let projectID = session.project.id, epoch = mediaPlacement.epoch
        Task {
            defer { mediaPlacement.setPaused(false) }
            let outcome = await Task.detached(priority: .userInitiated) { MediaFileOps.collect(media: media, into: folder) }.value
            guard session.project.id == projectID, mediaPlacement.epoch == epoch else { return }   // another project meanwhile
            if !outcome.done.isEmpty {
                mediaPlacement.applyRelinks(Dictionary(outcome.done.map { ($0.id, $0.destination) }, uniquingKeysWith: { a, _ in a }))
            }
            mediaPlacement.projectChanged()
            let n = Set(outcome.done.map(\.source)).count
            shell.statusBar.flash(outcome.failed.isEmpty ? (n == 0 ? "All media is already in the project folder." : "Collected \(n) files into \(folder.lastPathComponent).")
                                  : "Collected \(n) files; could not copy: \(outcome.failed.prefix(3).joined(separator: ", ")). Those stay where they are.", seconds: 8)
        }
    }

    @objc func saveProjectAs(_ sender: Any?) { Task { await saveDocumentAs() } }

    /// Save, or Save As for an untitled project. False when the user canceled or saving failed.
    @discardableResult
    func saveDocument() async -> Bool {
        if session.fileURL != nil {
            SQLog.info("project save start: \(session.fileURL?.path ?? "")")
            do { try await session.save(); SQLog.info("project save ok"); session.fileURL.map(noteRecent); return true } catch { if reportedSilently(error) { return false }; presentError("Could not save", error); return false }
        }
        return await saveDocumentAs()
    }

    @discardableResult
    func saveDocumentAs() async -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.project.name + "." + ProjectFile.fileExtension
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        let ok: Bool = await withCheckedContinuation { c in
            panel.begin { c.resume(returning: $0 == .OK) }
        }
        guard ok, var url = panel.url else { return false }
        if url.pathExtension != ProjectFile.fileExtension { url.appendPathExtension(ProjectFile.fileExtension) }
        SQLog.info("project save as start: \(url.path)")
        // Save As keeps the project's folder watching: a project that watched its folder watches the new one
        // (`restartWatching` below); a project that did not stays unwatched. Save a Copy still never watches.
        do { try await session.saveAs(to: url); SQLog.info("project save as ok"); noteRecent(url); mediaPlacement.restartWatching(); return true } catch {
            if reportedSilently(error) { return false }
            presentError("Could not save", error); return false
        }
    }

    /// Save a Copy: writes the project somewhere as a new document; this window keeps its file and unsaved changes.
    @discardableResult
    func saveDocumentCopy() async -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.project.name + " copy." + ProjectFile.fileExtension
        panel.canCreateDirectories = true
        panel.prompt = "Save a Copy"
        let ok: Bool = await withCheckedContinuation { c in
            panel.begin { c.resume(returning: $0 == .OK) }
        }
        guard ok, var url = panel.url else { return false }
        if url.pathExtension != ProjectFile.fileExtension { url.appendPathExtension(ProjectFile.fileExtension) }
        SQLog.info("project save copy start: \(url.path)")
        do { try await session.saveCopy(to: url); SQLog.info("project save copy ok"); return true } catch {
            if reportedSilently(error) { return false }
            presentError("Could not save a copy", error); return false
        }
    }

    /// The user opened another project while saving: no dialog, one log line.
    private func reportedSilently(_ error: Error) -> Bool {
        guard error as? EditorSession.SaveError == .projectChanged else { return false }
        NSLog("save canceled: another project was opened meanwhile")
        return true
    }

    /// Asks before a document is replaced. True to go on.
    func confirmDiscardChanges() async -> Bool {
        guard session.isDirty else { return true }
        let choice = SaveChangesPrompt.choice(SaveChangesPrompt.makeDialog(documentName: session.displayName, hasFile: session.fileURL != nil).runModal())
        let saved: Bool? = choice == .save ? await saveDocument() : nil
        return SaveChangesPrompt.outcome(choice, saveSucceeded: saved) == .proceed
    }

    func presentMessage(_ title: String, _ detail: String) {
        let alert = SQDialog()
        alert.style = .warning
        alert.messageText = title
        alert.informativeText = detail
        // A sheet only on the visible editor; with only the start window up the dialog is its own window.
        if let w = window, w.isVisible { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    func presentError(_ title: String, _ error: Error) {
        SQLog.error("\(title): \(error.localizedDescription)")
        let alert = SQDialog()
        alert.style = .warning
        alert.messageText = title
        alert.informativeText = SQL10n.errorText(error)
        // A sheet only on the visible editor; with only the start window up the dialog is its own window.
        if let w = window, w.isVisible { alert.beginSheetModal(for: w) } else { alert.runModal() }
    }

    // MARK: Recovery

    static func makeRecoveryDialog(projectName: String, date: Date) -> SQDialog {
        let alert = SQDialog()
        alert.messageText = SQL10n.format("Recover “%@”?", projectName)
        alert.informativeText = SQL10n.format("Sequence Studio did not close cleanly. An autosaved version from %@ is available.",
                                              date.formatted(date: .abbreviated, time: .shortened))
        alert.addButton("Recover")
        alert.addButton("Discard")
        return alert
    }

    /// Writes one crash report per crashed session found at launch (off the main thread). Returns the newest report.
    nonisolated static func writeCrashReports(_ crashed: [CrashedSession], store: AutosaveStore,
                                              reports: CrashReportStore = CrashReportStore()) -> URL? {
        guard !crashed.isEmpty else { return nil }
        let fm = FileManager.default
        SQLog.shared.flush()
        let logFiles = (0..<3).map { SQLog.directory.appendingPathComponent($0 == 0 ? "sq.log" : "sq.\($0).log") }
        let log = CrashReport.logTail(files: logFiles)
        let diag = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let diagFiles = (try? fm.contentsOfDirectory(at: diag, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var newest: URL?
        for session in crashed {
            let project = session.autosave.flatMap { try? store.read($0) }
            let system = diagFiles.filter { $0.lastPathComponent.hasPrefix("Sequence Studio") }
                .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= session.info.started }
                .map(\.lastPathComponent).sorted().last
            let text = CrashReport.render(session: session, project: project, log: log,
                                          appVersion: "\(AppVersion.display) (\(AppVersion.build))",
                                          os: ProcessInfo.processInfo.operatingSystemVersionString, systemReport: system)
            if let url = try? reports.write(text, date: Date()) { newest = url }
        }
        return newest
    }

    /// At launch: crashed sessions get a report, and one with a newer autosave is offered for recovery.
    /// The scan runs off the main thread (it lists every project folder of the Autosave store).
    func offerRecovery() async {
        let store = session.autosaveStore
        let scanner = RecoveryScanner(store: store)
        let (found, report) = await Task.detached(priority: .userInitiated) { () -> ([RecoveryCandidate], URL?) in
            let r = scanner.scanSessions()
            let url = Self.writeCrashReports(r.crashed, store: store)
            scanner.markReported(r.crashed)   // a kept recovery marker must not report the same crash again at the next launch
            return (r.candidates, url)
        }.value
        // Meanwhile the user may have opened something or a sheet is up: the prompt would then interrupt them.
        guard window.sqAttachedSheet == nil, !pendingOpenRequest, session.isEmptyUntitled else { return }
        if let report {
            SQLog.info("crash report written: \(report.lastPathComponent)")
            await presentCrashReport(report)
            guard window.sqAttachedSheet == nil, !pendingOpenRequest, session.isEmptyUntitled else { return }
        }
        guard let candidate = found.first else { return }   // the caller shows the start window
        SQLog.info("recovery offered: \(candidate.projectName)")
        let alert = Self.makeRecoveryDialog(projectName: candidate.projectName, date: candidate.autosave.date)
        let host = recoveryPromptWindow()   // a sheet of the start window: the editor opens only on Recover
        alert.beginSheetModal(for: host) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .first {
                    Task {
                        do { try await self.session.recover(candidate, scanner: scanner); self.sweepLeftoverMattes(); self.autoPickWorkspace(recoveredFrom: candidate.projectURL); self.closeStartWindow() } catch {
                            self.presentError("Could not recover", error)
                            self.showStartWindow()   // never an empty editor window
                        }
                    }
                } else {
                    SQLog.info("recovery discarded")
                    scanner.dismiss(candidate)
                    self.showStartWindow()   // never an empty editor window
                }
            }
        }
    }

    static func makeCrashReportDialog(report: URL) -> (title: String, message: String, options: [String]) {
        ("Sequence Studio quit unexpectedly",
         "A report with the last log lines and a summary of the project (media names only, no file paths) was saved as "
            + report.lastPathComponent + ". Send it with your feedback to help fix the problem.",
         ["Reveal Report", "Copy Report"])
    }

    /// The window a launch-time recovery or crash prompt sits on: the start window (no project is open yet), never the editor.
    func recoveryPromptWindow() -> NSWindow {
        switch StartOverlayPolicy.recoveryPromptHost(hasRealProject: hasRealProject) {
        case .startWindow:
            showStartWindow()
            return startWindow?.window ?? window
        case .editorWindow:
            showEditorWindow()
            return window
        }
    }

    /// Offers the report: reveal it in Finder or copy its text. Returns when the dialog is closed.
    func presentCrashReport(_ report: URL) async {
        let d = Self.makeCrashReportDialog(report: report)
        let host = recoveryPromptWindow()
        let choice: Int? = await withCheckedContinuation { cont in
            SQDialog.choice(d.title, message: d.message, options: d.options, cancel: "Close", in: host) { cont.resume(returning: $0) }
        }
        switch choice {
        case 0: NSWorkspace.shared.activateFileViewerSelecting([report])
        case 1:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString((try? String(contentsOf: report, encoding: .utf8)) ?? "", forType: .string)
        default: break
        }
    }

    // MARK: Export

    func showExport() {
        exports.presentDialog(for: session, on: window)
    }
}

/// File > Close Project, Autosave Versions; Help > Keyboard Shortcuts.
extension AppController {
    @objc func closeProjectItem(_ sender: Any?) {
        guard window.sqAttachedSheet == nil else { return }       // an open export sheet or dialog: finish or cancel it first
        Task {
            guard await confirmDiscardChanges() else { return }
            MaskTrackActivity.shared.stop(owner: session, reason: "its project closes")
            session.closeProject()
            resetPreviewSpeed()
            showStartWindow()
        }
    }

    @objc func showShortcutsItem(_ sender: Any?) { shortcutsWindow.show() }

    func fillAutosaveMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        // Named checkpoints first (bookmark icon), then the timed autosaves; "Latest" marks the newest timed one.
        let all = session.autosaveVersions
        let versions = all.filter { $0.name != nil } + all.filter { $0.name == nil }
        let now = Date()
        let newestPlain = all.first { $0.name == nil }
        for v in versions {
            let title = v.name.map { AutosaveVersionLabel.checkpointTitle(name: $0, date: v.date) }
                ?? AutosaveVersionLabel.title(date: v.date, now: now, isNewest: v == newestPlain)
            let item = NSMenuItem(title: title, action: #selector(restoreAutosaveItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v.url
            if v.name != nil { item.image = SQIcon.bookmarkFilled.image(size: 14) }
            menu.addItem(item)
        }
        if versions.isEmpty {
            let none = NSMenuItem(title: SQL10n.string("No Versions Yet"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    /// File > Project > Save Checkpoint: asks for a name, then keeps the project as it is now until the user deletes it.
    @objc func saveCheckpointItem(_ sender: Any?) {
        guard window.sqAttachedSheet == nil else { return }
        let field = SQDialog.makeField(SQL10n.string("Checkpoint"), width: nil)
        let a = SQDialog()
        a.messageText = SQL10n.string("Save Checkpoint")
        a.informativeText = SQL10n.string("A checkpoint is kept until you remove it; automatic backups never replace it.")
        a.accessoryView = SQDialogForm(rows: [SQDialog.fieldRow(field)])
        a.initialFirstResponder = field
        a.addButton(SQL10n.string("Save"))
        a.addButton("Cancel", role: .cancel)
        guard a.runModal() == .first, AutosaveStore.sanitized(field.stringValue) != nil else { return }
        let name = field.stringValue
        Task {
            if await session.saveCheckpoint(name: name) != nil {
                shell.statusBar.flash(SQL10n.format("Checkpoint “%@” saved.", AutosaveStore.sanitized(name) ?? name), seconds: 4)
            }
        }
    }

    @objc func restoreAutosaveItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL, let v = session.autosaveVersions.first(where: { $0.url == url }) else { return }
        do {
            session.stopPlayback()
            try session.restoreAutosave(v)
            sweepLeftoverMattes()
            shell.statusBar.flash(SQL10n.format("Restored the version from %@. Undo brings back the previous state.", v.date.formatted(date: .omitted, time: .standard)), seconds: 8)
        } catch { presentError("Could not restore this version", error) }
    }
}

extension AppController {
    /// Growing-file timer: one self-rescheduling main-actor task. The session decides per tick whether to look at the disk
    /// (not while playing or exporting, only online files, longer waits while nothing changes) and says when to come back.
    func startGrowingFilePoll() {
        guard growingFilePoll == nil else { return }
        growingFilePoll = Task { @MainActor [weak self] in
            var delay = GrowingFilePolicy.busyInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                let exporting = exports.queueModel.jobs.contains { $0.state == .running || $0.state == .waiting }
                delay = await session.growingFileTick(enabled: settings.refreshGrowingFiles, isExporting: exporting)
            }
        }
    }
}
