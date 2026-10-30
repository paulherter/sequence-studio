import Foundation

/// Raw deflate (RFC 1951) and zlib (RFC 1950) in plain Swift, for platforms without the Compression framework (Windows):
/// the .prproj reader (`SQPremiereImport`) and `PortablePNG` use it. macOS uses Compression elsewhere; the tests run both
/// on the same bytes.
/// shortcut: bit-by-bit Huffman decoding (slow for pictures of several megapixels); upgrade to table lookups when a large
/// picture or a big project file decodes slowly.
public enum RawInflate {
    public enum Failure: Error, Equatable { case corrupt }

    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]
        init(lengths: [Int]) {
            symbols = [Int](repeating: 0, count: lengths.count)
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offs = [Int](repeating: 0, count: 16)
            for i in 1..<15 { offs[i + 1] = offs[i] + counts[i] }
            for (s, l) in lengths.enumerated() where l != 0 { symbols[offs[l]] = s; offs[l] += 1 }
        }
    }

    private static let lenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// Inflates raw deflate bytes; throws `Failure.corrupt` for bad input or output beyond `limit`.
    public static func inflate(_ src: [UInt8], limit: Int) throws -> Data {
        var pos = 0, bitBuf = 0, bitCnt = 0
        var out = [UInt8]()
        func bits(_ n: Int) throws -> Int {
            while bitCnt < n {
                guard pos < src.count else { throw Failure.corrupt }
                bitBuf |= Int(src[pos]) << bitCnt; pos += 1; bitCnt += 8
            }
            let v = bitBuf & ((1 << n) - 1)
            bitBuf >>= n; bitCnt -= n
            return v
        }
        func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = h.counts[len]
                if code - count < first { return h.symbols[index + (code - first)] }
                index += count; first += count; first <<= 1; code <<= 1
            }
            throw Failure.corrupt
        }
        var fixedLit: Huffman?, fixedDist: Huffman?
        var last = false
        while !last {
            last = try bits(1) == 1
            let type = try bits(2)
            if type == 0 {
                bitBuf = 0; bitCnt = 0
                guard pos + 4 <= src.count else { throw Failure.corrupt }
                let len = Int(src[pos]) | Int(src[pos + 1]) << 8
                pos += 4
                guard pos + len <= src.count, out.count + len <= limit else { throw Failure.corrupt }
                out.append(contentsOf: src[pos..<(pos + len)]); pos += len
                continue
            }
            let lit: Huffman, dist: Huffman
            if type == 1 {
                if fixedLit == nil {
                    var l = [Int](repeating: 8, count: 288)
                    for i in 144..<256 { l[i] = 9 }
                    for i in 256..<280 { l[i] = 7 }
                    fixedLit = Huffman(lengths: l); fixedDist = Huffman(lengths: [Int](repeating: 5, count: 30))
                }
                lit = fixedLit!; dist = fixedDist!
            } else if type == 2 {
                let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
                guard nlen <= 286, ndist <= 30 else { throw Failure.corrupt }
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var cl = [Int](repeating: 0, count: 19)
                for i in 0..<ncode { cl[order[i]] = try bits(3) }
                let clh = Huffman(lengths: cl)
                var lengths = [Int]()
                while lengths.count < nlen + ndist {
                    let sym = try decode(clh)
                    if sym < 16 { lengths.append(sym); continue }
                    var rep = 0, val = 0
                    if sym == 16 { guard let p = lengths.last else { throw Failure.corrupt }; val = p; rep = 3 + (try bits(2)) }
                    else if sym == 17 { rep = 3 + (try bits(3)) } else { rep = 11 + (try bits(7)) }
                    guard lengths.count + rep <= nlen + ndist else { throw Failure.corrupt }
                    lengths.append(contentsOf: [Int](repeating: val, count: rep))
                }
                lit = Huffman(lengths: Array(lengths[0..<nlen])); dist = Huffman(lengths: Array(lengths[nlen...]))
            } else { throw Failure.corrupt }
            while true {
                let sym = try decode(lit)
                if sym < 256 {
                    guard out.count < limit else { throw Failure.corrupt }
                    out.append(UInt8(sym))
                } else if sym == 256 { break }
                else {
                    let li = sym - 257
                    guard li < 29 else { throw Failure.corrupt }
                    let len = lenBase[li] + (try bits(lenExtra[li]))
                    let ds = try decode(dist)
                    guard ds < 30 else { throw Failure.corrupt }
                    let d = distBase[ds] + (try bits(distExtra[ds]))
                    guard d <= out.count, out.count + len <= limit else { throw Failure.corrupt }
                    let start = out.count - d
                    for i in 0..<len { out.append(out[start + i]) }
                }
            }
        }
        return Data(out)
    }

    /// A zlib stream (2-byte header, deflate data, Adler-32 not checked) as in a PNG's IDAT chunks.
    public static func zlib(_ src: [UInt8], limit: Int) throws -> Data {
        guard src.count > 2, src[0] & 0x0F == 8, src[1] & 0x20 == 0, (Int(src[0]) << 8 | Int(src[1])) % 31 == 0 else { throw Failure.corrupt }
        return try inflate(Array(src[2...]), limit: limit)
    }
}
