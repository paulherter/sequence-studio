import Foundation
import Testing
@testable import SQCore

// C5: Outline (a stroke around any picture's alpha: cutouts, stickers, keyed footage) and Long Shadow (the picture's
// silhouette dragged out along an angle).

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func clip(_ e: ClipEffect) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(5)), start: .zero)
    c.effects = [e]
    return c
}

private func effect(_ kind: String, _ values: [String: Double] = [:]) -> ClipEffect {
    var e = ClipEffect.make(kind: kind)!
    for (k, v) in values { e.parameters[k] = AnimatedProperty(v) }
    return e
}

private func filter(_ e: ClipEffect) -> ImageFilter? { clip(e).effects(at: s(1)).segments.first?.filter }

@Suite struct OutlineLongShadowTests {
    @Test func bothAreOfferedWithStoredKindStrings() throws {
        #expect(ClipEffect.outlineKind == "alphaOutline" && ClipEffect.longShadowKind == "longShadow")
        for k in [ClipEffect.outlineKind, ClipEffect.longShadowKind] {
            #expect(EffectCatalog.all.contains { $0.kind == k }, "\(k)")
            #expect(ClipEffect.make(kind: k) != nil)
            #expect(ClipEffect.maskInputKinds.contains(k))
            #expect(!HiddenCatalog.effectKinds.contains(k))
        }
        #expect(EffectCatalog.title(for: ClipEffect.outlineKind) == "Outline")
        #expect(EffectCatalog.title(for: ClipEffect.longShadowKind) == "Long Shadow")
        #expect(EffectCatalog.param(ClipEffect.outlineKind, ClipEffect.outlineWidthKey)?.range == 0...500)
        #expect(EffectCatalog.param(ClipEffect.outlineKind, ClipEffect.outlineSoftnessKey)?.range == 0...200)
        #expect(EffectCatalog.param(ClipEffect.longShadowKind, ClipEffect.longShadowLengthKey)?.range == 0...4_000)
    }

    @Test func outlineDefaultsAndMargins() {
        #expect(filter(effect(ClipEffect.outlineKind)) == .outline(width: 12, color: SIMD3(1, 1, 1), softness: 0, position: .outside))
        // The canvas grows by what the stroke can reach beyond the picture.
        #expect(ImageFilter.outline(width: 12, color: .zero, softness: 4, position: .outside).margin == 17)
        #expect(ImageFilter.outline(width: 12, color: .zero, softness: 4, position: .centre).margin == 11)
        #expect(ImageFilter.outline(width: 12, color: .zero, softness: 4, position: .inside).margin == 1)
    }

    @Test func outlineIsClamped() {
        let hi = effect(ClipEffect.outlineKind, [ClipEffect.outlineWidthKey: 9_000, ClipEffect.outlineSoftnessKey: -5,
                                                 ClipEffect.outlinePositionKey: 7])
        #expect(filter(hi) == .outline(width: 500, color: SIMD3(1, 1, 1), softness: 0, position: .centre))
        let inside = effect(ClipEffect.outlineKind, [ClipEffect.outlinePositionKey: 1, ClipEffect.outlineSoftnessKey: 300])
        #expect(filter(inside) == .outline(width: 12, color: SIMD3(1, 1, 1), softness: 200, position: .inside))
    }

    @Test func zeroWidthOutlineIsNoEffect() {
        #expect(clip(effect(ClipEffect.outlineKind, [ClipEffect.outlineWidthKey: 0])).effects(at: s(1)) == .none)
        #expect(clip(effect(ClipEffect.outlineKind, [ClipEffect.outlineWidthKey: -3])).effects(at: s(1)) == .none)
    }

    @Test func longShadowDefaultsAndClamping() {
        #expect(filter(effect(ClipEffect.longShadowKind))
                == .longShadow(angle: 135, length: 200, color: SIMD3(0, 0, 0), fade: 0.5, opacity: 0.8))
        #expect(ImageFilter.longShadow(angle: 135, length: 200, color: .zero, fade: 0.5, opacity: 1).margin == 201)
        let hi = effect(ClipEffect.longShadowKind, [ClipEffect.longShadowLengthKey: 1e9, ClipEffect.longShadowFadeKey: 400,
                                                    ClipEffect.longShadowOpacityKey: -1])
        #expect(clip(hi).effects(at: s(1)) == .none)   // opacity 0: nothing to draw
        let long = effect(ClipEffect.longShadowKind, [ClipEffect.longShadowLengthKey: 1e9, ClipEffect.longShadowFadeKey: -4])
        #expect(filter(long) == .longShadow(angle: 135, length: 4_000, color: .zero, fade: 0, opacity: 0.8))
        #expect(clip(effect(ClipEffect.longShadowKind, [ClipEffect.longShadowLengthKey: 0])).effects(at: s(1)) == .none)
    }

    /// Angle convention as RGB Split: 0 = up, clockwise; the shadow runs away from the light along (sin a, -cos a).
    @Test func longShadowDirection() {
        let d = ImageFilter.longShadowDirection(degrees: 90)
        #expect(abs(d.x - 1) < 1e-12 && abs(d.y) < 1e-12)
        let down = ImageFilter.longShadowDirection(degrees: 180)
        #expect(abs(down.x) < 1e-12 && abs(down.y - 1) < 1e-12)
    }

    /// Long Shadow grows the canvas only along the axes it runs on (per axis, both sides, so the picture stays centered).
    @Test func longShadowMarginFollowsTheAngle() {
        func m(_ a: Double) -> Vec2 { ImageFilter.longShadow(angle: a, length: 100, color: .zero, fade: 0, opacity: 1).axisMargin }
        #expect(abs(m(90).x - 101) < 1e-9 && abs(m(90).y - 1) < 1e-9)
        #expect(abs(m(180).x - 1) < 1e-9 && abs(m(180).y - 101) < 1e-9)
        let d = m(135)
        #expect(abs(d.x - (100 * 0.5.squareRoot() + 1)) < 1e-9 && abs(d.y - d.x) < 1e-9)
        // Other filters: the same margin on both axes.
        let o = ImageFilter.outline(width: 12, color: .zero, softness: 4, position: .outside)
        #expect(o.axisMargin == Vec2(o.margin, o.margin))
    }
}
