import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell
import WinSDK

/// When the project last changed (dirty) or was saved, for the title row's "Edited …" text.
@MainActor private var editedState: (dirty: Bool, url: URL?, date: Date?) = (false, nil, nil)

/// The window's own caption, two rows like the Mac window: the menu row (menu titles, a drag area, Minimize / Maximize /
/// Close) and the title row below it (project name, edit time, Edit | Color, Workspace popup, Export). Win32 asks
/// `windowHit` where to drag and resize (Window.swift `WM_NCHITTEST`).
extension AppController {
    static let titleRowHeight = CGFloat(DrawTheme.Metrics.topBar)
    /// Both rows (points): the dock starts below.
    var chromeHeight: CGFloat { CaptionRowHost.height + Self.titleRowHeight }

    func configureChrome() {
        caption.onButton = { b in
            guard let h = WinPointer.hwnd else { return }
            switch b {
            case .minimize: ShowWindow(h, SW_MINIMIZE)
            case .maximize: ShowWindow(h, IsZoomed(h) ? SW_RESTORE : SW_MAXIMIZE)
            case .close: PostMessageW(h, UINT(WM_CLOSE), 0, 0)
            }
        }
        AppWindow.hitTest = { [weak self] x, y in self?.windowHit(x: x, y: y) ?? .client }
    }

    func makeTitleRow() -> TitleRowHost {
        let r = TitleRowHost()
        r.menus = shell.menuBar.controller
        r.onExport = { [weak self] in self?.shell.perform(.command(.export)) }
        // Window > Workspaces, freshly built (the Mac `makeTitleRow`): the checked item is the current workspace.
        r.workspaceItems = { [weak self] in
            guard let self else { return [] }
            let menus = shell.menuBar.refresh?() ?? shell.menuBar.menus
            return menus.lazy.flatMap(\.items).first { $0.title == "Workspaces" }?.submenu ?? []
        }
        return r
    }

    /// Lays out both rows for a window `width` points wide (from `layoutDock`).
    func layoutChrome(width: CGFloat) {
        if let h = WinPointer.hwnd { caption.isMaximized = IsZoomed(h) }
        caption.layout(width: width)
        let bar = shell.menuBar
        bar.maxWidth = CaptionRowHost.menuRoom(from: bar.origin.x, width: width)
        titleRow.projectName = session.displayName
        titleRow.edited = editedDate()
        titleRow.workspaceName = shell.dock.store.current.name
        titleRow.isChooser = shell.isStartShown
        titleRow.layout(after: 0, width: width, barHeight: Self.titleRowHeight, top: CaptionRowHost.height,
                        measure: TextMeasure(atlas: atlas, scale: screen.theme.scale))
        colorPage.layoutSwitch(after: titleRow.switchAfter, barHeight: Self.titleRowHeight, top: CaptionRowHost.height,
                               shown: !shell.isStartShown)
    }

    private func editedDate() -> Date? {
        let dirty = session.isDirty, url = session.fileURL
        if dirty != editedState.dirty || url != editedState.url {
            let saved = url.flatMap { FileWalk.Values.read($0, keys: [.contentModificationDateKey])?.contentModificationDate }
            editedState = (dirty, url, dirty ? Date() : saved)
        }
        return editedState.date
    }

    /// The rows' background under the panels (the screen's own 44 pt top bar lies beneath).
    static func drawChromeRows(_ c: inout Canvas, width: CGFloat, theme t: DrawTheme) {
        let h = CaptionRowHost.height + titleRowHeight
        c.fill(CGRect(x: 0, y: 0, width: width, height: h), t.titlebar)
        c.fill(CGRect(x: 0, y: h - 1, width: width, height: 1), t.separator)
    }

    /// Menu titles, title row and window buttons over the panels (the page switch is drawn by `colorPage`).
    func drawChrome(_ c: inout Canvas) {
        shell.drawBar(&c, theme: screen.theme)
        titleRow.draw(&c, theme: screen.theme)
        caption.draw(&c, theme: screen.theme)
    }

    /// What the window point (client pixels) is to Windows: edges resize, the rows drag except over their controls.
    func windowHit(x: Float, y: Float) -> WindowHit {
        let k = CGFloat(max(screen.theme.scale, 0.01))
        let size = shell.size, p = CGPoint(x: CGFloat(x) / k, y: CGFloat(y) / k)
        // An open menu lies over the rows: every point is the menu's (a click outside closes it).
        let rows = shell.menuBar.controller.isOpen ? 0 : chromeHeight
        var controls = shell.menuBar.titleFrames
        if let more = shell.menuBar.overflowFrame { controls.append(more) }
        controls += [titleRow.frames[.workspace], titleRow.frames[.export], colorPage.frames[.pageSwitch]].compactMap { $0 }
        // The start screen covers the title row.
        if shell.isStartShown { controls.append(CGRect(x: 0, y: CaptionRowHost.height, width: size.width, height: Self.titleRowHeight)) }
        return caption.hit(p, size: size, captionHeight: rows, controls: controls)
    }
}
