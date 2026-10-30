import Foundation
import Testing
@testable import SQCore

@Suite struct KeyColorPickAndLayerLabelTests {
    @Test func hueOfPrimaries() {
        #expect(KeyColorPick.hue(fromLinear: SIMD3(0.1, 0.8, 0.1)) == 120)
        #expect(KeyColorPick.hue(fromLinear: SIMD3(0.1, 0.1, 0.8)) == 240)
        #expect(KeyColorPick.hue(fromLinear: SIMD3(0.8, 0.1, 0.1)) == 0)
        #expect(KeyColorPick.hue(fromLinear: SIMD3(0.8, 0.1, 0.4))! > 300)
    }

    @Test func grayAndBlackPickNothing() {
        #expect(KeyColorPick.hue(fromLinear: SIMD3(0.5, 0.5, 0.5)) == nil)
        #expect(KeyColorPick.hue(fromLinear: SIMD3(0, 0, 0)) == nil)
        #expect(KeyColorPick.hue(fromLinear: SIMD3(.nan, 0.2, 0.1)) == nil)
    }

    @Test func layerLabelRoundTripsAndIsAbsentWhenNil() throws {
        var l = GraphicsLayer(name: "a", content: .shape(kind: .rectangle))
        let plainData = try JSONEncoder().encode(l)
        #expect(!String(decoding: plainData, as: UTF8.self).contains("label"))
        l.label = .mango
        let back = try JSONDecoder().decode(GraphicsLayer.self, from: JSONEncoder().encode(l))
        #expect(back.label == .mango)
        let old = try JSONDecoder().decode(GraphicsLayer.self, from: plainData)
        #expect(old.label == nil)
    }
}
