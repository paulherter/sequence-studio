import Foundation
import SQAppShell
import SQDrawKit
import SQDrawShell
import SQEditorSession
import WinSDK

/// `--chrome-test <folder>`: drives the real window through our own caption. It resizes to small, medium and large
/// sizes (screenshot each, checks that the rows' parts do not overlap and that the hit test gives drag area, buttons
/// and edges), clicks Color and Edit in the page switch, picks another workspace from the Workspace popup and back,
/// and maximizes and restores through the Maximize button. Prints "chrome test: … ok|FAIL" lines.
@MainActor final class WinChromeTest {
    let app: AppController
    let hwnd: HWND
    let folder: String
    var failures = 0
    private var steps: [(wait: Double, run: @MainActor (WinChromeTest) -> Void)] = []
    private var next = 0, at = 0.0
    /// A screenshot the main loop takes after the next frame.
    var shot: String?
    var done: Bool { next >= steps.count }

    init(app: AppController, hwnd: HWND, folder: String) {
        self.app = app; self.hwnd = hwnd; self.folder = folder
        let sizes = [(800, 520), (1024, 640), (1440, 900), (2200, 1240)]
        for (w, h) in sizes {
            steps.append((0.2, { $0.resize(w, h) }))
            steps.append((0.8, { $0.checkLayout("\(w)x\(h)") }))
            steps.append((0.1, { $0.shot = $0.folder + "\\pc-chrome-\(w)x\(h).png" }))
        }
        steps.append((0.3, { $0.resize(1440, 900) }))
        steps.append((0.6, { $0.checkMinimum() }))
        steps.append((0.1, { $0.clickPage(.color) }))
        steps.append((0.5, { $0.expectPage(.color) }))
        steps.append((0.1, { $0.shot = $0.folder + "\\pc-chrome-color.png" }))
        steps.append((0.3, { $0.clickPage(.edit) }))
        steps.append((0.5, { $0.expectPage(.edit) }))
        steps.append((0.1, { $0.pickWorkspace(other: true) }))
        steps.append((0.6, { $0.shot = $0.folder + "\\pc-chrome-workspace.png" }))
        steps.append((0.3, { $0.pickWorkspace(other: false) }))
        steps.append((0.5, { $0.clickMaximize(expect: true) }))
        steps.append((0.8, { $0.checkLayout("maximized") }))
        steps.append((0.1, { $0.shot = $0.folder + "\\pc-chrome-maximized.png" }))
        steps.append((0.3, { $0.clickMaximize(expect: false) }))
        steps.append((0.6, { $0.report() }))
    }

    private var k: CGFloat { CGFloat(max(app.screen.theme.scale, 0.01)) }

    /// Runs the steps that are due (call once per frame with the seconds since launch).
    func tick(_ t: Double) {
        guard !done, t >= at else { return }
        let s = steps[next]
        next += 1
        s.run(self)
        at = t + (next < steps.count ? steps[next].wait : 0)
    }

    private func expect(_ ok: Bool, _ what: String) {
        if !ok { failures += 1 }
        print("chrome test: \(what) \(ok ? "ok" : "FAIL")")
    }

    private func resize(_ w: Int, _ h: Int) {
        if IsZoomed(hwnd) { ShowWindow(hwnd, SW_RESTORE) }
        let s = Float(GetDpiForWindow(hwnd)) / 96
        SetWindowPos(hwnd, nil, 40, 40, Int32(Float(w) * s), Int32(Float(h) * s), UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }

    private func checkLayout(_ name: String) {
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        var wr = RECT()
        GetWindowRect(hwnd, &wr)
        let size = app.shell.size
        let bar = app.shell.menuBar, cap = app.caption, row = app.titleRow
        let titlesEnd = (bar.overflowFrame ?? bar.titleFrames.last).map(\.maxX) ?? 0
        var notes = [String(format: "%.0fx%.0f pt", size.width, size.height),
                     "client=window \(rc.right - rc.left == wr.right - wr.left && rc.bottom - rc.top == wr.bottom - wr.top)",
                     "\(bar.titleFrames.count) titles\(bar.overflowFrame == nil ? "" : " + »")"]
        var ok = titlesEnd <= cap.buttonsMinX - CaptionRowHost.dragRoom + 0.5 && cap.frames[.close]?.maxX == size.width
        let sw = app.colorPage.frames[.pageSwitch]
        if let n = row.frames[.name], let sw { ok = ok && n.maxX <= sw.minX }
        if let e = row.frames[.edited], let sw { ok = ok && e.maxX <= sw.minX }
        let right = row.frames[.workspace] ?? row.frames[.export]
        if let sw, let right { ok = ok && sw.maxX <= right.minX }
        if let ex = row.frames[.export] { ok = ok && ex.maxX <= size.width && ex.minY >= CaptionRowHost.height }
        notes.append(row.frames[.workspace] == nil ? "no workspace popup" : "workspace popup")
        // Hit test: the free menu row and the name drag, buttons are buttons, the dock is client, edges resize.
        func hit(_ x: CGFloat, _ y: CGFloat) -> WindowHit { app.windowHit(x: Float(x * k), y: Float(y * k)) }
        let maximized = IsZoomed(hwnd)
        var hits = hit(cap.buttonsMinX - 10, 16) == .caption && hit(size.width - 23, 16) == .close
            && hit(size.width - 69, 16) == .maximize && hit(size.width / 2, app.chromeHeight + 40) == .client
        if let n = row.frames[.name], n.width > 4 { hits = hits && hit(n.midX, n.midY) == .caption }
        if let t = bar.titleFrames.first { hits = hits && hit(t.midX, t.midY) == .client }
        if !maximized { hits = hits && hit(1, size.height / 2) == .left && hit(size.width - 1, size.height - 1) == .bottomRight }
        notes.append("hit test \(hits ? "ok" : "wrong")")
        if maximized {
            // The client fills the work area, less the strip an auto-hide taskbar needs to come up.
            var mi = MONITORINFO()
            mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            GetMonitorInfoW(MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST)), &mi)
            var tl = POINT(x: 0, y: 0), br = POINT(x: rc.right, y: rc.bottom)
            ClientToScreen(hwnd, &tl); ClientToScreen(hwnd, &br)
            let edges = autoHideTaskbarEdges(hwnd), w = mi.rcWork, g = autoHideGap
            let want = RECT(left: w.left + (edges.contains(0) ? g : 0), top: w.top + (edges.contains(1) ? g : 0),
                            right: w.right - (edges.contains(2) ? g : 0), bottom: w.bottom - (edges.contains(3) ? g : 0))
            let fits = tl.x == want.left && tl.y == want.top && br.x == want.right && br.y == want.bottom
            notes.append("auto-hide taskbar edges \(edges), client \(tl.x),\(tl.y)-\(br.x),\(br.y) \(fits ? "=" : "!=") work area")
            ok = ok && fits
        }
        expect(ok && hits, "layout \(name) (\(notes.joined(separator: ", ")))")
    }

    private func checkMinimum() {
        var info = MINMAXINFO()
        _ = withUnsafeMutablePointer(to: &info) { SendMessageW(hwnd, UINT(WM_GETMINMAXINFO), 0, LPARAM(Int(bitPattern: $0))) }
        let s = Float(GetDpiForWindow(hwnd)) / 96
        expect(info.ptMinTrackSize.x == LONG(Float(AppWindow.minimumSize.0) * s) && info.ptMinTrackSize.y == LONG(Float(AppWindow.minimumSize.1) * s),
               "minimum size \(info.ptMinTrackSize.x)x\(info.ptMinTrackSize.y) px")
    }

    private func click(_ p: CGPoint) {
        let x = Int((p.x * k).rounded()), y = Int((p.y * k).rounded())
        let lp = LPARAM((x & 0xFFFF) | ((y & 0xFFFF) << 16))
        PostMessageW(hwnd, UINT(WM_MOUSEMOVE), 0, lp)
        PostMessageW(hwnd, UINT(WM_LBUTTONDOWN), WPARAM(MK_LBUTTON), lp)
        PostMessageW(hwnd, UINT(WM_LBUTTONUP), 0, lp)
    }

    private func clickPage(_ p: WorkspaceStore.Page) {
        guard let f = app.colorPage.frames[.pageSwitch] else { return expect(false, "page switch shown") }
        let seg = f.width / 2
        click(CGPoint(x: f.minX + (p == .edit ? seg / 2 : seg * 1.5), y: f.midY))
    }

    private func expectPage(_ p: WorkspaceStore.Page) {
        expect(app.shell.dock.store.page == p, "page switch to \(p) (\(app.shell.dock.store.current.name))")
    }

    private var originalWorkspace = ""

    private func pickWorkspace(other: Bool) {
        guard let r = app.titleRow.frames[.workspace] else { return expect(false, "workspace popup shown") }
        if other { originalWorkspace = app.shell.dock.store.current.name }
        let before = app.shell.dock.store.current.name
        app.shell.menuBar.controller.dismiss()
        _ = app.titleRow.handle(.mouseDown(x: Float(r.midX * k), y: Float(r.midY * k), modifiers: []), scale: Float(k))
        let opened = app.shell.menuBar.controller.isOpen
        // The workspaces come first, up to the separator (then Save as New Workspace… and the other commands).
        let items = Array((app.shell.menuBar.controller.views.first?.items ?? []).prefix { !$0.title.isEmpty })
        let target = other ? items.first { $0.action != nil && $0.title != before }
                           : items.first { $0.title == originalWorkspace }
        app.shell.menuBar.controller.dismiss()
        guard opened, let target, let action = target.action else {
            return expect(false, "workspace popup opened \(opened), \(items.count) items")
        }
        action()
        let now = app.shell.dock.store.current.name
        expect(now == target.title && (other ? now != before : now == originalWorkspace),
               "workspace \(before) -> \(now) (\(items.count) items)")
    }

    private func clickMaximize(expect zoomed: Bool) {
        guard let r = app.caption.frames[.maximize] else { return expect(false, "maximize button") }
        // The button is HTMAXBUTTON (snap layouts): Windows sends WM_NC* messages in screen coordinates.
        var p = POINT(x: LONG(r.midX * k), y: LONG(r.midY * k))
        ClientToScreen(hwnd, &p)
        let lp = LPARAM((Int(p.x) & 0xFFFF) | ((Int(p.y) & 0xFFFF) << 16))
        let code = SendMessageW(hwnd, UINT(WM_NCHITTEST), 0, lp)
        PostMessageW(hwnd, UINT(WM_NCMOUSEMOVE), WPARAM(code), lp)
        PostMessageW(hwnd, UINT(WM_NCLBUTTONDOWN), WPARAM(code), lp)
        PostMessageW(hwnd, UINT(WM_NCLBUTTONUP), WPARAM(code), lp)
        pendingZoom = zoomed
        steps.insert((0.4, { t in
            let z = IsZoomed(t.hwnd)
            t.expect(code == LRESULT(HTMAXBUTTON) && z == t.pendingZoom,
                     "maximize button hit \(code == LRESULT(HTMAXBUTTON) ? "HTMAXBUTTON" : "\(code)"), zoomed \(z)")
        }), at: next)
    }
    private var pendingZoom = false

    private func report() {
        print("chrome test: \(failures == 0 ? "passed" : "\(failures) failed")")
    }
}
