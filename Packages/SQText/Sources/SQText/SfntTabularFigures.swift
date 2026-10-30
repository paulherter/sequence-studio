import Foundation

/// The `tnum` (tabular figures) substitutions of a font's GSUB table: single substitutions (lookup type 1, also behind the
/// extension type 7) of every lookup the `tnum` features name. AppKit's `monospacedDigitSystemFont` turns this feature on, so
/// every digit of the Mac UI has one width; the shared UI does the same for the glyphs it draws.
struct TabularFigures: Sendable {
    /// Original glyph -> tabular glyph.
    let map: [Int: Int]

    init?(_ b: FontBytes, tables: [String: Int], digits: [Int]) {
        guard let gsub = tables["GSUB"], b.u16(gsub) == 1 else { return nil }
        let features = gsub + b.u16(gsub + 6), lookups = gsub + b.u16(gsub + 8)
        var wanted = Set<Int>()
        for i in 0..<b.u16(features) where b.tag(features + 2 + 6 * i) == "tnum" {
            let f = features + b.u16(features + 2 + 6 * i + 4)
            for k in 0..<b.u16(f + 2) { wanted.insert(b.u16(f + 4 + 2 * k)) }
        }
        guard !wanted.isEmpty else { return nil }
        let digitSet = Set(digits)
        var out: [Int: Int] = [:]
        for index in wanted.sorted() where index < b.u16(lookups) {
            let lookup = lookups + b.u16(lookups + 2 + 2 * index)
            var type = b.u16(lookup)
            for s in 0..<b.u16(lookup + 4) {
                var sub = lookup + b.u16(lookup + 6 + 2 * s)
                if type == 7 { // extension: the real lookup type and a 32-bit offset
                    guard b.u16(sub) == 1 else { continue }
                    type = b.u16(sub + 2)
                    sub += b.u32(sub + 4)
                }
                guard type == 1 else { continue }
                let format = b.u16(sub), coverage = sub + b.u16(sub + 2)
                for g in digitSet where out[g] == nil {
                    guard let ci = Self.coverageIndex(b, coverage, glyph: g) else { continue }
                    if format == 1 { out[g] = (g + b.s16(sub + 4)) & 0xFFFF }
                    else if format == 2, ci < b.u16(sub + 4) { out[g] = b.u16(sub + 6 + 2 * ci) }
                }
            }
        }
        guard !out.isEmpty else { return nil }
        map = out
    }

    private static func coverageIndex(_ b: FontBytes, _ o: Int, glyph g: Int) -> Int? {
        let n = b.u16(o + 2)
        if b.u16(o) == 1 {
            for i in 0..<n where b.u16(o + 4 + 2 * i) == g { return i }
            return nil
        }
        for i in 0..<n {
            let r = o + 4 + 6 * i
            if g >= b.u16(r), g <= b.u16(r + 2) { return b.u16(r + 4) + g - b.u16(r) }
        }
        return nil
    }
}
