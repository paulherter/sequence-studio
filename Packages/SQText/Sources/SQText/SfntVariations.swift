import Foundation

// Variable fonts for the portable text backend (OpenType `fvar`, `avar`, `gvar`, `HVAR` and item variation stores),
// written from the OpenType 1.9 specification. Compiled everywhere: the Mac tests compare it with Core Text.

/// Big-endian reads over a font file; reads outside the file give 0.
struct FontBytes: @unchecked Sendable {
    let b: [UInt8]
    @inline(__always) func u8(_ o: Int) -> Int { o >= 0 && o < b.count ? Int(b[o]) : 0 }
    @inline(__always) func s8(_ o: Int) -> Int { let v = u8(o); return v >= 0x80 ? v - 0x100 : v }
    @inline(__always) func u16(_ o: Int) -> Int { o >= 0 && o + 2 <= b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
    @inline(__always) func s16(_ o: Int) -> Int { let v = u16(o); return v >= 0x8000 ? v - 0x10000 : v }
    @inline(__always) func u32(_ o: Int) -> Int { u16(o) << 16 | u16(o + 2) }
    @inline(__always) func s32(_ o: Int) -> Int { let v = u32(o); return v >= 0x8000_0000 ? v - 0x1_0000_0000 : v }
    func f2dot14(_ o: Int) -> Double { Double(s16(o)) / 16384 }
    func fixed(_ o: Int) -> Double { Double(s32(o)) / 65536 }
    func tag(_ o: Int) -> String { String(decoding: (0..<4).map { UInt8(u8(o + $0)) }, as: UTF8.self) }

    /// Table offsets by tag (a collection's first font).
    func tables() -> [String: Int] {
        var base = 0
        if tag(0) == "ttcf" { base = u32(12) }
        var out: [String: Int] = [:]
        for i in 0..<u16(base + 4) {
            let rec = base + 12 + i * 16
            guard rec + 16 <= b.count else { break }
            out[tag(rec)] = u32(rec + 8)
        }
        return out
    }
}

/// One region of the variation space: per axis (start, peak, end) in normalized coordinates.
enum VariationTent {
    /// The scalar of a tuple at `coords` (OpenType "Algorithm for interpolation of instance values").
    static func scalar(peak: [Double], start: [Double]?, end: [Double]?, coords: [Double]) -> Double {
        var s = 1.0
        for i in peak.indices {
            let p = peak[i]
            if p == 0 { continue }
            let lo = start?[i] ?? min(0, p), hi = end?[i] ?? max(0, p)
            if lo > p || p > hi || (lo < 0 && hi > 0) { continue }
            let v = i < coords.count ? coords[i] : 0
            if v == p { continue }
            if v <= lo || v >= hi { return 0 }
            s *= v < p ? (v - lo) / (p - lo) : (hi - v) / (hi - p)
        }
        return s
    }
}

/// An item variation store (HVAR, GDEF): delta sets by (outer, inner) index, scaled by their regions.
struct ItemVariationStore: @unchecked Sendable {
    private let bytes: FontBytes
    private let regions: [[(Double, Double, Double)]]
    private let data: [Int]

    init?(_ bytes: FontBytes, at o: Int) {
        guard o > 0, bytes.u16(o) == 1 else { return nil }
        self.bytes = bytes
        let rl = o + bytes.u32(o + 2)
        let axes = bytes.u16(rl), count = bytes.u16(rl + 2)
        regions = (0..<count).map { r in
            (0..<axes).map { a in
                let p = rl + 4 + (r * axes + a) * 6
                return (bytes.f2dot14(p), bytes.f2dot14(p + 2), bytes.f2dot14(p + 4))
            }
        }
        data = (0..<bytes.u16(o + 6)).map { o + bytes.u32(o + 8 + $0 * 4) }
    }

    func delta(outer: Int, inner: Int, coords: [Double]) -> Double {
        guard outer < data.count else { return 0 }
        let d = data[outer]
        let items = bytes.u16(d), wordField = bytes.u16(d + 2), regionCount = bytes.u16(d + 4)
        guard inner < items else { return 0 }
        let long = wordField & 0x8000 != 0, words = wordField & 0x7FFF
        let rowSize = long ? words * 4 + (regionCount - words) * 2 : words * 2 + (regionCount - words)
        var p = d + 6 + regionCount * 2 + inner * rowSize
        var sum = 0.0
        for j in 0..<regionCount {
            let v: Int
            if j < words { v = long ? bytes.s32(p) : bytes.s16(p); p += long ? 4 : 2 } else {
                v = long ? bytes.s16(p) : bytes.s8(p); p += long ? 2 : 1
            }
            let ri = bytes.u16(d + 6 + j * 2)
            guard v != 0, ri < regions.count else { continue }
            let r = regions[ri]
            sum += Double(v) * VariationTent.scalar(peak: r.map(\.1), start: r.map(\.0), end: r.map(\.2), coords: coords)
        }
        return sum
    }
}

/// The variation tables of a font: axes, named instances, normalization, glyph point deltas and advance deltas.
final class FontVariations: @unchecked Sendable {
    struct Axis: Sendable { let tag: String; let minimum: Double; let defaultValue: Double; let maximum: Double }
    let axes: [Axis]
    /// Named instances, user coordinates in axis order.
    let instances: [[Double]]
    private let bytes: FontBytes
    private let avar: [[(Double, Double)]]
    private let gvar: Int?, gvarLong: Bool, gvarData: Int, gvarGlyphs: Int
    private let sharedTuples: [[Double]]
    private let hvar: ItemVariationStore?, hvarMap: Int?

    init?(_ bytes: FontBytes, tables t: [String: Int]) {
        guard let fvar = t["fvar"] else { return nil }
        self.bytes = bytes
        let axesAt = fvar + bytes.u16(fvar + 4), axisCount = bytes.u16(fvar + 8), axisSize = bytes.u16(fvar + 10)
        let instanceCount = bytes.u16(fvar + 12), instanceSize = bytes.u16(fvar + 14)
        guard axisCount > 0 else { return nil }
        axes = (0..<axisCount).map { i in
            let a = axesAt + i * axisSize
            return Axis(tag: bytes.tag(a), minimum: bytes.fixed(a + 4), defaultValue: bytes.fixed(a + 8), maximum: bytes.fixed(a + 12))
        }
        let instancesAt = axesAt + axisCount * axisSize
        instances = (0..<instanceCount).map { i in
            (0..<axisCount).map { bytes.fixed(instancesAt + i * instanceSize + 4 + $0 * 4) }
        }
        var maps: [[(Double, Double)]] = []
        if let a = t["avar"] {
            var p = a + 8
            for _ in 0..<bytes.u16(a + 6) {
                let n = bytes.u16(p)
                maps.append((0..<n).map { (bytes.f2dot14(p + 2 + $0 * 4), bytes.f2dot14(p + 4 + $0 * 4)) })
                p += 2 + n * 4
            }
        }
        avar = maps
        if let g = t["gvar"], bytes.u16(g + 4) == axisCount {
            gvar = g
            gvarGlyphs = bytes.u16(g + 12)
            gvarLong = bytes.u16(g + 14) & 1 != 0
            gvarData = g + bytes.u32(g + 16)
            let shared = g + bytes.u32(g + 8)
            sharedTuples = (0..<bytes.u16(g + 6)).map { i in (0..<axisCount).map { bytes.f2dot14(shared + (i * axisCount + $0) * 2) } }
        } else {
            gvar = nil; gvarGlyphs = 0; gvarLong = false; gvarData = 0; sharedTuples = []
        }
        if let h = t["HVAR"] {
            hvar = ItemVariationStore(bytes, at: h + bytes.u32(h + 4))
            let m = bytes.u32(h + 8)
            hvarMap = m > 0 ? h + m : nil
        } else { hvar = nil; hvarMap = nil }
    }

    func axisIndex(_ tag: String) -> Int? { axes.firstIndex { $0.tag == tag } }

    /// User coordinates (axis order) to normalized ones: default 0, ends -1 / 1, `avar` applied, F2Dot14 precision.
    func normalized(_ user: [Double]) -> [Double] {
        axes.indices.map { i in
            let a = axes[i]
            let v = min(max(i < user.count ? user[i] : a.defaultValue, a.minimum), a.maximum)
            var n = 0.0
            if v < a.defaultValue, a.defaultValue > a.minimum { n = (v - a.defaultValue) / (a.defaultValue - a.minimum) }
            if v > a.defaultValue, a.maximum > a.defaultValue { n = (v - a.defaultValue) / (a.maximum - a.defaultValue) }
            if i < avar.count, let mapped = Self.map(n, avar[i]) { n = mapped }
            return (n * 16384).rounded() / 16384
        }
    }

    private static func map(_ v: Double, _ seg: [(Double, Double)]) -> Double? {
        guard seg.count >= 2 else { return nil }
        if v <= seg[0].0 { return seg[0].1 }
        for k in 1..<seg.count where v <= seg[k].0 {
            let (a, b) = (seg[k - 1], seg[k])
            return b.0 == a.0 ? b.1 : a.1 + (v - a.0) * (b.1 - a.1) / (b.0 - a.0)
        }
        return seg[seg.count - 1].1
    }

    /// The advance width delta of a glyph in font units (HVAR), nil when the font has no HVAR (use the phantom points).
    func advanceDelta(glyph g: Int, coords: [Double]) -> Double? {
        guard let hvar else { return nil }
        var outer = 0, inner = g
        if let m = hvarMap {
            let format = bytes.u8(m), entry = bytes.u8(m + 1)
            let count = format == 0 ? bytes.u16(m + 2) : bytes.u32(m + 2)
            let at = m + (format == 0 ? 4 : 6)
            let size = (entry >> 4 & 3) + 1, innerBits = (entry & 0xF) + 1
            let i = min(g, max(0, count - 1))
            var v = 0
            for k in 0..<size { v = v << 8 | bytes.u8(at + i * size + k) }
            outer = v >> innerBits; inner = v & (1 << innerBits - 1)
        }
        return hvar.delta(outer: outer, inner: inner, coords: coords)
    }

    /// Point deltas (x, y) of glyph `g` at `coords`: `pointCount` outline points (or composite components) then the four
    /// phantom points. `original` and `ends` (simple glyphs) let untouched points be interpolated (IUP); composite glyphs
    /// pass nil and untouched components stay put. nil when the glyph does not vary.
    func deltas(glyph g: Int, pointCount: Int, original: [GlyphRasterFont.Point]?, ends: [Int],
                coords: [Double]) -> [SIMD2<Double>]? {
        guard let gvar, g >= 0, g < gvarGlyphs, coords.contains(where: { $0 != 0 }) else { return nil }
        let offs = gvar + 20
        let a = gvarLong ? bytes.u32(offs + g * 4) : bytes.u16(offs + g * 2) * 2
        let b = gvarLong ? bytes.u32(offs + g * 4 + 4) : bytes.u16(offs + g * 2 + 2) * 2
        guard b > a else { return nil }
        let o = gvarData + a
        let raw = bytes.u16(o)
        let tupleCount = raw & 0x0FFF
        var serialized = o + bytes.u16(o + 2)
        let total = pointCount + 4
        var shared: [Int]?
        if raw & 0x8000 != 0 { shared = readPoints(&serialized) }
        var out = [SIMD2<Double>](repeating: .zero, count: total)
        var header = o + 4
        let n = axes.count
        var changed = false
        for _ in 0..<tupleCount {
            let size = bytes.u16(header), index = bytes.u16(header + 2)
            header += 4
            var peak: [Double]
            if index & 0x8000 != 0 {
                peak = (0..<n).map { bytes.f2dot14(header + $0 * 2) }; header += n * 2
            } else {
                let k = index & 0x0FFF
                peak = k < sharedTuples.count ? sharedTuples[k] : [Double](repeating: 0, count: n)
            }
            var start: [Double]?, end: [Double]?
            if index & 0x4000 != 0 {
                start = (0..<n).map { bytes.f2dot14(header + $0 * 2) }; header += n * 2
                end = (0..<n).map { bytes.f2dot14(header + $0 * 2) }; header += n * 2
            }
            var p = serialized
            serialized += size
            let s = VariationTent.scalar(peak: peak, start: start, end: end, coords: coords)
            if s == 0 { continue }
            let points = index & 0x2000 != 0 ? readPoints(&p) : shared
            let count = points?.count ?? total
            let xs = readDeltas(&p, count), ys = readDeltas(&p, count)
            changed = true
            guard let points else {
                for i in 0..<total { out[i] += SIMD2(xs[i], ys[i]) * s }
                continue
            }
            var tuple = [SIMD2<Double>](repeating: .zero, count: total)
            var touched = [Bool](repeating: false, count: total)
            for (k, i) in points.enumerated() where i < total { tuple[i] = SIMD2(xs[k], ys[k]); touched[i] = true }
            if let original { Self.interpolateUntouched(&tuple, touched: touched, original: original, ends: ends) }
            for i in 0..<total { out[i] += tuple[i] * s }
        }
        return changed ? out : nil
    }

    /// Packed point numbers; nil = every point.
    private func readPoints(_ p: inout Int) -> [Int]? {
        var count = bytes.u8(p); p += 1
        if count & 0x80 != 0 { count = (count & 0x7F) << 8 | bytes.u8(p); p += 1 }
        if count == 0 { return nil }
        var out: [Int] = []
        out.reserveCapacity(count)
        var last = 0
        while out.count < count {
            let control = bytes.u8(p); p += 1
            let run = (control & 0x7F) + 1, words = control & 0x80 != 0
            for _ in 0..<run where out.count < count {
                last += words ? bytes.u16(p) : bytes.u8(p)
                p += words ? 2 : 1
                out.append(last)
            }
            if p >= bytes.b.count { break }
        }
        return out
    }

    private func readDeltas(_ p: inout Int, _ count: Int) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(count)
        while out.count < count {
            let control = bytes.u8(p); p += 1
            let run = (control & 0x3F) + 1
            for _ in 0..<run where out.count < count {
                switch control & 0xC0 {
                case 0x80: out.append(0)
                case 0x40: out.append(Double(bytes.s16(p))); p += 2
                case 0xC0: out.append(Double(bytes.s32(p))); p += 4
                default: out.append(Double(bytes.s8(p))); p += 1
                }
            }
            if p >= bytes.b.count { break }
        }
        while out.count < count { out.append(0) }
        return out
    }

    /// Interpolation of untouched points per contour (OpenType "Inferred deltas for un-referenced point numbers").
    static func interpolateUntouched(_ d: inout [SIMD2<Double>], touched: [Bool], original: [GlyphRasterFont.Point], ends: [Int]) {
        var start = 0
        for end in ends {
            guard end >= start, end < original.count else { break }
            let idx = Array(start...end).filter { touched[$0] }
            defer { start = end + 1 }
            if idx.isEmpty || idx.count == end - start + 1 { continue }
            if idx.count == 1 {
                for i in start...end where !touched[i] { d[i] = d[idx[0]] }
                continue
            }
            for (k, a) in idx.enumerated() {
                let b = idx[(k + 1) % idx.count]
                var i = a + 1
                while true {
                    if i > end { i = start }
                    if i == b { break }
                    for axis in 0..<2 {
                        let c = axis == 0 ? original[i].x : original[i].y
                        var c1 = axis == 0 ? original[a].x : original[a].y, c2 = axis == 0 ? original[b].x : original[b].y
                        var d1 = d[a][axis], d2 = d[b][axis]
                        if c1 > c2 { swap(&c1, &c2); swap(&d1, &d2) }
                        if c1 == c2 {
                            d[i][axis] = c == c1 ? (d1 == d2 ? d1 : 0) : c < c1 ? d1 : d2
                        } else {
                            d[i][axis] = c <= c1 ? d1 : c >= c2 ? d2 : d1 + (c - c1) * (d2 - d1) / (c2 - c1)
                        }
                    }
                    i += 1
                }
            }
        }
    }
}
