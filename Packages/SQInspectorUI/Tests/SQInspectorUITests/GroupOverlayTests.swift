import CoreGraphics
import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

@Suite struct GroupOverlayTests {
    private func target() -> OverlayTarget {
        var t = OverlayTarget(clip: UUID(), size: CGSize(width: 640, height: 360), isText: false,
                              baseTransform: ClipTransform(position: Vec2(40, -10), scale: Vec2(1.5, 1.5)), shift: .zero,
                              positionTrack: KeyframeTrack<Vec2>())
        t.groupStages = [ClipTransform(position: Vec2(100, 20), scale: Vec2(0.5, 0.5), rotation: 30, opacity: 0.5)]
        return t
    }

    @Test func overlayDrawsThroughTheGroupStage() {
        let t = target()
        #expect(t.displayTransform == t.groupStages[0].composed(after: t.baseTransform))
        #expect(abs(t.displayTransform.scale.x - 0.75) < 1e-9)
    }

    @Test func overlayEditsComeBackThroughTheGroupStage() {
        let t = target()
        let back = t.baseTransform(fromDisplay: t.displayTransform)
        #expect(abs(back.position.x - 40) < 1e-6 && abs(back.position.y + 10) < 1e-6)
        #expect(abs(back.scale.x - 1.5) < 1e-9 && abs(back.rotation) < 1e-9 && abs(back.opacity - 1) < 1e-9)
    }

    @Test func groupTransformHandlesAreCanvasSpaceAndScaleHasNone() {
        let k = ClipEffect.groupTransformKind
        #expect(!PointHandleMapping.hasHandle(kind: k, key: ClipEffect.groupScaleKey))
        #expect(PointHandleMapping.hasHandle(kind: k, key: ClipEffect.groupPositionKey))
        #expect(PointHandleMapping.hasHandle(kind: ClipEffect.dropShadowKind, key: "x"))
        let tr = ClipTransform(position: Vec2(50, 0), scale: Vec2(2, 2))
        #expect(PointHandleMapping.offset(kind: k, local: Vec2(10, 5), transform: tr) == Vec2(10, 5))
        #expect(PointHandleMapping.local(kind: k, offset: Vec2(10, 5), transform: tr) == Vec2(10, 5))
        #expect(PointHandleMapping.offset(kind: "x", local: Vec2(10, 5), transform: tr) == Vec2(70, 10))
    }

    @Test func groupTransformShowsScaleAndOpacityAsPercent() {
        let scale = EffectProperty.fx(UUID(), kind: ClipEffect.groupTransformKind, key: ClipEffect.groupScaleKey)
        let opacity = EffectProperty.fx(UUID(), kind: ClipEffect.groupTransformKind, key: ClipEffect.groupOpacityKey)
        #expect(scale.display(1) == 100 && scale.native(fromDisplay: 50) == 0.5 && scale.displayUnit == "%")
        #expect(opacity.display(0.5) == 50 && opacity.displayUnit == "%")
        let pos = EffectProperty.fx(UUID(), kind: ClipEffect.groupTransformKind, key: ClipEffect.groupPositionKey)
        #expect(pos.display(12) == 12)
    }
}
