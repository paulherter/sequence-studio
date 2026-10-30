import Foundation

/// Fields of a VP9 key frame's uncompressed header (VP9 bitstream spec section 6.2), enough to describe the stream.
struct VP9KeyFrameInfo: Equatable {
    var profile: Int, bitDepth: Int
    var subsamplingX: Int, subsamplingY: Int
    var colorSpace: Int, fullRange: Bool
    var width: Int, height: Int

    var chroma: String {
        switch (subsamplingX, subsamplingY) {
        case (1, 1): return "4:2:0"
        case (1, 0): return "4:2:2"
        case (0, 1): return "4:4:0"
        default: return "4:4:4"
        }
    }

    /// nil when `frame` is not a key frame or is malformed.
    static func parse(_ frame: Data) -> VP9KeyFrameInfo? {
        var r = Bits(frame)
        guard r.read(2) == 2 else { return nil }
        let low = r.read(1), high = r.read(1)
        let profile = high << 1 | low
        if profile == 3 { _ = r.read(1) }
        if r.read(1) == 1 { return nil }                    // show_existing_frame
        guard r.read(1) == 0 else { return nil }            // frame_type: 0 = key frame
        _ = r.read(1); _ = r.read(1)                        // show_frame, error_resilient_mode
        guard r.read(8) == 0x49, r.read(8) == 0x83, r.read(8) == 0x42 else { return nil }
        var depth = 8
        if profile >= 2 { depth = r.read(1) == 1 ? 12 : 10 }
        let cs = r.read(3)
        var range = false, sx = 1, sy = 1
        if cs != 7 {
            range = r.read(1) == 1
            if profile == 1 || profile == 3 { sx = r.read(1); sy = r.read(1); _ = r.read(1) }
        } else {
            range = true
            if profile == 1 || profile == 3 { sx = 0; sy = 0; _ = r.read(1) } else { return nil }   // RGB needs profile 1 or 3
        }
        let w = r.read(16) + 1, h = r.read(16) + 1
        guard !r.overrun else { return nil }
        return VP9KeyFrameInfo(profile: profile, bitDepth: depth, subsamplingX: sx, subsamplingY: sy, colorSpace: cs,
                               fullRange: range, width: w, height: h)
    }

    /// `vpcC` atom payload (ISO full box without the size/type header).
    func vpcC(primaries: Int, transfer: Int, matrix: Int) -> Data {
        let chromaCode: Int
        switch (subsamplingX, subsamplingY) { case (1, 1): chromaCode = 0; case (1, 0): chromaCode = 2; default: chromaCode = 3 }
        let pixels = width * height
        let level: Int = pixels <= 552_960 ? 31 : pixels <= 983_040 ? 40 : pixels <= 2_228_224 ? 41 : pixels <= 8_912_896 ? 51 : 62
        return Data([1, 0, 0, 0, UInt8(profile), UInt8(level), UInt8(bitDepth << 4 | chromaCode << 1 | (fullRange ? 1 : 0)),
                     UInt8(primaries), UInt8(transfer), UInt8(matrix), 0, 0])
    }

    struct Bits {
        let d: [UInt8]
        var pos = 0
        var overrun = false
        init(_ data: Data) { d = [UInt8](data.prefix(32)) }
        mutating func read(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                let byte = pos >> 3
                if byte >= d.count { overrun = true; return v << 1 }
                v = v << 1 | Int((d[byte] >> UInt8(7 - pos & 7)) & 1)
                pos += 1
            }
            return v
        }
    }
}
