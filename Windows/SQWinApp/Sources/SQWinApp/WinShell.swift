import Foundation
import SQCore
import SQEditorSession
import WinSDK

/// Windows backends of the shell's platform hooks (`ShellHost.revealFile`, `copyText`): Explorer and the clipboard.
enum WinShell {
    /// Opens Explorer with `url` selected (the Mac `activateFileViewerSelecting`).
    static func reveal(_ url: URL) {
        let args = "/select,\"" + url.path.replacingOccurrences(of: "/", with: "\\") + "\""
        _ = "explorer.exe".withCString(encodedAs: UTF16.self) { exe in
            args.withCString(encodedAs: UTF16.self) { a in ShellExecuteW(nil, nil, exe, a, nil, SW_SHOWNORMAL) }
        }
    }

    /// Opens a web page, mail link or folder with its default handler (the Mac `NSWorkspace.open`).
    static func open(_ url: URL) {
        let target = url.isFileURL ? url.path.replacingOccurrences(of: "/", with: "\\") : url.absoluteString
        _ = "open".withCString(encodedAs: UTF16.self) { verb in
            target.withCString(encodedAs: UTF16.self) { t in ShellExecuteW(nil, verb, t, nil, nil, SW_SHOWNORMAL) }
        }
    }

    /// Puts `text` on the clipboard as Unicode text.
    static func copy(_ text: String) {
        guard OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let units = Array(text.utf16) + [0]
        guard let mem = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(units.count * 2)) else { return }
        guard let p = GlobalLock(mem) else { GlobalFree(mem); return }
        units.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        GlobalUnlock(mem)
        if SetClipboardData(UINT(CF_UNICODETEXT), mem) == nil { GlobalFree(mem) }
    }

    /// The clipboard's Unicode text (Ctrl-V in a drawn field); nil when it holds none.
    static func pasteText() -> String? {
        guard OpenClipboard(nil) else { return nil }
        defer { CloseClipboard() }
        guard let mem = GetClipboardData(UINT(CF_UNICODETEXT)), let p = GlobalLock(mem) else { return nil }
        defer { GlobalUnlock(mem) }
        let units = p.assumingMemoryBound(to: UInt16.self)
        var n = 0
        while units[n] != 0 { n += 1 }
        return String(decoding: UnsafeBufferPointer(start: units, count: n), as: UTF16.self)
    }

    /// Files (Explorer copy, CF_HDROP) or a PNG image (the registered "PNG" format that browsers and screenshot tools set) on the
    /// clipboard, for Paste in the Project panel and the timeline.
    // shortcut: a bitmap-only clipboard (CF_DIB without "PNG") is not converted; upgrade when a source needs it.
    static func mediaClipboard() -> PasteMedia.Content {
        guard OpenClipboard(nil) else { return PasteMedia.Content() }
        defer { CloseClipboard() }
        if let mem = GetClipboardData(UINT(CF_HDROP)) {
            let drop = HDROP(bitPattern: UInt(bitPattern: mem))
            var urls: [URL] = []
            for i in 0..<DragQueryFileW(drop, 0xFFFF_FFFF, nil, 0) {
                let n = DragQueryFileW(drop, i, nil, 0)
                var buf = [UInt16](repeating: 0, count: Int(n) + 1)
                _ = DragQueryFileW(drop, i, &buf, n + 1)
                let url = URL(fileURLWithPath: String(decoding: buf.prefix(Int(n)), as: UTF16.self))
                if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
            }
            if !urls.isEmpty { return PasteMedia.Content(fileURLs: urls) }
        }
        let png = "PNG".withCString(encodedAs: UTF16.self) { RegisterClipboardFormatW($0) }
        if png != 0, let mem = GetClipboardData(png), let p = GlobalLock(mem) {
            defer { GlobalUnlock(mem) }
            return PasteMedia.Content(imageData: Data(bytes: p, count: Int(GlobalSize(mem))))
        }
        return PasteMedia.Content()
    }

    /// The About card's Supporters (the Mac bundles `SUPPORTERS.md`): the copy beside the exe, else the source tree's.
    /// shortcut: a dev build reads the checkout through #filePath; the installer must put the file beside the exe.
    static func supporters() -> [String] {
        let name = SupportersList.fileName + "." + SupportersList.fileExtension
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(name)
        for u in [exe, repo] { if let t = try? String(contentsOf: u, encoding: .utf8) { return SupportersList.parse(t) } }
        return []
    }
}
