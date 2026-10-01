import Testing
import Foundation
import SQCore
@testable import SQText

/// The monitor (text generator path) and the export burn-in (raw raster) must put a caption at the same pixels.
@Suite struct CaptionLayoutTests {
    func parity(text: String, style: TextStyle, w: Int, h: Int) throws {
        let t = CaptionLayout.template(text: text, style: style, canvasWidth: Double(w), canvasHeight: Double(h))
        let canvas = SequenceFormat(width: w, height: h, frameDuration: Time(1, 30))
        // Monitor.
        let ref = try TextGenerator.makeRef(template: t, animations: nil)
        let f = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(2, 1), canvas: canvas, scale: 1))
        let c = CaptionLayout.boxCentre(canvasWidth: Double(w), canvasHeight: Double(h))
        let tr = f.layerTransform(base: ClipTransform(position: Vec2(c.x, c.y)), canvas: canvas)
        let monitor = (x: Double(w) / 2 + tr.position.x, y: Double(h) / 2 + tr.position.y)
        // Burn-in.
        let r = try #require(try TextRenderer.render(text: t.text, style: t.style, maxWidth: t.box?.width, boxHeight: t.box?.height))
        let burn = CaptionLayout.rasterCentre(canvasWidth: Double(w), canvasHeight: Double(h), originX: r.originX, originY: r.originY,
                                              width: Double(r.pixelWidth), height: Double(r.pixelHeight))
        #expect(abs(monitor.x - burn.x) < 0.01 && abs(monitor.y - burn.y) < 0.01, "monitor \(monitor) burn \(burn)")
        #expect(abs(f.width - Double(r.pixelWidth)) < 0.01 && abs(f.height - Double(r.pixelHeight)) < 0.01)
    }

    @Test func plainOneLine() throws {
        try parity(text: "Hello", style: TextStyle(fontName: "Helvetica", size: 56), w: 1920, h: 1080)
    }

    @Test func shadowStrokeAndThreeLines() throws {
        var s = TextStyle(fontName: "Helvetica-Bold", size: 60, weight: .bold)
        s.stroke = TextStroke(color: .black, width: 8)
        s.shadow = TextShadow(color: .black, angle: 135, distance: 14, blur: 10)
        s.background = TextBackground(color: .black, padding: BoxPadding(horizontal: 20, vertical: 10), cornerRadius: 8)
        try parity(text: "one line\ntwo lines here\nand a third line", style: s, w: 1080, h: 1920)
    }

    @Test func textSitsAboveTheBottomMargin() throws {
        let t = CaptionLayout.template(text: "Hi", style: TextStyle(fontName: "Helvetica", size: 50), canvasWidth: 1920, canvasHeight: 1080)
        let r = try #require(try TextRenderer.render(text: "Hi", style: t.style, maxWidth: t.box?.width, boxHeight: t.box?.height))
        let c = CaptionLayout.rasterCentre(canvasWidth: 1920, canvasHeight: 1080, originX: r.originX, originY: r.originY,
                                           width: Double(r.pixelWidth), height: Double(r.pixelHeight))
        let bottom = c.y + Double(r.pixelHeight) / 2
        #expect(bottom <= 1080 * (1 - CaptionLayout.bottomMargin) + 0.5)
    }
}
