import Foundation
import Testing
@testable import SQCore

@Suite struct UnsharpMaskEffectTests {
    private func effect(radius: Double? = nil, amount: Double? = nil, threshold: Double? = nil) -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.unsharpMaskKind)!
        if let radius { e.parameters[ClipEffect.unsharpRadiusKey] = AnimatedProperty(radius) }
        if let amount { e.parameters[ClipEffect.unsharpAmountKey] = AnimatedProperty(amount) }
        if let threshold { e.parameters[ClipEffect.unsharpThresholdKey] = AnimatedProperty(threshold) }
        return e
    }

    @Test func dropInDefaultsDoNothing() {
        let e = ClipEffect.make(kind: ClipEffect.unsharpMaskKind)!
        #expect(e.imageFilter(atLocal: .zero) == nil)
        #expect(EffectCatalog.title(for: ClipEffect.unsharpMaskKind) == "Unsharp Mask")
        #expect(EffectCatalog.all.contains { $0.kind == ClipEffect.unsharpMaskKind })
    }

    @Test func parametersBecomeTheFilter() {
        #expect(effect(radius: 4, amount: 150, threshold: 10).imageFilter(atLocal: .zero)
                == .unsharpMask(sigma: 2, amount: 1.5, threshold: 0.1))
        #expect(effect(radius: 0, amount: 100).imageFilter(atLocal: .zero) == nil)
        #expect(effect(amount: 0).imageFilter(atLocal: .zero) == nil)
    }

    @Test func everyParameterIsKeyframable() {
        let spec = EffectCatalog.spec(for: ClipEffect.unsharpMaskKind)!
        #expect(spec.params.map(\.key) == [ClipEffect.unsharpRadiusKey, ClipEffect.unsharpAmountKey, ClipEffect.unsharpThresholdKey])
        #expect(ClipEffect.maskInputKinds.contains(ClipEffect.unsharpMaskKind))
    }
}
