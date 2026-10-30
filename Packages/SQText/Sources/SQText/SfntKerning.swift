import Foundation

/// Pair kerning from a font's GPOS table: the lookups of every `kern` feature, pair adjustment (format 1 glyph pairs,
/// format 2 class pairs, also behind extension lookups), x advance of the first glyph with its variation delta (GDEF
/// item variation store). Written from the OpenType 1.9 specification.
/// shortcut: only the x advance of the first glyph (no placement, no mark skipping, no script / language selection: all
/// `kern` lookups apply); enough for Latin titles, upgrade with HarfBuzz for complex scripts.
final class PairKerning: @unchecked Sendable {
    private let bytes: FontBytes
    /// Per lookup, its pair adjustment subtables (first match wins inside a lookup).
    private let lookups: [[Int]]
    private let store: ItemVariationStore?

    init?(_ bytes: FontBytes, tables t: [String: Int]) {
        guard let gpos = t["GPOS"], bytes.u16(gpos) == 1 else { return nil }
        self.bytes = bytes
        let features = gpos + bytes.u16(gpos + 6), lookupList = gpos + bytes.u16(gpos + 8)
        var indices = Set<Int>()
        for i in 0..<bytes.u16(features) {
            let rec = features + 2 + i * 6
            guard bytes.tag(rec) == "kern" else { continue }
            let f = features + bytes.u16(rec + 4)
            for k in 0..<bytes.u16(f + 2) { indices.insert(bytes.u16(f + 4 + k * 2)) }
        }
        var out: [[Int]] = []
        for li in indices.sorted() where li < bytes.u16(lookupList) {
            let l = lookupList + bytes.u16(lookupList + 2 + li * 2)
            let type = bytes.u16(l)
            var subs: [Int] = []
            for k in 0..<bytes.u16(l + 4) {
                let s = l + bytes.u16(l + 6 + k * 2)
                if type == 2 { subs.append(s) } else if type == 9, bytes.u16(s + 2) == 2 { subs.append(s + bytes.u32(s + 4)) }
            }
            if !subs.isEmpty { out.append(subs) }
        }
        guard !out.isEmpty else { return nil }
        lookups = out
        if let gdef = t["GDEF"], bytes.u16(gdef) == 1, bytes.u16(gdef + 2) >= 3, bytes.u32(gdef + 14) > 0 {
            store = ItemVariationStore(bytes, at: gdef + bytes.u32(gdef + 14))
        } else { store = nil }
    }

    /// The advance adjustment between glyphs `a` and `b` (font units), at normalized `coords`.
    func kern(_ a: Int, _ b: Int, coords: [Double]) -> Double {
        var total = 0.0
        for subs in lookups {
            for s in subs { if let v = pair(s, a, b, coords) { total += v; break } }
        }
        return total
    }

    private func valueSize(_ f: Int) -> Int { (0..<8).reduce(0) { $0 + (f >> $1 & 1) } * 2 }

    private func pair(_ s: Int, _ a: Int, _ b: Int, _ coords: [Double]) -> Double? {
        guard let ci = coverage(s + bytes.u16(s + 2), a) else { return nil }
        let f1 = bytes.u16(s + 4), f2 = bytes.u16(s + 6)
        let size1 = valueSize(f1), size2 = valueSize(f2)
        switch bytes.u16(s) {
        case 1:
            guard ci < bytes.u16(s + 8) else { return nil }
            let set = s + bytes.u16(s + 10 + ci * 2)
            let record = 2 + size1 + size2
            var lo = 0, hi = bytes.u16(set) - 1
            while lo <= hi {
                let mid = (lo + hi) / 2, r = set + 2 + mid * record
                let g = bytes.u16(r)
                if g < b { lo = mid + 1 } else if g > b { hi = mid - 1 } else { return xAdvance(r + 2, f1, base: set, coords) }
            }
            return nil
        case 2:
            let c1 = classOf(s + bytes.u16(s + 8), a), c2 = classOf(s + bytes.u16(s + 10), b)
            let n1 = bytes.u16(s + 12), n2 = bytes.u16(s + 14)
            guard c1 < n1, c2 < n2 else { return nil }
            return xAdvance(s + 16 + (c1 * n2 + c2) * (size1 + size2), f1, base: s, coords)
        default:
            return nil
        }
    }

    /// `base`: where device offsets start (the pair set in format 1, the subtable in format 2, as HarfBuzz reads them).
    private func xAdvance(_ r: Int, _ format: Int, base: Int, _ coords: [Double]) -> Double {
        guard format & 0x4 != 0 || format & 0x40 != 0 else { return 0 }
        func at(_ bit: Int) -> Int { r + valueSize(format & (bit - 1)) }
        var v = format & 0x4 != 0 ? Double(bytes.s16(at(0x4))) : 0
        if format & 0x40 != 0, let store, coords.contains(where: { $0 != 0 }) {
            let off = bytes.u16(at(0x40))
            let d = base + off
            if off > 0, bytes.u16(d + 4) == 0x8000 {
                v += store.delta(outer: bytes.u16(d), inner: bytes.u16(d + 2), coords: coords)
            }
        }
        return v
    }

    private func coverage(_ c: Int, _ g: Int) -> Int? {
        switch bytes.u16(c) {
        case 1:
            var lo = 0, hi = bytes.u16(c + 2) - 1
            while lo <= hi {
                let mid = (lo + hi) / 2, v = bytes.u16(c + 4 + mid * 2)
                if v < g { lo = mid + 1 } else if v > g { hi = mid - 1 } else { return mid }
            }
        case 2:
            var lo = 0, hi = bytes.u16(c + 2) - 1
            while lo <= hi {
                let mid = (lo + hi) / 2, r = c + 4 + mid * 6
                if bytes.u16(r + 2) < g { lo = mid + 1 } else if bytes.u16(r) > g { hi = mid - 1 } else {
                    return bytes.u16(r + 4) + g - bytes.u16(r)
                }
            }
        default: break
        }
        return nil
    }

    private func classOf(_ c: Int, _ g: Int) -> Int {
        switch bytes.u16(c) {
        case 1:
            let start = bytes.u16(c + 2), n = bytes.u16(c + 4)
            return g >= start && g < start + n ? bytes.u16(c + 6 + (g - start) * 2) : 0
        case 2:
            var lo = 0, hi = bytes.u16(c + 2) - 1
            while lo <= hi {
                let mid = (lo + hi) / 2, r = c + 4 + mid * 6
                if bytes.u16(r + 2) < g { lo = mid + 1 } else if bytes.u16(r) > g { hi = mid - 1 } else { return bytes.u16(r + 4) }
            }
            return 0
        default: return 0
        }
    }
}
