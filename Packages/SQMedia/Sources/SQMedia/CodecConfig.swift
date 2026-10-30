import Foundation
import SQCore

/// Dolby Vision decoder configuration (`dvcC` / `dvvC` / `dvwC` payload, DOVIDecoderConfigurationRecord). iPhone HDR
/// video is profile 8.4: an HEVC Main10 base layer in HLG plus RPU metadata. We decode the base layer only (VideoToolbox
/// hands it out untouched, no RPU reshaping), so its compatibility id names the color space we render.
public struct DolbyVisionConfig: Sendable, Equatable {
    public var profile: Int
    public var level: Int
    public var hasRPU: Bool
    public var hasEnhancementLayer: Bool
    public var hasBaseLayer: Bool
    /// dv_bl_signal_compatibility_id: 1 HDR10, 2 SDR (BT.709), 4 HLG, 6 BT.2100 PQ, 0 none (profile 5, IPTPQc2).
    public var compatibilityID: Int

    public init(profile: Int, level: Int, hasRPU: Bool, hasEnhancementLayer: Bool, hasBaseLayer: Bool, compatibilityID: Int) {
        self.profile = profile; self.level = level; self.hasRPU = hasRPU
        self.hasEnhancementLayer = hasEnhancementLayer; self.hasBaseLayer = hasBaseLayer; self.compatibilityID = compatibilityID
    }

    /// The color space of the cross-compatible base layer; nil when there is none we can show (profile 5 needs the RPU).
    public var baseLayerColorSpace: ColorSpaceID? {
        switch compatibilityID {
        case 1, 6: .pqBT2020
        case 2: .rec709
        case 4: .hlgBT2020
        default: nil
        }
    }
}

/// Chroma format and bit depth from the `avcC` / `hvcC` atom payload (pure, testable).
enum CodecConfig {
    struct Result: Equatable { var chroma: String; var bitDepth: Int }

    static func chromaName(_ idc: Int) -> String { idc == 0 || idc == 1 ? "4:2:0" : idc == 2 ? "4:2:2" : "4:4:4" }

    static func hevc(_ d: Data) -> Result? {
        let b = [UInt8](d)
        guard b.count > 17 else { return nil }
        return Result(chroma: chromaName(Int(b[16] & 3)), bitDepth: Int(b[17] & 7) + 8)
    }

    /// `vpcC` payload (version 1 full box): byte 6 holds bit depth (high nibble), chroma subsampling code, full range.
    static func vp9(_ d: Data) -> Result? {
        let b = [UInt8](d)
        guard b.count >= 7 else { return nil }
        let code = Int(b[6] >> 1) & 7
        return Result(chroma: code == 2 ? "4:2:2" : code == 3 ? "4:4:4" : "4:2:0", bitDepth: Int(b[6] >> 4))
    }

    /// `av1C` payload: byte 2 holds high_bitdepth, twelve_bit, monochrome, subsampling x/y.
    static func av1(_ d: Data) -> Result? {
        let b = [UInt8](d)
        guard b.count >= 4 else { return nil }
        let hi = b[2] & 0x40 != 0, twelve = b[2] & 0x20 != 0
        let sx = b[2] & 0x08 != 0, sy = b[2] & 0x04 != 0
        return Result(chroma: sx && sy ? "4:2:0" : sx ? "4:2:2" : "4:4:4", bitDepth: twelve ? 12 : hi ? 10 : 8)
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
        if chroma == 3 { _ = r.bit() }               // separate_color_plane_flag
        let depth = r.ue() + 8
        return Result(chroma: chromaName(chroma), bitDepth: depth)
    }

    /// Atom names that carry a DOVIDecoderConfigurationRecord (profiles <= 7, 8-10, > 10).
    static let dolbyVisionAtoms = ["dvvC", "dvcC", "dvwC"]

    /// Bytes 0-1 version, then profile (7 bits), level (6), rpu / el / bl flags, then the compatibility id (high nibble).
    static func dolbyVision(_ d: Data) -> DolbyVisionConfig? {
        let b = [UInt8](d)
        guard b.count >= 5 else { return nil }
        let bits = Int(b[2]) << 8 | Int(b[3])
        return DolbyVisionConfig(profile: bits >> 9, level: (bits >> 3) & 0x3F, hasRPU: bits & 4 != 0,
                                 hasEnhancementLayer: bits & 2 != 0, hasBaseLayer: bits & 1 != 0, compatibilityID: Int(b[4] >> 4))
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
