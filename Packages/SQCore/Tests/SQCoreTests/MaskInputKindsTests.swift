import Foundation
import Testing
@testable import SQCore

// Mask follow-up (1): Color, keying and Transform effects take a mask input (DECISIONS 2026-10-06 "Mask inputs on color,
// keys and Transform"). The renderer gets them as effect segments with a `scope`; the clip's own grade and transform leave
// them out.

@Suite struct MaskInputKindsTests {
    private func clip() -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero)
    }

    private func inputMask(_ c: inout Clip) -> ClipMask {
        var m = ClipMask.make(.ellipse, name: "M")
        m.usedByOpacity = false
        c.masks.append(m)
        return m
    }

    private func grade(exposure: Float) -> ClipEffect {
        var e = ColorEffect(id: 1)
        e.basic.exposure = exposure
        return ClipEffect.colorGrade(e)
    }

    private func ultraKey() -> ClipEffect {
        ClipEffect(kind: ClipEffect.ultraKeyKind, parameters: ClipEffect.defaultParameters(for: ClipEffect.ultraKeyKind))
    }

    private func transform(scale: Double) -> ClipEffect {
        var e = ClipEffect(kind: ClipEffect.transformKind, parameters: ClipEffect.defaultParameters(for: ClipEffect.transformKind))
        e.parameters[ClipEffect.stageScaleKey] = AnimatedProperty(scale)
        return e
    }

    // MARK: Which effects take a mask

    @Test func keysTransformAndLaterColourEffectsTakeAMask() {
        var c = clip()
        c.effects = [grade(exposure: 0.5), grade(exposure: 1), ultraKey(),
                     ClipEffect(kind: ClipEffect.lumaKeyKind), transform(scale: 120), ClipEffect(kind: ClipEffect.cropKind)]
        let takes = c.effects.map { c.takesMaskInput($0) }
        // The first Color effect converts the footage (the clip's base grade): it stays whole.
        #expect(takes == [false, true, true, true, true, false])
        let m = inputMask(&c)
        c.setMask(m.id, input: true, ofEffect: c.effects[0].id)
        #expect(c.effects[0].maskInput.isEmpty)
        c.setMask(m.id, input: true, ofEffect: c.effects[1].id)
        #expect(c.effects[1].maskInput == [m.id])
    }

    // MARK: Color

    @Test func maskedColourEffectLeavesTheClipGradeAndBecomesASegment() throws {
        var c = clip()
        c.effects = [grade(exposure: 0.5), grade(exposure: 1)]
        let m = inputMask(&c)
        let whole = c.renderColor(atLocal: .zero)
        #expect(whole.effects.count == 2)
        c.setMask(m.id, input: true, ofEffect: c.effects[1].id)
        let base = c.renderColor(atLocal: .zero)
        #expect(base.effects.count == 1)
        #expect(base.effects[0].basic.exposure == 0.5)
        let fx = c.effects(at: .zero)
        let seg = try #require(fx.segments.first { $0.grade != nil })
        #expect(seg.grade?.basic.exposure == 1)
        #expect(seg.scope.count == 1)
        #expect(fx.segments.count == 2)                      // the graded image, then the draw
        #expect(!fx.isIdentity)
    }

    @Test func colourEffectWithoutLiveMaskStaysInTheClipGrade() {
        var c = clip()
        c.effects = [grade(exposure: 0.5), grade(exposure: 1)]
        var m = inputMask(&c)
        c.setMask(m.id, input: true, ofEffect: c.effects[1].id)
        m.enabled = false
        c.masks = [m]
        #expect(c.renderColor(atLocal: .zero).effects.count == 2)
        #expect(c.effects(at: .zero).segments.allSatisfy { $0.grade == nil })
    }

    @Test func switchedOffMaskedColourEffectDrawsNothing() {
        var c = clip()
        c.effects = [grade(exposure: 0.5), grade(exposure: 1)]
        let m = inputMask(&c)
        c.setMask(m.id, input: true, ofEffect: c.effects[1].id)
        c.effects[1].enabled = false
        #expect(c.renderColor(atLocal: .zero).effects.count == 1)
        #expect(c.effects(at: .zero).segments.allSatisfy { $0.grade == nil })
    }

    // MARK: Keys

    @Test func maskedKeyGetsItsOwnSegment() throws {
        var c = clip()
        c.effects = [ultraKey(), ClipEffect(kind: ClipEffect.lumaKeyKind)]
        let m = inputMask(&c)
        c.setMask(m.id, input: true, ofEffect: c.effects[0].id)
        let fx = c.effects(at: .zero)
        let keyed = try #require(fx.segments.first)
        #expect(keyed.keys.count == 1)
        #expect(keyed.scope.count == 1)
        #expect(keyed.filter == nil && keyed.blurAfter == 0 && keyed.shadow == nil && keyed.grade == nil)
        // The unmasked Luma Key follows in the next pass, unscoped.
        #expect(fx.segments.count >= 2)
        #expect(fx.segments[1].keys.count == 1)
        #expect(fx.segments[1].scope.isEmpty)
    }

    @Test func maskedKeyAfterAnUnmaskedOneStartsANewPass() {
        var c = clip()
        c.effects = [ClipEffect(kind: ClipEffect.lumaKeyKind), ultraKey()]
        let m = inputMask(&c)
        c.setMask(m.id, input: true, ofEffect: c.effects[1].id)
        let fx = c.effects(at: .zero)
        #expect(fx.segments[0].keys.count == 1 && fx.segments[0].scope.isEmpty)
        #expect(fx.segments[1].keys.count == 1 && fx.segments[1].scope.count == 1)
        #expect(fx.segments.count == 3)
    }

    // MARK: Transform

    @Test func maskedTransformIsAPictureWarpNotAClipTransform() throws {
        var c = clip()
        c.effects = [transform(scale: 200)]
        let frame = Vec2(1920, 1080)
        #expect(c.renderTransform(at: .zero, frame: frame).scale.x == 2)
        let m = inputMask(&c)
        c.setMask(m.id, input: true, ofEffect: c.effects[0].id)
        #expect(c.renderTransform(at: .zero, frame: frame).scale.x == 1)
        let seg = try #require(c.effects(at: .zero).segments.first)
        guard case .stageWarp(let a, let b, let cc, let d, let tx, let ty, let opacity)? = seg.filter else {
            Issue.record("no stage warp: \(String(describing: seg.filter))"); return
        }
        // Inverse of scale 2 about the center: source = output / 2.
        #expect(abs(a - 0.5) < 1e-12 && abs(d - 0.5) < 1e-12 && abs(b) < 1e-12 && abs(cc) < 1e-12)
        #expect(abs(tx) < 1e-9 && abs(ty) < 1e-9)
        #expect(opacity == 1)
        #expect(seg.scope.count == 1)
    }

    @Test func stageWarpInvertsPositionRotationAndAnchor() throws {
        var s = StageTransform.identity
        s.position = Vec2(30, -10); s.rotation = 30; s.scale = 1.5; s.scaleY = 0.8; s.anchor = Vec2(12, 7)
        guard case .stageWarp(let a, let b, let c, let d, let tx, let ty, _)? = ImageFilter.stage(s) else {
            Issue.record("identity"); return
        }
        let fwd = Affine2(s)
        for p in [Vec2(0, 0), Vec2(100, -40), Vec2(-300, 220)] {
            let q = fwd.apply(p)
            let back = Vec2(a * q.x + b * q.y + tx, c * q.x + d * q.y + ty)
            #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
        }
        #expect(ImageFilter.stage(.identity) == nil)
    }

    @Test func maskedTransformLeavesTheShutterAndStaticCheckAlone() {
        var c = clip()
        c.effects = [transform(scale: 150)]
        let m = inputMask(&c)
        c.setMask(m.id, input: true, ofEffect: c.effects[0].id)
        #expect(!c.hasTransformStage)
    }
}
