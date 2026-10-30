import Foundation
import SQAppShell
import SQDrawKit
import WinSDK

/// The window's pointer and text-input services the drawn controls ask for (`HostRequests`), on the UI thread:
/// pointer lock while a value field scrubs (the Mac ScrubField hides the pointer and pins it), the shared pointer shape
/// (SQAppShell `AppPointer`: crosshair, I-beam, resize, hand, and the panels' requests through `HostHover`, the timeline
/// tool cursors drawn), and IME (on only while a text editor is open; composition and candidate windows at its caret).
enum WinPointer {
    nonisolated(unsafe) static var hwnd: HWND?
    nonisolated(unsafe) private static var shape: AppPointerShape = .arrow
    /// Client px where the pointer is pinned, and the virtual drag position the moves add up to.
    nonisolated(unsafe) private static var lock: (x: Float, y: Float)?
    nonisolated(unsafe) private static var virtual: (x: Float, y: Float) = (0, 0)
    nonisolated(unsafe) private static var hidden = false
    nonisolated(unsafe) private static var imeOn = true
    nonisolated(unsafe) private static var imePlaced: DrawRect?

    // MARK: Cursor

    /// WM_SETCURSOR in the client area: the shape the shared rules asked for last frame.
    static func setCursor() {
        if shape.hasDrawnGlyph, let c = toolCursor(shape) { _ = SetCursor(c); return }
        // IDC_ARROW, IDC_CROSS, IDC_IBEAM, IDC_SIZEWE, IDC_SIZENS, IDC_SIZEALL, IDC_HAND, IDC_NO (Windows has no open or
        // closed hand: the pan arrows).
        // Drag copy and zoom in are drawn above (`DrawCursorGlyph`).
        let id: Int = switch shape {
        case .crosshair: 32515
        case .iBeam: 32513
        case .resizeLeftRight: 32644
        case .resizeUpDown: 32645
        case .resizeDiagonalDown: 32642       // IDC_SIZENWSE
        case .resizeDiagonalUp: 32643         // IDC_SIZENESW
        case .openHand, .closedHand, .move: 32646
        case .pointingHand: 32649
        case .notAllowed: 32648
        default: 32512
        }
        _ = SetCursor(LoadCursorW(nil, UnsafePointer<UInt16>(bitPattern: id)))
    }

    /// The timeline tool cursors, drawn once per shape and DPI (`DrawCursorImage`: the Mac glyphs) and kept.
    nonisolated(unsafe) private static var toolCursors: [DrawCursor: (dpi: UInt32, cursor: HCURSOR)] = [:]

    private static func toolCursor(_ c: DrawCursor) -> HCURSOR? {
        let dpi = max(GetDpiForWindow(hwnd), 96)
        if let k = toolCursors[c], k.dpi == dpi { return k.cursor }
        guard let img = DrawCursorImage.render(c, scale: Float(dpi) / 96) else { return nil }
        let w = img.image.width, h = img.image.height
        var bi = BITMAPINFO()
        bi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bi.bmiHeader.biWidth = LONG(w)
        bi.bmiHeader.biHeight = -LONG(h)                       // top-down rows
        bi.bmiHeader.biPlanes = 1
        bi.bmiHeader.biBitCount = 32
        var bits: UnsafeMutableRawPointer?
        let dc = GetDC(nil)
        let color = CreateDIBSection(dc, &bi, 0, &bits, nil, 0)   // DIB_RGB_COLORS
        ReleaseDC(nil, dc)
        guard let color, let bits else { return nil }
        let px = bits.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(w * h) {                                // RGBA -> BGRA, straight alpha (32-bit cursors blend it)
            px[i * 4] = img.image.pixels[i * 4 + 2]
            px[i * 4 + 1] = img.image.pixels[i * 4 + 1]
            px[i * 4 + 2] = img.image.pixels[i * 4]
            px[i * 4 + 3] = img.image.pixels[i * 4 + 3]
        }
        let zeros = [UInt8](repeating: 0, count: ((w + 15) / 16) * 2 * h)
        let mask = zeros.withUnsafeBytes { CreateBitmap(Int32(w), Int32(h), 1, 1, $0.baseAddress) }
        defer { DeleteObject(color); if let mask { DeleteObject(mask) } }
        var info = ICONINFO(fIcon: false, xHotspot: DWORD(img.hotX), yHotspot: DWORD(img.hotY), hbmMask: mask, hbmColor: color)
        guard let cursor = CreateIconIndirect(&info) else { return nil }
        if let old = toolCursors[c] { DestroyCursor(old.cursor) }
        toolCursors[c] = (dpi, cursor)
        return cursor
    }

    /// The pointer in client pixels now (the shape rules read what lies under it).
    static var position: (Float, Float) {
        var p = POINT()
        guard GetCursorPos(&p), ScreenToClient(hwnd, &p) else { return (-1, -1) }
        return (Float(p.x) * WinDrawScale.mainFactor, Float(p.y) * WinDrawScale.mainFactor)
    }

    // MARK: Pointer lock

    /// A move with the button down: the position panels see. While a scrub asks for the lock the pointer stays hidden
    /// at the point the lock began and the moves add up to a virtual position (it may leave the window, like the Mac's
    /// deltas). nil: the move the re-pin itself caused.
    static func dragged(x: Float, y: Float) -> (Float, Float)? {
        guard HostRequests.shared.pointerLock else { release(); return (x, y) }
        guard let l = lock else {
            lock = (x, y); virtual = (x, y)
            if !hidden { hidden = true; _ = ShowCursor(false) }
            return (x, y)
        }
        let dx = x - l.x, dy = y - l.y
        if dx == 0, dy == 0 { return nil }
        virtual = (virtual.x + dx, virtual.y + dy)
        var p = POINT(x: LONG(l.x), y: LONG(l.y))
        ClientToScreen(hwnd, &p)
        _ = SetCursorPos(p.x, p.y)
        return virtual
    }

    /// The button went up: the release point panels see (the virtual one after a locked drag); the pointer shows again
    /// where the drag began.
    static func released(x: Float, y: Float) -> (Float, Float) {
        defer { release() }
        return lock == nil ? (x, y) : virtual
    }

    private static func release() {
        lock = nil
        if hidden { hidden = false; _ = ShowCursor(true) }
    }

    // MARK: Per frame

    /// After the frame is drawn: the cursor shape, a lock a canceled scrub left, IME on/off and its placement.
    /// `textEditing`: an editor that does not report a caret (the monitor's on-canvas text field) is open.
    static func frame(shape wanted: AppPointerShape, textEditing: Bool) {
        if wanted != shape {
            shape = wanted
            var p = POINT()
            var rc = RECT()
            if GetCursorPos(&p), ScreenToClient(hwnd, &p), GetClientRect(hwnd, &rc),
               p.x >= rc.left, p.x < rc.right, p.y >= rc.top, p.y < rc.bottom { setCursor() }
        }
        if !HostRequests.shared.pointerLock, lock != nil || hidden { release() }
        let caret = HostRequests.shared.caret
        IMM.enable(caret != nil || textEditing)
        if let caret, caret != imePlaced { imePlaced = caret; IMM.place(caret) } else if caret == nil { imePlaced = nil }
    }

    /// imm32, loaded at run time (no import library to link): context association and window placement.
    private enum IMM {
        typealias GetContext = @convention(c) (HWND?) -> UnsafeMutableRawPointer?
        typealias ReleaseContext = @convention(c) (HWND?, UnsafeMutableRawPointer?) -> Int32
        typealias SetWindow = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32
        typealias Associate = @convention(c) (HWND?, UnsafeMutableRawPointer?, UInt32) -> Int32

        nonisolated(unsafe) static let lib: HMODULE? = wide("imm32.dll").withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }
        static func fn<T>(_ name: String, _: T.Type) -> T? {
            guard let lib, let p = GetProcAddress(lib, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        nonisolated(unsafe) static let getContext = fn("ImmGetContext", GetContext.self)
        nonisolated(unsafe) static let releaseContext = fn("ImmReleaseContext", ReleaseContext.self)
        nonisolated(unsafe) static let setComposition = fn("ImmSetCompositionWindow", SetWindow.self)
        nonisolated(unsafe) static let setCandidate = fn("ImmSetCandidateWindow", SetWindow.self)
        nonisolated(unsafe) static let associate = fn("ImmAssociateContextEx", Associate.self)

        /// Off while no text editor is open, so an IME does not compose over shortcuts; IACE_DEFAULT turns it back on.
        static func enable(_ on: Bool) {
            guard on != imeOn, let associate else { return }
            imeOn = on
            _ = associate(hwnd, nil, on ? 0x10 : 0)
        }

        /// COMPOSITIONFORM (CFS_POINT at the caret's top) and CANDIDATEFORM (CFS_EXCLUDE: below the caret, not over it),
        /// as plain 32-bit fields so the layout is the C one.
        static func place(_ r: DrawRect) {
            guard let getContext, let releaseContext, let himc = getContext(hwnd) else { return }
            defer { _ = releaseContext(hwnd, himc) }
            let x = Int32(r.x), top = Int32(r.y), bottom = Int32(r.y + r.h)
            var comp: [Int32] = [0x0002, x, top, 0, 0, 0, 0]
            var cand: [Int32] = [0, 0x0080, x, bottom, x, top, x + 1, bottom]
            comp.withUnsafeMutableBytes { _ = setComposition?(himc, $0.baseAddress) }
            cand.withUnsafeMutableBytes { _ = setCandidate?(himc, $0.baseAddress) }
        }
    }
}
