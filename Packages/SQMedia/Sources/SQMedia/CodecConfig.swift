import Foundation

/// Chroma format and bit depth from the `avcC` / `hvcC` atom payload (pure, testable).
enum CodecConfig {
    struct Result: Equatable { var chroma: String; var bitDepth: Int }

    static func chromaName(_ idc: Int) -> String { idc == 0 || idc == 1 ? "4:2:0" : idc == 2 ? "4:2:2" : "4:4:4" }

    static func hevc(_ d: Data) -> Result? {
        let b = [UInt8](d)
        guard b.count > 17 else { return nil }
        return Result(chroma: chromaName(Int(b[16] & 3)), bitDepth: Int(b[17] & 7) + 8)
    }

    static func avc(_ d: Data) -> Result? {
        let b = [UInt8](d)
        guard b.count > 8, b[0] == 1, b[5] & 0x1F >= 1 else { return nil }
        let len = Int(b[6]) << 8 | Int(b[7])
        guard b.count >= 8 + len, len > 4 else { return nil }
        // SPS NAL: header byte, then profile_idc, constraints, level_idc, then bit-packed fields.
        let sps = removeEmulationPrevention(Array(b[8..<(8 + len)]))
        let profile = Int(sps[1])
        guard [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) else { return Result(chroma: "4:2:0", bitDepth: 8) }
        var r = BitReader(Array(sps[4...]))
        _ = r.ue()                                   // seq_parameter_set_id
        let chroma = r.ue()
        if chroma == 3 { _ = r.bit() }               // separate_colour_plane_flag
        let depth = r.ue() + 8
        return Result(chroma: chromaName(chroma), bitDepth: depth)
    }

    private static func removeEmulationPrevention(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; var zeros = 0
        for x in b {
            if zeros >= 2 && x == 3 { zeros = 0; continue }
            out.append(x); zeros = x == 0 ? zeros + 1 : 0
        }
        return out
    }

    private struct BitReader {
        let bytes: [UInt8]; var pos = 0
        init(_ b: [UInt8]) { bytes = b }
        mutating func bit() -> Int {
            guard pos / 8 < bytes.count else { pos += 1; return 0 }
            let v = Int(bytes[pos / 8] >> (7 - UInt8(pos % 8))) & 1; pos += 1; return v
        }
        mutating func ue() -> Int {
            var zeros = 0
            while bit() == 0, zeros < 32, pos / 8 < bytes.count { zeros += 1 }
            var v = 0
            for _ in 0..<zeros { v = v << 1 | bit() }
            return (1 << zeros) - 1 + v
        }
    }
}
