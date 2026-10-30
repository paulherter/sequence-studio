import Foundation
import Synchronization

/// A 16-byte SMPTE universal label: KLV key, instance UID or a label value (coding, color, data definition).
public struct MXFUL: Hashable, Sendable {
    public var hi: UInt64, lo: UInt64

    public init(hi: UInt64, lo: UInt64) { self.hi = hi; self.lo = lo }

    /// From up to 16 bytes (missing bytes are 0).
    public init(_ bytes: [UInt8]) {
        var h: UInt64 = 0, l: UInt64 = 0
        for i in 0..<16 {
            let b = UInt64(i < bytes.count ? bytes[i] : 0)
            if i < 8 { h = h << 8 | b } else { l = l << 8 | b }
        }
        hi = h; lo = l
    }

    /// Byte `i` (0...15).
    @inline(__always) public func byte(_ i: Int) -> UInt8 {
        i < 8 ? UInt8(truncatingIfNeeded: hi >> UInt64(56 - 8 * i)) : UInt8(truncatingIfNeeded: lo >> UInt64(56 - 8 * (i - 8)))
    }

    public var bytes: [UInt8] { (0..<16).map(byte) }

    /// True when bytes `range` equal `expected`.
    func matches(_ expected: [UInt8], at start: Int) -> Bool {
        for (i, b) in expected.enumerated() where byte(start + i) != b { return false }
        return true
    }

    private var isSMPTE: Bool { hi >> 32 == 0x060E_2B34 }

    // MARK: key kinds

    /// Partition pack (ST 377-1 section 7.1): byte 13 is 2 header, 3 body, 4 footer.
    var partitionKind: UInt8? {
        guard isSMPTE, matches([0x02, 0x05, 0x01], at: 4), matches([0x0D, 0x01, 0x02, 0x01, 0x01], at: 8),
              (2...4).contains(byte(13)) else { return nil }
        return byte(13)
    }
    var isPartitionPack: Bool { partitionKind != nil }
    var isPrimer: Bool { isSMPTE && matches([0x02, 0x05, 0x01], at: 4) && matches([0x0D, 0x01, 0x02, 0x01, 0x01, 0x05], at: 8) }
    var isRandomIndexPack: Bool { isSMPTE && matches([0x02, 0x05, 0x01], at: 4) && matches([0x0D, 0x01, 0x02, 0x01, 0x01, 0x11], at: 8) }
    var isIndexSegment: Bool { isSMPTE && byte(4) == 0x02 && matches([0x0D, 0x01, 0x02, 0x01, 0x01, 0x10, 0x01], at: 8) }
    var isFill: Bool { isSMPTE && matches([0x01, 0x01, 0x01], at: 4) && matches([0x03, 0x01, 0x02, 0x10, 0x01, 0x00, 0x00, 0x00], at: 8) }
    /// Generic container essence element (ST 379); also Avid's private container label.
    var isEssenceElement: Bool {
        isSMPTE && matches([0x01, 0x02, 0x01], at: 4)
            && (matches([0x0D, 0x01, 0x03, 0x01], at: 8) || matches([0x0E, 0x04, 0x03, 0x01], at: 8))
    }
    /// System item of a content package (CP 0x04, GC 0x14).
    var isSystemItem: Bool {
        isSMPTE && matches([0x0D, 0x01, 0x03, 0x01], at: 8) && (byte(12) == 0x04 || byte(12) == 0x14)
    }
    /// Bytes 12...15 of an essence element key: item type, element count, element type, element number.
    var trackNumber: UInt32 { UInt32(truncatingIfNeeded: lo) }
    /// Header metadata local set (2-byte tags, 2-byte lengths): the set kind (byte 14), nil for other keys.
    var metadataSetKind: UInt8? {
        guard isSMPTE, byte(4) == 0x02, byte(5) == 0x53, matches([0x0D, 0x01, 0x01, 0x01, 0x01, 0x01], at: 8) else { return nil }
        return byte(14)
    }
}

/// One KLV packet: key, position of the value and its declared length (may reach past the end of a truncated file).
struct MXFKLV: Sendable {
    var key: MXFUL
    var offset: Int
    var valueOffset: Int
    var length: Int
    var end: Int { valueOffset + length }
}

/// Bounds-checked big-endian reader over the file (positional reads) or data in memory. Every accessor returns nil instead of reading
/// outside the data, so malformed lengths can never trap.
struct MXFBytes: @unchecked Sendable {
    private let data: Data?
    /// The open file, nil for data in memory and for a detached parse.
    let reader: MXFFileReader?
    let count: Int
    private let base: Int

    init(_ d: Data) { data = d; reader = nil; count = d.count; base = d.startIndex }
    /// Reads through the file descriptor: a file that goes away (camera card pulled, copy replaced) gives nil
    /// from every accessor, where a memory map would raise SIGBUS.
    init(_ r: MXFFileReader) { data = nil; reader = r; count = r.size; base = 0 }
    /// No backing at all (the cached parse of a file that is not open): every accessor returns nil.
    init(detached count: Int) { data = nil; reader = nil; self.count = count; base = 0 }

    @inline(__always) func u8(_ o: Int) -> UInt8? {
        guard o >= 0, o < count else { return nil }
        if let data { return data[base + o] }
        return uint(o, 1).map { UInt8($0) }
    }

    /// Unsigned big-endian integer of `n` bytes (1...8).
    func uint(_ o: Int, _ n: Int) -> UInt64? {
        guard n >= 1, n <= 8, o >= 0, o <= count - n else { return nil }
        var v: UInt64 = 0
        if let data {
            for i in 0..<n { v = v << 8 | UInt64(data[base + o + i]) }
            return v
        }
        var raw: UInt64 = 0
        guard let reader, withUnsafeMutableBytes(of: &raw, { reader.small(o, n, into: $0.baseAddress!) }) else { return nil }
        withUnsafeBytes(of: &raw) { p in for i in 0..<n { v = v << 8 | UInt64(p[i]) } }
        return v
    }
    func u16(_ o: Int) -> UInt16? { uint(o, 2).map { UInt16($0) } }
    func u32(_ o: Int) -> UInt32? { uint(o, 4).map { UInt32($0) } }
    func u64(_ o: Int) -> UInt64? { uint(o, 8) }
    /// A u64 file position or size as Int; nil when it cannot be a position in any real file.
    func position(_ o: Int) -> Int? {
        guard let v = uint(o, 8), v < UInt64(1) << 56 else { return nil }
        return Int(v)
    }

    func ul(_ o: Int) -> MXFUL? {
        guard let h = uint(o, 8), let l = uint(o + 8, 8) else { return nil }
        return MXFUL(hi: h, lo: l)
    }

    func contains(_ r: Range<Int>) -> Bool { r.lowerBound >= 0 && r.upperBound <= count && r.lowerBound <= r.upperBound }

    /// Copies `r` to `dst`; false when the range is not inside the data or the file cannot be read.
    func copy(_ r: Range<Int>, to dst: UnsafeMutableRawPointer) -> Bool {
        guard contains(r) else { return false }
        guard !r.isEmpty else { return true }
        if let data {
            data.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress! + r.lowerBound, byteCount: r.count) }
            return true
        }
        return reader?.read(r, into: dst) ?? false
    }

    /// Copy of `r`, nil when it is not inside the data.
    func slice(_ r: Range<Int>) -> Data? {
        guard contains(r) else { return nil }
        if let data { return data.subdata(in: (base + r.lowerBound)..<(base + r.upperBound)) }
        guard !r.isEmpty else { return Data() }
        var out = Data(count: r.count)
        return out.withUnsafeMutableBytes({ copy(r, to: $0.baseAddress!) }) ? out : nil
    }

    /// Calls `body` with the bytes of `r`: in place for memory, one read into a scratch buffer for a file.
    /// nil when the range is not inside the data or cannot be read.
    func withBytes<T>(_ r: Range<Int>, _ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T? {
        guard contains(r) else { return nil }
        if let data {
            if r.isEmpty { return try body(UnsafeBufferPointer(start: nil, count: 0)) }
            return try data.withUnsafeBytes { raw -> T in
                let p = raw.bindMemory(to: UInt8.self)
                return try body(UnsafeBufferPointer(rebasing: p[r]))
            }
        }
        guard let reader else { return nil }
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, r.count))
        defer { scratch.deallocate() }
        guard r.isEmpty || reader.read(r, into: scratch) else { return nil }
        return try body(UnsafeBufferPointer(start: scratch, count: r.count))
    }

    /// The KLV packet at `o`: nil when key and length do not fit, or the BER length is malformed (indefinite, more
    /// than 8 bytes, absurd). The value itself may be cut off: check `fits`.
    func klv(at o: Int) -> MXFKLV? {
        guard let key = ul(o), let b = u8(o + 16) else { return nil }
        if b < 0x80 { return MXFKLV(key: key, offset: o, valueOffset: o + 17, length: Int(b)) }
        let n = Int(b & 0x7F)
        guard n >= 1, n <= 8, let v = uint(o + 17, n), v < UInt64(1) << 56 else { return nil }
        return MXFKLV(key: key, offset: o, valueOffset: o + 17 + n, length: Int(v))
    }

    func fits(_ k: MXFKLV) -> Bool { k.end <= count }
}

/// BER length decoding on its own (ST 377-1 section 6.3.4), for tests and small buffers.
enum MXFBER {
    /// (length, bytes used) at the start of `b`; nil when malformed.
    static func decode(_ b: [UInt8]) -> (length: UInt64, size: Int)? {
        guard let first = b.first else { return nil }
        if first < 0x80 { return (UInt64(first), 1) }
        let n = Int(first & 0x7F)
        guard n >= 1, n <= 8, b.count > n else { return nil }
        var v: UInt64 = 0
        for i in 1...n { v = v << 8 | UInt64(b[i]) }
        return (v, n + 1)
    }
}

/// Positional reads of a file (`pread`), with a few small cached windows for the many tiny reads of KLV walking and
/// metadata parsing. Errors and short reads are reported, never raised as a signal.
final class MXFFileReader: @unchecked Sendable {
    let size: Int
    /// Modification date in nanoseconds since 1970.
    let modified: Int64
    private let fd: Int32
    private struct Window { var start = -1; var bytes: [UInt8] = [] }
    private struct Windows { var list = [Window](repeating: Window(), count: 4); var next = 0 }
    private let windows = Mutex(Windows())
    private static let windowSize = 4096

    init?(url: URL) {
        let fd = url.withUnsafeFileSystemRepresentation { $0.map { open($0, O_RDONLY | O_CLOEXEC) } ?? -1 }
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0 else { close(fd); return nil }
        self.fd = fd
        size = Int(st.st_size)
        modified = Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec)
    }

    deinit { close(fd) }

    /// Reads exactly `r`; false on an error or when the file ends early.
    func read(_ r: Range<Int>, into dst: UnsafeMutableRawPointer) -> Bool {
        guard r.lowerBound >= 0, r.upperBound <= size else { return false }
        var done = 0
        while done < r.count {
            let n = pread(fd, dst + done, r.count - done, off_t(r.lowerBound + done))
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            done += n
        }
        return true
    }

    /// A few bytes through the window cache.
    func small(_ o: Int, _ n: Int, into dst: UnsafeMutableRawPointer) -> Bool {
        guard n > 0, o >= 0, o <= size - n else { return false }
        let size = size
        return windows.withLock { w in
            for win in w.list where win.start >= 0 && o >= win.start && o + n <= win.start + win.bytes.count {
                win.bytes.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress! + (o - win.start), byteCount: n) }
                return true
            }
            // Aligned so that a walk forward stays inside; a read across the boundary starts its own window.
            var start = o & ~(Self.windowSize - 1)
            if o + n > start + Self.windowSize { start = o }
            let length = min(Self.windowSize, size - start)
            var bytes = [UInt8](repeating: 0, count: length)
            guard bytes.withUnsafeMutableBytes({ self.read(start..<(start + length), into: $0.baseAddress!) }) else { return false }
            bytes.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress! + (o - start), byteCount: n) }
            w.list[w.next] = Window(start: start, bytes: bytes)
            w.next = (w.next + 1) % w.list.count
            return true
        }
    }
}
