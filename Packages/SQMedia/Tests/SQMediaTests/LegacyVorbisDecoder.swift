import Accelerate
import Foundation

/// Frozen copy of `VorbisDecoder` before the 2026-10-04 speed-up (differential reference for tests only).
/// Vorbis I decoder (Xiph's public specification, https://xiph.org/vorbis/doc/Vorbis_I_spec.html), written for
/// this project from the spec text. Floor type 1 and residue types 0, 1 and 2 (everything libvorbis encoders write).
/// One instance decodes one stream, packet after packet (not thread safe).
final class LegacyVorbisDecoder {
    public enum Failure: Error { case badHeader, unsupported(String), badPacket }

    public private(set) var channels = 0
    public private(set) var sampleRate = 0

    // MARK: setup data

    private struct Codebook {
        var dimensions = 0, entries = 0
        /// Huffman trie: node i has children child[2i], child[2i+1]; value > 0 = node index, value <= 0 = leaf -(entry).
        var trie: [Int32] = []
        /// entries * dimensions decoded vector values (lookup types 1 and 2), empty without lookup.
        var vectors: [Float] = []
        var hasLookup: Bool { !vectors.isEmpty }
    }
    private struct Floor1 {
        var partitionClass: [Int] = []
        var classDimensions: [Int] = [], classSubclasses: [Int] = [], masterbooks: [Int] = []
        var subclassBooks: [[Int]] = []
        var multiplier = 1, rangeBits = 0
        var x: [Int] = []
        var sortedOrder: [Int] = []
        var lowNeighbor: [Int] = [], highNeighbor: [Int] = []
    }
    private struct Residue {
        var type = 0, begin = 0, end = 0, partitionSize = 1, classifications = 1, classbook = 0
        var books: [[Int]] = []
    }
    private struct Mapping {
        var couplingMagnitude: [Int] = [], couplingAngle: [Int] = []
        var mux: [Int] = []
        var submapFloor: [Int] = [], submapResidue: [Int] = []
    }
    private struct Mode { var blockflag = false, mapping = 0 }

    private var codebooks: [Codebook] = []
    private var floors: [Floor1] = []
    private var residues: [Residue] = []
    private var mappings: [Mapping] = []
    private var modes: [Mode] = []
    private var blocksize = [0, 0]

    // MARK: running state

    private var tail: [[Float]] = []
    private var prevN = 0
    private var started = false
    private var windows: [Int: [Float]] = [:]
    private var dct: [Int: vDSP.DCT] = [:]

    private static let floorTable: [Float] = (0..<256).map { Float(pow(10.0, Double($0 - 255) * 0.546875 / 20.0)) }

    /// `codecPrivate` is the Matroska CodecPrivate: Xiph-laced identification, comment and setup headers.
    public init(codecPrivate: Data) throws {
        let b = [UInt8](codecPrivate)
        guard b.count > 3, b[0] == 2 else { throw Failure.badHeader }
        var pos = 1
        var sizes: [Int] = []
        for _ in 0..<2 {
            var s = 0
            while pos < b.count { let x = Int(b[pos]); pos += 1; s += x; if x != 255 { break } }
            sizes.append(s)
        }
        guard pos + sizes[0] + sizes[1] < b.count else { throw Failure.badHeader }
        let ident = Array(b[pos..<(pos + sizes[0])])
        let setup = Array(b[(pos + sizes[0] + sizes[1])...])
        try parseIdentification(ident)
        try parseSetup(setup)
        tail = Array(repeating: [], count: channels)
    }

    // MARK: header parsing

    private struct Bits {
        let d: [UInt8]
        var pos = 0
        var eop = false
        init(_ d: [UInt8]) { self.d = d }
        mutating func read(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            var v = 0
            var got = 0
            while got < n {
                let byte = pos >> 3
                if byte >= d.count { eop = true; return v }
                let off = pos & 7
                let take = min(8 - off, n - got)
                v |= Int((d[byte] >> UInt8(off)) & UInt8((1 << take) - 1)) << got
                got += take; pos += take
            }
            return v
        }
        mutating func bit() -> Int { read(1) }
    }

    private static func ilog(_ x: Int) -> Int { x <= 0 ? 0 : Int.bitWidth - x.leadingZeroBitCount }

    private func parseIdentification(_ p: [UInt8]) throws {
        guard p.count >= 30, p[0] == 1, p[1...6].elementsEqual("vorbis".utf8) else { throw Failure.badHeader }
        func u32(_ i: Int) -> Int { Int(p[i]) | Int(p[i + 1]) << 8 | Int(p[i + 2]) << 16 | Int(p[i + 3]) << 24 }
        guard u32(7) == 0 else { throw Failure.unsupported("version") }
        channels = Int(p[11]); sampleRate = u32(12)
        blocksize = [1 << Int(p[28] & 15), 1 << Int(p[28] >> 4)]
        guard channels > 0, sampleRate > 0, blocksize[0] >= 64, blocksize[1] >= blocksize[0], blocksize[1] <= 8192 else { throw Failure.badHeader }
    }

    private static func float32Unpack(_ x: Int) -> Float {
        let mantissa = Double(x & 0x1FFFFF)
        let sign = x & 0x8000_0000 != 0
        let exponent = Double((x & 0x7FE0_0000) >> 21)
        return Float((sign ? -mantissa : mantissa) * pow(2.0, exponent - 788))
    }

    private func parseSetup(_ p: [UInt8]) throws {
        guard p.count > 7, p[0] == 5, p[1...6].elementsEqual("vorbis".utf8) else { throw Failure.badHeader }
        var r = Bits(Array(p[7...]))
        // codebooks
        let nBooks = r.read(8) + 1
        for _ in 0..<nBooks { codebooks.append(try parseCodebook(&r)) }
        // time domain transforms (placeholders)
        let nTimes = r.read(6) + 1
        for _ in 0..<nTimes { guard r.read(16) == 0 else { throw Failure.badHeader } }
        // floors
        let nFloors = r.read(6) + 1
        for _ in 0..<nFloors {
            guard r.read(16) == 1 else { throw Failure.unsupported("floor type 0") }
            floors.append(try parseFloor1(&r))
        }
        // residues
        let nRes = r.read(6) + 1
        for _ in 0..<nRes {
            var res = Residue()
            res.type = r.read(16)
            guard res.type <= 2 else { throw Failure.badHeader }
            res.begin = r.read(24); res.end = r.read(24)
            res.partitionSize = r.read(24) + 1
            res.classifications = r.read(6) + 1
            res.classbook = r.read(8)
            guard res.classbook < codebooks.count else { throw Failure.badHeader }
            var cascade: [Int] = []
            for _ in 0..<res.classifications {
                let low = r.read(3)
                let high = r.bit() == 1 ? r.read(5) : 0
                cascade.append(high << 3 | low)
            }
            for c in cascade {
                var row = [Int](repeating: -1, count: 8)
                for j in 0..<8 where c & (1 << j) != 0 {
                    row[j] = r.read(8)
                    guard row[j] < codebooks.count else { throw Failure.badHeader }
                }
                res.books.append(row)
            }
            residues.append(res)
        }
        // mappings
        let nMaps = r.read(6) + 1
        for _ in 0..<nMaps {
            guard r.read(16) == 0 else { throw Failure.unsupported("mapping type") }
            var m = Mapping()
            let submaps = r.bit() == 1 ? r.read(4) + 1 : 1
            if r.bit() == 1 {
                let steps = r.read(8) + 1
                let bits = Self.ilog(channels - 1)
                for _ in 0..<steps {
                    let mag = r.read(bits), ang = r.read(bits)
                    guard mag != ang, mag < channels, ang < channels else { throw Failure.badHeader }
                    m.couplingMagnitude.append(mag); m.couplingAngle.append(ang)
                }
            }
            guard r.read(2) == 0 else { throw Failure.badHeader }
            if submaps > 1 {
                for _ in 0..<channels { let x = r.read(4); guard x < submaps else { throw Failure.badHeader }; m.mux.append(x) }
            } else { m.mux = Array(repeating: 0, count: channels) }
            for _ in 0..<submaps {
                _ = r.read(8)
                let f = r.read(8), rs = r.read(8)
                guard f < floors.count, rs < residues.count else { throw Failure.badHeader }
                m.submapFloor.append(f); m.submapResidue.append(rs)
            }
            mappings.append(m)
        }
        // modes
        let nModes = r.read(6) + 1
        for _ in 0..<nModes {
            var m = Mode()
            m.blockflag = r.bit() == 1
            guard r.read(16) == 0, r.read(16) == 0 else { throw Failure.badHeader }
            m.mapping = r.read(8)
            guard m.mapping < mappings.count else { throw Failure.badHeader }
            modes.append(m)
        }
        guard r.bit() == 1, !r.eop else { throw Failure.badHeader }
    }

    private func parseCodebook(_ r: inout Bits) throws -> Codebook {
        guard r.read(24) == 0x564342 else { throw Failure.badHeader }
        var cb = Codebook()
        cb.dimensions = r.read(16)
        cb.entries = r.read(24)
        guard cb.dimensions > 0, cb.entries > 0 else { throw Failure.badHeader }
        var lengths = [Int](repeating: 0, count: cb.entries)
        if r.bit() == 1 {
            var current = r.read(5) + 1
            var entry = 0
            while entry < cb.entries {
                let n = r.read(Self.ilog(cb.entries - entry))
                guard entry + n <= cb.entries, current <= 32 else { throw Failure.badHeader }
                for i in entry..<(entry + n) { lengths[i] = current }
                entry += n; current += 1
                if r.eop { throw Failure.badHeader }
            }
        } else {
            let sparse = r.bit() == 1
            for i in 0..<cb.entries {
                if sparse { if r.bit() == 1 { lengths[i] = r.read(5) + 1 } } else { lengths[i] = r.read(5) + 1 }
            }
        }
        cb.trie = try Self.buildTrie(lengths)
        let lookupType = r.read(4)
        if lookupType == 1 || lookupType == 2 {
            let minimum = Self.float32Unpack(r.read(32)), delta = Self.float32Unpack(r.read(32))
            let valueBits = r.read(4) + 1
            let sequence = r.bit() == 1
            var lookupValues: Int
            if lookupType == 1 {
                lookupValues = 0
                // greatest integer v with v^dimensions <= entries
                while true {
                    var p = 1, ok = true
                    for _ in 0..<cb.dimensions { p *= (lookupValues + 1); if p > cb.entries { ok = false; break } }
                    if !ok { break }
                    lookupValues += 1
                }
            } else { lookupValues = cb.entries * cb.dimensions }
            var mult = [Int](repeating: 0, count: lookupValues)
            for i in 0..<lookupValues { mult[i] = r.read(valueBits) }
            var table = [Float](repeating: 0, count: cb.entries * cb.dimensions)
            for e in 0..<cb.entries {
                var last: Float = 0
                var div = 1
                for d in 0..<cb.dimensions {
                    let m: Int
                    if lookupType == 1 { m = mult[(e / div) % lookupValues]; div *= lookupValues } else { m = mult[e * cb.dimensions + d] }
                    let v = Float(m) * delta + minimum + last
                    table[e * cb.dimensions + d] = v
                    if sequence { last = v }
                }
            }
            cb.vectors = table
        } else if lookupType != 0 { throw Failure.badHeader }
        guard !r.eop else { throw Failure.badHeader }
        return cb
    }

    /// Canonical Huffman code assignment of the Vorbis spec (first free codeword of the length), as a bit trie.
    private static func buildTrie(_ lengths: [Int]) throws -> [Int32] {
        var trie: [Int32] = [0, 0]      // node 0 = root; children index 0 = unset
        // Spec algorithm with 32-bit left aligned "available" markers.
        var available = [UInt32](repeating: 0, count: 33)
        var first = -1
        for (i, l) in lengths.enumerated() where l > 0 { first = i; break }
        guard first >= 0 else { return trie }   // no used entries: any decode fails
        func insert(_ code: UInt32, _ length: Int, _ entry: Int) throws {
            var node = 0
            for b in 0..<length {
                let bit = Int((code >> UInt32(31 - b)) & 1)
                let slot = node * 2 + bit
                if b == length - 1 {
                    guard trie[slot] == 0 else { throw Failure.badHeader }
                    trie[slot] = Int32(-entry)
                    if entry == 0 { trie[slot] = Int32.min }     // leaf for entry 0 (0 and -0 collide with "unset")
                } else {
                    var n = Int(trie[slot])
                    if n <= 0 {
                        guard trie[slot] == 0 else { throw Failure.badHeader }
                        n = trie.count / 2
                        trie.append(contentsOf: [0, 0])
                        trie[slot] = Int32(n)
                    }
                    node = n
                }
            }
        }
        try insert(0, lengths[first], first)
        for l in 1...lengths[first] { available[l] = 1 << UInt32(32 - l) }
        for i in (first + 1)..<max(first + 1, lengths.count) where lengths[i] > 0 {
            let len = lengths[i]
            var z = len
            while z > 0 && available[z] == 0 { z -= 1 }
            guard z > 0 else { throw Failure.badHeader }
            let res = available[z]
            available[z] = 0
            try insert(res, len, i)
            if z != len { for y in stride(from: len, to: z, by: -1) { available[y] = res &+ (1 << UInt32(32 - y)) } }
        }
        return trie
    }

    private func parseFloor1(_ r: inout Bits) throws -> Floor1 {
        var f = Floor1()
        let partitions = r.read(5)
        for _ in 0..<partitions { f.partitionClass.append(r.read(4)) }
        let maxClass = f.partitionClass.max() ?? -1
        for _ in 0...max(maxClass, 0) where maxClass >= 0 {
            f.classDimensions.append(r.read(3) + 1)
            let sub = r.read(2)
            f.classSubclasses.append(sub)
            f.masterbooks.append(sub != 0 ? r.read(8) : -1)
            var books: [Int] = []
            for _ in 0..<(1 << sub) { books.append(r.read(8) - 1) }
            f.subclassBooks.append(books)
        }
        for b in f.masterbooks + f.subclassBooks.flatMap({ $0 }) where b >= codebooks.count { throw Failure.badHeader }
        f.multiplier = r.read(2) + 1
        f.rangeBits = r.read(4)
        f.x = [0, 1 << f.rangeBits]
        for c in f.partitionClass { for _ in 0..<f.classDimensions[c] { f.x.append(r.read(f.rangeBits)) } }
        guard f.x.count <= 65, !r.eop else { throw Failure.badHeader }
        f.sortedOrder = f.x.indices.sorted { f.x[$0] != f.x[$1] ? f.x[$0] < f.x[$1] : $0 < $1 }
        for i in 0..<f.x.count {
            var lo = 0, hi = 1, loX = -1, hiX = Int.max
            if i >= 2 {
                for j in 0..<i {
                    if f.x[j] < f.x[i] && f.x[j] > loX { lo = j; loX = f.x[j] }
                    if f.x[j] > f.x[i] && f.x[j] < hiX { hi = j; hiX = f.x[j] }
                }
            }
            f.lowNeighbor.append(lo); f.highNeighbor.append(hi)
        }
        return f
    }

    // MARK: packet decoding

    /// Huffman scalar; nil at end of packet.
    private func scalar(_ cb: Codebook, _ r: inout Bits) -> Int? {
        var node = 0
        while true {
            let bit = r.bit()
            if r.eop { return nil }
            let v = cb.trie[node * 2 + bit]
            if v == Int32.min { return 0 }
            if v < 0 { return Int(-v) }
            if v == 0 { return nil }
            node = Int(v)
        }
    }

    private func window(n: Int, prev: Bool, next: Bool) -> [Float] {
        let key = n << 2 | (prev ? 2 : 0) | (next ? 1 : 0)
        if let w = windows[key] { return w }
        let long = n == blocksize[1]
        let bs0 = blocksize[0]
        let leftStart: Int, leftEnd: Int, leftN: Int, rightStart: Int, rightEnd: Int, rightN: Int
        if long && !prev { leftStart = n / 4 - bs0 / 4; leftEnd = n / 4 + bs0 / 4; leftN = bs0 / 2 } else { leftStart = 0; leftEnd = n / 2; leftN = n / 2 }
        if long && !next { rightStart = n * 3 / 4 - bs0 / 4; rightEnd = n * 3 / 4 + bs0 / 4; rightN = bs0 / 2 } else { rightStart = n / 2; rightEnd = n; rightN = n / 2 }
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if i < leftStart { w[i] = 0 }
            else if i < leftEnd {
                let s = sin(Double.pi * (Double(i - leftStart) + 0.5) / Double(2 * leftN))
                w[i] = Float(sin(Double.pi / 2 * s * s))
            } else if i < rightStart { w[i] = 1 }
            else if i < rightEnd {
                let s = sin(Double.pi / 2 + Double.pi * (Double(i - rightStart) + 0.5) / Double(2 * rightN))
                w[i] = Float(sin(Double.pi / 2 * s * s))
            } else { w[i] = 0 }
        }
        windows[key] = w
        return w
    }

    /// Decodes one audio packet. Returns `channels` arrays of equal length (empty for the stream's first packet
    /// and for malformed packets).
    public func decode(_ packet: Data) -> [[Float]] {
        var r = Bits([UInt8](packet))
        guard r.bit() == 0 else { return Array(repeating: [], count: channels) }
        let mode = r.read(Self.ilog(modes.count - 1))
        guard mode < modes.count, !r.eop else { return Array(repeating: [], count: channels) }
        let blockflag = modes[mode].blockflag
        let n = blocksize[blockflag ? 1 : 0]
        var prevFlag = true, nextFlag = true
        if blockflag { prevFlag = r.bit() == 1; nextFlag = r.bit() == 1 }
        let half = n / 2
        let map = mappings[modes[mode].mapping]

        // floors
        var floorCurves = [[Float]?](repeating: nil, count: channels)
        for ch in 0..<channels {
            let fl = floors[map.submapFloor[map.mux[ch]]]
            floorCurves[ch] = decodeFloor(fl, &r, half: half)
        }
        var noResidue = floorCurves.map { $0 == nil }
        // coupling: a pair is decoded when either half is
        for (m, a) in zip(map.couplingMagnitude, map.couplingAngle) where !(noResidue[m] && noResidue[a]) {
            noResidue[m] = false; noResidue[a] = false
        }
        // residue
        var spectrum = [[Float]](repeating: [Float](repeating: 0, count: half), count: channels)
        for (s, resIndex) in map.submapResidue.enumerated() {
            let chans = (0..<channels).filter { map.mux[$0] == s }
            guard !chans.isEmpty else { continue }
            let res = residues[resIndex]
            let skip = chans.map { noResidue[$0] }
            if res.type == 2 {
                guard skip.contains(false) else { continue }
                var interleaved = [Float](repeating: 0, count: half * chans.count)
                decodeResidue(res, &r, vectors: &interleaved, count: 1, length: half * chans.count, skip: [false])
                for (k, ch) in chans.enumerated() { for i in 0..<half { spectrum[ch][i] = interleaved[i * chans.count + k] } }
            } else {
                var flat = [Float](repeating: 0, count: half * chans.count)
                decodeResidue(res, &r, vectors: &flat, count: chans.count, length: half, skip: skip)
                for (k, ch) in chans.enumerated() { for i in 0..<half { spectrum[ch][i] = flat[k * half + i] } }
            }
        }
        // inverse coupling, last step first
        for step in stride(from: map.couplingMagnitude.count - 1, through: 0, by: -1) {
            let mi = map.couplingMagnitude[step], ai = map.couplingAngle[step]
            for j in 0..<half {
                let mm = spectrum[mi][j], aa = spectrum[ai][j]
                var newM: Float, newA: Float
                if mm > 0 {
                    if aa > 0 { newM = mm; newA = mm - aa } else { newA = mm; newM = mm + aa }
                } else {
                    if aa > 0 { newM = mm; newA = mm + aa } else { newA = mm; newM = mm - aa }
                }
                spectrum[mi][j] = newM; spectrum[ai][j] = newA
            }
        }
        // floor * residue, IMDCT, window
        let w = window(n: n, prev: prevFlag, next: nextFlag)
        var block = [[Float]](repeating: [], count: channels)
        for ch in 0..<channels {
            guard let curve = floorCurves[ch] else { block[ch] = [Float](repeating: 0, count: n); continue }
            var spec = spectrum[ch]
            vDSP.multiply(spec, curve, result: &spec)
            var y = imdct(spec, n: n)
            vDSP.multiply(y, w, result: &y)
            block[ch] = y
        }
        // overlap-add
        guard started else {
            started = true; prevN = n
            for ch in 0..<channels { tail[ch] = Array(block[ch][half...]) }
            return Array(repeating: [], count: channels)
        }
        let outLen = prevN / 4 + n / 4
        var out = [[Float]](repeating: [Float](repeating: 0, count: outLen), count: channels)
        let shift = n / 4 - prevN / 4
        for ch in 0..<channels {
            for t in 0..<outLen {
                var v: Float = t < tail[ch].count ? tail[ch][t] : 0
                let k = t + shift
                if k >= 0 && k < n { v += block[ch][k] }
                out[ch][t] = v
            }
            tail[ch] = Array(block[ch][half...])
        }
        prevN = n
        return out
    }

    /// Window size of an audio packet (nil for header or malformed packets). Used to count a stream's samples without decoding.
    public func blockSize(of packet: Data) -> Int? {
        var r = Bits([UInt8](packet.prefix(8)))
        guard r.bit() == 0 else { return nil }
        let mode = r.read(Self.ilog(modes.count - 1))
        guard mode < modes.count, !r.eop else { return nil }
        return blocksize[modes[mode].blockflag ? 1 : 0]
    }

    /// Forget overlap state (after a seek): the next packet is treated as the first.
    public func reset() {
        started = false; prevN = 0
        for i in 0..<channels { tail[i] = [] }
    }

    private func decodeFloor(_ f: Floor1, _ r: inout Bits, half: Int) -> [Float]? {
        guard r.bit() == 1 else { return nil }
        let range = [256, 128, 86, 64][f.multiplier - 1]
        var y = [Int](repeating: 0, count: f.x.count)
        let yBits = Self.ilog(range - 1)
        y[0] = r.read(yBits); y[1] = r.read(yBits)
        var offset = 2
        for cls in f.partitionClass {
            let cdim = f.classDimensions[cls], cbits = f.classSubclasses[cls]
            let csub = (1 << cbits) - 1
            var cval = 0
            if cbits > 0 {
                guard let v = scalar(codebooks[f.masterbooks[cls]], &r) else { return nil }
                cval = v
            }
            for _ in 0..<cdim {
                let book = f.subclassBooks[cls][cval & csub]
                cval >>= cbits
                if book >= 0 {
                    guard let v = scalar(codebooks[book], &r) else { return nil }
                    y[offset] = v
                } else { y[offset] = 0 }
                offset += 1
            }
        }
        if r.eop { return nil }
        // amplitude value synthesis (spec 7.2.4)
        var final = y
        var step2 = [Bool](repeating: false, count: y.count)
        step2[0] = true; step2[1] = true
        for i in 2..<y.count {
            let lo = f.lowNeighbor[i], hi = f.highNeighbor[i]
            let predicted = renderPoint(f.x[lo], final[lo], f.x[hi], final[hi], f.x[i])
            let val = y[i]
            let highroom = range - predicted, lowroom = predicted
            let room = highroom < lowroom ? highroom * 2 : lowroom * 2
            if val != 0 {
                step2[lo] = true; step2[hi] = true; step2[i] = true
                if val >= room {
                    final[i] = highroom > lowroom ? val - lowroom + predicted : predicted - val + highroom - 1
                } else {
                    final[i] = val % 2 == 1 ? predicted - (val + 1) / 2 : predicted + val / 2
                }
            } else {
                step2[i] = false
                final[i] = predicted
            }
        }
        // curve synthesis (spec 7.2.4 step 2)
        var curve = [Float](repeating: 0, count: half)
        let order = f.sortedOrder
        var lx = 0
        var ly = final[order[0]] * f.multiplier
        var hx = 0, hy = ly
        for k in 1..<order.count {
            let idx = order[k]
            guard step2[idx] else { continue }
            hy = final[idx] * f.multiplier
            hx = f.x[idx]
            renderLine(lx, ly, hx, hy, &curve, half)
            lx = hx; ly = hy
        }
        if hx < half { renderLine(hx, hy, half, hy, &curve, half) }
        return curve
    }

    private func renderPoint(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ x: Int) -> Int {
        let dy = y1 - y0, adx = x1 - x0
        let ady = abs(dy)
        let err = ady * (x - x0)
        let off = err / adx
        return dy < 0 ? y0 - off : y0 + off
    }

    /// Bresenham-style line of the spec (7.2.4 render_line), writing `floor[x]` through the inverse dB table.
    private func renderLine(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ out: inout [Float], _ limit: Int) {
        let dy = y1 - y0, adx = x1 - x0
        guard adx > 0 else { return }
        let ady = abs(dy)
        let base = dy / adx
        var x = x0, y = y0, err = 0
        let sy = dy < 0 ? base - 1 : base + 1
        let ady2 = ady - abs(base) * adx
        if x < limit { out[x] = Self.floorTable[max(0, min(255, y))] }
        x += 1
        while x < x1 {
            err += ady2
            if err >= adx { err -= adx; y += sy } else { y += base }
            if x < limit { out[x] = Self.floorTable[max(0, min(255, y))] }
            x += 1
        }
    }

    private func decodeResidue(_ res: Residue, _ r: inout Bits, vectors: inout [Float], count: Int, length: Int, skip: [Bool]) {
        let limitBegin = min(res.begin, length), limitEnd = min(res.end, length)
        let toRead = limitEnd - limitBegin
        guard toRead > 0 else { return }
        let partitions = toRead / res.partitionSize
        guard partitions > 0 else { return }
        let classbook = codebooks[res.classbook]
        let classWords = classbook.dimensions
        var classes = [[Int]](repeating: [Int](repeating: 0, count: partitions + classWords), count: count)
        for pass in 0..<8 {
            var p = 0
            while p < partitions {
                if pass == 0 {
                    for j in 0..<count where !skip[j] {
                        guard var temp = scalar(classbook, &r) else { return }
                        for i in stride(from: classWords - 1, through: 0, by: -1) {
                            classes[j][i + p] = temp % res.classifications
                            temp /= res.classifications
                        }
                    }
                }
                var i = 0
                while i < classWords && p < partitions {
                    for j in 0..<count where !skip[j] {
                        let book = res.books[classes[j][p]][pass]
                        guard book >= 0 else { continue }
                        let cb = codebooks[book]
                        guard cb.hasLookup else { continue }
                        let offset = limitBegin + p * res.partitionSize
                        let base = j * length
                        let dim = cb.dimensions
                        if res.type == 0 {
                            let step = res.partitionSize / dim
                            var s = 0
                            while s < step {
                                guard let e = scalar(cb, &r) else { return }
                                for k in 0..<dim { vectors[base + offset + s + k * step] += cb.vectors[e * dim + k] }
                                s += 1
                            }
                        } else {
                            var s = 0
                            while s < res.partitionSize {
                                guard let e = scalar(cb, &r) else { return }
                                for k in 0..<dim where s + k < res.partitionSize { vectors[base + offset + s + k] += cb.vectors[e * dim + k] }
                                s += dim
                            }
                        }
                    }
                    p += 1; i += 1
                }
            }
        }
    }

    // MARK: IMDCT

    /// y[k] = sum_j X[j] cos(pi/M (k + 1/2 + M/2)(j + 1/2)), M = n/2, via a DCT-IV.
    func imdctForTest(_ x: [Float], n: Int) -> [Float] { imdct(x, n: n) }
    private func imdct(_ x: [Float], n: Int) -> [Float] {
        let m = n / 2
        if dct[m] == nil { dct[m] = vDSP.DCT(count: m, transformType: .IV) }
        let z = dct[m]!.transform(x)
        var y = [Float](repeating: 0, count: n)
        let h = m / 2
        for k in 0..<h { y[k] = z[k + h] }
        for k in h..<(3 * h) { y[k] = -z[3 * h - 1 - k] }
        for k in (3 * h)..<n { y[k] = -z[k - 3 * h] }
        return y
    }

    /// Reference O(n^2) transform for tests.
    static func imdctDirect(_ x: [Float], n: Int) -> [Float] {
        let m = n / 2
        return (0..<n).map { k in
            var s = 0.0
            for j in 0..<m { s += Double(x[j]) * cos(Double.pi / Double(m) * (Double(k) + 0.5 + Double(m) / 2) * (Double(j) + 0.5)) }
            return Float(s)
        }
    }
}
