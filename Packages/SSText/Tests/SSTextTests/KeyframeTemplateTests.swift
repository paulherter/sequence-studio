import Testing
import Foundation
import SSCore
@testable import SSText

@Suite struct KeyframeTemplateTests {
    @Test func trackSortsAndEvaluatesWithSSCoreKeyframes() {
        let t = AnimationTrack(property: "opacity", keys: [
            (Time(1, 1), 1, .linear), (.zero, 0, .linear),
        ])
        #expect(t.track.keys.map(\.time) == [.zero, Time(1, 1)])
        #expect(t.value(at: .zero) == 0)
        #expect(abs(t.value(at: Time(1, 2))! - 0.5) < 1e-9)
        #expect(t.value(at: Time(1, 1)) == 1)
        #expect(t.value(at: Time(5, 1)) == 1)   // clamped after the last key
        #expect(AnimationTrack(property: "x", keys: []).value(at: .zero) == nil)
    }

    @Test func shapesMapToSSCoreInterpolation() {
        let over = AnimationTrack(property: "s", keys: [(.zero, 0, .overshoot), (Time(1, 1), 1, .linear)]).track.keys
        #expect(over[0].interpolation == .bezier)
        #expect(over[0].outHandle.dy > 1)                 // handle outside 0...1 = overshoot
        let hold = AnimationTrack(property: "s", keys: [(.zero, 0, .hold), (Time(1, 1), 1, .linear)]).track.keys
        #expect(hold[0].interpolation == .hold)
        let lin = AnimationTrack(property: "s", keys: [(.zero, 0, .linear), (Time(1, 1), 1, .linear)]).track.keys
        #expect(lin[0].interpolation == .linear)
    }

    @Test func holdKeepsStartValueUntilNextKey() {
        let t = AnimationTrack(property: "s", keys: [(.zero, 2, .hold), (Time(1, 1), 7, .linear)])
        #expect(t.value(at: Time(1, 2)) == 2)
        #expect(t.value(at: Time(999, 1000)) == 2)
        #expect(t.value(at: Time(1, 1)) == 7)
    }

    @Test func easingShapesBehaveLikeTheOldCurves() {
        func mid(_ s: SegmentShape) -> Double {
            AnimationTrack(property: "p", keys: [(.zero, 0, s), (Time(1, 1), 1, .linear)]).value(at: Time(1, 2))!
        }
        #expect(abs(mid(.linear) - 0.5) < 1e-9)
        #expect(mid(.easeIn) < 0.5)
        #expect(mid(.easeOut) > 0.5)
        #expect(abs(mid(.easeInOut) - 0.5) < 1e-6)
        // t^3 ease-in: cubic-bezier (1/3,0)(2/3,0) is exactly t^3.
        #expect(abs(mid(.easeIn) - 0.125) < 1e-6)
    }

    @Test func templateLookupByProperty() {
        let tpl = CaptionPresetLibrary.builtIn.animation(for: "pop-in")
        #expect(tpl.track(for: "scale") != nil)
        #expect(tpl.track(for: "opacity") != nil)
        #expect(tpl.track(for: "nope") == nil)
        #expect(tpl.value(of: "nope", at: .zero) == nil)
    }

    @Test func popInScaleOvershootsAndOpacityRises() {
        let tpl = CaptionPresetLibrary.builtIn.animation(for: "pop-in")
        let d = tpl.duration
        #expect(d > .zero && d <= Time(1, 2))
        #expect(abs(tpl.value(of: "scale", at: .zero)! - 0.8) < 1e-9)
        #expect(abs(tpl.value(of: "scale", at: d)! - 1.0) < 1e-9)
        let samples = (1...99).map { tpl.value(of: "scale", at: Time(d.value * Int64($0), d.timescale * 100))! }
        #expect(samples.max()! > 1.0)                       // overshoot past the end value
        #expect(samples.max()! < 1.2)                       // but not wildly
        #expect(tpl.value(of: "scale", at: Time(d.value * 7, d.timescale * 10))! > 1.0)
        #expect(tpl.value(of: "opacity", at: .zero) == 0)
        #expect(tpl.value(of: "opacity", at: d) == 1)
        let quarter = tpl.value(of: "opacity", at: Time(d.value, d.timescale * 8))!
        #expect(quarter > 0 && quarter < 1)
        #expect(tpl.value(of: "opacity", at: Time(d.value * 3, d.timescale * 4)) == 1)
    }

    @Test func noneAndFade() {
        let none = CaptionPresetLibrary.builtIn.animation(for: "none")
        #expect(none.tracks.isEmpty && none.duration == .zero)
        #expect(none.value(of: "opacity", at: .zero) == nil)
        let fade = CaptionPresetLibrary.builtIn.animation(for: "fade")
        #expect(fade.track(for: "scale") == nil)
        #expect(fade.value(of: "opacity", at: .zero) == 0)
        #expect(abs(fade.value(of: "opacity", at: Time(1, 10))! - 0.5) < 1e-9)
        #expect(fade.value(of: "opacity", at: fade.duration) == 1)
    }

    @Test func builtInsAreDeterministic() throws {
        let a = CaptionPresetLibrary.builtIn.animation(for: "pop-in")
        let b = CaptionPresetLibrary.builtIn.animation(for: "pop-in")
        #expect(a == b)
        #expect(try JSONEncoder().encode(a).count > 0)
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
