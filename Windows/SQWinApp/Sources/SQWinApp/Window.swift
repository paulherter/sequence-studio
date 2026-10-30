import CSQWinApp
import Foundation
import SQAppShell
import SQDrawKit
import SQDrawShell
import WinSDK

nonisolated(unsafe) private var gEvents: [InputEvent] = []
/// The `ScrollGesture` behind each `.scroll` in `gEvents`, by index (the host publishes it while delivering the event).
nonisolated(unsafe) private var gGestures: [Int: ScrollGesture] = [:]
nonisolated(unsafe) private var gScroll = WinScroll()
/// Where the last wheel message pointed: the made-up end of a touchpad gesture goes there.
nonisolated(unsafe) private var gScrollAt: (Float, Float, InputModifiers) = (0, 0, [])
nonisolated(unsafe) private var gPendingSize: (Int, Int)?
nonisolated(unsafe) private var gMouseDown = false
/// TrackMouseEvent(TME_LEAVE) is armed; Windows sends one WM_MOUSELEAVE per arming.
nonisolated(unsafe) private var gLeaveArmed = false
/// Files dropped from Explorer (WM_DROPFILES), one list per drop.
nonisolated(unsafe) private var gDrops: [(urls: [URL], x: Float, y: Float)] = []
/// Keys released (WM_KEYUP): Hold-S in the timeline ends on the S key-up.
nonisolated(unsafe) private var gKeyUps: [InputKey] = []
/// The window lost the keyboard focus (WM_KILLFOCUS): held keys' key-ups will not come.
nonisolated(unsafe) private var gFocusLost = false
/// Indexes in `gEvents` of key downs that are auto-repeats (lParam bit 30: the key was already down).
nonisolated(unsafe) private var gRepeats: Set<Int> = []
/// Alt pressed and released alone (the menu-bar key); counted for the main loop.
nonisolated(unsafe) private var gAltTap = AltTap()
nonisolated(unsafe) private var gAltTaps = 0
/// The window moved to a monitor with another DPI (WM_DPICHANGED); the main loop updates the theme scale.
nonisolated(unsafe) private var gDPIChanged = false
/// TrackMouseEvent(TME_LEAVE | TME_NONCLIENT) is armed over the Maximize button.
nonisolated(unsafe) private var gNCLeaveArmed = false
/// WM_CHAR text beyond the key map: IME results, layout letters, dead keys (`ShellTextInput`).
nonisolated(unsafe) private var gText = ShellTextInput()

func wide(_ s: String) -> [UInt16] { Array(s.utf16) + [0] }

/// Pixels a maximized window leaves free at an auto-hide taskbar's edge (enough for the pointer to reveal it).
let autoHideGap: LONG = 2

/// The edges (ABE_LEFT 0, ABE_TOP 1, ABE_RIGHT 2, ABE_BOTTOM 3) of `hwnd`'s monitor that hold an auto-hide taskbar.
func autoHideTaskbarEdges(_ hwnd: HWND) -> [UINT] {
    var state = APPBARDATA()
    state.cbSize = DWORD(MemoryLayout<APPBARDATA>.size)
    guard SHAppBarMessage(DWORD(0x4 /* ABM_GETSTATE */), &state) & UINT_PTR(0x1 /* ABS_AUTOHIDE */) != 0 else { return [] }
    var mi = MONITORINFO()
    mi.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
    guard GetMonitorInfoW(MonitorFromWindow(hwnd, DWORD(MONITOR_DEFAULTTONEAREST)), &mi) else { return [] }
    return (UINT(0)...UINT(3)).filter { edge in
        var abd = APPBARDATA()
        abd.cbSize = DWORD(MemoryLayout<APPBARDATA>.size)
        abd.uEdge = edge
        abd.rc = mi.rcMonitor
        return SHAppBarMessage(DWORD(0xB /* ABM_GETAUTOHIDEBAREX */), &abd) != 0
    }
}

func keyModifiers() -> InputModifiers {
    var m: InputModifiers = []
    if GetKeyState(Int32(VK_SHIFT)) < 0 { m.insert(.shift) }
    if GetKeyState(Int32(VK_CONTROL)) < 0 { m.insert(.command) }
    if GetKeyState(Int32(VK_MENU)) < 0 { m.insert(.option) }
    return m
}

private func key(_ vk: Int) -> InputKey? {
    switch vk {
    case 0x20: .space
    case 0x25: .left
    case 0x26: .up
    case 0x27: .right
    case 0x28: .down
    case 0x24: .home
    case 0x23: .end
    case 0x2E: .delete
    case 0x08: .backspace
    case 0x1B: .escape
    case 0x0D: .enter
    case 0x21: .pageUp
    case 0x22: .pageDown
    case 0x70...0x7B: .function(vk - 0x6F)      // F1...F12
    case 0x09: .character("\t")     // Tab (InputKey.tab): field focus order
    case 0xBB, 0x6B: .plus
    case 0xBD, 0x6D: .minus
    case 0xDC, 0xE2: .character("\\")
    case 0x41...0x5A: .character(Character(UnicodeScalar(UInt8(vk + 32))))
    case 0x30...0x39: .character(Character(UnicodeScalar(UInt8(vk))))
    case 0x60...0x69: .character(Character(UnicodeScalar(UInt8(vk - 0x30))))    // keypad digits
    // US-layout OEM keys, unshifted (the Mac key map binds the unshifted cap: `,` `.` `[` `]` `;` `'` `/` `` ` ``).
    case 0xBC: .character(",")
    case 0xBE: .character(".")
    case 0xDB: .character("[")
    case 0xDD: .character("]")
    case 0xBA: .character(";")
    case 0xDE: .character("'")
    case 0xBF: .character("/")
    case 0xC0: .character("`")
    default: nil
    }
}

/// Draw pixels per main-window pixel: the frame is laid out at the largest scale of the main and the floating windows
/// (`WinFloatingHost.draw`), so a main window on a display with a smaller scale reports its pointer scaled up. 1 when the
/// main window has the largest scale (always, without floating windows).
enum WinDrawScale {
    nonisolated(unsafe) static var mainFactor: Float = 1
}

private func point(_ lp: LPARAM) -> (Float, Float) {
    (Float(Int16(truncatingIfNeeded: lp)) * WinDrawScale.mainFactor, Float(Int16(truncatingIfNeeded: lp >> 16)) * WinDrawScale.mainFactor)
}

/// Screen coordinates (WM_NC* messages) to client pixels.
private func clientPoint(_ hwnd: HWND?, _ lp: LPARAM) -> (Float, Float) {
    var p = POINT(x: LONG(Int16(truncatingIfNeeded: lp)), y: LONG(Int16(truncatingIfNeeded: lp >> 16)))
    ScreenToClient(hwnd, &p)
    return (Float(p.x) * WinDrawScale.mainFactor, Float(p.y) * WinDrawScale.mainFactor)
}

/// Our drawn chrome's answer to WM_NCHITTEST. Minimize and Close are client area (the caption row handles them);
/// Maximize is HTMAXBUTTON so Windows 11 shows its snap layouts over it.
private func hitCode(_ h: WindowHit) -> LRESULT {
    switch h {
    case .client, .minimize, .close: LRESULT(HTCLIENT)
    case .caption: LRESULT(HTCAPTION)
    case .maximize: LRESULT(HTMAXBUTTON)
    case .left: LRESULT(HTLEFT)
    case .right: LRESULT(HTRIGHT)
    case .top: LRESULT(HTTOP)
    case .bottom: LRESULT(HTBOTTOM)
    case .topLeft: LRESULT(HTTOPLEFT)
    case .topRight: LRESULT(HTTOPRIGHT)
    case .bottomLeft: LRESULT(HTBOTTOMLEFT)
    case .bottomRight: LRESULT(HTBOTTOMRIGHT)
    }
}

private func wndProc(_ hwnd: HWND?, _ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) -> LRESULT {
    switch msg {
    case UINT(WM_NCCALCSIZE) where wp != 0:
        // No system caption or frame: the client area is the whole window. Maximized, Windows puts the frame outside
        // the monitor, so the client is inset by it to stay on screen.
        if let hwnd, IsZoomed(hwnd), let params = UnsafeMutablePointer<NCCALCSIZE_PARAMS>(bitPattern: Int(lp)) {
            let dpi = GetDpiForWindow(hwnd)
            let fx = GetSystemMetricsForDpi(SM_CXFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
            let fy = GetSystemMetricsForDpi(SM_CYFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
            params.pointee.rgrc.0.left += fx; params.pointee.rgrc.0.right -= fx
            params.pointee.rgrc.0.top += fy; params.pointee.rgrc.0.bottom -= fy
            // An auto-hide taskbar shows when the pointer touches its screen edge; a maximized window covering that
            // edge would keep it hidden, so the edge keeps a thin strip free (as Windows Terminal and Explorer do).
            for edge in autoHideTaskbarEdges(hwnd) {
                switch edge {
                case 0: params.pointee.rgrc.0.left += autoHideGap
                case 1: params.pointee.rgrc.0.top += autoHideGap
                case 2: params.pointee.rgrc.0.right -= autoHideGap
                default: params.pointee.rgrc.0.bottom -= autoHideGap
                }
            }
        }
        return 0
    case UINT(WM_NCHITTEST):
        guard let test = AppWindow.hitTestNow else { return DefWindowProcW(hwnd, msg, wp, lp) }
        let (x, y) = clientPoint(hwnd, lp)
        return hitCode(test(x, y))
    case UINT(WM_NCMOUSEMOVE) where wp == WPARAM(HTMAXBUTTON),
         UINT(WM_NCLBUTTONDOWN) where wp == WPARAM(HTMAXBUTTON),
         UINT(WM_NCLBUTTONDBLCLK) where wp == WPARAM(HTMAXBUTTON),
         UINT(WM_NCLBUTTONUP) where wp == WPARAM(HTMAXBUTTON):
        // The Maximize button is HTMAXBUTTON (snap layouts); the caption row draws and runs it like the others.
        let (x, y) = clientPoint(hwnd, lp)
        switch msg {
        case UINT(WM_NCMOUSEMOVE):
            if !gNCLeaveArmed {
                var t = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE | TME_NONCLIENT),
                                        hwndTrack: hwnd, dwHoverTime: 0)
                gNCLeaveArmed = TrackMouseEvent(&t)
            }
            gEvents.append(.mouseMoved(x: x, y: y))
        case UINT(WM_NCLBUTTONUP): gEvents.append(.mouseUp(x: x, y: y))
        default: gEvents.append(.mouseDown(x: x, y: y, modifiers: keyModifiers()))
        }
        return 0
    case UINT(WM_NCMOUSELEAVE):
        gNCLeaveArmed = false
        if !gMouseDown { gEvents.append(.mouseMoved(x: -100_000, y: -100_000)) }
        return 0
    case UINT(WM_NCRBUTTONUP) where wp == WPARAM(HTCAPTION), UINT(WM_NCRBUTTONDOWN) where wp == WPARAM(HTCAPTION):
        return 0                      // no system menu on the caption (all menus are ours)
    case UINT(WM_SYSCHAR):
        return 0                      // Alt+Space: no system menu either
    case UINT(WM_GETMINMAXINFO):
        if let hwnd, let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lp)) {
            let k = Float(GetDpiForWindow(hwnd)) / 96
            info.pointee.ptMinTrackSize = POINT(x: LONG(Float(AppWindow.minimumSize.0) * k), y: LONG(Float(AppWindow.minimumSize.1) * k))
        }
        return 0
    case UINT(WM_DPICHANGED):
        // Per-monitor DPI: take the size Windows suggests for the new monitor; the main loop rescales the theme.
        if let r = UnsafePointer<RECT>(bitPattern: Int(lp))?.pointee {
            SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }
        gDPIChanged = true
        return 0
    case UINT(WM_SIZE):
        gPendingSize = (Int(lp & 0xFFFF), Int((lp >> 16) & 0xFFFF))
        return 0
    case UINT(WM_LBUTTONDOWN):
        gAltTap.other()
        SetCapture(hwnd)
        gMouseDown = true
        let (x, y) = point(lp)
        gEvents.append(.mouseDown(x: x, y: y, modifiers: keyModifiers()))
        return 0
    case UINT(WM_RBUTTONDOWN):
        gAltTap.other()
        // Context menus open on the press; the matching release follows at once so no panel sees a drag.
        let (x, y) = point(lp)
        gEvents.append(.mouseDown(x: x, y: y, modifiers: keyModifiers().union(.secondary)))
        gEvents.append(.mouseUp(x: x, y: y))
        return 0
    case UINT(WM_MOUSEMOVE):
        let (x, y) = point(lp)
        if !gLeaveArmed {
            var t = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: DWORD(TME_LEAVE),
                                    hwndTrack: hwnd, dwHoverTime: 0)
            gLeaveArmed = TrackMouseEvent(&t)
        }
        if !gMouseDown { gEvents.append(.mouseMoved(x: x, y: y)) }
        else if let (vx, vy) = WinPointer.dragged(x: x, y: y) { gEvents.append(.mouseDragged(x: vx, y: vy)) }
        return 0
    case UINT(WM_MOUSELEAVE):
        // The pointer left the window: a move far outside every panel ends their hover and hides the tip (the
        // shared rule `HostHover.endEvent` with no offer), the Mac `mouseExited`.
        gLeaveArmed = false
        if !gMouseDown { gEvents.append(.mouseMoved(x: -100_000, y: -100_000)) }
        return 0
    case UINT(WM_LBUTTONUP):
        ReleaseCapture()
        gMouseDown = false
        let (x, y) = WinPointer.released(x: point(lp).0, y: point(lp).1)
        gEvents.append(.mouseUp(x: x, y: y))
        return 0
    case UINT(WM_MOUSEWHEEL), UINT(WM_MOUSEHWHEEL):
        var p = POINT(x: LONG(Int16(truncatingIfNeeded: lp)), y: LONG(Int16(truncatingIfNeeded: lp >> 16)))
        ScreenToClient(hwnd, &p)
        // The Mac gesture meaning (WinScroll): touchpad points with phases, a pinch (Ctrl + touchpad), mouse notches.
        // Ctrl and Shift from the message's key flags: a touchpad pinch sets MK_CONTROL without a real Ctrl key.
        let flags = Int(wp & 0xFFFF)
        var mods = keyModifiers()
        if flags & Int(MK_CONTROL) != 0 { mods.insert(.command) }
        if flags & Int(MK_SHIFT) != 0 { mods.insert(.shift) }
        let g = gScroll.wheel(delta: Int(Int16(truncatingIfNeeded: wp >> 16)), horizontal: msg == UINT(WM_MOUSEHWHEEL),
                              control: flags & Int(MK_CONTROL) != 0, now: ProcessInfo.processInfo.systemUptime)
        let f = WinDrawScale.mainFactor
        let px = WinScroll.pixels(g, scale: Float(GetDpiForWindow(hwnd)) / 96)
        gScrollAt = (Float(p.x) * f, Float(p.y) * f, mods)
        gGestures[gEvents.count] = g
        gEvents.append(.scroll(x: Float(p.x) * f, y: Float(p.y) * f, dx: px.dx * f, dy: px.dy * f, modifiers: mods))
        return 0
    case UINT(WM_KEYDOWN), UINT(WM_SYSKEYDOWN):
        if Int(wp) == Int(VK_MENU) { gAltTap.altDown() } else { gAltTap.other() }
        let k = key(Int(wp))
        gText.keyDown(k)
        if let k {
            if (lp >> 30) & 1 != 0 { gRepeats.insert(gEvents.count) }
            gEvents.append(.keyDown(k, modifiers: keyModifiers()))
        }
        return 0
    case UINT(WM_CHAR), UINT(WM_DEADCHAR):
        let out = msg == UINT(WM_DEADCHAR) ? gText.deadChar() : gText.char(UInt16(truncatingIfNeeded: wp))
        switch out {
        case .none: break
        case .type(let c): gEvents.append(.keyDown(.character(c), modifiers: []))
        case .replace, .drop:
            if case .keyDown(.character, _)? = gEvents.last { gEvents.removeLast() }
            if case .replace(let c) = out { gEvents.append(.keyDown(.character(c), modifiers: [])) }
        }
        return 0
    case UINT(WM_KEYUP), UINT(WM_SYSKEYUP):
        // Returning 0 for the Alt key-up also keeps Windows from opening the system menu.
        if Int(wp) == Int(VK_MENU), gAltTap.altUp() { gAltTaps += 1 }
        if let k = key(Int(wp)) { gKeyUps.append(k) }
        return 0
    case UINT(WM_KILLFOCUS):
        gFocusLost = true
        gAltTap = AltTap()
        return 0
    case UINT(WM_DROPFILES):
        // Explorer drag-and-drop: the paths of one drop (the Mac panel's file drop, `importMixed`).
        let drop = HDROP(bitPattern: UInt(wp))
        var urls: [URL] = []
        for i in 0..<DragQueryFileW(drop, 0xFFFF_FFFF, nil, 0) {
            let n = DragQueryFileW(drop, i, nil, 0)
            var buf = [UInt16](repeating: 0, count: Int(n) + 1)
            _ = DragQueryFileW(drop, i, &buf, n + 1)
            urls.append(URL(fileURLWithPath: String(decoding: buf.prefix(Int(n)), as: UTF16.self)))
        }
        var pt = POINT()
        _ = DragQueryPoint(drop, &pt)                  // client pixels, like the mouse events
        DragFinish(drop)
        if !urls.isEmpty { gDrops.append((urls, Float(pt.x), Float(pt.y))) }
        return 0
    case UINT(WM_SETCURSOR) where Int(lp & 0xFFFF) == Int(HTCLIENT):
        WinPointer.setCursor()          // the eyedropper's crosshair, else the arrow
        return 1
    case UINT(WM_CLOSE):
        DestroyWindow(hwnd)
        return 0
    case UINT(WM_DESTROY):
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wp, lp)
    }
}

/// A Win32 window (per-monitor DPI aware). Input is queued as portable `InputEvent`s for the main loop.
final class AppWindow {
    let hwnd: HWND
    private(set) var closed = false

    init(title: String, width: Int, height: Int) throws {
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
        let cls = wide("SQWinAppWindow")
        let hinst = GetModuleHandleW(nil)
        let ok = cls.withUnsafeBufferPointer { c -> Bool in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = wndProc
            wc.hInstance = hinst
            wc.hCursor = LoadCursorW(nil, UnsafePointer<UInt16>(bitPattern: 32512))  // IDC_ARROW
            wc.lpszClassName = c.baseAddress
            return RegisterClassExW(&wc) != 0
        }
        guard ok else { throw AppError("RegisterClassEx failed") }
        // The window draws its own caption (WM_NCCALCSIZE): the window rect is the client rect. It opens on the
        // primary monitor's work area, at most `width x height` points.
        let scale = Float(GetDpiForSystem()) / 96
        var work = RECT()
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &work, 0)
        let pw = min(LONG(Float(width) * scale), work.right - work.left), ph = min(LONG(Float(height) * scale), work.bottom - work.top)
        let r = RECT(left: 0, top: 0, right: pw, bottom: ph)
        let x = work.left + max((work.right - work.left - pw) / 2, 0), y = work.top + max((work.bottom - work.top - ph) / 2, 0)
        let t = wide(title)
        let h = cls.withUnsafeBufferPointer { c in
            t.withUnsafeBufferPointer { tt in
                CreateWindowExW(0, c.baseAddress, tt.baseAddress, DWORD(WS_OVERLAPPEDWINDOW), x, y,
                                r.right - r.left, r.bottom - r.top, nil, nil, hinst, nil)
            }
        }
        guard let h else { throw AppError("CreateWindowEx failed") }
        hwnd = h
        WinPointer.hwnd = h
        // Recompute the frame now that WM_NCCALCSIZE removes it (CreateWindowEx measured the system caption).
        SetWindowPos(h, nil, 0, 0, 0, 0, UINT(SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        DragAcceptFiles(hwnd, true)
        // Explorer drags while they hover (the timeline ghost); the release still arrives as WM_DROPFILES.
        _ = sq_drop_register(UnsafeMutableRawPointer(hwnd))
        ShowWindow(hwnd, SW_SHOW)
    }

    /// Smallest window (points): the title row and the dock still fit without overlaps.
    nonisolated(unsafe) static var minimumSize = (800, 520)

    /// Where a client point (pixels) drags, resizes or presses a window button (`WindowHit`); nil = the system frame.
    @MainActor static var hitTest: (@MainActor (Float, Float) -> WindowHit)? {
        get { hitTestBox }
        set { hitTestBox = newValue; hitTestNow = newValue.map { f in { x, y in MainActor.assumeIsolated { f(x, y) } } } }
    }
    @MainActor private static var hitTestBox: (@MainActor (Float, Float) -> WindowHit)?
    /// `hitTest` for the window procedure (called on the UI thread, outside Swift's actor isolation).
    nonisolated(unsafe) fileprivate static var hitTestNow: ((Float, Float) -> WindowHit)?

    /// True once after the window changed monitors to another DPI.
    func takeDPIChange() -> Bool {
        defer { gDPIChanged = false }
        return gDPIChanged
    }

    /// Device pixels per design point.
    var scale: Float { Float(GetDpiForWindow(hwnd)) / 96 }

    var clientSize: (Int, Int) {
        var rc = RECT()
        GetClientRect(hwnd, &rc)
        return (Int(rc.right - rc.left), Int(rc.bottom - rc.top))
    }

    /// Pumps Win32 messages; returns the input that arrived and a new size, if any.
    func pump() -> (events: [InputEvent], gestures: [Int: ScrollGesture], resized: (Int, Int)?) {
        var msg = MSG()
        while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
            if msg.message == UINT(WM_QUIT) { closed = true }
            TranslateMessage(&msg)
            DispatchMessageW(&msg)
        }
        // A touchpad sends no end: WinScroll makes it up after a short quiet spell (rubber band, pinch guard).
        if let end = gScroll.idle(now: ProcessInfo.processInfo.systemUptime) {
            gGestures[gEvents.count] = end
            gEvents.append(.scroll(x: gScrollAt.0, y: gScrollAt.1, dx: 0, dy: 0, modifiers: gScrollAt.2))
        }
        let e = gEvents, g = gGestures
        repeatedEvents = gRepeats
        gEvents.removeAll()
        gGestures.removeAll()
        gRepeats.removeAll()
        let s = gPendingSize
        gPendingSize = nil
        return (e, g, s)
    }

    /// Posts a wheel message to the window as the system would (tests of the wheel route): `delta` in WHEEL_DELTA units.
    func postWheel(delta: Int, horizontal: Bool = false, control: Bool = false, x: Int32, y: Int32) {
        var p = POINT(x: x, y: y)
        ClientToScreen(hwnd, &p)
        let wp = WPARAM(UInt32(UInt16(bitPattern: Int16(delta))) << 16 | UInt32(control ? MK_CONTROL : 0))
        let lp = LPARAM(Int(UInt32(UInt16(truncatingIfNeeded: p.y)) << 16 | UInt32(UInt16(truncatingIfNeeded: p.x))))
        SendMessageW(hwnd, UINT(horizontal ? WM_MOUSEHWHEEL : WM_MOUSEWHEEL), wp, lp)
    }

    /// Takes a drop at its point (window pixels) before the shell imports it: the timeline places files under the pointer.
    @MainActor static var dropRoute: (@MainActor ([URL], Float, Float) -> Bool)?

    /// Files dropped since the last call, one list per drop; drops `dropRoute` took are left out.
    @MainActor func takeDrops() -> [[URL]] {
        let d = gDrops
        gDrops.removeAll()
        return d.filter { !(Self.dropRoute?($0.urls, $0.x, $0.y) ?? false) }.map(\.urls)
    }

    /// Keys released since the last call (InputEvent has no key-up; only Hold-S needs one).
    /// Indexes (in the last `pump()` events) of key downs that are auto-repeats.
    var repeatedEvents: Set<Int> = []

    func takeKeyUps() -> [InputKey] {
        let k = gKeyUps
        gKeyUps.removeAll()
        return k
    }

    /// True once after the window lost the keyboard focus (the host releases held keys).
    func takeFocusLost() -> Bool {
        defer { gFocusLost = false }
        return gFocusLost
    }

    /// Alt taps since the last call (the host focuses its menu bar).
    func takeAltTaps() -> Int {
        defer { gAltTaps = 0 }
        return gAltTaps
    }

    /// Window title (the shell's "*Name - Sequence Studio").
    func setTitle(_ s: String) { _ = wide(s).withUnsafeBufferPointer { SetWindowTextW(hwnd, $0.baseAddress) } }

    func close() { SendMessageW(hwnd, UINT(WM_CLOSE), 0, 0) }

    /// Synthetic input through the real window procedure (tests).
    func post(_ msg: Int32, wp: WPARAM = 0, x: Int = 0, y: Int = 0) {
        PostMessageW(hwnd, UINT(msg), wp, LPARAM((x & 0xFFFF) | ((y & 0xFFFF) << 16)))
    }
}
