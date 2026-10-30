import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

@Suite struct RotationTextTests {
    @Test func formatsTurnsAndDegrees() {
        #expect(RotationText.format(30) == "30.0\u{00B0}")
        #expect(RotationText.format(0) == "0.0\u{00B0}")
        #expect(RotationText.format(-30) == "-30.0\u{00B0}")
        #expect(RotationText.format(390) == "1x 30.0\u{00B0}")
        #expect(RotationText.format(720) == "2x 0.0\u{00B0}")
        #expect(RotationText.format(-390) == "-1x 30.0\u{00B0}")
        #expect(RotationText.format(359.97) == "1x 0.0\u{00B0}")
    }

    @Test func hugeValuesDoNotTrap() {
        #expect(!RotationText.format(1e23).isEmpty)
        #expect(!RotationText.format(-Double.greatestFiniteMagnitude).isEmpty)
        _ = RotationText.parse("99999999999999999999x", current: 0)
        #expect(RotationText.parse("1e400x", current: 0) == nil)
    }

    @Test func parsesTurnsAndPlainInput() {
        #expect(RotationText.parse("1x30", current: 0) == 390)
        #expect(RotationText.parse("1x 30.5\u{00B0}", current: 0) == 390.5)
        #expect(RotationText.parse("-1x30", current: 0) == -390)
        #expect(RotationText.parse("2x", current: 0) == 720)
        #expect(RotationText.parse("390", current: 0) == 390)
        #expect(RotationText.parse("+10", current: 20) == 30)
        #expect(RotationText.parse("1.5x3", current: 0) == nil)
        #expect(RotationText.parse("abc", current: 0) == nil)
        #expect(RotationText.parse(RotationText.format(1234.5), current: 0) == 1234.5)
    }

    @Test func positionAndAnchorAreCenteredYUp() {
        // Stored: px from center, y down. Shown (Resolve / FCP): 0,0 = centered, Y up; no canvas or picture size involved.
        #expect(EffectProperty.position.display(0, component: .x) == 0)
        #expect(EffectProperty.position.display(0, component: .y) == 0)
        #expect(EffectProperty.position.display(120, component: .x) == 120)
        #expect(EffectProperty.position.display(120, component: .y) == -120)
        #expect(EffectProperty.anchor.display(-40, component: .y) == 40)
        #expect(EffectProperty.rotation.display(30) == -30)      // counterclockwise positive
        #expect(EffectProperty.scale.display(1.5) == 150 && EffectProperty.opacity.display(0.5) == 50)
        #expect(EffectProperty.scale.displaySign() == 1 && EffectProperty.opacity.displaySign() == 1)
    }

    @Test func displayRoundTripsToTheStoredValue() {
        let rows: [(EffectProperty, EffectComponent)] = [
            (.position, .x), (.position, .y), (.anchor, .x), (.anchor, .y), (.rotation, .all),
            (.scale, .x), (.scale, .y), (.opacity, .all),
        ]
        for (p, c) in rows {
            for m in [-1234.5, -1, 0, 0.25, 1, 540, 960, 1e5] {
                let back = p.native(fromDisplay: p.display(m, component: c), component: c)
                #expect(abs(back - m) < 1e-9, "\(p) \(c) \(m)")
            }
        }
        // Effect-stage rows (Transform / Auto Reframe / Group Transform).
        let kinds: [(String, String, EffectComponent)] = [
            (ClipEffect.transformKind, ClipEffect.stagePositionYKey, .all),
            (ClipEffect.transformKind, ClipEffect.stageAnchorYKey, .all),
            (ClipEffect.transformKind, ClipEffect.stageRotationKey, .all),
            (ClipEffect.transformKind, ClipEffect.stagePositionXKey, .y),
            (ClipEffect.groupTransformKind, ClipEffect.groupPositionKey, .y),
        ]
        for (kind, key, c) in kinds {
            let p = EffectProperty.fx(UUID(), kind: kind, key: key)
            #expect(p.displaySign(component: c) == -1, "\(kind) \(key)")
            #expect(p.native(fromDisplay: p.display(37, component: c), component: c) == 37)
        }
        #expect(EffectProperty.fx(UUID(), kind: ClipEffect.transformKind, key: ClipEffect.stagePositionXKey)
            .displaySign(component: .x) == 1)
    }

    @Test func displayDoesNotChangeTheRenderedTransform() {
        // An imported clip (Premiere values converted at import) keeps its stored transform: showing it and writing
        // the shown numbers back (what an untouched field does) maps every point exactly as before.
        var t = ClipTransform.identity
        t.position = Vec2(310, -95); t.anchor = Vec2(-12, 40); t.rotation = 17.5; t.scale = Vec2(1.2, 0.8)
        var back = t
        back.position = Vec2(EffectProperty.position.native(fromDisplay: EffectProperty.position.display(t.position.x, component: .x), component: .x),
                             EffectProperty.position.native(fromDisplay: EffectProperty.position.display(t.position.y, component: .y), component: .y))
        back.anchor = Vec2(EffectProperty.anchor.native(fromDisplay: EffectProperty.anchor.display(t.anchor.x, component: .x), component: .x),
                           EffectProperty.anchor.native(fromDisplay: EffectProperty.anchor.display(t.anchor.y, component: .y), component: .y))
        back.rotation = EffectProperty.rotation.native(fromDisplay: EffectProperty.rotation.display(t.rotation))
        #expect(back == t)
        func map(_ x: ClipTransform, _ p: Vec2) -> Vec2 {
            let r = x.rotation * .pi / 180, d = p - x.anchor
            let sx = d.x * x.scale.x, sy = d.y * x.scale.y
            return Vec2(sx * cos(r) - sy * sin(r), sx * sin(r) + sy * cos(r)) + x.position
        }
        for p in [Vec2(0, 0), Vec2(100, -50), Vec2(-960, 540)] { #expect(map(back, p) == map(t, p)) }
    }
}
