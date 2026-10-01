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
            ("ITU_R_2020", "SMPTE_ST_2084_PQ", nil, .rec709),                // PQ/HDR10 not supported in V1: falls back
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
}
