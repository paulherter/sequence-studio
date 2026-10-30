import Foundation
import Testing
@testable import SQExport

/// The still code values both platforms write (`FrameStillPixels`): BT.709 curve, straight alpha, 16-bit TIFF, EXR halves.
@Suite struct FrameStillPixelsTests {
    /// Float to binary16 bits (test helper; values here are exact in half).
    static func half(_ f: Float) -> UInt16 {
        if f == 0 { return 0 }
        let b = f.bitPattern
        let sign = UInt16((b >> 16) & 0x8000)
        let e = Int((b >> 23) & 0xFF) - 127 + 15
        return sign | UInt16(e) << 10 | UInt16((b >> 13) & 0x3FF)
    }

    static func pixels(_ rgba: [[Float]]) -> [UInt16] { rgba.flatMap { $0.map(half) } }

    @Test func halfBitsDecode() {
        for v: Float in [0, 1, 0.5, 0.25, -2, 1024, 0.000061035156] {
            #expect(FrameStillPixels.float(halfBits: Self.half(v)) == v)
        }
        #expect(FrameStillPixels.float(halfBits: 0x0001) == Float(1) / 16_777_216)   // smallest subnormal 2^-24
        #expect(FrameStillPixels.float(halfBits: 0x7C00) == .infinity)
    }

    @Test func pngIsOpaqueBT709() throws {
        let px = Self.pixels([[1, 0.5, 0, 0.5], [0.018, 0.25, 1, 1]])
        let img = try #require(px.withUnsafeBytes {
            FrameStillPixels.image(halfRGBA: $0, width: 2, height: 1, bytesPerRow: 16, format: .png)
        })
        #expect(img.bitsPerChannel == 8 && !img.hasAlpha && !img.isFloat)
        // Premultiplied values go through the curve as they are (opaque formats keep the composite over black).
        let e = { (x: Float) in UInt8((FrameStillPixels.oetf(x) * 255).rounded()) }
        #expect(img.bytes == [255, e(0.5), 0, 255, e(0.018), e(0.25), 255, 255])
    }

    @Test func alphaFormatsAreStraight() throws {
        let px = Self.pixels([[0.25, 0.125, 0, 0.5], [0, 0, 0, 0]])
        let png = try #require(px.withUnsafeBytes {
            FrameStillPixels.image(halfRGBA: $0, width: 2, height: 1, bytesPerRow: 16, format: .pngAlpha)
        })
        let e = { (x: Float) in UInt8((FrameStillPixels.oetf(x) * 255).rounded()) }
        #expect(png.hasAlpha)
        #expect(png.bytes == [e(0.5), e(0.25), 0, 128, 0, 0, 0, 0])
        let tiff = try #require(px.withUnsafeBytes {
            FrameStillPixels.image(halfRGBA: $0, width: 2, height: 1, bytesPerRow: 16, format: .tiff16Alpha)
        })
        #expect(tiff.bitsPerChannel == 16 && tiff.bytes.count == 16)
        let r = UInt16(tiff.bytes[0]) | UInt16(tiff.bytes[1]) << 8
        #expect(r == UInt16((FrameStillPixels.oetf(0.5) * 65535).rounded()))
        #expect(UInt16(tiff.bytes[6]) | UInt16(tiff.bytes[7]) << 8 == 32768)   // 0.5 * 65535 rounded
    }

    @Test func exrKeepsTheHalvesAndRowsArePacked() throws {
        // Two rows with padding between them: the output is tightly packed.
        var px = Self.pixels([[2, 0.5, 0.25, 1]]) + [0, 0, 0, 0] + Self.pixels([[0, 0, 1, 0.5]]) + [0, 0, 0, 0]
        let img = try #require(px.withUnsafeMutableBytes {
            FrameStillPixels.image(halfRGBA: UnsafeRawBufferPointer($0), width: 1, height: 2, bytesPerRow: 16, format: .exr)
        })
        #expect(img.isFloat && img.hasAlpha && img.bytes.count == 16)
        let first = img.bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        #expect(FrameStillPixels.float(halfBits: first) == 2)   // over-range light stays
        let second = img.bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8 + 4, as: UInt16.self) }
        #expect(FrameStillPixels.float(halfBits: second) == 1)
        px = []
    }

    @Test func tooSmallInputIsRejected() {
        let px = [UInt16](repeating: 0, count: 4)
        #expect(px.withUnsafeBytes { FrameStillPixels.image(halfRGBA: $0, width: 2, height: 1, bytesPerRow: 16, format: .png) } == nil)
    }
}
