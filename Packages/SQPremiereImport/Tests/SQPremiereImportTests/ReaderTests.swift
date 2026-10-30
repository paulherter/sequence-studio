import Testing
import Foundation
import SQCore
@testable import SQPremiereImport

@Suite struct ReaderTests {
    let S = PRFixture.second

    @Test func ticksBecomeRationalTime() {
        #expect(PRTicks.time(S) == Time(1, 1))
        #expect(PRTicks.time(8_467_200_000) == Time(1, 30))
        #expect(PRTicks.time(8_475_667_200) == Time(1001, 30000))
        #expect(PRTicks.time(S * 3 / 2) == Time(3, 2))
        #expect(PRTicks.frameDuration(ticksPerFrame: 8_475_667_200) == Time(1001, 30000))
        // 48 kHz samples stay exact.
        #expect(PRTicks.time(S / 48000) == Time(1, 48000))
    }

    @Test func hostileTicksNeverTrap() {
        _ = PRTicks.time(Int64.max)
        _ = PRTicks.time(Int64.min)
        #expect(PRTicks.sub(Int64.max, -5) == Int64.max)
        #expect(PRTicks.sub(Int64.min, 5) == Int64.min + 1)
        #expect(PRTicks.sub(10, 4) == 6)
        #expect(PRSafe.int(.nan) == nil)
        #expect(PRSafe.int(.infinity) == nil)
        #expect(PRSafe.int(1e300) == nil)
        #expect(PRSafe.int(7.9) == 7)
    }

    @Test func gzipExtraFieldLengthIsLittleEndian() throws {
        // FEXTRA of 511 bytes (0x01FF): the old precedence read 2 + 255 | 1 << 8 = 257 and landed inside the extra field.
        var gz = Data([0x1f, 0x8b, 8, 0x04, 0, 0, 0, 0, 0, 3, 0xFF, 0x01])
        gz.append(Data(repeating: 0x41, count: 511))
        gz.append(contentsOf: [179, 73, 212, 183, 3, 0])
        gz.append(Data(repeating: 0, count: 8))
        #expect(try PRGzip.inflate(gz) == Data("<a/>".utf8))
    }

    @Test func gunzipsAndPassesPlainXMLThrough() throws {
        let text = String(repeating: "<PremiereData Version=\"3\"></PremiereData>\n", count: 2000)
        let plain = Data(text.utf8)
        // gzip = 10-byte header (with FNAME) + raw deflate + crc32 + isize.
        var gz = Data([0x1f, 0x8b, 8, 0x08, 0, 0, 0, 0, 0, 3])
        gz.append(contentsOf: Array("x.xml".utf8) + [0])
        let packed = TestZip.deflate(plain)
        #expect(packed.count > 0)
        gz.append(packed)
        gz.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        #expect(try PRGzip.inflate(gz) == plain)
        #expect(try PRGzip.inflate(plain) == plain)
    }

    @Test func objectTableFollowsRefs() throws {
        let xml = """
        <PremiereData Version="3"><A ObjectID="1"><Ref ObjectRef="2"/><U ObjectURef="abc"/><Name>first</Name></A>\
        <B ObjectID="2"><Name>second</Name></B><C ObjectUID="abc"><Inner><Name>third</Name></Inner></C></PremiereData>
        """
        let table = try PRObjectTable(xml: Data(xml.utf8))
        let a = try #require(table["1"])
        #expect(a.text("Name") == "first")
        #expect(table.deref(a.child("Ref"))?.text("Name") == "second")
        #expect(table.deref(a.child("U"))?.text("Inner/Name") == "third")
        #expect(table.all(named: "B").count == 1)
    }

    @Test func parsesStaticValuesAndKeyframes() {
        let p = PRParamValue.parse(start: "-91445760000000000,100.,0,0,0,0,0,0",
                                   keys: "254016000000,50.,0,0,0,0.16666666666666666,0,0.16666666666666666;508032000000,0.5:0.25,5,0,10,0.3333,-2,0.5;")
        #expect(p.staticValue == "100.")
        #expect(p.keys.count == 2)
        #expect(p.keys[0].ticks == S && p.keys[0].value == "50." && p.keys[0].interpolation == 0)
        #expect(p.keys[1].interpolation == 5 && p.keys[1].inSlope == 10 && p.keys[1].inInfluence == 0.3333)
        #expect(p.keys[1].outSlope == -2 && p.keys[1].outInfluence == 0.5)
        #expect(PRParamValue.double("100.") == 100)
        #expect(PRParamValue.double("-3.25") == -3.25)
        #expect(PRParamValue.point("0.5:0.25") == Vec2(0.5, 0.25))
        #expect(PRParamValue.bool("true") == true)
        #expect(PRParamValue.bool("false") == false)
        // Packed color, 16 bit per channel ARGB: opaque black, then opaque white.
        #expect(PRParamValue.color("18374686479671623680") == EffectColor(red: 0, green: 0, blue: 0, alpha: 1))
        #expect(PRParamValue.color(String(UInt64.max)) == EffectColor(red: 1, green: 1, blue: 1, alpha: 1))
    }

    @Test func readsSequencesTracksItemsAndEffects() throws {
        let f = PRFixture()
        let m = f.media(path: "/footage/a.mov", title: "a.mov")
        let pos = f.param(1, "0.5:0.5", kind: "PointComponentParam")
        let motion = f.component("AE.ADBE Motion", [pos])
        let v = f.item(start: nil, end: 2 * S, inPoint: 10 * S, outPoint: 12 * S, source: .media(m), components: [motion], name: "A")
        let a = f.item(start: S, end: 2 * S, inPoint: 0, outPoint: S * 8 / 5, speed: 1.6, source: .media(m), audio: true)
        f.sequence("Main", ticksPerFrame: 8_475_667_200, width: 1080, height: 1920,
                   video: [f.track([v])], audio: [f.track([a], audio: true)])
        let doc = try PRReader.read(data: f.data)
        #expect(doc.sequences.count == 1)
        let s = try #require(doc.sequences.first)
        #expect(s.name == "Main" && s.width == 1080 && s.height == 1920)
        #expect(s.frameDuration == Time(1001, 30000))
        #expect(s.videoTracks.count == 1 && s.audioTracks.count == 1)
        let vi = try #require(s.videoTracks[0].items.first)
        #expect(vi.start == 0 && vi.end == 2 * S && vi.inPoint == 10 * S && vi.outPoint == 12 * S && vi.speed == 1)
        #expect(vi.name == "A")
        guard case .media(let media) = vi.source else { Issue.record("not media"); return }
        #expect(media.path == "/footage/a.mov" && media.title == "a.mov")
        #expect(vi.components.map(\.matchName) == ["AE.ADBE Motion"])
        #expect(vi.components[0].param(1)?.staticValue == "0.5:0.5")
        let ai = try #require(s.audioTracks[0].items.first)
        #expect(ai.isAudio && ai.speed == 1.6 && ai.start == S)
    }

    @Test func sharedBinaryBlobsResolveByHash() throws {
        let f = PRFixture()
        let blob = FlatBlob.premiereText("Hi", font: "Inter-Bold", size: 50, tracking: 0).base64EncodedString()
        let m = f.media(path: "/f/a.mov", title: "a.mov")
        let a = f.component("AE.ADBE Text", [f.blobParam(1, base64: blob, hash: "h1")])
        let b = f.component("AE.ADBE Text", [f.blobParam(1, base64: "", hash: "h1")])
        f.sequence("Main", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .media(m), components: [a, b])])])
        let item = try #require(PRReader.read(data: f.data).sequences.first?.videoTracks.first?.items.first)
        #expect(item.components[1].param(1)?.blob == blob)
    }

    @Test func decodesFlatBufferTextBlob() throws {
        let blob = FlatBlob.premiereText("hier sind", font: "Inter-Bold", size: 73.144, tracking: -44)
        let t = try #require(PRTextBlob.decode(blob))
        #expect(t.text == "hier sind")
        #expect(t.fontName == "Inter-Bold")
        #expect(abs((t.size ?? 0) - 73.144) < 0.001)
        #expect(t.tracking == -44)
        #expect(t.shadow == nil)
    }

    /// TCL C8L 'Bis zu\r3.200': Premiere ends a paragraph with CR; the second line is another run in another font and size.
    @Test func decodesRunsAndCarriageReturnLineBreaks() throws {
        let blob = FlatBlob.premiereRuns([("Bis zu\r", 0, 136), ("3.200", 1, 195)], fonts: ["BasicSans-Regular", "BasicSans-Bold"])
        let t = try #require(PRTextBlob.decode(blob))
        #expect(t.text == "Bis zu\n3.200")
        #expect(t.fontName == "BasicSans-Regular" && t.size == 136)
        #expect(t.runs.map(\.text) == ["Bis zu\n", "3.200"])
        #expect(t.runs.map(\.fontName) == ["BasicSans-Regular", "BasicSans-Bold"] && t.runs.map(\.size) == [136, 195])
        let second = try #require(t.secondLine)
        #expect(second.fontName == "BasicSans-Bold" && second.size == 195)
        #expect(!t.mixedStyles)
        // CRLF is one break; one style throughout has no second line.
        let plain = try #require(PRTextBlob.decode(FlatBlob.premiereRuns([("a\r\nb", 0, 50)], fonts: ["Inter-Bold"])))
        #expect(plain.text == "a\nb" && plain.secondLine == nil && !plain.mixedStyles)
        // A style change inside the first line cannot be shown with two line styles: reported, first style kept.
        let mixed = try #require(PRTextBlob.decode(FlatBlob.premiereRuns([("a", 0, 50), ("b", 1, 80)], fonts: ["X-Regular", "X-Bold"])))
        #expect(mixed.secondLine == nil && mixed.mixedStyles)
    }

    @Test func decodesFlatBufferTextShadow() throws {
        let blob = FlatBlob.premiereText("auf Audio", font: "Inter-Bold", size: 90, tracking: 0,
                                         shadow: ((0, 0, 0), true, 90.781, 17.764, 19.255, 20.461, 178.612))
        let t = try #require(PRTextBlob.decode(blob))
        #expect(t.text == "auf Audio" && t.fontName == "Inter-Bold")
        let s = try #require(t.shadow)
        #expect(s.red == 0 && s.green == 0 && s.blue == 0)
        #expect(abs(s.opacity - 0.90781) < 1e-5 && s.distance == 0 && s.angle == 0)  // fields 20/34 (here 19.255 / 17.764) are not the shadow angle / distance
        #expect(abs(s.size - 20.461) < 1e-3 && abs(s.blur - 178.612) < 1e-3)
        let off = FlatBlob.premiereText("x", font: "Inter-Bold", size: 90, tracking: 0, shadow: ((0, 0, 0), false, 90, 20, 178, 19, 17))
        #expect(try #require(PRTextBlob.decode(off)).shadow == nil)
    }

    /// Main table field 17 is the Background color (18 on, 19 opacity), not the fill: the maintainer's captions store cyan
    /// 75/203/214 there with the background off and render white in Premiere (S112 x2, TCL C8L).
    @Test func flatField17IsTheBackgroundNotTheFill() throws {
        let off = try #require(PRTextBlob.decode(FlatBlob.premiereText("x", font: "Inter-Bold", size: 90, tracking: 0,
                                                                       background: ((75, 203, 214), false, 100, 9.26, 0))))
        #expect(off.fill == nil && off.background == nil)
        let on = try #require(PRTextBlob.decode(FlatBlob.premiereText("x", font: "Inter-Bold", size: 90, tracking: 0,
                                                                      background: ((0xEE, 0x4A, 0x4A), true, 80, 12, 6))))
        #expect(on.fill == nil)
        let bg = try #require(on.background)
        #expect(bg.color == PRText.RGB(red: 0xEE / 255.0, green: 0x4A / 255.0, blue: 0x4A / 255.0))
        #expect(abs(bg.opacity - 0.8) < 1e-6 && abs(bg.size - 12) < 1e-6 && abs(bg.cornerRadius - 6) < 1e-6)
    }

    /// Shadow color channels are one-byte fields too.
    @Test func shadowColourReadsBytes() throws {
        let t = try #require(PRTextBlob.decode(FlatBlob.premiereText("x", font: "Inter-Bold", size: 90, tracking: 0,
            shadow: ((10, 20, 30), true, 50, 4, 135, 2, 3))))
        let s = try #require(t.shadow)
        #expect(s.red == 10 / 255.0 && s.green == 20 / 255.0 && s.blue == 30 / 255.0)
    }

    @Test func decodesLegacyJSONFillAndStroke() throws {
        func blob(_ fill: Int, fillVisible: Bool, stroke: Int, strokeVisible: Bool, width: Int) -> Data {
            func p(_ v: String) -> String { "{\"mParamValues\":[[0,\(v)]]}" }
            let json = "{\"mTextParam\":{\"mStyleSheet\":{\"mText\":\"Hi\",\"mFillColor\":\(p("\(fill)")),\"mFillVisible\":\(p("\(fillVisible)")),"
                + "\"mStrokeColor\":\(p("\(stroke)")),\"mStrokeVisible\":\(p("\(strokeVisible)")),\"mStrokeWidth\":\(p("\(width)"))}}}"
            return Data(count: 8) + (json + "\0").data(using: .utf16LittleEndian)!
        }
        let t = try #require(PRTextBlob.decode(blob(0xFF8000, fillVisible: true, stroke: 0x000080, strokeVisible: true, width: 4)))
        #expect(t.fill == PRText.RGB(red: 1, green: 128.0 / 255, blue: 0))
        #expect(t.stroke == PRText.Stroke(color: PRText.RGB(red: 0, green: 0, blue: 128.0 / 255), width: 4))
        let off = try #require(PRTextBlob.decode(blob(0x606060, fillVisible: false, stroke: 0xFFFFFF, strokeVisible: false, width: 1)))
        #expect(off.fill == nil && off.stroke == nil)
    }

    @Test func decodesLegacyJSONTextBlob() throws {
        let json = #"{"mTextParam":{"mAlignment":0,"mStyleSheet":{"mFontName":{"mParamValues":[[0,"BasicSans-Bold"]]},"mFontSize":{"mParamValues":[[0,81.5]]},"mFillColor":{"mParamValues":[[0,16777215]]},"mText":"Hello","mTracking":{"mParamValues":[[0,0]]}}}}"#
        var blob = Data(repeating: 0, count: 8)
        blob.append(json.data(using: .utf16LittleEndian)!)
        let t = try #require(PRTextBlob.decode(blob))
        #expect(t.text == "Hello")
        #expect(t.fontName == "BasicSans-Bold")
        #expect(t.size == 81.5)
    }
}
