#if canImport(CoreText)
import Foundation
import CoreVideo
import Testing
import SQCore
@testable import SQText

@Suite struct DateStampTextTests {
    private func spec(_ corner: DateStamp.Corner) -> DateStampSpec {
        DateStampSpec(text: "JUL 14 1998  10:32 PM", corner: corner, fontSize: 48, red: 1, green: 0.55, blue: 0.1,
                      canvasWidth: 1920, canvasHeight: 1080)
    }

    @Test func becomesAnAreaTextGeneratorInsideTheMargin() throws {
        let ref = try #require(DateStampText.textRef(for: .dateStamp(spec(.bottomRight))))
        #expect(ref.kind == GeneratorRef.text)
        let (t, _) = try TextGenerator.decode(ref)
        #expect(t.text == "JUL 14 1998  10:32 PM")
        #expect(t.style.alignment == .right && t.style.verticalAlignment == .bottom)
        #expect(t.box == TextBox(width: 1920 - 130, height: 1080 - 130))
        let tl = try TextGenerator.decode(try #require(DateStampText.textRef(for: .dateStamp(spec(.topLeft))))).0
        #expect(tl.style.alignment == .left && tl.style.verticalAlignment == .top)
    }

    /// Bounding box of the non-transparent pixels of a linear half-float premultiplied RGBA buffer.
    private func inkBox(_ f: TextFrame) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, w: Int, h: Int)? {
        let pb = f.buffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        var box = (minX: Int.max, minY: Int.max, maxX: -1, maxY: -1, w: w, h: h)
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float16.self)
            for x in 0..<w where row[x * 4 + 3] > 0.5 {
                box.minX = min(box.minX, x); box.maxX = max(box.maxX, x); box.minY = min(box.minY, y); box.maxY = max(box.maxY, y)
            }
        }
        return box.maxX >= 0 ? box : nil
    }

    @Test func rendersAtTheChosenCornerInsideTheMargin() throws {
        let canvas = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25))
        for (corner, right, bottom) in [(DateStamp.Corner.bottomRight, true, true), (.bottomLeft, false, true),
                                        (.topRight, true, false), (.topLeft, false, false)] {
            let ref = try #require(DateStampText.textRef(for: .dateStamp(spec(corner))))
            let f = try #require(try TextGenerator.frame(ref: ref, localTime: .zero, clipDuration: Time(5, 1), canvas: canvas, scale: 1))
            let tr = f.layerTransform(base: .identity, canvas: canvas)
            let ink = try #require(inkBox(f))
            // Ink position on the canvas = raster top-left (center + position - size / 2) + ink offset.
            let left = 960 + tr.position.x - f.width / 2, top = 540 + tr.position.y - f.height / 2
            let sx = Double(ink.w) / f.width
            let x0 = left + Double(ink.minX) / sx, x1 = left + Double(ink.maxX + 1) / sx
            let y0 = top + Double(ink.minY) / sx, y1 = top + Double(ink.maxY + 1) / sx
            #expect(x0 >= 0 && x1 <= 1920 && y0 >= 0 && y1 <= 1080, "\(corner) inside canvas")
            #expect((right ? x1 > 1920.0 / 2 : x1 < 1920.0 / 2), "\(corner) horizontal side")
            #expect((bottom ? y0 > 1080.0 / 2 : y1 < 1080.0 / 2), "\(corner) vertical side")
            #expect(abs((right ? 1920 - x1 : x0) - 65) < 12, "\(corner) margin x")
        }
    }

    @Test func otherKindsAreNotAStamp() {
        #expect(DateStampText.textRef(for: .solid(rgb: [0, 0, 0])) == nil)
    }
}
#endif
