import Foundation
import SQCore
import Testing
@testable import SQMedia

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }

private func box(_ type: String, _ payload: Data) -> Data {
    Data(be32(UInt32(8 + payload.count)) + Array(type.utf8)) + payload
}

/// Canon maker notes as in `CMT3`: TIFF header, a directory with a filler tag and the log settings (tag 0x4026).
private func makerNotes(curve: Int32, gamut: Int32, little: Bool = true, type: UInt16 = 9, entries: Int = 12,
                        withLogInfo: Bool = true) -> Data {
    func u16(_ v: UInt16) -> [UInt8] { little ? [UInt8(v & 255), UInt8(v >> 8)] : [UInt8(v >> 8), UInt8(v & 255)] }
    func u32(_ v: UInt32) -> [UInt8] { little ? be32(v).reversed() : be32(v) }
    var values = [Int32](repeating: 0, count: max(entries, 12))
    values[0] = Int32(entries * 4); values[9] = gamut; values[11] = curve
    var d = (little ? [0x49, 0x49] : [0x4D, 0x4D]) + u16(42) + u32(8)
    let tags = withLogInfo ? 2 : 1
    let dataAt = UInt32(8 + 2 + tags * 12 + 4)
    d += u16(UInt16(tags))
    d += u16(0x0010) + u16(4) + u32(1) + u32(0x8000_0453)                // model id, inline
    if withLogInfo { d += u16(0x4026) + u16(type) + u32(UInt32(entries)) + u32(dataAt) }
    d += u32(0)
    for v in values.prefix(entries) { d += u32(UInt32(bitPattern: v)) }
    return Data(d)
}

private let canonUUID: [UInt8] = [0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0, 0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48]

private func canonMP4(_ notes: Data?, uuid: [UInt8] = canonUUID) -> Data {
    var inner = box("CNCV", Data("CanonAVC0001".utf8)) + box("CMT1", Data(count: 16))
    if let notes { inner += box("CMT3", notes) }
    let moov = box("mvhd", Data(count: 100)) + box("uuid", Data(uuid) + inner) + box("trak", Data(count: 32))
    return box("ftyp", Data("isom0000".utf8)) + box("mdat", Data(count: 64)) + box("moov", moov)
}

private func tempDir() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("canon-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct CanonMetadataTests {
    @Test func everyCurveAndGamutFromTheMakerNotes() {
        let expected: [[ColorSpaceID]] = [
            [.canonLogBT709, .canonLogBT2020, .canonLogCinemaGamut],
            [.canonLog2BT709, .canonLog2BT2020, .canonLog2CinemaGamut],
            [.canonLog3BT709, .canonLog3BT2020, .canonLog3CinemaGamut],
        ]
        for curve in 1...3 {
            for gamut in 0...2 {
                for little in [true, false] {
                    let m = CanonMetadata(makerNotes: makerNotes(curve: Int32(curve), gamut: Int32(gamut), little: little))
                    #expect(m?.colorSpace == expected[curve - 1][gamut], "curve \(curve) gamut \(gamut)")
                }
            }
        }
        #expect(CanonMetadata(makerNotes: makerNotes(curve: 3, gamut: 2, type: 4))?.colorSpace == .canonLog3CinemaGamut)
    }

    @Test func nothingWhenLogIsOffOrAValueIsOpen() {
        #expect(CanonMetadata(makerNotes: makerNotes(curve: 0, gamut: 2))?.colorSpace == nil)             // Canon Log off
        #expect(CanonMetadata(makerNotes: makerNotes(curve: 0x7fff_ffff, gamut: 2))?.colorSpace == nil)   // undefined
        #expect(CanonMetadata(makerNotes: makerNotes(curve: 3, gamut: 0x7fff_ffff))?.colorSpace == nil)   // gamut undefined
        #expect(CanonMetadata(makerNotes: makerNotes(curve: 4, gamut: 2))?.colorSpace == nil)             // unknown curve
        #expect(CanonMetadata(makerNotes: makerNotes(curve: 3, gamut: 3))?.colorSpace == nil)             // unknown gamut
        #expect(CanonMetadata(makerNotes: makerNotes(curve: -1, gamut: -1))?.colorSpace == nil)
    }

    @Test func damagedMakerNotesGiveNothing() {
        let good = makerNotes(curve: 3, gamut: 2)
        #expect(CanonMetadata(makerNotes: Data()) == nil)
        #expect(CanonMetadata(makerNotes: Data("not a tiff header".utf8)) == nil)
        #expect(CanonMetadata(makerNotes: makerNotes(curve: 3, gamut: 2, withLogInfo: false)) == nil)
        #expect(CanonMetadata(makerNotes: makerNotes(curve: 3, gamut: 2, entries: 10)) == nil, "block ends before the curve")
        #expect(CanonMetadata(makerNotes: makerNotes(curve: 3, gamut: 2, type: 3)) == nil, "not 32-bit values")
        for cut in 0..<good.count { _ = CanonMetadata(makerNotes: good.prefix(cut)) }                     // never traps
        #expect(CanonMetadata(makerNotes: good.prefix(good.count - 4)) == nil)
        var far = [UInt8](good); far[4] = 0xFF; far[5] = 0xFF; far[6] = 0xFF; far[7] = 0x7F               // directory offset out of range
        #expect(CanonMetadata(makerNotes: Data(far)) == nil)
    }

    @Test func readFromAnMP4InOneWalk() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        func camera(_ data: Data, _ name: String) throws -> (sony: SonyMetadata?, canon: CanonMetadata?) {
            let f = dir.appendingPathComponent(name)
            try data.write(to: f)
            return CameraMetadata.read(forClip: f)
        }
        let log3 = try camera(canonMP4(makerNotes(curve: 3, gamut: 2)), "MVI_0001.MP4")
        #expect(log3.canon?.colorSpace == .canonLog3CinemaGamut)
        #expect(log3.sony == nil)
        #expect(try camera(canonMP4(makerNotes(curve: 1, gamut: 0)), "MVI_0002.MP4").canon?.colorSpace == .canonLogBT709)
        #expect(try camera(canonMP4(makerNotes(curve: 0, gamut: 0)), "MVI_0003.MP4").canon?.colorSpace == nil)
        #expect(try camera(canonMP4(nil), "MVI_0004.MP4").canon == nil)
        var other = canonUUID; other[0] = 0x86
        #expect(try camera(canonMP4(makerNotes(curve: 3, gamut: 2), uuid: other), "MVI_0005.MP4").canon == nil, "another vendor's uuid box")
        #expect(try camera(box("ftyp", Data("isom0000".utf8)) + box("moov", box("mvhd", Data(count: 100))), "plain.mp4").canon == nil)
        // A truncated file ends the walk without an error.
        #expect(try camera(canonMP4(makerNotes(curve: 3, gamut: 2)).dropLast(30), "cut.mp4").canon == nil)
    }

    @Test func detectionOrder() {
        let log3 = CanonMetadata(curve: .log3, gamut: .cinemaGamut)
        #expect(ColorDetection.detect(colorPrimaries: "ITU_R_709_2", transfer: "ITU_R_709_2", sony: nil, canon: log3) == .canonLog3CinemaGamut)
        #expect(ColorDetection.detect(colorPrimaries: nil, transfer: nil, sony: nil, canon: log3) == .canonLog3CinemaGamut)
        // An explicit HDR tag wins; metadata without both values changes nothing.
        #expect(ColorDetection.detect(colorPrimaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", sony: nil, canon: log3) == .pqBT2020)
        #expect(ColorDetection.detect(colorPrimaries: "ITU_R_2020", transfer: "ITU_R_2100_HLG", sony: nil, canon: log3) == .hlgBT2020)
        #expect(ColorDetection.detect(colorPrimaries: nil, transfer: nil, sony: nil, canon: CanonMetadata(curve: .log3, gamut: nil)) == .rec709)
        #expect(ColorDetection.detect(colorPrimaries: nil, transfer: nil, sony: nil, canon: CanonMetadata(curve: nil, gamut: .cinemaGamut)) == .rec709)
        #expect(ColorDetection.detect(colorPrimaries: nil, transfer: nil, sony: nil, canon: nil) == .rec709)
    }

    @Test func theClipChoiceStillWins() {
        let detected = CanonMetadata(curve: .log2, gamut: .cinemaGamut).colorSpace
        #expect(ColorSpaceID.effective(clip: nil, detected: detected, tagged: false, projectDefault: nil) == .canonLog2CinemaGamut)
        #expect(ColorSpaceID.effective(clip: .rec709, detected: detected, tagged: false, projectDefault: nil) == .rec709)
    }

    // MARK: sidecar

    private func xml(_ body: String, root: String = "ClipInfo xmlns=\"http://www.canon.com/ns/VideoClip\"") -> Data {
        let name = root.split(separator: " ").first.map(String.init) ?? root
        return Data("<?xml version=\"1.0\"?><\(root)><Device manufacturer=\"Canon\" model=\"EOS C70\"/>\(body)</\(name)>".utf8)
    }

    @Test func sidecarValuesMustSitUnderACanonElement() {
        let values = "<Gamma>Canon Log 3</Gamma><ColorSpace>Cinema Gamut</ColorSpace>"
        // Canon by namespace (default or prefixed) or by element name.
        #expect(CanonMetadata(xml: xml(values))?.colorSpace == .canonLog3CinemaGamut)
        #expect(CanonMetadata(xml: xml(values, root: "c:Clip xmlns:c=\"urn:schemas-canon:clip\""))?.colorSpace == .canonLog3CinemaGamut)
        #expect(CanonMetadata(xml: xml("<Wrap>\(values)</Wrap>", root: "CanonClipMetadata"))?.colorSpace == .canonLog3CinemaGamut)
        // Another vendor's or an unrelated XML that only mentions Canon: nothing.
        #expect(CanonMetadata(xml: xml(values, root: "ClipInfo")) == nil)
        #expect(CanonMetadata(xml: xml(values, root: "NonRealTimeMeta xmlns=\"urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20\"")) == nil)
        #expect(CanonMetadata(xml: Data("<Notes><Text>shot on canon</Text><Curve>Canon Log 3</Curve><Space>Rec709</Space></Notes>".utf8)) == nil)
        #expect(CanonMetadata(xml: Data("<Notes><Text>canon</Text><Space>Rec709</Space></Notes>".utf8)) == nil)
        // Values next to, not under, the Canon element do not count.
        #expect(CanonMetadata(xml: Data("<Clip><CanonInfo/>\(values)</Clip>".utf8)) == nil)
        #expect(CanonMetadata(xml: Data("<Clip><CanonInfo><Gamma>Canon Log 3</Gamma></CanonInfo><ColorSpace>Cinema Gamut</ColorSpace></Clip>".utf8))?.colorSpace == nil)
    }

    @Test func oversizedSidecarIsNeverLoaded() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let values = "<Gamma>Canon Log 3</Gamma><ColorSpace>Cinema Gamut</ColorSpace>"
        let padding = "<!--" + String(repeating: "x", count: CameraMetadata.maxSidecarBytes) + "-->"
        // Canon sidecar next to an MXF clip.
        let clip = dir.appendingPathComponent("A001.MXF"), side = dir.appendingPathComponent("A001.XML")
        try Data(count: 64).write(to: clip)
        try xml(values).write(to: side)
        #expect(CameraMetadata.sidecarData(side) != nil)
        #expect(CameraMetadata.read(forClip: clip, boxes: false).canon?.colorSpace == .canonLog3CinemaGamut)
        try xml(values + padding).write(to: side)
        #expect(CameraMetadata.sidecarData(side) == nil)
        #expect(CameraMetadata.read(forClip: clip, boxes: false).canon == nil)
        // Sony sidecar: same limit.
        let sonyClip = dir.appendingPathComponent("C0001.MP4"), sonySide = dir.appendingPathComponent("C0001M01.XML")
        try Data(count: 64).write(to: sonyClip)
        let item = "<Item name=\"CaptureGammaEquation\" value=\"s-log3-cine\"/>"
        try Data("<NonRealTimeMeta>\(item)</NonRealTimeMeta>".utf8).write(to: sonySide)
        #expect(CameraMetadata.read(forClip: sonyClip).sony?.captureGamma == "s-log3-cine")
        try Data("<NonRealTimeMeta>\(item)\(padding)</NonRealTimeMeta>".utf8).write(to: sonySide)
        #expect(CameraMetadata.read(forClip: sonyClip).sony == nil)
        #expect(try SonyMetadata.read(forClip: sonyClip) == nil)
    }

    @Test func sidecarValues() {
        #expect(CanonMetadata(xml: xml("<Gamma>Canon Log 3</Gamma><ColorSpace>Cinema Gamut</ColorSpace>"))?.colorSpace == .canonLog3CinemaGamut)
        #expect(CanonMetadata(xml: xml("<Item name=\"Gamma\" value=\"C-Log2\"/><Item name=\"Gamut\" value=\"BT.2020\"/>"))?.colorSpace == .canonLog2BT2020)
        #expect(CanonMetadata(xml: xml("<Gamma> Canon Log </Gamma><ColorSpace>BT.709</ColorSpace>"))?.colorSpace == .canonLogBT709)
        // Curve without a gamut, two curves, two gamuts, a name inside a longer value, no Canon: nothing preselected.
        #expect(CanonMetadata(xml: xml("<Gamma>Canon Log 3</Gamma>"))?.colorSpace == nil)
        #expect(CanonMetadata(xml: xml("<Gamma>Canon Log 3</Gamma><Look>Canon Log 2</Look><ColorSpace>Cinema Gamut</ColorSpace>")) == nil)
        #expect(CanonMetadata(xml: xml("<Gamma>Canon Log 3</Gamma><ColorSpace>Cinema Gamut</ColorSpace><View>BT.709</View>"))?.colorSpace == nil)
        #expect(CanonMetadata(xml: xml("<Note>Canon Log 3 to BT.709 LUT</Note><ColorSpace>Cinema Gamut</ColorSpace>")) == nil)
        #expect(CanonMetadata(xml: xml("<Gamma>Wide DR</Gamma><ColorSpace>BT.709</ColorSpace>")) == nil)
        #expect(CanonMetadata(xml: Data("<Clip><Gamma>C-Log3</Gamma><ColorSpace>Cinema Gamut</ColorSpace></Clip>".utf8)) == nil)
        #expect(CanonMetadata(xml: Data("<Canon><Gamma>".utf8)) == nil)
    }

    @Test func sidecarNextToAnMXFClip() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appendingPathComponent("A001C001_CANON.MXF")
        try Data(count: 64).write(to: clip)
        #expect(CameraMetadata.read(forClip: clip, boxes: false).canon == nil)
        try xml("<Gamma>Canon Log 2</Gamma><ColorSpace>Cinema Gamut</ColorSpace>").write(to: dir.appendingPathComponent("A001C001_CANON.XML"))
        let found = CameraMetadata.read(forClip: clip, boxes: false)
        #expect(found.canon?.colorSpace == .canonLog2CinemaGamut)
        #expect(found.sony == nil)
    }
}
