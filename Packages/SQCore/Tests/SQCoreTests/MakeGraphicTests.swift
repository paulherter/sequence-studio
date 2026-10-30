import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct MakeGraphicTests {
    private func project() -> (Project, Timeline.ID, Track.ID) {
        let v1 = Track(kind: .video), v2 = Track(kind: .video)
        let t = Timeline(name: "T", frameDuration: Time(1, 30), tracks: [v1, v2, Track(kind: .audio)])
        return (Project(name: "P", timelines: [t]), t.id, v2.id)
    }

    private func clip(_ p: Project, _ tl: Timeline.ID, _ id: Clip.ID) -> Clip {
        p.timeline(tl)!.tracks.flatMap(\.clips).first { $0.id == id }!
    }

    @Test func shapeClipKeepsPictureAndClipProperties() throws {
        var (p, tl, v2) = project()
        let id = try p.addShapeClip(.ellipse, in: tl, at: s(1), track: v2, duration: s(4))
        var c = clip(p, tl, id)
        c.animation.position = AnimatedProperty(Vec2(40, -20))
        c.blendMode = .multiply
        c.effects.append(ClipEffect(kind: ClipEffect.gaussianBlurKind,
                                    parameters: ClipEffect.defaultParameters(for: ClipEffect.gaussianBlurKind)
                                        .merging([ClipEffect.blurrinessKey: AnimatedProperty(12)]) { $1 }))
        try p.edit(tl) { try $0.replaceClip(c) }
        let b = p.timeline(tl)!.videoLayers(at: s(2))
        #expect(b.count == 1 && b[0].shape != nil)

        try p.convertToGraphics(clipID: id)
        let n = clip(p, tl, id)
        #expect(n.isGraphics && n.graphics?.layers.count == 1)
        #expect(n.animation == c.animation && n.blendMode == .multiply && n.timeline == c.timeline)
        #expect(n.effects.contains { $0.kind == ClipEffect.gaussianBlurKind })
        #expect(!n.effects.contains { $0.kind == ClipEffect.shapeEffectKind })
        let l = n.graphics!.layers[0]
        #expect(l.animation == ClipAnimation() && l.shapeEffect != nil)

        let a = p.timeline(tl)!.videoLayers(at: s(2))
        #expect(a.count == 1 && a[0].groups.count == 1)
        #expect(a[0].shape == b[0].shape)
        #expect(a[0].generator == b[0].generator)
        #expect(a[0].localTime == b[0].localTime)
        #expect(a[0].groups[0].transform == b[0].transform)
        #expect(a[0].groups[0].blendMode == b[0].blendMode)
        #expect(a[0].groups[0].effects == b[0].effects)
        #expect(a[0].transform == ClipTransform())
    }

    @Test func textClipCopiesPayloadUnchanged() throws {
        var (p, tl, v2) = project()
        let ref = GeneratorRef(kind: GeneratorRef.text, payload: Data("hello".utf8), payloadVersion: 3)
        let id = try p.addGeneratorClip(kind: ref.kind, payload: ref.payload, payloadVersion: 3, name: "Title",
                                        in: tl, at: .zero, track: v2, duration: s(3))
        let before = p.timeline(tl)!.videoLayers(at: s(1))
        try p.convertToGraphics(clipID: id)
        guard case .text(let r) = clip(p, tl, id).graphics!.layers[0].content else { Issue.record("not text"); return }
        #expect(r == ref)
        let after = p.timeline(tl)!.videoLayers(at: s(1))
        #expect(after.count == 1 && after[0].generator == before[0].generator && after[0].localTime == before[0].localTime)
        #expect(after[0].groups[0].transform == before[0].transform)
    }

    @Test func zonesAndEffectsStayOnTheClipAndPictureMatches() throws {
        var (p, tl, v2) = project()
        let id = try p.addShapeClip(.rectangle, in: tl, at: .zero, track: v2, duration: s(4))
        try p.setAnimationZones(AnimationZones(introEnd: s(1), outroLength: s(1)), clip: id)
        let b = p.timeline(tl)!.videoLayers(at: s(1))
        try p.convertToGraphics(clipID: id)
        #expect(clip(p, tl, id).zones != nil)
        let a = p.timeline(tl)!.videoLayers(at: s(1))
        #expect(a[0].shape == b[0].shape && a[0].groups[0].effects == b[0].effects)
    }

    @Test func refusesWhatWouldChangeThePicture() throws {
        var (p, tl, v2) = project()
        let keyed = try p.addShapeClip(.rectangle, in: tl, at: .zero, track: v2, duration: s(2))
        var c = clip(p, tl, keyed)
        let i = try #require(c.effects.firstIndex { $0.kind == ClipEffect.shapeEffectKind })
        c.effects[i].parameters[ClipEffect.shapeWidthKey]?.track.insert(Keyframe(time: .zero, value: 50))
        try p.edit(tl) { try $0.replaceClip(c) }
        #expect(p.makeGraphicBlocker(clipID: keyed) != nil)
        #expect(throws: EditError.notConvertible) { try p.convertToGraphics(clipID: keyed) }

        let blur = try p.addShapeClip(.rectangle, in: tl, at: s(3), track: v2, duration: s(2))
        var m = clip(p, tl, blur)
        m.animation.shutterAngle = AnimatedProperty(180)
        try p.edit(tl) { try $0.replaceClip(m) }
        #expect(p.makeGraphicBlocker(clipID: blur) == "Turn off motion blur first.")

        let var1 = try p.addShapeClip(.rectangle, in: tl, at: s(6), track: v2, duration: s(2))
        try p.edit(tl) { $0.variants = [FormatVariant(name: "V", width: 1080, height: 1920)] }
        var v = clip(p, tl, var1)
        v.variantOverrides = [p.timeline(tl)!.variants[0].id: { var o = VariantOverride(); o.position = AnimatedProperty(Vec2(1, 2)); return o }()]
        try p.edit(tl) { try $0.replaceClip(v) }
        #expect(p.makeGraphicBlocker(clipID: var1) == "Remove format variants first.")
        let text = try p.addGeneratorClip(kind: GeneratorRef.text, payload: Data("t".utf8), in: tl, at: s(9), track: v2, duration: s(1))
        #expect(p.makeGraphicBlocker(clipID: text) == "Remove format variants first.")
    }

    @Test func styleKitRewriteReachesTextLayersOfGraphics() throws {
        var (p, tl, v2) = project()
        let id = try p.addGraphicsClip(in: tl, at: .zero, track: v2, duration: s(2))
        let ref = GeneratorRef(kind: GeneratorRef.text, payload: Data("old".utf8))
        try p.addGraphicsLayer(.text(ref), to: id)
        let n = p.rewriteGenerators { $0.kind == GeneratorRef.text ? GeneratorRef(kind: $0.kind, payload: Data("new".utf8)) : nil }
        #expect(n == 1)
        guard case .text(let r) = clip(p, tl, id).graphics!.layers[0].content else { Issue.record("not text"); return }
        #expect(r.payload == Data("new".utf8))
    }

    @Test func rejectsOtherClipsAndLockedTracks() throws {
        var (p, tl, v2) = project()
        let g = try p.addGraphicsClip(in: tl, at: .zero, track: v2, duration: s(2))
        #expect(!p.canConvertToGraphics(clipID: g))
        #expect(throws: EditError.clipNotFound) { try p.convertToGraphics(clipID: g) }
        #expect(throws: EditError.clipNotFound) { try p.convertToGraphics(clipID: UUID()) }
        let sh = try p.addShapeClip(.rectangle, in: tl, at: s(5), track: v2, duration: s(2))
        #expect(p.canConvertToGraphics(clipID: sh))
        try p.edit(tl) { $0.tracks[1].isLocked = true }
        #expect(throws: EditError.trackLocked) { try p.convertToGraphics(clipID: sh) }
    }
}
