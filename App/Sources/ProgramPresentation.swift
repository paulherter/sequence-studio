import AppKit
import SQCore
import SQEditorSession
import SQMonitorUI
import SQRender
import SQUIKit

/// Program monitor Full Screen: a borderless window over the screen showing only the picture. The engine presents into
/// the window's layer while it is open and goes back to the panel's layer on exit. Keys keep working through the app's
/// key monitor (plain playback keys); Esc leaves.
@MainActor
final class ProgramPresentation {
    private final class PresentationWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        // The app's key monitor handles keys first; whatever it passes on must not beep.
        override func keyDown(with event: NSEvent) {}
        override func keyUp(with event: NSEvent) {}
    }

    let window: NSWindow
    private let viewer = ViewerView()
    private let engine: any ProgramEngine
    private let restore: () -> Void

    /// `restore` runs on exit (re-attach the panel's layer and re-apply its zoom).
    init(engine: any ProgramEngine, on screen: NSScreen, restore: @escaping () -> Void) {
        self.engine = engine
        self.restore = restore
        let w = PresentationWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .mainMenu + 1
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.Colors.monitorBackdrop
        w.hasShadow = false
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window = w
        viewer.drivesLayer = false
        viewer.frame = NSRect(origin: .zero, size: screen.frame.size)
        viewer.autoresizingMask = [.width, .height]
        w.contentView = viewer
        viewer.onResize = { [weak engine] in engine?.redraw() }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        engine.viewerZoom = .fit
        engine.attach(viewer.metalLayer)
        engine.redraw()
        _ = SQToast.show("Press Esc to exit full screen", in: viewer)
    }

    func close() {
        window.orderOut(nil)
        restore()
    }
}

extension AppController {
    func enterProgramPresentation() {
        guard presentation == nil, panels.monitorModel.hasSequence else { return }
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let p = ProgramPresentation(engine: session.engine, on: screen) { [weak self] in
            guard let self else { return }
            session.engine.attach(panels.viewer.metalLayer)
            panels.monitorModel.setZoom(panels.monitorModel.zoom)    // re-applies the panel's zoom to engine and surface
            session.engine.redraw()
            window?.makeKeyAndOrderFront(nil)
        }
        presentation = p
        p.show()
    }

    func exitProgramPresentation() {
        guard let p = presentation else { return }
        presentation = nil
        p.close()
    }
}
