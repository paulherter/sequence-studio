#if canImport(CoreText)
import CoreText
import CoreVideo
import Foundation
import Testing
import SQCore
@testable import SQText

/// Where the ink sits: the portable raster's glyphs against Core Text's, per line, for the Windows sample title (96 pt
/// bold, stroke, shadow).
@Suite struct PortableTextPlacementTests {
    private func alphas(_ text: String, _ style: TextStyle) throws -> (pc: [Float], mac: [Float], w: Int, h: Int) {
        let mac = try #require(try TextRenderer.render(text: text, style: style, maxWidth: nil))
        let pc = try #require(PortableTextRenderer.render(text: text, style: style, maxWidth: nil))
        let w = pc.picture.width, h = pc.picture.height
        #expect(w == mac.pixelWidth && h == mac.pixelHeight)
        let pb = mac.linearBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!, rowBytes = CVPixelBufferGetBytesPerRow(pb)
        var m = [Float](repeating: 0, count: w * h)
        for y in 0..<min(h, mac.pixelHeight) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<min(w, mac.pixelWidth) { m[y * w + x] = Float(row[x * 4 + 3]) }
        }
        return ((0..<(w * h)).map { pc.picture.pixels[$0 * 4 + 3] }, m, w, h)
    }

    /// Every glyph where the pen puts it: Core Graphics used to round each glyph origin down to a whole pixel, so the
    /// fourth H of "HHHH" sat 0.8 px left of the portable one.
    @Test func glyphOriginsAreNotQuantized() throws {
        let (pc, mac, w, h) = try alphas("HHHH", TextStyle(size: 96, weight: .bold))
        let advance = 68.93                                   // Inter Bold H at 96 pt
        for i in 0..<4 {
            let cols = Int(Double(i) * advance)..<min(w, Int(Double(i + 1) * advance))
            func centroid(_ a: [Float]) -> Double {
                var sum = 0.0, mass = 0.0
                for y in 0..<h { for x in cols { let v = Double(a[y * w + x]); sum += v * Double(x); mass += v } }
                return sum / max(mass, 1e-9)
            }
            #expect(abs(centroid(pc) - centroid(mac)) < 0.05, "H \(i): \(centroid(pc)) vs \(centroid(mac))")
        }
    }

    /// The Windows sample title (stroke, shadow): same size, nearly the same coverage. The rest of the gap is glyph shape,
    /// not placement: the portable lowercase ("Toyota") covers about 0.5 % more under a stroke.
    @Test func sampleTitleCoverageMatchesCoreText() throws {
        let style = TextStyle(size: 96, weight: .bold, stroke: TextStroke(color: RGBAColor(red: 0.1, green: 0.1, blue: 0.4), width: 3),
                              shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.7), offsetX: 4, offsetY: 4, blur: 8))
        let (pc, mac, _, _) = try alphas("AVATAR Toyota\nWave", style)
        let inkP = pc.reduce(0, +), inkM = mac.reduce(0, +)
        #expect(abs(inkP - inkM) < inkM * 0.012, "coverage \(inkP) vs \(inkM)")
    }
}
#endif
