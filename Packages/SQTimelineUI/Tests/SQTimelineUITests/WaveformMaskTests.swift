#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Testing
@testable import SQTimelineUI
@testable import SQUIKit

/// A BGRA bitmap like the timeline's content cache: opaque background, view space (flipped, points) mapped onto it.
private final class Canvas {
    let cg: CGContext
    let width: Int, height: Int
    init(width: Int, height: Int, scale: CGFloat, background: CGColor = CGColor(srgbRed: 0.2, green: 0.3, blue: 0.5, alpha: 1)) {
        self.width = width; self.height = height
        cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        cg.setFillColor(background)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: scale, y: -scale)
    }
    var pixels: [UInt8] {
        let p = cg.data!.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: p, count: cg.bytesPerRow * height))
    }
}

private func columns(_ n: Int, seed: Int = 3) -> [[WaveformColumn]] {
    [(0..<n).map { i in
        let v = Float((i * 37 + seed) % 101) / 100
        return WaveformColumn(lo: -v * 0.7, hi: v, clipped: false)
    }]
}

private func maxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 }

@MainActor @Suite struct WaveformMaskTests {
    static let color = CGColor(gray: 1, alpha: 0.55)

    /// The mask matches CoreGraphics filling `WaveformPath.path` (its antialiased edges included) at 1x and 2x, both shapes.
    @Test(arguments: [(CGFloat(1), WaveformStyle.Shape.rectified), (2, .rectified), (1, .bipolar), (2, .bipolar)])
    func matchesCoreGraphicsFill(scale: CGFloat, shape: WaveformStyle.Shape) throws {
        var style = WaveformStyle(); style.shape = shape
        let cols = columns(120)
        let rect = CGRect(x: 10, y: 7.3, width: 120, height: 41.6)      // fractional top and bottom
        let ref = Canvas(width: Int(160 * scale), height: Int(60 * scale), scale: scale)
        ref.cg.addPath(WaveformPath.path(columns: cols, rect: rect, style: style))
        ref.cg.setFillColor(Self.color)
        ref.cg.fillPath()

        let out = Canvas(width: Int(160 * scale), height: Int(60 * scale), scale: scale)
        let mask = WaveformMask()
        #expect(mask.begin(band: rect, ctm: out.cg.ctm, color: Self.color))
        mask.add(columns: cols, rect: rect, style: style)
        mask.flush(in: out.cg)
        #expect(mask.directBlends == 1)                                   // blended into the bitmap's bytes
        #expect(maxDiff(ref.pixels, out.pixels) <= 3)
        #expect(ref.pixels != Canvas(width: Int(160 * scale), height: Int(60 * scale), scale: scale).pixels)   // something was drawn
    }

    @Test func respectsClipAndFirstColumn() throws {
        let cols = columns(50)
        let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
        let clip = CGRect(x: 30, y: 5, width: 20, height: 20)
        let ref = Canvas(width: 100, height: 40, scale: 2)
        ref.cg.saveGState()
        ref.cg.clip(to: clip)
        ref.cg.addPath(WaveformPath.path(columns: cols, rect: rect, style: .init(), firstColumn: 25))
        ref.cg.setFillColor(Self.color)
        ref.cg.fillPath()
        ref.cg.restoreGState()

        let out = Canvas(width: 100, height: 40, scale: 2)
        let mask = WaveformMask()
        #expect(mask.begin(band: rect.intersection(clip), ctm: out.cg.ctm, color: Self.color))     // only the dirty part is masked
        mask.add(columns: cols, rect: rect, style: .init(), firstColumn: 25)
        mask.flush(in: out.cg)
        #expect(maxDiff(ref.pixels, out.pixels) <= 3)
    }

    /// The direct bitmap blend writes only inside the context's (rect) clip, at a fractional clip and offset origin too.
    @Test(arguments: [CGFloat(1), 2])
    func directBlendHonoursContextClip(scale: CGFloat) throws {
        let cols = columns(90)
        let rect = CGRect(x: 4.25, y: 2, width: 90, height: 36)
        let clip = CGRect(x: 21, y: 6.5, width: 33.5, height: 20)
        func paint(_ c: Canvas, mask: Bool) -> Int {
            c.cg.saveGState()
            c.cg.clip(to: clip)
            var blends = 0
            if mask {
                let m = WaveformMask()
                #expect(m.begin(band: rect, ctm: c.cg.ctm, color: Self.color))
                var r = rect; r.origin.x = WaveformMask.snappedX(rect.minX, ctm: c.cg.ctm)
                m.add(columns: cols, rect: r, style: .init())
                m.flush(in: c.cg)
                blends = m.directBlends
            } else {
                var r = rect; r.origin.x = WaveformMask.snappedX(rect.minX, ctm: c.cg.ctm)
                c.cg.addPath(WaveformPath.path(columns: cols, rect: r, style: .init()))
                c.cg.setFillColor(Self.color)
                c.cg.fillPath()
            }
            c.cg.restoreGState()
            return blends
        }
        let ref = Canvas(width: Int(100 * scale), height: Int(40 * scale), scale: scale)
        _ = paint(ref, mask: false)
        let out = Canvas(width: Int(100 * scale), height: Int(40 * scale), scale: scale)
        #expect(paint(out, mask: true) == 1)
        // Pixels the clip edge cuts through are antialiased by CoreGraphics and whole in the blend (the content cache only
        // ever clips to whole pixels): compare everything else.
        let a = ref.pixels, b = out.pixels, bpr = ref.cg.bytesPerRow
        let edgeX = [clip.minX, clip.maxX].map { Int(($0 * scale).rounded(.down)) }
        let edgeY = [clip.minY, clip.maxY].map { Int(($0 * scale).rounded(.down)) }
        var worst = 0
        for y in 0..<ref.height where !edgeY.contains(y) {
            for x in 0..<ref.width where !edgeX.contains(x) {
                for k in 0..<4 { worst = max(worst, abs(Int(a[y * bpr + x * 4 + k]) - Int(b[y * bpr + x * 4 + k]))) }
            }
        }
        #expect(worst <= 3)
    }

    /// Columns past the rect's right edge are not drawn (as in `WaveformPath.path`).
    @Test func stopsAtRectEdge() throws {
        let out = Canvas(width: 40, height: 20, scale: 1)
        let before = out.pixels
        let mask = WaveformMask()
        let full = [[WaveformColumn]](repeating: [WaveformColumn](repeating: WaveformColumn(lo: 0, hi: 1, clipped: false), count: 30), count: 1)
        #expect(mask.begin(band: CGRect(x: 0, y: 0, width: 40, height: 20), ctm: out.cg.ctm, color: CGColor(gray: 1, alpha: 1)))
        mask.add(columns: full, rect: CGRect(x: 0, y: 0, width: 10, height: 20), style: .init(), firstColumn: 5)
        mask.flush(in: out.cg)
        let px = out.pixels
        func changed(_ x: Int) -> Bool { px[(10 * 40 + x) * 4] != before[(10 * 40 + x) * 4] }
        #expect(!changed(4) && changed(5) && changed(9) && !changed(10))
    }

    /// A fractional clip origin snaps the columns to whole device pixels: every column stays fully opaque, no seams.
    @Test func fractionalOriginSnapsToPixels() throws {
        let out = Canvas(width: 40, height: 10, scale: 1, background: CGColor(gray: 0, alpha: 1))
        let mask = WaveformMask()
        let full = [[WaveformColumn]](repeating: [WaveformColumn](repeating: WaveformColumn(lo: 0, hi: 1, clipped: false), count: 10), count: 1)
        #expect(mask.begin(band: CGRect(x: 0, y: 0, width: 40, height: 10), ctm: out.cg.ctm, color: CGColor(gray: 1, alpha: 1)))
        mask.add(columns: full, rect: CGRect(x: 5.4, y: 0, width: 10, height: 10), style: .init())
        mask.flush(in: out.cg)
        let px = out.pixels
        let row = (0..<40).map { px[(5 * 40 + $0) * 4] }
        #expect(row[4] == 0 && row[15] == 0)
        #expect((5..<15).allSatisfy { row[$0] == 255 })
    }

    @Test func refusesRotatedOrEmpty() {
        let rotated = Canvas(width: 10, height: 10, scale: 1)
        rotated.cg.rotate(by: 0.3)
        let mask = WaveformMask()
        #expect(!mask.begin(band: CGRect(x: 0, y: 0, width: 10, height: 10), ctm: rotated.cg.ctm, color: Self.color))
        #expect(!mask.begin(band: .zero, ctm: .identity, color: Self.color))
        #expect(mask.begin(band: CGRect(x: 0, y: 0, width: 10, height: 10), ctm: .identity, color: Self.color))
    }

    /// A context that is not an 8-bit premultiplied RGB bitmap (here gray) gets the mask through CoreGraphics.
    @Test func fallbackOutsideRGBBitmaps() throws {
        let cols = columns(60)
        let rect = CGRect(x: 4, y: 3.25, width: 60, height: 30.5)
        func canvas() -> CGContext {
            let cg = CGContext(data: nil, width: 140, height: 80, bitsPerComponent: 8, bytesPerRow: 140, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            cg.setFillColor(CGColor(gray: 0.1, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 140, height: 80))
            cg.translateBy(x: 0, y: 80); cg.scaleBy(x: 2, y: -2)
            return cg
        }
        let ref = canvas(), out = canvas()
        ref.addPath(WaveformPath.path(columns: cols, rect: rect, style: .init())); ref.setFillColor(Self.color); ref.fillPath()
        let mask = WaveformMask()
        #expect(mask.begin(band: rect, ctm: out.ctm, color: Self.color))
        mask.add(columns: cols, rect: rect, style: .init())
        mask.flush(in: out)
        #expect(mask.directBlends == 0)
        func px(_ cg: CGContext) -> [UInt8] { Array(UnsafeBufferPointer(start: cg.data!.assumingMemoryBound(to: UInt8.self), count: 140 * 80)) }
        #expect(maxDiff(px(ref), px(out)) <= 3)
        #expect(px(ref) != px(canvas()))
    }

    /// A y-up user space (unflipped context) draws the same pixels as the path fill too.
    @Test func unflippedContext() throws {
        let cols = columns(60)
        let rect = CGRect(x: 4, y: 3.25, width: 60, height: 30.5)
        func canvas() -> CGContext {
            let cg = CGContext(data: nil, width: 140, height: 80, bitsPerComponent: 8, bytesPerRow: 560, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.setFillColor(CGColor(gray: 0.1, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 140, height: 80))
            cg.scaleBy(x: 2, y: 2)
            return cg
        }
        let ref = canvas(), out = canvas()
        ref.addPath(WaveformPath.path(columns: cols, rect: rect, style: .init())); ref.setFillColor(Self.color); ref.fillPath()
        let mask = WaveformMask()
        #expect(mask.begin(band: rect, ctm: out.ctm, color: Self.color))
        mask.add(columns: cols, rect: rect, style: .init())
        mask.flush(in: out)
        func px(_ cg: CGContext) -> [UInt8] { Array(UnsafeBufferPointer(start: cg.data!.assumingMemoryBound(to: UInt8.self), count: 560 * 80)) }
        #expect(maxDiff(px(ref), px(out)) <= 3)
    }
}
