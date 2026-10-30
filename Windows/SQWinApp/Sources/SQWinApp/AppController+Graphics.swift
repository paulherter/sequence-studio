import SQAppShell

extension AppController {
    /// The Graphics card's host (SQAppShell `GraphicsHost`) with the Windows template save and the Keystones card's model.
    func makeGraphicsHost() -> GraphicsHost {
        let g = GraphicsHost(session: session, menus: shell.menuBar.controller, shell: shell, inspector: inspector)
        g.onSaveTemplate = { [weak self] in timelineEditors.dialogs?.saveSelectionAsTemplate() }
        g.modifiers = keyModifiers                      // Alt copies while dragging layers
        g.panel.keystones = timelineDrags.keystones     // the text item reads and saves the same ones (the Mac host)
        return g
    }
}
