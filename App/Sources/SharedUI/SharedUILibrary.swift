import AppKit
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawLibrary
import SQDrawShell
import SQEditorSession

/// The Library and Effects panels of the shared UI (SQAppShell `LibraryHost`, `EffectsHost`), as on Windows: tiles from
/// the timeline's thumbnail atlas, drags onto `timelinePanel`; placed media reaches `mediaStore` through `session.onChange`.
extension SharedUIController {
    func makeLibraryHost() -> LibraryHost {
        let h = LibraryHost(session: session, menus: shell.menuBar.controller, shell: shell)
        h.withTimeline = { [weak self] change in if let self { change(&timelinePanel) } }
        h.modifiers = { MacKeys.modifiers(flags: NSEvent.modifierFlags.rawValue) }
        h.poster = { [mediaStore] url in
            mediaStore.picture(media: mediaStore.id(forPath: url.path), at: nil).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        wirePreferencesLibrary(h.model)
        return h
    }

    /// Preferences > Media: the Library Folders list and Delete Cache (the Mac `SettingsWindow` media page).
    private func wirePreferencesLibrary(_ model: LibraryPanelModel) {
        shell.libraryFolders = {
            model.folders.map {
                ShellLibraryFolder(id: $0.id, name: $0.folder.displayName,
                                   path: ($0.folder.url.path as NSString).abbreviatingWithTildeInPath, offline: $0.state == .offline)
            }
        }
        shell.addLibraryFolder = { url in
            _ = await model.addFolder(url: url, bookmark: try? url.bookmarkData(options: .withSecurityScope))
        }
        shell.removeLibraryFolder = { id in await model.removeFolder(id) }
        shell.clearCache = { [weak self] in
            let settings = AppSettings.load(from: .standard)
            self?.session.autoProxy?.clearCache()
            let proxies = settings.proxyCacheDirectory.standardizedFileURL
            if let items = try? FileManager.default.contentsOfDirectory(at: settings.effectiveCacheFolder, includingPropertiesForKeys: nil) {
                for f in items where f.standardizedFileURL != proxies { try? FileManager.default.removeItem(at: f) }
            }
        }
    }

    func makeEffectsHost() -> EffectsHost {
        let h = EffectsHost(session: session, menus: shell.menuBar.controller, shell: shell, library: library.model)
        h.withTimeline = { [weak self] change in if let self { change(&timelinePanel) } }
        h.modifiers = { MacKeys.modifiers(flags: NSEvent.modifierFlags.rawValue) }
        return h
    }

    func drawLibraryPanels(_ c: inout Canvas, scale: Float, theme: DrawTheme) {
        library.layout(shell.dock.contentFrame(.library), scale: scale); library.draw(&c, theme: theme)
        effects.layout(shell.dock.contentFrame(.effects), scale: scale); effects.draw(&c, theme: theme)
    }

    func drawLibraryDragLabels(_ c: inout Canvas, scale: Float, theme: DrawTheme) {
        library.drawDragLabel(&c, scale: scale, theme: theme)
        effects.drawDragLabel(&c, scale: scale, theme: theme)
    }

    func handleLibraryPanels(_ e: InputEvent, scale: Float) -> Bool {
        library.handle(e, scale: scale) || effects.handle(e, scale: scale)
    }
}
