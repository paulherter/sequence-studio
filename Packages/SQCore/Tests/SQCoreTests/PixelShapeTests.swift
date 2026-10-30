import Foundation
import Testing
@testable import SQCore

// Sequence pixel shape: display size and fit in display space; square stays as it was.
struct PixelShapeTests {
    private func format(_ w: Int, _ h: Int, _ par: PixelAspect = .square) -> SequenceFormat {
        var f = SequenceFormat(width: w, height: h, frameDuration: Time(1, 30))
        f.pixelAspect = par
        return f
    }

    @Test func displaySizeFollowsTheShape() {
        #expect(format(1920, 1080).displayWidth == 1920)
        #expect(format(1080, 1080, PixelAspect(2, 1)!).displayWidth == 2160)
        #expect(format(1440, 1080, PixelAspect(4, 3)!).displayWidth == 1920)
        #expect(format(1920, 1080).layoutFormat == format(1920, 1080))
        let l = format(1080, 1080, PixelAspect(2, 1)!).layoutFormat
        #expect(l.width == 2160 && l.height == 1080 && l.pixelAspect == .square)
        #expect(format(1080, 1080, PixelAspect(2, 1)!).storedPixels.width == 1080)
    }

    @Test func squareFitIsUnchanged() {
        let f = format(1920, 1080)
        #expect(f.fitScale(width: 3840, height: 2160) == 0.5)
        #expect(f.fillScale(width: 1080, height: 1920) == 1920.0 / 1080)
    }

    @Test func aSquareClipFitsTheDisplayFrame() {
        // 1080 x 1080 stored at 2:1 shows 2160 x 1080: a 1920 x 1080 clip fits at 1 (height-limited), and shown in display
        // space it is 1920 wide inside 2160, undistorted.
        let f = format(1080, 1080, PixelAspect(2, 1)!)
        #expect(f.fitScale(width: 1920, height: 1080) == 1)
        #expect(f.fillScale(width: 1920, height: 1080) == 2160.0 / 1920)
        // The square-pixel frame of the same stored size would have fitted it at 1080/1920.
        #expect(f.storedPixels.fitScale(width: 1920, height: 1080) == 1080.0 / 1920)
    }

    @Test func variantsInheritTheShape() {
        let base = format(1080, 1080, PixelAspect(2, 1)!)
        let v = FormatVariant(name: "Tall", width: 1080, height: 1920)
        #expect(v.format(base: base).pixelAspect == PixelAspect(2, 1)!)
    }

    @Test func settingsCarryTheShape() throws {
        var t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())
        var p = Project(name: "P", timelines: [t])
        var s = t.settings
        s.format.pixelAspect = PixelAspect(4, 3)!
        try p.setSettings(s, of: t.id)
        t = p.timelines[0]
        #expect(t.format.pixelAspect == PixelAspect(4, 3)!)
        #expect(t.settings == s)
    }
}
