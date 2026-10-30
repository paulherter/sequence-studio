import SQAppShell
import SQDrawMonitor
import SQUIKit
import WinSDK

/// The eyedropper's screen sample on Windows (the Mac KeyPick samples the screen with ScreenCaptureKit): the color of
/// the pixel under the mouse pointer, read from the desktop through GDI (GetPixel). Nil when GDI cannot read it
/// (CLR_INVALID: a secure desktop, a pointer outside every monitor).
enum WinScreenSample {
    static func colorUnderCursor() -> SQColorValue? {
        var p = POINT()
        guard GetCursorPos(&p) else { return nil }
        guard let dc = GetDC(nil) else { return nil }
        defer { ReleaseDC(nil, dc) }
        let c = GetPixel(dc, p.x, p.y)
        guard c != 0xFFFF_FFFF else { return nil }
        // COLORREF is 0x00BBGGRR.
        return SQColorValue(r: Double(c & 0xFF) / 255, g: Double((c >> 8) & 0xFF) / 255, b: Double((c >> 16) & 0xFF) / 255, a: 1)
    }

    /// The `side` x `side` screen pixels around the pointer (display 8-bit RGB, rows top-down) for the eyedropper's loupe:
    /// one BitBlt of the desktop into a memory bitmap, read back with GetDIBits as 32-bit BGRA. Nil when GDI fails.
    static func gridUnderCursor(side: Int = ColorLoupe.side) -> ColorLoupe? {
        var p = POINT()
        guard side > 0, GetCursorPos(&p) else { return nil }
        guard let screen = GetDC(nil) else { return nil }
        defer { ReleaseDC(nil, screen) }
        guard let mem = CreateCompatibleDC(screen) else { return nil }
        defer { DeleteDC(mem) }
        let n = Int32(side)
        guard let bmp = CreateCompatibleBitmap(screen, n, n) else { return nil }
        defer { DeleteObject(HGDIOBJ(bmp)) }
        let old = SelectObject(mem, HGDIOBJ(bmp))
        let copied = BitBlt(mem, 0, 0, n, n, screen, p.x - n / 2, p.y - n / 2, DWORD(0x00CC_0020))   // SRCCOPY
        SelectObject(mem, old)
        guard copied else { return nil }
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = n
        info.bmiHeader.biHeight = -n                    // top-down rows
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(0)         // BI_RGB
        var bgra = [UInt8](repeating: 0, count: side * side * 4)
        let rows = bgra.withUnsafeMutableBytes { GetDIBits(mem, bmp, 0, UINT(side), $0.baseAddress, &info, UINT(0)) }   // DIB_RGB_COLORS
        guard rows == n else { return nil }
        let pixels = (0..<(side * side)).map { i in SIMD3<UInt8>(bgra[i * 4 + 2], bgra[i * 4 + 1], bgra[i * 4]) }
        return ColorLoupe(width: side, height: side, pixels: pixels)
    }
}

/// The shared hosts' eyedropper seam (SQAppShell `AppScreenSampler`) on GDI: the host samples per event and draws the loupe.
@MainActor
final class WinScreenSampler: AppScreenSampler {
    var ownEyedropper: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)? { nil }
    func colorUnderPointer() -> SQColorValue? { WinScreenSample.colorUnderCursor() }
    func loupeUnderPointer() -> ColorLoupe? { WinScreenSample.gridUnderCursor() }
}
