import Foundation

// Minimal TrueType/OpenType reader for the portable text backend (TextBackend+Portable.swift); compiled everywhere so the
// Mac tests can compare it with Core Text.

/// The tables of a font file the portable backend reads.
final class SfntFace: @unchecked Sendable {
    let unitsPerEm: Int
    let ascender: Int, descender: Int, lineGap: Int
    let weightClass: Int
    /// `post` underline position (negative below the baseline) and thickness; OS/2 x and cap height (0 before OS/2 v2).
    let underlinePosition: Int, underlineThickness: Int, xHeight: Int, capHeight: Int
    let bytes: FontBytes
    /// Variation axes, named instances and deltas (nil for a static font).
    let variations: FontVariations?
    /// GPOS pair kerning (nil without a `kern` feature).
    let kerning: PairKerning?
    /// Apple `trak` tracking (horizontal, normal track; nil without one): the size-dependent letter spacing Core Text adds to
    /// every glyph of the system font.
    let tracking: SizeTracking?
    private let tableOffsets: [String: Int]
    /// Tabular-figure glyphs of the digits (`tnum`; nil without them), read on first use.
    private(set) lazy var tabularDigits: TabularFigures? = TabularFigures(
        bytes, tables: tableOffsets, digits: (0x30...0x39).map { glyph(for: Unicode.Scalar($0)!) })
    private let data: Data
    private let numberOfHMetrics: Int
    private let hmtx: Int
    private let cmapSubtable: Int?
    private let cmapFormat: Int

    init?(data: Data) {
        self.data = data
        func u16(_ o: Int) -> Int { o + 2 <= data.count ? Int(data[data.startIndex + o]) << 8 | Int(data[data.startIndex + o + 1]) : 0 }
        func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }
        guard data.count > 12 else { return nil }
        var tables: [String: Int] = [:]
        // A collection (ttc) starts with 'ttcf': use its first font.
        var base = 0
        if String(decoding: data.prefix(4), as: UTF8.self) == "ttcf" { base = u32(12) }
        let count = u16(base + 4)
        for i in 0..<count {
            let rec = base + 12 + i * 16
            guard rec + 16 <= data.count else { return nil }
            tables[String(decoding: data[(data.startIndex + rec)..<(data.startIndex + rec + 4)], as: UTF8.self)] = u32(rec + 8)
        }
        guard let head = tables["head"], let hhea = tables["hhea"], let hm = tables["hmtx"] else { return nil }
        unitsPerEm = max(16, u16(head + 18))
        func s16(_ o: Int) -> Int { let v = u16(o); return v >= 0x8000 ? v - 0x10000 : v }
        ascender = s16(hhea + 4); descender = s16(hhea + 6); lineGap = s16(hhea + 8)
        numberOfHMetrics = max(1, u16(hhea + 34))
        hmtx = hm
        weightClass = tables["OS/2"].map { u16($0 + 4) } ?? 400
        underlinePosition = tables["post"].map { s16($0 + 8) } ?? 0
        underlineThickness = tables["post"].map { s16($0 + 10) } ?? 0
        let os2v2 = tables["OS/2"].flatMap { u16($0) >= 2 ? $0 : nil }
        xHeight = os2v2.map { s16($0 + 86) } ?? 0
        capHeight = os2v2.map { s16($0 + 88) } ?? 0
        var best: (Int, Int)?   // (subtable offset, format); prefer full Unicode (format 12), then BMP (format 4)
        if let cmap = tables["cmap"] {
            for i in 0..<u16(cmap + 2) {
                let rec = cmap + 4 + i * 8
                let platform = u16(rec), encoding = u16(rec + 2), off = cmap + u32(rec + 4)
                let fmt = u16(off)
                let unicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10))
                guard unicode, fmt == 4 || fmt == 12 else { continue }
                if best == nil || fmt == 12 { best = (off, fmt) }
            }
        }
        cmapSubtable = best?.0; cmapFormat = best?.1 ?? 0
        let fb = FontBytes(b: [UInt8](data))
        bytes = fb
        let all = fb.tables()
        variations = FontVariations(fb, tables: all)
        kerning = PairKerning(fb, tables: all)
        tracking = all["trak"].flatMap { SizeTracking(fb, at: $0) }
        tableOffsets = all
    }

    convenience init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: d)
    }

    private func u16(_ o: Int) -> Int { o >= 0 && o + 2 <= data.count ? Int(data[data.startIndex + o]) << 8 | Int(data[data.startIndex + o + 1]) : 0 }
    private func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }

    func glyph(for scalar: Unicode.Scalar) -> Int {
        guard let sub = cmapSubtable else { return 0 }
        let c = Int(scalar.value)
        if cmapFormat == 12 {
            let groups = u32(sub + 12)
            var lo = 0, hi = groups - 1
            while lo <= hi {
                let mid = (lo + hi) / 2, g = sub + 16 + mid * 12
                let start = u32(g), end = u32(g + 4)
                if c < start { hi = mid - 1 } else if c > end { lo = mid + 1 } else { return u32(g + 8) + (c - start) }
            }
            return 0
        }
        guard c <= 0xFFFF else { return 0 }
        let segX2 = u16(sub + 6), ends = sub + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2
        for i in 0..<(segX2 / 2) where c <= u16(ends + i * 2) {
            let start = u16(starts + i * 2)
            guard c >= start else { return 0 }
            let ro = u16(ranges + i * 2), delta = u16(deltas + i * 2)
            if ro == 0 { return (c + delta) & 0xFFFF }
            let g = u16(ranges + i * 2 + ro + (c - start) * 2)
            return g == 0 ? 0 : (g + delta) & 0xFFFF
        }
        return 0
    }

    /// Advance width in font units.
    func advance(glyph: Int) -> Int {
        let i = min(glyph, numberOfHMetrics - 1)
        return u16(hmtx + i * 4)
    }

    /// Advance width in font units at normalized variation `coords` (empty = default instance).
    func advance(glyph: Int, coords: [Double]) -> Double {
        let base = Double(advance(glyph: glyph))
        guard let v = variations, coords.contains(where: { $0 != 0 }) else { return base }
        return base + (v.advanceDelta(glyph: glyph, coords: coords) ?? 0)
    }

    /// GPOS kerning between two glyphs in font units.
    func kern(_ a: Int, _ b: Int, coords: [Double]) -> Double { kerning?.kern(a, b, coords: coords) ?? 0 }
}

/// The Apple `trak` table: tracking in font units per point size, for the normal track (0.0), linear between the sizes and
/// clamped outside them. Core Text applies it to every glyph of the system font (SF text gets looser below 12 pt and
/// tighter above it).
struct SizeTracking: Sendable {
    let sizes: [Double], units: [Double]

    init?(_ b: FontBytes, at o: Int) {
        let horiz = o + b.u16(o + 6)
        guard b.u16(o + 6) != 0 else { return nil }
        let tracks = b.u16(horiz), count = b.u16(horiz + 2), sizeTable = o + b.u32(horiz + 4)
        guard count > 0, tracks > 0, count < 64 else { return nil }
        let s = (0..<count).map { b.fixed(sizeTable + 4 * $0) }
        for t in 0..<tracks where b.fixed(horiz + 8 + 8 * t) == 0 {
            let values = o + b.u16(horiz + 8 + 8 * t + 6)
            sizes = s; units = (0..<count).map { Double(b.s16(values + 2 * $0)) }
            return
        }
        return nil
    }

    /// Font units of tracking at `pointSize`.
    func at(pointSize p: Double) -> Double {
        if p <= sizes[0] { return units[0] }
        for i in 1..<sizes.count where p <= sizes[i] {
            let t = (p - sizes[i - 1]) / (sizes[i] - sizes[i - 1])
            return units[i - 1] + (units[i] - units[i - 1]) * t
        }
        return units[units.count - 1]
    }
}
