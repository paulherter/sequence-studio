import Foundation

/// One item of the MP4 `meta` box (ISO BMFF item model: iinf/infe + iloc, bytes in `idat` or at a file offset).
public struct EmbeddedItem: Sendable, Hashable {
    public var id: UInt32
    public var name: String
    public var itemType: String?
    public var contentType: String?
    /// 1 = offsets relative to `idat`, 0 = absolute file offsets, 2 = item offsets (unsupported).
    public var constructionMethod: Int
    /// Absolute file offset of the first extent, and total length of all extents.
    public var fileOffset: UInt64
    public var length: UInt64
    var extentOffsets: [UInt64]
    var extentLengths: [UInt64]
}

/// A camera look LUT found inside a clip. `data` is always `.cube` text, ready for a cube parser.
public struct EmbeddedLUT: Sendable, Hashable {
    public var name: String?
    public var data: Data
    /// Size of the item in the file (Sony: a binary "BCUB" block, converted to text for `data`).
    public var sourceItemBytes: Int
    public var sourceItemName: String

    public init(name: String?, data: Data, sourceItemBytes: Int = 0, sourceItemName: String = "") {
        self.name = name
        self.data = data
        self.sourceItemBytes = sourceItemBytes
        self.sourceItemName = sourceItemName
    }
}

public enum EmbeddedMeta {
    public typealias Reader = (_ offset: UInt64, _ count: Int) throws -> Data

    static let maxItemBytes: UInt64 = 16 << 20

    // MARK: Public entry points

    /// Lists the items of the clip's `meta` box (top level or inside `moov`). Empty if there is none.
    public static func items(inClip url: URL) throws -> [EmbeddedItem] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        return try items(size: size, read: fileReader(fh))
    }

    /// Bytes of one item (all extents concatenated, capped at 16 MB).
    public static func data(of item: EmbeddedItem, inClip url: URL) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        return try data(of: item, read: fileReader(fh))
    }

    /// The camera look LUT of the clip, if any item holds one (plain `.cube` text or Sony's binary look data).
    public static func lut(inClip url: URL) throws -> EmbeddedLUT? {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        let read = fileReader(fh)
        return try lut(in: try items(size: size, read: read), read: read)
    }

    // MARK: Pure parts (testable on synthetic bytes)

    public static func items(inData bytes: Data) throws -> [EmbeddedItem] {
        try items(size: UInt64(bytes.count), read: dataReader(bytes))
    }

    public static func lut(inData bytes: Data) throws -> EmbeddedLUT? {
        let read = dataReader(bytes)
        return try lut(in: try items(size: UInt64(bytes.count), read: read), read: read)
    }

    static func items(size: UInt64, read: Reader) throws -> [EmbeddedItem] {
        guard let meta = try findMeta(size: size, read: read) else { return [] }
        return try parseMeta(body: meta.start, end: meta.end, read: read)
    }

    static func data(of item: EmbeddedItem, read: Reader) throws -> Data {
        var out = Data()
        for (o, l) in zip(item.extentOffsets, item.extentLengths) {
            guard UInt64(out.count) + l <= maxItemBytes else { break }
            out.append(try read(o, Int(l)))
        }
        return out
    }

    static func lut(in items: [EmbeddedItem], read: Reader) throws -> EmbeddedLUT? {
        // Likely candidates first (name mentions look/LUT, then big items), skipping unsupported/empty ones.
        let ranked = items.sorted { rank($0) < rank($1) }
        for item in ranked where item.length > 0 && item.length <= maxItemBytes && item.constructionMethod != 2 {
            let bytes = try data(of: item, read: read)
            if looksLikeCube(bytes) {
                return EmbeddedLUT(name: cubeTitle(bytes) ?? (item.name.isEmpty ? nil : item.name), data: bytes,
                                   sourceItemBytes: bytes.count, sourceItemName: item.name)
            }
            if let sony = SonyLookData.decode(bytes) {
                return EmbeddedLUT(name: sony.name, data: Data(sony.cubeText.utf8),
                                   sourceItemBytes: bytes.count, sourceItemName: item.name)
            }
        }
        return nil
    }

    private static func rank(_ i: EmbeddedItem) -> Int {
        let n = i.name.lowercased()
        if n.contains("look") || n.contains("lut") { return 0 }
        return i.length > 100_000 ? 1 : 2
    }

    /// True if the bytes are `.cube` text: a keyword header line (TITLE / LUT_*_SIZE / DOMAIN_*) comes first.
    public static func looksLikeCube(_ d: Data) -> Bool {
        let head = d.prefix(4096)
        guard !head.contains(0), let text = String(data: head, encoding: .utf8)
                ?? String(data: head.dropLast(1), encoding: .utf8)
                ?? String(data: head.dropLast(2), encoding: .utf8)
                ?? String(data: head.dropLast(3), encoding: .utf8) else { return false }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let key = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
            return key == "TITLE" || key == "LUT_3D_SIZE" || key == "LUT_1D_SIZE" || key.hasPrefix("DOMAIN_")
                || key.hasPrefix("LUT_3D_INPUT_RANGE") || key.hasPrefix("LUT_1D_INPUT_RANGE")
        }
        return false
    }

    private static func cubeTitle(_ d: Data) -> String? {
        guard let text = String(data: d.prefix(4096), encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("TITLE") {
                let t = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
                return t.isEmpty ? nil : t
            }
        }
        return nil
    }

    // MARK: Readers

    static func dataReader(_ d: Data) -> Reader {
        { off, n in
            guard off <= UInt64(d.count) else { throw CocoaError(.fileReadCorruptFile) }
            let s = d.startIndex + Int(off)
            return d.subdata(in: s..<min(d.endIndex, s + n))
        }
    }

    static func fileReader(_ fh: FileHandle) -> Reader {
        { off, n in
            try fh.seek(toOffset: off)
            return try fh.read(upToCount: n) ?? Data()
        }
    }

    // MARK: Box walking

    private struct Box { var type: String; var start: UInt64; var end: UInt64 }  // start = after header

    private static func boxes(from: UInt64, to: UInt64, read: Reader) throws -> [Box] {
        var out: [Box] = []
        var pos = from
        while pos + 8 <= to {
            let h = [UInt8](try read(pos, 16))
            guard h.count >= 8 else { break }
            var size = be(h, 0, 4)
            let type = String(decoding: h[4..<8], as: UTF8.self)
            var header: UInt64 = 8
            if size == 1 {
                guard h.count == 16 else { break }
                size = be(h, 8, 8)
                header = 16
            } else if size == 0 {
                size = to - pos
            }
            guard size >= header, pos + size <= to else { break }
            out.append(Box(type: type, start: pos + header, end: pos + size))
            pos += size
        }
        return out
    }

    private static func findMeta(size: UInt64, read: Reader) throws -> Box? {
        let top = try boxes(from: 0, to: size, read: read)
        if let m = top.first(where: { $0.type == "meta" }) { return m }
        if let moov = top.first(where: { $0.type == "moov" }) {
            return try boxes(from: moov.start, to: moov.end, read: read).first { $0.type == "meta" }
        }
        return nil
    }

    private struct Info { var id: UInt32; var name: String; var type: String?; var content: String? }
    private struct Loc { var method: Int; var base: UInt64; var offsets: [UInt64]; var lengths: [UInt64] }

    private static func parseMeta(body: UInt64, end: UInt64, read: Reader) throws -> [EmbeddedItem] {
        guard body + 4 <= end else { return [] }
        let children = try boxes(from: body + 4, to: end, read: read)  // FullBox: skip version/flags
        var infos: [Info] = []
        var locs: [UInt32: Loc] = [:]
        var idatStart: UInt64 = 0
        for c in children {
            switch c.type {
            case "iinf": infos = try parseIinf(c, read: read)
            case "iloc": locs = try parseIloc(c, read: read)
            case "idat": idatStart = c.start
            default: break
            }
        }
        var items: [EmbeddedItem] = []
        for info in infos {
            guard let loc = locs[info.id] else { continue }
            let offsets = loc.offsets.map { (loc.method == 1 ? idatStart : 0) + loc.base + $0 }
            items.append(EmbeddedItem(
                id: info.id, name: info.name, itemType: info.type, contentType: info.content,
                constructionMethod: loc.method, fileOffset: offsets.first ?? 0,
                length: loc.lengths.reduce(0, +), extentOffsets: offsets, extentLengths: loc.lengths))
        }
        return items
    }

    private static func parseIinf(_ box: Box, read: Reader) throws -> [Info] {
        let d = [UInt8](try read(box.start, Int(min(box.end - box.start, 1 << 20))))
        guard d.count >= 6 else { return [] }
        let version = d[0]
        var p = 4
        let count = version == 0 ? Int(be(d, p, 2)) : Int(be(d, p, 4))
        p += version == 0 ? 2 : 4
        var out: [Info] = []
        for _ in 0..<count {
            guard p + 12 <= d.count else { break }
            let size = Int(be(d, p, 4))
            guard size >= 12, p + size <= d.count,
                  String(decoding: d[(p + 4)..<(p + 8)], as: UTF8.self) == "infe" else { break }
            let v = d[p + 8]
            let b = Array(d[(p + 12)..<(p + size)])  // after size, type, version/flags
            var q = 0
            var id: UInt32 = 0
            var itemType: String?
            if v >= 2 {
                let idLen = v == 2 ? 2 : 4
                guard b.count >= idLen + 2 + 4 else { break }
                id = UInt32(truncatingIfNeeded: be(b, 0, idLen)); q = idLen + 2
                itemType = String(decoding: b[q..<(q + 4)], as: UTF8.self); q += 4
            } else {
                guard b.count >= 4 else { break }
                id = UInt32(truncatingIfNeeded: be(b, 0, 2)); q = 4
            }
            let name = cString(b, &q)
            var content: String?
            if q < b.count, v < 2 || itemType == "mime" { content = cString(b, &q) }
            out.append(Info(id: id, name: name, type: itemType, content: content))
            p += size
        }
        return out
    }

    private static func parseIloc(_ box: Box, read: Reader) throws -> [UInt32: Loc] {
        let d = [UInt8](try read(box.start, Int(min(box.end - box.start, 1 << 20))))
        guard d.count >= 8 else { return [:] }
        let version = Int(d[0])
        let offSize = Int(d[4] >> 4), lenSize = Int(d[4] & 15)
        let baseSize = Int(d[5] >> 4)
        let indexSize = version >= 1 ? Int(d[5] & 15) : 0
        var p = 6
        let count: Int
        if version < 2 { count = Int(be(d, p, 2)); p += 2 } else { count = Int(be(d, p, 4)); p += 4 }
        var out: [UInt32: Loc] = [:]
        for _ in 0..<count {
            let idSize = version < 2 ? 2 : 4
            guard p + idSize <= d.count else { break }
            let id = UInt32(truncatingIfNeeded: be(d, p, idSize)); p += idSize
            var method = 0
            if version >= 1 {
                guard p + 2 <= d.count else { break }
                method = Int(be(d, p, 2) & 15); p += 2
            }
            guard p + 2 + baseSize + 2 <= d.count else { break }
            p += 2  // data_reference_index
            let base = be(d, p, baseSize); p += baseSize
            let n = Int(be(d, p, 2)); p += 2
            var loc = Loc(method: method, base: base, offsets: [], lengths: [])
            for _ in 0..<n {
                guard p + indexSize + offSize + lenSize <= d.count else { break }
                p += indexSize
                loc.offsets.append(be(d, p, offSize)); p += offSize
                loc.lengths.append(be(d, p, lenSize)); p += lenSize
            }
            out[id] = loc
        }
        return out
    }

    private static func be(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
        guard n > 0, at + n <= b.count else { return 0 }
        return b[at..<(at + n)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private static func cString(_ b: [UInt8], _ q: inout Int) -> String {
        let s = q
        while q < b.count, b[q] != 0 { q += 1 }
        let str = String(decoding: b[s..<q], as: UTF8.self)
        if q < b.count { q += 1 }
        return str
    }
}

/// Sony "Look Control data" item: SMPTE KLV ("ELUT") wrapping a big-endian "SONYBCUB" block.
/// Layout found in ZV-E1 clips (offsets from the start of "SONYBCUB"): u32 version at 8, u32 block length at 12,
/// u32 LUT size N at 128, u32 data offset at 136 (3328), u32 data length at 140 (N^3 * 12), 3 x f32 domain min at 144,
/// 3 x f32 domain max at 156, NUL-terminated file name at 256; the data are N^3 big-endian RGB f32 triplets, red fastest.
enum SonyLookData {
    struct Decoded { var name: String?; var size: Int; var cubeText: String }

    static func decode(_ item: Data) -> Decoded? {
        let magic = Data("SONYBCUB".utf8)
        guard item.count > 400, let r = item.range(of: magic) else { return nil }
        let b = item[r.lowerBound...]
        let base = b.startIndex
        func u32(_ o: Int) -> Int {
            guard o + 4 <= b.count else { return 0 }
            return (0..<4).reduce(0) { $0 << 8 | Int(b[base + o + $1]) }
        }
        func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: u32(o))) }
        let n = u32(128), dataOffset = u32(136), dataLength = u32(140)
        guard (2...129).contains(n), dataLength == n * n * n * 12, dataOffset >= 256,
              dataOffset + dataLength <= b.count else { return nil }
        let dmin = (0..<3).map { f32(144 + 4 * $0) }, dmax = (0..<3).map { f32(156 + 4 * $0) }
        guard (dmin + dmax).allSatisfy({ $0.isFinite }), zip(dmin, dmax).allSatisfy({ $0 < $1 }) else { return nil }
        var nameEnd = 256
        while nameEnd < min(b.count, 256 + 128), b[base + nameEnd] != 0 { nameEnd += 1 }
        let name = String(decoding: b[(base + 256)..<(base + nameEnd)], as: UTF8.self)
        var text = "TITLE \"\(name)\"\nLUT_3D_SIZE \(n)\n"
        text += String(format: "DOMAIN_MIN %.6f %.6f %.6f\nDOMAIN_MAX %.6f %.6f %.6f\n",
                       dmin[0], dmin[1], dmin[2], dmax[0], dmax[1], dmax[2])
        for i in 0..<(n * n * n) {
            let o = dataOffset + i * 12
            let (x, y, z) = (f32(o), f32(o + 4), f32(o + 8))
            guard x.isFinite, y.isFinite, z.isFinite else { return nil }
            text += String(format: "%.6f %.6f %.6f\n", x, y, z)
        }
        return Decoded(name: name.isEmpty ? nil : name, size: n, cubeText: text)
    }
}
