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
        h.inspectorDropClip = { [weak self] in self?.inspectorDropClip($0) }
        h.poster = { [mediaStore] url in
            mediaStore.picture(media: mediaStore.id(forPath: url.path), at: nil).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        h.isSequencePlaying = { [weak self] in self.map { !$0.engine.rate.isPaused } ?? false }
        h.previewFrame = { [weak self] in
            guard let self, let size = libraryFrames.size else { return nil }
            return (LibraryPreviewFrames.slot, size)
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
        h.inspectorDropClip = { [weak self] in self?.inspectorDropClip($0) }
        h.graphicsDrop = { [weak self] kinds, p in self?.graphics.dropEffects(kinds, at: p) ?? false }
        h.graphicsDragOver = { [weak self] p in self?.graphics.effectDragOver(at: p) }
        return h
    }

    /// The clip shown in Effect Controls when a Library/Effects drag is released over that card (no transition shown).
    func inspectorDropClip(_ p: CGPoint) -> Clip.ID? {
        guard inspector.frame.contains(p), !inspector.showsTransitionControls else { return nil }
        return inspector.model.clip?.id
    }

    func drawLibraryPanels(_ c: inout Canvas, scale: Float, theme: DrawTheme) {
        library.layout(shell.dock.contentFrame(.library), scale: scale); library.draw(&c, theme: theme)
        effects.layout(shell.dock.contentFrame(.effects), scale: scale); effects.draw(&c, theme: theme)
    }

    func drawLibraryDragLabels(_ c: inout Canvas, scale: Float, theme: DrawTheme) {
        library.drawDragLabel(&c, scale: scale, theme: theme)
        effects.drawDragLabel(&c, scale: scale, theme: theme)
        drawInspectorDropHighlight(&c, scale: scale, theme: theme)
    }

    /// While an effect, preset or keystone is dragged over Effect Controls (a drop there lands on its clip) the card gets an
    /// accent outline.
    func drawInspectorDropHighlight(_ c: inout Canvas, scale: Float, theme: DrawTheme) {
        let k = CGFloat(max(scale, 0.01))
        let dragged = [effects.dragLabel, library.dragLabel].compactMap { $0 }.map { CGPoint(x: CGFloat($0.x) / k, y: CGFloat($0.y) / k) }
            + [keystones.palette.dragPoint].compactMap { $0 }
        guard let p = dragged.first, inspectorDropClip(p) != nil else { return }
        c.stroke(roundedRect: inspector.frame.insetBy(dx: 1, dy: 1), radius: CGFloat(DrawTheme.Radius.small), width: 2, theme.accent)
    }

    func handleLibraryPanels(_ e: InputEvent, scale: Float) -> Bool {
        library.handle(e, scale: scale) || effects.handle(e, scale: scale)
    }
}
