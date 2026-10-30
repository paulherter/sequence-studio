import Foundation
import Testing
import SQCore
@testable import SQText

@Suite struct TextPresetStillTests {
    static let w = 128, h = 80
    static let gray = TextPresetStill.background(red: 34, green: 34, blue: 34, width: w, height: h)

    /// Bounding box of the pixels that differ from the background.
    func ink(_ px: [UInt8]) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var box: (Int, Int, Int, Int)?
        for y in 0..<Self.h {
            for x in 0..<Self.w where px[(y * Self.w + x) * 4] != 34 {
                box = box.map { (min($0.0, x), max($0.1, x), min($0.2, y), max($0.3, y)) } ?? (x, x, y, y)
            }
        }
        return box.map { (minX: $0.0, maxX: $0.1, minY: $0.2, maxY: $0.3) }
    }

    @Test func aStyleDrawsItsSampleTextCenteredOverTheBackground() throws {
        let style = TextStyle(fontName: "Inter", size: 96, weight: .bold, color: .white)
        let px = TextPresetStill.still(style: style, background: Self.gray, width: Self.w, height: Self.h)
        #expect(px.count == Self.w * Self.h * 4)
        let box = try #require(ink(px))
        #expect(abs((box.minX + box.maxX) / 2 - Self.w / 2) <= 3)
        #expect(abs((box.minY + box.maxY) / 2 - Self.h / 2) <= 4)
        #expect(box.maxX - box.minX < Self.w)
        // White text at full cover reaches near white.
        #expect(stride(from: 0, to: px.count, by: 4).contains { px[$0] > 240 })
        #expect(stride(from: 3, to: px.count, by: 4).allSatisfy { px[$0] == 255 })
    }

    @Test func aLongTextShrinksToTheTileWidth() throws {
        let style = TextStyle(fontName: "Inter", size: 96, weight: .bold, color: .white)
        let px = TextPresetStill.still(style: style, text: "A rather long template title", background: Self.gray,
                                       width: Self.w, height: Self.h)
        let box = try #require(ink(px))
        #expect(box.minX >= 2 && box.maxX <= Self.w - 3)
    }

    @Test func looksAndAnimationsHaveStillsAndAnimationsLoop() throws {
        let look = try #require(TextPresetCatalog.looks.first)
        #expect(TextPresetStill.still(TextPresetCatalog.lookID(look), background: Self.gray, width: Self.w, height: Self.h) != nil)
        let motion = try #require(TextPresetCatalog.motions.first)
        let id = TextPresetCatalog.motionID(motion)
        #expect(TextPresetStill.still(id, background: Self.gray, width: Self.w, height: Self.h).map(ink) != nil)
        let frames = try #require(TextPresetStill.loop(id, fps: 10, background: Self.gray, width: Self.w, height: Self.h))
        #expect(frames.count == max(1, Int((TextPresetStill.loopDuration(motion) * 10).rounded())))
        #expect(TextPresetStill.still("not.a.preset", background: Self.gray, width: Self.w, height: Self.h) == nil)
    }

    @Test func thePoseMovesTurnsAndFadesThePicture() throws {
        // A 10 x 2 white bar.
        let bar = PortableTextRenderer.Picture(width: 10, height: 2, pixels: [Float](repeating: 1, count: 10 * 2 * 4))
        func box(_ pose: AnimationSample) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
            ink(TextPresetStill.compose(bar, pose: pose, over: Self.gray, width: Self.w, height: Self.h))
        }
        let rest = try #require(box(.rest))
        #expect(rest.maxX - rest.minX >= 9 && rest.maxY - rest.minY <= 2)
        var turned = AnimationSample(); turned.rotation = 90
        let t = try #require(box(turned))
        #expect(t.maxY - t.minY >= 9 && t.maxX - t.minX <= 2)
        var moved = AnimationSample(); moved.offset.y = 270          // a quarter of 1080 = 20 of 80 px, down
        let m = try #require(box(moved))
        #expect(m.minY - rest.minY == 20)
        var faded = AnimationSample(); faded.opacity = 0
        #expect(box(faded) == nil)
    }
}
