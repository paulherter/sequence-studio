import CoreMedia
import Foundation
import Testing
import SQCore
@testable import SQMedia

/// CREATOR 8: iPhone Dolby Vision (profile 8.4, HLG base layer) without a real clip. The `dvvC` / `dvcC` payload is
/// the DOVIDecoderConfigurationRecord (Dolby "Dolby Vision Streams Within the ISO Base Media File Format" 2.2).
@Suite struct DolbyVisionTests {
    /// version 1.0, profile, level, rpu/el/bl flags, compatibility id, then reserved zeros (24 bytes total).
    static func record(profile: Int, level: Int, rpu: Bool = true, el: Bool = false, bl: Bool = true, compat: Int) -> Data {
        var b = [UInt8](repeating: 0, count: 24)
        b[0] = 1; b[1] = 0
        let bits = (profile << 9) | (level << 3) | ((rpu ? 1 : 0) << 2) | ((el ? 1 : 0) << 1) | (bl ? 1 : 0)
        b[2] = UInt8((bits >> 8) & 0xFF); b[3] = UInt8(bits & 0xFF)
        b[4] = UInt8(compat << 4)
        return Data(b)
    }

    @Test func parsesIPhoneProfile84() throws {
        let c = try #require(CodecConfig.dolbyVision(Self.record(profile: 8, level: 7, compat: 4)))
        #expect(c == DolbyVisionConfig(profile: 8, level: 7, hasRPU: true, hasEnhancementLayer: false, hasBaseLayer: true,
                                       compatibilityID: 4))
        #expect(c.baseLayerColorSpace == .hlgBT2020)
        #expect(CodecConfig.dolbyVision(Data([1, 0, 0])) == nil)
    }

    @Test func baseLayerTable() {
        func space(_ p: Int, _ id: Int) -> ColorSpaceID? {
            DolbyVisionConfig(profile: p, level: 6, hasRPU: true, hasEnhancementLayer: false, hasBaseLayer: true,
                              compatibilityID: id).baseLayerColorSpace
        }
        #expect(space(8, 4) == .hlgBT2020)   // 8.4: iPhone
        #expect(space(8, 1) == .pqBT2020)    // 8.1: HDR10 base
        #expect(space(8, 6) == .pqBT2020)    // 8.6: BT.2100 PQ
        #expect(space(8, 2) == .rec709)      // 8.2: SDR base
        #expect(space(5, 0) == nil)          // 5: IPTPQc2, no displayable base layer
        #expect(space(8, 0) == nil)
    }

    @Test func dolbyVisionSampleEntriesReadHEVCBitDepth() {
        // hvcC with general_chroma_format_idc 1 (4:2:0) and bit_depth_luma_minus8 = 2 (10 bit).
        var h = [UInt8](repeating: 0, count: 23)
        h[16] = 0xFC | 1; h[17] = 0xF8 | 2
        let ext: [String: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: ["hvcC": Data(h)]]
        for sub in ["hvc1", "hev1", "dvh1", "dvhe"] {
            let code = sub.utf8.reduce(FourCharCode(0)) { $0 << 8 | FourCharCode($1) }
            let (chroma, depth) = MediaImporter.chromaAndDepth(subType: code, extensions: ext)
            #expect(chroma == "4:2:0" && depth == 10, "\(sub)")
        }
    }

    @Test func detectionUsesDolbyVisionWhenTagsAreMissing() {
        let dv84 = DolbyVisionConfig(profile: 8, level: 7, hasRPU: true, hasEnhancementLayer: false, hasBaseLayer: true, compatibilityID: 4)
        let dv81 = DolbyVisionConfig(profile: 8, level: 7, hasRPU: true, hasEnhancementLayer: false, hasBaseLayer: true, compatibilityID: 1)
        // iPhone writes HLG tags too: tags and DV agree.
        #expect(ColorDetection.detect(colorPrimaries: "ITU_R_2020", transfer: "ITU_R_2100_HLG", sony: nil, dolbyVision: dv84) == .hlgBT2020)
        // Remuxed file that lost the colr atom: the DV record still says HLG.
        #expect(ColorDetection.detect(colorPrimaries: nil, transfer: nil, sony: nil, dolbyVision: dv84) == .hlgBT2020)
        #expect(ColorDetection.detect(colorPrimaries: "ITU_R_709_2", transfer: "ITU_R_709_2", sony: nil, dolbyVision: dv81) == .pqBT2020)
        // Explicit HDR tags win over the record.
        #expect(ColorDetection.detect(colorPrimaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", sony: nil, dolbyVision: dv84) == .pqBT2020)
    }

    @Test func dolbyVisionFromFormatDescriptionAtoms() throws {
        for key in ["dvvC", "dvcC", "dvwC"] {
            let atoms: [String: Any] = [key: Self.record(profile: 8, level: 5, compat: 4)]
            let ext: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms]
            var fd: CMVideoFormatDescription?
            #expect(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_HEVC, width: 1920, height: 1080,
                                                   extensions: ext as CFDictionary, formatDescriptionOut: &fd) == 0)
            let f = try #require(fd)
            #expect(ColorDetection.dolbyVision(of: f)?.compatibilityID == 4, "\(key)")
            #expect(ColorDetection.detect(formatDescription: f, sony: nil) == .hlgBT2020, "\(key)")
        }
    }
}
