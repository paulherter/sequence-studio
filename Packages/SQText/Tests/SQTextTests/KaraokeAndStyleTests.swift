import Testing
import CoreGraphics
import CoreVideo
import ImageIO
import Foundation
import SQCore
@testable import SQText

private func bytes(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let n = CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
    return Array(UnsafeBufferPointer(start: CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), count: n))
}

private let red = RGBAColor(red: 1, green: 0, blue: 0)

@Suite struct KaraokeAndStyleTests {
    func base(_ w: FontWeight = .black) -> TextStyle {
        TextStyle(fontName: "Helvetica-Bold", size: 100, weight: w, color: .white, alignment: .center)
    }

    // MARK: All caps

    @Test func allCapsChangesTheGlyphsNotTheText() throws {
        var s = base(); s.allCaps = true
        let lower = TextLayout.layout(text: "abc", style: s, maxWidth: nil)
        let upper = TextLayout.layout(text: "ABC", style: base(), maxWidth: nil)
        #expect(lower.lines[0].text == "ABC")
        #expect(abs(lower.lines[0].width - upper.lines[0].width) < 0.001)
        let template = TextTemplate(name: "t", text: "abc", style: s)
        #expect(template.text == "abc")                       // what is stored is what was typed
        let plain = TextLayout.layout(text: "abc", style: base(), maxWidth: nil)
        #expect(abs(lower.lines[0].width - plain.lines[0].width) > 1)
    }

    @Test func allCapsDecodesAsOffFromOldFiles() throws {
        let json = #"{"fontName":"Helvetica","size":48,"weight":400,"color":{"red":1,"green":1,"blue":1,"alpha":1},"alignment":"center","lineSpacing":0}"#
        let s = try JSONDecoder().decode(TextStyle.self, from: Data(json.utf8))
        #expect(!s.allCaps)
        var on = s; on.allCaps = true
        #expect(try JSONDecoder().decode(TextStyle.self, from: JSONEncoder().encode(on)).allCaps)
    }

    // MARK: Tracking

    @Test func widthGrowsLinearlyWithTracking() {
        func width(_ t: Double) -> Double {
            var s = base(); s.tracking = t
            return TextLayout.layout(text: "Hello", style: s, maxWidth: nil).lines[0].width
        }
        let w0 = width(0), w5 = width(5), w10 = width(10), w20 = width(20)
        #expect(abs((w10 - w0) - 2 * (w5 - w0)) < 0.01)
        #expect(abs((w20 - w0) - 4 * (w5 - w0)) < 0.01)
        #expect(w5 - w0 >= 20)                                // five characters, 5 px each
    }

    // MARK: Stroke position

    @Test func strokeBoundsGrowByTheStrokeWidthOutsideAndHalfOfItCentred() {
        func ink(_ p: StrokePosition?) -> TextLayoutResult {
            var s = base()
            if let p { s.stroke = TextStroke(color: .black, width: 10, position: p) }
            return TextLayout.layout(text: "I", style: s, maxWidth: nil)
        }
        let none = ink(nil), outside = ink(.outside), centre = ink(.centre)
        #expect(abs(outside.inkBounds.width - none.inkBounds.width - 20) < 0.001)   // w on each side
        #expect(abs(centre.inkBounds.width - none.inkBounds.width - 10) < 0.001)    // w / 2 on each side
    }

    @Test func oldStrokesAreOutside() throws {
        let json = #"{"color":{"red":0,"green":0,"blue":0,"alpha":1},"width":6}"#
        #expect(try JSONDecoder().decode(TextStroke.self, from: Data(json.utf8)).position == .outside)
    }

    @Test func centredStrokeDrawsOverTheFill() throws {
        // A wide centred stroke covers the inside of a thin stem, an outside one does not.
        func stemCentre(_ p: StrokePosition) throws -> (r: Int, g: Int, b: Int, a: Int) {
            var s = base(); s.stroke = TextStroke(color: .black, width: 30, position: p)
            let r = try #require(try TextRenderer.render(text: "I", style: s, maxWidth: nil))
            let pr = RasterProbe(r.image)
            return pr.px(pr.w / 2, pr.h / 2)
        }
        let outside = try stemCentre(.outside), centre = try stemCentre(.centre)
        #expect(outside.r > 200)       // white fill intact
        #expect(centre.r < 60)         // black stroke on top of the narrow stem
    }

    // MARK: Karaoke highlight

    @Test func highlightColoursOnlyTheLitWord() throws {
        let h = TextHighlight(words: 1..<2, color: red)
        let r = try #require(try TextRenderer.render(text: "I I I", style: base(), maxWidth: nil, highlight: h))
        let p = RasterProbe(r.image)
        let y = p.h / 2
        let cols = (0..<p.w).filter { p.px($0, y).a > 200 }
        // Three stems: split the columns into groups.
        var groups: [[Int]] = []
        for c in cols { if let l = groups.last?.last, c == l + 1 { groups[groups.count - 1].append(c) } else { groups.append([c]) } }
        #expect(groups.count == 3, "\(groups.map { ($0.first!, $0.last!) })")
        func mid(_ g: [Int]) -> (r: Int, g: Int, b: Int, a: Int) { p.px(g[g.count / 2], y) }
        #expect(mid(groups[0]).g > 200 && mid(groups[0]).r > 200)                 // white
        #expect(mid(groups[1]).r > 200 && mid(groups[1]).g < 60 && mid(groups[1]).b < 60)   // red
        #expect(mid(groups[2]).g > 200 && mid(groups[2]).r > 200, "\(mid(groups[0])) \(mid(groups[1])) \(mid(groups[2]))")
    }

    @Test func highlightKeepsTheLayoutAndTheStroke() throws {
        var s = base(); s.stroke = TextStroke(color: .black, width: 6)
        let plain = try #require(try TextRenderer.render(text: "I I I", style: s, maxWidth: nil))
        let lit = try #require(try TextRenderer.render(text: "I I I", style: s, maxWidth: nil,
                                                       highlight: TextHighlight(words: 0..<3, color: red)))
        #expect(plain.pixelWidth == lit.pixelWidth && plain.pixelHeight == lit.pixelHeight && plain.originX == lit.originX)
        // The stroke is not recoloured: a pixel just outside the first stem is black in both.
        let a = RasterProbe(plain.image), b = RasterProbe(lit.image)
        let y = a.h / 2
        let firstStem = (0..<a.w).first { a.px($0, y).a > 200 && a.px($0, y).r > 200 }!
        #expect(a.px(firstStem - 3, y).r < 60 && b.px(firstStem - 3, y).r < 60)
    }

    @Test func renderIsDeterministic() throws {
        let h = TextHighlight(words: 1..<2, color: red)
        let a = try #require(try TextRenderer.render(text: "one two three", style: base(), maxWidth: 600, highlight: h))
        let b = try #require(try TextRenderer.render(text: "one two three", style: base(), maxWidth: 600, highlight: h))
        #expect(RasterProbe(a.image).data == RasterProbe(b.image).data)
        #expect(bytes(a.linearBuffer) == bytes(b.linearBuffer))
        let off = try #require(try TextRenderer.render(text: "one two three", style: base(), maxWidth: 600))
        #expect(RasterProbe(off.image).data != RasterProbe(a.image).data)   // the highlight is visible
    }

    @Test func monitorAndExportDrawTheSameRaster() throws {
        // The monitor goes through TextGenerator (a text layer), the export through TextRenderer: same template, same pixels.
        let style = CaptionPresetLibrary.builtIn.style(for: "tiktok")
        let h = TextHighlight(words: 1..<2, color: RGBAColor(red: 1, green: 0.86, blue: 0.1))
        let t = CaptionLayout.template(text: "so this is how", style: style, canvasWidth: 1080, canvasHeight: 1920, highlight: h)
        let ref = try TextGenerator.makeRef(template: t, animations: nil)
        let canvas = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        TextGenerator.clearCache()
        let frame = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(1, 1), canvas: canvas, scale: 1))
        let direct = try #require(try TextRenderer.render(text: t.text, style: t.style, maxWidth: t.box?.width,
                                                          boxHeight: t.box?.height, highlight: t.highlight))
        #expect(bytes(frame.buffer) == bytes(direct.linearBuffer))
        // And the lit and unlit rasters differ, so the test would notice a dropped highlight.
        var unlit = t; unlit.highlight = nil
        let plain = try #require(try TextRenderer.render(text: unlit.text, style: unlit.style, maxWidth: unlit.box?.width,
                                                         boxHeight: unlit.box?.height))
        #expect(bytes(plain.linearBuffer) != bytes(direct.linearBuffer))
    }

    /// Writes the karaoke look (three moments of one caption) to $SQ_RENDER_DIR for a look by eye; a no-op otherwise.
    @Test func writesTheKaraokeLookWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["SQ_RENDER_DIR"] else { return }
        var style = CaptionPresetLibrary.builtIn.style(for: "tiktok")
        style.allCaps = true
        let color = CaptionKaraoke.color(KaraokeStyle())
        let w = 1080, rowH = 330
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: rowH * 3, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.25, green: 0.3, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: rowH * 3))
        for (i, lit) in [0, 2, 4].enumerated() {
            let t = CaptionLayout.template(text: "so this is how it works", style: style, canvasWidth: 1080, canvasHeight: 1920,
                                           highlight: TextHighlight(words: lit..<(lit + 1), color: color))
            let r = try #require(try TextRenderer.render(text: t.text, style: t.style, maxWidth: t.box?.width,
                                                         boxHeight: t.box?.height, highlight: t.highlight))
            let y = CGFloat(rowH * (2 - i)) + CGFloat(rowH - r.pixelHeight) / 2
            ctx.draw(r.image, in: CGRect(x: (CGFloat(w) - CGFloat(r.pixelWidth)) / 2, y: y,
                                         width: CGFloat(r.pixelWidth), height: CGFloat(r.pixelHeight)))
        }
        let img = ctx.makeImage()!
        let url = URL(fileURLWithPath: dir).appendingPathComponent("karaoke.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func highlightTemplateRoundTrips() throws {
        var t = TextTemplate(name: "c", text: "a b", style: base())
        t.highlight = TextHighlight(words: 0..<1, color: red)
        let back = try TextTemplate.decode(from: t.encoded())
        #expect(back.highlight == t.highlight)
        var old = t; old.highlight = nil
        #expect(try TextTemplate.decode(from: old.encoded()).highlight == nil)
    }

    // MARK: Karaoke state of a caption

    func item(_ words: [(String, Int64, Int64)]) -> CaptionItem {
        CaptionItem(lines: [words.map(\.0).joined(separator: " ")],
                    range: TimeRange(start: .zero, end: Time(words.last!.2 + 5, 10)),
                    words: words.map { CaptionWord(text: $0.0, range: TimeRange(start: Time($0.1, 10), end: Time($0.2, 10))) })
    }

    @Test func theLitWordFollowsTheSpeech() {
        let it = item([("so", 0, 3), ("this", 4, 8), ("works", 9, 14)])
        let k = KaraokeStyle(red: 1, green: 0, blue: 0)
        func lit(_ tenths: Int64) -> Range<Int>? { CaptionKaraoke.highlight(for: it, style: k, at: Time(tenths, 10))?.words }
        #expect(lit(0) == 0..<1)
        #expect(lit(3) == 0..<1)         // the pause keeps the spoken word lit
        #expect(lit(4) == 1..<2)
        #expect(lit(10) == 2..<3)
        #expect(lit(15) == nil)          // after the last word
        #expect(CaptionKaraoke.highlight(for: it, style: nil, at: .zero) == nil)
    }

    @Test func spokenWordsStayLitWhenAsked() {
        let it = item([("so", 0, 3), ("this", 4, 8), ("works", 9, 14)])
        let k = KaraokeStyle(red: 1, green: 0, blue: 0, keepSpoken: true)
        #expect(CaptionKaraoke.highlight(for: it, style: k, at: Time(5, 10))?.words == 0..<2)
        #expect(CaptionKaraoke.highlight(for: it, style: k, at: Time(15, 10))?.words == 0..<3)   // all spoken
    }

    // MARK: Align to frame

    func layout(_ s: TextStyle = TextStyle(fontName: "Helvetica", size: 80)) -> TextLayoutResult {
        TextLayout.layout(text: "Hello", style: s, maxWidth: nil)
    }

    @Test func sixButtonsPlaceTheTextBlockAtTheFrameEdges() {
        let l = layout()
        let bw = l.bounds.width, bh = l.bounds.height
        let cur = Vec2(40, -70)
        func go(_ a: FrameAlignment, scale: Vec2 = Vec2(1, 1)) -> Vec2 {
            TextAlignToFrame.position(a, layout: l, position: cur, scale: scale, rotation: 0, canvasWidth: 1920, canvasHeight: 1080)
        }
        #expect(abs(go(.left).x - (bw / 2 - 960)) < 1e-6 && go(.left).y == cur.y)
        #expect(abs(go(.right).x - (960 - bw / 2)) < 1e-6 && go(.right).y == cur.y)
        #expect(go(.centerHorizontally).x == 0 && go(.centerHorizontally).y == cur.y)
        #expect(abs(go(.top).y - (bh / 2 - 540)) < 1e-6 && go(.top).x == cur.x)
        #expect(abs(go(.bottom).y - (540 - bh / 2)) < 1e-6 && go(.bottom).x == cur.x)
        #expect(go(.centerVertically).y == 0 && go(.centerVertically).x == cur.x)
        #expect(abs(go(.left, scale: Vec2(2, 2)).x - (bw - 960)) < 1e-6)      // the scaled block is twice as wide
    }

    @Test func alignmentUsesTheTextNotItsShadow() {
        var s = TextStyle(fontName: "Helvetica", size: 80)
        s.shadow = TextShadow(color: .black, offsetX: 30, offsetY: 0, blur: 0)
        let l = layout(s)
        // The raster is wider than the text on the shadow side; the text's own left edge still lands on the frame edge.
        let p = TextAlignToFrame.position(.left, layout: l, position: Vec2(0, 0), scale: Vec2(1, 1), rotation: 0,
                                          canvasWidth: 1920, canvasHeight: 1080)
        #expect(abs(p.x - (l.bounds.width / 2 - 960)) < 1e-6)
        // Scaled up, the raster grows about its own centre, so the position has to make up for the shadow side.
        let q = TextAlignToFrame.position(.left, layout: l, position: Vec2(0, 0), scale: Vec2(2, 2), rotation: 0,
                                          canvasWidth: 1920, canvasHeight: 1080)
        let d = (l.inkBounds.x + l.inkBounds.width / 2) - (l.bounds.x + l.bounds.width / 2)
        #expect(abs(q.x - (l.bounds.width - 960 - d * (1 - 2))) < 1e-6)
    }

    // MARK: Word spans, All Caps with length-changing capitals, the lit-only layer

    @Test func wordSpansAreFoundOnTheOriginalTextEvenWhenCapitalsChangeTheLength() {
        var s = base(); s.allCaps = true
        let l = TextLayout.layout(text: "Stra\u{DF}e is  here", style: s, maxWidth: nil)
        #expect(l.displayText == "STRASSE IS  HERE")          // the sharp s became SS
        #expect(l.wordSpans == [NSRange(location: 0, length: 7), NSRange(location: 8, length: 2), NSRange(location: 12, length: 4)])
        #expect(l.lines[0].text == "STRASSE IS  HERE")
        // The stored text is untouched and has the same three words.
        #expect(CaptionItem(lines: ["Stra\u{DF}e is  here"], range: TimeRange(start: .zero, end: Time(1, 1))).tokens.count == 3)
    }

    @Test func aHighlightedWordStaysOneWordWhenTheWrapBreaksIt() throws {
        // A word wider than the box is broken across lines; both pieces belong to word 1 and both are lit.
        let l = TextLayout.layout(text: "a Supercalifragilistic b", style: base(), maxWidth: 220)
        #expect(l.wordSpans.count == 3)
        let pieces = l.lines.filter { NSIntersectionRange($0.location == 0 ? NSRange(location: 0, length: 0) : NSRange(location: $0.location, length: $0.text.utf16.count), l.wordSpans[1]).length > 0 }
        #expect(pieces.count >= 2)
        let h = TextHighlight(words: 1..<2, color: red, onlyLit: true)
        let r = try #require(try TextRenderer.render(text: "a Supercalifragilistic b", style: base(), maxWidth: 220, highlight: h))
        let p = RasterProbe(r.image)
        // Red ink appears on at least two separate text rows (one per line the word occupies).
        let rows = (0..<p.h).filter { y in (0..<p.w).contains { let c = p.px($0, y); return c.a > 200 && c.r > 200 && c.g < 60 } }
        var bands = 0, prev = -2
        for y in rows { if y != prev + 1 { bands += 1 }; prev = y }
        #expect(bands >= 2)
    }

    @Test func theLitLayerHoldsOnlyTheLitWordsAtTheSameSizeAsThePlainRaster() throws {
        var s = base(); s.stroke = TextStroke(color: .black, width: 6)
        let plain = try #require(try TextRenderer.render(text: "I I I", style: s, maxWidth: nil))
        let layer = try #require(try TextRenderer.render(text: "I I I", style: s, maxWidth: nil,
                                                         highlight: TextHighlight(words: 1..<2, color: red, onlyLit: true)))
        #expect(plain.pixelWidth == layer.pixelWidth && plain.pixelHeight == layer.pixelHeight)
        #expect(plain.originX == layer.originX && plain.originY == layer.originY)
        let p = RasterProbe(layer.image)
        let y = p.h / 2
        let opaque = (0..<p.w).filter { p.px($0, y).a > 200 }
        #expect(!opaque.isEmpty && opaque.allSatisfy { p.px($0, y).r > 200 && p.px($0, y).g < 60 })   // red only: no white, no stroke
        #expect(opaque.first! > p.w / 3 && opaque.last! < 2 * p.w / 3)                                 // the middle word only
    }

    @Test func plainPlusLitLayerMatchTheMonitorAndExportPaths() throws {
        let style = CaptionPresetLibrary.builtIn.style(for: "tiktok")
        let h = TextHighlight(words: 1..<2, color: RGBAColor(red: 1, green: 0.86, blue: 0.1), onlyLit: true)
        let canvas = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30))
        for hl in [nil, h] as [TextHighlight?] {
            let t = CaptionLayout.template(text: "so this is how", style: style, canvasWidth: 1080, canvasHeight: 1920, highlight: hl)
            let ref = try TextGenerator.makeRef(template: t, animations: nil)
            TextGenerator.clearCache()
            let frame = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(1, 1), canvas: canvas, scale: 1))
            let direct = try #require(try TextRenderer.render(text: t.text, style: t.style, maxWidth: t.box?.width,
                                                              boxHeight: t.box?.height, highlight: t.highlight))
            #expect(bytes(frame.buffer) == bytes(direct.linearBuffer))
            #expect(frame.x == frame.x && frame.width == Double(direct.pixelWidth))
        }
    }
}
