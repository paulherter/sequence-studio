import Testing
import Foundation
#if canImport(Compression)
import Compression
#endif
import SQCore
@testable import SQPremiereImport

/// Builds minimal ZIP archives in memory (stored or deflated entries, CRC left 0: the reader does not check it).
enum TestZip {
#if canImport(Compression)
    static func deflate(_ data: Data) -> Data {
        let cap = data.count + 1024
        var out = [UInt8](repeating: 0, count: cap)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&out, cap, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(out[..<n])
    }
#else
    /// Stored (uncompressed) deflate blocks: valid input for the reader, no Compression framework needed.
    static func deflate(_ data: Data) -> Data {
        var out = [UInt8](), i = 0
        repeat {
            let n = min(65535, data.count - i), last: UInt8 = i + n >= data.count ? 1 : 0
            out += [last, UInt8(n & 255), UInt8(n >> 8), UInt8(~n & 255), UInt8((~n >> 8) & 255)]
            out += data[(data.startIndex + i)..<(data.startIndex + i + n)]
            i += n
        } while i < data.count
        return Data(out)
    }
#endif

    /// gzip member around `data` (header, raw deflate, 8 trailer bytes: PRGzip skips CRC and size).
    static func gzip(_ data: Data) -> Data {
        Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0x13]) + deflate(data) + Data(repeating: 0, count: 8)
    }

    static func make(_ files: [(name: String, data: Data)], deflated: Bool = false) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
        var out = [UInt8](), central = [UInt8]()
        for f in files {
            let name = [UInt8](f.name.utf8)
            let body = deflated ? deflate(f.data) : f.data
            let method = deflated ? 8 : 0
            let offset = out.count
            let sizes = le32(0) + le32(body.count) + le32(f.data.count) + le16(name.count)
            out += [0x50, 0x4b, 3, 4] + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + sizes + le16(0) + name + [UInt8](body)
            central += [0x50, 0x4b, 1, 2] + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + sizes
                + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let cdOffset = out.count
        out += central
        out += [0x50, 0x4b, 5, 6] + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(cdOffset) + le16(0)
        return Data(out)
    }
}

@Suite struct MogrtImportTests {
    let S = PRFixture.second

    static func strDB(_ s: String) -> [String: Any] { ["strDB": [["localeString": "en_US", "str": s]]] }

    /// A definition.json with the keys seen in real templates (docs/ENGINE-NOTES.md "Motion Graphics Templates").
    static func definition(name: String, author: String?, controls: [[String: Any]] = [], seconds: Int = 5) -> Data {
        var d: [String: Any] = [
            "apiVersion": "1.8", "capsuleName": name, "capsuleNameLocalized": strDB(name), "clientControls": controls,
            "sourceInfoLocalized": ["en_US": ["duration": ["scale": 1, "value": seconds],
                                              "framesize": ["size": ["x": 1920, "y": 1080], "topleft": ["x": 0, "y": 0]]]],
            "usedFontsLocalized": ["en_US": ["Inter-Bold"]],
        ]
        if let author { d["authorApp"] = author }
        return try! JSONSerialization.data(withJSONObject: d)
    }

    static func textControl(_ name: String, _ value: String, id: String = "3") -> [String: Any] {
        ["id": id, "type": 6, "uiName": strDB(name), "value": strDB(value),
         "fonteditinfo": ["fontEditValue": "Inter-Bold", "fontSizeEditValue": 60]]
    }

    func textComponent(_ f: PRFixture, _ s: String, at pos: String = "0.3:0.8") -> String {
        f.component("AE.ADBE Text", [f.blobParam(1, base64: FlatBlob.premiereText(s, font: "Inter-Bold", size: 60, tracking: 0).base64EncodedString()),
                                     f.param(3, pos, kind: "PointComponentParam"), f.param(4, "100.")])
    }

    /// A template as Premiere writes it: definition.json, thumb.png and project.prgraphic (a zip around one gzip project).
    func package(_ f: PRFixture, definition: Data, deflated: Bool = true, thumb: Data? = Data([0x89, 0x50, 0x4e, 0x47])) -> Data {
        let graphic = TestZip.make([("lower third.prproj", deflated ? TestZip.gzip(f.data) : f.data)])
        var files: [(name: String, data: Data)] = [("project.prgraphic", graphic), ("definition.json", definition)]
        if let thumb { files.append(("thumb.png", thumb)) }
        return TestZip.make(files, deflated: deflated)
    }

    @Test func zipReaderReadsStoredAndDeflatedEntries() throws {
        let text = Data(String(repeating: "lower third ", count: 400).utf8)
        for deflated in [false, true] {
            let zip = try PRZip(TestZip.make([("a.txt", text), ("dir/b.bin", Data([1, 2, 3]))], deflated: deflated))
            #expect(zip.names == ["a.txt", "dir/b.bin"])
            #expect(try zip.data("a.txt") == text)
            #expect(try zip.data("dir/b.bin") == Data([1, 2, 3]))
            #expect(try zip.data("missing") == nil)
        }
        #expect(throws: PRImportError.corruptArchive) { try PRZip(Data("not a zip at all, just some text".utf8)) }
    }

    @Test func premiereTemplateBecomesATitleTemplateWithNamedTextSlot() throws {
        let f = PRFixture()
        f.sequence("Lower Third", width: 1920, height: 1080,
                   video: [f.track([f.item(start: 0, end: 5 * S, inPoint: 0, outPoint: 5 * S, source: .graphic,
                                           components: [textComponent(f, "Breaking News")], name: "Graphic")])])
        let slider: [String: Any] = ["id": "9", "type": 2, "uiName": Self.strDB("Bar Width"), "value": 40, "min": 0, "max": 100]
        let def = Self.definition(name: "News Lower Third", author: "ppro", controls: [Self.textControl("Headline", "Breaking News"), slider])
        let r = try MogrtImporter.read(data: package(f, definition: def), fileName: "file name")

        #expect(r.template.name == "News Lower Third")
        #expect(r.template.duration == Time(seconds: 5))
        #expect(r.template.layers.map(\.kind) == [.text])
        #expect(r.template.content.format.width == 1920 && r.template.content.format.height == 1080)
        let slot = try #require(r.template.slots.first)
        #expect(r.template.slots.count == 1 && slot.name == "Headline" && slot.kind == .text && slot.value == .text("Breaking News"))
        #expect(r.thumbnail == Data([0x89, 0x50, 0x4e, 0x47]))

        // The description: what the package said.
        let d = r.description
        #expect(d.definition.author == .premiere && d.definition.width == 1920 && d.definition.height == 1080)
        #expect(d.definition.duration == Time(seconds: 5) && d.definition.fonts == ["Inter-Bold"])
        #expect(d.definition.controls.map(\.kind) == [.text, .slider])
        #expect(d.definition.controls[0].value == .text("Breaking News") && d.definition.controls[0].fontName == "Inter-Bold")
        #expect(d.definition.controls[1].value == .number(40))
        #expect(d.textLayers.count == 1 && d.textLayers[0].text == "Breaking News" && d.textLayers[0].fontName == "Inter-Bold")
        #expect(d.textLayers[0].size == 60 && d.shapeLayerCount == 0)

        // The slider has no counterpart: dropped and counted.
        #expect(r.report.status(of: "Control “Bar Width” (slider)") == .dropped)
        #expect(r.droppedCount == 1)

        // The template survives its own on-disk format and can be placed and edited like a saved one.
        let again = try JSONDecoder().decode(TitleTemplate.self, from: JSONEncoder().encode(r.template))
        #expect(again == r.template)
        var p = Project(name: "P", timelines: [Timeline(name: "Main", format: r.template.content.format, tracks: [Track(kind: .video)])])
        let tl = p.timelines[0]
        let placed = try p.applyTitleTemplate(r.template, in: tl.id, track: tl.tracks[0].id, at: .zero)
        try p.setTemplateSlot(slot.id, to: .text("Flood Warning"), clip: placed)
        let clip = try #require(p.timelines[0].tracks[0].clips.first)
        #expect(clip.templateSlots?.first?.value == .text("Flood Warning"))
    }

    @Test func storedPlainProjectAlsoReads() throws {
        let f = PRFixture()
        f.sequence("T", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic, components: [textComponent(f, "Name")])])])
        let r = try MogrtImporter.read(data: package(f, definition: Self.definition(name: "", author: "ppro"), deflated: false, thumb: nil), fileName: "Plain")
        #expect(r.template.name == "Plain" && r.thumbnail == nil)
        // No control names the text: the slot keeps its own name.
        #expect(r.template.slots.map(\.name) == ["Text 1"] && r.droppedCount == 0)
    }

    @Test func twoTextLayersGetOneSlotEachNamedByTheirControls() throws {
        let f = PRFixture()
        f.sequence("T", width: 1920, height: 1080,
                   video: [f.track([f.item(start: 0, end: 3 * S, inPoint: 0, outPoint: 3 * S, source: .graphic,
                                           components: [textComponent(f, "Jane Doe"), textComponent(f, "Reporter", at: "0.3:0.9")])])])
        let def = Self.definition(name: "Two Lines", author: "ppro",
                                  controls: [Self.textControl("Title", "Reporter", id: "4"), Self.textControl("Name", "Jane Doe"),
                                             Self.textControl("Unused", "Nowhere", id: "5")])
        let r = try MogrtImporter.read(data: package(f, definition: def), fileName: "x")
        // Slots follow the document layer order (bottom first), like the Graphics clip of a project import.
        #expect(r.template.slots.map(\.name) == ["Title", "Name"])
        #expect(r.template.slots.allSatisfy { $0.graphicsLayer != nil })
        #expect(r.description.textLayers.map(\.text) == ["Jane Doe", "Reporter"])
        #expect(r.report.status(of: "Control “Unused” (text)") == .dropped && r.droppedCount == 1)
    }

    @Test func shapeNextToTextIsDroppedAndCounted() throws {
        let f = PRFixture()
        let shape = f.component("AE.ADBE Shape", [f.param(4, "0.5:0.5", kind: "PointComponentParam")])
        f.sequence("T", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic,
                                                components: [shape, textComponent(f, "Name")])])])
        let r = try MogrtImporter.read(data: package(f, definition: Self.definition(name: "Bar", author: "ppro")), fileName: "x")
        #expect(r.template.slots.count == 1 && r.description.shapeLayerCount == 1)
        #expect(r.report.status(of: "Shape layer") == .dropped && r.report.count(of: "Shape layer") == 1)
        #expect(r.droppedCount >= 1)
    }

    @Test func templateWithoutTextReportsNothingImportable() throws {
        let f = PRFixture()
        let shape = f.component("AE.ADBE Shape", [f.param(4, "0.5:0.5", kind: "PointComponentParam")])
        f.sequence("T", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic, components: [shape])])])
        do {
            _ = try MogrtImporter.read(data: package(f, definition: Self.definition(name: "Bar", author: "ppro")), fileName: "x")
            Issue.record("expected an error")
        } catch let MogrtImportError.nothingImportable(name, dropped) {
            #expect(name == "Bar" && dropped >= 1)
        }
    }

    @Test func afterEffectsTemplateIsRefusedWithAClearMessage() throws {
        let aep = TestZip.make([("comp.aep", Data("RIFX".utf8))])
        let byAuthor = TestZip.make([("project.aegraphic", aep), ("definition.json", Self.definition(name: "Testo", author: "aefx"))], deflated: true)
        #expect(throws: MogrtImportError.needsAfterEffects(name: "Testo")) { try MogrtImporter.read(data: byAuthor, fileName: "x") }
        // No author key: the composition file decides.
        let byFile = TestZip.make([("project.aegraphic", aep), ("definition.json", Self.definition(name: "", author: nil))])
        #expect(throws: MogrtImportError.needsAfterEffects(name: "Fallback")) { try MogrtImporter.read(data: byFile, fileName: "Fallback") }
        let message = try #require(MogrtImportError.needsAfterEffects(name: "Testo").errorDescription)
        #expect(message.contains("Testo") && message.contains("needs After Effects to render") && message.contains("cannot be imported yet"))
    }

    /// A small entry that inflates to far more than it declares must stop at the declared size, not fill memory first.
    @Test func inflateStopsAtTheGivenLimit() throws {
        let big = Data(repeating: 0x41, count: 8 << 20)
        let packed = TestZip.deflate(big)
        #expect(throws: PRImportError.corruptArchive) { try PRGzip.rawInflate([UInt8](packed), limit: 10) }
        #expect(try PRGzip.rawInflate([UInt8](packed), limit: big.count) == big)
        // The embedded project's gzip has a cap too.
        #expect(throws: PRImportError.corruptArchive) { try PRGzip.inflate(TestZip.gzip(big), limit: 1 << 20) }
        #expect(try PRGzip.inflate(TestZip.gzip(big), limit: big.count) == big)
        #expect(PRGzip.maxProjectSize >= 1 << 30)

        // A ZIP entry that declares 10 bytes and inflates to 8 MB.
        var zip = [UInt8](TestZip.make([("definition.json", big)], deflated: true))
        func patch(_ at: Int) { zip.replaceSubrange(at..<(at + 4), with: [10, 0, 0, 0]) }
        patch(22)                                               // local header: uncompressed size
        let central = try #require(zip.indices.dropLast(3).last { zip[$0] == 0x50 && zip[$0 + 1] == 0x4b && zip[$0 + 2] == 1 && zip[$0 + 3] == 2 })
        patch(central + 24)                                     // central directory: uncompressed size
        let reader = try PRZip(Data(zip))
        #expect(reader.entries.first?.uncompressedSize == 10)
        #expect(throws: PRImportError.corruptArchive) { try reader.data("definition.json") }
    }

    /// Numbers no frame size or menu can have are dropped, never trapped on.
    @Test func absurdNumbersInTheDefinitionDoNotCrash() throws {
        let json = """
        {"authorApp":"ppro","capsuleName":"Huge",
         "clientControls":[{"id":"1","type":13,"uiName":{"strDB":[{"localeString":"en_US","str":"Style"}]},"value":1e300,"menucontent":[]},
                           {"id":"2","type":13,"uiName":{"strDB":[{"localeString":"en_US","str":"Look"}]},"value":2,"menucontent":[]}],
         "sourceInfoLocalized":{"en_US":{"duration":{"scale":1e300,"value":1e300},"framesize":{"size":{"x":1e300,"y":-1e300}}}}}
        """
        let d = try #require(MogrtDefinition.parse(Data(json.utf8)))
        #expect(d.width == nil && d.height == nil && d.duration == nil)
        #expect(d.controls.map(\.value) == [.none, .menu(index: 2, items: [])])
        let ok = try #require(MogrtDefinition.parse(Self.definition(name: "Fine", author: "ppro")))
        #expect(ok.width == 1920 && ok.height == 1080)
    }

    /// A graphic archive with only a folder or an empty file holds no project: "no graphic", not "damaged".
    @Test func graphicWithoutAProjectFileIsMissingNotDamaged() throws {
        let def = Self.definition(name: "Hollow", author: "ppro")
        for files in [[(name: "assets/", data: Data())], [(name: "empty.prproj", data: Data())], [(name: "assets/", data: Data()), (name: "notes.txt", data: Data())]] {
            let data = TestZip.make([("project.prgraphic", TestZip.make(files)), ("definition.json", def)])
            #expect(throws: MogrtImportError.missingGraphic(name: "Hollow")) { try MogrtImporter.read(data: data, fileName: "x") }
        }
        // A folder entry ahead of a project without the usual extension: the project is found.
        let f = PRFixture()
        f.sequence("T", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic, components: [textComponent(f, "Name")])])])
        let graphic = TestZip.make([("assets/", Data()), ("project", TestZip.gzip(f.data))])
        let r = try MogrtImporter.read(data: TestZip.make([("project.prgraphic", graphic), ("definition.json", def)]), fileName: "x")
        #expect(r.template.slots.count == 1)
        // Real damage still reads as damage.
        let broken = TestZip.make([("project.prgraphic", TestZip.make([("a.prproj", Data("<nope".utf8))])), ("definition.json", def)])
        #expect(throws: MogrtImportError.unreadable(name: "Hollow")) { try MogrtImporter.read(data: broken, fileName: "x") }
    }

    @Test func otherFilesAreRefused() throws {
        #expect(throws: MogrtImportError.notATemplate) { try MogrtImporter.read(data: Data("hello, this is surely no archive".utf8), fileName: "x") }
        #expect(throws: MogrtImportError.notATemplate) { try MogrtImporter.read(data: TestZip.make([("readme.txt", Data("x".utf8))]), fileName: "x") }
        let noGraphic = TestZip.make([("definition.json", Self.definition(name: "Empty", author: "ppro"))])
        #expect(throws: MogrtImportError.missingGraphic(name: "Empty")) { try MogrtImporter.read(data: noGraphic, fileName: "x") }
        for e in [MogrtImportError.notATemplate, .missingGraphic(name: "A"), .unreadable(name: "A"), .nothingImportable(name: "A", dropped: 2)] {
            #expect(e.errorDescription?.isEmpty == false)
        }
    }

    /// Runs only with `SQ_MOGRT_SAMPLE=/path/to/template.mogrt` (real templates never live in the repo).
    static let sample = ProcessInfo.processInfo.environment["SQ_MOGRT_SAMPLE"]
    @Test(.enabled(if: sample != nil)) func importsRealTemplate() throws {
        let url = URL(fileURLWithPath: Self.sample!)
        do {
            let r = try MogrtImporter.read(url: url)
            print("mogrt \(r.template.name): \(r.template.layers.count) layers, slots \(r.template.slots.map { "\($0.name)=\($0.value)" }), "
                + "duration \(r.template.duration), definition duration \(String(describing: r.description.definition.duration)), "
                + "texts \(r.description.textLayers), dropped \(r.droppedCount)\n\(r.report.summary)")
            #expect(!r.template.layers.isEmpty)
            log("\(r.template.name): \(r.template.layers.count) layers, slots \(r.template.slots.map { "\($0.name)=\($0.value)" }), "
                + "duration \(r.template.duration), definition duration \(String(describing: r.description.definition.duration)), "
                + "texts \(r.description.textLayers), dropped \(r.droppedCount)\n\(r.report.summary)")
        } catch let e as MogrtImportError {
            print("mogrt refused: \(e.errorDescription ?? "")")
            log("refused: \(e.errorDescription ?? "")")
        }
    }

    /// `SQ_MOGRT_SAMPLE_LOG=/path`: what the sample import produced (the test script prints errors only).
    private func log(_ s: String) {
        guard let path = ProcessInfo.processInfo.environment["SQ_MOGRT_SAMPLE_LOG"] else { return }
        try? Data(s.utf8).write(to: URL(fileURLWithPath: path))
    }
}
