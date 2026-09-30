import Testing
import Foundation
import SSCore
@testable import SSText

@Suite struct KeyframeTemplateTests {
    @Test func fractionReducesAndClamps() {
        #expect(Fraction(2, 4) == Fraction(1, 2))
        #expect(Fraction(3, 2) == .one)
        #expect(Fraction(-1, 2) == .zero)
        #expect(Fraction(1, 0) == .zero)
        #expect(Fraction(1, 4) < Fraction(1, 3))
        #expect(abs(Fraction(1, 4).doubleValue - 0.25) < 1e-12)
    }

    @Test func easingEndpointsAndShape() {
        for e in [Easing.linear, .easeIn, .easeOut, .easeInOut, .overshoot] {
            #expect(abs(e.apply(0)) < 1e-9)
            #expect(abs(e.apply(1) - 1) < 1e-9)
        }
        #expect(Easing.easeIn.apply(0.5) < 0.5)
        #expect(Easing.easeOut.apply(0.5) > 0.5)
        #expect(Easing.overshoot.apply(0.7) > 1)
        #expect(Easing.hold.apply(0.99) == 0 && Easing.hold.apply(1) == 1)
    }

    @Test func trackSortsAndEvaluates() {
        let t = KeyframeTrack(property: "opacity", keyframes: [
            Keyframe(time: Fraction(1, 1), value: 1),
            Keyframe(time: Fraction(0, 1), value: 0, easing: .linear),
        ])
        #expect(t.keyframes.map(\.time) == [.zero, .one])
        #expect(t.value(at: .zero) == 0)
        #expect(abs(t.value(at: Fraction(1, 2))! - 0.5) < 1e-9)
        #expect(t.value(at: .one) == 1)
        #expect(KeyframeTrack(property: "x", keyframes: []).value(at: .zero) == nil)
    }

    @Test func templateLookupByProperty() {
        let tpl = CaptionPresetLibrary.builtIn.animation(for: "pop-in")
        #expect(tpl.track(for: "scale") != nil)
        #expect(tpl.track(for: "opacity") != nil)
        #expect(tpl.track(for: "nope") == nil)
    }

    @Test func popInScaleAndOpacity() {
        let tpl = CaptionPresetLibrary.builtIn.animation(for: "pop-in")
        let scale = tpl.track(for: "scale")!, op = tpl.track(for: "opacity")!
        #expect(abs(scale.value(at: .zero)! - 0.8) < 1e-9)
        #expect(abs(scale.value(at: .one)! - 1.0) < 1e-9)
        let peak = (1...99).map { scale.value(at: Fraction(Int64($0), 100))! }.max()!
        #expect(peak > 1.0)  // overshoot
        #expect(op.value(at: .zero) == 0)
        #expect(op.value(at: .one) == 1)
        #expect(tpl.duration > .zero && tpl.duration <= Time(1, 2))
    }

    @Test func noneAndFade() {
        let none = CaptionPresetLibrary.builtIn.animation(for: "none")
        #expect(none.tracks.isEmpty && none.duration == .zero)
        let fade = CaptionPresetLibrary.builtIn.animation(for: "fade")
        #expect(fade.track(for: "scale") == nil)
        #expect(fade.track(for: "opacity")?.value(at: .zero) == 0)
    }

    @Test func unknownRefsFallBackToDefaults() {
        let lib = CaptionPresetLibrary.builtIn
        #expect(lib.style(for: "does-not-exist") == lib.style(for: lib.defaultStyleID))
        #expect(lib.style(for: "default") == lib.style(for: "classic"))
        #expect(lib.animation(for: "does-not-exist") == lib.animation(for: lib.defaultAnimationID))
        #expect(lib.defaultAnimationID == "none")
        #expect(lib.hasStyle("bold-box") && !lib.hasStyle("zzz"))
    }

    @Test func builtInStylesAreDistinct() {
        let lib = CaptionPresetLibrary.builtIn
        let classic = lib.style(for: "classic"), box = lib.style(for: "bold-box"), outline = lib.style(for: "outline")
        #expect(box.background != nil)
        #expect(outline.stroke != nil)
        #expect(classic.background == nil && classic.stroke == nil)
        #expect(Set([classic, box, outline]).count == 3)
        #expect(lib.styleIDs.contains("default"))
    }

    @Test func templateCodableRoundTrip() throws {
        let tpl = CaptionPresetLibrary.builtIn.animation(for: "pop-in")
        let data = try JSONEncoder().encode(tpl)
        #expect(try JSONDecoder().decode(KeyframeTemplate.self, from: data) == tpl)
    }
}
