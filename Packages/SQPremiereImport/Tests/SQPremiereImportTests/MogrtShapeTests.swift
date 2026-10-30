import Testing
import Foundation
import SQCore
import SQText
@testable import SQPremiereImport

/// .mogrt follow-ups (F7.17b): text fill and alignment from the legacy text blob, Shape layers as Graphics layers, the
/// "x,y" point form of real templates.
@Suite struct MogrtShapeTests {
    let S = PRFixture.second
    let helper = MogrtImportTests()

    // MARK: Blob builders

    /// The legacy text blob of real templates: 8-byte header, UTF-16LE JSON.
    static func legacyText(_ s: String, fill: Int?, alignment: Int?, font: String = "Inter-Bold", size: Double = 60) -> String {
        func value(_ v: Any) -> [String: Any] { ["mParamValues": [[0, v]]] }
        var sheet: [String: Any] = ["mText": s, "mFontName": value(font), "mFontSize": value(size), "mTracking": value(0)]
        if let fill { sheet["mFillVisible"] = value(true); sheet["mFillColor"] = value(fill) }
        var tp: [String: Any] = ["mStyleSheet": sheet]
        if let alignment { tp["mAlignment"] = alignment }
        return header(json: ["mTextParam": tp])
    }

    static func header(json: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: json)
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes += [UInt8](String(decoding: data, as: UTF8.self).data(using: .utf16LittleEndian)!)
        return Data(bytes).base64EncodedString()
    }

    /// A path blob: UInt32 2, UInt32 count, per point a zero float and vertex / in / out handle (x, y); one closing byte.
    /// `handles` are absolute like the vertex (equal to it for a straight point).
    static func path(_ points: [(v: (Double, Double), tin: (Double, Double)?, tout: (Double, Double)?)]) -> String {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func f(_ v: Double) { u32(Float(v).bitPattern) }
        u32(2); u32(UInt32(points.count))
        for p in points {
            f(0); f(p.v.0); f(p.v.1)
            let i = p.tin ?? p.v, o = p.tout ?? p.v
            f(i.0); f(i.1); f(o.0); f(o.1)
        }
        d.append(1)
        return d.base64EncodedString()
    }

    static func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> String {
        path([((x0, y0), nil, nil), ((x1, y0), nil, nil), ((x1, y1), nil, nil), ((x0, y1), nil, nil)])
    }

    static func appearance(fill: Int? = 0, stroke: Int? = nil, strokeWidth: Double = 1, shadow: Bool = false) -> String {
        header(json: ["mStyle": ["mFillColor": fill ?? 0, "mFillVisible": fill != nil, "mStrokeColor": stroke ?? 0,
                                 "mStrokeVisible": stroke != nil, "mStrokeWidth": strokeWidth, "mShadowVisible": shadow], "mVersion": 1])
    }

    func shapeComponent(_ f: PRFixture, blob: String, appearance: String = MogrtShapeTests.appearance(), position: String = "0.5:0.5",
                        anchor: String = "0:0", scale: String = "100.", rotation: String = "0.", opacity: String = "100.",
                        positionKeys: String? = nil) -> String {
        f.component("AE.ADBE Shape", [
            f.blobParam(1, base64: blob), f.blobParam(2, base64: appearance), f.param(4, position, keys: positionKeys, kind: "PointComponentParam"),
            f.param(5, scale), f.param(6, scale), f.param(7, "true"), f.param(8, rotation), f.param(9, opacity),
            f.param(10, anchor, kind: "PointComponentParam"),
        ])
    }

    func legacyTextComponent(_ f: PRFixture, _ s: String, fill: Int?, alignment: Int?, at pos: String = "0.3:0.8") -> String {
        f.component("AE.ADBE Text", [f.blobParam(1, base64: Self.legacyText(s, fill: fill, alignment: alignment)),
                                     f.param(3, pos, kind: "PointComponentParam"), f.param(4, "100.")])
    }

    func read(_ f: PRFixture, components: [String]) throws -> MogrtImportResult {
        f.sequence("T", width: 1920, height: 1080,
                   video: [f.track([f.item(start: 0, end: 3 * S, inPoint: 0, outPoint: 3 * S, source: .graphic, components: components)])])
        return try MogrtImporter.read(data: helper.package(f, definition: MogrtImportTests.definition(name: "T", author: "ppro")), fileName: "x")
    }

    func graphicsLayers(_ r: MogrtImportResult) throws -> [GraphicsLayer] {
        let clip = try #require(r.template.content.tracks.flatMap(\.clips).first)
        return try #require(clip.graphics).layers
    }

    // MARK: Text fill and alignment

    @Test func legacyBlobAlignmentMapsTheNSTextOrder() {
        for (raw, expected) in [(0, 0), (1, 1), (2, 2), (3, 0), (4, 1), (5, 2)] {
            #expect(PRTextBlob.decode(base64: Self.legacyText("A", fill: 0xFF0000, alignment: raw))?.alignment == expected)
        }
        #expect(PRTextBlob.decode(base64: Self.legacyText("A", fill: nil, alignment: nil))?.alignment == nil)
        #expect(PRTextBlob.decode(base64: Self.legacyText("A", fill: nil, alignment: 9))?.alignment == nil)
    }

    @Test func textKeepsItsRealFillAndAlignment() throws {
        let f = PRFixture()
        let r = try read(f, components: [legacyTextComponent(f, "Right Cyan", fill: 0x00B5E2, alignment: 1)])
        #expect(r.description.textLayers.first?.alignment == 1)
        let c = try #require(r.description.textLayers.first?.color)
        #expect(abs(c.red - 0) < 0.01 && abs(c.green - 181.0 / 255) < 0.01 && abs(c.blue - 226.0 / 255) < 0.01)
        let clip = try #require(r.template.content.tracks.flatMap(\.clips).first)
        let (t, _) = try TextGenerator.decode(try #require(clip.generator))
        #expect(t.style.alignment == .right)
        #expect(abs(t.style.color.red - 0) < 0.01 && abs(t.style.color.green - 181.0 / 255) < 0.01)
    }

    @Test func leftAlignedPointTextIsLeftAndCenterStaysCenter() throws {
        for (raw, expected) in [(0, TextAlignment.left), (2, .center)] {
            let f = PRFixture()
            let r = try read(f, components: [legacyTextComponent(f, "Name", fill: 0xFFFFFF, alignment: raw)])
            let clip = try #require(r.template.content.tracks.flatMap(\.clips).first)
            let (t, _) = try TextGenerator.decode(try #require(clip.generator))
            #expect(t.style.alignment == expected)
        }
    }

    // MARK: Point form

    @Test func pointParamOfARealTemplateIsJoinedToXY() {
        let p = PRParamValue.parse(start: "-91445760000000000,0.25,0.75,0,0,0,0,0,0,5,4,0,0,0,0", keys: nil)
        #expect(PRParamValue.point(p.staticValue) == Vec2(0.25, 0.75))
        // A scalar and the "x:y" form are untouched.
        #expect(PRParamValue.parse(start: "-9,100.,0,0,0,0,0,0", keys: nil).staticValue == "100.")
        #expect(PRParamValue.parse(start: "-9,0.5:0.5,0,0,0,0,0,0", keys: nil).staticValue == "0.5:0.5")
        let k = PRParamValue.parse(start: nil, keys: "100,0.2,0.4,0,0,0,0,0,0,5,4,0,0,0,0;200,0.6,0.8,0,0,0,0,0,0,5,4,0,0,0,0")
        #expect(k.keys.map(\.value) == ["0.2:0.4", "0.6:0.8"])
    }

    // MARK: Shapes

    @Test func rectangleShapeBecomesAFilledRectangleLayerBelowTheText() throws {
        let f = PRFixture()
        // 400 x 100 box at the frame center, red fill, white 4 px outline.
        let shape = shapeComponent(f, blob: Self.rect(0, 0, 400, 100), appearance: Self.appearance(fill: 0xFF0000, stroke: 0xFFFFFF, strokeWidth: 4),
                                   position: "0.5:0.5", anchor: "0.104166:0.0925926")
        let r = try read(f, components: [legacyTextComponent(f, "Name", fill: 0xFFFFFF, alignment: 2), shape])
        let layers = try graphicsLayers(r)
        #expect(layers.count == 2 && layers[0].isText == false && layers[1].isText)   // bottom first
        let l = layers[0]
        guard case .shape(let kind) = l.content else { Issue.record("not a shape"); return }
        #expect(kind == .rectangle)
        let e = try #require(l.shapeEffect)
        #expect(e.parameters[ClipEffect.shapeWidthKey]?.value == 400 && e.parameters[ClipEffect.shapeHeightKey]?.value == 100)
        #expect(e.parameters[ClipEffect.shapeFillKey]?.value == 1 && e.parameters[ClipEffect.shapeStrokeKey]?.value == 1)
        #expect(e.parameters[ClipEffect.shapeStrokeWidthKey]?.value == 4)
        let fill = try #require(e.colors[ClipEffect.shapeFillColorKey]?.value)
        #expect(fill.red == 1 && fill.green == 0 && fill.blue == 0)
        // Box center (200, 50) minus the anchor (200, 100) lands the center 50 px above the frame center.
        let p = l.animation.position.value
        #expect(abs(p.x) < 0.5 && abs(p.y + 50) < 0.5)
        #expect(r.report.status(of: "Shape layer") == .mapped && r.droppedCount == 0)
        #expect(r.template.slots.count == 1)
    }

    @Test func scaleRotationAndOpacityOfAShapeCarryOver() throws {
        let f = PRFixture()
        let shape = shapeComponent(f, blob: Self.rect(0, 0, 200, 100), position: "0.25:0.5", anchor: "0:0", scale: "50.", rotation: "10.", opacity: "40.")
        let r = try read(f, components: [legacyTextComponent(f, "A", fill: 0xFFFFFF, alignment: 2), shape])
        let l = try graphicsLayers(r)[0]
        let e = try #require(l.shapeEffect)
        #expect(e.parameters[ClipEffect.shapeWidthKey]?.value == 100 && e.parameters[ClipEffect.shapeHeightKey]?.value == 50)
        #expect(l.animation.rotation.value == 10 && abs(l.animation.opacity.value - 0.4) < 1e-9)
        // Local center (100, 50) scaled by 0.5 = (50, 25), rotated 10 degrees, on the position (480, 540) from frame center (960, 540).
        let c = cos(10 * Double.pi / 180), s = sin(10 * Double.pi / 180)
        let p = l.animation.position.value
        #expect(abs(p.x - (480 + 50 * c - 25 * s - 960)) < 0.5 && abs(p.y - (540 + 50 * s + 25 * c - 540)) < 0.5)
    }

    @Test func ellipseShapeIsAnEllipseLayer() throws {
        let f = PRFixture()
        let k = 0.5523
        // 200 x 100 ellipse: vertices at the middle of the box edges, handles a quadrant of a circle long.
        let pts: [(v: (Double, Double), tin: (Double, Double)?, tout: (Double, Double)?)] = [
            ((100, 0), (100 - 100 * k, 0), (100 + 100 * k, 0)),
            ((200, 50), (200, 50 - 50 * k), (200, 50 + 50 * k)),
            ((100, 100), (100 + 100 * k, 100), (100 - 100 * k, 100)),
            ((0, 50), (0, 50 + 50 * k), (0, 50 - 50 * k)),
        ]
        let r = try read(f, components: [legacyTextComponent(f, "A", fill: 0xFFFFFF, alignment: 2), shapeComponent(f, blob: Self.path(pts))])
        let l = try graphicsLayers(r)[0]
        guard case .shape(let kind) = l.content else { Issue.record("not a shape"); return }
        #expect(kind == .ellipse)
        #expect(l.shapeEffect?.parameters[ClipEffect.shapeWidthKey]?.value == 200)
    }

    @Test func roundedRectangleKeepsItsCornerRadius() throws {
        let f = PRFixture()
        let r12 = 12.0
        let pts: [(v: (Double, Double), tin: (Double, Double)?, tout: (Double, Double)?)] = [
            ((r12, 0), nil, nil), ((300 - r12, 0), nil, nil), ((300, r12), nil, nil), ((300, 80 - r12), nil, nil),
            ((300 - r12, 80), nil, nil), ((r12, 80), nil, nil), ((0, 80 - r12), nil, nil), ((0, r12), nil, nil),
        ]
        let (form, _, _) = Mapping.classifyShape(Mapping.shapePoints(Self.path(pts))!)
        #expect(form == .rectangle(radius: 12))
        let res = try read(f, components: [legacyTextComponent(f, "A", fill: 0xFFFFFF, alignment: 2), shapeComponent(f, blob: Self.path(pts))])
        let l = try graphicsLayers(res)[0]
        #expect(l.shapeEffect?.parameters[ClipEffect.shapeCornerRadiusKey]?.value == 12)
    }

    @Test func straightPolygonBecomesAClosedPath() throws {
        let f = PRFixture()
        let tri = Self.path([((0, 100), nil, nil), ((100, 0), nil, nil), ((200, 100), nil, nil)])
        let r = try read(f, components: [legacyTextComponent(f, "A", fill: 0xFFFFFF, alignment: 2), shapeComponent(f, blob: tri)])
        let l = try graphicsLayers(r)[0]
        guard case .path(let pts, let closed) = l.content else { Issue.record("not a path"); return }
        #expect(closed && pts.count == 3)
        #expect(r.report.status(of: "Shape layer") == .mapped)
    }

    @Test func penPathWithCurvesStaysOutButIsListed() throws {
        let f = PRFixture()
        let curved = Self.path([((0, 0), (0, 0), (30, -40)), ((100, 0), (70, -40), (100, 0)), ((100, 100), nil, nil), ((0, 100), nil, nil), ((50, 130), (20, 130), (80, 130))])
        let r = try read(f, components: [legacyTextComponent(f, "A", fill: 0xFFFFFF, alignment: 2), shapeComponent(f, blob: curved)])
        #expect(r.report.status(of: "Shape layer") == .dropped && r.report.count(of: "Shape layer") == 1)
        #expect(r.report.entries.first { $0.feature == "Shape layer" }?.note.contains("pen path") == true)
        #expect(r.droppedCount >= 1 && r.description.shapeLayerCount == 1)
        // Only the text layer is left: a plain text clip, as before.
        let clip = try #require(r.template.content.tracks.flatMap(\.clips).first)
        #expect(clip.graphics == nil)
    }

    @Test func shapeOpacityKeysAndRealPointFormCarryOver() throws {
        let f = PRFixture()
        // Position in the real "x,y" form, as written in Premiere-authored templates.
        let shape = f.component("AE.ADBE Shape", [
            f.blobParam(1, base64: Self.rect(0, 0, 100, 100)), f.blobParam(2, base64: Self.appearance()),
            f.param(4, "0.75,0.5,0,0,0,0,0,0,5,4,0", kind: "PointComponentParam"), f.param(5, "100."), f.param(6, "100."), f.param(7, "true"),
            f.param(8, "0."), f.param(9, "0.", keys: "0,0.,0,0,0,0,0,0;\(Int64(S)),100.,0,0,0,0,0,0"),
        ])
        let r = try read(f, components: [legacyTextComponent(f, "A", fill: 0xFFFFFF, alignment: 2), shape])
        let l = try graphicsLayers(r)[0]
        // Position 0.75 of 1920 = 1440, box center (50, 50), default anchor 0: center at 1440 + 50 - 960 = 530, 540 + 50 - 540 = 50.
        #expect(abs(l.animation.position.value.x - 530) < 0.5 && abs(l.animation.position.value.y - 50) < 0.5)
        #expect(l.animation.opacity.isAnimated)
    }

    @Test func shapeOnlyTemplateStillReportsNothingEditable() throws {
        let f = PRFixture()
        f.sequence("T", video: [f.track([f.item(start: 0, end: S, inPoint: 0, outPoint: S, source: .graphic,
                                                components: [shapeComponent(f, blob: Self.rect(0, 0, 10, 10))])])])
        #expect(throws: MogrtImportError.self) {
            _ = try MogrtImporter.read(data: helper.package(f, definition: MogrtImportTests.definition(name: "Bar", author: "ppro")), fileName: "x")
        }
    }

    @Test func projectImportStillLeavesShapesOut() throws {
        let f = PRFixture()
        f.sequence("T", width: 1920, height: 1080,
                   video: [f.track([f.item(start: 0, end: 3 * S, inPoint: 0, outPoint: 3 * S, source: .graphic,
                                           components: [legacyTextComponent(f, "A", fill: 0xFFFFFF, alignment: 2), shapeComponent(f, blob: Self.rect(0, 0, 10, 10))])])])
        let res = PRMapper.map(try PRReader.read(data: f.data), name: "P")
        let clips = res.project.timelines.flatMap(\.tracks).flatMap(\.clips)
        #expect(clips.count == 1 && clips[0].graphics == nil)
    }
}
