import Foundation
import Testing
@testable import SSMedia

private let fixtureXML = """
<?xml version="1.0" encoding="UTF-8"?>
<NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20" lastUpdate="2026-01-01T00:00:00+01:00">
<Device manufacturer="Sony" modelName="ZV-E1"/>
<AcquisitionRecord><Group name="CameraUnitMetadataSet">
<Item name="CaptureGammaEquation" value="s-log3-cine"/>
<Item name="CaptureColorPrimaries" value="s-gamut3-cine"/>
<Item name="CodingEquations" value="rec709"/>
</Group></AcquisitionRecord>
<RelevantFiles><RelatedTo file="Look.cube" rel="LUT"/></RelevantFiles>
</NonRealTimeMeta>
"""

private func box(_ type: String, _ payload: Data, large: Bool = false) -> Data {
    var d = Data()
    func be32(_ v: UInt32) { d.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]) }
    if large {
        be32(1); d.append(contentsOf: Array(type.utf8))
        let n = UInt64(16 + payload.count)
        be32(UInt32(n >> 32)); be32(UInt32(n & 0xFFFF_FFFF))
    } else {
        be32(UInt32(8 + payload.count)); d.append(contentsOf: Array(type.utf8))
    }
    d.append(payload)
    return d
}

private func fakeMP4(xml: String?, large: Bool = false) -> Data {
    var d = box("ftyp", Data("isom0000".utf8))
    d.append(box("mdat", Data(repeating: 0, count: 64), large: large))
    if let xml {
        let xmlBox = box("xml ", Data(count: 4) + Data(xml.utf8), large: large)
        d.append(box("meta", Data(count: 4) + box("hdlr", Data(count: 8)) + xmlBox, large: large))
    }
    return d
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sony-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct SonyMetadataTests {
    @Test func parsesFixture() throws {
        let m = try SonyMetadata(xml: Data(fixtureXML.utf8))
        #expect(m.captureGamma == "s-log3-cine")
        #expect(m.captureColorPrimaries == "s-gamut3-cine")
        #expect(m.codingEquations == "rec709")
        #expect(m.modelName == "ZV-E1")
        #expect(m.relatedLUTFile == "Look.cube")
        #expect(m.isSLog3SGamut3Cine)
    }

    @Test func missingItems() throws {
        let m = try SonyMetadata(xml: Data("<NonRealTimeMeta/>".utf8))
        #expect(m.captureGamma == nil && m.modelName == nil && m.relatedLUTFile == nil)
        #expect(!m.isSLog3SGamut3Cine)
    }

    @Test func malformedThrows() {
        #expect(throws: (any Error).self) { try SonyMetadata(xml: Data("<a><b></a>".utf8)) }
    }

    @Test func embeddedRead() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for large in [false, true] {
            let f = dir.appendingPathComponent("A\(large).MP4")
            try fakeMP4(xml: fixtureXML, large: large).write(to: f)
            #expect(try SonyMetadata.read(forClip: f)?.isSLog3SGamut3Cine == true)
        }
    }

    @Test func noMetaIsNil() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("B.MP4")
        try fakeMP4(xml: nil).write(to: f)
        #expect(try SonyMetadata.read(forClip: f) == nil)
    }

    @Test func sidecarWins() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("C0001.MP4")
        try fakeMP4(xml: fixtureXML).write(to: f)
        let side = fixtureXML.replacingOccurrences(of: "s-log3-cine", with: "rec709")
        try Data(side.utf8).write(to: dir.appendingPathComponent("C0001M01.xml"))
        #expect(try SonyMetadata.read(forClip: f)?.captureGamma == "rec709")
    }

    @Test func realFiles() throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Videos/iOS 27 Features #2")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        for n in 2157...2164 {
            let f = dir.appendingPathComponent("C\(n).MP4")
            guard FileManager.default.fileExists(atPath: f.path) else { continue }
            let t0 = ContinuousClock.now
            let m = try SonyMetadata.read(forClip: f)
            let dt = ContinuousClock.now - t0
            print("SonyMetadata C\(n): \(dt)")
            #expect(m?.captureGamma == "s-log3-cine")
            #expect(m?.captureColorPrimaries == "s-gamut3-cine")
            #expect(dt < .milliseconds(50))
        }
    }
}
