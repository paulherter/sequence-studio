import Foundation
#if canImport(AVFoundation)
import AVFoundation
import VideoToolbox
import simd
#endif
#if canImport(SQRender)
import SQRender
#endif

/// HDR delivery tagging of the exported file (an SDR to HLG/PQ conform): Rec.2020 primaries and matrix, the HLG or PQ transfer,
/// plus mastering display (MDCV) and content light level (CLLI) metadata written on the encoder session. Pure data here;
/// `ExportWriter.speedEncoderProperties` and `videoOutputSettings` add it when `ExportSettings.hdrDelivery` is set.
/// Needs a 10-bit codec: only HEVC (Main 10) carries it; H.264 and ProRes ignore the setting.
public struct HDRDelivery: Sendable, Hashable, Codable {
    public enum Transfer: String, Sendable, Codable, CaseIterable {
        case hlg, pq
        public var title: String { self == .hlg ? "HLG" : "PQ (HDR10)" }
    }
    public var transfer: Transfer
    /// Peak luminance of the mastering display and of the brightest pixel, in nits (cd/m2), 100...10000.
    public var peakNits: Double
    /// Maximum frame-average light level in nits, at most `peakNits`.
    public var frameAverageNits: Double
    /// Black level of the mastering display in nits.
    public var minNits: Double

    public init(transfer: Transfer = .pq, peakNits: Double = 1000, frameAverageNits: Double = 400, minNits: Double = 0.005) {
        self.transfer = transfer
        self.peakNits = min(max(peakNits, 100), 10_000)
        self.frameAverageNits = min(max(frameAverageNits, 1), self.peakNits)
        self.minNits = min(max(minNits, 0), 5)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(transfer: (try? c.decode(Transfer.self, forKey: .transfer)) ?? .pq,
                  peakNits: (try? c.decode(Double.self, forKey: .peakNits)) ?? 1000,
                  frameAverageNits: (try? c.decode(Double.self, forKey: .frameAverageNits)) ?? 400,
                  minNits: (try? c.decode(Double.self, forKey: .minNits)) ?? 0.005)
    }
    private enum Keys: String, CodingKey { case transfer, peakNits, frameAverageNits, minNits }

    private static func be16(_ v: Int) -> [UInt8] { let u = UInt16(clamping: v); return [UInt8(u >> 8), UInt8(u & 0xFF)] }
    private static func be32(_ v: Int) -> [UInt8] {
        let u = UInt32(clamping: v); return [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    }

    /// 24 bytes as in `kCMFormatDescriptionExtension_MasteringDisplayColorVolume`: primaries G, B, R then white point (x, y as
    /// UInt16 in 0.00002 units), then max and min luminance (UInt32 in 0.0001 nit). Display: P3 primaries, D65 white.
    public var masteringDisplayData: Data {
        func c(_ v: Double) -> [UInt8] { Self.be16(Int((v / 0.00002).rounded())) }
        var b: [UInt8] = []
        for p in [(0.265, 0.690), (0.150, 0.060), (0.680, 0.320), (0.3127, 0.3290)] { b += c(p.0) + c(p.1) }
        b += Self.be32(Int((peakNits / 0.0001).rounded())) + Self.be32(Int((minNits / 0.0001).rounded()))
        return Data(b)
    }

    /// 4 bytes as in `kCMFormatDescriptionExtension_ContentLightLevelInfo`: MaxCLL then MaxFALL, UInt16 nits.
    public var contentLightLevelData: Data {
        Data(Self.be16(Int(peakNits.rounded())) + Self.be16(Int(frameAverageNits.rounded())))
    }

    #if canImport(AVFoundation) && canImport(SQRender)
    /// CPU reference of the export output stage for an HDR delivery: working-linear Rec.709 light (1.0 = reference white,
    /// 203 nit) -> Rec.2020 primaries -> HLG or PQ signal 0...1. The export shader (`ExportShaderSource`) is held to this.
    public func encode(_ workingLinear: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_max(Gamut.rec709.matrix(to: .bt2020) * workingLinear, SIMD3<Float>.zero)
        let signal = transfer == .pq ? TransferFunctions.pqEncode(c) : TransferFunctions.hlgEncode(c)
        return simd_clamp(signal, SIMD3<Float>.zero, SIMD3<Float>.one)
    }

    public var primariesTag: String { AVVideoColorPrimaries_ITU_R_2020 }
    public var matrixTag: String { AVVideoYCbCrMatrix_ITU_R_2020 }
    public var transferTag: String { transfer == .pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG }

    /// AVVideoColorPropertiesKey dictionary.
    var colorProperties: [String: Any] {
        [AVVideoColorPrimariesKey: primariesTag, AVVideoTransferFunctionKey: transferTag, AVVideoYCbCrMatrixKey: matrixTag]
    }

    /// The two metadata blocks as VideoToolbox compression properties.
    var metadataProperties: [String: Any] {
        [kVTCompressionPropertyKey_MasteringDisplayColorVolume as String: masteringDisplayData,
         kVTCompressionPropertyKey_ContentLightLevelInfo as String: contentLightLevelData]
    }

    /// VideoToolbox keys for the tags and the two metadata blocks.
    var sessionProperties: [String: Any] {
        var r = metadataProperties
        r[kVTCompressionPropertyKey_ColorPrimaries as String] = primariesTag
        r[kVTCompressionPropertyKey_TransferFunction as String] = transferTag
        r[kVTCompressionPropertyKey_YCbCrMatrix as String] = matrixTag
        return r
    }
    #endif
}
