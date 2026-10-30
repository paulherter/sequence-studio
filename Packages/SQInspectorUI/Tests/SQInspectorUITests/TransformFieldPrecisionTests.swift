import Foundation
import SQCore
import Testing
@testable import SQInspectorUI

/// A transform field shows one decimal but stores what was typed: the display rounding never reaches the model.
@MainActor @Suite struct TransformFieldPrecisionTests {
    private func model() -> EffectControlsModel {
        let c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero)
        let m = EffectControlsModel()
        m.setClip(c)
        return m
    }

    @Test func transformRowsShowOneDecimal() {
        for p in [EffectProperty.position, .anchor, .scale, .rotation, .opacity] { #expect(p.displayDecimals == 1) }
    }

    @Test func storedValueKeepsTheTypedPrecision() {
        let m = model()
        m.setValue(.rotation, to: 33.25)
        #expect(m.clip!.animation.rotation.value == 33.25)
        #expect(m.scalarValue(.rotation) == 33.25)
    }
}
