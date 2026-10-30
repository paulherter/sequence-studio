import Foundation
import Testing
@testable import SQCore

// v87 Color range masks: the key maths (CPU reference of the compositor), the model, and the file gate (a v86 build would
// read the source as a full-frame path, so a file holding one is written as v87; others keep their lowest version).

private func project(_ masks: [ClipMask]) -> Project {
    var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)),
                 start: .zero, mediaDuration: Time(100, 1))
    c.masks = masks
    var tr = Track(kind: .video)
    try? tr.overwrite(c)
    let top = Timeline(name: "S", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)), tracks: [tr])
    return Project(name: "P", timelines: [top])
}

@Suite struct ColorRangeMaskTests {
    @Test func valueIsFullInsideToleranceAndFallsOverSoftness() {
        let k = ColorRangeKey(red: 0.5, green: 0.5, blue: 0.5, tolerance: 0.2, softness: 0.2)
        #expect(k.value(red: 0.5, green: 0.5, blue: 0.5) == 1)
        // distance 0.2 * sqrt(3) in RGB = tolerance exactly: still fully covered
        let e = 0.2 * 3.0.squareRoot() / 3.0.squareRoot()   // all three channels off by 0.2 -> distance 0.2
        #expect(k.value(red: 0.5 + e, green: 0.5 + e, blue: 0.5 + e) == 1)
        let mid = 0.3  // distance 0.3 = tolerance + softness / 2 -> smoothstep(0.5) = 0.5
        #expect(abs(k.value(red: 0.5 + mid, green: 0.5 + mid, blue: 0.5 + mid) - 0.5) < 1e-9)
        #expect(k.value(red: 0.5 + 0.45, green: 0.5 + 0.45, blue: 0.5 + 0.45) == 0)
    }

    @Test func zeroSoftnessIsAHardEdge() {
        let k = ColorRangeKey(red: 0, green: 1, blue: 0, tolerance: 0.1, softness: 0)
        #expect(k.value(red: 0, green: 1, blue: 0) == 1)
        #expect(k.value(red: 0, green: 0, blue: 0) == 0)
    }

    @Test func keyClampsAndRoundTrips() throws {
        let k = ColorRangeKey(red: 2, green: -1, blue: .nan, tolerance: 5, softness: -3)
        #expect(k.red == 1 && k.green == 0 && k.blue == 0 && k.tolerance == 1 && k.softness == 0)
        let d = try JSONEncoder().encode(ColorRangeKey.default)
        #expect(try JSONDecoder().decode(ColorRangeKey.self, from: d) == .default)
    }

    @Test func coverageReadsThePictureColor() {
        var key = ColorRangeKey(red: 0, green: 1, blue: 0, tolerance: 0.2, softness: 0)
        key.softness = 0
        let m = ClipMask.makeColorRange(key: key)
        let shapes = [m.shape(atLocal: .zero)]
        #expect(shapes[0].source == .colorRange && shapes[0].colorRange == key)
        let frame = Vec2(100, 100)
        func cov(_ x: Double) -> Double {
            MaskCoverage.coverage(at: Vec2(x, 50), masks: shapes, frame: frame, pixel: 1, color: { p in
                p.x < 50 ? (r: 0.0, g: 1.0, b: 0.0) : (r: 1.0, g: 0.0, b: 0.0)
            })
        }
        #expect(cov(10) == 1)
        #expect(cov(90) == 0)
        var inv = m; inv.inverted = true
        #expect(MaskCoverage.coverage(at: Vec2(10, 50), masks: [inv.shape(atLocal: .zero)], frame: frame, pixel: 1,
                                      color: { _ in (r: 0.0, g: 1.0, b: 0.0) }) == 0)
        // no picture -> covers nothing
        #expect(MaskCoverage.coverage(at: Vec2(10, 50), masks: shapes, frame: frame, pixel: 1) == 0)
    }

    @Test func maskDoesNotUseAMatte() {
        #expect(!MaskSource.colorRange.usesMatte)
        let s = ClipMask.makeColorRange().shape(atLocal: .zero)
        #expect(s.polygon.count >= 2)   // stays in the clip's mask list (maskShapes filter)
    }

    @Test func keyIsStoredOnlyOnColorRangeMasks() throws {
        var m = ClipMask.make(.rectangle, name: "R")
        m.colorRange = ColorRangeKey(red: 1, green: 0, blue: 0)
        #expect(m.colorRange == .default)
        let data = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(!data.contains("colorRange"))
    }

    @Test func projectGate() throws {
        let plain = project([ClipMask.make(.rectangle, name: "R")])
        let obj0 = try #require(try JSONSerialization.jsonObject(with: try ProjectFile.encode(plain)) as? [String: Any])
        #expect((obj0["formatVersion"] as? Int ?? 0) < 87)

        var m = ClipMask.makeColorRange(key: ColorRangeKey(red: 0.2, green: 0.4, blue: 0.6, tolerance: 0.3, softness: 0.1))
        m.opacity = AnimatedProperty(80)
        let p = project([m])
        let data = try ProjectFile.encode(p)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["formatVersion"] as? Int == 87)
        for mig in [nil, ProjectFile.migrations] {
            #expect(try ProjectFile.decode(data, migrations: mig) == p)
        }
    }

    @Test func versionConstant() {
        #expect(ProjectFile.v87Version == 87)
        #expect(ProjectFile.currentVersion >= 87)
    }
}
