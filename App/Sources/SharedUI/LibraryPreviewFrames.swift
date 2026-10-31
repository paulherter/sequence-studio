import AVFoundation
import SQAppShell
import SQDrawKit
import SQLibrary

/// The playing Library video as pictures for an image slot: an `AVPlayerItemVideoOutput` on the preview player's item,
/// scaled down to 480 px wide, read once per drawn frame (the shared Library panel's viewer, `LibraryDrawPanel.previewFrame`).
/// shortcut: shares image slot 1 with the Slip two-up, Mask Tint and the Export sheet and yields to them while they show;
/// upgrade when the renderer has a free slot.
@MainActor
final class LibraryPreviewFrames {
    static let slot = 1
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var image: RGBAImage?
    private var generation = 0
    /// Set by the last `current` call: the panel may draw `slot` now.
    private(set) var size: CGSize?

    /// The newest frame as (slot, image, generation); nil when no video previews or the slot is taken.
    func current(_ host: LibraryHost, slotTaken: Bool) -> (Int, RGBAImage, Int)? {
        let preview = host.model.preview
        guard !slotTaken, preview.mode == .video, let player = preview.player, let item = player.currentItem,
              item.presentationSize.width > 0 else { reset(); return nil }
        if self.item !== item {
            reset()
            let s = item.presentationSize
            let w = min(480, s.width), h = max((w * s.height / s.width).rounded(), 1)
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(w), kCVPixelBufferHeightKey as String: Int(h),
            ])
            item.add(out)
            output = out
            self.item = item
        }
        guard let output else { return nil }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: t), let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
           let img = SharedUIController.rgbaImage(bgra: pb) {
            image = img
            generation += 1
        }
        guard let image else { size = nil; return nil }
        size = CGSize(width: image.width, height: image.height)
        return (Self.slot, image, 3_000_000 + generation)
    }

    private func reset() {
        if let output, let item { item.remove(output) }
        output = nil; item = nil; image = nil; size = nil
    }
}
