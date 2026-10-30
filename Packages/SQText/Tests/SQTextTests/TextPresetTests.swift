import Testing
import Foundation
import SQCore
@testable import SQText

@Suite struct TextPresetTests {
    @Test func catalogIsWellFormed() {
        #expect(TextPresetCatalog.looks.count >= 8)
        #expect(TextPresetCatalog.motions.count >= 8)
        let ids = TextPresetCatalog.looks.map(\.id) + TextPresetCatalog.motions.map(\.id)
        #expect(Set(ids).count == ids.count)
        for c in TextPresetCategory.allCases {
            #expect(!TextPresetCatalog.looks(in: c).isEmpty, "looks in \(c)")
            #expect(!TextPresetCatalog.motions(in: c).isEmpty, "motions in \(c)")
        }
    }

    @Test func looksUseBundledFontsOnly() {
        for l in TextPresetCatalog.looks { #expect(BundledFonts.isBundled(l.style.fontName), "\(l.id): \(l.style.fontName)") }
    }

    @Test func motionsAreAnchoredAndFitProperties() {
        let known: Set<String> = ["scale", "opacity", "positionX", "positionY", "rotation"]
        for m in TextPresetCatalog.motions {
            #expect(m.animationIn != nil || m.animationOut != nil, "\(m.id)")
            if let i = m.animationIn { #expect(i.anchor == .start && (i.duration > .zero || i.textAnimator != nil) && i.tracks.allSatisfy { known.contains($0.property) }, "\(m.id)") }
            if let o = m.animationOut { #expect(o.anchor == .end && o.duration > .zero && o.tracks.allSatisfy { known.contains($0.property) }, "\(m.id)") }
        }
    }

    @Test func typewriterIsABuiltInTextAnimation() throws {
        let m = try #require(TextPresetCatalog.motion(id: "textanim.title-typewriter"))
        #expect(m.name == "Typewriter" && m.category == .titles && m.animationOut == nil)
        let a = try #require(m.animationIn?.textAnimator)
        #expect(a.effect == .typewriter && a.unit == .character && a.order == .forward && a.stagger > .zero)
        #expect(TextPresetCatalog.motions(in: .titles).contains(m))
        // Applying it sets the in side and keeps the out side.
        let out = KeyframeTemplate(tracks: [AnimationTrack(property: "opacity", keys: [(.zero, 1, .linear), (Time(1, 5), 0, .linear)])],
                                   duration: Time(1, 5), anchor: .end)
        let set = TextPresetApply.apply(motion: m, to: AnimationSet(in: nil, out: out))
        #expect(set.animationIn?.textAnimator?.effect == .typewriter && set.animationOut == out)
    }

    @Test func lookReplacesStyleOnly() {
        let box = TextBox(width: 800, height: 200)
        let t = TextTemplate(name: "T", text: "Hello", style: TextStyle(size: 30), animation: nil, box: box)
        let look = TextPresetCatalog.looks[0]
        let r = TextPresetApply.apply(look: look, to: t)
        #expect(r.style == look.style)
        #expect(r.text == "Hello" && r.box == box)
    }

    @Test func motionKeepsTheOtherSide() {
        let inOnly = TextPresetCatalog.motions.first { $0.animationIn != nil && $0.animationOut == nil }!
        let outOnly = TextPresetCatalog.motions.first { $0.animationOut != nil && $0.animationIn == nil }!
        var set = TextPresetApply.apply(motion: inOnly, to: nil)
        #expect(set.animationIn == inOnly.animationIn && set.animationOut == nil)
        set = TextPresetApply.apply(motion: outOnly, to: set)
        #expect(set.animationIn == inOnly.animationIn && set.animationOut == outOnly.animationOut)
        // A second in-animation replaces the first one and keeps the out.
        let other = TextPresetCatalog.motions.first { $0.animationIn != nil && $0.animationOut == nil && $0.id != inOnly.id }!
        set = TextPresetApply.apply(motion: other, to: set)
        #expect(set.animationIn == other.animationIn && set.animationOut == outOnly.animationOut)
    }

    @Test func lookAndMotionStackOnAGeneratorRef() throws {
        let t = TextTemplate(name: "T", text: "Hi", style: TextStyle())
        var ref = try TextGenerator.makeRef(template: t, animations: nil)
        ref = try TextPresetApply.apply(look: TextPresetCatalog.looks[1], to: ref)
        ref = try TextPresetApply.apply(motion: TextPresetCatalog.motions[0], to: ref)
        let (tt, anim) = try TextGenerator.decode(ref)
        #expect(tt.style == TextPresetCatalog.looks[1].style && tt.text == "Hi")
        #expect(anim?.animationIn == TextPresetCatalog.motions[0].animationIn)
        // Another look afterwards keeps the animation.
        ref = try TextPresetApply.apply(look: TextPresetCatalog.looks[2], to: ref)
        let (_, anim2) = try TextGenerator.decode(ref)
        #expect(anim2 == anim)
    }

    @Test func wrongKindThrows() {
        let ref = GeneratorRef(kind: "solid", payload: Data(), payloadVersion: 1)
        #expect(throws: (any Error).self) { try TextPresetApply.apply(look: TextPresetCatalog.looks[0], to: ref) }
    }

    @Test func idPrefixes() {
        let l = TextPresetCatalog.looks[0], m = TextPresetCatalog.motions[0]
        #expect(TextPresetCatalog.look(id: TextPresetCatalog.lookID(l))?.id == l.id)
        #expect(TextPresetCatalog.motion(id: TextPresetCatalog.motionID(m))?.id == m.id)
        #expect(TextPresetCatalog.look(id: "nope") == nil)
        #expect(TextPresetCatalog.isTextPresetID(TextPresetCatalog.lookID(l)))
        #expect(!TextPresetCatalog.isTextPresetID("film.grain"))
    }
}
