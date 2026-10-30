import CoreMedia
import Foundation
import SQCore

/// Start timecode of an MXF file (timecode track of the material package, else of the file package).
public struct MXFTimecode: Sendable, Hashable {
    /// Frame count of the first frame since 00:00:00:00.
    public var startFrame: Int64
    /// Frames per second rounded up (24, 25, 30, 50, 60).
    public var base: Int
    public var dropFrame: Bool

    public init(startFrame: Int64, base: Int, dropFrame: Bool) {
        self.startFrame = startFrame; self.base = base; self.dropFrame = dropFrame
    }

    /// "HH:MM:SS:FF", with ";" before the frames for drop frame.
    public var string: String {
        guard base > 0 else { return "00:00:00:00" }
        var f = max(0, startFrame)
        let b = Int64(base)
        if dropFrame, base == 30 || base == 60 {
            let drop = b / 15                              // 2 at 29.97, 4 at 59.94
            let per10 = b * 600 - 9 * drop, perMin = b * 60 - drop
            let d = f / per10, m = f % per10
            f += 9 * drop * d + (m > drop ? drop * ((m - drop) / perMin) : 0)
        }
        let ff = f % b, s = (f / b) % 60, m = (f / (b * 60)) % 60, h = (f / (b * 3600)) % 24
        func two(_ v: Int64) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(two(h)):\(two(m)):\(two(s))\(dropFrame ? ";" : ":")\(two(ff))"
    }
}

/// Picture essence descriptor (CDCI, RGBA, MPEG video) of one track.
public struct MXFPictureDescriptor: Sendable, Hashable {
    public var coding: MXFUL?
    public var container: MXFUL?
    public var storedWidth = 0, storedHeight = 0
    public var displayWidth = 0, displayHeight = 0
    /// 0 full frame, 1 separate fields, 2 single field, 3 mixed fields, 4 segmented frame.
    public var frameLayout = 0
    public var aspect: (num: Int, den: Int)? { aspectNum > 0 && aspectDen > 0 ? (aspectNum, aspectDen) : nil }
    var aspectNum = 0, aspectDen = 0
    public var componentDepth = 0
    public var horizontalSubsampling = 0, verticalSubsampling = 0
    public var transfer: MXFUL?
    public var primaries: MXFUL?
    public var codingEquations: MXFUL?
    public var isRGBA = false

    /// "4:2:2", "4:2:0", "4:4:4" from the subsampling factors; nil when the descriptor does not say.
    public var chroma: String? {
        if isRGBA { return "4:4:4" }
        switch (horizontalSubsampling, verticalSubsampling) {
        case (2, 2): return "4:2:0"
        case (2, 1), (2, 0): return "4:2:2"
        case (1, 1), (1, 0): return "4:4:4"
        default: return nil
        }
    }
    /// 0 not written (field 1 first), 1 field 1 is the earlier field, 2 field 2 is.
    public var fieldDominance = 0
    /// First active line of field 1 and of field 2 (0 = not written).
    public var videoLineMap = (first: 0, second: 0)
    public var isInterlaced: Bool { frameLayout == 1 || frameLayout == 3 }

    /// The earlier field of interlaced pictures; nil for progressive material: full frame (0), segmented frame (4,
    /// PsF: one progressive picture carried as two fields) and single field (2, nothing to pair).
    /// The line map says which field is the upper one, the rule of FFmpeg's reader: one odd and one even start line
    /// (1080i: 21 and 584, 625 lines: 23 and 336) means field 1 is the top field, two of the same parity (525-line
    /// DV: 23 and 285) means it is the bottom field. Without a line map field 1 is taken as the top field, as in
    /// every HD format. Field dominance 2 swaps the two in time.
    public var fieldOrder: FieldOrder? {
        guard isInterlaced else { return nil }
        let mapped = videoLineMap.first > 0 && videoLineMap.second > 0
        let fieldOneIsTop = !mapped || (videoLineMap.first + videoLineMap.second) % 2 == 1
        return fieldOneIsTop == (fieldDominance != 2) ? .topFirst : .bottomFirst
    }

    /// CoreMedia color tags of the descriptor's labels (ST 377-1 annex, RP 224 `04 01 01 01 0k xx`).
    public var transferTag: String? {
        guard let u = transfer, u.matches([0x04, 0x01, 0x01, 0x01, 0x01], at: 8) else { return nil }
        switch u.byte(13) {
        case 0x01, 0x02, 0x04, 0x05: return kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String
        case 0x03: return kCMFormatDescriptionTransferFunction_SMPTE_240M_1995 as String
        case 0x06: return kCMFormatDescriptionTransferFunction_Linear as String
        case 0x09: return kCMFormatDescriptionTransferFunction_ITU_R_2020 as String
        case 0x0A: return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
        case 0x0B: return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
        default: return nil
        }
    }
    public var primariesTag: String? {
        guard let u = primaries, u.matches([0x04, 0x01, 0x01, 0x01, 0x03], at: 8) else { return nil }
        switch u.byte(13) {
        case 0x01: return kCMFormatDescriptionColorPrimaries_SMPTE_C as String
        case 0x02: return kCMFormatDescriptionColorPrimaries_EBU_3213 as String
        case 0x03: return kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
        case 0x04: return kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String
        case 0x06: return kCMFormatDescriptionColorPrimaries_P3_D65 as String
        default: return nil
        }
    }
    public var matrixTag: String? {
        guard let u = codingEquations, u.matches([0x04, 0x01, 0x01, 0x01, 0x02], at: 8) else { return nil }
        switch u.byte(13) {
        case 0x01: return kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String
        case 0x02: return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
        case 0x03: return kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995 as String
        case 0x06: return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String
        default: return nil
        }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.coding == b.coding && a.container == b.container && a.storedWidth == b.storedWidth && a.storedHeight == b.storedHeight
            && a.frameLayout == b.frameLayout && a.componentDepth == b.componentDepth
    }
    public func hash(into h: inout Hasher) { h.combine(coding); h.combine(storedWidth); h.combine(storedHeight) }
}

/// Sound essence descriptor (generic sound, wave, AES3) of one track.
public struct MXFSoundDescriptor: Sendable, Hashable {
    public var container: MXFUL?
    public var compression: MXFUL?
    public var sampleRate = 48_000
    public var channels = 1
    public var bits = 16
    public var blockAlign = 0

    public var bytesPerSample: Int {
        if blockAlign > 0, channels > 0, blockAlign % channels == 0, (1...4).contains(blockAlign / channels) { return blockAlign / channels }
        return max(1, min(4, (bits + 7) / 8))
    }
    /// PCM is little endian unless the compression label says big endian (`04 02 02 01 7E`, AIFF style).
    public var isBigEndian: Bool { compression?.matches([0x04, 0x02, 0x02, 0x01, 0x7E], at: 8) ?? false }
    /// Uncompressed PCM: no compression label, or one of the PCM labels (`04 02 02 01 xx`).
    public var isPCM: Bool {
        guard let c = compression, c.hi != 0 || c.lo != 0 else { return true }
        return c.matches([0x04, 0x02, 0x02, 0x01], at: 8)
    }
    /// Name of a compressed sound coding for messages.
    public var codecName: String {
        guard let c = compression, !isPCM else { return "PCM" }
        if c.matches([0x04, 0x02, 0x02, 0x02, 0x03, 0x01, 0x01], at: 8) { return "A-law" }
        if c.matches([0x04, 0x02, 0x02, 0x02, 0x03, 0x02, 0x01], at: 8) { return "AC-3" }
        if c.matches([0x04, 0x02, 0x02, 0x02, 0x03, 0x02], at: 8) { return "MPEG audio" }
        if c.matches([0x04, 0x02, 0x02, 0x02, 0x04], at: 8) || c.matches([0x04, 0x02, 0x02, 0x02, 0x03, 0x03], at: 8) { return "AAC" }
        return "compressed audio"
    }
}

/// One essence track of the file package.
public struct MXFTrack: Sendable, Hashable {
    public enum Kind: Sendable { case picture, sound, data, other }
    public var id: UInt32 = 0
    /// Bytes 12...15 of this track's essence element keys.
    public var number: UInt32 = 0
    public var kind: Kind = .other
    public var editRateNum = 0, editRateDen = 1
    public var origin: Int64 = 0
    /// Duration in edit units from the metadata (-1 unknown, e.g. a file still being written).
    public var duration: Int64 = -1
    public var picture: MXFPictureDescriptor?
    public var sound: MXFSoundDescriptor?

    /// Length of one edit unit.
    public var editUnit: Time? { editRateNum > 0 && editRateDen > 0 ? Time(Int64(editRateDen), Int64(editRateNum)) : nil }
}

/// A header metadata local set: 2-byte tag, 2-byte length items.
struct MXFSet {
    let kind: UInt8
    let items: [UInt16: Range<Int>]
    let r: MXFBytes

    init?(_ r: MXFBytes, _ k: MXFKLV, kind: UInt8) {
        var items: [UInt16: Range<Int>] = [:]
        var p = k.valueOffset
        let end = min(k.end, r.count)
        while p + 4 <= end, let tag = r.u16(p), let len = r.u16(p + 2) {
            let v = p + 4
            guard v + Int(len) <= end else { break }
            items[tag] = v..<(v + Int(len))
            p = v + Int(len)
        }
        self.kind = kind; self.items = items; self.r = r
    }

    func uint(_ tag: UInt16) -> UInt64? {
        guard let i = items[tag], (1...8).contains(i.count) else { return nil }
        return r.uint(i.lowerBound, i.count)
    }
    func int(_ tag: UInt16) -> Int? { uint(tag).flatMap { $0 <= UInt64(Int32.max) * 4 ? Int($0) : nil } }
    func int64(_ tag: UInt16) -> Int64? {
        guard let i = items[tag], i.count == 8, let v = r.u64(i.lowerBound) else { return nil }
        return Int64(bitPattern: v)
    }
    func ul(_ tag: UInt16) -> MXFUL? {
        guard let i = items[tag], i.count == 16 else { return nil }
        return r.ul(i.lowerBound)
    }
    /// Two signed 32-bit integers (numerator, denominator).
    func rational(_ tag: UInt16) -> (Int, Int)? {
        guard let i = items[tag], i.count == 8, let n = r.u32(i.lowerBound), let d = r.u32(i.lowerBound + 4) else { return nil }
        return (Int(Int32(bitPattern: n)), Int(Int32(bitPattern: d)))
    }
    /// A batch or array of 16-byte references (count, item length, items).
    func refs(_ tag: UInt16) -> [MXFUL] {
        guard let i = items[tag], i.count >= 8, let n = r.u32(i.lowerBound), let len = r.u32(i.lowerBound + 4), len >= 16 else { return [] }
        let fit = (i.count - 8) / Int(len)
        return (0..<min(Int(n), fit)).compactMap { r.ul(i.lowerBound + 8 + $0 * Int(len)) }
    }
}

/// The structural metadata the engine needs, resolved from the header metadata sets.
struct MXFMetadata {
    var tracks: [MXFTrack] = []
    var timecode: MXFTimecode?

    /// Parses the sets in `region` (primer pack and sets of one partition).
    static func parse(_ r: MXFBytes, region: Range<Int>) -> MXFMetadata {
        var sets: [MXFUL: MXFSet] = [:]
        var order: [MXFUL] = []
        var p = region.lowerBound
        let end = min(region.upperBound, r.count)
        var guardCount = 0
        while p < end, let k = r.klv(at: p), guardCount < 200_000 {
            guardCount += 1
            if let kind = k.key.metadataSetKind, let s = MXFSet(r, k, kind: kind), let uid = s.ul(0x3C0A), sets[uid] == nil {
                sets[uid] = s; order.append(uid)
            }
            guard k.end > p, k.end <= r.count else { break }
            p = k.end
        }
        return resolve(sets, order: order)
    }

    private static let pictureKinds: Set<UInt8> = [0x27, 0x28, 0x29, 0x51]
    private static let soundKinds: Set<UInt8> = [0x42, 0x47, 0x48]

    private static func resolve(_ sets: [MXFUL: MXFSet], order: [MXFUL]) -> MXFMetadata {
        let all = order.compactMap { sets[$0] }
        func fileDescriptors(of package: MXFSet) -> [MXFSet] {
            guard let d = package.ul(0x4701).flatMap({ sets[$0] }) else { return [] }
            let list = d.kind == 0x44 ? d.refs(0x3F01).compactMap { sets[$0] } : [d]
            return list.filter { pictureKinds.contains($0.kind) || soundKinds.contains($0.kind) }
        }
        let sourcePackages = all.filter { $0.kind == 0x37 }
        let filePackage = sourcePackages.first { !fileDescriptors(of: $0).isEmpty } ?? sourcePackages.first
        var descriptors = filePackage.map(fileDescriptors) ?? []
        if descriptors.isEmpty { descriptors = all.filter { pictureKinds.contains($0.kind) || soundKinds.contains($0.kind) } }

        func trackSets(of package: MXFSet?) -> [MXFSet] {
            guard let package else { return [] }
            return package.refs(0x4403).compactMap { sets[$0] }.filter { $0.kind == 0x3B }
        }
        var trackSetList = trackSets(of: filePackage)
        if trackSetList.isEmpty, filePackage == nil { trackSetList = all.filter { $0.kind == 0x3B } }

        func components(of track: MXFSet) -> (sequence: MXFSet?, parts: [MXFSet]) {
            guard let s = track.ul(0x4803).flatMap({ sets[$0] }) else { return (nil, []) }
            if s.kind == 0x0F { return (s, s.refs(0x1001).compactMap { sets[$0] }) }
            return (nil, [s])
        }

        var out = MXFMetadata()
        var unlinked = descriptors.filter { $0.int(0x3006) == nil }
        for t in trackSetList {
            var track = MXFTrack()
            track.id = UInt32(truncatingIfNeeded: t.uint(0x4801) ?? 0)
            track.number = UInt32(truncatingIfNeeded: t.uint(0x4804) ?? 0)
            if let (n, d) = t.rational(0x4B01), n > 0, d > 0 { track.editRateNum = n; track.editRateDen = d }
            track.origin = t.int64(0x4B02) ?? 0
            let (seq, _) = components(of: t)
            if let d = seq?.int64(0x0202) { track.duration = d }

            var desc = descriptors.first { $0.int(0x3006).map { UInt32(truncatingIfNeeded: $0) } == track.id && track.id != 0 }
            let item = UInt8(track.number >> 24)
            let numberKind: MXFTrack.Kind = item == 0x05 || item == 0x15 ? .picture : item == 0x06 || item == 0x16 ? .sound
                : item == 0x07 || item == 0x17 ? .data : .other
            var definitionKind: MXFTrack.Kind = .other
            if let dd = seq?.ul(0x0201), dd.matches([0x01, 0x03, 0x02, 0x02], at: 8) {
                definitionKind = dd.byte(12) == 1 ? .picture : dd.byte(12) == 2 ? .sound : dd.byte(12) == 3 ? .data : .other
            }
            let guess = numberKind != .other ? numberKind : definitionKind
            if desc == nil, guess == .picture || guess == .sound {
                // No LinkedTrackID: descriptors without one are taken in order, by kind.
                let kinds = guess == .picture ? pictureKinds : soundKinds
                if let i = unlinked.firstIndex(where: { kinds.contains($0.kind) }) { desc = unlinked.remove(at: i) }
            }
            if let desc, pictureKinds.contains(desc.kind) {
                track.kind = .picture; track.picture = picture(desc)
            } else if let desc, soundKinds.contains(desc.kind) {
                track.kind = .sound; track.sound = sound(desc)
            } else {
                track.kind = guess
            }
            if track.kind == .picture || track.kind == .sound || track.kind == .data { out.tracks.append(track) }
            if track.editRateNum == 0, let desc, let (n, d) = desc.rational(0x3001), n > 0, d > 0, track.kind == .picture {
                out.tracks[out.tracks.count - 1].editRateNum = n; out.tracks[out.tracks.count - 1].editRateDen = d
            }
        }

        // Timecode: the material package's timecode track is what editors show; the file package's is the fallback.
        let material = all.first { $0.kind == 0x36 }
        for package in [material, filePackage] where out.timecode == nil {
            for t in trackSets(of: package) {
                guard let tc = components(of: t).parts.first(where: { $0.kind == 0x14 }),
                      let start = tc.int64(0x1501), let base = tc.int(0x1502), base > 0, base <= 1000 else { continue }
                out.timecode = MXFTimecode(startFrame: start, base: base, dropFrame: (tc.uint(0x1503) ?? 0) != 0)
                break
            }
        }
        return out
    }

    private static func picture(_ s: MXFSet) -> MXFPictureDescriptor {
        var d = MXFPictureDescriptor()
        d.coding = s.ul(0x3201); d.container = s.ul(0x3004)
        d.storedHeight = s.int(0x3202) ?? 0; d.storedWidth = s.int(0x3203) ?? 0
        d.displayHeight = s.int(0x3208) ?? s.int(0x3204) ?? d.storedHeight
        d.displayWidth = s.int(0x3209) ?? s.int(0x3205) ?? d.storedWidth
        d.frameLayout = s.int(0x320C) ?? 0
        d.fieldDominance = s.int(0x3212) ?? 0
        // Array of 32-bit integers: count, item length, items.
        if let m = s.items[0x320D], m.count >= 16, s.r.u32(m.lowerBound) == 2, s.r.u32(m.lowerBound + 4) == 4,
           let a = s.r.u32(m.lowerBound + 8), let b = s.r.u32(m.lowerBound + 12), a < 10_000, b < 10_000 {
            d.videoLineMap = (Int(a), Int(b))
        }
        if let (n, den) = s.rational(0x320E) { d.aspectNum = n; d.aspectDen = den }
        d.transfer = s.ul(0x3210); d.primaries = s.ul(0x3219); d.codingEquations = s.ul(0x321A)
        d.componentDepth = s.int(0x3301) ?? 0
        d.horizontalSubsampling = s.int(0x3302) ?? 0; d.verticalSubsampling = s.int(0x3308) ?? 0
        d.isRGBA = s.kind == 0x29
        return d
    }

    private static func sound(_ s: MXFSet) -> MXFSoundDescriptor {
        var d = MXFSoundDescriptor()
        d.container = s.ul(0x3004); d.compression = s.ul(0x3D06)
        if let (n, den) = s.rational(0x3D03), n > 0, den > 0, n / den >= 1000, n / den <= 768_000 { d.sampleRate = n / den }
        if let c = s.int(0x3D07), c >= 1, c <= 64 { d.channels = c }
        if let b = s.int(0x3D01), b >= 8, b <= 32 { d.bits = b }
        if let a = s.int(0x3D0A), a >= 1, a <= 256 { d.blockAlign = a }
        return d
    }
}

/// Video coding of an MXF picture track.
public enum MXFVideoCodec: Sendable, Equatable {
    case h264
    /// ProRes; nil when the label does not name the flavor (the frame header decides).
    case prores(FourCharCode?)
    /// Known coding without a decoder path here; the name is shown to the user.
    case unsupported(String)

    /// From the descriptor's picture essence coding label, else the essence container label. nil: neither says.
    public static func identify(coding: MXFUL?, container: MXFUL?) -> MXFVideoCodec? {
        if let c = coding, c.hi != 0 || c.lo != 0 {
            if c.matches([0x04, 0x01, 0x02, 0x02], at: 8) {
                switch (c.byte(12), c.byte(13)) {
                case (0x01, 0x30...0x3F): return .h264
                case (0x01, 0x20...0x2F): return .unsupported("MPEG-4 Part 2")
                case (0x01, 0x01...0x1F): return .unsupported("MPEG-2 (XDCAM / IMX)")
                case (0x02, _): return .unsupported("DV")
                case (0x03, 0x01): return .unsupported("JPEG 2000")
                case (0x03, 0x02): return .unsupported("DNxHD / DNxHR")
                case (0x03, 0x06):
                    let flavors: [UInt8: String] = [1: "apco", 2: "apcs", 3: "apcn", 4: "apch", 5: "ap4h", 6: "ap4x"]
                    return .prores(flavors[c.byte(14)].map(code))
                case (0x04, _): return .unsupported("VC-1")
                case (0x71, _): return .unsupported("DNxHD / DNxHR")
                default: break
                }
            }
            if c.matches([0x04, 0x01, 0x02, 0x01], at: 8) { return .unsupported("uncompressed video") }
            if c.matches([0x0E, 0x04, 0x02, 0x01, 0x02, 0x04], at: 8) { return .unsupported("DNxHD / DNxHR") }
            if c.matches([0x0E, 0x04, 0x02, 0x01, 0x02, 0x11], at: 8) { return .prores(nil) }
        }
        if let k = container, k.matches([0x0D, 0x01, 0x03, 0x01, 0x02], at: 8) {
            switch k.byte(13) {
            case 0x0F, 0x10: return .h264
            case 0x1C: return .prores(nil)
            case 0x01: return .unsupported("MPEG-2 (IMX)")
            case 0x02: return .unsupported("DV")
            case 0x05: return .unsupported("uncompressed video")
            case 0x0C: return .unsupported("JPEG 2000")
            case 0x11: return .unsupported("DNxHD / DNxHR")
            case 0x0A: return .unsupported("VC-1")
            default: break       // 0x04 MPEG elementary stream: MPEG-2 or H.264, the stream decides
            }
        }
        return nil
    }

    static func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }
}
