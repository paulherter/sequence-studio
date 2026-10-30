import Foundation
import Testing
@testable import SQCore

// Consolidation round 1 (DECISIONS 2026-10-07): hidden = not listed, still resolved, applied and rendered.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ effects: [ClipEffect], kind: TrackKind = .video) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: kind, source: TimeRange(start: s(10), duration: s(5)), start: s(0))
    c.effects = effects
    return c
}

@Suite struct HiddenMotionTests {
    @Test func hiddenMotionPresetsAreNotOfferedButStillApply() throws {
        let all = Set(MotionPresets.builtIns.map(\.id))
        #expect(HiddenCatalog.motionPresetIDs.isSubset(of: all), "a hidden id that does not exist")
        let offered = Set(MotionPresets.offered.map(\.id))
        #expect(offered.isDisjoint(with: HiddenCatalog.motionPresetIDs))
        #expect(offered.count + HiddenCatalog.motionPresetIDs.count == all.count)
        for id in ["whipIn", "elasticIn", "bounceIn", "spinIn", "slideInOvershoot", "captionPop", "ghostFrame"] {
            #expect(offered.contains(id), "\(id) is kept")
        }
        for id in HiddenCatalog.motionPresetIDs {
            let p = try #require(EffectStackPresets.preset(id: id), "\(id) must still resolve")
            #expect(!p.effects.isEmpty && p.effects.allSatisfy { EffectCatalog.spec(for: $0.kind) != nil }, "\(id)")
            var c = clip([])
            c.applyPreset(p.preset)
            #expect(c.effects.map(\.kind) == p.effects.map(\.kind), "\(id) applies the same effects")
        }
    }

    @Test func hiddenKeystonesAreAKnownSetOfBuiltIns() {
        let ids = Set(Keystone.builtIns.map(\.id))
        for n in HiddenCatalog.keystoneNumbers { #expect(ids.contains(Keystone.builtInID(n)), "keystone \(n)") }
        #expect(HiddenCatalog.isHidden(keystone: Keystone.builtInID(1)))
        #expect(!HiddenCatalog.isHidden(keystone: Keystone.builtInID(10)))   // Spin In stays
        #expect(Keystone.builtIn(named: "Spin In")?.id == Keystone.builtInID(10))
    }
}
