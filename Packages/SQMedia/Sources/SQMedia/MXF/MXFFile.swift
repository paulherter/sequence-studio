import Foundation
import SQCore
import Synchronization

/// One index table segment (ST 377-1 section 11).
struct MXFIndexSegment {
    var startPosition: Int64 = 0
    var duration: Int64 = 0
    var editUnitByteCount = 0
    var indexSID: UInt32 = 0, bodySID: UInt32 = 0
    var temporalOffsets: [Int8] = []
    var flags: [UInt8] = []
    var streamOffsets: [UInt64] = []

    init() {}

    init?(_ r: MXFBytes, _ k: MXFKLV) {
        guard let s = MXFSet(r, k, kind: 0x10) else { return nil }
        startPosition = s.int64(0x3F0C) ?? 0
        duration = s.int64(0x3F0D) ?? 0
        editUnitByteCount = s.int(0x3F05) ?? 0
        indexSID = UInt32(truncatingIfNeeded: s.uint(0x3F06) ?? 0)
        bodySID = UInt32(truncatingIfNeeded: s.uint(0x3F07) ?? 0)
        guard startPosition >= 0, duration >= 0 else { return nil }
        if let a = s.items[0x3F0A], a.count >= 8, let n = r.u32(a.lowerBound), let len = r.u32(a.lowerBound + 4), len >= 11 {
            let count = min(Int(n), (a.count - 8) / Int(len))
            temporalOffsets.reserveCapacity(count); flags.reserveCapacity(count); streamOffsets.reserveCapacity(count)
            for i in 0..<count {
                let o = a.lowerBound + 8 + i * Int(len)
                guard let t = r.u8(o), let f = r.u8(o + 2), let so = r.u64(o + 3) else { break }
                temporalOffsets.append(Int8(bitPattern: t)); flags.append(f); streamOffsets.append(so)
            }
        }
    }
}

/// A partition pack and what follows it.
struct MXFPartition {
    var offset = 0
    /// 2 header, 3 body, 4 footer.
    var kind: UInt8 = 0
    /// Open partitions (status 1 and 3) may carry unfinished metadata.
    var isOpen = false
    var previous = 0, footer = 0
    var headerByteCount = 0, indexByteCount = 0
    var indexSID: UInt32 = 0, bodySID: UInt32 = 0
    var bodyOffset: UInt64 = 0
    var packEnd = 0
    /// First essence or system item KLV of this partition, nil when it has none.
    var essenceStart: Int?
    var essenceEnd = 0
    /// Primer pack and metadata sets.
    var metadata: Range<Int>?
}

/// A parsed MXF file (SMPTE ST 377-1): OP1a, frame-wrapped essence, as cameras and editors write it.
/// The file is read with positional reads, never mapped; every length is bounds-checked, malformed files throw instead of trapping.
public final class MXFFile: @unchecked Sendable {
    public let url: URL
    let bytes: MXFBytes
    /// Picture, sound and data tracks of the file package.
    public let tracks: [MXFTrack]
    public let timecode: MXFTimecode?
    /// Bytes before the header partition (run-in).
    public let runIn: Int
    public let partitionCount: Int
    /// True when the edit units come from the index table, false when the essence was scanned (no usable index:
    /// file still being written, truncated, or a broken index).
    public let usesIndexTable: Bool
    /// File offset of each edit unit (content package), in stored order.
    let unitOffsets: [Int]
    /// Per edit unit from the index table: temporal offset and flags. Empty when the index does not have them.
    let temporalOffsets: [Int8]
    let flags: [UInt8]

    /// What every open instance of one file shares through the cached parse (`open`, keyed by path, size and
    /// modification date): the sample index a demuxer built, so thumbnails and color detection do not sort the
    /// index or scan the stream again.
    final class Shared: Sendable {
        let built = Mutex<MXFDemuxer.Built?>(nil)
        /// How often a demuxer built the sample index of this file (tests).
        let indexBuilds = Mutex(0)
    }
    let shared: Shared

    public var unitCount: Int { unitOffsets.count }
    public var videoTrack: MXFTrack? { tracks.first { $0.kind == .picture } }
    public var soundTracks: [MXFTrack] { tracks.filter { $0.kind == .sound } }

    // MARK: opening

    /// True for a file that starts with an MXF partition pack; a run-in (up to 64 KB) is only searched for `.mxf`.
    public static func isMXF(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let wide = url.pathExtension.lowercased() == "mxf"
        guard let d = try? h.read(upToCount: wide ? 65_536 + 16 : 16), d.count >= 16 else { return false }
        return headerOffset(MXFBytes(d), limit: wide ? 65_536 : 0) != nil
    }

    static func headerOffset(_ r: MXFBytes, limit: Int) -> Int? {
        let prefix: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02]
        return r.withBytes(0..<min(r.count, limit + 16)) { p -> Int? in
            var i = 0
            while i + 16 <= p.count {
                if p[i] == 0x06, p[i + 1] == 0x0E {
                    var ok = true
                    for j in 2..<prefix.count where p[i + j] != prefix[j] { ok = false; break }
                    if ok, p[i + 13] == 0x02 { return i }
                }
                i += 1
            }
            return nil
        } ?? nil
    }

    /// Parses without an open file, least recently used first.
    private static let cache = Mutex<[(key: String, parse: MXFFile)]>([])
    static let cacheLimit = 32

    private static func key(_ url: URL, _ r: MXFFileReader) -> String { "\(url.path)|\(r.size)|\(r.modified)" }

    /// Opens `url` with its own file descriptor (closed when the returned file is released). The parse is cached
    /// by path, size and modification date; the cache itself keeps no file open, so a card can be ejected once
    /// nothing reads from it.
    public static func open(_ url: URL) throws -> MXFFile {
        guard let reader = MXFFileReader(url: url) else { throw MediaError.unreadable }
        let key = key(url, reader)
        let hit = cache.withLock { c -> MXFFile? in
            guard let i = c.firstIndex(where: { $0.key == key }) else { return nil }
            let e = c.remove(at: i)
            c.append(e)
            return e.parse
        }
        if let hit { return MXFFile(parse: hit, bytes: MXFBytes(reader)) }
        let f = try MXFFile(bytes: MXFBytes(reader), url: url)
        let parse = MXFFile(parse: f, bytes: MXFBytes(detached: reader.size))
        cache.withLock { c in
            c.removeAll { $0.key == key }
            c.append((key, parse))
            if c.count > cacheLimit { c.removeFirst(c.count - cacheLimit) }
        }
        return f
    }

    /// The cached parse of `url` (it has no open file), nil when there is none. Does not count as a use.
    static func cachedParse(of url: URL) -> MXFFile? {
        guard let reader = MXFFileReader(url: url) else { return nil }
        let key = key(url, reader)
        return cache.withLock { c in c.first { $0.key == key }?.parse }
    }

    /// The parse of `p` over other bytes: an open file for a cached parse, or no file for the cache.
    private init(parse p: MXFFile, bytes: MXFBytes) {
        url = p.url; self.bytes = bytes; tracks = p.tracks; timecode = p.timecode; runIn = p.runIn
        partitionCount = p.partitionCount; usesIndexTable = p.usesIndexTable; unitOffsets = p.unitOffsets
        temporalOffsets = p.temporalOffsets; flags = p.flags; shared = p.shared
    }

    public convenience init(url: URL) throws {
        // Positional reads, no memory map: MXF comes from camera cards, and a pulled card or a file replaced while
        // it is copied must end in a thrown error, where touching a mapped page would raise SIGBUS.
        guard let reader = MXFFileReader(url: url) else { throw MediaError.unreadable }
        try self.init(bytes: MXFBytes(reader), url: url)
    }

    public convenience init(data: Data, url: URL = URL(fileURLWithPath: "/dev/null")) throws {
        try self.init(bytes: MXFBytes(data), url: url)
    }

    init(bytes r: MXFBytes, url: URL) throws {
        self.url = url
        bytes = r
        shared = Shared()
        guard r.count >= 64, let header = Self.headerOffset(r, limit: 65_536) else { throw MediaError.unreadable }
        runIn = header
        var parts = Self.partitions(r, header: header)
        guard !parts.isEmpty else { throw MediaError.unreadable }
        var segments: [MXFIndexSegment] = []
        Self.walk(&parts, r, segments: &segments)
        partitionCount = parts.count

        // Metadata: the header partition's, unless it is open or has no durations and the footer repeats it.
        var meta = parts.first?.metadata.map { MXFMetadata.parse(r, region: $0) } ?? MXFMetadata()
        let unfinished = parts[0].isOpen || meta.tracks.isEmpty || meta.tracks.contains { $0.duration < 0 }
        if unfinished, let last = parts.dropFirst().last(where: { $0.metadata != nil }), let region = last.metadata {
            let m = MXFMetadata.parse(r, region: region)
            if !m.tracks.isEmpty { meta = m }
        }
        tracks = meta.tracks
        timecode = meta.timecode
        guard !tracks.isEmpty else { throw MediaError.unreadable }

        if let t = Self.unitsFromIndex(r, parts: parts, segments: segments, tracks: tracks) {
            unitOffsets = t.offsets; temporalOffsets = t.temporal; flags = t.flags
            usesIndexTable = true
        } else {
            let offsets = Self.scan(r, from: header)
            unitOffsets = offsets
            // Index entries stay useful when they cover what the scan found (a complete index, broken offsets).
            let table = Self.table(segments)
            if let table, table.cbr == 0, table.temporal.count >= offsets.count, !offsets.isEmpty {
                temporalOffsets = Array(table.temporal.prefix(offsets.count)); flags = Array(table.flags.prefix(offsets.count))
            } else {
                temporalOffsets = []; flags = []
            }
            usesIndexTable = false
        }
    }

    // MARK: partitions

    static func partition(_ r: MXFBytes, at o: Int, runIn: Int) -> MXFPartition? {
        guard let k = r.klv(at: o), let kind = k.key.partitionKind, k.length >= 64, r.fits(k) else { return nil }
        let v = k.valueOffset
        var p = MXFPartition()
        p.offset = o; p.kind = kind; p.packEnd = k.end
        p.isOpen = k.key.byte(14) == 1 || k.key.byte(14) == 3
        guard let prev = r.position(v + 16), let foot = r.position(v + 24), let hbc = r.position(v + 32),
              let ibc = r.position(v + 40), let isid = r.u32(v + 48), let bo = r.u64(v + 52), let bsid = r.u32(v + 60) else { return nil }
        p.previous = prev > 0 ? runIn &+ prev : 0
        p.footer = foot > 0 ? runIn &+ foot : 0
        p.headerByteCount = hbc; p.indexByteCount = ibc; p.indexSID = isid; p.bodyOffset = bo; p.bodySID = bsid
        return p
    }

    /// Partition packs by the random index pack, the footer's previous-partition chain, and (in `walk`) by meeting them.
    private static func partitions(_ r: MXFBytes, header: Int) -> [MXFPartition] {
        var offsets: Set<Int> = [header]
        if let total = r.u32(r.count - 4), total >= 33, Int(total) <= r.count - header {
            let o = r.count - Int(total)
            if let k = r.klv(at: o), k.key.isRandomIndexPack, r.fits(k) {
                var p = k.valueOffset
                while p + 12 <= k.end - 4, offsets.count < 100_000, let off = r.position(p + 4) {
                    if off < r.count - header { offsets.insert(header + off) }
                    p += 12
                }
            }
        }
        if let hp = partition(r, at: header, runIn: header), hp.footer > header {
            var o = hp.footer, n = 0
            while o > header, n < 100_000, let p = partition(r, at: o, runIn: header) {
                offsets.insert(o); n += 1
                guard p.previous > header, p.previous < o else { break }
                o = p.previous
            }
        }
        return offsets.sorted().compactMap { partition(r, at: $0, runIn: header) }
    }

    /// Walks what follows each partition pack up to its essence: metadata region, index segments, essence start.
    /// Partitions met on the way that nothing pointed to are added.
    private static func walk(_ parts: inout [MXFPartition], _ r: MXFBytes, segments: inout [MXFIndexSegment]) {
        var i = 0
        var known = Set(parts.map(\.offset))
        let runIn = parts[0].offset
        while i < parts.count, parts.count < 100_000 {
            var p = parts[i].packEnd, steps = 0
            var metaStart: Int?, metaEnd = 0
            while steps < 2_000_000, let k = r.klv(at: p) {
                steps += 1
                let key = k.key
                if key.isPartitionPack {
                    if !known.contains(p), let np = partition(r, at: p, runIn: runIn) {
                        known.insert(p); parts.append(np); parts.sort { $0.offset < $1.offset }
                    }
                    break
                }
                if key.isRandomIndexPack { break }
                if key.isEssenceElement || key.isSystemItem { parts[i].essenceStart = p; break }
                guard r.fits(k), k.end > p else { break }
                if key.isIndexSegment {
                    if let s = MXFIndexSegment(r, k) { segments.append(s) }
                } else if key.isPrimer || key.metadataSetKind != nil {
                    if metaStart == nil { metaStart = p }
                    metaEnd = k.end
                }
                p = k.end
            }
            if let metaStart { parts[i].metadata = metaStart..<metaEnd }
            i += 1
        }
        for i in parts.indices {
            parts[i].essenceEnd = i + 1 < parts.count ? parts[i + 1].offset : r.count
            // Essence that starts past the next partition pack (a corrupt length before it) cannot be placed.
            if let s = parts[i].essenceStart, s >= parts[i].essenceEnd { parts[i].essenceStart = nil }
        }
    }

    // MARK: edit units

    private struct Table { var offsets: [UInt64] = []; var temporal: [Int8] = []; var flags: [UInt8] = []; var cbr = 0; var duration: Int64 = 0; var bodySID: UInt32 = 0 }

    /// The segments joined into one table in edit unit order; nil when there is no usable index.
    private static func table(_ segments: [MXFIndexSegment]) -> Table? {
        // Index tables are often repeated (footer and body): for one start position keep the longest segment.
        var byStart: [Int64: MXFIndexSegment] = [:]
        for s in segments where !s.streamOffsets.isEmpty {
            if let old = byStart[s.startPosition], old.streamOffsets.count >= s.streamOffsets.count { continue }
            byStart[s.startPosition] = s
        }
        var t = Table()
        if byStart.isEmpty {
            guard let cbr = segments.first(where: { $0.editUnitByteCount > 0 }) else { return nil }
            t.cbr = cbr.editUnitByteCount; t.duration = cbr.duration; t.bodySID = cbr.bodySID
            return t
        }
        for start in byStart.keys.sorted() {
            guard let s = byStart[start] else { continue }
            let have = Int64(t.offsets.count)
            guard start <= have else { break }                 // a gap: what follows cannot be placed
            let skip = Int(have - start)
            guard skip < s.streamOffsets.count else { continue }
            t.offsets += s.streamOffsets[skip...]; t.temporal += s.temporalOffsets[skip...]; t.flags += s.flags[skip...]
            t.bodySID = s.bodySID
        }
        return t.offsets.isEmpty ? nil : t
    }

    /// Edit unit file offsets by index table arithmetic (no essence is read), checked against a few real positions.
    static func unitsFromIndex(_ r: MXFBytes, parts: [MXFPartition], segments: [MXFIndexSegment],
                                       tracks: [MXFTrack]) -> (offsets: [Int], temporal: [Int8], flags: [UInt8])? {
        guard let t = table(segments) else { return nil }
        let wanted = t.bodySID
        // A partition whose essence starts past its end makes every offset behind it wrong: the scan takes over.
        guard !parts.contains(where: { p in p.essenceStart.map { $0 < 0 || $0 >= p.essenceEnd } ?? false }) else { return nil }
        var bodies = parts.filter { $0.essenceStart != nil && (wanted == 0 || $0.bodySID == wanted) }
        if bodies.isEmpty { bodies = parts.filter { $0.essenceStart != nil } }
        guard !bodies.isEmpty else { return nil }
        bodies.sort { $0.bodyOffset < $1.bodyOffset }
        var bi = 0
        func fileOffset(_ s: UInt64) -> Int? {
            if bodies[bi].bodyOffset > s { bi = 0 }
            while bi + 1 < bodies.count, bodies[bi + 1].bodyOffset <= s { bi += 1 }
            let b = bodies[bi]
            guard s >= b.bodyOffset, let start = b.essenceStart, b.essenceEnd > start,
                  s - b.bodyOffset < UInt64(b.essenceEnd - start) else { return nil }
            return start + Int(s - b.bodyOffset)
        }
        var offsets: [Int] = []
        if t.cbr > 0 {
            let total = bodies.reduce(0) { $0 + max(0, $1.essenceEnd - ($1.essenceStart ?? $1.essenceEnd)) }
            var count = t.duration > 0 ? t.duration : tracks.map(\.duration).max() ?? -1
            if count <= 0 { count = Int64(total / t.cbr) }
            count = max(0, min(count, Int64(total / t.cbr) + 1, 50_000_000))
            // The first two units must be content packages before the table is filled: clip-wrapped sound with a
            // constant byte count would otherwise give millions of offsets inside one element.
            for i in 0..<min(2, Int(count)) {
                guard let o = fileOffset(UInt64(i) * UInt64(t.cbr)), let k = r.klv(at: o),
                      k.key.isEssenceElement || k.key.isSystemItem, r.fits(k) else { return nil }
            }
            offsets.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                guard let o = fileOffset(UInt64(i) * UInt64(t.cbr)) else { break }
                offsets.append(o)
            }
        } else {
            offsets.reserveCapacity(t.offsets.count)
            for s in t.offsets {
                guard let o = fileOffset(s) else { return nil }
                offsets.append(o)
            }
        }
        guard !offsets.isEmpty else { return nil }
        // The index must land on content packages: first, second, middle and last unit.
        for i in Set([0, min(1, offsets.count - 1), offsets.count / 2, offsets.count - 1]) {
            guard let k = r.klv(at: offsets[i]), k.key.isEssenceElement || k.key.isSystemItem, r.fits(k) else { return nil }
        }
        return (offsets, t.cbr > 0 ? [] : t.temporal, t.cbr > 0 ? [] : t.flags)
    }

    /// Finds the content packages by walking every KLV: for files without a usable index.
    private static func scan(_ r: MXFBytes, from start: Int) -> [Int] {
        var offsets: [Int] = []
        var seen: [UInt32] = []
        var unit: Int?
        var hasPicture = false, anyPicture = false
        func close() {
            if let u = unit, !seen.isEmpty { offsets.append(u) }
            unit = nil; seen.removeAll(keepingCapacity: true); hasPicture = false
        }
        var p = start
        while let k = r.klv(at: p), k.end > p {
            let key = k.key
            if key.isSystemItem {
                if unit == nil || !seen.isEmpty { close(); unit = p }
            } else if key.isEssenceElement {
                guard r.fits(k) else { break }            // cut off inside this element: the unit is incomplete
                let n = key.trackNumber
                if unit == nil || seen.contains(n) { close(); unit = p }
                seen.append(n)
                let item = UInt8(n >> 24)
                if item == 0x05 || item == 0x15 { hasPicture = true; anyPicture = true }
            } else if key.isPartitionPack || key.isRandomIndexPack {
                close()
            }
            guard r.fits(k) else { break }
            p = k.end
        }
        // The last unit counts when nothing of it is missing as far as one can tell.
        if !anyPicture || hasPicture { close() }
        return offsets
    }

    // MARK: essence access

    struct Element { var track: UInt32; var range: Range<Int> }

    /// The essence elements of edit unit `u` (walked on demand).
    func elements(ofUnit u: Int) -> [Element] {
        guard u >= 0, u < unitOffsets.count else { return [] }
        let start = unitOffsets[u]
        let limit = u + 1 < unitOffsets.count && unitOffsets[u + 1] > start ? unitOffsets[u + 1] : bytes.count
        var out: [Element] = []
        var p = start
        while p < limit, out.count < 256, let k = bytes.klv(at: p), k.end > p {
            let key = k.key
            if key.isSystemItem {
                if !out.isEmpty { break }
            } else if key.isEssenceElement {
                let n = key.trackNumber
                // An element ends before the next edit unit: a corrupt length must not make a reader allocate and
                // read up to the end of the file.
                guard bytes.fits(k), k.end <= limit, !out.contains(where: { $0.track == n }) else { break }
                out.append(Element(track: n, range: k.valueOffset..<k.end))
            } else if !key.isFill {
                break
            }
            guard bytes.fits(k) else { break }
            p = k.end
        }
        return out
    }

    /// The picture element of edit unit `u`.
    func pictureRange(ofUnit u: Int) -> Range<Int>? {
        let all = elements(ofUnit: u).filter { let t = UInt8($0.track >> 24); return t == 0x05 || t == 0x15 }
        if let n = videoTrack?.number, n != 0, let e = all.first(where: { $0.track == n }) { return e.range }
        return all.first?.range
    }

    public var videoCodec: MXFVideoCodec? {
        guard let p = videoTrack?.picture else { return videoTrack == nil ? nil : MXFVideoCodec.identify(coding: nil, container: nil) }
        return MXFVideoCodec.identify(coding: p.coding, container: p.container)
    }
}
