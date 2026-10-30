import AppKit
import Metal
import SQAppShell
import SQAudioFX
import SQCore
import SQEditorSession
import SQPlayback

/// The Mac backend of the shared hosts' engine seam (`AppMonitorEngine`): a `PlaybackEngine` (Program, Source) presents
/// into its monitor's CAMetalLayer itself (SharedUIController's viewers); a layerless one (a pane of the slip / trim
/// two-up) renders on `tick`. the Scopes get a CPU copy through the engine's frame
/// capture (blit into a shared texture on the render loop's command buffer, read back once it finished).
/// shortcut: the copy is rgba16Float or 8-bit BGRA/RGBA read as display values, every second pixel past 960 px wide; the
/// AppKit Scopes measure the texture on the GPU. Upgrade with GPU scopes (the Windows port plan "Missing").
@MainActor
final class MacPictureTap: AppMonitorEngine {
    private let engine: any ProgramEngine
    private let layerless: Bool
    /// The window the Export Frame save panel sheets on.
    var window: () -> NSWindow? = { nil }
    private var latest: AppPicture?
    private var inFlight = false
    private(set) var pictureGeneration = 0
    private let copies = CaptureCopies()

    init(engine: any ProgramEngine, layerless: Bool = false) {
        self.engine = engine
        self.layerless = layerless
    }

    var player: any ProgramEngine { engine }

    func tick() { if layerless { (engine as? PlaybackEngine)?.tick() } }

    func setMedia(_ media: [MediaRef]) {}   // the engines share the session's ProjectMediaResolver

    /// Export Frame: the engine's full-size render (playback paused), as the AppKit UI's `exportProgramFrame`.
    func exportFrame(suggestedName: String, files: (any PanelFileChooser)?, status: @escaping @MainActor @Sendable (String) -> Void) {
        guard let engine = engine as? PlaybackEngine else { status("There is no frame to export yet."); return }
        engine.pause()
        let window = window()
        Task { @MainActor in
            await engine.withFullSizeFrame { FrameExport.run($0, suggestedName: suggestedName, on: window, status: status) }
        }
    }

    var hasPicture: Bool { engine.lastRenderedTexture != nil }
    var skippedFrames: Int { engine.droppedFrames }

    /// The last copy; asks for the next one (one in flight at a time), so the scopes follow playback a frame behind.
    func scopePicture() -> AppPicture? {
        if !inFlight {
            inFlight = true
            let copies = copies
            engine.requestFrameCapture(key: "sharedUI.scopes") { [weak self] frame, cb in
                guard let copy = copies.target(for: frame), let blit = cb.makeBlitCommandEncoder() else { return nil }
                blit.copy(from: frame, to: copy)
                blit.endEncoding()
                let box = UncheckedTexture(texture: copy)
                return {
                    let picture = MacPictureTap.read(box.texture)
                    Task { @MainActor in self?.landed(picture) }
                }
            }
            // A stand-in engine never captures: do not wait forever. Paused, nothing renders by itself: re-present once.
            if engine.lastRenderedTexture == nil { inFlight = false } else if engine.rate.isPaused { engine.redraw() }
        }
        return latest
    }

    private func landed(_ p: AppPicture?) {
        inFlight = false
        guard let p else { return }
        latest = p
        pictureGeneration += 1
    }

    func setMonitorGain(_ setting: MonitorGain.Setting) {
        // Nothing to forward: MeterPanel saves the setting (`MonitorGain.store`) and the Mac AudioEngine's
        // MonitorGainDriver follows UserDefaults changes and ramps by itself.
    }

    func setChannelMonitor(_ state: ChannelMonitor) { (engine as? PlaybackEngine)?.audio?.setChannelMonitor(state) }

    /// Reads a shared-storage copy to 8-bit RGBA (display values clamped).
    nonisolated static func read(_ t: MTLTexture) -> AppPicture? {
        let step = t.width > 960 ? 2 : 1
        let w = t.width / step, h = t.height / step
        guard w > 0, h > 0 else { return nil }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let region = MTLRegionMake2D(0, 0, t.width, t.height)
        switch t.pixelFormat {
        case .rgba16Float:
            var src = [Float16](repeating: 0, count: t.width * t.height * 4)
            src.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width * 8, from: region, mipmapLevel: 0) }
            for y in 0..<h {
                for x in 0..<w {
                    let s = ((y * step) * t.width + x * step) * 4, d = (y * w + x) * 4
                    for c in 0..<3 { out[d + c] = UInt8(max(0, min(1, Float(src[s + c]))) * 255 + 0.5) }
                }
            }
        case .bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb:
            var src = [UInt8](repeating: 0, count: t.width * t.height * 4)
            src.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: region, mipmapLevel: 0) }
            let bgra = t.pixelFormat == .bgra8Unorm || t.pixelFormat == .bgra8Unorm_srgb
            for y in 0..<h {
                for x in 0..<w {
                    let s = ((y * step) * t.width + x * step) * 4, d = (y * w + x) * 4
                    out[d] = src[s + (bgra ? 2 : 0)]; out[d + 1] = src[s + 1]; out[d + 2] = src[s + (bgra ? 0 : 2)]
                }
            }
        default:
            return nil
        }
        return AppPicture(bytes: out, width: w, height: h, fullRange: true, rgba: true)
    }
}

private struct UncheckedTexture: @unchecked Sendable { let texture: MTLTexture }

/// One shared-storage copy texture, remade when the composite's size or format changes (render thread only).
private final class CaptureCopies: @unchecked Sendable {
    private var texture: MTLTexture?

    func target(for frame: MTLTexture) -> MTLTexture? {
        if let t = texture, t.width == frame.width, t.height == frame.height, t.pixelFormat == frame.pixelFormat { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: frame.pixelFormat, width: frame.width,
                                                         height: frame.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = [.shaderRead]
        texture = frame.device.makeTexture(descriptor: d)
        return texture
    }
}
