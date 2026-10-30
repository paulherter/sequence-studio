import AppKit
import AVFoundation
import ImageIO
import SQCore
import SQEditorSession
import SQEditorUI

/// Start window: Recents, New (9:16 / 16:9 / Variants) and Templates.
extension AppController {
    private var startView: StartWindowView {
        StartWindowView(
            templates: templateStore.all,
            recents: recentProjects.entries,
            missing: missingRecents,
            infos: recentInfos,
            posters: recentPosters,
            onNewProject: { [weak self] in Task { await self?.createProjectFolder() } },
            onImportPremiere: { [weak self] in self?.importPremiereProject(nil) },
            onCreate: { [weak self] t in self?.quickCreate(t) },
            onOpen: { [weak self] url in Task { await self?.openProject(at: url) } },
            onOpenOther: { [weak self] in self?.openProject(nil) },
            onDeleteTemplate: { [weak self] t in self?.templateStore.delete(t); self?.refreshStartWindow() },
            onRenameTemplate: { [weak self] t in self?.renameTemplate(t) },
            onLocateRecent: { [weak self] url in self?.locateRecent(url) },
            onRemoveRecent: { [weak self] url in
                self?.recentProjects.remove(path: url.standardizedFileURL.path)
                self?.recentProjects.save()
                self?.refreshStartWindow()
            },
            onClearRecents: { [weak self] in self?.clearRecents(nil); self?.refreshStartWindow() },
            onSaveTemplate: session.isEmptyUntitled ? nil : { [weak self] in self?.saveSequenceAsTemplate(nil) },
            reopenLast: Self.reopenLastOnLaunch,
            onSetReopenLast: { [weak self] on in
                UserDefaults.standard.set(on, forKey: Self.reopenLastKey)
                self?.refreshStartWindow()
            },
            supportEntries: SupportLinks.entries,
            onSupportEntry: { [weak self] e in
                switch e {
                case .support: self?.openSupportPage(nil)
                case .discord: self?.openDiscord(nil)
                case .github: self?.openGitHub(nil)
                }
            },
            onFeedback: { [weak self] in self?.sendFeedback(nil) },
            onKeyboardMap: { [weak self] in self?.showShortcutsItem(nil) })
    }

    static let reopenLastKey = "sq.reopenLastOnLaunch"
    /// Default off: the start window with the newest project highlighted is one click away already.
    static var reopenLastOnLaunch: Bool { UserDefaults.standard.bool(forKey: reopenLastKey) }

    @objc func showStartWindowItem(_ sender: Any?) { showStartWindow() }

    /// True once a real project (saved, edited or with content) is open in the editor.
    var hasRealProject: Bool { !session.isEmptyUntitled }

    /// The start window is the key window: only commands that start or open a project (and app-level ones) work.
    var chooserShown: Bool { startWindow?.window.isKeyWindow == true }

    /// The start screen in its own window. Without a real project the editor window goes away meanwhile (never an
    /// empty editor); with one (Window > Start Window) the editor stays where it is.
    func showStartWindow() {
        if let s = startWindow {
            s.content.refresh(startView)
        } else {
            let s = StartWindowController(rootView: startView)
            s.onUserClose = { [weak self] in self?.startWindowClosedByUser() }
            s.content.onEscape = { [weak self] in
                guard let self, StartOverlayPolicy.escapeCloses(hasRealProject: self.hasRealProject) else { return }
                self.closeStartWindow()
            }
            startWindow = s
        }
        // Show first, hide the editor after: hiding the only visible window first made AppKit quit the app
        // (last window closed) before the start window was up.
        startWindow?.show()
        if !hasRealProject, window.sqAttachedSheet == nil { window.orderOut(nil) }
        pruneRecentsInBackground()
    }

    /// Red button on the start window: back to the open project, or quit when there is none.
    private func startWindowClosedByUser() {
        if hasRealProject { showEditorWindow() } else { NSApp.terminate(nil) }
    }

    /// Marks recents whose file is gone (grayed, "Locate…" or Remove; nothing is dropped silently). The existence checks
    /// run off the main thread (network volumes can stall); the window refreshes with the result.
    func pruneRecentsInBackground() {
        let recents = recentProjects
        Task {
            let missing = await Task.detached(priority: .utility) { recents.missing { FileManager.default.fileExists(atPath: $0) } }.value
            let gone = Set(missing)
            let paths = recents.entries.map(\.path).filter { !gone.contains($0) }
            let infos = await Task.detached(priority: .utility) { StartProjectInfo.read(paths) }.value
            let have = Set(recentPosters.keys)
            let need = infos.filter { !$0.value.mediaMissing && $0.value.posterPath != nil && !have.contains($0.key) }
            let stills = await Task.detached(priority: .utility) { StartPosterLoader.load(need) }.value
            guard gone != missingRecents || infos != recentInfos || !stills.isEmpty else { return }
            missingRecents = gone
            recentInfos = infos
            for (k, v) in stills { recentPosters[k] = v.image }
            refreshStartWindow()
        }
    }

    /// "Locate…" on a missing recent: pick the project file's new place; the entry moves there and the project opens.
    func locateRecent(_ url: URL) {
        let panel = NSOpenPanel()
        panel.message = "Locate \(url.lastPathComponent)"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = url.deletingLastPathComponent().deletingLastPathComponent()
        guard panel.runModal() == .OK, let new = panel.url else { return }
        recentProjects.relocate(path: url.standardizedFileURL.path, to: new)
        recentProjects.save()
        missingRecents.remove(url.standardizedFileURL.path)
        refreshStartWindow()
        Task { await openProject(at: new) }
    }

    func refreshStartWindow() { startWindow?.content.refresh(startView) }

    /// A project was created, opened or imported: the start window goes, the editor shows in its own window.
    func closeStartWindow() {
        startWindow?.hide()
        showEditorWindow()
    }

    /// Brings the editor window up (its remembered frame; first time nearly the whole screen).
    func showEditorWindow() {
        guard !RenderPanels.isRequested, let w = window else { return }
        if !w.isVisible { SplashHandoff.present(w) } else { w.makeKey() }
        if w.firstResponder === w { w.makeFirstResponder(panels?.timelineView) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.presentWelcomeIfNeeded()
            self?.checkForUpdatesAtLaunch()
        }
    }

    /// Built-in cards: one click, the project is created in `~/Movies/Sequence Studio/<Name>` and opened ("Untitled",
    /// "Untitled 2", ...). A user template card asks only for the video name (Return creates the folder).
    /// File > New Project asks for name and place instead.
    func quickCreate(_ template: ProjectTemplate) {
        Task {
            guard await confirmDiscardChanges() else { return }
            // Folder lookup and free-name search touch the disk: off the main thread.
            let (parent, suggested) = await Task.detached(priority: .userInitiated) { () -> (URL, String) in
                // Settings > Media > Projects Folder (default ~/Movies/Sequence Studio).
                let parent = StorageLocations.load().projectsRoot
                try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                return (parent, Self.freeProjectName("Untitled", in: parent))
            }.value
            var name = suggested
            if template.id.hasPrefix("user-") {
                guard let typed = askVideoName(suggested: suggested, template: template) else { return }
                name = await Task.detached(priority: .userInitiated) { Self.freeProjectName(typed, in: parent) }.value
            }
            await createProject(template: template, name: name, in: parent, mode: nil)
        }
    }

    /// The one question of the start flow: the video's name. nil = canceled.
    func askVideoName(suggested: String, template: ProjectTemplate) -> String? {
        let field = SQDialog.makeField(suggested, placeholder: "Video name", width: 300)
        let alert = SQDialog()
        alert.messageText = "Name this video"
        alert.informativeText = SQL10n.format("From “%@”. Its folder is created in Movies/Sequence Studio.", template.name)
        alert.accessoryView = field
        alert.addButton("Create")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        guard alert.runModal() == .first else { return nil }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? suggested : typed
    }

    nonisolated static func freeProjectName(_ base: String, in parent: URL) -> String {
        MediaManagement.freeFolderName(base) { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }
    }

    func renameTemplate(_ t: ProjectTemplate) {
        let field = SQDialog.makeField(t.name, width: 260)
        let alert = SQDialog()
        alert.messageText = "Rename Template"
        alert.accessoryView = field
        alert.addButton("Rename")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        guard alert.runModal() == .first else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, typed != t.name else { return }
        do { try templateStore.rename(t, to: typed); refreshStartWindow() } catch { presentError("Could not rename the template", error) }
    }

    /// File > New Sequence from Template…: pick a template (built-in or saved), name the sequence; it opens next to the others.
    @objc func newSequenceFromTemplate(_ sender: Any?) {
        let templates = templateStore.all
        let name = SQDialog.makeField(session.suggestedSequenceName, width: nil)
        name.frame = NSRect(x: 0, y: 32, width: 300, height: Theme.Row.controlLarge)
        let tpl = SQPopup(frame: NSRect(x: 0, y: 0, width: 300, height: Theme.Row.controlLarge), pullsDown: false)
        tpl.boxHeight = Theme.Row.controlLarge
        for t in templates { tpl.addItem(withTitle: "\(t.name) (\(t.format.width) × \(t.format.height))") }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        box.addSubview(name); box.addSubview(tpl)
        let alert = SQDialog()
        alert.messageText = "New Sequence from Template"
        alert.accessoryView = box
        alert.addButton("Create")
        alert.addButton("Cancel")
        alert.initialFirstResponder = name
        guard alert.runModal() == .first, templates.indices.contains(tpl.indexOfSelectedItem) else { return }
        session.addSequence(from: templates[tpl.indexOfSelectedItem], name: name.stringValue)
    }

    /// Saves the active sequence's format, track counts and variants as a template for new projects.
    @objc func saveSequenceAsTemplate(_ sender: Any?) {
        guard let tl = session.activeTimeline else { return }
        let field = SQDialog.makeField(tl.name, width: 260)
        let alert = SQDialog()
        alert.messageText = "Save Sequence as Template"
        alert.informativeText = "New projects start with its format, tracks and variants, its titles, emoji and adjustment layers, and this project's Looks. Footage and music are left out."
        alert.accessoryView = field
        alert.addButton("Save")
        alert.addButton("Cancel")
        alert.initialFirstResponder = field
        guard alert.runModal() == .first else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        let name = ProjectTemplate.freeName(typed, taken: templateStore.all.map(\.name))
        do { try templateStore.saveTemplate(from: tl, name: name, styleKit: session.project.styleKit); refreshStartWindow() } catch { presentError("Could not save the template", error) }
    }
}

/// First-frame stills for the start cards, decoded off the main thread at card size.
struct StartPoster: @unchecked Sendable { let image: CGImage }

enum StartPosterLoader {
    nonisolated static func load(_ infos: [String: StartProjectInfo]) -> [String: StartPoster] {
        var out: [String: StartPoster] = [:]
        for (key, info) in infos {
            guard let path = info.posterPath else { continue }
            let url = URL(fileURLWithPath: path)
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 640, height: 640)
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: max(info.posterSeconds, 0), preferredTimescale: 600), actualTime: nil) {
                out[key] = StartPoster(image: cg)
            } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                            kCGImageSourceThumbnailMaxPixelSize: 640,
                                                                            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                out[key] = StartPoster(image: cg)
            }
        }
        return out
    }
}
