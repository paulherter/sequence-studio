import Foundation
import Testing
@testable import SQMedia

private func be(_ v: UInt64, _ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: v >> UInt64(8 * (n - 1 - $0))) }) }

private func box(_ type: String, _ payload: Data) -> Data {
    be(UInt64(8 + payload.count), 4) + Data(type.utf8) + payload
}

private func cstr(_ s: String) -> Data { Data(s.utf8) + Data([0]) }

/// Sony-style item list: infe v0 (id, protection, name, content type), iloc v1, construction_method 1 into `idat`.
private func metaBox(items: [(name: String, bytes: Data)], infeVersion: UInt8 = 0, ilocMethod: Int = 1,
                     baseOffset: UInt64 = 0, nested: Bool = false) -> Data {
    var infes = Data()
    for (i, it) in items.enumerated() {
        var p = Data([infeVersion, 0, 0, 0])
        if infeVersion >= 2 {
            p += be(UInt64(i + 1), 2) + be(0, 2) + Data("mime".utf8) + cstr(it.name) + cstr("application/octet-stream")
        } else {
            p += be(UInt64(i + 1), 2) + be(0, 2) + cstr(it.name) + cstr("application/octet-stream")
        }
        infes += box("infe", p)
    }
    let iinf = box("iinf", Data([0, 0, 0, 0]) + be(UInt64(items.count), 2) + infes)

    var idat = Data()
    var iloc = Data([1, 0, 0, 0, 0x44, 0x40]) + be(UInt64(items.count), 2)  // offset 4, length 4, base 4, index 0
    let idatPrefix: UInt64 = baseOffset
    idat += Data(count: Int(idatPrefix))
    for (i, it) in items.enumerated() {
        iloc += be(UInt64(i + 1), 2) + be(UInt64(ilocMethod), 2) + be(0, 2)
        iloc += be(ilocMethod == 1 ? baseOffset : 0, 4) + be(1, 2)
        iloc += be(UInt64(idat.count) - (ilocMethod == 1 ? idatPrefix : 0), 4) + be(UInt64(it.bytes.count), 4)
        idat += it.bytes
    }
    let hdlr = box("hdlr", Data(count: 8) + Data("nrtm".utf8) + Data(count: 12) + cstr("Non-Real Time Metadata"))
    return box("meta", Data([0, 0, 0, 0]) + hdlr + iinf + box("iloc", iloc) + box("idat", idat))
}

private func mp4(meta: Data, insideMoov: Bool = false) -> Data {
    var d = box("ftyp", Data("isom0000".utf8)) + box("mdat", Data(repeating: 7, count: 100))
    d += insideMoov ? box("moov", box("mvhd", Data(count: 4)) + meta) : meta
    return d
}

private let cubeText = Data("""
# comment
TITLE "Look"
LUT_3D_SIZE 2
0 0 0
1 0 0
0 1 0
1 1 0
0 0 1
1 0 1
0 1 1
1 1 1

""".utf8)

/// Builds an item in Sony's "ELUT" + "SONYBCUB" layout with an N^3 identity-ish LUT (red fastest, big-endian f32).
private func sonyItem(size n: Int, name: String) -> Data {
    let dataOffset = 3328
    var blob = Data("SONYBCUB".utf8) + Data(count: dataOffset - 8)
    func put(_ v: UInt32, at o: Int) { blob.replaceSubrange(o..<(o + 4), with: be(UInt64(v), 4)) }
    put(0x0100_0000, at: 8)
    put(UInt32(dataOffset + n * n * n * 12), at: 12)
    put(UInt32(n), at: 128)
    put(UInt32(dataOffset), at: 136)
    put(UInt32(n * n * n * 12), at: 140)
    put(Float(1).bitPattern, at: 156); put(Float(1).bitPattern, at: 160); put(Float(1).bitPattern, at: 164)
    blob.replaceSubrange(256..<(256 + name.utf8.count), with: Data(name.utf8))
    for b in 0..<n { for g in 0..<n { for r in 0..<n {
        for c in [r, g, b] { blob += be(UInt64(Float(Double(c) / Double(n - 1)).bitPattern), 4) }
    } } }
    return Data("ELUT".utf8) + Data(count: 9) + blob
}

@Suite("EmbeddedLUT") struct EmbeddedLUTTests {
    @Test func listsItemsWithNamesAndSizes() throws {
        let file = mp4(meta: metaBox(items: [("Look Control data", cubeText), ("Lens profile", Data(repeating: 9, count: 33))]))
        let items = try EmbeddedMeta.items(inData: file)
        #expect(items.map(\.name) == ["Look Control data", "Lens profile"])
        #expect(items.map(\.length) == [UInt64(cubeText.count), 33])
        #expect(items.allSatisfy { $0.constructionMethod == 1 && $0.contentType == "application/octet-stream" })
        let read = EmbeddedMeta.dataReader(file)
        #expect(try EmbeddedMeta.data(of: items[0], read: read) == cubeText)
        #expect(try EmbeddedMeta.data(of: items[1], read: read) == Data(repeating: 9, count: 33))
    }

    @Test func extractsCubeText() throws {
        let file = mp4(meta: metaBox(items: [("Lens profile", Data(repeating: 1, count: 50)), ("Look Control data", cubeText)]))
        let lut = try #require(try EmbeddedMeta.lut(inData: file))
        #expect(lut.data == cubeText)
        #expect(lut.name == "Look")
        #expect(lut.sourceItemName == "Look Control data")
    }

    @Test func metaInsideMoovAndBaseOffset() throws {
        let file = mp4(meta: metaBox(items: [("LUT", cubeText)], baseOffset: 5), insideMoov: true)
        let lut = try #require(try EmbeddedMeta.lut(inData: file))
        #expect(lut.data == cubeText)
    }

    @Test func infeVersion2() throws {
        let file = mp4(meta: metaBox(items: [("x", cubeText)], infeVersion: 2))
        let items = try EmbeddedMeta.items(inData: file)
        #expect(items.first?.itemType == "mime")
        #expect(items.first?.name == "x")
        #expect(try EmbeddedMeta.lut(inData: file)?.data == cubeText)
    }

    @Test func absoluteOffsetsMethodZero() throws {
        // Method 0: offsets are file offsets. Put the bytes in mdat and point iloc at them.
        let payload = cubeText
        var d = box("ftyp", Data("isom0000".utf8))
        let payloadOffset = UInt64(d.count + 8)
        d += box("mdat", payload)
        let infe = box("infe", Data([0, 0, 0, 0]) + be(1, 2) + be(0, 2) + cstr("Look") + cstr("application/octet-stream"))
        let iinf = box("iinf", Data([0, 0, 0, 0]) + be(1, 2) + infe)
        let iloc = box("iloc", Data([1, 0, 0, 0, 0x44, 0x00]) + be(1, 2) + be(1, 2) + be(0, 2) + be(0, 2)
                       + be(1, 2) + be(payloadOffset, 4) + be(UInt64(payload.count), 4))
        d += box("meta", Data([0, 0, 0, 0]) + iinf + iloc)
        let items = try EmbeddedMeta.items(inData: d)
        #expect(items.first?.constructionMethod == 0)
        #expect(items.first?.fileOffset == payloadOffset)
        #expect(try EmbeddedMeta.lut(inData: d)?.data == payload)
    }

    @Test func noMetaOrNoLUT() throws {
        #expect(try EmbeddedMeta.items(inData: box("ftyp", Data("isom0000".utf8))).isEmpty)
        let file = mp4(meta: metaBox(items: [("Lens profile", Data(repeating: 9, count: 200))]))
        #expect(try EmbeddedMeta.lut(inData: file) == nil)
    }

    @Test func truncatedDataDoesNotCrash() throws {
        let file = mp4(meta: metaBox(items: [("Look", cubeText)]))
        for cut in stride(from: 40, to: file.count, by: 7) {
            _ = try? EmbeddedMeta.lut(inData: file.prefix(cut))
        }
    }

    @Test func cubeValidation() {
        #expect(EmbeddedMeta.looksLikeCube(cubeText))
        #expect(EmbeddedMeta.looksLikeCube(Data("LUT_3D_SIZE 33\n0 0 0\n".utf8)))
        #expect(!EmbeddedMeta.looksLikeCube(Data("hello world\n".utf8)))
        #expect(!EmbeddedMeta.looksLikeCube(Data([0x45, 0x4c, 0x55, 0x54, 0, 0, 1, 2])))
        #expect(!EmbeddedMeta.looksLikeCube(Data()))
    }

    @Test func sonyBinaryLookConvertsToCube() throws {
        let file = mp4(meta: metaBox(items: [("Look Control data", sonyItem(size: 3, name: "NeutralPaul.cube"))]))
        let lut = try #require(try EmbeddedMeta.lut(inData: file))
        #expect(lut.name == "NeutralPaul.cube")
        #expect(EmbeddedMeta.looksLikeCube(lut.data))
        let lines = String(decoding: lut.data, as: UTF8.self).split(separator: "\n")
        #expect(lines[1] == "LUT_3D_SIZE 3")
        #expect(lines.count == 4 + 27)
        #expect(lines[4] == "0.000000 0.000000 0.000000")
        #expect(lines[5] == "0.500000 0.000000 0.000000")  // red fastest
        #expect(lines.last == "1.000000 1.000000 1.000000")
    }

    @Test func realClipEmbeddedLUT() throws {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/Videos")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        var checked = 0
        var found: (URL, EmbeddedLUT, [EmbeddedItem])?
        for case let url as URL in en where url.pathExtension.lowercased() == "mp4" {
            checked += 1
            if checked > 400 { break }
            guard let meta = try? SonyMetadata.read(forClip: url), meta.relatedLUTFile != nil,
                  let items = try? EmbeddedMeta.items(inClip: url),
                  let lut = try? EmbeddedMeta.lut(inClip: url) else { continue }
            found = (url, lut, items)
            break
        }
        guard let (url, lut, items) = found else { return }  // no ZV-E1 clip with a look item: skip
        print("EmbeddedLUT real clip \(url.lastPathComponent): items \(items.map { "\($0.name) \($0.length) B" }), "
              + "LUT \(lut.name ?? "-") from '\(lut.sourceItemName)' \(lut.sourceItemBytes) B -> \(lut.data.count) B cube text")
        #expect(EmbeddedMeta.looksLikeCube(lut.data))
        let text = String(decoding: lut.data, as: UTF8.self)
        #expect(text.contains("LUT_3D_SIZE"))
        #expect(lut.sourceItemBytes > 100_000)
    }
}
