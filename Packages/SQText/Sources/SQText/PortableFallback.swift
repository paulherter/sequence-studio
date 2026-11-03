import Foundation

/// Font fallback of the portable text path: a scalar the primary face lacks (glyph 0, the "no glyph" box) is looked up in
/// the system symbol and emoji faces (Windows: Segoe UI Emoji, Segoe UI Symbol), as Core Text falls back on the Mac.
/// Emoji sequences (ZWJ, skin tones, flags, keycaps) are joined by the face's GSUB features and drawn from its COLR layers
/// (`SfntColorGlyphs`); a sequence the face cannot join shows its parts one by one.
enum PortableFallback {
    /// The fallback faces in order (the first that has the scalar wins). Tests may replace them.
    nonisolated(unsafe) static var fonts: [GlyphRasterFont] = systemFonts()

    static func systemFonts() -> [GlyphRasterFont] {
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? ProcessInfo.processInfo.environment["windir"]
        guard let root, !root.isEmpty else { return [] }
        return ["seguiemj.ttf", "seguisym.ttf"].compactMap { name in
            GlyphRasterFont(url: URL(fileURLWithPath: root).appendingPathComponent("Fonts").appendingPathComponent(name))
        }
    }

    /// Scalars that only modify the one before (no glyph, no advance): variation selectors, ZWJ, skin tones, keycap.
    static func isJoiner(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0xFE00...0xFE0F, 0x200D, 0x1F3FB...0x1F3FF, 0x20E3, 0xE0020...0xE007F: return true
        default: return false
        }
    }

    struct Pick {
        let font: GlyphRasterFont?; let glyph: Int
        /// Advance in font units when the plan sets it (a zero-advance person of a ZWJ family); nil = the face's advance.
        var advance: Int? = nil
    }

    /// The advance of a glyph a ZWJ sequence leaves behind: the face's own, or (a zero advance, which the font expects GPOS
    /// to fix) the right edge of its ink, so the people stand side by side instead of on top of each other.
    /// shortcut: no GPOS placement; upgrade when a font needs more than this.
    static func advanceOfSequenceGlyph(_ glyph: Int, in f: GlyphRasterFont) -> Int {
        let adv = f.advance(glyph: glyph)
        if adv > 0 { return adv }
        let layers = f.face.colorGlyphs?.layers(of: glyph)?.map(\.glyph) ?? [glyph]
        var maxX = 0.0
        for l in layers { for c in f.contours(glyph: l, coords: []) { for p in c { maxX = max(maxX, p.x) } } }
        return Int(maxX.rounded())
    }

    private static func isRegionalIndicator(_ s: Unicode.Scalar) -> Bool { (0x1F1E6...0x1F1FF).contains(s.value) }
    private static func isKeycapBase(_ s: Unicode.Scalar) -> Bool { s == "#" || s == "*" || ("0"..."9").contains(s) }

    /// The scalars after `start` that belong to the same emoji sequence: variation selectors, skin tones, keycap, tags, ZWJ
    /// with the emoji it joins, and the second regional indicator of a flag.
    private static func clusterEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var i = start + 1
        if isRegionalIndicator(scalars[start]), i < scalars.count, isRegionalIndicator(scalars[i]) { return i + 1 }
        while i < scalars.count {
            if isJoiner(scalars[i]) { i += 1; if scalars[i - 1].value == 0x200D, i < scalars.count { i += 1 } } else { break }
        }
        return i
    }

    /// The face and glyph for each scalar of `text`; `font == nil` means the primary face (glyph may be 0 = notdef).
    /// An emoji sequence the fallback face turns into one glyph (GSUB: ZWJ family, skin tone, flag, keycap) puts it on the
    /// first scalar and marks the rest `skip` (no glyph, no advance); the glyphs it leaves (a family is several) take the first scalars.
    static func plan(_ scalars: [Unicode.Scalar], primary: GlyphRasterFont, fallbacks: [GlyphRasterFont] = PortableFallback.fonts)
        -> [(pick: Pick, skip: Bool)] {
        var out: [(Pick, Bool)] = []
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            let skipped = (Pick(font: nil, glyph: 0), true)
            if isJoiner(s) { out.append(skipped); i += 1; continue }
            let g = primary.glyph(for: s)
            let keycap = isKeycapBase(s) && i + 1 < scalars.count && (scalars[i + 1].value == 0x20E3 || (scalars[i + 1].value == 0xFE0F && i + 2 < scalars.count && scalars[i + 2].value == 0x20E3))
            let face = fallbacks.first(where: { $0.glyph(for: s) != 0 })
            let emojiForm = keycap || (i + 1 < scalars.count && scalars[i + 1].value == 0xFE0F)   // keycap or VS16: the emoji face wins
            if (g != 0 && (!emojiForm || face == nil)) || s.properties.isWhitespace || s.value < 0x20 { out.append((Pick(font: nil, glyph: g), false)); i += 1; continue }
            guard let f = face else {
                out.append((Pick(font: nil, glyph: 0), false)); i += 1; continue
            }
            let end = clusterEnd(scalars, from: i)
            let parts = Array(scalars[i..<end])
            let glyphs = parts.compactMap { p -> Int? in
                if (0xFE00...0xFE0F).contains(p.value) { return nil }
                let pg = f.glyph(for: p); return pg == 0 ? nil : pg
            }
            let joined = f.face.substitution?.apply(glyphs) ?? glyphs
            if keycap, joined.count != 1 {   // the face has no keycap glyph: the digit in the text face, the rest dropped
                out.append((Pick(font: nil, glyph: g), false))
                out += Array(repeating: skipped, count: parts.count - 1)
            } else {
                // The joined glyphs sit on the first scalars of the sequence (a ZWJ family stays several glyphs, each a
                // joined variant); the rest take no room.
                let several = joined.count > 1 && parts.contains { $0.value == 0x200D }
                for k in parts.indices {
                    out.append(k < joined.count
                        ? (Pick(font: f, glyph: joined[k], advance: several ? advanceOfSequenceGlyph(joined[k], in: f) : nil), false)
                        : skipped)
                }
            }
            i = end
        }
        return out
    }
}
