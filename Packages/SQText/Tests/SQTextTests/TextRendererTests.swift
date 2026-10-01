import Testing
import CoreGraphics
import CoreVideo
@testable import SQText

struct RasterProbe {
    let w: Int, h: Int, data: [UInt8]
    init(_ img: CGImage) {
        let w = img.width, h = img.height
        self.w = w; self.h = h
        var d = [UInt8](repeating: 0, count: w * h * 4)
        d.withUnsafeMutableBytes { p in
            let c = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.data = d
    }
    /// y = 0 is the top row (CGContext bitmap memory is top row first).
    func px(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        guard x >= 0, y >= 0, x < w, y < h else { return (-1, -1, -1, -1) }   // out of range fails every probe
        let i = (y * w + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
}

@Suite struct TextRendererTests {
    let bigI = TextStyle(fontName: "Helvetica-Bold", size: 200, color: RGBAColor(red: 1, green: 0, blue: 0))

    func raster(_ text: String = "I", _ style: TextStyle, scale: Double = 1) throws -> TextRaster {
        try #require(try TextRenderer.render(text: text, style: style, maxWidth: nil, scale: scale))
    }

    @Test func sizeMatchesInkBoundsTimesScale() throws {
        var st = bigI
        st.stroke = TextStroke(color: .black, width: 6)
        st.shadow = TextShadow(color: .black, offsetX: 4, offsetY: 8, blur: 5)
        for scale in [1.0, 0.5, 2.0] {
            let r = try raster("Hello", st, scale: scale)
            #expect(r.pixelWidth == Int((r.layout.inkBounds.width * scale).rounded(.up)))
            #expect(r.pixelHeight == Int((r.layout.inkBounds.height * scale).rounded(.up)))
            #expect(r.image.width == r.pixelWidth && r.image.height == r.pixelHeight)
            #expect(CVPixelBufferGetWidth(r.linearBuffer) == r.pixelWidth)
            #expect(CVPixelBufferGetHeight(r.linearBuffer) == r.pixelHeight)
            #expect(r.originX == r.layout.inkBounds.x && r.originY == r.layout.inkBounds.y)
        }
    }

    @Test func emptyTextIsNil() throws {
        #expect(try TextRenderer.render(text: "", style: bigI, maxWidth: nil) == nil)
    }

    @Test func fillColorInsideGlyph() throws {
        let r = try raster("I", bigI)
        let l = r.layout.lines[0]
        let p = RasterProbe(r.image)
        let x = Int(l.x + l.width / 2 - r.originX), y = Int(l.y + l.baseline - 70 - r.originY)
        let c = p.px(x, y)
        #expect(c.r == 255 && c.g == 0 && c.b == 0 && c.a == 255)
        #expect(p.px(1, 1).a == 0)
    }

    @Test func backgroundCornerTransparentWithRadius() throws {
        var st = bigI
        st.background = TextBackground(color: RGBAColor(red: 0, green: 0, blue: 1),
                                       padding: BoxPadding(horizontal: 30, vertical: 30), cornerRadius: 30)
        let r = try raster("I", st)
        let p = RasterProbe(r.image)
        let br = try #require(r.layout.backgroundRect)
        let x0 = Int(br.x - r.originX), y0 = Int(br.y - r.originY)
        #expect(p.px(x0 + 1, y0 + 1).a == 0)
        #expect(p.px(x0 + 30, y0 + 1).a > 240)
        let mid = p.px(x0 + 3, y0 + Int(br.height / 2))
        #expect(mid.b == 255 && mid.a == 255)
        st.background = TextBackground(color: RGBAColor(red: 0, green: 0, blue: 1),
                                       padding: BoxPadding(horizontal: 30, vertical: 30))
        let r2 = try raster("I", st)
        let b2 = try #require(r2.layout.backgroundRect)
        #expect(RasterProbe(r2.image).px(Int(b2.x - r2.originX) + 1, Int(b2.y - r2.originY) + 1).a == 255)
    }

    @Test func shadowOffsetDirectionYDown() throws {
        var st = bigI
        st.color = RGBAColor(red: 1, green: 1, blue: 1)
        st.shadow = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0), offsetX: 0, offsetY: 40, blur: 0)
        let r = try raster("I", st)
        let l = r.layout.lines[0]
        let p = RasterProbe(r.image)
        let cx = Int(l.x + l.width / 2 - r.originX)
        let baselineY = Int(l.y + l.baseline - r.originY)
        let below = p.px(cx, baselineY + 20)          // glyph ends at the baseline; only the shadow reaches here
        #expect(below.a > 240 && below.r < 10)
        #expect(p.px(cx, baselineY - Int(200 * 0.72) - 4).a == 0)    // just above the cap height: nothing
        st.shadow = TextShadow(color: RGBAColor(red: 0, green: 0, blue: 0), offsetX: 60, offsetY: 0, blur: 0)
        let r2 = try raster("I", st)
        let l2 = r2.layout.lines[0]
        let p2 = RasterProbe(r2.image)
        let y2 = Int(l2.y + l2.baseline - 70 - r2.originY)
        let right = p2.px(Int(l2.x + l2.width / 2 - r2.originX) + 50, y2)
        #expect(right.a > 240 && right.r < 10)
    }

    @Test func outerStrokeExtendsOutsideButNotInside() throws {
        var st = bigI
        st.stroke = TextStroke(color: RGBAColor(red: 0, green: 1, blue: 0), width: 10)
        let r = try raster("I", st)
        let l = r.layout.lines[0]
        let p = RasterProbe(r.image)
        let cx = Int(l.x + l.width / 2 - r.originX), y = Int(l.y + l.baseline - 70 - r.originY)
        let c = p.px(cx, y)
        #expect(c.r == 255 && c.g == 0)
        var x = cx
        while p.px(x, y).r == 255 && p.px(x, y).g == 0 { x -= 1 }
        let s = p.px(x - 5, y)
        #expect(s.g > 200 && s.r < 40)
    }

    @Test func linearBufferValueForGrey() throws {
        var st = bigI
        st.color = RGBAColor(red: 0.5, green: 0.5, blue: 0.5)
        let r = try raster("I", st)
        let l = r.layout.lines[0]
        let x = Int(l.x + l.width / 2 - r.originX), y = Int(l.y + l.baseline - 70 - r.originY)
        let pb = r.linearBuffer
        #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_64RGBAHalf)
        #expect(CVPixelBufferGetIOSurface(pb) != nil)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pb)).assumingMemoryBound(to: Float16.self)
        let v = [Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]), Float(row[x * 4 + 3])]
        #expect(abs(v[0] - 0.214) < 0.004 && abs(v[1] - 0.214) < 0.004 && abs(v[2] - 0.214) < 0.004)
        #expect(abs(v[3] - 1) < 0.001)
    }
}
