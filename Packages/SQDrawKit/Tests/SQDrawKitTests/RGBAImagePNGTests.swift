import Foundation
import Testing
@testable import SQDrawKit
#if canImport(ImageIO)
import ImageIO
#endif

@Suite struct RGBAImagePNGTests {
    @Test func checksumsMatchTheReferenceValues() {
        #expect(RGBAImage.crc32(Array("IEND".utf8)) == 0xAE42_6082)
        #expect(RGBAImage.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
    }

    @Test func videoLevelGrayAndPrimariesConvert() {
        // 2x2: luma 126 (mid gray at video levels), neutral chroma.
        let gray = RGBAImage(nv12: [126, 126, 126, 126, 128, 128], width: 2, height: 2, fullRange: false)
        #expect(Array(gray.pixels[0..<4]) == [128, 128, 128, 255])
        // Rec.709 red at video levels: Y 63, Cb 102, Cr 240.
        let red = RGBAImage(nv12: [63, 63, 63, 63, 102, 240], width: 2, height: 2, fullRange: false)
        #expect(red.pixels[0] >= 253 && red.pixels[1] <= 2 && red.pixels[2] <= 2)
    }

    @Test func scaledAveragesBoxesAndKeepsAspect() {
        var img = RGBAImage(width: 4, height: 2, fill: DrawColor(0, 0, 0, 1))
        for x in 0..<2 { for y in 0..<2 { img.pixels[(y * 4 + x) * 4] = 200 } }   // left half red 200
        let small = img.scaled(maxWidth: 2)
        #expect(small.width == 2 && small.height == 1)
        #expect(Array(small.pixels[0..<4]) == [200, 0, 0, 255] && Array(small.pixels[4..<8]) == [0, 0, 0, 255])
        #expect(img.scaled(maxWidth: 8) == img)
    }

    @Test func pngHasHeaderAndSizeAndDecodes() {
        var img = RGBAImage(width: 300, height: 260, fill: DrawColor(1, 0, 0, 1))   // > 65535 bytes: several stored blocks
        img.pixels[4 * 301 + 1] = 200
        let d = img.pngData()
        #expect(Array(d.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(Array(d[16..<24]) == [0, 0, 1, 44, 0, 0, 1, 4])
        #if canImport(ImageIO)
        let src = CGImageSourceCreateWithData(d as CFData, nil)
        let cg = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        #expect(cg?.width == 300 && cg?.height == 260)
        #endif
    }
}
