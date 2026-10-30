import Foundation
import SQCore
import Synchronization

/// One track of a Matroska / WebM file.
public struct WebMTrack: Sendable {
    public enum Kind: Sendable { case video, audio, other }
    public var number = 0
    public var kind = Kind.other
    public var codecID = ""
    public var codecPrivate = Data()
    /// Video
    public var width = 0, height = 0
    public var matrix: Int?, transfer: Int?, primaries: Int?, range: Int?, bitsPerChannel: Int?
    /// Audio
    public var sampleRate = 0.0, channels = 0, bitDepth = 0
    /// Nanoseconds per frame, 0 = unknown.
    public var defaultDuration: Int64 = 0
    /// Opus: samples (48 kHz) to drop from the start; ns of decoder pre-roll.
    public var codecDelayNs: Int64 = 0, seekPreRollNs: Int64 = 0
    /// The track's blocks are compressed or encrypted (ContentEncodings): not readable here.
    public var hasContentEncoding = false
}

/// One frame (a laced block yields one entry per frame) of a track, located in the file.
public struct WebMBlock: Sendable {
    public var track: Int32
    public var isKey: Bool
    /// Absolute time in `WebMFile.timecodeScale` units.
    public var ticks: Int64
    /// BlockDuration in ticks, nil when the block has none.
    public var durationTicks: Int64?
    public var offset: Int64
    public var size: Int32
}

/// Structure of a Matroska / WebM file: tracks and the location of every frame. The payload stays in the file
/// (memory mapped); `WebMFile` is parsed once per file and cached.
public final class WebMFile: @unchecked Sendable {
    public let url: URL
    /// Nanoseconds per tick (default 1 000 000 = 1 ms).
    public let timecodeScale: Int64
    public let tracks: [WebMTrack]
    /// All blocks in file order.
    public let blocks: [WebMBlock]
    /// Segment duration in seconds, from the Info element.
    public let infoDuration: Double?
    private let data: Data

    public func track(_ kind: WebMTrack.Kind) -> WebMTrack? { tracks.first { $0.kind == kind } }
    public func blocks(of track: Int) -> [WebMBlock] { blocks.filter { Int($0.track) == track } }

    /// Time of `ticks` as a rational.
    public func time(_ ticks: Int64) -> Time {
        let nsPerSecond: Int64 = 1_000_000_000
        if nsPerSecond % timecodeScale == 0 { return Time(ticks, nsPerSecond / timecodeScale) }
        return Time(ticks * timecodeScale, nsPerSecond)
    }

    public func payload(_ b: WebMBlock) -> Data {
        let o = Int(b.offset)
        return data.subdata(in: (data.startIndex + o)..<(data.startIndex + o + Int(b.size)))
    }

    /// True when the file starts with the EBML magic.
    public static func isWebM(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 4), d.count == 4 else { return false }
        return Array(d) == [0x1A, 0x45, 0xDF, 0xA3]
    }

    // MARK: cache

    /// Most recently opened files (a few, parsed structure only; the payload is memory mapped).
    private static let cache = Mutex<[(key: String, file: WebMFile)]>([])
    public static func open(_ url: URL) throws -> WebMFile {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let key = "\(url.path)|\((attrs?[.size] as? NSNumber)?.int64Value ?? 0)|\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let f = cache.withLock({ $0.first { $0.key == key }?.file }) { return f }
        let f = try WebMFile(url: url)
        cache.withLock { c in c.append((key, f)); if c.count > 6 { c.removeFirst() } }
        return f
    }

    // MARK: parsing

    public init(url: URL) throws {
        self.url = url
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count > 16 else { throw MediaError.unreadable }
        data = d
        var p = Parser(data: d)
        try p.parse()
        guard !p.tracks.isEmpty else { throw MediaError.unreadable }
        timecodeScale = p.timecodeScale
        tracks = p.tracks
        blocks = p.blocks
        infoDuration = p.duration
    }

    struct Parser {
        let data: Data
        var timecodeScale: Int64 = 1_000_000
        var duration: Double?
        var tracks: [WebMTrack] = []
        var blocks: [WebMBlock] = []
        var clusterTime: Int64 = 0

        init(data: Data) { self.data = data }

        static let unknown: UInt64 = .max

        func byte(_ i: Int) -> UInt8 { data[data.startIndex + i] }

        /// EBML element ID (marker bits kept) at `i`; nil when invalid or out of range.
        func readID(_ i: Int) -> (id: UInt32, len: Int)? {
            guard i < data.count else { return nil }
            let b = byte(i)
            let n = b.leadingZeroBitCount + 1
            guard n <= 4, i + n <= data.count else { return nil }
            var v = UInt32(0)
            for k in 0..<n { v = v << 8 | UInt32(byte(i + k)) }
            return (v, n)
        }

        /// EBML variable-size integer (marker removed); all-ones = unknown size.
        func readVint(_ i: Int) -> (value: UInt64, len: Int)? {
            guard i < data.count else { return nil }
            let b = byte(i)
            guard b != 0 else { return nil }
            let n = b.leadingZeroBitCount + 1
            guard i + n <= data.count else { return nil }
            var v = UInt64(b) & (0xFF >> UInt64(n))
            var allOnes = v == (0xFF >> UInt64(n))
            for k in 1..<max(1, n) {
                let x = byte(i + k)
                if x != 0xFF { allOnes = false }
                v = v << 8 | UInt64(x)
            }
            return (allOnes ? Parser.unknown : v, n)
        }

        func uint(_ at: Int, _ size: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<min(size, 8) { v = v << 8 | UInt64(byte(at + k)) }
            return v
        }

        func float(_ at: Int, _ size: Int) -> Double? {
            if size == 4 { return Double(Float(bitPattern: UInt32(uint(at, 4)))) }
            if size == 8 { return Double(bitPattern: uint(at, 8)) }
            return nil
        }

        mutating func parse() throws {
            // Top level: the EBML header, then the Segment. Segment and Cluster are walked flat (their size may be
            // unknown in live recordings); other masters are read with their known size.
            var i = 0
            let end = data.count
            while i < end {
                guard let (id, il) = readID(i), let (size, sl) = readVint(i + il) else { break }
                let body = i + il + sl
                switch id {
                case 0x18538067, 0x1F43B675:       // Segment, Cluster: enter
                    i = body
                case 0x1549A966:                    // Info
                    parseInfo(body, body + Int(size)); i = body + Int(size)
                case 0x1654AE6B:                    // Tracks
                    parseTracks(body, min(end, body + Int(size))); i = body + Int(size)
                case 0xE7:                          // cluster Timecode
                    clusterTime = Int64(bitPattern: uint(body, Int(size))); i = body + Int(size)
                case 0xA3:                          // SimpleBlock
                    addBlock(body, Int(size), key: nil, duration: nil); i = body + Int(size)
                case 0xA0:                          // BlockGroup
                    parseGroup(body, min(end, body + Int(size))); i = body + Int(size)
                default:
                    guard size != Parser.unknown else { return }
                    i = body + Int(size)
                }
            }
        }

        mutating func parseInfo(_ start: Int, _ end: Int) {
            var i = start
            var dur: Double?
            while i < end, let (id, il) = readID(i), let (size, sl) = readVint(i + il), size != Parser.unknown {
                let body = i + il + sl, n = Int(size)
                if id == 0x2AD7B1 { timecodeScale = max(1, Int64(uint(body, n))) }
                else if id == 0x4489 { dur = float(body, n) }
                i = body + n
            }
            if let dur { duration = dur * Double(timecodeScale) / 1_000_000_000 }
        }

        mutating func parseTracks(_ start: Int, _ end: Int) {
            var i = start
            while i < end, let (id, il) = readID(i), let (size, sl) = readVint(i + il), size != Parser.unknown {
                let body = i + il + sl
                if id == 0xAE { tracks.append(parseTrackEntry(body, min(end, body + Int(size)))) }
                i = body + Int(size)
            }
        }

        func parseTrackEntry(_ start: Int, _ end: Int) -> WebMTrack {
            var t = WebMTrack()
            var i = start
            while i < end, let (id, il) = readID(i), let (size, sl) = readVint(i + il), size != Parser.unknown {
                let body = i + il + sl, n = Int(size)
                switch id {
                case 0xD7: t.number = Int(uint(body, n))
                case 0x83: let k = uint(body, n); t.kind = k == 1 ? .video : k == 2 ? .audio : .other
                case 0x86: t.codecID = String(decoding: (0..<n).map { byte(body + $0) }.prefix { $0 != 0 }, as: UTF8.self)
                case 0x63A2: t.codecPrivate = data.subdata(in: (data.startIndex + body)..<(data.startIndex + body + n))
                case 0x56AA: t.codecDelayNs = Int64(uint(body, n))
                case 0x56BB: t.seekPreRollNs = Int64(uint(body, n))
                case 0x23E383: t.defaultDuration = Int64(uint(body, n))
                case 0x6D80: t.hasContentEncoding = true
                case 0xE0:  // Video
                    var j = body
                    let e = body + n
                    while j < e, let (cid, cl) = readID(j), let (cs, csl) = readVint(j + cl), cs != Parser.unknown {
                        let cb = j + cl + csl, cn = Int(cs)
                        switch cid {
                        case 0xB0: t.width = Int(uint(cb, cn))
                        case 0xBA: t.height = Int(uint(cb, cn))
                        case 0x55B0:
                            var k = cb
                            let ke = cb + cn
                            while k < ke, let (kid, kl) = readID(k), let (ks, ksl) = readVint(k + kl), ks != Parser.unknown {
                                let kb = k + kl + ksl, kn = Int(ks)
                                switch kid {
                                case 0x55B1: t.matrix = Int(uint(kb, kn))
                                case 0x55B2: t.bitsPerChannel = Int(uint(kb, kn))
                                case 0x55B9: t.range = Int(uint(kb, kn))
                                case 0x55BA: t.transfer = Int(uint(kb, kn))
                                case 0x55BB: t.primaries = Int(uint(kb, kn))
                                default: break
                                }
                                k = kb + kn
                            }
                        default: break
                        }
                        j = cb + cn
                    }
                case 0xE1:  // Audio
                    var j = body
                    let e = body + n
                    while j < e, let (cid, cl) = readID(j), let (cs, csl) = readVint(j + cl), cs != Parser.unknown {
                        let cb = j + cl + csl, cn = Int(cs)
                        switch cid {
                        case 0xB5: t.sampleRate = float(cb, cn) ?? 0
                        case 0x9F: t.channels = Int(uint(cb, cn))
                        case 0x6264: t.bitDepth = Int(uint(cb, cn))
                        default: break
                        }
                        j = cb + cn
                    }
                default: break
                }
                i = body + n
            }
            return t
        }

        mutating func parseGroup(_ start: Int, _ end: Int) {
            var i = start
            var block: (Int, Int)?
            var dur: Int64?
            var hasRef = false
            while i < end, let (id, il) = readID(i), let (size, sl) = readVint(i + il), size != Parser.unknown {
                let body = i + il + sl, n = Int(size)
                switch id {
                case 0xA1: block = (body, n)
                case 0x9B: dur = Int64(uint(body, n))
                case 0xFB: hasRef = true
                default: break
                }
                i = body + n
            }
            if let block { addBlock(block.0, block.1, key: !hasRef, duration: dur) }
        }

        /// Next EBML-laced frame size: previous size plus the signed delta `raw - bias`. Nil when the value is
        /// unknown, would be negative or overflows (corrupt file).
        static func laceSize(after prev: Int, raw: UInt64, length: Int) -> Int? {
            guard raw != unknown, (1...8).contains(length), let r = Int64(exactly: raw) else { return nil }
            let bias = (Int64(1) << (7 * Int64(length) - 1)) - 1
            let (delta, o1) = r.subtractingReportingOverflow(bias)
            guard !o1 else { return nil }
            let (sum, o2) = Int64(prev).addingReportingOverflow(delta)
            guard !o2, sum >= 0 else { return nil }
            return Int(exactly: sum)
        }

        /// Block header: track vint, int16 timecode, flags, then the (possibly laced) frames.
        mutating func addBlock(_ at: Int, _ size: Int, key: Bool?, duration: Int64?) {
            guard size >= 4, at + size <= data.count, let (track, tl) = readVint(at) else { return }
            let rel = Int16(bitPattern: UInt16(uint(at + tl, 2)))
            let flags = byte(at + tl + 2)
            let isKey = key ?? (flags & 0x80 != 0)
            let lacing = (flags >> 1) & 3
            var pos = at + tl + 3
            let end = at + size
            let ticks = clusterTime + Int64(rel)
            guard lacing != 0 else {
                blocks.append(WebMBlock(track: Int32(truncatingIfNeeded: track), isKey: isKey, ticks: ticks,
                                        durationTicks: duration, offset: Int64(pos), size: Int32(end - pos)))
                return
            }
            guard pos < end else { return }
            let count = Int(byte(pos)) + 1
            pos += 1
            var sizes: [Int] = []
            switch lacing {
            case 1:     // Xiph
                for _ in 0..<(count - 1) {
                    var s = 0
                    while pos < end { let b = Int(byte(pos)); pos += 1; s += b; if b != 255 { break } }
                    sizes.append(s)
                }
            case 3:     // EBML
                guard let (first, fl) = readVint(pos) else { return }
                pos += fl
                guard first != Parser.unknown, let firstSize = Int(exactly: first), firstSize <= end - pos else { return }
                sizes.append(firstSize)
                for _ in 1..<max(1, count - 1) where count > 2 {
                    guard let (raw, l) = readVint(pos), let prev = sizes.last,
                          let next = Parser.laceSize(after: prev, raw: raw, length: l), next <= end - pos else { return }
                    pos += l
                    sizes.append(next)
                }
            default:    // fixed
                let each = (end - pos) / count
                sizes = Array(repeating: each, count: count - 1)
            }
            sizes.append(end - pos - sizes.reduce(0, +))
            for (k, s) in sizes.enumerated() where s > 0 && pos + s <= end {
                // Laced frames have no own timestamp: the caller spaces them with the track's default duration.
                blocks.append(WebMBlock(track: Int32(truncatingIfNeeded: track), isKey: isKey, ticks: ticks + Int64(k),
                                        durationTicks: nil, offset: Int64(pos), size: Int32(s)))
                pos += s
            }
        }
    }
}
