import Foundation
import Testing
@testable import SQExport

/// Per-frame GIF palettes (`GIFPalette`, the Windows GIF writer): exact for flat frames, close for photos.
@Suite struct GIFPaletteTests {
    static func rgba(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<h { for x in 0..<w { let c = f(x, y); out += [c.0, c.1, c.2, 255] } }
        return out
    }

    @Test func fewColorsStayExact() {
        let px = Self.rgba(4, 2) { x, y in x < 2 ? (255, 0, 0) : y == 0 ? (0, 0, 255) : (12, 200, 99) }
        let f = px.withUnsafeBytes { GIFPalette.quantize($0, width: 4, height: 2, bytesPerRow: 16) }
        #expect(f.colors.count == 3)
        for (i, idx) in f.indices.enumerated() {
            let c = f.colors[Int(idx)]
            #expect([c.0, c.1, c.2] == Array(px[i * 4..<i * 4 + 3]))
        }
    }

    @Test func bgraOffsetsReadTheRightChannels() {
        let px: [UInt8] = [10, 20, 30, 255]   // B G R A
        let f = px.withUnsafeBytes { GIFPalette.quantize($0, width: 1, height: 1, bytesPerRow: 4, rOffset: 2, gOffset: 1, bOffset: 0) }
        #expect(f.colors.count == 1 && f.colors[0] == (30, 20, 10))
    }

    @Test func gradientUsesAtMost256ColorsAndStaysClose() {
        let w = 256, h = 64
        let px = Self.rgba(w, h) { x, y in (UInt8(x), UInt8((y * 4) & 255), UInt8(255 - x)) }
        let f = px.withUnsafeBytes { GIFPalette.quantize($0, width: w, height: h, bytesPerRow: w * 4) }
        #expect(f.colors.count <= 256 && f.colors.count > 200)
        var sum = 0.0, worst = 0
        for i in 0..<(w * h) {
            let c = f.colors[Int(f.indices[i])]
            let d = [abs(Int(c.0) - Int(px[i * 4])), abs(Int(c.1) - Int(px[i * 4 + 1])), abs(Int(c.2) - Int(px[i * 4 + 2]))].max()!
            sum += Double(d); worst = max(worst, d)
        }
        #expect(sum / Double(w * h) < 10)
        #expect(worst < 40)
    }

    @Test func sameFrameSamePalette() {
        let px = Self.rgba(64, 64) { x, y in (UInt8(x * 4), UInt8(y * 4), UInt8((x ^ y) * 4)) }
        let a = px.withUnsafeBytes { GIFPalette.quantize($0, width: 64, height: 64, bytesPerRow: 256) }
        let b = px.withUnsafeBytes { GIFPalette.quantize($0, width: 64, height: 64, bytesPerRow: 256) }
        #expect(a == b)
    }
}
