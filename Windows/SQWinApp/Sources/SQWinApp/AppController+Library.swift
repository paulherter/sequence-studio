import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell

/// The Library and Effects panels on the dock (SQAppShell `LibraryHost`, `EffectsHost`): tiles from the timeline's FFmpeg
/// thumbnail atlas, drags onto `timelinePanel`, placed media refreshes the engine's media table.
extension AppController {
    func makeLibraryHost() -> LibraryHost {
        let h = LibraryHost(session: session, menus: shell.menuBar.controller, shell: shell)
        h.withTimeline = { [weak self] change in if let self { change(&timelinePanel) } }
        h.modifiers = keyModifiers
        h.onPlaced = { [weak self] in self?.libraryPlaced() }
        h.poster = { [paths] url in
            winTimelineMedia?.picture(media: paths.id(forPath: url.path), at: nil).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        return h
    }

    func makeEffectsHost() -> EffectsHost {
        let h = EffectsHost(session: session, menus: shell.menuBar.controller, shell: shell, library: library.model)
        h.withTimeline = { [weak self] change in if let self { change(&timelinePanel) } }
        h.modifiers = keyModifiers
        h.onPlaced = { [weak self] in self?.mediaChanged() }
        return h
    }

    func libraryPlaced() {
        engine.setMedia(session.project.media)
        paths.set(session.project)
        mediaChanged()
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
