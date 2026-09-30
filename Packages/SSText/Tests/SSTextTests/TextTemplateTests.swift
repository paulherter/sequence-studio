import Testing
import Foundation
@testable import SSText

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

    @Test func writesFormatVersionOne() throws {
        let json = try JSONSerialization.jsonObject(with: sample().encoded()) as! [String: Any]
        #expect(json["formatVersion"] as? Int == 1)
        #expect(TextTemplate.formatVersion == 1)
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
        let json = #"{"formatVersion": 2, "name": 5, "layers": []}"#
        do {
            _ = try TextTemplate.decode(from: Data(json.utf8))
            Issue.record("expected throw")
        } catch let e as TextTemplateError {
            #expect(e == .unsupportedVersion(found: 2, supported: 1))
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
        let d = TextTemplateError.unsupportedVersion(found: 3, supported: 1).description
        #expect(d.contains("3") && d.contains("1"))
    }
}
