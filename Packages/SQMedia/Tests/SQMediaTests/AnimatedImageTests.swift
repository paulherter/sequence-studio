import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SQCore
import Testing
import UniformTypeIdentifiers
@testable import SQMedia

// CREATOR 7: animated GIF / APNG / WebP and numbered PNG sequences import as a clip. The frames are rendered once into a
// cached ProRes 4444 strip (alpha kept) that the normal video path plays; the project file needs no new field.

/// Every test that calls this must `defer { try? FileManager.default.removeItem(at: dir) }`.
private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("SQAnim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func solid(_ w: Int, _ h: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// Writes an animated GIF (`delays` in seconds) or APNG.
private func writeAnimated(_ type: UTType, to url: URL, frames: [CGImage], delays: [Double]) throws {
    let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames.count, nil)!
    let key: CFString = type == .gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
    let delayKey: CFString = type == .gif ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
    CGImageDestinationSetProperties(dst, [key: [(type == .gif ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount): 0]] as CFDictionary)
    for (i, f) in frames.enumerated() { CGImageDestinationAddImage(dst, f, [key: [delayKey: delays[i]]] as CFDictionary) }
    #expect(CGImageDestinationFinalize(dst))
}

private func writePNG(_ img: CGImage, to url: URL) {
    let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
}

// MARK: Pure logic

@Test func delayIsClampedLikeBrowsers() {
    #expect(AnimatedImage.frameDuration(seconds: 0.2) == Time(200, 1000))
    #expect(AnimatedImage.frameDuration(seconds: 0.0) == Time(100, 1000))     // 0 and <= 10 ms play at 100 ms
    #expect(AnimatedImage.frameDuration(seconds: 0.01) == Time(100, 1000))
    #expect(AnimatedImage.frameDuration(seconds: nil) == Time(100, 1000))
    #expect(AnimatedImage.frameDuration(seconds: 0.033) == Time(33, 1000))
}

@Test func sequenceGroupsNumberedFiles() {
    let d = URL(fileURLWithPath: "/tmp/x")
    func u(_ n: String) -> URL { d.appendingPathComponent(n) }
    let urls = [u("fx_0003.png"), u("fx_0001.png"), u("fx_0002.png"), u("photo.png"), u("other_1.png")]
    let groups = ImageSequence.groups(in: urls)
    #expect(groups.count == 1)
    #expect(groups[0].map(\.lastPathComponent) == ["fx_0001.png", "fx_0002.png", "fx_0003.png"])
}

@Test func sequenceSplitsAtGapsAndMixedExtensions() {
    let d = URL(fileURLWithPath: "/tmp/x")
    func u(_ n: String) -> URL { d.appendingPathComponent(n) }
    let urls = [u("a1.png"), u("a2.png"), u("a5.png"), u("a6.png"), u("a7.png"), u("a8.jpg"), u("b.png")]
    let g = ImageSequence.groups(in: urls)
    #expect(g.map { $0.map(\.lastPathComponent) } == [["a1.png", "a2.png"], ["a5.png", "a6.png", "a7.png"]])
}

@Test func singleNumberedFileIsNotASequence() {
    #expect(ImageSequence.groups(in: [URL(fileURLWithPath: "/tmp/x/shot_01.png")]).isEmpty)
    #expect(ImageSequence.groups(in: [URL(fileURLWithPath: "/tmp/x/a1.mov"), URL(fileURLWithPath: "/tmp/x/a2.mov")]).isEmpty)
}

@Test func straightAlphaConversion() {
    var px: [UInt8] = [64, 32, 16, 128,   10, 20, 30, 0,   200, 100, 50, 255]    // BGRA premultiplied
    px.withUnsafeMutableBytes { AnimatedImage.unpremultiply($0.baseAddress!, pixels: 3) }
    #expect(abs(Int(px[0]) - 127) <= 1 && abs(Int(px[1]) - 64) <= 1 && abs(Int(px[2]) - 32) <= 1 && px[3] == 128)
    #expect(px[4] == 0 && px[5] == 0 && px[6] == 0 && px[7] == 0)
    #expect(px[8] == 200 && px[11] == 255)
}

// MARK: Import

@Test func animatedGIFImportsAsCachedStrip() async throws {
    let dir = try tempDir(), cache = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: cache) }
    let gif = dir.appendingPathComponent("pop.gif")
    try writeAnimated(.gif, to: gif, frames: [solid(48, 32, r: 255, g: 0, b: 0), solid(48, 32, r: 0, g: 255, b: 0), solid(48, 32, r: 0, g: 0, b: 255)],
                      delays: [0.1, 0.2, 0.1])
    let info = try #require(AnimatedImage.info(of: gif))
    #expect(info.count == 3 && info.delays == [Time(100, 1000), Time(200, 1000), Time(100, 1000)])
    #expect(info.duration == Time(400, 1000))

    let (ref, media) = try await MediaImporter.probeAnimated(gif, cache: cache)
    #expect(ref.name == "pop.gif" && ref.path.hasPrefix(cache.path) && ref.path.hasSuffix(".mov"))
    #expect(!media.isStill && media.duration == Time(4, 10) && media.video?.width == 48 && media.video?.height == 32)
    #expect(media.audio == nil)
    // Re-importing reuses the strip.
    let stamp = try FileManager.default.attributesOfItem(atPath: ref.path)[.modificationDate] as? Date
    let (again, _) = try await MediaImporter.probeAnimated(gif, cache: cache)
    #expect(again.path == ref.path)
    #expect(try FileManager.default.attributesOfItem(atPath: ref.path)[.modificationDate] as? Date == stamp)
}

@Test func animatedPNGKeepsAlpha() async throws {
    let dir = try tempDir(), cache = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: cache) }
    let png = dir.appendingPathComponent("a.png")
    try writeAnimated(.png, to: png, frames: [solid(32, 32, r: 255, g: 0, b: 0, a: 128), solid(32, 32, r: 255, g: 0, b: 0, a: 128)], delays: [0.1, 0.1])
    #expect(AnimatedImage.info(of: png)?.count == 2)
    let (ref, media) = try await MediaImporter.probeAnimated(png, cache: cache)
    #expect(media.duration == Time(2, 10))
    let dec = try VTVideoDecoder(demuxer: try await AVDemuxer(url: URL(fileURLWithPath: ref.path)), media: UUID())
    #expect(dec.alpha == .straight)
}

@Test func singleFrameImageIsNotAnimated() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let png = dir.appendingPathComponent("still.png")
    writePNG(solid(16, 16, r: 1, g: 2, b: 3), to: png)
    #expect(AnimatedImage.info(of: png) == nil)
}

@Test func pngSequenceImportsAtTheGivenFrameRate() async throws {
    let dir = try tempDir(), cache = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: cache) }
    let urls = (1...4).map { dir.appendingPathComponent(String(format: "fx_%03d.png", $0)) }
    for (i, u) in urls.enumerated() { writePNG(solid(40, 24, r: UInt8(i * 60), g: 0, b: 0), to: u) }
    let (ref, media) = try await MediaImporter.probeSequence(urls, fps: 24, cache: cache)
    #expect(ref.name == "fx_[001-004].png")
    #expect(media.duration == Time(4, 24) && media.video?.width == 40 && !media.isStill)
}

@Test func brokenAnimationFailsCleanly() async throws {
    let dir = try tempDir(), cache = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: cache) }
    let bad = dir.appendingPathComponent("bad.gif")
    try Data("not an image".utf8).write(to: bad)
    await #expect(throws: (any Error).self) { _ = try await MediaImporter.probeAnimated(bad, cache: cache) }
}
