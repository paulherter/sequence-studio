import Foundation

/// H.264 byte stream (Annex B) handling for essence that is not in the length-prefixed MP4 form: XAVC in MXF.
enum H264AnnexB {
    /// True when the buffer begins with a start code (after leading zero bytes).
    static func hasStartCode(_ p: UnsafeBufferPointer<UInt8>) -> Bool {
        var i = 0
        while i < p.count, i < 64, p[i] == 0 { i += 1 }
        return i >= 2 && i < p.count && p[i] == 1
    }

    /// The NAL units of a byte stream: ranges without start codes and without trailing zero bytes.
    static func nalRanges(_ p: UnsafeBufferPointer<UInt8>, limit: Int = .max) -> [Range<Int>] {
        guard let base = p.baseAddress, p.count >= 4 else { return [] }
        var out: [Range<Int>] = []
        var nalStart = -1
        var i = 2
        let n = p.count
        func close(_ end: Int) {
            guard nalStart >= 0 else { return }
            var e = end
            while e > nalStart, p[e - 1] == 0 { e -= 1 }
            if e > nalStart { out.append(nalStart..<e) }
        }
        while i < n, out.count < limit {
            // Start codes end in 0x01: jump from one 0x01 byte to the next.
            guard let hit = memchr(base + i, 1, n - i) else { break }
            let j = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            if p[j - 1] == 0, p[j - 2] == 0 {
                close(j - 2)
                nalStart = j + 1
            }
            i = j + 1
        }
        if out.count < limit { close(n) }
        return out
    }

    /// The NAL units of a length-prefixed buffer (4-byte big-endian sizes); nil when the sizes do not add up.
    static func lengthPrefixedRanges(_ p: UnsafeBufferPointer<UInt8>, limit: Int = .max) -> [Range<Int>]? {
        var out: [Range<Int>] = []
        var i = 0
        while i + 4 <= p.count, out.count < limit {
            let len = Int(p[i]) << 24 | Int(p[i + 1]) << 16 | Int(p[i + 2]) << 8 | Int(p[i + 3])
            guard len > 0, len <= p.count - i - 4 else { return nil }
            out.append((i + 4)..<(i + 4 + len))
            i += 4 + len
        }
        return out.count == limit || i == p.count ? (out.isEmpty ? nil : out) : nil
    }

    /// NAL units of a frame in either form.
    static func nals(_ p: UnsafeBufferPointer<UInt8>, limit: Int = .max) -> [Range<Int>] {
        if hasStartCode(p) { return nalRanges(p, limit: limit) }
        return lengthPrefixedRanges(p, limit: limit) ?? nalRanges(p, limit: limit)
    }

    /// The NAL units VideoToolbox gets: filler data (type 12) and access unit delimiters are dropped, constant-bitrate
    /// intra streams are padded with megabytes of filler. Returns the ranges and the length-prefixed size.
    static func kept(_ p: UnsafeBufferPointer<UInt8>) -> (ranges: [Range<Int>], size: Int) {
        var size = 0
        let ranges = nals(p).filter { r in
            let type = p[r.lowerBound] & 0x1F
            if type == 12 || type == 9 { return false }
            size += 4 + r.count
            return true
        }
        return (ranges, size)
    }

    /// Writes `ranges` of `p` as length-prefixed NAL units (4-byte sizes) to `dst` (`kept(p).size` bytes).
    static func write(_ p: UnsafeBufferPointer<UInt8>, _ ranges: [Range<Int>], to dst: UnsafeMutableRawPointer) {
        guard let base = p.baseAddress else { return }
        var o = 0
        for r in ranges {
            let n = UInt32(truncatingIfNeeded: r.count).bigEndian
            withUnsafeBytes(of: n) { (dst + o).copyMemory(from: $0.baseAddress!, byteCount: 4) }
            (dst + o + 4).copyMemory(from: base + r.lowerBound, byteCount: r.count)
            o += 4 + r.count
        }
    }

    /// The frame as length-prefixed NAL units (4-byte sizes).
    static func lengthPrefixed(_ p: UnsafeBufferPointer<UInt8>) -> Data {
        let k = kept(p)
        guard k.size > 0 else { return Data() }
        var out = Data(count: k.size)
        out.withUnsafeMutableBytes { write(p, k.ranges, to: $0.baseAddress!) }
        return out
    }

    /// First sequence and picture parameter sets of a frame.
    static func parameterSets(_ p: UnsafeBufferPointer<UInt8>) -> (sps: [UInt8], pps: [UInt8])? {
        var sps: [UInt8]?, pps: [UInt8]?
        for r in nals(p, limit: 32) {
            let type = p[r.lowerBound] & 0x1F
            if type == 7, sps == nil { sps = Array(p[r]) }
            if type == 8, pps == nil { pps = Array(p[r]) }
            if type == 1 || type == 5 { break }
        }
        guard let sps, let pps else { return nil }
        return (sps, pps)
    }

    // MARK: bit level (only what picture order needs)

    /// The raw payload of a NAL unit without its header byte: emulation prevention bytes removed.
    static func rbsp(_ nal: UnsafeBufferPointer<UInt8>, maxBytes: Int = .max) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(nal.count, 512))
        var zeros = 0
        var i = 1
        while i < nal.count, out.count < maxBytes {
            let b = nal[i]
            if zeros >= 2, b == 3 { zeros = 0; i += 1; continue }
            zeros = b == 0 ? zeros + 1 : 0
            out.append(b); i += 1
        }
        return out
    }

    struct BitReader {
        let b: [UInt8]
        var pos = 0
        var failed = false
        init(_ b: [UInt8]) { self.b = b }

        mutating func bit() -> UInt32 {
            guard pos < b.count * 8 else { failed = true; return 0 }
            let v = (b[pos >> 3] >> UInt8(7 - (pos & 7))) & 1
            pos += 1
            return UInt32(v)
        }
        mutating func bits(_ n: Int) -> UInt32 {
            var v: UInt32 = 0
            for _ in 0..<max(0, min(n, 32)) { v = v << 1 | bit() }
            return v
        }
        mutating func ue() -> UInt32 {
            var zeros = 0
            while bit() == 0 { zeros += 1; if failed || zeros > 31 { failed = true; return 0 } }
            return zeros == 0 ? 0 : (1 << UInt32(zeros)) - 1 + bits(zeros)
        }
        mutating func se() -> Int32 {
            let k = ue()
            return k & 1 == 1 ? Int32((k + 1) / 2) : -Int32(k / 2)
        }
    }

    struct SPS: Equatable {
        var profile = 0
        var chromaFormat = 1
        var separateColorPlane = false
        var log2MaxFrameNum = 4
        var pocType = 0
        var log2MaxPocLsb = 4
        var frameMbsOnly = true
    }

    /// Parses a sequence parameter set NAL (with header byte) as far as picture order needs.
    static func sps(_ nal: [UInt8]) -> SPS? {
        guard nal.count > 4, nal[0] & 0x1F == 7 else { return nil }
        var r = BitReader(nal.withUnsafeBufferPointer { rbsp($0) })
        var s = SPS()
        s.profile = Int(r.bits(8)); _ = r.bits(16); _ = r.ue()
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(s.profile) {
            s.chromaFormat = Int(r.ue())
            if s.chromaFormat == 3 { s.separateColorPlane = r.bit() == 1 }
            _ = r.ue(); _ = r.ue(); _ = r.bit()
            if r.bit() == 1 {                                     // scaling matrix
                for i in 0..<(s.chromaFormat != 3 ? 8 : 12) where r.bit() == 1 {
                    var last: Int32 = 8, next: Int32 = 8
                    for _ in 0..<(i < 6 ? 16 : 64) {
                        if next != 0 {
                            let delta = r.se()
                            guard delta >= -128, delta <= 127 else { return nil }    // the standard's range
                            next = (last &+ delta &+ 256) % 256
                        }
                        last = next == 0 ? last : next
                        if r.failed { return nil }
                    }
                }
            }
        }
        s.log2MaxFrameNum = Int(r.ue()) + 4
        s.pocType = Int(r.ue())
        if s.pocType == 0 { s.log2MaxPocLsb = Int(r.ue()) + 4 }
        else if s.pocType == 1 {
            _ = r.bit(); _ = r.se(); _ = r.se()
            let n = r.ue()
            guard n <= 255 else { return nil }
            for _ in 0..<n { _ = r.se() }
        }
        _ = r.ue(); _ = r.bit(); _ = r.ue(); _ = r.ue()
        s.frameMbsOnly = r.bit() == 1
        guard !r.failed, s.log2MaxFrameNum <= 16, s.log2MaxPocLsb <= 16, s.pocType <= 2 else { return nil }
        return s
    }

    struct Slice: Equatable {
        var isIDR = false
        var isReference = false
        /// Slice type modulo 5: 0 P, 1 B, 2 I.
        var type = 0
        var pocLsb: Int?
    }

    /// The first slice of a frame: NAL type, reference flag and picture order count (type 0 only).
    static func firstSlice(_ p: UnsafeBufferPointer<UInt8>, sps: SPS?) -> Slice? {
        for range in nals(p, limit: 32) {
            let header = p[range.lowerBound]
            let type = header & 0x1F
            guard type == 1 || type == 5 else { continue }
            var s = Slice()
            s.isIDR = type == 5
            s.isReference = header & 0x60 != 0
            var r = BitReader(rbsp(UnsafeBufferPointer(rebasing: p[range]), maxBytes: 48))
            _ = r.ue()
            s.type = Int(r.ue() % 5)
            _ = r.ue()
            if let sps, !r.failed {
                if sps.separateColorPlane { _ = r.bits(2) }
                _ = r.bits(sps.log2MaxFrameNum)
                if !sps.frameMbsOnly, r.bit() == 1 { _ = r.bit() }
                if s.isIDR { _ = r.ue() }
                if sps.pocType == 0 {
                    let lsb = Int(r.bits(sps.log2MaxPocLsb))
                    if !r.failed { s.pocLsb = lsb }
                }
            }
            return r.failed ? nil : s
        }
        return nil
    }

    /// Display position of each frame (given in decode order) from picture order counts: frames are sorted by count
    /// inside each IDR period. nil when a count is missing (the caller then keeps decode order).
    static func displayOrder(_ slices: [Slice], log2MaxPocLsb: Int) -> [Int]? {
        let maxLsb = 1 << log2MaxPocLsb
        var poc = [Int](repeating: 0, count: slices.count)
        var prevMsb = 0, prevLsb = 0
        for (i, s) in slices.enumerated() {
            guard let lsb = s.pocLsb else { return nil }
            if s.isIDR { prevMsb = 0; prevLsb = 0 }
            var msb = prevMsb
            if lsb < prevLsb, prevLsb - lsb >= maxLsb / 2 { msb += maxLsb }
            else if lsb > prevLsb, lsb - prevLsb > maxLsb / 2 { msb -= maxLsb }
            poc[i] = msb + lsb
            if s.isReference { prevMsb = msb; prevLsb = lsb }
        }
        var display = [Int](repeating: 0, count: slices.count)
        var start = 0
        while start < slices.count {
            var end = start + 1
            while end < slices.count, !slices[end].isIDR { end += 1 }
            let order = (start..<end).sorted { poc[$0] != poc[$1] ? poc[$0] < poc[$1] : $0 < $1 }
            for (rank, frame) in order.enumerated() { display[frame] = start + rank }
            start = end
        }
        return display
    }
}
