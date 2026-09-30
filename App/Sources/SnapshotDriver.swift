import AppKit
import SSEditorUI

/// Developer aid: with `SS_SNAPSHOT=<dir>` the app writes PNGs of its own window (Edit PC, Edit MacBook, Color) and quits.
/// Renders the view hierarchy through PDF (`dataWithPDF` calls every view's draw directly), so no screen-recording
/// permission is involved; Metal layers (the viewer) and the toolbar stay blank. Not part of the UI.
@MainActor
enum SnapshotDriver {
    static func runIfRequested(_ c: AppController) {
        guard let dir = ProcessInfo.processInfo.environment["SS_SNAPSHOT"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            save(c, to: url.appendingPathComponent("edit-pc.png"))
            _ = c.store.selectEdit(Workspace.editingMacBook.name)
            c.applyWorkspace()
            try? await Task.sleep(for: .seconds(1))
            save(c, to: url.appendingPathComponent("edit-macbook.png"))
            c.store.setPage(.color)
            c.applyWorkspace()
            try? await Task.sleep(for: .seconds(1))
            save(c, to: url.appendingPathComponent("color.png"))
            exit(0)
        }
    }

    private static func save(_ c: AppController, to url: URL) {
        guard let content = c.window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let pdf = content.dataWithPDF(inside: content.bounds)
        guard let rep = NSPDFImageRep(data: pdf) else { return }
        let scale: CGFloat = 2
        let w = Int(rep.bounds.width * scale), h = Int(rep.bounds.height * scale)
        guard let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
        NSColor(white: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        try? bmp.representation(using: .png, properties: [:])?.write(to: url)
        NSLog("snapshot \(url.path) \(w)x\(h)")
    }
}
