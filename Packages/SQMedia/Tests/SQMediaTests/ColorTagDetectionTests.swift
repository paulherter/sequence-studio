import Foundation
import SQCore
import Testing
@testable import SQMedia

private let sonyXML = """
<?xml version="1.0" encoding="UTF-8"?>
<NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20">
<Device manufacturer="Sony" modelName="ZV-E1"/>
<AcquisitionRecord><Group name="CameraUnitMetadataSet">
<Item name="CaptureGammaEquation" value="s-log3-cine"/>
<Item name="CaptureColorPrimaries" value="s-gamut3-cine"/>
</Group></AcquisitionRecord>
</NonRealTimeMeta>
"""

@Suite struct ColorTagDetectionTests {
    @Test func transferTagsDecide() {
        #expect(ColorTagDetection.detect(colorPrimaries: "ITU_R_2020", transfer: "ITU_R_2100_HLG", sony: nil) == .hlgBT2020)
        #expect(ColorTagDetection.detect(colorPrimaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", sony: nil) == .pqBT2020)
        #expect(ColorTagDetection.detect(colorPrimaries: nil, transfer: nil, sony: nil) == .rec709)
    }

    @Test func untaggedSonyClipIsSLog3() throws {
        let sony = try SonyMetadata(xml: Data(sonyXML.utf8))
        #expect(ColorTagDetection.detect(colorPrimaries: nil, transfer: nil, sony: sony) == .sLog3SGamut3Cine)
    }

    @Test func sidecarBesideTheClipIsRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-colortag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("C0001.MP4")
        try Data(count: 64).write(to: clip)
        try Data(sonyXML.utf8).write(to: dir.appendingPathComponent("C0001M01.XML"))
        let found = ColorTagDetection.detect(url: clip, colorPrimaries: nil, transfer: nil)
        #expect(found.space == .sLog3SGamut3Cine)
    }
}
