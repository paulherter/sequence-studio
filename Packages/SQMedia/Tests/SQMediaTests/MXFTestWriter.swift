import Foundation

/// Builds MXF files in memory for tests (OP1a, frame-wrapped): header partition with metadata, body partitions with
/// content packages, footer with an index table, random index pack. No footage is needed.
struct MXFFixture {
    enum Index { case vbr, cbr, none }

    var runIn = 0
    var editRate = (num: 25, den: 1)
    /// Picture element payloads in stored order.
    var frames: [Data] = []
    /// Index entry fields per edit unit; defaults: 0 and 0x80 (key frame).
    var temporalOffsets: [Int8]?
    var flags: [UInt8]?
    var index = Index.vbr
    /// Entries per index table segment.
    var segmentSize = 1000
    var hasFooter = true
    var hasRIP = true
    var hasSystemItem = true
    /// Body partitions the content packages are spread over; 0 puts the essence into the header partition.
    var bodyPartitions = 1
    var linkedTrackIDs = true

    var coding: [UInt8]? = MXFFixture.avcIntraCoding
    var pictureContainer: [UInt8] = MXFFixture.avcContainer
    var width = 1920, height = 1080
    /// Frame layout of the picture descriptor (0 full frame, 1 separate fields, 3 mixed fields, 4 segmented frame).
    var frameLayout: UInt8 = 0
    var fieldDominance: UInt8?
    var videoLineMap: (Int, Int)?
    var depth = 10, hSub = 2, vSub = 1
    var transfer: [UInt8]? = MXFFixture.label(0x01, 0x02)
    var primaries: [UInt8]? = MXFFixture.label(0x03, 0x03)
    var equations: [UInt8]? = MXFFixture.label(0x02, 0x02)

    /// Mono sound tracks.
    var audioTracks = 0
    var audioBits = 24
    var audioBigEndian = false
    var audioCompression: [UInt8]?
    var audioRate = 48_000
    var samplesPerUnit: [Int] = [1920]
    /// Element type byte of the sound element keys (3 wave, 0x10 D-10 AES3).
    var soundElementType: UInt8 = 0x03

    var timecode: (start: Int64, base: Int, drop: Bool)? = (90_000, 25, false)

    static let avcIntraCoding: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x04, 0x01, 0x02, 0x02, 0x01, 0x32, 0x31, 0x01]
    static let avcLongCoding: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x04, 0x01, 0x02, 0x02, 0x01, 0x31, 0x60, 0x01]
    static let avcContainer: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x10, 0x60, 0x01]
    static let waveContainer: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x02, 0x06, 0x01, 0x00]
    static let bigEndianPCM: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x07, 0x04, 0x02, 0x02, 0x01, 0x7E, 0x00, 0x00, 0x00]
    static let pictureKey: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x15, 0x01, 0x05, 0x00]
    static let systemKey: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x04, 0x01, 0x01, 0x00]
    static let fillKey: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x01, 0x01, 0x02, 0x03, 0x01, 0x02, 0x10, 0x01, 0x00, 0x00, 0x00]
    static let indexKey: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x10, 0x01, 0x00]
    static let op1a: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x01, 0x09, 0x00]

    /// Color label `04 01 01 01 kind value`.
    static func label(_ kind: UInt8, _ value: UInt8) -> [UInt8] {
        [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x04, 0x01, 0x01, 0x01, kind, value, 0x00, 0x00]
    }
    static func coding(_ tail: [UInt8]) -> [UInt8] { [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x0A, 0x04, 0x01, 0x02, 0x02] + tail }
    static func partitionKey(_ kind: UInt8, status: UInt8 = 0x04) -> [UInt8] {
        [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, kind, status, 0x00]
    }
    static func soundKey(count: Int, type: UInt8, number: Int) -> [UInt8] {
        [0x06, 0x0E, 0x2B, 0x34, 0x01, 0x02, 0x01, 0x01, 0x0D, 0x01, 0x03, 0x01, 0x16, UInt8(count), type, UInt8(number)]
    }
    var pictureTrackNumber: UInt32 { 0x1501_0500 }
    func soundTrackNumber(_ i: Int) -> UInt32 { 0x1600_0000 | UInt32(audioTracks) << 16 | UInt32(soundElementType) << 8 | UInt32(i) }

    /// The sample test audio holds: channel `c`, sample `n` (a signed value of `bits` bits).
    static func sample(_ c: Int, _ n: Int, bits: Int = 24) -> Int32 {
        let span = Int64(1) << Int64(bits - 1)
        return Int32((Int64(n) * 7_919 + Int64(c) * 104_729 + 17) % (2 * span - 2) - span + 1)
    }

    // MARK: bytes

    static func be(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> UInt64(8 * (n - 1 - $0))) } }
    static func ber(_ n: Int, long: Int = 4) -> [UInt8] {
        long == 0 && n < 0x80 ? [UInt8(n)] : [0x80 | UInt8(max(long, 1))] + be(UInt64(n), max(long, 1))
    }
    static func klv(_ key: [UInt8], _ value: [UInt8], long: Int = 4) -> [UInt8] { key + ber(value.count, long: long) + value }
    static func item(_ tag: UInt16, _ value: [UInt8]) -> [UInt8] { be(UInt64(tag), 2) + be(UInt64(value.count), 2) + value }
    static func set(_ kind: UInt8, _ items: [[UInt8]]) -> [UInt8] {
        klv([0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01, 0x0D, 0x01, 0x01, 0x01, 0x01, 0x01, kind, 0x00], items.flatMap { $0 })
    }
    static func uid(_ n: Int) -> [UInt8] { [0xAA, 0xBB] + be(UInt64(n), 14) }
    static func refs(_ ids: [Int]) -> [UInt8] { be(UInt64(ids.count), 4) + be(16, 4) + ids.flatMap(uid) }
    static func rational(_ n: Int, _ d: Int) -> [UInt8] { be(UInt64(UInt32(bitPattern: Int32(n))), 4) + be(UInt64(UInt32(bitPattern: Int32(d))), 4) }

    private func metadata() -> [UInt8] {
        typealias F = MXFFixture
        let duration = F.be(UInt64(frames.count), 8)
        let rate = F.rational(editRate.num, editRate.den)
        var sets: [[UInt8]] = []
        var next = 100
        func id() -> Int { next += 1; return next }
        let preface = id(), storage = id(), material = id(), source = id(), multi = id()

        // A track with a sequence holding one component.
        func track(_ trackID: Int, number: UInt32, definition: UInt8, component: (Int) -> [UInt8]) -> Int {
            let t = id(), s = id(), c = id()
            let dd: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01, 0x01, 0x01, 0x03, 0x02, definition == 0 ? 0x01 : 0x02,
                               definition == 0 ? 0x01 : definition, 0x00, 0x00, 0x00]
            sets.append(F.set(0x3B, [F.item(0x3C0A, F.uid(t)), F.item(0x4801, F.be(UInt64(trackID), 4)), F.item(0x4804, F.be(UInt64(number), 4)),
                                     F.item(0x4B01, rate), F.item(0x4B02, F.be(0, 8)), F.item(0x4803, F.uid(s))]))
            sets.append(F.set(0x0F, [F.item(0x3C0A, F.uid(s)), F.item(0x0201, dd), F.item(0x0202, duration), F.item(0x1001, F.refs([c]))]))
            sets.append(component(c))
            return t
        }
        func timecodeTrack(_ trackID: Int) -> Int? {
            guard let tc = timecode else { return nil }
            return track(trackID, number: 0, definition: 0) { c in
                F.set(0x14, [F.item(0x3C0A, F.uid(c)), F.item(0x0202, duration), F.item(0x1501, F.be(UInt64(bitPattern: tc.start), 8)),
                             F.item(0x1502, F.be(UInt64(tc.base), 2)), F.item(0x1503, [tc.drop ? 1 : 0])])
            }
        }
        func clip(_ c: Int) -> [UInt8] { F.set(0x11, [F.item(0x3C0A, F.uid(c)), F.item(0x0202, duration)]) }

        let materialTracks = [timecodeTrack(1)].compactMap { $0 }
        var sourceTracks = [timecodeTrack(1)].compactMap { $0 }
        var descriptors: [Int] = []
        if !frames.isEmpty {
            sourceTracks.append(track(2, number: pictureTrackNumber, definition: 1, component: clip))
            let d = id()
            var items = [F.item(0x3C0A, F.uid(d)), F.item(0x3001, rate), F.item(0x3004, pictureContainer),
                         F.item(0x3202, F.be(UInt64(height), 4)), F.item(0x3203, F.be(UInt64(width), 4)),
                         F.item(0x3208, F.be(UInt64(height), 4)), F.item(0x3209, F.be(UInt64(width), 4)),
                         F.item(0x320C, [frameLayout]), F.item(0x320E, F.rational(16, 9)), F.item(0x3301, F.be(UInt64(depth), 4)),
                         F.item(0x3302, F.be(UInt64(hSub), 4)), F.item(0x3308, F.be(UInt64(vSub), 4))]
            if linkedTrackIDs { items.append(F.item(0x3006, F.be(2, 4))) }
            if let fieldDominance { items.append(F.item(0x3212, [fieldDominance])) }
            if let m = videoLineMap { items.append(F.item(0x320D, F.be(2, 4) + F.be(4, 4) + F.be(UInt64(m.0), 4) + F.be(UInt64(m.1), 4))) }
            if let coding { items.append(F.item(0x3201, coding)) }
            if let transfer { items.append(F.item(0x3210, transfer)) }
            if let primaries { items.append(F.item(0x3219, primaries)) }
            if let equations { items.append(F.item(0x321A, equations)) }
            sets.append(F.set(0x28, items)); descriptors.append(d)
        }
        let bytes = (audioBits + 7) / 8
        for i in 0..<audioTracks {
            sourceTracks.append(track(3 + i, number: soundTrackNumber(i), definition: 2, component: clip))
            let d = id()
            var items = [F.item(0x3C0A, F.uid(d)), F.item(0x3001, rate), F.item(0x3004, F.waveContainer),
                         F.item(0x3D03, F.rational(audioRate, 1)), F.item(0x3D07, F.be(1, 4)), F.item(0x3D01, F.be(UInt64(audioBits), 4)),
                         F.item(0x3D0A, F.be(UInt64(bytes), 2))]
            if linkedTrackIDs { items.append(F.item(0x3006, F.be(UInt64(3 + i), 4))) }
            if let c = audioCompression ?? (audioBigEndian ? F.bigEndianPCM : nil) { items.append(F.item(0x3D06, c)) }
            sets.append(F.set(0x48, items)); descriptors.append(d)
        }
        var out = F.klv(F.partitionKey(0x05, status: 0x01), F.be(1, 4) + F.be(18, 4) + F.be(0x3C0A, 2) + [UInt8](repeating: 0, count: 16))
        out += F.set(0x2F, [F.item(0x3C0A, F.uid(preface)), F.item(0x3B03, F.uid(storage))])
        out += F.set(0x18, [F.item(0x3C0A, F.uid(storage)), F.item(0x1901, F.refs([material, source]))])
        out += F.set(0x36, [F.item(0x3C0A, F.uid(material)), F.item(0x4403, F.refs(materialTracks))])
        out += F.set(0x37, [F.item(0x3C0A, F.uid(source)), F.item(0x4403, F.refs(sourceTracks)), F.item(0x4701, F.uid(multi))])
        out += F.set(0x44, [F.item(0x3C0A, F.uid(multi)), F.item(0x3001, rate), F.item(0x3F01, F.refs(descriptors))])
        out += sets.flatMap { $0 }
        return out
    }

    /// One content package: system item, picture, sound elements, fill.
    func unit(_ u: Int, sampleStart: Int, samples: Int, padTo: Int = 0) -> [UInt8] {
        typealias F = MXFFixture
        var out: [UInt8] = []
        if hasSystemItem { out += F.klv(F.systemKey, [UInt8](repeating: 0x5A, count: 57), long: 0) }
        if u < frames.count { out += F.klv(F.pictureKey, [UInt8](frames[u])) }
        let bytes = (audioBits + 7) / 8
        for c in 0..<audioTracks {
            var pcm = [UInt8](); pcm.reserveCapacity(samples * bytes)
            for n in sampleStart..<(sampleStart + samples) {
                let v = UInt32(bitPattern: F.sample(c, n, bits: audioBits))
                let le = (0..<bytes).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * $0)) }
                pcm += audioBigEndian ? le.reversed() : le
            }
            out += F.klv(F.soundKey(count: audioTracks, type: soundElementType, number: c), pcm)
        }
        let fill = max(padTo - out.count - 20, 37)
        out += F.klv(F.fillKey, [UInt8](repeating: 0, count: fill))
        return out
    }

    func build() -> Data {
        typealias F = MXFFixture
        var out = [UInt8](repeating: 0x11, count: runIn)
        var partitionOffsets: [(sid: UInt32, offset: Int)] = []
        var packs: [Int] = []                       // value offsets of the partition packs, for patching

        func pack(_ kind: UInt8, status: UInt8 = 0x04, headerBytes: Int = 0, indexBytes: Int = 0, indexSID: UInt32 = 0,
                  bodyOffset: Int = 0, bodySID: UInt32 = 0) {
            let here = out.count - runIn
            let previous = partitionOffsets.last?.offset ?? 0
            partitionOffsets.append((bodySID, here))
            var v = F.be(1, 2) + F.be(3, 2) + F.be(1, 4) + F.be(UInt64(here), 8) + F.be(UInt64(previous), 8) + F.be(0, 8)
            v += F.be(UInt64(headerBytes), 8) + F.be(UInt64(indexBytes), 8) + F.be(UInt64(indexSID), 4)
            v += F.be(UInt64(bodyOffset), 8) + F.be(UInt64(bodySID), 4) + F.op1a
            v += F.be(1, 4) + F.be(16, 4) + pictureContainer
            out += F.partitionKey(kind, status: status) + F.ber(v.count)
            packs.append(out.count)
            out += v
        }

        let meta = metadata()
        let unitCount = max(frames.count, audioTracks > 0 && frames.isEmpty ? samplesPerUnit.count : 0)
        var units: [[UInt8]] = []
        var sampleStart = 0
        for u in 0..<unitCount {
            let n = audioTracks > 0 ? samplesPerUnit[u % samplesPerUnit.count] : 0
            units.append(unit(u, sampleStart: sampleStart, samples: n))
            sampleStart += n
        }
        if index == .cbr, let longest = units.map(\.count).max() {
            sampleStart = 0
            for u in 0..<unitCount {
                let n = audioTracks > 0 ? samplesPerUnit[u % samplesPerUnit.count] : 0
                units[u] = unit(u, sampleStart: sampleStart, samples: n, padTo: longest + 64)
                sampleStart += n
            }
        }

        let finished = hasFooter
        pack(0x02, status: finished ? 0x04 : 0x01, headerBytes: meta.count, bodySID: bodyPartitions == 0 ? 1 : 0)
        out += meta
        var streamOffsets: [Int] = []
        var stream = 0
        let groups = max(1, bodyPartitions)
        let perGroup = max(1, (unitCount + groups - 1) / groups)
        for g in 0..<groups {
            let slice = units[min(g * perGroup, unitCount)..<min((g + 1) * perGroup, unitCount)]
            if bodyPartitions > 0 { pack(0x03, bodyOffset: stream, bodySID: 1) }
            for u in slice { streamOffsets.append(stream); out += u; stream += u.count }
        }

        if hasFooter {
            var segments: [UInt8] = []
            let rate = F.rational(editRate.num, editRate.den)
            if index == .vbr {
                var start = 0
                while start < unitCount {
                    let end = min(unitCount, start + segmentSize)
                    var entries = F.be(UInt64(end - start), 4) + F.be(11, 4)
                    for u in start..<end {
                        entries += [UInt8(bitPattern: temporalOffsets?[u] ?? 0), 0, flags?[u] ?? 0x80] + F.be(UInt64(streamOffsets[u]), 8)
                    }
                    segments += F.klv(F.indexKey, [F.item(0x3C0A, F.uid(9000 + start)), F.item(0x3F0B, rate),
                                                   F.item(0x3F0C, F.be(UInt64(start), 8)), F.item(0x3F0D, F.be(UInt64(end - start), 8)),
                                                   F.item(0x3F05, F.be(0, 4)), F.item(0x3F06, F.be(2, 4)), F.item(0x3F07, F.be(1, 4)),
                                                   F.item(0x3F08, [0]), F.item(0x3F0A, entries)].flatMap { $0 })
                    start = end
                }
            } else if index == .cbr {
                segments += F.klv(F.indexKey, [F.item(0x3C0A, F.uid(9000)), F.item(0x3F0B, rate), F.item(0x3F0C, F.be(0, 8)),
                                               F.item(0x3F0D, F.be(UInt64(unitCount), 8)),
                                               F.item(0x3F05, F.be(UInt64(units.first?.count ?? 0), 4)),
                                               F.item(0x3F06, F.be(2, 4)), F.item(0x3F07, F.be(1, 4))].flatMap { $0 })
            }
            let footer = out.count - runIn
            pack(0x04, indexBytes: segments.count, indexSID: segments.isEmpty ? 0 : 2)
            out += segments
            for v in packs { out.replaceSubrange((v + 24)..<(v + 32), with: F.be(UInt64(footer), 8)) }
            if hasRIP {
                var rip: [UInt8] = []
                for p in partitionOffsets { rip += F.be(UInt64(p.sid), 4) + F.be(UInt64(p.offset), 8) }
                let total = 16 + 5 + rip.count + 4
                out += F.klv(F.partitionKey(0x11, status: 0x01), rip + F.be(UInt64(total), 4))
            }
        }
        return Data(out)
    }
}

/// Writes tiny H.264 streams (Annex B) whose every macroblock is raw PCM: no encoder needed, lossless, any profile.
enum H264TestStream {
    struct Bits {
        var bytes: [UInt8] = []
        private var current: UInt8 = 0, filled = 0
        mutating func put(_ v: UInt32, _ n: Int) {
            for i in (0..<n).reversed() {
                current = current << 1 | UInt8((v >> UInt32(i)) & 1); filled += 1
                if filled == 8 { bytes.append(current); current = 0; filled = 0 }
            }
        }
        mutating func ue(_ v: UInt32) {
            let x = v + 1
            let len = 32 - x.leadingZeroBitCount
            put(0, len - 1); put(x, len)
        }
        mutating func se(_ v: Int32) { ue(v > 0 ? UInt32(2 * v - 1) : UInt32(-2 * v)) }
        mutating func align() { while filled != 0 { put(0, 1) } }
        mutating func trailing() { put(1, 1); align() }
    }

    struct Spec {
        var width = 64, height = 48
        var tenBit422 = false
        /// 2: output order is decode order. 0: explicit counts in the slice headers.
        var pocType = 2
        var level: UInt8 = 30
    }

    /// NAL unit with start code and emulation prevention.
    static func nal(_ header: UInt8, _ payload: [UInt8], longStartCode: Bool = true) -> [UInt8] {
        var out: [UInt8] = longStartCode ? [0, 0, 0, 1, header] : [0, 0, 1, header]
        out.reserveCapacity(payload.count + 16)
        var zeros = 0
        for b in payload {
            if zeros >= 2, b <= 3 { out.append(3); zeros = 0 }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }

    static func sps(_ s: Spec) -> [UInt8] {
        var b = Bits()
        b.put(s.tenBit422 ? 122 : 100, 8)
        b.put(s.tenBit422 ? 0x10 : 0, 8)                 // constraint_set3: the intra profile of High 4:2:2
        b.put(UInt32(s.level), 8)
        b.ue(0)
        b.ue(s.tenBit422 ? 2 : 1); b.ue(s.tenBit422 ? 2 : 0); b.ue(s.tenBit422 ? 2 : 0); b.put(0, 1); b.put(0, 1)
        b.ue(0)                                           // log2_max_frame_num 4
        b.ue(UInt32(s.pocType))
        if s.pocType == 0 { b.ue(2) }                     // log2_max_pic_order_cnt_lsb 6
        b.ue(1); b.put(0, 1)
        b.ue(UInt32(s.width / 16 - 1)); b.ue(UInt32(s.height / 16 - 1))
        b.put(1, 1); b.put(1, 1); b.put(0, 1); b.put(0, 1)
        b.trailing()
        return nal(0x67, b.bytes)
    }

    static func pps() -> [UInt8] {
        var b = Bits()
        b.ue(0); b.ue(0); b.put(0, 1); b.put(0, 1); b.ue(0); b.ue(0); b.ue(0); b.put(0, 1); b.put(0, 2)
        b.se(0); b.se(0); b.se(0); b.put(1, 1); b.put(0, 1); b.put(0, 1)
        b.trailing()
        return nal(0x68, b.bytes)
    }

    /// One frame of a flat color. `luma` and `chroma` are sample values at the stream's bit depth.
    /// `idr`: key frame; else an intra slice in a non-IDR picture (`reference` sets nal_ref_idc).
    static func frame(_ s: Spec, luma: Int, chroma: Int? = nil, idr: Bool = true, reference: Bool = true, idrID: Int = 0,
                      frameNum: Int = 0, pocLsb: Int = 0, parameterSets: Bool = true, accessUnitDelimiter: Bool = false,
                      filler: Int = 0) -> Data {
        let depth = s.tenBit422 ? 10 : 8
        let c = chroma ?? (1 << (depth - 1))
        var pcm = Bits()
        for _ in 0..<256 { pcm.put(UInt32(luma), depth) }
        for _ in 0..<(s.tenBit422 ? 256 : 128) { pcm.put(UInt32(c), depth) }

        var b = Bits()
        b.ue(0); b.ue(7); b.ue(0)
        b.put(UInt32(idr ? 0 : frameNum & 15), 4)
        if idr { b.ue(UInt32(idrID)) }
        if s.pocType == 0 { b.put(UInt32(pocLsb & 63), 6) }
        if idr { b.put(0, 2) } else if reference { b.put(0, 1) }
        b.se(0)
        b.ue(1)                                           // no deblocking
        let macroblocks = (s.width / 16) * (s.height / 16)
        b.ue(25); b.align()
        var payload = b.bytes
        payload.reserveCapacity(macroblocks * (pcm.bytes.count + 2) + 8)
        payload += pcm.bytes
        for _ in 1..<macroblocks { payload += [0x0D, 0x00]; payload += pcm.bytes }   // mb_type 25 and alignment
        payload.append(0x80)

        var out: [UInt8] = []
        if accessUnitDelimiter { out += nal(0x09, [0x10]) }
        if parameterSets { out += sps(s) + pps() }
        if filler > 0 { out += nal(0x0C, [UInt8](repeating: 0xFF, count: filler) + [0x80]) }
        out += nal(idr ? 0x65 : reference ? 0x41 : 0x01, payload, longStartCode: false)
        return Data(out)
    }
}
