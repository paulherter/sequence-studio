import Foundation
import Testing
import SQCore
import SQDrawKit
import SQLibrary
import SQText
@testable import SQInspectorUI

@MainActor
@Suite struct TextTemplateTileAtlasTests {
    func styled(_ name: String, color: RGBAColor = .white) -> TextTemplateTile {
        TextTemplateTile(source: .builtIn(name), name: name, style: TextStyle(fontName: "Inter", size: 96, weight: .bold, color: color),
                         sampleText: "Text")
    }

    @Test func picturesAreMadeAFewPerCallAndPackedIntoSlotFour() throws {
        let atlas = TextTemplateTileAtlas()
        let tiles = (0..<6).map { styled("t\($0)") }
        #expect(atlas.prepare(tiles))                         // 4 made, 2 left
        #expect(atlas.picture(for: tiles[3]) != nil && atlas.picture(for: tiles[4]) == nil)
        #expect(!atlas.prepare(tiles))
        let g = atlas.generation
        #expect(!atlas.prepare(tiles) && atlas.generation == g)        // nothing new: no upload
        #expect(atlas.image.width == 256 * 8 && atlas.image.height == 160)
        let p = try #require(atlas.picture(for: tiles[5]))
        #expect(p.slot == 4 && DrawList.imageSlots > 4)
        #expect(p.source == (5.0 / 8, 0, 6.0 / 8, 1))
        // The cell holds the rendered look: white ink over the tile background.
        let px = atlas.image.pixels, x0 = 5 * 256
        let cell = (0..<160).flatMap { y in (0..<256).map { x in px[(y * atlas.image.width + x0 + x) * 4] } }
        #expect(cell.contains { $0 > 200 } && cell.contains(34))
    }

    @Test func aSavedPictureWinsAndAChangedTileIsRedrawn() throws {
        let atlas = TextTemplateTileAtlas()
        atlas.decodePicture = { _ in RGBAImage(width: 2, height: 2, fill: DrawColor(1, 0, 0)) }
        var saved = TextTemplateTile(source: .user(UUID(), .titleTemplate), name: "Lower third", style: nil, sampleText: "Lower third",
                                     thumbnail: Data([1, 2, 3]))
        let plain = TextTemplateTile(source: .builtIn("plain"), name: "Plain", style: nil, sampleText: "Text")
        atlas.prepare([saved, plain])
        #expect(atlas.picture(for: plain) == nil)                       // no picture: the tab draws the sample text
        #expect(atlas.picture(for: saved) != nil)
        #expect(Array(atlas.image.pixels[0..<4]) == [255, 0, 0, 255])
        saved.name = "Renamed"
        #expect(atlas.picture(for: saved) == nil)                       // stale until made again
        atlas.prepare([saved])
        #expect(atlas.picture(for: saved) != nil)
    }

    @Test func theTabDrawsTheAtlasPictureInTheWell() {
        let tab = TextTemplatesTabDraw()
        let atlas = TextTemplateTileAtlas()
        tab.allTiles = [styled("one")]
        atlas.prepare(tab.shownTiles)
        tab.picture = { atlas.picture(for: $0) }
        var c = Canvas(width: 320, height: 400, atlas: nil, scale: 1)
        tab.draw(&c)
        #expect(c.list.quads.contains { $0.kind == DrawQuad.Kind.image.rawValue && $0.pad == 4 })
    }
}
