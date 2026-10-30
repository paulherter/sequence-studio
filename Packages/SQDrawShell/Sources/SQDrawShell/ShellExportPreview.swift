import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQExport
import SQUIKit

/// The Export sheet's picture, translated from the Mac `ExportPreviewModel`: a small frame source of the sequence being
/// exported (`ExportDialogModel.previewSource`, the export's own compositor), the frame under the scrub bar, playback at
/// the sequence rate, Space and the arrows. The frame becomes an `RGBAImage` through the host's `frameImage` (the Mac
/// converts its CVPixelBuffer); the sheet draws it from image slot `slot`.
@MainActor
public final class ShellExportPreview {
    public typealias Provider = ExportDialogModel.PreviewSourceProvider
    /// shortcut: borrows the Slip two-up slot (no Slip drag runs while the modal sheet is up); upgrade when the renderers
    /// keep a seventh image slot.
    public static let slot = 1

    /// The host's frame conversion (BGRA frame -> RGBA pixels); nil = no picture on this platform.
    public var frameImage: (@Sendable (ExportFrame) -> RGBAImage?)?
    public private(set) var image: RGBAImage?
    /// Moves with every new picture (the renderer re-uploads the slot).
    public private(set) var generation = 0
    public private(set) var fraction: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    public private(set) var errorText: String?
    public private(set) var frameCount = 0
    public private(set) var frameDuration = Time(1, 30)
    public private(set) var hasProvider = false

    private struct Key: Hashable { var sequence: UUID; var settings: ExportSettings }
    private var key: Key?
    private var source: (any FrameSource)?
    private var loadTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var wanted: Int?
    private var rendering = false
    private(set) var currentIndex = 0

    public init() {}

    /// "00:00:01:12" of the shown frame.
    public var timecode: String { ExportDecodeError.timecode(frameDuration * Int64(currentIndex), frameDuration: frameDuration) }

    /// The note in the box while there is no picture (`ExportDialogView.syncPreview`).
    public var note: String? {
        guard image == nil else { return nil }
        if !hasProvider || frameImage == nil { return SQL10n.string("No preview available") }
        if let errorText { return errorText }
        // The source is ready but its first frame still renders (off the main thread on Windows): keep the note.
        let firstFrame = source != nil && frameCount > 0
        return isLoading || firstFrame ? SQL10n.string("Loading preview\u{2026}") : nil
    }

    /// The selection or the selected format changed: reloads the source only when its inputs changed.
    public func configure(sequenceID: UUID, settings: ExportSettings, provider: Provider?) {
        hasProvider = provider != nil
        guard let provider, frameImage != nil else { return }
        let k = Key(sequence: sequenceID, settings: ExportPreviewMath.previewSettings(from: settings))
        guard k != key else { return }
        let keepFraction = fraction
        let sameSequence = key?.sequence == sequenceID
        key = k
        stop()
        loadTask?.cancel()
        isLoading = true; errorText = nil
        if !sameSequence { image = nil; fraction = 0 }
        loadTask = Task { [weak self] in
            do {
                let src = try await provider(k.sequence, k.settings)
                guard let self, !Task.isCancelled, self.key == k else { return }
                self.source = src
                self.frameCount = src.frameCount
                self.frameDuration = src.frameDuration
                self.isLoading = false
                self.show(index: ExportPreviewMath.index(fraction: sameSequence ? keepFraction : 0, count: src.frameCount))
            } catch {
                guard let self, !Task.isCancelled, self.key == k else { return }
                self.source = nil; self.frameCount = 0; self.isLoading = false
                self.errorText = SQL10n.localized((error as? LocalizedError)?.errorDescription ?? "No preview")
            }
        }
    }

    public func scrub(to f: Double) {
        guard frameCount > 0 else { return }
        stop()
        show(index: ExportPreviewMath.index(fraction: f, count: frameCount))
    }

    public func step(_ delta: Int) {
        guard frameCount > 0 else { return }
        stop()
        show(index: min(max(currentIndex + delta, 0), frameCount - 1))
    }

    public func togglePlay() {
        if isPlaying { stop(); return }
        guard frameCount > 0 else { return }
        if currentIndex >= frameCount - 1 { currentIndex = 0 }
        isPlaying = true
        let start = currentIndex
        let fps = Double(frameDuration.timescale) / Double(max(frameDuration.value, 1))
        let t0 = ContinuousClock.now
        playTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let el = ContinuousClock.now - t0
                let secs = Double(el.components.seconds) + Double(el.components.attoseconds) / 1e18
                let idx = start + Int(secs * fps)
                if idx >= self.frameCount - 1 {
                    await self.render(index: self.frameCount - 1)
                    self.isPlaying = false; self.playTask = nil
                    return
                }
                await self.render(index: idx)
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    public func stop() {
        playTask?.cancel(); playTask = nil
        isPlaying = false
    }

    /// Ends playback and drops the source (the sheet closed).
    public func close() { stop(); loadTask?.cancel(); source = nil; key = nil }

    private func show(index: Int) {
        currentIndex = index
        fraction = ExportPreviewMath.fraction(index: index, count: frameCount)
        Task { await render(index: index) }
    }

    /// Latest request wins; frames that arrive late are skipped.
    private func render(index: Int) async {
        wanted = index
        if rendering { return }
        rendering = true
        defer { rendering = false }
        while let i = wanted, let src = source {
            wanted = nil
            do {
                let frame = try await src.frame(at: i)
                if let img = frameImage?(frame) {
                    image = img; generation &+= 1; currentIndex = i
                    fraction = ExportPreviewMath.fraction(index: i, count: frameCount)
                    errorText = nil
                }
            } catch {
                errorText = SQL10n.localized((error as? LocalizedError)?.errorDescription ?? "Frame could not be drawn")
            }
        }
    }
}
