import SQCore
import Testing
@testable import SQEditorUI

@MainActor @Suite struct TransitionSearchAliasTests {
    private func hits(_ q: String) -> [String] {
        EffectsPanelView.transitionEntries.filter { $0.matches(query: q) }.map(\.title)
    }
    @Test func filmDissolveFindsTheLinearLightDissolve() {
        #expect(hits("film dissolve") == ["Dissolve"])
    }
    @Test func theThirdTransitionSetIsInTheCatalog() {
        for t in ["Flip 3D", "Spring", "Fall", "Burn", "Flare", "Warp", "Shake"] { #expect(hits(t.lowercased()).contains(t), "\(t)") }
    }
}
