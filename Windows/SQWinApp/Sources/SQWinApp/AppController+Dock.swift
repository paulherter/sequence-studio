import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawEditor
import SQDrawShell
import SQEditorSession
import SQUIKit
import WinSDK

/// The panel dock of the window (`ShellDock`): the saved workspaces place the cards, the hosts draw into them, panels that
/// are not on Windows yet show a placeholder card.
extension AppController {
    /// Panels a Windows host draws; the others get `ShellDock.drawPlaceholder`.
    static let hostedPanels: Set<PanelID> = [.programMonitor, .sourceMonitor, .effectControls, .project, .timeline, .audioMeter, .scopes, .graphics, .text,
                                                .colorInspector, .steps, .colorClips, .library, .effects]

    func configureDock() {
        let d = shell.dock
        d.ownsHeader = { $0 == .programMonitor || $0 == .sourceMonitor }
        d.save = { s in
            do { try s.save() } catch { SQLog.error("workspaces save failed: \(error.localizedDescription)") }
        }
        d.presentMenu = { [weak self] items, p in self?.shell.menuBar.controller.present(items: items, at: p, pointer: p) }
        d.load(WorkspaceStore.load())
        d.focused = .timeline
        projectList.showsTitle = false   // the dock's tab strip names it
        // The panels read `CommandMap.current` for the key text in their menus and tips.
        CommandMap.current = shell.map
        // Window > App Windows > Minimize and Maximize (the Mac performMiniaturize / performZoom).
        let nextAction = shell.onAction
        shell.onAction = { a in
            guard a == .minimize || a == .zoom, let h = GetActiveWindow() else { return nextAction?(a) ?? false }
            ShowWindow(h, a == .minimize ? SW_MINIMIZE : (IsZoomed(h) ? SW_RESTORE : SW_MAXIMIZE))
            return true
        }
        let nextKeys = shell.onKeymapChanged
        shell.onKeymapChanged = { m in CommandMap.current = m; nextKeys?(m) }
    }

    /// Lays the dock out between the top bar and the status bar and returns the screen's cards in pixels.
    func layoutDock(width: Int, height: Int, scale: Float) -> EditorScreen.Slots {
        let d = shell.dock, k = CGFloat(max(scale, 0.01))
        let top = chromeHeight, bottom = CGFloat(DrawTheme.Metrics.statusBar)
        d.measure = TextMeasure(atlas: atlas, scale: scale)
        d.frame = CGRect(x: 0, y: top, width: CGFloat(width) / k, height: max(CGFloat(height) / k - top - bottom, 0))
        d.layout()
        monitors.syncTab(dock: d)
        layoutChrome(width: CGFloat(width) / k)
        meters.showsScopes = d.shows(.scopes)
        func px(_ r: CGRect?) -> DrawRect {
            guard let r else { return .zero }
            return DrawRect(x: Float(r.minX * k), y: Float(r.minY * k), w: Float(r.width * k), h: Float(r.height * k))
        }
        return EditorScreen.Slots(monitor: px(colorPage.monitorCard(monitorCard)), inspector: px(d.contentFrame(.effectControls)),
                                  project: px(d.contentFrame(.project)), timeline: px(d.contentFrame(.timeline)))
    }

    /// The card the monitor host draws in: the Program monitor's, else the Source monitor's.
    // shortcut: one monitor card (one video quad); when Program and Source sit in separate groups the Source group shows a
    // placeholder, upgrade when the window renders two pictures.
    var monitorCard: CGRect? { shell.dock.monitorCard }

    /// The Scopes and audio meter cards.
    func layoutMeters(scale: Float) {
        let d = shell.dock, k = CGFloat(scale)
        func px(_ r: CGRect?) -> DrawRect {
            guard let r else { return .zero }
            return DrawRect(x: Float(r.minX * k), y: Float(r.minY * k), w: Float(r.width * k), h: Float(r.height * k))
        }
        meters.layout(meter: px(d.contentFrame(.audioMeter)), scopes: px(d.contentFrame(.scopes)), scale: scale)
    }

    /// Placeholder cards for the panels Windows does not have yet, and the hidden monitor's card.
    func drawDockPlaceholders(_ c: inout Canvas) {
        let d = shell.dock
        for g in d.groups {
            let hosted = Self.hostedPanels.contains(g.selected)
                && !((g.selected == .sourceMonitor || g.selected == .programMonitor) && !shell.dock.isMonitorCard(g))
            if !hosted { ShellDock.drawPlaceholder(&c, panel: g.selected, in: g.content, theme: screen.theme) }
        }
    }

    /// The first-run welcome once the editor is up (after the start screen), as the Mac `presentWelcomeIfNeeded`.
    /// Scripted runs (`--edit-test`, `--ui-shot`, `--play-test`, …) never show it: its dialog would take their events.
    func presentWelcomeOnce() {
        guard !welcomeChecked, !shell.isStartShown, shell.dialog == nil else { return }
        welcomeChecked = true
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { return }
        shell.presentWelcomeIfNeeded()
    }

    /// A press in a card gives that panel the dock's focus (the accent tab underline).
    func focusDockPanel(_ e: InputEvent, scale: Float) {
        guard case .mouseDown(let x, let y, _) = e,
              let p = shell.dock.panel(at: CGPoint(x: CGFloat(x / scale), y: CGFloat(y / scale))) else { return }
        shell.dock.focused = p
    }

    func makeColorPage() -> ColorPageHost {
        let h = ColorPageHost(session: session, menus: shell.menuBar.controller, shell: shell)
        h.controller.beep = { _ = MessageBeep(UINT(MB_OK)) }
        h.readProgramFrame = { [weak self] width in self?.engine.linearFrame(width: width) }
        h.media = { winTimelineMedia }
        h.loupeUnderPointer = { WinScreenSample.gridUnderCursor() }
        return h
    }
}
