import Foundation
import Testing
@testable import SQCore

@Suite struct CornerWarpEffectTests {
    private func effect(_ values: [String: Vec2] = [:]) -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.cornerPinKind)!
        for (k, v) in values { e.points[k] = AnimatedProperty(v) }
        return e
    }

    @Test func dropInDefaultsDoNothing() {
        #expect(effect().imageFilter(atLocal: .zero) == nil)
        #expect(EffectCatalog.title(for: ClipEffect.cornerPinKind) == "Corner Warp")
        #expect(EffectCatalog.all.contains { $0.kind == ClipEffect.cornerPinKind })
    }

    @Test func offsetsBecomeTheFilter() {
        let e = effect([ClipEffect.cornerPinTopLeftKey: Vec2(10, 5), ClipEffect.cornerPinBottomRightKey: Vec2(-3, -4)])
        #expect(e.imageFilter(atLocal: .zero)
                == .cornerPin(topLeft: Vec2(10, 5), topRight: .zero, bottomRight: Vec2(-3, -4), bottomLeft: .zero))
    }

    @Test func everyCornerIsAPointAndTakesMasks() {
        let spec = EffectCatalog.spec(for: ClipEffect.cornerPinKind)!
        #expect(spec.params.map(\.key) == [ClipEffect.cornerPinTopLeftKey, ClipEffect.cornerPinTopRightKey,
                                           ClipEffect.cornerPinBottomRightKey, ClipEffect.cornerPinBottomLeftKey])
        for p in spec.params { if case .point = p.kind {} else { Issue.record("\(p.key) is not a point") } }
        #expect(ClipEffect.maskInputKinds.contains(ClipEffect.cornerPinKind))
    }
}
