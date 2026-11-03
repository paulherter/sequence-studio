import Foundation

/// COLR version 0 color glyphs with their CPAL palette (the emoji layers of Segoe UI Emoji): a base glyph is drawn as a
/// stack of outline glyphs, each in one palette color. COLRv1 paint graphs are not read (the font keeps v0 records for
/// every glyph).
/// shortcut: palette 0 only, no COLRv1 gradients or transforms; upgrade when a font ships v1 only.
struct ColorGlyphs: Sendable {
    struct Layer: Equatable { let glyph: Int; let color: RGBAColor? }   // nil color = the text color (palette index 0xFFFF)

    private let bytes: FontBytes
    private let baseRecords: Int, baseCount: Int, layerRecords: Int, layerCount: Int
    private let colors: [RGBAColor]

    init?(_ b: FontBytes, tables: [String: Int]) {
        guard let colr = tables["COLR"], let cpal = tables["CPAL"] else { return nil }
        bytes = b
        baseCount = b.u16(colr + 2); baseRecords = colr + b.u32(colr + 4)
        layerRecords = colr + b.u32(colr + 8); layerCount = b.u16(colr + 12)
        guard baseCount > 0 else { return nil }
        let entries = b.u16(cpal + 2), palettes = b.u16(cpal + 4), array = cpal + b.u32(cpal + 8)
        guard palettes > 0 else { return nil }
        let first = b.u16(cpal + 12)
        colors = (0..<entries).map { i in
            let o = array + 4 * (first + i)
            return RGBAColor(red: Double(b.u8(o + 2)) / 255, green: Double(b.u8(o + 1)) / 255,
                             blue: Double(b.u8(o)) / 255, alpha: Double(b.u8(o + 3)) / 255)
        }
    }

    /// The layers of `glyph`, bottom first; nil when it is a plain outline glyph.
    func layers(of glyph: Int) -> [Layer]? {
        var lo = 0, hi = baseCount - 1
        while lo <= hi {
            let mid = (lo + hi) / 2, r = baseRecords + mid * 6, id = bytes.u16(r)
            if glyph < id { hi = mid - 1 } else if glyph > id { lo = mid + 1 } else {
                let first = bytes.u16(r + 2), n = bytes.u16(r + 4)
                guard first + n <= layerCount else { return nil }
                return (0..<n).map { i in
                    let l = layerRecords + (first + i) * 4, p = bytes.u16(l + 2)
                    return Layer(glyph: bytes.u16(l), color: p == 0xFFFF ? nil : (p < colors.count ? colors[p] : .black))
                }
            }
        }
        return nil
    }
}

/// The glyph substitutions of the GSUB features an emoji sequence needs (`ccmp`, `liga`, `rlig`, `calt`): single (1),
/// ligature (4), chaining context by coverage (6.3) and extension (7) lookups. This is how Segoe UI Emoji turns a ZWJ
/// family, a skin tone or a pair of regional indicators into one glyph.
/// shortcut: no lookup flags, no script/language selection (every listed feature applies), no contextual formats 1 and 2.
struct GlyphSubstitution: Sendable {
    private let bytes: FontBytes
    private let lookupList: Int
    private let order: [Int]    // lookup indexes of the features, ascending

    init?(_ b: FontBytes, tables: [String: Int]) {
        guard let gsub = tables["GSUB"] else { return nil }
        bytes = b
        let features = gsub + b.u16(gsub + 6)
        lookupList = gsub + b.u16(gsub + 8)
        var set = Set<Int>()
        for i in 0..<b.u16(features) {
            let rec = features + 2 + i * 6
            guard ["ccmp", "liga", "rlig", "calt"].contains(b.tag(rec)) else { continue }
            let f = features + b.u16(rec + 4)
            for k in 0..<b.u16(f + 2) { set.insert(b.u16(f + 4 + 2 * k)) }
        }
        guard !set.isEmpty else { return nil }
        order = set.sorted()
    }

    func apply(_ glyphs: [Int]) -> [Int] {
        var g = glyphs
        for l in order {
            var i = 0
            while i < g.count { i += max(1, step(lookup: l, in: &g, at: i)) }
        }
        return g
    }

    /// Applies one lookup at `pos`; returns how far to move on (0 = nothing matched, stay and move one), and updates `g`.
    private func step(lookup index: Int, in g: inout [Int], at pos: Int) -> Int {
        let l = lookupList + bytes.u16(lookupList + 2 + 2 * index)
        for s in 0..<bytes.u16(l + 4) {
            var sub = l + bytes.u16(l + 6 + 2 * s), type = bytes.u16(l)
            if type == 7 { type = bytes.u16(sub + 2); sub += bytes.u32(sub + 4) }
            switch type {
            case 1: if single(sub, &g, pos) { return 1 }
            case 4: if let n = ligature(sub, &g, pos) { return n }
            case 6: if bytes.u16(sub) == 3, let n = chain(sub, &g, pos) { return n }
            default: break
            }
        }
        return 1
    }

    func coverage(_ o: Int, _ glyph: Int) -> Int? {
        switch bytes.u16(o) {
        case 1:
            var lo = 0, hi = bytes.u16(o + 2) - 1
            while lo <= hi {
                let mid = (lo + hi) / 2, v = bytes.u16(o + 4 + 2 * mid)
                if glyph < v { hi = mid - 1 } else if glyph > v { lo = mid + 1 } else { return mid }
            }
        case 2:
            for r in 0..<bytes.u16(o + 2) {
                let rec = o + 4 + 6 * r, start = bytes.u16(rec)
                if glyph >= start && glyph <= bytes.u16(rec + 2) { return bytes.u16(rec + 4) + glyph - start }
            }
        default: break
        }
        return nil
    }

    private func single(_ sub: Int, _ g: inout [Int], _ pos: Int) -> Bool {
        guard let c = coverage(sub + bytes.u16(sub + 2), g[pos]) else { return false }
        if bytes.u16(sub) == 1 { g[pos] = (g[pos] + bytes.s16(sub + 4)) & 0xFFFF } else {
            guard c < bytes.u16(sub + 4) else { return false }
            g[pos] = bytes.u16(sub + 6 + 2 * c)
        }
        return true
    }

    private func ligature(_ sub: Int, _ g: inout [Int], _ pos: Int) -> Int? {
        guard bytes.u16(sub) == 1, let c = coverage(sub + bytes.u16(sub + 2), g[pos]), c < bytes.u16(sub + 4) else { return nil }
        let set = sub + bytes.u16(sub + 6 + 2 * c)
        for k in 0..<bytes.u16(set) {
            let lig = set + bytes.u16(set + 2 + 2 * k), n = bytes.u16(lig + 2)
            guard n >= 1, pos + n <= g.count else { continue }
            if (1..<n).allSatisfy({ g[pos + $0] == bytes.u16(lig + 4 + 2 * ($0 - 1)) }) {
                g.replaceSubrange(pos..<(pos + n), with: [bytes.u16(lig)])
                return 1
            }
        }
        return nil
    }

    private func chain(_ sub: Int, _ g: inout [Int], _ pos: Int) -> Int? {
        var o = sub + 2
        let back = bytes.u16(o); o += 2
        let backCov = (0..<back).map { sub + bytes.u16(o + 2 * $0) }; o += 2 * back
        let input = bytes.u16(o); o += 2
        let inCov = (0..<input).map { sub + bytes.u16(o + 2 * $0) }; o += 2 * input
        let ahead = bytes.u16(o); o += 2
        let aheadCov = (0..<ahead).map { sub + bytes.u16(o + 2 * $0) }; o += 2 * ahead
        let records = bytes.u16(o); o += 2
        guard input > 0, pos >= back, pos + input + ahead <= g.count else { return nil }
        for (i, c) in backCov.enumerated() where coverage(c, g[pos - 1 - i]) == nil { return nil }
        for (i, c) in inCov.enumerated() where coverage(c, g[pos + i]) == nil { return nil }
        for (i, c) in aheadCov.enumerated() where coverage(c, g[pos + input + i]) == nil { return nil }
        let before = g.count
        for r in 0..<records {
            let seq = bytes.u16(o + 4 * r), lookup = bytes.u16(o + 4 * r + 2)
            let at = pos + seq
            if at < g.count { _ = step(lookup: lookup, in: &g, at: at) }
        }
        return max(1, input + g.count - before)
    }
}
