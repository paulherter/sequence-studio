import Foundation
import SQDrawKit
import SQDrawShell
import SQUIKit

/// The "..." in the dock tab strip of the panels without options of their own (Controls, Text, Graphics, Marker List):
/// the Mac `TabStrip` shows it for every tab group and opens the tab menu (Maximize / Close Panel).
@MainActor
public final class TabMenuOptions {
    private var buttons: [PanelStripOptions] = []

    public init(panels: [PanelID], dock: ShellDock, menus: MenuController) {
        for p in panels {
            let o = PanelStripOptions(panel: p, dock: dock)
            o.onOpen = { [weak dock, weak menus] at in
                guard let dock else { return }
                menus?.present(items: dock.tabMenu(p), at: at)
            }
            buttons.append(o)
        }
    }

    public func draw(_ c: inout Canvas, theme: DrawTheme) {
        for b in buttons { b.draw(&c, theme: theme) }
    }

    /// One event in pixels; true when a button took the press.
    public func handle(_ e: InputEvent, scale: Float) -> Bool {
        var took = false
        for b in buttons where b.handle(e, scale: scale) { took = true }
        return took
    }
}
