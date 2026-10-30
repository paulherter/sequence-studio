import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SQExport

@Suite struct FrameStillWriterTests {
    /// 2x1: an opaque mid-gray pixel and a half-transparent red one (premultiplied linear).
    private let pixels: [Float16] = [0.2, 0.2, 0.2, 1,   0.25, 0, 0, 0.5]

    private func write(_ f: FrameStillFormat) throws -> (CGImage, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).\(f.fileExtension)")
        try pixels.withUnsafeBufferPointer { try FrameStillWriter.write(pixels: $0, width: 2, height: 1, format: f, to: url) }
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return (try #require(CGImageSourceCreateImageAtIndex(src, 0, nil)), url)
    }

    @Test func opaquePngDropsAlpha() throws {
        let (img, url) = try write(.png); defer { try? FileManager.default.removeItem(at: url) }
        #expect(img.width == 2 && img.height == 1)
        #expect([.none, .noneSkipLast, .noneSkipFirst].contains(img.alphaInfo))
    }

    @Test func alphaPngKeepsHalfTransparency() throws {
        let (img, url) = try write(.pngAlpha); defer { try? FileManager.default.removeItem(at: url) }
        #expect(img.alphaInfo != .none && img.alphaInfo != .noneSkipLast)
        // Read back as straight RGBA8.
        var px = [UInt8](repeating: 0, count: 8)
        let ctx = CGContext(data: &px, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(px[3] == 255)
        #expect(abs(Int(px[7]) - 128) <= 2)
    }

    @Test func oetfEndpoints() {
        #expect(FrameStillWriter.oetf(0) == 0)
        #expect(abs(FrameStillWriter.oetf(1) - 1) < 1e-5)
        #expect(FrameStillWriter.oetf(2) == FrameStillWriter.oetf(1))
    }

    @Test func tiffAndExrWriteWhenSupported() throws {
        for f in [FrameStillFormat.tiff16, .tiff16Alpha, .exr] where f.isSupported {
            let (img, url) = try write(f); defer { try? FileManager.default.removeItem(at: url) }
            #expect(img.width == 2)
            if f == .exr { #expect(img.bitsPerComponent == 16 || img.bitsPerComponent == 32) }
        }
        #expect(FrameStillFormat.available.contains(.png))
    }

    @Test func shortBufferIsRejected() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("short-\(UUID().uuidString).png")
        let few: [Float16] = [0, 0, 0, 1]
        #expect(throws: (any Error).self) {
            try few.withUnsafeBufferPointer { try FrameStillWriter.write(pixels: $0, width: 2, height: 2, format: .png, to: url) }
        }
    }
}
