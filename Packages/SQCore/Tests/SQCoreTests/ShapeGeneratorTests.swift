import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct ShapeGeneratorTests {
    private func project(width: Int = 1920, height: Int = 1080) -> (Project, Timeline.ID, Track.ID, Track.ID) {
        let v = Track(kind: .video), a = Track(kind: .audio)
        let t = Timeline(name: "T", format: SequenceFormat(width: width, height: height, frameDuration: Time(1, 25)), tracks: [v, a])
        return (Project(name: "P", timelines: [t]), t.id, v.id, a.id)
    }
    private func clip(_ p: Project, _ tl: Timeline.ID, _ id: Clip.ID) -> Clip {
        p.timeline(tl)!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    @Test func generatorOwnedKindsAreKnown() {
        #expect(EffectCatalog.isGeneratorOwned(ClipEffect.shapeEffectKind))
        #expect(EffectCatalog.owningGenerator(of: ClipEffect.shapeEffectKind) == GeneratorRef.shape)
        for spec in EffectCatalog.all { #expect(!EffectCatalog.isGeneratorOwned(spec.kind)) }
        #expect(EffectCatalog.owningGenerator(of: ClipEffect.gaussianBlurKind) == nil)
    }

    @Test func generatorOwnedEffectCannotBeAddedOrDuplicated() throws {
        var (p, tl, v, _) = project()
        let id = try p.addShapeClip(.rectangle, in: tl, at: s(1), track: v, duration: s(4))
        var c = clip(p, tl, id)
        let shapeID = try #require(c.effects.first { $0.kind == ClipEffect.shapeEffectKind }?.id)
        #expect(c.addEffect(kind: ClipEffect.shapeEffectKind) == nil)
        #expect(c.duplicateEffect(shapeID) == nil)
        #expect(c.effects.filter { $0.kind == ClipEffect.shapeEffectKind }.count == 1)
        // A plain clip cannot get one either.
        c.generator = nil
        c.effects = []
        #expect(c.addEffect(kind: ClipEffect.shapeEffectKind) == nil)
        #expect(c.effects.isEmpty)
    }

    @Test func pasteAttributesCopiesTheShapeOnlyOntoAShape() throws {
        var (p, tl, v, _) = project()
        let a = try p.addShapeClip(.rectangle, in: tl, at: s(0), track: v, duration: s(4))
        let b = try p.addShapeClip(.ellipse, in: tl, at: s(5), track: v, duration: s(4))
        var src = clip(p, tl, a)
        let sid = src.effects.first { $0.kind == ClipEffect.shapeEffectKind }!.id
        src.setParameter(sid, ClipEffect.shapeWidthKey, to: 123)
        _ = src.addEffect(kind: ClipEffect.gaussianBlurKind)

        // Same generator kind: the shape values replace the target's single Shape effect.
        let dst = clip(p, tl, b).pastingAttributes(from: src)
        let shapes = dst.effects.filter { $0.kind == ClipEffect.shapeEffectKind }
        #expect(shapes.count == 1)
        #expect(shapes.first?.parameters[ClipEffect.shapeWidthKey]?.value == 123)
        #expect(dst.generator?.shapeKind == .ellipse)      // the outline kind stays the target's
        #expect(dst.effects.contains { $0.kind == ClipEffect.gaussianBlurKind })

        // Another clip: ordinary effects paste, the Shape effect does not.
        var plain = clip(p, tl, b)
        plain.generator = nil
        plain.effects = []
        let pasted = plain.pastingAttributes(from: src)
        #expect(!pasted.effects.contains { $0.kind == ClipEffect.shapeEffectKind })
        #expect(pasted.effects.contains { $0.kind == ClipEffect.gaussianBlurKind })
    }

    @Test func payloadRoundTripsTheShapeKind() {
        for k in ShapeKind.allCases {
            let ref = GeneratorRef.shape(k)
            #expect(ref.kind == GeneratorRef.shape)
            #expect(ref.shapeKind == k)
        }
        #expect(GeneratorRef(kind: GeneratorRef.text, payload: Data()).shapeKind == nil)
        // A damaged payload still draws something: a rectangle.
        #expect(GeneratorRef(kind: GeneratorRef.shape, payload: Data("x".utf8)).shapeKind == .rectangle)
    }

    @Test func catalogKnowsTheShapeButTheEffectsPanelDoesNot() {
        let spec = EffectCatalog.spec(for: ClipEffect.shapeEffectKind)
        #expect(spec?.title == "Shape")
        #expect(!EffectCatalog.all.contains { $0.kind == ClipEffect.shapeEffectKind })
        let e = ClipEffect.make(kind: ClipEffect.shapeEffectKind)!
        #expect(e.colors[ClipEffect.shapeFillColorKey] != nil && e.colors[ClipEffect.shapeStrokeColorKey] != nil)
        #expect(e.parameters[ClipEffect.shapeStrokeWidthKey] != nil && e.parameters[ClipEffect.shapeCornerRadiusKey] != nil)
    }

    @Test func addRectangleSizesToTheCanvas() throws {
        var (p, tl, v, _) = project()
        let id = try p.addShapeClip(.rectangle, in: tl, at: s(1), track: v, duration: s(4))
        let c = clip(p, tl, id)
        #expect(c.generator?.shapeKind == .rectangle)
        #expect(c.name == "Rectangle")
        #expect(c.timeline == TimeRange(start: s(1), duration: s(4)))
        let st = try #require(c.shapeStyle(atLocal: .zero))
        #expect(st.kind == .rectangle)
        #expect(st.width == 960 && st.height == 540)
        #expect(st.fill != nil)
        #expect(st.stroke == nil)                       // stroke off by default
        #expect(st.cornerRadius == 0)
    }

    @Test func ellipseIsACircleAndLineIsAStroke() throws {
        var (p, tl, v, _) = project()
        let e = try p.addShapeClip(.ellipse, in: tl, at: s(0), track: v, duration: s(2))
        let es = try #require(clip(p, tl, e).shapeStyle(atLocal: .zero))
        #expect(es.width == 540 && es.height == 540)
        let l = try p.addShapeClip(.line, in: tl, at: s(2), track: v, duration: s(2))
        let ls = try #require(clip(p, tl, l).shapeStyle(atLocal: .zero))
        #expect(ls.kind == .line)
        #expect(ls.width == 960)
        #expect(ls.stroke != nil && ls.fill == nil)
        #expect(ls.strokeWidth > 0)
        #expect(ls.rasterSize.height == ls.strokeWidth)
    }

    @Test func refusesAudioTracks() {
        var (p, tl, _, a) = project()
        #expect(throws: EditError.wrongTrackKind) { try p.addShapeClip(.rectangle, in: tl, at: s(0), track: a, duration: s(1)) }
    }

    @Test func everyStyleValueIsKeyframable() throws {
        var (p, tl, v, _) = project()
        let id = try p.addShapeClip(.rectangle, in: tl, at: s(0), track: v, duration: s(4))
        var c = clip(p, tl, id)
        let i = c.effects.firstIndex { $0.kind == ClipEffect.shapeEffectKind }!
        c.effects[i].colors[ClipEffect.shapeFillColorKey] = AnimatedProperty(.black, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: EffectColor(red: 1, green: 0, blue: 0)),
            Keyframe(time: s(2), value: EffectColor(red: 0, green: 0, blue: 1)),
        ]))
        c.effects[i].parameters[ClipEffect.shapeWidthKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 100), Keyframe(time: s(2), value: 300),
        ]))
        c.effects[i].parameters[ClipEffect.shapeCornerRadiusKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 0), Keyframe(time: s(2), value: 20),
        ]))
        c.effects[i].parameters[ClipEffect.shapeStrokeKey] = AnimatedProperty(1)
        c.effects[i].parameters[ClipEffect.shapeStrokeWidthKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 2), Keyframe(time: s(2), value: 10),
        ]))
        try p.edit(tl) { try $0.replaceClip(c) }
        let mid = try #require(clip(p, tl, id).shapeStyle(atLocal: s(1)))
        #expect(mid.width == 200)
        #expect(mid.cornerRadius == 10)
        #expect(mid.strokeWidth == 6)
        #expect(abs(mid.fill!.red - 0.5) < 1e-9 && abs(mid.fill!.blue - 0.5) < 1e-9)
        #expect(mid.rasterSize.width == 206)            // stroke centered on the outline: half of it outside
    }

    @Test func cornerRadiusIsClampedToHalfTheShorterSide() throws {
        var (p, tl, v, _) = project(width: 400, height: 200)
        let id = try p.addShapeClip(.rectangle, in: tl, at: s(0), track: v, duration: s(1))
        var c = clip(p, tl, id)
        let i = c.effects.firstIndex { $0.kind == ClipEffect.shapeEffectKind }!
        c.effects[i].parameters[ClipEffect.shapeCornerRadiusKey] = AnimatedProperty(5_000)
        try p.edit(tl) { try $0.replaceClip(c) }
        #expect(clip(p, tl, id).shapeStyle(atLocal: .zero)?.cornerRadius == 50)    // 200 x 100 rectangle
    }

    @Test func disabledShapeDrawsNothingAndMissingEffectUsesDefaults() throws {
        var (p, tl, v, _) = project()
        let id = try p.addShapeClip(.rectangle, in: tl, at: s(0), track: v, duration: s(1))
        var c = clip(p, tl, id)
        c.effects[0].enabled = false
        #expect(c.shapeStyle(atLocal: .zero) == nil)
        c.effects = []
        #expect(c.shapeStyle(atLocal: .zero) != nil)
        // Not a shape: no style.
        let plain = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(1)), start: .zero)
        #expect(plain.shapeStyle(atLocal: .zero) == nil)
    }

    @Test func changingTheKindKeepsTheStyle() throws {
        var (p, tl, v, _) = project()
        let id = try p.addShapeClip(.rectangle, in: tl, at: s(0), track: v, duration: s(1))
        let before = clip(p, tl, id).effects
        try p.setShapeKind(clipID: id, to: .ellipse)
        let c = clip(p, tl, id)
        #expect(c.generator?.shapeKind == .ellipse)
        #expect(c.effects == before)
        #expect(throws: EditError.clipNotFound) { try p.setShapeKind(clipID: UUID(), to: .line) }
    }

    @Test func layerRequestCarriesTheEvaluatedStyle() throws {
        var (p, tl, v, _) = project()
        let id = try p.addShapeClip(.ellipse, in: tl, at: s(1), track: v, duration: s(2))
        let layers = p.timeline(tl)!.videoLayers(at: s(2))
        #expect(layers.count == 1)
        #expect(layers[0].clip == id)
        #expect(layers[0].shape == clip(p, tl, id).shapeStyle(atLocal: s(1)))
        #expect(layers[0].effects == .none)             // the Shape effect is not an image effect
    }

    @Test func shapeClipSurvivesEncoding() throws {
        var (p, tl, v, _) = project()
        let id = try p.addShapeClip(.line, in: tl, at: s(0), track: v, duration: s(1))
        let c = clip(p, tl, id)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
        #expect(back == c)
        #expect(back.shapeStyle(atLocal: .zero) == c.shapeStyle(atLocal: .zero))
    }
}

@Suite struct ArrowShapeTests {
    @Test func arrowOutlineFitsItsBoxAndPointsRight() {
        let st = ShapeStyle(kind: .arrow, width: 200, height: 100, fill: .white)
        let pts = st.arrowPoints
        #expect(pts.count == 7)
        #expect(pts.allSatisfy { $0.x >= 0 && $0.x <= 200 && $0.y >= 0 && $0.y <= 100 })
        #expect(pts.contains(Vec2(200, 50)))
        #expect(pts.first == Vec2(0, 30) && pts.last == Vec2(0, 70))
        #expect(!st.isEmpty && st.rasterSize.width == 200)
    }

    @Test func shortArrowKeepsAShaft() {
        let pts = ShapeStyle(kind: .arrow, width: 50, height: 100, fill: .white).arrowPoints
        #expect(pts[1].x == 20)
    }

    @Test func arrowClipHasDefaultsAndRoundTripsItsKind() throws {
        var p = Project(name: "P", timelines: [Timeline(name: "T", format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25)),
                                                          tracks: [Track(kind: .video, name: "V1")])])
        let tl = p.timelines[0]
        let id = try p.addShapeClip(.arrow, in: tl.id, at: .zero, track: tl.tracks[0].id, duration: Time(2, 1))
        let c = p.timeline(tl.id)!.tracks.flatMap(\.clips).first { $0.id == id }!
        #expect(c.generator?.shapeKind == .arrow)
        let s = try #require(c.shapeStyle(atLocal: .zero))
        #expect(s.kind == .arrow && s.width == 480 && s.height == 180 && s.fill != nil)
        #expect(ShapeKind(rawValue: "arrow") == .arrow)
    }
}
