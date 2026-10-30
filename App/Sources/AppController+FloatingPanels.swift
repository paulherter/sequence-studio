import AppKit
import SQEditorUI

/// Floating panels: a dock panel popped out into its own SQ window (second display editing). The layout tree is not
/// touched: a floating panel only counts as hidden while it floats (`applyWorkspace` hides it in the copy it hands to
/// the host), so docking it back restores its exact dock position. State is per workspace (`FloatingPanelState`).
extension AppController {
    var floatingKey: String { FloatingPanelState.key(page: store.page, editName: store.editName) }

    func isFloating(_ p: PanelID) -> Bool { floatingPanels.contains(p) }

    /// Panels floating in the workspace on screen.
    var floatingPanels: Set<PanelID> {
        RenderPanels.isRequested ? [] : floatingState.panels(for: floatingKey)
    }

    /// Pops a panel out. Its window starts at the dock size, offset from the dock position.
    func floatPanel(_ p: PanelID, at dropPoint: CGPoint? = nil) {
        guard PanelID.dockable.contains(p), !isFloating(p), !RenderPanels.isRequested else { return }
        let bar = Double(SQFloatingPanel.titleBarHeight)
        var frame: CGRect
        if let dropPoint {
            // Dragged out of the dock: the window opens where the tab was released.
            frame = FloatingPanelState.tearOffFrame(for: p, at: dropPoint, titleBar: bar).rect
            frame = FloatingPanelState.clamp(frame, screens: NSScreen.screens.map(\.visibleFrame), titleBar: bar)
        } else {
            let view = panels.view(for: p)
            var current = CGRect(x: 0, y: 0, width: 520, height: 360)
            if let w = view.window, view.superview != nil {
                current = w.convertToScreen(view.convert(view.bounds, to: nil))
            }
            frame = FloatingPanelState.defaultFrame(for: p, current: current).rect
            frame.size.height += bar
            frame.origin.y -= bar
        }
        floatingState.float(p, key: floatingKey, frame: FloatingPanelFrame(frame))
        if maximizedPanel == p { maximizedPanel = nil }
        saveFloatingState()
        applyWorkspace()
        floatingWindows[p]?.bringToFront()
        focusedPanel = p
    }

    /// Back into the layout, at the position it left.
    func dockFloatingPanel(_ p: PanelID) {
        guard isFloating(p) else { return }
        floatingState.dock(p, key: floatingKey)
        saveFloatingState()
        applyWorkspace()
        focusedPanel = p
    }

    /// Close Panel of a floating panel: not floating any more and hidden in the layout, like a docked one.
    func closeFloatingPanel(_ p: PanelID) {
        floatingState.dock(p, key: floatingKey)
        saveFloatingState()
        closePanel(p)
    }

    /// Brings the floating windows of the workspace on screen in line with the state: opens missing ones, closes the
    /// ones of another workspace or a docked panel. Runs after the host rebuilt the dock (it takes the views back first).
    func syncFloatingWindows() {
        let want = floatingPanels
        for (p, w) in floatingWindows where !want.contains(p) {
            w.close()
            floatingWindows[p] = nil
        }
        let key = floatingKey
        let screens = NSScreen.screens.map(\.visibleFrame)
        for p in want where floatingWindows[p] == nil {
            guard let saved = floatingState.frame(of: p, key: key) else { continue }
            let frame = FloatingPanelState.clamp(saved.rect, screens: screens, titleBar: SQFloatingPanel.titleBarHeight)
            let w = FloatingPanelWindow(panel: p, title: EditorCommand.localizedPanelTitle(p), content: panels.view(for: p))
            w.onDock = { [weak self] in self?.dockFloatingPanel(p) }
            w.onClose = { [weak self] in self?.closeFloatingPanel(p) }
            w.onActivate = { [weak self] in self?.focusedPanel = p }
            w.onFrameChange = { [weak self] f in
                guard let self else { return }
                self.floatingState.setFrame(FloatingPanelFrame(f), of: p, key: self.floatingKey)
                self.saveFloatingState()
            }
            floatingWindows[p] = w
            w.show(frame: frame)
        }
    }

    /// The floating panel whose window is under the pointer (they sit above the main window), if any.
    func floatingPanelUnderMouse() -> PanelID? {
        let m = NSEvent.mouseLocation
        return floatingPanels.first { floatingWindows[$0]?.window?.frame.contains(m) == true }
    }

    /// Maximize of a floating panel fills its screen's visible area; again restores the previous frame.
    func toggleFloatingZoom(_ p: PanelID) {
        guard let w = floatingWindows[p] else { return }
        w.toggleZoom()
        w.bringToFront()
        focusedPanel = p
    }

    func saveFloatingState() {
        if RenderPanels.isRequested { return }
        saveFloatingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { try? self?.floatingState.save() } }
        saveFloatingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
