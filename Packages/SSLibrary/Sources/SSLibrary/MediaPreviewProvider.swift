import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import SSMedia
import UniformTypeIdentifiers

public enum MediaPreviewError: Error, Equatable, Sendable {
    case unsupported
    case decodeFailed(String)
}

/// `PreviewProvider` backed by AVFoundation / ImageIO.
/// - thumbnail: video frame at 10 % of the duration (first frame as fallback), or a downscaled image; written as PNG,
///   fitted inside `pixelWidth x pixelHeight` (aspect preserved, never upscaled for images).
/// - waveform: `WaveformBuilder` peak pyramid in `WaveformData`'s binary format.
/// Generating a thumbnail also probes alpha and stores it in a small sidecar next to the thumbnails, keyed by
/// content only (not size): `<caches>/.../thumbnail/<contentKey>.alpha`. See `hasAlpha(for:)`.
public struct MediaPreviewProvider: PreviewProvider {
    private let cache: PreviewCache

    public init(cache: PreviewCache) { self.cache = cache }

    public func generate(_ request: PreviewRequest, to destination: URL) async throws {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: request.contentHash.path)
        switch request.kind {
        case .thumbnail: try await makeThumbnail(request, url: url, to: destination)
        case .waveform:
            let data = try await WaveformBuilder.build(url: url).serialized()
            try Task.checkCancellation()
            try data.write(to: destination)
        }
        try Task.checkCancellation()
        try checkUnchanged(request, url: url)
    }

    /// Alpha probed while making the thumbnail; nil if no thumbnail has been generated for this content yet.
    public func hasAlpha(for request: PreviewRequest) -> Bool? {
        guard let s = try? String(contentsOf: alphaURL(for: request.contentHash), encoding: .utf8) else { return nil }
        return s == "1"
    }

    private func alphaURL(for hash: ContentHash) -> URL {
        cache.root.appendingPathComponent(PreviewKind.thumbnail.rawValue, isDirectory: true)
            .appendingPathComponent("\(hash.key).alpha")
    }

    /// Throws `.stale` if the source file no longer matches the request's content hash.
    private func checkUnchanged(_ request: PreviewRequest, url: URL) throws {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let m = v?.contentModificationDate, let s = v?.fileSize else { throw PreviewError.stale }
        if Int64(s) != request.contentHash.size || abs(m.timeIntervalSince(request.contentHash.modified)) > 0.001 {
            throw PreviewError.stale
        }
    }

    // MARK: Thumbnail

    private func makeThumbnail(_ request: PreviewRequest, url: URL, to destination: URL) async throws {
        let maxSize = CGSize(width: max(request.pixelWidth, 1), height: max(request.pixelHeight, 1))
        let image: CGImage
        let alpha: Bool
        switch LibraryItemKind.classify(url) {
        case .video, .overlay:
            (image, alpha) = try await videoThumbnail(url: url, maxSize: maxSize)
        case .image:
            (image, alpha) = try imageThumbnail(url: url, maxSize: maxSize)
        default:
            throw MediaPreviewError.unsupported
        }
        try Task.checkCancellation()
        try writePNG(image, to: destination)
        try writeAlpha(alpha, for: request.contentHash)
    }

    private func videoThumbnail(url: URL, maxSize: CGSize) async throws -> (CGImage, Bool) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaPreviewError.unsupported }
        let formats = try await track.load(.formatDescriptions)
        let alpha = formats.contains { Self.videoFormatHasAlpha($0) }
        let duration = try await asset.load(.duration)

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maxSize
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity

        var times: [CMTime] = []
        if duration.isNumeric, duration > .zero {
            // 10 % in: exact rational (value*1 / timescale*10), no Double.
            times.append(CMTime(value: duration.value, timescale: duration.timescale * 10).convertScale(duration.timescale, method: .roundHalfAwayFromZero))
        }
        times.append(.zero)
        var lastError: (any Error)?
        for t in times {
            try Task.checkCancellation()
            do {
                let (image, _) = try await gen.image(at: t)
                return (image, alpha)
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        throw MediaPreviewError.decodeFailed(lastError?.localizedDescription ?? "no frame")
    }

    private func imageThumbnail(url: URL, maxSize: CGSize) throws -> (CGImage, Bool) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw MediaPreviewError.decodeFailed("open image") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let alpha = (props?[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(maxSize.width, maxSize.height)),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw MediaPreviewError.decodeFailed("downscale image")
        }
        return (img, alpha)
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MediaPreviewError.decodeFailed("png destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw MediaPreviewError.decodeFailed("png write") }
    }

    private func writeAlpha(_ alpha: Bool, for hash: ContentHash) throws {
        let u = alphaURL(for: hash)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((alpha ? "1" : "0").utf8).write(to: u, options: .atomic)
    }

    // MARK: Alpha detection

    /// ProRes 4444 (XQ), HEVC with alpha, or a format description flagged `ContainsAlphaChannel`.
    static func videoFormatHasAlpha(_ desc: CMFormatDescription) -> Bool {
        let ext = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool
        return videoCodecHasAlpha(CMFormatDescriptionGetMediaSubType(desc), containsAlphaExtension: ext)
    }

    static func videoCodecHasAlpha(_ codec: FourCharCode, containsAlphaExtension: Bool?) -> Bool {
        if containsAlphaExtension == true { return true }
        switch codec {
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ, kCMVideoCodecType_HEVCWithAlpha:
            return true
        default:
            return false
        }
    }
}
