import Foundation
import Testing
import SQText
@testable import SQDrawKit

/// The UI atlas carries Inter SemiBold next to the regular face (titles of panels, cards and empty states).
@MainActor @Suite struct GlyphAtlasWeightTests {
    @Test func semiboldIsItsOwnHeavierWiderFace() throws {
        let atlas = try #require(GlyphAtlas())
        let bold = atlas.semiboldFace
        #expect(bold > 0)
        #expect(atlas.semiboldFace == bold)       // one face, added once
        let regularW = atlas.width(of: "Media offline", pixelSize: 24)
        let boldW = atlas.width(of: "Media offline", pixelSize: 24, face: bold)
        #expect(boldW > regularW)
        // More ink per glyph: the stems are thicker.
        func ink(_ face: Int) -> Int {
            let g = atlas.metric(for: "H", face: face).glyph
            return atlas.font(face: face).rasterize(glyph: g, pixelsPerEm: 48).coverage.reduce(0) { $0 + Int($1) }
        }
        #expect(ink(bold) > ink(0) * 11 / 10)
    }

    /// Medium (tab titles, clip names, buttons) is its own face between regular and SemiBold.
    @Test func mediumSitsBetweenRegularAndSemibold() throws {
        let atlas = try #require(GlyphAtlas())
        let medium = atlas.mediumFace
        #expect(medium > 0 && medium != atlas.semiboldFace)
        #expect(atlas.mediumFace == medium)
        let s = "Media offline Sequence 01"
        let r = atlas.width(of: s, pixelSize: 24), m = atlas.width(of: s, pixelSize: 24, face: medium)
        let b = atlas.width(of: s, pixelSize: 24, face: atlas.semiboldFace)
        #expect(r < m && m < b)
        #expect(Canvas(width: 10, height: 10, atlas: nil, scale: 1).medium == 0)
    }

    @Test func theRegularFaceKeepsTheDefaultInstanceAndNoAtlasMeansFaceZero() throws {
        let inter = try #require(GlyphRasterFont.inter)
        #expect(inter.coords.isEmpty)
        #expect(GlyphRasterFont.interSemibold?.coords.isEmpty == false)
        let canvas = Canvas(width: 10, height: 10, atlas: nil, scale: 1)
        #expect(canvas.semibold == 0)
    }

    /// Text centers on the UI face's own cap height: Inter's 0.727 em; the Mac system font's weights come from its wght axis.
    @Test func capHeightAndWeightsFollowTheUIFace() throws {
        let inter = try #require(GlyphAtlas())
        #expect(abs(inter.capHeightRatio - 0.727) < 0.015)
        #if os(macOS)
        let sf = try #require(GlyphAtlas(font: GlyphRasterFont.macSystemUI))
        #expect((0.66...0.74).contains(sf.capHeightRatio))
        #expect(sf.semiboldFace > 0 && sf.mediumFace > 0 && sf.mediumFace != sf.semiboldFace)
        #expect(sf.width(of: "Media offline", pixelSize: 24, face: sf.semiboldFace) > sf.width(of: "Media offline", pixelSize: 24))
        #endif
    }
}

/// Characters the UI face lacks (the Mac system font has no ⇥ or ↩; Montserrat no arrows at all) draw from Inter.
@MainActor @Suite struct GlyphAtlasFallbackTests {
    @Test func aMissingSymbolDrawsFromInterAtTheAskedFacesScale() throws {
        let montserrat = try #require(GlyphRasterFont.bundled(name: "Montserrat"))
        #expect(montserrat.glyph(for: "⇥") == 0 && montserrat.unitsPerEm == 1000)
        let atlas = try #require(GlyphAtlas(font: montserrat))
        let m = atlas.metric(for: "⇥")
        #expect(m.face > 0 && m.glyph != 0)
        #expect(atlas.font(face: m.face) === GlyphRasterFont.inter)
        // Advance in the asked face's units: Inter's 2048-unit advance scaled to Montserrat's 1000.
        let inter = try #require(GlyphRasterFont.inter)
        let interAdv = inter.advance(glyph: inter.glyph(for: "⇥"))
        #expect(abs(m.advance - interAdv * 1000 / 2048) <= 1)
        #expect(atlas.width(of: "⇥", pixelSize: 20) > 5)
        // A character the face has keeps the face.
        #expect(atlas.metric(for: "A").face == 0)
        // The drawn text emits a glyph quad with ink for each symbol.
        var list = DrawList(width: 100, height: 50)
        list.text("⇥↩", x: 10, baseline: 30, pixelSize: 20, color: .white, atlas: atlas)
        #expect(list.quads.count == 2)
    }

    @Test func interKeepsItsOwnGlyphsAndWeightsFallBackAtTheirWeight() throws {
        let atlas = try #require(GlyphAtlas())
        #expect(atlas.fallbackFace(of: 0) == nil)
        #expect(atlas.metric(for: "⇥").face == 0)
        #if os(macOS)
        let sf = try #require(GlyphAtlas(font: GlyphRasterFont.macSystemUI))
        for s in ["⇥", "↩", "↵", "␣"] as [Unicode.Scalar] {
            #expect(sf.font.glyph(for: s) == 0)
            let m = sf.metric(for: s)
            #expect(m.glyph != 0 && sf.font(face: m.face) === GlyphRasterFont.inter, "\(s)")
            #expect(sf.entry(glyph: m.glyph, pixelSize: 24, face: m.face).w > 0)
        }
        #expect(sf.metric(for: "⌘").face == 0)   // SF has the command sign
        let semibold = sf.semiboldFace
        #expect(sf.font(face: sf.metric(for: "⇥", face: semibold).face) === GlyphRasterFont.interSemibold)
        #endif
    }
}
