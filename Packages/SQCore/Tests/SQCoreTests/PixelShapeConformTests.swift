import Foundation
import Testing
@testable import SQCore

// Change Format on sequences with a Pixel Shape: clips live in display space, so the conform factors use display widths.
struct PixelShapeConformTests {
    private func format(_ w: Int, _ h: Int, _ par: PixelAspect = .square) -> SequenceFormat {
        var f = SequenceFormat(width: w, height: h, frameDuration: Time(1, 30))
        f.pixelAspect = par
        return f
    }

    private func textClip() -> Clip {
        let text = GeneratorRef(kind: GeneratorRef.text, payload: Data("t".utf8))
        var c = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                     start: .zero, generator: text)
        c.animation.position = AnimatedProperty(Vec2(-600, 300))
        return c
    }

    @Test func pureShapeChangeScalesTheDisplayWidthOnly() {
        // Same stored size, 4:3 pixels: the picture goes from 1440 to 1920 wide (display), height stays.
        let from = format(1440, 1080), to = format(1440, 1080, PixelAspect(4, 3)!)
        #expect(SequenceConform.frameFactor(from: from, to: to, mode: .fill) == 1920.0 / 1440)
        #expect(SequenceConform.frameFactor(from: from, to: to, mode: .fit) == 1)
        let c = SequenceConform.conformText(textClip(), from: from, to: to, blockSize: nil)
        #expect(c.animation.position.value == Vec2(-600 * 1920.0 / 1440, 300))
    }

    @Test func sizeAndShapeChangeTogether() {
        let from = format(1920, 1080), to = format(1080, 1080, PixelAspect(2, 1)!)     // displays 2160 x 1080
        #expect(SequenceConform.frameFactor(from: from, to: to, mode: .fill) == 2160.0 / 1920)
        #expect(SequenceConform.frameFactor(from: from, to: to, mode: .fit) == 1)
        let c = SequenceConform.conformText(textClip(), from: from, to: to, blockSize: nil)
        #expect(c.animation.position.value == Vec2(-600 * 2160.0 / 1920, 300))
        // Going back: the display width shrinks, the height stays.
        #expect(SequenceConform.frameFactor(from: to, to: from, mode: .fit) == 1920.0 / 2160)
        #expect(SequenceConform.frameFactor(from: to, to: from, mode: .fill) == 1)
    }

    @Test func titleSafeUsesTheDisplayWidth() {
        let f = format(1440, 1080, PixelAspect(4, 3)!)
        let s = SequenceConform.safeHalfExtent(of: f), q = SequenceConform.safeHalfExtent(of: format(1920, 1080))
        #expect(s.x == q.x && s.y == q.y)
    }

    @Test func squareToSquareIsUnchanged() {
        let from = format(1920, 1080), to = format(1080, 1920)
        #expect(SequenceConform.frameFactor(from: from, to: to, mode: .fit) == min(1080.0 / 1920, 1920.0 / 1080))
        #expect(SequenceConform.frameFactor(from: from, to: to, mode: .fill) == 1920.0 / 1080)
        let c = SequenceConform.conformText(textClip(), from: from, to: to, blockSize: nil)
        #expect(abs(c.animation.position.value.x + 337.5) < 1e-9 && abs(c.animation.position.value.y - 300 * 1920.0 / 1080) < 1e-9)
        #expect(SequenceConform.safeHalfExtent(of: from) == Vec2(1920 * (0.5 - SequenceConform.titleSafeInset), 1080 * (0.5 - SequenceConform.titleSafeInset)))
    }

    @Test func namedPresetMatchTakesTheShapeIntoAccount() {
        let classic = format(1440, 1080)
        #expect(SequenceFormatPresets.preset(matching: classic)?.name.hasPrefix("Classic 4:3") == true)
        #expect(SequenceFormatPresets.preset(matching: format(1440, 1080, PixelAspect(4, 3)!)) == nil)
    }
}
