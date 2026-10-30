import CSQWinApp
import Foundation
import SQAppShell
import SQCore
import SQDrawKit
import SQDrawShell
import SQEditorSession
import SQGPUD3D12
import WinSDK

/// Floating panels on Windows (the design notes "floating panels"): the portable `ShellFloating` decides which panels
/// float and where; this file opens one borderless owned window per entry. Each window shows its rectangle of the one
/// canvas `AppController.frame` draws (`DrawList.region`, its own D3D12 swap chain) and sends its mouse events moved to
/// that rectangle, so the panel hosts run unchanged. A floating window takes the keyboard like the Mac panel does (it
/// activates on a click); its key, character and focus messages go to the main window's procedure, so text fields,
/// shortcuts and held keys run through the one key path (`Window.swift`) as if the main window had the focus.
///
/// Coordinates: the shell's frames are screen points, y up (the Mac convention, so `floating-panels.json` is shared);
/// here a point is a pixel at the main window's DPI divided by its scale, and a window's size is its pixels over its own
/// display's scale.
///
/// Mixed DPI (the Mac way, `ShellFloating.drawScale`): the one frame is drawn at the largest scale of the main window and
/// every floating window (`draw`, the app's theme scale). A window on a display with a smaller scale shows its part of
/// the frame reduced by `ratio = windowScale / draw` (DrawQuads.slang `viewScale`, supersampled), so no window shows an
/// enlarged picture; the main window does the same through `WinDrawScale.mainFactor`.

nonisolated(unsafe) private var gFloatingWindows: [UInt: WinFloatingWindow] = [:]
nonisolated(unsafe) private var gFloatingClass = false

private func key(_ h: HWND?) -> UInt { UInt(bitPattern: h) }

private func floatingProc(_ hwnd: HWND?, _ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) -> LRESULT {
    nonisolated(unsafe) let h = hwnd
    return MainActor.assumeIsolated { floatingHandle(h, msg, wp, lp) }
}

@MainActor
private func floatingHandle(_ hwnd: HWND?, _ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) -> LRESULT {
    guard let w = gFloatingWindows[key(hwnd)] else { return DefWindowProcW(hwnd, msg, wp, lp) }
    func pt() -> (Float, Float) { (Float(Int16(truncatingIfNeeded: lp)), Float(Int16(truncatingIfNeeded: lp >> 16))) }
    switch msg {
    case UINT(WM_NCCALCSIZE) where wp != 0: return 0
    case UINT(WM_NCHITTEST):
        var p = POINT(x: LONG(Int16(truncatingIfNeeded: lp)), y: LONG(Int16(truncatingIfNeeded: lp >> 16)))
        ScreenToClient(hwnd, &p)
        return w.hit(Float(p.x), Float(p.y))
    case UINT(WM_MOUSEACTIVATE): return LRESULT(MA_ACTIVATE)
    case UINT(WM_KEYDOWN), UINT(WM_SYSKEYDOWN), UINT(WM_KEYUP), UINT(WM_SYSKEYUP), UINT(WM_CHAR), UINT(WM_DEADCHAR), UINT(WM_SYSCHAR),
         UINT(WM_KILLFOCUS):
        return SendMessageW(w.owner, msg, wp, lp)
    case UINT(WM_SETFOCUS):
        w.onActivate?()
        return 0
    case UINT(WM_LBUTTONDOWN):
        SetCapture(hwnd); w.down = true
        let (x, y) = pt()
        w.events.append(.mouseDown(x: x, y: y, modifiers: keyModifiers()))
        return 0
    case UINT(WM_RBUTTONDOWN):
        let (x, y) = pt()
        w.events.append(.mouseDown(x: x, y: y, modifiers: keyModifiers().union(.secondary)))
        w.events.append(.mouseUp(x: x, y: y))
        return 0
    case UINT(WM_MOUSEMOVE):
        let (x, y) = pt()
        if !w.leaveArmed {
            var t = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE), hwndTrack: hwnd, dwHoverTime: 0)
            w.leaveArmed = TrackMouseEvent(&t)
        }
        w.events.append(w.down ? .mouseDragged(x: x, y: y) : .mouseMoved(x: x, y: y))
        return 0
    case UINT(WM_MOUSELEAVE):
        w.leaveArmed = false
        if !w.down { w.events.append(.mouseMoved(x: -100_000, y: -100_000)) }
        return 0
    case UINT(WM_LBUTTONUP):
        ReleaseCapture(); w.down = false
        let (x, y) = pt()
        w.events.append(.mouseUp(x: x, y: y))
        return 0
    case UINT(WM_MOUSEWHEEL), UINT(WM_MOUSEHWHEEL):
        var p = POINT(x: LONG(Int16(truncatingIfNeeded: lp)), y: LONG(Int16(truncatingIfNeeded: lp >> 16)))
        ScreenToClient(hwnd, &p)
        let flags = Int(wp & 0xFFFF)
        var mods = keyModifiers()
        if flags & Int(MK_CONTROL) != 0 { mods.insert(.command) }
        if flags & Int(MK_SHIFT) != 0 { mods.insert(.shift) }
        let g = w.scroll.wheel(delta: Int(Int16(truncatingIfNeeded: wp >> 16)), horizontal: msg == UINT(WM_MOUSEHWHEEL),
                               control: flags & Int(MK_CONTROL) != 0, now: ProcessInfo.processInfo.systemUptime)
        let px = WinScroll.pixels(g, scale: w.scale)
        w.gestures[w.events.count] = g
        w.events.append(.scroll(x: Float(p.x), y: Float(p.y), dx: px.dx, dy: px.dy, modifiers: mods))
        return 0
    case UINT(WM_SETCURSOR) where Int(lp & 0xFFFF) == Int(HTCLIENT):
        WinPointer.setCursor()
        return 1
    case UINT(WM_DPICHANGED):
        // Dragged to a display with another scale: keep the logical size (the suggested rectangle).
        if let r = UnsafePointer<RECT>(bitPattern: Int(lp))?.pointee {
            SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }
        w.scale = w.dpiScale
        w.moved = true
        return 0
    case UINT(WM_MOVE), UINT(WM_SIZE):
        w.moved = true
        return 0
    case UINT(WM_CLOSE): return 0                   // closing goes through the title row's Close button
    default: return DefWindowProcW(hwnd, msg, wp, lp)
    }
}

/// One floating panel's OS window.
@MainActor
final class WinFloatingWindow {
    let hwnd: HWND
    let owner: HWND
    let panel: PanelID
    /// The window took the focus (the owner moves the panel focus here).
    var onActivate: (() -> Void)?
    let renderer: UIRenderer
    var events: [InputEvent] = []
    var gestures: [Int: ScrollGesture] = [:]
    var scroll = WinScroll()
    var down = false, leaveArmed = false, moved = false
    /// Pixels per point of the display the window is on (its DPI over 96).
    var scale: Float = 1
    /// Window pixel -> window code (title drags, the grip resizes).
    var hit: (Float, Float) -> LRESULT = { _, _ in LRESULT(HTCLIENT) }


    init(panel: PanelID, owner: HWND, rect: RECT, device: D3D12GPUDevice?) throws {
        self.panel = panel
        self.owner = owner
        if !gFloatingClass {
            let cls = wide("SQWinFloatingWindow")
            let ok = cls.withUnsafeBufferPointer { c -> Bool in
                var wc = WNDCLASSEXW()
                wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
                wc.lpfnWndProc = floatingProc
                wc.hInstance = GetModuleHandleW(nil)
                wc.hCursor = LoadCursorW(nil, UnsafePointer<UInt16>(bitPattern: 32512))
                wc.lpszClassName = c.baseAddress
                return RegisterClassExW(&wc) != 0
            }
            guard ok else { throw AppError("RegisterClassEx (floating) failed") }
            gFloatingClass = true
        }
        let cls = wide("SQWinFloatingWindow"), title = wide(EditorCommand.localizedPanelTitle(panel))
        let h = cls.withUnsafeBufferPointer { c in
            title.withUnsafeBufferPointer { t in
                // WS_THICKFRAME so HTBOTTOMRIGHT resizes; WM_NCCALCSIZE removes the frame again.
                CreateWindowExW(DWORD(WS_EX_TOOLWINDOW), c.baseAddress, t.baseAddress,
                                DWORD(WS_POPUP) | DWORD(WS_THICKFRAME), rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
                                owner, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let h else { throw AppError("CreateWindowEx (floating) failed") }
        hwnd = h
        var c = RECT()
        GetClientRect(h, &c)
        renderer = try UIRenderer(hwnd: UnsafeMutableRawPointer(h), width: max(Int(c.right), 1), height: max(Int(c.bottom), 1), device: device)
        gFloatingWindows[key(h)] = self
        SetWindowPos(h, nil, 0, 0, 0, 0, UINT(SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        ShowWindow(h, SW_SHOWNOACTIVATE)
    }

    var dpiScale: Float { Float(GetDpiForWindow(hwnd)) / 96 }

    /// In front with the keyboard focus.
    func activate() {
        SetForegroundWindow(hwnd)
        SetFocus(hwnd)
    }

    func destroy() {
        gFloatingWindows[key(hwnd)] = nil
        DestroyWindow(hwnd)
    }

    var clientSize: (Int, Int) {
        var c = RECT()
        GetClientRect(hwnd, &c)
        return (Int(c.right), Int(c.bottom))
    }

    var windowRect: RECT {
        var r = RECT()
        GetWindowRect(hwnd, &r)
        return r
    }

    func take() -> (events: [InputEvent], gestures: [Int: ScrollGesture]) {
        defer { events.removeAll(); gestures.removeAll() }
        return (events, gestures)
    }
}

/// Opens, moves and closes the OS windows to match `ShellFloating.windows` and runs their frames and input.
@MainActor
final class WinFloatingHost {
    private let app: AppController
    private let main: AppWindow
    private var windows: [PanelID: WinFloatingWindow] = [:]
    private var canvas: DrawList?
    private var lastRevision = -1

    init(app: AppController, main: AppWindow, loadState: Bool) {
        self.app = app
        self.main = main
        let f = app.shell.dock.floating
        f.screens = { [weak self] in self?.screens() ?? [] }
        f.mainScreenFrame = { [weak self] in self?.mainFrame() }
        f.save = { s in do { try s.save() } catch { SQLog.error("floating panels save failed: \(error.localizedDescription)") } }
        f.raise = { [weak self] p in self?.windows[p]?.activate() }
        app.shell.dock.floatPanel = { p in f.float(p) }
        if loadState { f.load(FloatingPanelState.load()) }
    }

    private var k: CGFloat { CGFloat(max(main.scale, 0.01)) }

    /// The scale the one frame is drawn at (the app's theme scale): the largest of the main window and the floating windows.
    private(set) var draw: Float = 1

    /// Window scale over draw scale for the main window.
    var mainRatio: Float { ShellFloating.ratio(window: main.scale, draw: draw) }

    private func updateScale() {
        draw = ShellFloating.drawScale(main: main.scale, floating: windows.values.map(\.scale))
        WinDrawScale.mainFactor = mainRatio > 0 ? 1 / mainRatio : 1
        app.setWindowDPIScale(draw)
    }

    /// Pixel rectangle on the virtual screen -> screen points, y up.
    private func frame(_ r: RECT) -> CGRect {
        let k = k
        return CGRect(x: CGFloat(r.left) / k, y: -CGFloat(r.bottom) / k, width: CGFloat(r.right - r.left) / k, height: CGFloat(r.bottom - r.top) / k)
    }

    /// A floating window's points: the origin at the main window's scale (one virtual screen), the size at the window's
    /// own display scale, so a window on a 2x display next to a 1x main window keeps its logical size.
    private func frame(_ r: RECT, windowScale s: Float) -> CGRect {
        let k = k, s = CGFloat(max(s, 0.01))
        let h = CGFloat(r.bottom - r.top) / s
        return CGRect(x: CGFloat(r.left) / k, y: -(CGFloat(r.top) / k + h), width: CGFloat(r.right - r.left) / s, height: h)
    }

    private func pixels(_ f: CGRect, windowScale s: Float) -> RECT {
        let k = k, s = CGFloat(max(s, 0.01))
        let top = -f.maxY * k
        return RECT(left: LONG((f.minX * k).rounded()), top: LONG(top.rounded()),
                    right: LONG((f.minX * k + f.width * s).rounded()), bottom: LONG((top + f.height * s).rounded()))
    }

    func window(of p: PanelID) -> WinFloatingWindow? { windows[p] }

    private func mainFrame() -> CGRect? {
        var origin = POINT(x: 0, y: 0), c = RECT()
        ClientToScreen(main.hwnd, &origin)
        GetClientRect(main.hwnd, &c)
        return frame(RECT(left: origin.x, top: origin.y, right: origin.x + c.right, bottom: origin.y + c.bottom))
    }

    private func screens() -> [CGRect] {
        final class Box { var rects: [CGRect] = [] }
        let box = Box(), k = k
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        _ = EnumDisplayMonitors(nil, nil, { monitor, _, _, lp in
            var mi = MONITORINFO()
            mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            if GetMonitorInfoW(monitor, &mi) {
                let r = mi.rcWork
                Unmanaged<Box>.fromOpaque(UnsafeRawPointer(bitPattern: Int(lp))!).takeUnretainedValue().rects.append(
                    CGRect(x: CGFloat(r.left), y: -CGFloat(r.bottom), width: CGFloat(r.right - r.left), height: CGFloat(r.bottom - r.top)))
            }
            return true
        }, LPARAM(Int(bitPattern: ctx)))
        return box.rects.map { CGRect(x: $0.minX / k, y: $0.minY / k, width: $0.width / k, height: $0.height / k) }
    }

    /// The editor frame is the whole canvas: keep it, return the main window's part.
    func mainPart(of full: DrawList, width: Int, height: Int) -> DrawList {
        let f = app.shell.dock.floating
        f.flush()
        app.shell.menuBar.controller.regions = f.windows.map(\.rect)
        sync()
        guard !f.windows.isEmpty else { canvas = nil; return full }
        var list = full
        let e = f.canvasExtent, s = draw
        list.extendCanvas(width: Float(e.width) * s, height: Float(e.height) * s)
        canvas = list
        return list.region(DrawRect(x: 0, y: 0, w: Float(width), h: Float(height)))
    }

    private func sync() {
        let f = app.shell.dock.floating
        for (p, w) in windows where f.window(of: p) == nil { w.destroy(); windows[p] = nil }
        for win in f.windows {
            let target = pixels(win.frame, windowScale: windows[win.panel]?.scale ?? Float(k))
            if let w = windows[win.panel] {
                // The shell moved or sized it (a restored frame, a changed minimum): follow, unless the user is on it.
                let cur = w.windowRect
                if f.revision != lastRevision, cur.left != target.left || cur.top != target.top
                    || cur.right - cur.left != target.right - target.left || cur.bottom - cur.top != target.bottom - target.top {
                    SetWindowPos(w.hwnd, nil, target.left, target.top, target.right - target.left, target.bottom - target.top,
                                 UINT(SWP_NOZORDER | SWP_NOACTIVATE))
                    w.moved = false
                }
                continue
            }
            guard let w = try? WinFloatingWindow(panel: win.panel, owner: main.hwnd, rect: target, device: app.engine.gpu) else {
                SQLog.error("floating window for \(win.panel) failed")
                continue
            }
            // Created at the main window's size; on a display with another scale it takes its logical size there.
            w.scale = w.dpiScale
            if w.scale != Float(k) {
                let r = pixels(win.frame, windowScale: w.scale)
                SetWindowPos(w.hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
                w.moved = true
            }
            let p = win.panel
            w.hit = { [weak self] x, y in
                guard let self, let r = f.window(of: p)?.rect else { return LRESULT(HTCLIENT) }
                let k = self.windows[p]?.scale ?? Float(self.k)      // window pixels -> points
                switch f.hit(at: CGPoint(x: CGFloat(x / k) + r.minX, y: CGFloat(y / k) + r.minY)) {
                case .title?: return LRESULT(HTCAPTION)
                case .grip?: return LRESULT(HTBOTTOMRIGHT)
                default: return LRESULT(HTCLIENT)
                }
            }
            w.onActivate = { [weak app] in app?.shell.dock.focused = p }
            windows[win.panel] = w
            // A panel the user just floated or asked for takes the keyboard.
            if app.shell.dock.focused == p { w.activate() }
        }
        lastRevision = f.revision
    }

    /// Runs after the main window's input: the floating windows' events (moved onto the canvas), their moves and sizes,
    /// then their frames.
    func pump(handle: (InputEvent, ScrollGesture?) -> Void) {
        let f = app.shell.dock.floating
        for w in windows.values { w.scale = w.dpiScale }
        updateScale()
        for (p, w) in windows {
            guard let rect = f.window(of: p)?.rect else { continue }
            let dx = Float(rect.minX) * draw, dy = Float(rect.minY) * draw
            let inv = 1 / max(ShellFloating.ratio(window: w.scale, draw: draw), 0.01)
            let (events, gestures) = w.take()
            for (i, e) in events.enumerated() { handle(shift(e, dx, dy, inv), gestures[i]) }
            if w.moved, !w.down {
                w.moved = false
                f.setFrame(frame(w.windowRect, windowScale: w.scale), of: p)
                let (cw, ch) = w.clientSize
                w.renderer.resize(cw, ch)
            }
        }
    }

    /// A window event onto the canvas: window pixels to draw pixels (`inv` = draw over window scale), then the window's offset.
    private func shift(_ e: InputEvent, _ dx: Float, _ dy: Float, _ inv: Float) -> InputEvent {
        switch e {
        case .mouseDown(let x, let y, let m): .mouseDown(x: x * inv + dx, y: y * inv + dy, modifiers: m)
        case .mouseDragged(let x, let y): .mouseDragged(x: x * inv + dx, y: y * inv + dy)
        case .mouseMoved(let x, let y): x < -50_000 ? e : .mouseMoved(x: x * inv + dx, y: y * inv + dy)
        case .mouseUp(let x, let y): .mouseUp(x: x * inv + dx, y: y * inv + dy)
        case .scroll(let x, let y, let sx, let sy, let m): .scroll(x: x * inv + dx, y: y * inv + dy, dx: sx * inv, dy: sy * inv, modifiers: m)
        default: e
        }
    }

    /// Draws every floating window from the canvas the main window just drew.
    func render(images: (UIRenderer) -> Void) {
        guard let canvas else { return }
        let f = app.shell.dock.floating
        for (p, w) in windows {
            guard let rect = f.window(of: p)?.rect else { continue }
            if w.moved { let (cw, ch) = w.clientSize; w.renderer.resize(cw, ch) }
            // The window's part of the frame in draw pixels; reduced onto the window's pixels when its display has a smaller scale.
            let ratio = ShellFloating.ratio(window: w.scale, draw: draw)
            w.renderer.viewScale = ratio
            let part = canvas.region(DrawRect(x: Float(rect.minX) * draw, y: Float(rect.minY) * draw,
                                              w: Float(ShellFloating.drawSize(w.renderer.width, window: w.scale, draw: draw)),
                                              h: Float(ShellFloating.drawSize(w.renderer.height, window: w.scale, draw: draw))))
            images(w.renderer)
            w.renderer.render(part, atlas: app.atlas, clear: app.screen.theme.divider, vsync: false)
        }
    }

    func flush() { app.shell.dock.floating.flush(force: true) }
}
