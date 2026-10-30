import Foundation
import SQDrawKit
import Testing
@testable import SQDrawTimeline

@Suite("ThumbnailAtlas")
struct ThumbnailAtlasTests {
    private func frame(_ w: Int, _ h: Int, _ v: UInt8) -> RGBAImage {
        RGBAImage(width: w, height: h, fill: DrawColor(Float(v) / 255, 0, 0, 1))
    }

    @Test func insertFitsTheCellAndKeepsAspect() {
        var a = ThumbnailAtlas(slot: 0, cellWidth: 16, cellHeight: 9, columns: 2, rows: 2)
        let k = ThumbnailAtlas.Key(media: UUID(), frame: 3)
        #expect(a.picture(for: k) == nil)
        a.insert(k, frame: frame(64, 64, 200))
        let p = a.picture(for: k)!
        #expect(p.slot == 0)
        #expect(p.pixelSize == CGSize(width: 9, height: 9))
        #expect(a.generation == 1)
        // The cell's pixels hold the scaled frame; the rest of the cell stays clear.
        #expect(a.image.pixels[0] == 200 && a.image.pixels[3] == 255)
        #expect(a.image.pixels[(0 * a.image.width + 10) * 4 + 3] == 0)
        // Source rect stays half a texel inside the cell.
        #expect(abs(p.source.u0 - 0.5 / 32) < 1e-6 && abs(p.source.u1 - 8.5 / 32) < 1e-6)
    }

    @Test func fullGridReusesTheLeastRecentlyUsedCell() {
        var a = ThumbnailAtlas(slot: 1, cellWidth: 4, cellHeight: 4, columns: 2, rows: 1)
        let m = UUID()
        let k0 = ThumbnailAtlas.Key(media: m, frame: 0), k1 = ThumbnailAtlas.Key(media: m, frame: 1)
        let k2 = ThumbnailAtlas.Key(media: m, frame: 2)
        a.insert(k0, frame: frame(4, 4, 10))
        a.insert(k1, frame: frame(4, 4, 20))
        _ = a.picture(for: k0)            // k1 is now the oldest
        a.insert(k2, frame: frame(4, 4, 30))
        #expect(a.contains(k0) && a.contains(k2) && !a.contains(k1))
        #expect(a.count == 2)
        // k2 took k1's cell (the second column).
        #expect(a.image.pixels[4 * 4] == 30)
        #expect(a.picture(for: k2)!.source.u0 > 0.5)
    }

    @Test func downscaleAveragesTheBox() {
        let src = RGBAImage(width: 2, height: 1, pixels: [0, 0, 0, 255, 200, 100, 50, 255])
        let out = ThumbnailAtlas.scaled(src, width: 1, height: 1)
        #expect(out.pixels == [100, 50, 25, 255])
    }
}
