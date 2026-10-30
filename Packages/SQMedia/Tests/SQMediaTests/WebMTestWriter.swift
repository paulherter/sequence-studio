import Foundation

/// Minimal Matroska / WebM writer for tests: tracks plus frames, written as 1 s clusters.
struct WebMTestWriter {
    struct Track {
        var number: Int, isVideo: Bool, codecID: String
        var codecPrivate = Data()
        var width = 0, height = 0
        var channels = 0, rate = 0.0
        var bitDepth = 0
        var defaultDurationNs = 0
        var codecDelayNs = 0
    }
    struct Frame { var track: Int, ms: Int, key: Bool, data: Data }

    var tracks: [Track] = []
    var frames: [Frame] = []
    /// Cluster and Segment with the "unknown size" marker (live recordings).
    var unknownSizes = false
    /// Write non-key video blocks as BlockGroups (with ReferenceBlock) and key frames as SimpleBlocks.
    var blockGroups = false
    /// Keep `frames` in the given (decode) order instead of sorting by time: B-frame streams.
    var keepOrder = false

    static func el(_ id: [UInt8], _ body: Data) -> Data {
        var d = Data(id)
        var size = UInt64(body.count)
        var s = [UInt8](repeating: 0, count: 8)
        for i in (1..<8).reversed() { s[i] = UInt8(size & 0xFF); size >>= 8 }
        s[0] = 0x01
        d.append(contentsOf: s)
        d.append(body)
        return d
    }
    static func uint(_ id: [UInt8], _ v: Int) -> Data {
        var bytes: [UInt8] = []
        var x = UInt64(v)
        repeat { bytes.insert(UInt8(x & 0xFF), at: 0); x >>= 8 } while x > 0
        return el(id, Data(bytes))
    }
    static func float(_ id: [UInt8], _ v: Double) -> Data {
        var b = v.bitPattern.bigEndian
        return el(id, Data(bytes: &b, count: 8))
    }
    static func str(_ id: [UInt8], _ v: String) -> Data { el(id, Data(v.utf8)) }

    func data() -> Data {
        var out = Self.el([0x1A, 0x45, 0xDF, 0xA3], Self.str([0x42, 0x82], "webm"))
        var seg = Data()
        seg.append(Self.el([0x15, 0x49, 0xA9, 0x66], Self.uint([0x2A, 0xD7, 0xB1], 1_000_000)))
        var tr = Data()
        for t in tracks {
            var e = Self.uint([0xD7], t.number) + Self.uint([0x83], t.isVideo ? 1 : 2) + Self.str([0x86], t.codecID)
            if !t.codecPrivate.isEmpty { e += Self.el([0x63, 0xA2], t.codecPrivate) }
            if t.defaultDurationNs > 0 { e += Self.uint([0x23, 0xE3, 0x83], t.defaultDurationNs) }
            if t.codecDelayNs > 0 { e += Self.uint([0x56, 0xAA], t.codecDelayNs) }
            if t.isVideo {
                e += Self.el([0xE0], Self.uint([0xB0], t.width) + Self.uint([0xBA], t.height))
            } else {
                e += Self.el([0xE1], Self.float([0xB5], t.rate) + Self.uint([0x9F], t.channels) + (t.bitDepth > 0 ? Self.uint([0x62, 0x64], t.bitDepth) : Data()))
            }
            tr += Self.el([0xAE], e)
        }
        seg.append(Self.el([0x16, 0x54, 0xAE, 0x6B], tr))
        let sorted = keepOrder ? frames : frames.sorted { $0.ms < $1.ms }
        // A frame that comes later in decode order than one of the next second stays in the current cluster
        // (negative block offset), so the file order is kept.
        var clusters: [Int: [Frame]] = [:]
        var current = 0
        for f in sorted { current = max(current, f.ms / 1000 * 1000); clusters[current, default: []].append(f) }
        for start in clusters.keys.sorted() {
            var body = Self.uint([0xE7], start)
            for f in clusters[start]! {
                let video = tracks.first { $0.number == f.track }?.isVideo ?? false
                var hdr = Data([0x80 | UInt8(f.track)])
                let rel = Int16(f.ms - start)
                hdr.append(contentsOf: [UInt8(UInt16(bitPattern: rel) >> 8), UInt8(UInt16(bitPattern: rel) & 0xFF)])
                if blockGroups && video && !f.key {
                    hdr.append(0)
                    body += Self.el([0xA0], Self.el([0xA1], hdr + f.data) + Self.el([0xFB], Data([0x81])))
                } else {
                    hdr.append(f.key ? 0x80 : 0)
                    body += Self.el([0xA3], hdr + f.data)
                }
            }
            if unknownSizes {
                seg.append(Data([0x1F, 0x43, 0xB6, 0x75, 0xFF]))
                seg.append(body)
            } else {
                seg.append(Self.el([0x1F, 0x43, 0xB6, 0x75], body))
            }
        }
        if unknownSizes {
            out.append(Data([0x18, 0x53, 0x80, 0x67, 0xFF])); out.append(seg)
        } else {
            out.append(Self.el([0x18, 0x53, 0x80, 0x67], seg))
        }
        return out
    }

    /// First bytes of a profile 0 VP9 key frame (8-bit 4:2:0, BT.709): only the uncompressed header is meaningful.
    static func vp9KeyFrame(width: Int, height: Int, payload: Int = 16) -> Data {
        var bits: [UInt8] = [1, 0, 0, 0, 0, 0, 1, 0]            // marker 2, profile 0, no show-existing, key, shown, no error resilience
        for b in [0x49, 0x83, 0x42] { for i in (0..<8).reversed() { bits.append(UInt8((b >> i) & 1)) } }
        bits += [0, 1, 0, 0]                                       // color space 2 (BT.709), studio range
        for v in [width - 1, height - 1] { for i in (0..<16).reversed() { bits.append(UInt8((v >> i) & 1)) } }
        while bits.count % 8 != 0 { bits.append(0) }
        var d = Data()
        for i in stride(from: 0, to: bits.count, by: 8) { d.append(bits[i..<(i + 8)].reduce(0) { $0 << 1 | $1 }) }
        d.append(Data(repeating: 0xAB, count: payload))
        return d
    }
}
