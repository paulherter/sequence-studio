import Foundation
import Testing
@testable import SQCore

/// Key routing and Layer mix fields (v80, optional with defaults).
@Suite struct ColorGraphKeyModelTests {
    @Test func newFieldsDefaultAndRoundTrip() throws {
        var s = ColorStep(label: "A")
        #expect(s.layerMix == .normal && !s.keyOutside && s.keyMix == .multiply && !s.usesV80Fields)
        let plain = String(data: try JSONEncoder().encode(s), encoding: .utf8) ?? ""
        #expect(!plain.contains("layerMix") && !plain.contains("keyOutside") && !plain.contains("keyMix"), "defaults are not written")
        s.layerMix = .screen; s.keyOutside = true; s.keyMix = .subtract
        #expect(s.usesV80Fields)
        let back = try JSONDecoder().decode(ColorStep.self, from: try JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func oldStepJSONDecodesWithDefaults() throws {
        let json = #"{"id":"\#(UUID().uuidString)","label":"Old","kind":"layer"}"#
        let s = try JSONDecoder().decode(ColorStep.self, from: Data(json.utf8))
        #expect(s.layerMix == .normal && !s.keyOutside && s.keyMix == .multiply && s.kind == .layer)
    }

    @Test func aGraphWithTheNewFieldsNeedsV80() {
        var g = ColorGraph()
        #expect(!g.usesV80Fields)
        g.update(g.steps[0].id) { $0.keyOutside = true }
        #expect(g.usesV80Fields)
    }

    @Test func keyDonorsFollowWireOrderAndSkipDisabledSteps() {
        var g = ColorGraph()
        let a = g.steps[0].id
        let b = g.addStep(after: a), c = g.addStep(after: b), d = g.addStep(after: c)
        #expect(g.connectKey(from: c, to: .step(d)) == nil)
        #expect(g.connectKey(from: a, to: .step(d)) == nil, "a Step's key input holds one wire")
        #expect(g.keyDonors(.step(d)).map(\.id) == [a])
        g.update(a) { $0.enabled = false }
        #expect(g.keyDonors(.step(d)).isEmpty)
        _ = b
    }
}
