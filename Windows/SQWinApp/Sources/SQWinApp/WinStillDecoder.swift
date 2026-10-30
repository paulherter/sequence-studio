import Foundation
import SQCore
import SQDrawKit
import SQMedia
import SQMediaFFmpeg
import Synchronization

/// Decodes a still picture held in memory (the PNG of a saved multi-layer template, `TemplatePictureDecoder.platform`)
/// with FFmpeg: written to a temporary file, the first frame decoded in software like the timeline thumbnails.
/// A PNG goes through `SQCore.PortablePNG` first (straight RGBA, transparency kept); anything else, or a PNG it cannot read
/// (interlaced), falls to FFmpeg.
/// shortcut: the FFmpeg path comes back through NV12, so a transparent non-PNG picture shows on black and colors pass
/// 4:2:0; decode RGBA straight from FFmpeg when such pictures show up.
enum WinStillDecoder {
    static func decode(_ data: Data) -> RGBAImage? {
        if let png = PortablePNG.decode(data) { return RGBAImage(width: png.width, height: png.height, pixels: png.rgba) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-still-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let demuxer = try? FFmpegDemuxer(url: url),
              let decoder = try? FFmpegVideoDecoder(demuxer: demuxer, media: UUID(), hardware: false),
              demuxer.index.count > 0 else { return nil }
        let box = Mutex<RGBAImage?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard let f = try? await decoder.decode(0...0).first,
                  let ff = f.frame.storage as? FFmpegFrame, var bytes = try? ff.download() else { return }
            let w = f.frame.width, h = f.frame.height
            if bytes.count >= w * h * 3 { bytes = (0..<(w * h * 3 / 2)).map { bytes[$0 * 2 + 1] } }   // P010: high bytes
            let full = f.frame.pixelFormat == .nv12FullRange || f.frame.pixelFormat == .p010FullRange
            box.withLock { $0 = RGBAImage(nv12: bytes, width: w, height: h, fullRange: full) }
        }
        withExtendedLifetime(demuxer) { done.wait() }
        return box.withLock { $0 }
    }
}
