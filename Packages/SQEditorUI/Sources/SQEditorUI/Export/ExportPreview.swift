import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import SQCore
import SQExport

/// Drives the export dialog's picture: loads a small frame source of the sequence being exported (same compositor as the
/// export, so text, captions burn-in and color match), shows the frame under the scrub bar and plays at the sequence rate.
/// Not observable: the view subscribes with `onChange`.
@MainActor
public final class ExportPreviewModel {
    public typealias Provider = ExportDialogModel.PreviewSourceProvider

    public var onChange: (() -> Void)?
    public private(set) var image: CGImage?
    public private(set) var fraction: Double = 0
    public private(set) var isPlaying = false
    public private(set) var isLoading = false
    public private(set) var errorText: String?
    public private(set) var frameCount = 0
    public private(set) var frameDuration = Time(1, 30)

    private struct Key: Hashable { var sequence: UUID; var settings: ExportSettings }
    private var key: Key?
    private var source: (any FrameSource)?
    private var loadTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var wanted: Int?
    private var rendering = false
    private var currentIndex = 0
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    public init() {}

    /// Timecode of the shown frame, "00:00:01:12".
    public var timecode: String {
        ExportDecodeError.timecode(frameDuration * Int64(currentIndex), frameDuration: frameDuration)
    }

    public var durationTimecode: String {
        ExportDecodeError.timecode(frameDuration * Int64(frameCount), frameDuration: frameDuration)
    }

    /// Call whenever the selection or the selected format changes: reloads the source only when its inputs changed.
    public func configure(sequenceID: UUID, settings: ExportSettings, provider: Provider?) {
        guard let provider else { return }
        let k = Key(sequence: sequenceID, settings: ExportPreviewMath.previewSettings(from: settings))
        guard k != key else { return }
        let keepFraction = fraction
        let sameSequence = key?.sequence == sequenceID
        key = k
        stop()
        loadTask?.cancel()
        isLoading = true; errorText = nil
        if !sameSequence { image = nil; fraction = 0 }
        onChange?()
        loadTask = Task { [weak self] in
            do {
                let src = try await provider(k.sequence, k.settings)
                guard let self, !Task.isCancelled, self.key == k else { return }
                self.source = src
                self.frameCount = src.frameCount
                self.frameDuration = src.frameDuration
                self.isLoading = false
                let target = sameSequence ? keepFraction : 0
                self.show(index: ExportPreviewMath.index(fraction: target, count: src.frameCount))
            } catch {
                guard let self, !Task.isCancelled, self.key == k else { return }
                self.source = nil; self.frameCount = 0; self.isLoading = false
                self.errorText = SQL10n.localized((error as? LocalizedError)?.errorDescription ?? "No preview")
                self.onChange?()
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
        onChange?()
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
                    self.isPlaying = false; self.playTask = nil; self.onChange?()
                    return
                }
                await self.render(index: idx)
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    public func stop() {
        playTask?.cancel(); playTask = nil
        if isPlaying { isPlaying = false; onChange?() }
    }

    /// Ends playback and drops the source (dialog closed).
    public func close() {
        stop(); loadTask?.cancel(); source = nil; key = nil; onChange = nil
    }

    // MARK: Rendering (latest request wins; frames that arrive late are skipped)

    private func show(index: Int) {
        currentIndex = index
        fraction = ExportPreviewMath.fraction(index: index, count: frameCount)
        onChange?()
        Task { await render(index: index) }
    }

    private func render(index: Int) async {
        wanted = index
        if rendering { return }
        rendering = true
        defer { rendering = false }
        while let i = wanted, let src = source {
            wanted = nil
            do {
                let buffer = try await src.frame(at: i)
                if let cg = Self.cgImage(from: buffer) {
                    image = cg; currentIndex = i
                    fraction = ExportPreviewMath.fraction(index: i, count: frameCount)
                    errorText = nil
                }
            } catch {
                errorText = SQL10n.localized((error as? LocalizedError)?.errorDescription ?? "Frame could not be drawn")
            }
            onChange?()
        }
    }

    private static func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(ci, from: ci.extent)
    }
}
