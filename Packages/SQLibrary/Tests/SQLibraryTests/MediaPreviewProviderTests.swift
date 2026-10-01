import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import SQMedia
import SQMediaTestSupport
import Testing
import UniformTypeIdentifiers
@testable import SQLibrary

private func request(_ url: URL, kind: PreviewKind, w: Int = 160, h: Int = 90) throws -> PreviewRequest {
    let v = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let hash = ContentHash(path: url.path, modified: v.contentModificationDate!, size: Int64(v.fileSize!))
    return PreviewRequest(entryID: LibraryEntryID(folderID: UUID(), relativePath: url.lastPathComponent), kind: kind, pixelWidth: w, pixelHeight: h, contentHash: hash)
}

private func pngSize(_ url: URL) throws -> (Int, Int) {
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let p = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
    return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
}

private func writeImage(_ url: URL, alpha: Bool, size: Int = 400) throws {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
    let ctx = try #require(CGContext(data: nil, width: size, height: size / 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue))
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size / 2))
    let img = try #require(ctx.makeImage())
    let d = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(d, img, nil)
    #expect(CGImageDestinationFinalize(d))
}

@Test func videoThumbnailIsPNGWithinBounds() async throws {
    let tmp = try TempDir(); defer { tmp.remove() }
    var spec = TestClipSpec(); spec.frameCount = 60
    let clip = try await TestClipWriter.write(spec)
    let cache = PreviewCache(cachesDirectory: tmp.url)
    let provider = MediaPreviewProvider(cache: cache)
    let req = try request(clip, kind: .thumbnail)
    let out = tmp.url.appendingPathComponent("thumb.png")
    try await provider.generate(req, to: out)
    let (w, h) = try pngSize(out)
    #expect(w <= 160 && h <= 90 && max(w, h) >= 90)
    #expect(Double(w) / Double(h) > 1.7 && Double(w) / Double(h) < 1.85)   // 320x180 aspect kept
    #expect(provider.hasAlpha(for: req) == false)
}

@Test func imageThumbnailDownscalesAndReportsAlpha() async throws {
    let tmp = try TempDir(); defer { tmp.remove() }
    let provider = MediaPreviewProvider(cache: PreviewCache(cachesDirectory: tmp.url))
    for alpha in [true, false] {
        let src = tmp.url.appendingPathComponent("img-\(alpha).png")
        try writeImage(src, alpha: alpha)
        let req = try request(src, kind: .thumbnail, w: 100, h: 100)
        #expect(provider.hasAlpha(for: req) == nil)
        let out = tmp.url.appendingPathComponent("out-\(alpha).png")
        try await provider.generate(req, to: out)
        let (w, h) = try pngSize(out)
        #expect(w == 100 && h == 50)
        #expect(provider.hasAlpha(for: req) == alpha)
    }
}

@Test func waveformFileDecodes() async throws {
    let tmp = try TempDir(); defer { tmp.remove() }
    var spec = TestClipSpec(); spec.frameCount = 60; spec.audioClicks = [CMTime(value: 1, timescale: 1)]
    let clip = try await TestClipWriter.write(spec)
    let provider = MediaPreviewProvider(cache: PreviewCache(cachesDirectory: tmp.url))
    let out = tmp.url.appendingPathComponent("a.waveform")
    try await provider.generate(try request(clip, kind: .waveform), to: out)
    let wf = try WaveformData(serialized: try Data(contentsOf: out))
    #expect(wf.bucket(level: 0, index: 48_000 / 256, channel: 0).max == 1)
}

@Test func unsupportedAndStale() async throws {
    let tmp = try TempDir(); defer { tmp.remove() }
    let provider = MediaPreviewProvider(cache: PreviewCache(cachesDirectory: tmp.url))
    let txt = try tmp.write("notes.txt")
    await #expect(throws: MediaPreviewError.unsupported) {
        try await provider.generate(try request(txt, kind: .thumbnail), to: tmp.url.appendingPathComponent("x.png"))
    }
    // Source changes after the request was made: stale, not a wrong-content preview.
    let img = tmp.url.appendingPathComponent("a.png")
    try writeImage(img, alpha: false)
    let req = try request(img, kind: .thumbnail)
    try writeImage(img, alpha: false, size: 800)
    await #expect(throws: PreviewError.stale) {
        try await provider.generate(req, to: tmp.url.appendingPathComponent("y.png"))
    }
}

@Test func alphaCodecDetection() {
    #expect(MediaPreviewProvider.videoCodecHasAlpha(kCMVideoCodecType_AppleProRes4444, containsAlphaExtension: nil))
    #expect(MediaPreviewProvider.videoCodecHasAlpha(kCMVideoCodecType_AppleProRes4444XQ, containsAlphaExtension: nil))
    #expect(MediaPreviewProvider.videoCodecHasAlpha(kCMVideoCodecType_HEVCWithAlpha, containsAlphaExtension: nil))
    #expect(MediaPreviewProvider.videoCodecHasAlpha(kCMVideoCodecType_H264, containsAlphaExtension: true))
    #expect(!MediaPreviewProvider.videoCodecHasAlpha(kCMVideoCodecType_H264, containsAlphaExtension: nil))
    #expect(!MediaPreviewProvider.videoCodecHasAlpha(kCMVideoCodecType_AppleProRes422, containsAlphaExtension: false))
}

@Test func worksThroughCoordinator() async throws {
    let tmp = try TempDir(); defer { tmp.remove() }
    let img = tmp.url.appendingPathComponent("a.png")
    try writeImage(img, alpha: true)
    let cache = PreviewCache(cachesDirectory: tmp.url.appendingPathComponent("caches"))
    let coord = PreviewCoordinator(cache: cache, provider: MediaPreviewProvider(cache: cache))
    let req = try request(img, kind: .thumbnail, w: 64, h: 64)
    let url = try await coord.preview(for: req)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(MediaPreviewProvider(cache: cache).hasAlpha(for: req) == true)
}
