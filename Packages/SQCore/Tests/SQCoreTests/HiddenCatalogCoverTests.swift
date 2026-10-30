import Foundation
import Testing
@testable import SQCore

@Suite struct HiddenCatalogCoverTests {
    @Test func everyHiddenEffectNamesWhatCoversIt() {
        #expect(Set(HiddenCatalog.covers.keys) == HiddenCatalog.effectKinds)
    }

    @Test func effectCoversAreRealAndStayOffered() {
        for (kind, cover) in HiddenCatalog.covers {
            guard case .effect(let canonical) = cover else { continue }
            #expect(!HiddenCatalog.effectKinds.contains(canonical), "\(kind) is covered by a hidden effect")
            #expect(ClipEffect.make(kind: canonical) != nil, "\(canonical)")
        }
        #expect(HiddenCatalog.covers[ClipEffect.audioEQKind] == .effect(ClipEffect.audioParametricEQKind))
    }

    @Test func hiddenEffectsStayLookupable() {
        for k in HiddenCatalog.effectKinds { #expect(ClipEffect.make(kind: k) != nil, "\(k)") }
    }
}
