import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct TextTemplateTests {
    func sample(animated: Bool = true) -> TextTemplate {
        let lib = CaptionPresetLibrary.builtIn
        return TextTemplate(name: "Lower third", text: "Hello\nWorld",
                            style: lib.style(for: "bold-box"),
                            animation: animated ? lib.animation(for: "pop-in") : nil)
    }

    @Test func roundTripWithAndWithoutAnimation() throws {
        for animated in [true, false] {
            let t = sample(animated: animated)
            #expect(try TextTemplate.decode(from: t.encoded()) == t)
        }
    }

    @Test func writesCurrentFormatVersion() throws {
        let json = try JSONSerialization.jsonObject(with: sample().encoded()) as! [String: Any]
        #expect(json["formatVersion"] as? Int == 3)
        #expect(TextTemplate.formatVersion == 3)
    }

    static let v1JSON = """
    {"formatVersion":1,"name":"Old","text":"Hi",
     "style":{"fontName":"Helvetica","size":40,"weight":400,"color":{"red":1,"green":1,"blue":1,"alpha":1},
              "alignment":"center","lineSpacing":0},
     "animation":{"duration":{"value":1,"timescale":4},"tracks":[
       {"property":"scale","keyframes":[
         {"time":{"numerator":0,"denominator":1},"value":0.8,"easing":"overshoot"},
         {"time":{"numerator":1,"denominator":1},"value":1,"easing":"linear"}]},
       {"property":"opacity","keyframes":[
         {"time":{"numerator":0,"denominator":1},"value":0,"easing":"hold"},
         {"time":{"numerator":1,"denominator":2},"value":1,"easing":"linear"},
         {"time":{"numerator":1,"denominator":1},"value":1,"easing":"linear"}]}]}}
    """

    @Test func readsVersionOneFilesAndMigratesAnimation() throws {
        let t = try TextTemplate.decode(from: Data(Self.v1JSON.utf8))
        #expect(t.name == "Old" && t.text == "Hi" && t.style.size == 40)
        let anim = try #require(t.animation)
        #expect(anim.duration == Time(1, 4))
        // Fractions became duration * fraction.
        #expect(anim.track(for: "opacity")!.track.keys.map(\.time) == [.zero, Time(1, 8), Time(1, 4)])
        #expect(anim.track(for: "opacity")!.track.keys[0].interpolation == .hold)
        #expect(anim.value(of: "opacity", at: Time(1, 16)) == 0)          // hold
        #expect(anim.value(of: "opacity", at: Time(1, 8)) == 1)
        // Overshoot easing survived as a bezier with an out-of-range handle.
        let scale = anim.track(for: "scale")!
        #expect(scale.track.keys[0].interpolation == .bezier && scale.track.keys[0].outHandle.dy > 1)
        #expect(anim.value(of: "scale", at: Time(7, 40))! > 1.0)
        #expect(anim != CaptionPresetLibrary.builtIn.animation(for: "pop-in"))  // hold differs from built-in
        // Re-saving writes v2 and round-trips.
        let resaved = try t.encoded()
        let json = try JSONSerialization.jsonObject(with: resaved) as! [String: Any]
        #expect(json["formatVersion"] as? Int == 3)
        #expect(try TextTemplate.decode(from: resaved) == t)
    }

    @Test func versionOneBuiltInPopInMigratesToTheBuiltIn() throws {
        let v1 = Self.v1JSON.replacingOccurrences(of: #""easing":"hold""#, with: #""easing":"easeOut""#)
        let t = try TextTemplate.decode(from: Data(v1.utf8))
        #expect(t.animation == CaptionPresetLibrary.builtIn.animation(for: "pop-in"))
    }

    @Test func outputIsStableAndSorted() throws {
        let a = try sample().encoded(), b = try sample().encoded()
        #expect(a == b)
        let s = String(decoding: a, as: UTF8.self)
        let keys = ["\"animation\"", "\"formatVersion\"", "\"name\"", "\"style\"", "\"text\""]
        let positions = keys.map { s.range(of: $0)!.lowerBound }
        #expect(positions == positions.sorted())
    }

    @Test func newerVersionThrowsTypedError() throws {
        // Future file with a structure this version cannot parse: must still report the version.
        let json = #"{"formatVersion": 4, "name": 5, "layers": []}"#
        do {
            _ = try TextTemplate.decode(from: Data(json.utf8))
            Issue.record("expected throw")
        } catch let e as TextTemplateError {
            #expect(e == .unsupportedVersion(found: 4, supported: 3))
        }
    }

    @Test func missingOrBrokenDataThrowsInvalid() {
        for json in [#"{"name":"x"}"#, "not json", #"{"formatVersion":1,"name":"x"}"#] {
            #expect(throws: TextTemplateError.self) { try TextTemplate.decode(from: Data(json.utf8)) }
        }
        do { _ = try TextTemplate.decode(from: Data("not json".utf8)) } catch let e as TextTemplateError {
            if case .invalidData = e {} else { Issue.record("wrong error \(e)") }
        } catch { Issue.record("wrong error type") }
    }

    @Test func versionZeroOrNegativeIsInvalid() {
        #expect(throws: TextTemplateError.self) {
            try TextTemplate.decode(from: Data(#"{"formatVersion":0}"#.utf8))
        }
    }

    @Test func unknownExtraKeysInCurrentVersionAreIgnored() throws {
        var obj = try JSONSerialization.jsonObject(with: sample().encoded()) as! [String: Any]
        obj["futureHint"] = "x"
        let data = try JSONSerialization.data(withJSONObject: obj)
        #expect(try TextTemplate.decode(from: data) == sample())
    }

    @Test func errorHasReadableDescription() {
        let d = TextTemplateError.unsupportedVersion(found: 4, supported: 3).description
        #expect(d.contains("4") && d.contains("3"))
    }
}
