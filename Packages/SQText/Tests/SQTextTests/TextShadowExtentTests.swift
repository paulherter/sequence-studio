#if canImport(CoreText)
import Testing
import CoreGraphics
import Foundation
@testable import SQText

/// The text raster must hold the whole shadow: a blurred shadow cut by the raster edge shows as a faint hard-edged box
/// around the text (darker in parts over a light picture).
@Suite struct TextShadowExtentTests {
    /// Imported caption look (Premiere opacity 91 %, distance 20.5, Size 19.3, Blur 17.8 -> spread 5.8, blur 46).
    func caption(blur: Double, spread: Double, scale: Double, animated: Bool = false) throws -> (RasterProbe, Int, Int) {
        var st = TextStyle(fontName: "Helvetica-Bold", size: 83, color: RGBAColor(red: 1, green: 1, blue: 1))
        var sh = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.91), angle: 178.6, distance: 20.5, blur: blur)
        sh.spread = spread
        st.shadow = sh
        let r = try #require(animated
            ? try TextRenderer.render(text: "Aa smart", style: st, maxWidth: nil, scale: scale, characterStates: [])
            : try TextRenderer.render(text: "Aa smart", style: st, maxWidth: nil, scale: scale))
        return (RasterProbe(r.image), r.pixelWidth, r.pixelHeight)
    }

    func maxBorderAlpha(_ p: RasterProbe, _ w: Int, _ h: Int) -> Int {
        var m = 0
        for x in 0..<w { m = max(m, p.px(x, 0).a, p.px(x, h - 1).a) }
        for y in 0..<h { m = max(m, p.px(0, y).a, p.px(w - 1, y).a) }
        return m
    }

    @Test(arguments: [(46.0, 5.8, 1.0), (46.0, 5.8, 0.5), (139.0, 13.4, 1.0), (20.0, 0.0, 1.0)])
    func shadowFadesOutInsideTheRaster(blur: Double, spread: Double, scale: Double) throws {
        let (p, w, h) = try caption(blur: blur, spread: spread, scale: scale)
        #expect(maxBorderAlpha(p, w, h) <= 1, "blur \(blur) spread \(spread) scale \(scale)")
    }

    @Test func animatedRendererKeepsTheWholeShadowToo() throws {
        let (p, w, h) = try caption(blur: 46, spread: 5.8, scale: 1, animated: true)
        #expect(maxBorderAlpha(p, w, h) <= 1)
    }
}
#endif
