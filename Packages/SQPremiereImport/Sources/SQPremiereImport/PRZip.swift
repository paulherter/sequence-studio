import Foundation

/// Minimal ZIP reader for template packages (.mogrt and the project.prgraphic inside): stored and deflated entries read
/// through the central directory. No ZIP64, no encryption, no CRC check. Written from the public ZIP specification
/// (APPNOTE.TXT); entries are inflated only when asked for, so a large preview movie in the package costs nothing.
struct PRZip {
    struct Entry: Equatable {
        var name: String
        var method: Int
        var compressedSize: Int
        var uncompressedSize: Int
        var localOffset: Int
        var encrypted: Bool
    }

    /// Largest entry this reader inflates (definitions and embedded projects are kilobytes to a few megabytes).
    static let maxEntrySize = 256 << 20

    private let data: Data
    let entries: [Entry]
    var names: [String] { entries.map(\.name) }

    init(_ data: Data) throws {
        self.data = data
        let n = data.count
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= n ? Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? { u16(o).flatMap { lo in u16(o + 2).map { lo | $0 << 16 } } }
        // End of central directory: the last 22 bytes plus an optional comment of up to 65535 bytes.
        guard n >= 22 else { throw PRImportError.corruptArchive }
        var eocd: Int?
        var p = n - 22
        let lowest = max(0, n - 22 - 0xFFFF)
        while p >= lowest {
            if u32(p) == 0x0605_4b50 { eocd = p; break }
            p -= 1
        }
        guard let eocd, let count = u16(eocd + 10), let cdOffset = u32(eocd + 16), cdOffset < n else { throw PRImportError.corruptArchive }
        var out: [Entry] = []
        var q = cdOffset
        for _ in 0..<count {
            guard u32(q) == 0x0201_4b50, let flags = u16(q + 8), let method = u16(q + 10), let csize = u32(q + 20),
                  let usize = u32(q + 24), let nameLen = u16(q + 28), let extraLen = u16(q + 30), let commentLen = u16(q + 32),
                  let local = u32(q + 42), q + 46 + nameLen <= n else { throw PRImportError.corruptArchive }
            let nameBytes = data.subdata(in: (data.startIndex + q + 46)..<(data.startIndex + q + 46 + nameLen))
            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: Unicode.ASCII.self)
            out.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localOffset: local,
                             encrypted: flags & 1 != 0))
            q += 46 + nameLen + extraLen + commentLen
        }
        entries = out
    }

    /// The first entry whose name matches (case-insensitive, as packages on macOS and Windows differ).
    func entry(_ name: String) -> Entry? { entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    /// The entry's bytes; nil when there is no such entry. Throws `corruptArchive` for a damaged, encrypted or oversized one.
    func data(_ name: String) throws -> Data? { try entry(name).map(data) }

    func data(_ e: Entry) throws -> Data {
        let n = data.count, o = e.localOffset
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= n ? Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 : nil }
        guard !e.encrypted, e.uncompressedSize <= Self.maxEntrySize, e.compressedSize <= Self.maxEntrySize,
              u16(o) == 0x4b50, u16(o + 2) == 0x0403, let nameLen = u16(o + 26), let extraLen = u16(o + 28) else {
            throw PRImportError.corruptArchive
        }
        let start = o + 30 + nameLen + extraLen
        guard start + e.compressedSize <= n else { throw PRImportError.corruptArchive }
        let body = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        switch e.method {
        case 0: return body
        case 8:
            let inflated = try PRGzip.rawInflate([UInt8](body), limit: min(e.uncompressedSize, Self.maxEntrySize))
            guard inflated.count == e.uncompressedSize else { throw PRImportError.corruptArchive }
            return inflated
        default: throw PRImportError.corruptArchive
        }
    }
}
