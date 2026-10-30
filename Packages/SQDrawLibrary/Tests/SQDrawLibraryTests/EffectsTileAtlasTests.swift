import Foundation
import Testing
import SQCore
import SQDrawKit
import SQText
@testable import SQDrawLibrary

/// The Effects grid's stills: the Mac preview store's pictures packed into image slot 5, a few per frame, the icon for
/// audio transitions, and the grid drawing the still instead of the icon once it is made.
@MainActor @Suite struct EffectsTileAtlasTests {
    static let dissolve = "transition." + TransitionKind.crossDissolve.rawValue
    static var audio: String { "transition." + (TransitionKind.allCases.first { $0.trackKind == .audio }?.rawValue ?? "") }

    @Test func stillsArePackedAFewPerFrameAndMatchThePreviewPlan() throws {
        let atlas = EffectsTileAtlas()
        let look = try #require(TextPresetCatalog.looks.first).id
        let ids = [Self.dissolve, ClipEffect.gaussianBlurKind, TextPresetCatalog.lookPrefix + look, Self.audio, "unknown.id"]
        #expect(atlas.prepare(ids, budget: 2))                  // more to make
        #expect(atlas.picture(for: Self.dissolve) != nil && atlas.picture(for: ClipEffect.gaussianBlurKind) != nil)
        #expect(atlas.picture(for: ids[2]) == nil)
        let g = atlas.generation
        #expect(atlas.prepare(ids) == false)
        #expect(atlas.generation == g + 1)
        #expect(atlas.picture(for: Self.audio) == nil && atlas.picture(for: "unknown.id") == nil)
        let text = try #require(atlas.picture(for: ids[2]))
        #expect(text.slot == EffectsTileAtlas.slot && text.slot < DrawList.imageSlots)
        #expect(atlas.prepare(ids) == false && atlas.generation == g + 1)     // nothing new: no re-upload
        // The cross dissolve cell holds the mid mix of the two samples.
        let w = EffectsTileAtlas.cellWidth, h = EffectsTileAtlas.cellHeight
        let s = EffectPreviewPlan.sampleImages(width: w, height: h)
        let want = EffectPreviewPlan.blend(s.a, s.b, kind: .crossDissolve, weight: 0.5)
        let pic = try #require(atlas.picture(for: Self.dissolve))
        let x0 = Int((pic.x0 * Float(atlas.image.width)).rounded()), y0 = Int((pic.y0 * Float(atlas.image.height)).rounded())
        for (x, y) in [(10, 10), (96, 54), (180, 100)] {
            let i = ((y0 + y) * atlas.image.width + x0 + x) * 4, j = (y * w + x) * 4
            #expect(Array(atlas.image.pixels[i..<(i + 4)]) == Array(want[j..<(j + 4)]))
        }
    }

    @Test func hoveringATilePlaysItsLoopInTheLiveCell() async throws {
        let atlas = EffectsTileAtlas()
        atlas.prepare([Self.dissolve])
        atlas.setHover(Self.dissolve, now: 100)
        for _ in 0..<200 where atlas.liveID == nil {            // the loop is made off the main thread
            atlas.advance(now: 100)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(atlas.liveID == Self.dissolve)
        let still = try #require(atlas.picture(for: Self.dissolve))
        #expect(still.y0 == 0 && still.x0 == 0)                // the live cell is cell 0
        let g = atlas.generation
        atlas.advance(now: 100)                                // the same loop frame: no new upload
        #expect(atlas.generation == g)
        atlas.advance(now: 100.5)                              // half a second in: mid mix
        #expect(atlas.generation == g + 1)
        let w = EffectsTileAtlas.cellWidth, h = EffectsTileAtlas.cellHeight
        let s = EffectPreviewPlan.sampleImages(width: w, height: h)
        let want = EffectPreviewPlan.blend(s.a, s.b, kind: .crossDissolve, weight: EffectPreviewPlan.transitionLoop[15])
        let i = (54 * atlas.image.width + 96) * 4, j = (54 * w + 96) * 4
        #expect(Array(atlas.image.pixels[i..<(i + 4)]) == Array(want[j..<(j + 4)]))
        atlas.setHover(nil, now: 101)
        #expect(atlas.liveID == nil)
    }

    @Test func theGridDrawsTheStillOnceItIsMade() {
        let d = UserDefaults(suiteName: "EffectsTileAtlasTests.\(UUID().uuidString)")!
        let panel = EffectsDrawPanel(defaults: d)
        panel.setViewMode(.grid)
        panel.setQuery("dissolve")                          // a search opens the folders with hits
        panel.size = CGSize(width: 260, height: 2000)
        let atlas = EffectsTileAtlas()
        panel.picture = { atlas.picture(for: $0) }
        func imageQuads() -> Int {
            var c = Canvas(width: 260, height: 2000, atlas: nil, scale: 1)
            panel.draw(&c)
            return c.list.quads.filter { $0.kind == DrawQuad.Kind.image.rawValue && $0.pad == Float(EffectsTileAtlas.slot) }.count
        }
        #expect(imageQuads() == 0)
        let visible = panel.visibleTileIDs
        #expect(visible.contains(Self.dissolve))
        atlas.prepare(visible, budget: 1000)
        #expect(imageQuads() == visible.filter { atlas.picture(for: $0) != nil }.count)
        #expect(imageQuads() > 0)
        panel.setViewMode(.list)
        #expect(panel.visibleTileIDs.isEmpty)
    }
}
