import Foundation

extension GlyphRasterFont {
    /// The bundled file a family name resolves to (`PortableFontMatch`: the face nearest `weight`, the italic file for
    /// italic): the face drawn-list previews (look and template tiles) bake into the glyph atlas. nil for Inter and for
    /// a name that is not bundled (the preview keeps the UI face). Same on the Mac and Windows, so both preview identical glyphs.
    /// shortcut: the file's default instance (no variation coordinates, no shear): previews of a variable font's other
    /// weights draw at its default weight; pass coords to the atlas when previews need them.
    public static func bundled(name: String, weight: FontWeight = .regular, italic: Bool = false) -> GlyphRasterFont? {
        guard name.lowercased() != InterFont.familyName.lowercased(), !PortableFontMatch.candidates(for: name).isEmpty else { return nil }
        return PortableFontMatch.choose(name: name, weight: weight, italic: italic, size: 24)?.font
    }
}
