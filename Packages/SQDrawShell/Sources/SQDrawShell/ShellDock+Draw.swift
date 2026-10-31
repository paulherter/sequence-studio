import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

extension ShellDock {
    /// The divider surface, the cards and their tab strips (the Mac `WorkspaceHostView` background, `PanelContainerView`,
    /// `TabStrip`). Call before the panels draw into `contentFrame`.
    public func draw(_ c: inout Canvas, theme t: DrawTheme) {
        c.fill(frame, t.divider)
        let radius = CGFloat(DrawTheme.Radius.panel)
        for g in groups {
            if g.isFloating {
                // A floating window: square card with its own title row (the OS window has no frame of ours).
                c.fill(g.frame, t.panel)
                if let w = floating.window(of: g.selected) { floating.drawTitle(&c, w, theme: t, focused: focused == g.selected) }
                continue
            }
            c.fill(roundedRect: g.frame, radius: radius, t.panel)
            guard g.strip.height > 0 else { continue }
            c.fill(CGRect(x: g.strip.minX, y: g.strip.maxY - 1, width: g.strip.width, height: 1), t.separator)
            for (i, p) in g.panels.enumerated() where g.tabs[i].width > 0 {
                let r = g.tabs[i], on = p == g.selected
                // A hovered tab reads like the selected one (the Mac `TabButton.refresh`), none while a tab is dragged.
                let hover = !on && dragTab == nil && pointer.map(r.contains) == true
                c.draw(EditorCommand.localizedPanelTitle(p), in: r, fontSize: Self.tabFont, on || hover ? t.label : t.label3, align: .center,
                       face: c.medium)
                // The selected tab's underline (v9 `.tab[aria-selected]::after`): accent while the group has focus.
                if on {
                    let u = CGRect(x: r.minX + Self.tabPadding, y: g.strip.maxY - 2, width: max(r.width - 2 * Self.tabPadding, 0), height: 2)
                    c.fill(roundedRect: u, radius: 1, focused == p ? t.accent : t.label3)
                }
            }
        }
    }

    /// A card for a panel this platform does not have yet (inside `contentFrame`).
    public static func drawPlaceholder(_ c: inout Canvas, panel: PanelID, in r: CGRect, theme t: DrawTheme) {
        guard r.width > 40, r.height > 30 else { return }
        let title = EditorCommand.localizedPanelTitle(panel)
        c.draw(title, in: CGRect(x: r.minX, y: r.midY - 18, width: r.width, height: 18), fontSize: 13, t.label2, align: .center,
               face: c.semibold)
        c.draw(SQL10n.string(ShellPlatformText.panelMissing), in: CGRect(x: r.minX, y: r.midY + 2, width: r.width, height: 16), fontSize: 11,
               t.label3, align: .center)
    }

    /// The drag overlay (`DockOverlayView`) and the tab ghost; call after the panels.
    public func drawOverlay(_ c: inout Canvas, theme t: DrawTheme) {
        if let d = dropTarget {
            let box = d.container
            c.fill(box, DrawColor.black.alpha(0.28))
            let b = (Double(box.minX), Double(box.minY), Double(box.width), Double(box.height))
            let small = CGFloat(DrawTheme.Radius.small)
            for z in DropZone.allCases where z != d.zone {
                let h = DropZone.highlightRect(z, in: b)
                let r = CGRect(x: h.x, y: h.y, width: h.width, height: h.height).insetBy(dx: 2, dy: 2)
                c.fill(roundedRect: r, radius: small, t.accent.alpha(0.10))
                c.stroke(roundedRect: r, radius: small, width: 1, t.accent.alpha(0.35))
            }
            if let z = d.zone {
                let h = DropZone.highlightRect(z, in: b)
                let r = CGRect(x: h.x, y: h.y, width: h.width, height: h.height).insetBy(dx: 2, dy: 2)
                c.fill(roundedRect: r, radius: small, t.accent.alpha(0.55))
                c.stroke(roundedRect: r, radius: small, width: 2, t.accent)
            }
            if d.stripHighlight { c.fill(CGRect(x: box.minX, y: box.minY, width: box.width, height: Self.stripHeight), t.accent.alpha(0.55)) }
            if let x = d.insertionX { c.fill(CGRect(x: x - 1, y: box.minY + 3, width: 2, height: Self.stripHeight - 6), t.accent) }
        }
        if let (p, at) = dragTab {
            let title = EditorCommand.localizedPanelTitle(p)
            let w = ceil(measure.width(title, size: Self.tabFont, face: measure.medium)) + 2 * Self.tabPadding
            let r = CGRect(x: at.x - w / 2, y: at.y - Self.tabHeight / 2, width: w, height: Self.tabHeight)
            c.fill(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), t.panel.alpha(0.85))
            c.stroke(roundedRect: r, radius: CGFloat(DrawTheme.Radius.control), width: 1, t.separator)
            c.draw(title, in: r, fontSize: Self.tabFont, t.label, align: .center, face: c.medium)
        }
    }
}
