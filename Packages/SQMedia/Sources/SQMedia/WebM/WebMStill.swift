import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SQCore

/// Single frames of a WebM file (thumbnails, previews): AVAssetImageGenerator cannot read these files.
public enum WebMStill {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The frame shown at `time` (media time, 0 = first frame), scaled to `height` pixels (0 = full size).
    /// Not exact: the nearest earlier key frame, which decodes without the GOP before it.
    public static func cgImage(url: URL, time: CMTime, height: Int, exact: Bool) async throws -> CGImage {
        let demux = try await WebMDemuxer(url: url)
        let index = demux.index
        let t = Time(time) ?? .zero
        var i = index.frame(at: t) ?? (t < .zero ? 0 : index.count - 1)
        if !exact { i = index.entries[i].isSync ? i : index.previousSync(before: i) }
        let h = Int(CMVideoFormatDescriptionGetDimensions(demux.formatDescription).height)
        let scale: DecodeScale = height > 0 && height * 4 <= h ? .quarter : height > 0 && height * 2 <= h ? .half : .full
        let decoder = try VTVideoDecoder(demuxer: demux, media: UUID(), scale: scale)
        let frames = try await decoder.decode(i...i)
        decoder.invalidate()
        guard let frame = frames.first else { throw MediaError.truncated }
        return try image(frame.pixelBuffer, height: height)
    }

    /// A representative frame (10 % into the clip) for library thumbnails.
    public static func previewImage(url: URL, maxHeight: Int) async throws -> CGImage {
        let d = try await WebMDemuxer(url: url).index.duration
        return try await cgImage(url: url, time: Time(d.value, d.timescale * 10).cmTime, height: maxHeight, exact: false)
    }

    public static func image(_ pb: CVPixelBuffer, height: Int) throws -> CGImage {
        var ci = CIImage(cvPixelBuffer: pb)
        let h = ci.extent.height
        if height > 0, h > CGFloat(height) { let s = CGFloat(height) / h; ci = ci.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
        guard let cg = context.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw MediaError.decodeFailed(-1)
        }
        return cg
    }
}
