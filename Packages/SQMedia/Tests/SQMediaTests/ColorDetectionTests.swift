import CoreMedia
import Foundation
import Testing
import SQCore
@testable import SQMedia

private func sony(gamma: String, primaries: String) throws -> SonyMetadata {
    try SonyMetadata(xml: Data("""
    <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
    <AcquisitionRecord><Group name="CameraUnitMetadataSet">
    <Item name="CaptureGammaEquation" value="\(gamma)"/>
    <Item name="CaptureColorPrimaries" value="\(primaries)"/>
    </Group></AcquisitionRecord></NonRealTimeMeta>
    """.utf8))
}

@Suite struct ColorDetectionTests {
    @Test func detectionTable() throws {
        let slog = try sony(gamma: "s-log3-cine", primaries: "s-gamut3-cine")
        let other = try sony(gamma: "rec709", primaries: "rec709")
        let rows: [(String?, String?, SonyMetadata?, ColorSpaceID)] = [
            (nil, nil, nil, .rec709),                                        // untagged
            ("ITU_R_709_2", "ITU_R_709_2", nil, .rec709),
            ("ITU_R_2020", "ITU_R_2100_HLG", nil, .hlgBT2020),               // iPhone HLG
            ("ITU_R_2020", "SMPTE_ST_2084_PQ", nil, .pqBT2020),              // PQ / HDR10 (W9.3)
            (nil, "SMPTE_ST_2084_PQ", nil, .pqBT2020),
            ("ITU_R_2020", "AppleLog", nil, .appleLog),
            ("ITU_R_2020", "com.apple.log", nil, .appleLog),                 // CoreMedia LogTransferFunction value
            ("ITU_R_2020", "SMPTE_ST_2084_PQ", slog, .pqBT2020),             // tags win over the Sony XML
            ("ITU_R_709_2", "ITU_R_2100_HLG", nil, .hlgBT2020),              // HLG transfer alone is enough
            ("P3_D65", "ITU_R_2100_HLG", nil, .hlgBT2020),
            (nil, "ITU_R_2100_HLG", nil, .hlgBT2020),
            (nil, nil, slog, .sLog3SGamut3Cine),                             // Sony, untagged
            (nil, nil, other, .rec709),
            ("ITU_R_2020", "ITU_R_2100_HLG", slog, .hlgBT2020),              // tags win
        ]
        for (p, t, s, expected) in rows {
            #expect(ColorDetection.detect(colorPrimaries: p, transfer: t, sony: s) == expected)
        }
    }

    private func fd(primaries: CFString? = nil, transfer: CFString? = nil, matrix: CFString? = nil, log: CFString? = nil) throws -> CMFormatDescription {
        var ext: [CFString: Any] = [:]
        if let primaries { ext[kCMFormatDescriptionExtension_ColorPrimaries] = primaries }
        if let transfer { ext[kCMFormatDescriptionExtension_TransferFunction] = transfer }
        if let matrix { ext[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix }
        if let log { ext[kCMFormatDescriptionExtension_LogTransferFunction] = log }
        var out: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_HEVC, width: 1920, height: 1080,
                                                extensions: ext as CFDictionary, formatDescriptionOut: &out)
        #expect(st == 0)
        return try #require(out)
    }

    /// Real CoreMedia constants through a synthetic format description (no media file needed).
    @Test func formatDescriptionTags() throws {
        let hlg = try fd(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020, transfer: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
                         matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
        let pq = try fd(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020, transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
        let r709 = try fd(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2, transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                          matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
        let r2020 = try fd(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020, transfer: kCMFormatDescriptionTransferFunction_ITU_R_2020)
        // iPhone Apple Log: regular Rec.2020 tags plus the separate LogTransferFunction key.
        let appleLog = try fd(primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020, transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
                              matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, log: kCMFormatDescriptionLogTransferFunction_AppleLog)
        let unknown = try fd(primaries: "SomeFutureCurve" as CFString, transfer: "SomeFutureCurve" as CFString)
        let untagged = try fd()
        #expect(ColorDetection.detect(formatDescription: hlg, sony: nil) == .hlgBT2020)
        #expect(ColorDetection.detect(formatDescription: pq, sony: nil) == .pqBT2020)
        #expect(ColorDetection.detect(formatDescription: r709, sony: nil) == .rec709)
        #expect(ColorDetection.detect(formatDescription: r2020, sony: nil) == .rec709)   // SDR Rec.2020: no own space, treated as Rec.709 gamma
        #expect(ColorDetection.detect(formatDescription: appleLog, sony: nil) == .appleLog)
        #expect(ColorDetection.detect(formatDescription: unknown, sony: nil) == .rec709)
        #expect(ColorDetection.detect(formatDescription: untagged, sony: nil) == .rec709)
        #expect(ColorDetection.transferTag(of: appleLog) == kCMFormatDescriptionLogTransferFunction_AppleLog as String)
        #expect(ColorDetection.transferTag(of: untagged) == nil)
    }

    @Test func untaggedSonyStillDetected() throws {
        let slog = try sony(gamma: "s-log3-cine", primaries: "s-gamut3-cine")
        #expect(ColorDetection.detect(formatDescription: try fd(), sony: slog) == .sLog3SGamut3Cine)
    }
}
