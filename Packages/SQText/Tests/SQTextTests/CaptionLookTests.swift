import Foundation
import Testing
import SQCore
@testable import SQText

@Suite struct CaptionLookTests {
    @Test func popMatchesPaulsPreset() {
        let a = CaptionPresetLibrary.builtIn.animation(for: "caption-pop")
        #expect(a.anchor == .start)
        // FB-Y: softer than the maintainer's Premiere preset (90 % -> 105 % -> 100 % in 0.13 s, linear): 96 % -> 102 % -> 100 %, eased.
        #expect(a.value(of: "scale", at: .zero) == 0.96)
        #expect(abs(a.value(of: "scale", at: Time(2, 25))! - 1.02) < 1e-9)
        #expect(abs(a.value(of: "scale", at: Time(7, 25))! - 1.0) < 1e-9)
        #expect(a.value(of: "scale", at: Time(2, 1))! == 1.0)
    }

    @Test func defaultLookHasShadowAndPop() {
        let l = CaptionLook.default
        #expect(l.style.shadow != nil)
        #expect(l.animation == .captionPop)
    }

    @Test func payloadRoundTrip() throws {
        let l = CaptionLook.default
        let data = try l.payload()
        #expect(try CaptionLook(payload: data, version: 1) == l)
        #expect(throws: CaptionLookError.self) { try CaptionLook(payload: data, version: 2) }
    }

    @Test func registryMakesLooksResolvable() {
        var l = CaptionLook.default; l.style.size = 99
        let refs = CaptionLookRegistry.shared.register(l, id: "test-look")
        defer { CaptionLookRegistry.shared.unregister(id: "test-look") }
        let lib = CaptionPresetLibrary.builtIn
        #expect(lib.style(for: refs.styleRef).size == 99)
        #expect(lib.animation(for: refs.animationRef) == .captionPop)
        #expect(CaptionPresetLibrary.builtIn.hasStyle(refs.styleRef))
    }
}
