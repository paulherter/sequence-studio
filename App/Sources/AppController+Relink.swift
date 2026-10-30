import AppKit
import SQEditorUI
import SQCore

/// Offline media after opening a project: the project opens at once, files are looked for in the background (old
/// folders, the same folder on other volumes, the project folder, remembered folders) and a status chip offers the
/// reconnect in one click. File > Relink Media… opens `RelinkSheet` (folders the user picks, remembered in
/// `sq.relink.folders` so later Premiere imports search them too). Proxies and subclips follow the media IDs.
extension AppController {
    static let relinkFoldersKey = "sq.relink.folders"

    /// Folders chosen with Locate, newest first, only those that still exist (at most 10).
    var rememberedRelinkFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.relinkFoldersKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func rememberRelinkFolder(_ url: URL) {
        var list = UserDefaults.standard.stringArray(forKey: Self.relinkFoldersKey) ?? []
        list.removeAll { $0 == url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(10)), forKey: Self.relinkFoldersKey)
    }

    /// Never modal: finds the files in the background and shows the chip; nothing is offered when nothing is found
    /// (File > Relink Media… still works).
    func offerRelinkIfNeeded() {
        shell.statusBar.setRelinkOffer(nil)
        let total = session.missingMedia.count
        guard total > 0 else { return }
        let folder = session.fileURL?.deletingLastPathComponent()
        let extra = rememberedRelinkFolders
        Task { [weak self] in
            guard let self else { return }
            let plan = await self.session.relinkOffer(projectFolder: folder, extraFolders: extra)
            guard !plan.isEmpty else { return }
            let text = plan.count == total ? "Found \(total) offline files · Reconnect"
                                           : "Found \(plan.count) of \(total) offline files · Reconnect"
            self.shell.statusBar.onRelinkOfferClicked = { [weak self] in
                guard let self else { return }
                let n = self.session.applyRelinkOffer(plan)
                self.shell.statusBar.setRelinkOffer(nil)
                if n > 0 { self.shell.statusBar.flash(SQL10n.plural(n, one: "Reconnected %@ media file.", other: "Reconnected %@ media files."), seconds: 8) }
            }
            self.shell.statusBar.setRelinkOffer(text)
        }
    }

    /// Library health line > Fix > Reconnect: pick one found file or folder, score every offline item against what is
    /// around it, and show the checklist. Nothing is linked until the user confirms.
    func reconnectMedia() {
        let missing = session.missingMedia
        guard !missing.isEmpty else { shell.statusBar.flash("All media is online.", seconds: 3); return }
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose one file or folder you found. SQ looks around it for the other missing media."
        panel.prompt = "Search"
        let old = URL(fileURLWithPath: missing[0].path).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: old.path) { panel.directoryURL = old }
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = panel.url else { return }
                self.rememberRelinkFolder(url.hasDirectoryPath ? url : url.deletingLastPathComponent())
                self.shell.statusBar.flash("Searching…", seconds: 60)
                Task { [weak self] in
                    guard let self else { return }
                    let result = await self.session.proposeReconnect(from: url)
                    self.shell.statusBar.flash("", seconds: 0)
                    guard !result.proposals.isEmpty else {
                        self.shell.statusBar.flash("No matching files found around that location.", seconds: 6)
                        return
                    }
                    let names = Dictionary(missing.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                    ReconnectSheet.present(result: result, total: missing.count, names: names, over: window) { [weak self] picked in
                        guard let self else { return }
                        let n = self.session.applyReconnect(picked)
                        for p in picked {
                            self.panels.waveforms.invalidate(p.mediaID); self.panels.projectView.forgetThumbnail(p.mediaID)
                        }
                        self.panels.projectModel.scheduleOfflineRefresh()
                        self.shell.statusBar.setRelinkOffer(nil)
                        if n > 0 { self.shell.statusBar.flash(SQL10n.plural(n, one: "Reconnected %@ media file.", other: "Reconnected %@ media files."), seconds: 8) }
                    }
                }
            }
        }
    }

    /// File > Relink Media…: any time, not only at open.
    @objc func relinkMediaItem(_ sender: Any?) {
        guard !session.missingMedia.isEmpty else { shell.statusBar.flash("All media is online.", seconds: 3); return }
        guard let window else { return }
        RelinkSheet.present(session: session, over: window,
                            onFolderChosen: { [weak self] url in self?.rememberRelinkFolder(url) },
                            onClose: { [weak self] found, total in
                                guard let self, found > 0 else { return }
                                self.shell.statusBar.setRelinkOffer(nil)
                                self.shell.statusBar.flash(found == total ? SQL10n.plural(found, one: "Reconnected %@ media file.", other: "Reconnected %@ media files.")
                                                           : SQL10n.format("Reconnected %@ of %@ media files.", String(found), String(total)), seconds: 8)
                            })
    }
}
