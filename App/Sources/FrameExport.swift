import AppKit
import Metal
import SQEditorUI
import SQExport
import SQPlayback
import UniformTypeIdentifiers

/// Export Frame (Shift+E): saves the picture on screen as PNG, JPEG, 16-bit TIFF (PNG and TIFF also with alpha) or EXR. The compositor's texture is working-linear
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

    /// Export Frame from `ProgramEngine.withFullSizeFrame`: the save panel for a frame, a status line when there is none
    /// (a second Export Frame while one waits, or a canceled one, stays silent: the first one shows its panel).
    static func run(_ result: FullSizeFrameResult, suggestedName: String, on window: NSWindow?,
                    status: @escaping @MainActor @Sendable (String) -> Void) {
        switch result {
        case .frame(let texture): run(texture: texture, suggestedName: suggestedName, on: window, status: status)
        case .failed(.timedOut): status("The frame took too long to load. Nothing was exported.")
        case .failed(.incomplete): status("The frame is not complete (offline or damaged media). Nothing was exported.")
        case .failed(.busy), .failed(.cancelled): break
        }
    }

    /// Shows the save panel and writes the file. `texture` is the engine's last rendered frame at sequence resolution;
    /// callers pause playback first. Conversion, encoding and writing run off the main thread.
    static func run(texture: MTLTexture?, suggestedName: String, on window: NSWindow?, status: @escaping @MainActor @Sendable (String) -> Void) {
        // The blit is committed now (the render loop may move on); only the wait for the GPU is off the main thread.
        guard let texture, let pending = beginSnapshot(of: texture) else { status("There is no frame to export yet."); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let popup = SQPopup(frame: NSRect(x: 0, y: 0, width: 120, height: Theme.Row.controlLarge), pullsDown: false)
        popup.boxHeight = Theme.Row.controlLarge
        let formats = FrameStillFormat.available
        popup.addItems(withTitles: formats.map(\.displayName))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = row
        let handler = FormatHandler(panel: panel, popup: popup, formats: formats)
        popup.target = handler; popup.action = #selector(FormatHandler.changed)
        let finish: (NSApplication.ModalResponse) -> Void = { r in
            _ = handler
            guard r == .OK, let url = panel.url else { return }
            let format = formats[min(max(popup.indexOfSelectedItem, 0), formats.count - 1)]
            status(SQL10n.format("Exporting %@…", url.lastPathComponent))
            Task.detached(priority: .userInitiated) {
                var message: String
                do {
                    let snap = await pending.finished()
                    let count = snap.width * snap.height * 4
                    let pixels = UnsafeBufferPointer(start: snap.buffer.contents().assumingMemoryBound(to: Float16.self), count: count)
                    try FrameStillWriter.write(pixels: pixels, width: snap.width, height: snap.height, format: format, to: url)
                    message = SQL10n.format("Exported %@", url.lastPathComponent)
                } catch { message = SQL10n.format("Could not save the frame: %@", SQL10n.errorText(error)) }
                await MainActor.run { status(message) }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// A snapshot whose GPU copy was committed but may not have finished: `finished()` waits without blocking a thread.
    struct PendingSnapshot: @unchecked Sendable {
        let snapshot: Snapshot
        let commandBuffer: MTLCommandBuffer
        func finished() async -> Snapshot {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                commandBuffer.addCompletedHandler { _ in cont.resume() }
            }
            return snapshot
        }
    }

    /// Encodes and commits the copy of `texture` and returns at once (no wait on the main thread).
    static func beginSnapshot(of texture: MTLTexture) -> PendingSnapshot? {
        guard texture.pixelFormat == .rgba16Float else { return nil }
        let w = texture.width, h = texture.height, bpr = w * 8
        guard let queue = texture.device.makeCommandQueue(),
              let buf = texture.device.makeBuffer(length: bpr * h, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
        blit.endEncoding()
        cb.commit()
        return PendingSnapshot(snapshot: Snapshot(buffer: buf, width: w, height: h), commandBuffer: cb)
    }

    /// Synchronous variant for callers that need the pixels at once (title template thumbnails).
    static func snapshot(of texture: MTLTexture) -> Snapshot? {
        guard let p = beginSnapshot(of: texture) else { return nil }
        p.commandBuffer.waitUntilCompleted()
        return p.snapshot
    }

    @MainActor private final class FormatHandler: NSObject {
        let panel: NSSavePanel, popup: NSPopUpButton, formats: [FrameStillFormat]
        init(panel: NSSavePanel, popup: NSPopUpButton, formats: [FrameStillFormat]) {
            self.panel = panel; self.popup = popup; self.formats = formats
        }
        @objc func changed() {
            let f = formats[min(max(popup.indexOfSelectedItem, 0), formats.count - 1)]
            if let type = UTType(f.typeIdentifier) { panel.allowedContentTypes = [type] }
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "." + f.fileExtension
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
