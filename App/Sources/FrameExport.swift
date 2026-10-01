import AppKit
import Metal
import UniformTypeIdentifiers

/// Export Frame (Shift+E): saves the picture on screen as PNG or JPEG. The compositor's texture is working-linear
/// rgba16Float; the viewer applies the BT.709 transfer curve, so the export does too (what you see is what you get).
@MainActor
enum FrameExport {
    /// A private copy of one rendered frame (a GPU buffer, filled by a blit and finished before this value exists), so
    /// nothing the render loop does afterwards can tear it.
    struct Snapshot: @unchecked Sendable {
        let buffer: MTLBuffer
        let width: Int
        let height: Int
    }

    /// Shows the save panel and writes the file. `texture` is the engine's last rendered frame at sequence resolution;
    /// callers pause playback first. Conversion, encoding and writing run off the main thread.
    static func run(texture: MTLTexture?, suggestedName: String, on window: NSWindow?, status: @escaping @MainActor @Sendable (String) -> Void) {
        guard let texture, let snap = snapshot(of: texture) else { status("There is no frame to export yet."); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24), pullsDown: false)
        popup.addItems(withTitles: ["PNG", "JPEG"])
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = row
        let handler = FormatHandler(panel: panel, popup: popup)
        popup.target = handler; popup.action = #selector(FormatHandler.changed)
        let finish: (NSApplication.ModalResponse) -> Void = { r in
            _ = handler
            guard r == .OK, let url = panel.url else { return }
            let jpeg = popup.indexOfSelectedItem == 1
            status("Exporting \(url.lastPathComponent)…")
            Task.detached(priority: .userInitiated) {
                var message: String
                do {
                    guard let image = cgImage(from: snap) else { throw CocoaError(.fileWriteUnknown) }
                    let rep = NSBitmapImageRep(cgImage: image)
                    guard let data = rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.95] : [:]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try data.write(to: url)
                    message = "Exported \(url.lastPathComponent)"
                } catch { message = "Could not save the frame: \(error.localizedDescription)" }
                await MainActor.run { status(message) }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    static func snapshot(of texture: MTLTexture) -> Snapshot? {
        guard texture.pixelFormat == .rgba16Float else { return nil }
        let w = texture.width, h = texture.height, bpr = w * 8
        guard let queue = texture.device.makeCommandQueue(),
              let buf = texture.device.makeBuffer(length: bpr * h, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        return Snapshot(buffer: buf, width: w, height: h)
    }

    @MainActor private final class FormatHandler: NSObject {
        let panel: NSSavePanel, popup: NSPopUpButton
        init(panel: NSSavePanel, popup: NSPopUpButton) { self.panel = panel; self.popup = popup }
        @objc func changed() {
            let jpeg = popup.indexOfSelectedItem == 1
            panel.allowedContentTypes = [jpeg ? .jpeg : .png]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + (jpeg ? ".jpg" : ".png")
        }
    }

    /// BT.709 OETF of a linear value.
    nonisolated static func oetf(_ x: Float) -> Float {
        let v = min(max(x, 0), 1)
        return v < 0.018053968510807 ? 4.5 * v : 1.09929682680944 * powf(v, 0.45) - 0.09929682680944
    }

    nonisolated static func cgImage(from snap: Snapshot) -> CGImage? {
        let w = snap.width, h = snap.height
        let buf = snap.buffer
        let src = buf.contents().assumingMemoryBound(to: Float16.self)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 { out[i * 4 + c] = UInt8((oetf(Float(src[i * 4 + c])) * 255).rounded()) }
        }
        let space = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
