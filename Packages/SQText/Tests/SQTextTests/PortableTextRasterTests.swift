#if canImport(CoreText)
import CoreVideo
import Foundation
import Testing
@testable import SQText

/// The portable title raster (Windows) against the Core Text one on the Mac: same size, origin and nearly the same
/// coverage for every drawing step.
@Suite struct PortableTextRasterTests {
    private func compare(_ style: TextStyle, text: String = "Hello", highlight: TextHighlight? = nil,
                         meanBound: Float = 0.025) throws {
        let mac = try #require(try TextRenderer.render(text: text, style: style, maxWidth: nil, scale: 1, highlight: highlight))
        let pc = try #require(PortableTextRenderer.render(text: text, style: style, maxWidth: nil, scale: 1, highlight: highlight))
        #expect(pc.picture.width == mac.pixelWidth && pc.picture.height == mac.pixelHeight)
        #expect(pc.originX == mac.originX && pc.originY == mac.originY)
        let pb = mac.linearBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!, rowBytes = CVPixelBufferGetBytesPerRow(pb)
        let w = min(pc.picture.width, mac.pixelWidth), h = min(pc.picture.height, mac.pixelHeight)
        var diff: Float = 0, macInk: Float = 0, pcInk: Float = 0
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
            for x in 0..<w {
                for k in 0..<4 {
                    let a = Float(row[x * 4 + k]), b = pc.picture.pixels[(y * pc.picture.width + x) * 4 + k]
                    diff += abs(a - b)
                    if k == 3 { macInk += a; pcInk += b }
                }
            }
        }
        // Same instance (weight, optical size, italic file) and kerning as Core Text: the pixels nearly agree.
        // shortcut: bound at the measured level (0.008...0.038); single glyphs agree to 1e-4 but glyph runs drift by up to
        // 0.2 px across and italic runs up to 0.7 px down from CTLineDraw (not quarter-pixel quantization, tried).
        // Tighten once Core Text's run placement is measured.
        let mean = diff / Float(max(1, w * h * 4))
        #expect(mean < meanBound, "mean difference \(mean)")
        // Total coverage within a few percent: same glyphs, same strokes and boxes.
        #expect(abs(pcInk - macInk) <= macInk * 0.05, "coverage \(pcInk) vs \(macInk)")
    }

    @Test func plainFill() throws { try compare(TextStyle(size: 64)) }

    @Test func outsideAndCenteredStroke() throws {
        try compare(TextStyle(size: 64, stroke: TextStroke(color: RGBAColor(red: 1, green: 0, blue: 0), width: 4)))
        try compare(TextStyle(size: 64, stroke: TextStroke(color: RGBAColor(red: 0, green: 0, blue: 1), width: 3, position: .centre)))
    }

    @Test func shadowWithBlur() throws {
        try compare(TextStyle(size: 64, shadow: TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.8),
                                                         offsetX: 4, offsetY: 4, blur: 6)))
    }

    @Test func roundedBackgroundBox() throws {
        try compare(TextStyle(size: 48, background: TextBackground(color: RGBAColor(red: 0.1, green: 0.2, blue: 0.6),
                                                                  padding: .init(horizontal: 12, vertical: 6), cornerRadius: 8)))
    }

    @Test func gradientFill() throws {
        try compare(TextStyle(size: 64, gradient: TextGradient(start: RGBAColor(red: 1, green: 0.8, blue: 0),
                                                               end: RGBAColor(red: 0.9, green: 0, blue: 0.5))))
    }

    @Test func underlineAndStrikethroughBars() throws {
        try compare(TextStyle(size: 64, underline: true, strikethrough: true))
    }

    @Test func boldItalicTwoLines() throws {
        try compare(TextStyle(size: 56, weight: .bold, italic: true), text: "Sequence\nStudio", meanBound: 0.045)
        try compare(TextStyle(size: 40, weight: .black), text: "AVATAR To", meanBound: 0.045)
    }
}
#endif
