import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import SSCore
import SSMediaTestSupport
import Testing
import UniformTypeIdentifiers
@testable import SSMedia

@Test func quarterTurnFromTransform() {
    #expect(quarterTurnRotation(of: .identity) == 0)
    #expect(quarterTurnRotation(of: CGAffineTransform(rotationAngle: .pi / 2)) == 90)
    #expect(quarterTurnRotation(of: CGAffineTransform(rotationAngle: .pi)) == 180)
    #expect(quarterTurnRotation(of: CGAffineTransform(rotationAngle: -.pi / 2)) == 270)
    // iPhone portrait: a=0 b=1 c=-1 d=0
    #expect(quarterTurnRotation(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)) == 90)
}

@Test func probeReportsRotationAndDisplaySize() async throws {
    var spec = TestClipSpec(); spec.width = 320; spec.height = 180; spec.frameCount = 12; spec.rotation = 90
    let url = try await TestClipWriter.write(spec)
    let (_, info) = try await MediaImporter.probe(url)
    let v = try #require(info.video)
    #expect(v.width == 320 && v.height == 180 && v.rotation == 90)
    #expect(v.displayWidth == 180 && v.displayHeight == 320)
    #expect(!info.isStill)
    let dec = try VTVideoDecoder(demuxer: try await AVDemuxer(url: url), media: UUID(), scale: .full)
    #expect(dec.info.rotation == 90)
    let unrotated = try await TestClipWriter.write({ var s = TestClipSpec(); s.frameCount = 6; return s }())
    #expect(try await MediaImporter.probe(unrotated).1.video?.rotation == 0)
}

@Test func thumbnailOfRotatedClipIsUpright() async throws {
    var spec = TestClipSpec(); spec.width = 320; spec.height = 180; spec.frameCount = 12; spec.rotation = 90
    let url = try await TestClipWriter.write(spec)
    let img = try await Thumbnailer().firstFrame(media: UUID(), url: url, height: 0)
    #expect(img.width == 180 && img.height == 320)
}

private func writePNG(width: Int, height: Int, ext: String = "png", type: UTType = .png, orientation: Int? = nil) throws -> URL {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).\(ext)")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [:]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    #expect(CGImageDestinationFinalize(dest))
    return url
}

@Test func stillImageImportsAsImageMedia() async throws {
    let url = try writePNG(width: 64, height: 48)
    let (ref, info) = try await MediaImporter.probe(url)
    #expect(info.isStill && info.audio == nil)
    let v = try #require(info.video)
    #expect(v.width == 64 && v.height == 48 && v.rotation == 0)
    #expect(info.duration == MediaInfo.defaultStillDuration && ref.duration == Time(5, 1))
    #expect(ref.info == info)
}

@Test func jpegImportsAndLoadsBuffer() async throws {
    let url = try writePNG(width: 40, height: 30, ext: "jpg", type: .jpeg)
    let (_, info) = try await MediaImporter.probe(url)
    #expect(info.isStill && info.video?.width == 40)
    let pb = try StillImage.load(url)
    #expect(CVPixelBufferGetWidth(pb) == 40 && CVPixelBufferGetHeight(pb) == 30)
    #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    #expect(p[2] > 200 && p[1] < 60 && p[0] < 60 && p[3] == 255)    // BGRA: red
}

@Test func exifOrientationSwapsStillSize() async throws {
    let url = try writePNG(width: 80, height: 20, ext: "jpg", type: .jpeg, orientation: 6)
    let (_, info) = try await MediaImporter.probe(url)
    #expect(info.video?.width == 20 && info.video?.height == 80)
    let pb = try StillImage.load(url)
    #expect(CVPixelBufferGetWidth(pb) == 20 && CVPixelBufferGetHeight(pb) == 80)
}

@Test func stillThumbnailIsScaled() async throws {
    let url = try writePNG(width: 200, height: 100)
    let img = try await Thumbnailer().thumbnail(media: UUID(), url: url, height: 50)
    #expect(img.height == 50 && img.width == 100)
}

@Test func unreadableStillFailsImport() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).png")
    try Data("not an image".utf8).write(to: url)
    await #expect(throws: (any Error).self) { _ = try await MediaImporter.probe(url) }
}
