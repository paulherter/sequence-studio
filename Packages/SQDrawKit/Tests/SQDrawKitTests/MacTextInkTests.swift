#if canImport(AppKit)
import AppKit
import Foundation
import Testing
import SQText
@testable import SQDrawKit

@MainActor @Suite struct MacTextInkTests {
    @Test func inkIsCloseToCoreText() throws {
        let atlas = try #require(GlyphAtlas(font: GlyphRasterFont.macSystemUI ?? .inter))
        atlas.pointScale = 2
        let s = "Replace Transcript Settings"
        /// The shared UI text carries about the ink Core Text draws (font smoothing thickens stems; plain outline coverage is
        /// about 25 % lighter), so the Mac shared UI does not look thinner than the AppKit app.
        for (nsw, face, _) in [(NSFont.Weight.regular, 0, "reg"), (.semibold, atlas.semiboldFace, "semi")] {
            for sc in [2.0] {
                let size = 13.0
                let w = 400, h = 60
                let cs = CGColorSpaceCreateDeviceRGB()
                let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: sc, y: sc)
                let g = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.current = g
                (s as NSString).draw(at: NSPoint(x: 4, y: 10), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: nsw), .foregroundColor: NSColor.white])
                NSGraphicsContext.current = nil
                let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
                var ink = 0
                for i in 0..<(w * h) { ink += Int(px[i * 4]) }
                var mine = 0
                atlas.pointScale = Float(sc)
                var run = GlyphAtlas.TextRun(atlas: atlas, pixelSize: Float(size * sc), face: face)
                for u in s.unicodeScalars {
                    let st = run.step(u)
                    let e = atlas.entry(glyph: st.metric.glyph, pixelSize: Float(size * sc), face: st.metric.face)
                    for y in 0..<e.h { for x in 0..<e.w { mine += Int(atlas.pixels[(e.y + y) * atlas.size + e.x + x]) } }
                }
                let ratio = Double(ink) / Double(mine)
                #expect(ratio > 0.88 && ratio < 1.15, "Core Text ink \(ink), shared \(mine)")
            }
        }
    }
}
#endif
